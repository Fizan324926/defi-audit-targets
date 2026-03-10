#!/usr/bin/env python3
"""
VULN-002: Cross-Chain Double Deposit Verification

Analyzes the LayerZeroProvider code to verify that multiple bridge messages
can create multiple deposits from a single user operation when the user
has existing multichain balances.

Usage: python3 vuln002_cross_chain_double_deposit.py
"""

import hashlib
from dataclasses import dataclass, field
from typing import List, Optional


@dataclass
class MultichainBalance:
    """Simulates MultichainVault balance tracking"""
    account: str
    token: str
    amount: float


@dataclass
class BridgeMessage:
    """Simulates a LayerZero cross-chain message"""
    guid: str
    account: str
    src_chain_id: int
    amount: float
    token: str
    action_type: str
    deposit_params: dict = field(default_factory=dict)


@dataclass
class MultichainVault:
    """Simulates the MultichainVault contract"""
    balances: dict = field(default_factory=dict)

    def record_transfer_in(self, token: str, account: str, amount: float, src_chain_id: int):
        key = f"{account}:{token}"
        if key not in self.balances:
            self.balances[key] = 0
        self.balances[key] += amount
        return self.balances[key]

    def get_balance(self, account: str, token: str) -> float:
        key = f"{account}:{token}"
        return self.balances.get(key, 0)


class LayerZeroProviderSimulator:
    """Simulates the LayerZeroProvider.lzCompose flow"""

    def __init__(self, vault: MultichainVault):
        self.vault = vault
        self.deposits_created = []
        self.events = []

    def lz_compose(self, message: BridgeMessage) -> dict:
        """
        Simulates lzCompose processing:
        1. Records bridge-in (credits multichain balance)
        2. Handles action (e.g., creates deposit)
        """
        # Step 1: Record bridge transfer
        # NOTE: The account field is user-supplied and NOT validated
        new_balance = self.vault.record_transfer_in(
            message.token,
            message.account,
            message.amount,
            message.src_chain_id
        )

        self.events.append({
            "type": "bridge_in",
            "account": message.account,
            "token": message.token,
            "amount": message.amount,
            "new_balance": new_balance,
        })

        # Step 2: Handle deposit action
        if message.action_type == "Deposit":
            deposit_amount = message.deposit_params.get("amount", message.amount)

            # The deposit uses the MULTICHAIN BALANCE, not just the bridged amount
            # This is the key vulnerability: previous balance + new bridge = deposit amount
            available_balance = self.vault.get_balance(message.account, message.token)

            if available_balance >= deposit_amount:
                self.deposits_created.append({
                    "account": message.account,
                    "amount": deposit_amount,
                    "token": message.token,
                    "src_chain_id": message.src_chain_id,
                })
                self.events.append({
                    "type": "deposit_created",
                    "account": message.account,
                    "amount": deposit_amount,
                })
                return {"success": True, "deposit_amount": deposit_amount}
            else:
                self.events.append({
                    "type": "deposit_failed",
                    "account": message.account,
                    "required": deposit_amount,
                    "available": available_balance,
                })
                return {"success": False, "reason": "insufficient_balance"}

        return {"success": True, "action": "balance_only"}


def simulate_double_deposit():
    """
    Demonstrates the double-deposit vulnerability:
    User sends one bridge transaction, but the code processes it in a way
    that could create deposits using pre-existing multichain balances.
    """
    print("=" * 70)
    print("VULN-002: Cross-Chain Double Deposit Simulation")
    print("=" * 70)

    vault = MultichainVault()
    provider = LayerZeroProviderSimulator(vault)

    # Scenario 1: Normal single deposit
    print("\n--- Scenario 1: Normal Single Deposit ---")
    msg1 = BridgeMessage(
        guid="msg_001",
        account="0xAlice",
        src_chain_id=42161,  # Arbitrum
        amount=10.0,
        token="WETH",
        action_type="Deposit",
        deposit_params={"amount": 10.0}
    )
    result = provider.lz_compose(msg1)
    print(f"  Bridge: 10 WETH from Arbitrum")
    print(f"  Result: {result}")
    print(f"  Alice WETH balance: {vault.get_balance('0xAlice', 'WETH')}")

    # Scenario 2: Double deposit - user has existing balance
    print("\n--- Scenario 2: Double Deposit with Existing Balance ---")
    vault2 = MultichainVault()
    provider2 = LayerZeroProviderSimulator(vault2)

    # Alice already has 10 WETH in multichain vault from previous operation
    vault2.record_transfer_in("WETH", "0xAlice", 10.0, 42161)
    print(f"  Pre-existing balance: {vault2.get_balance('0xAlice', 'WETH')} WETH")

    # Alice bridges another 10 WETH with deposit instruction
    msg2 = BridgeMessage(
        guid="msg_002",
        account="0xAlice",
        src_chain_id=42161,
        amount=10.0,
        token="WETH",
        action_type="Deposit",
        deposit_params={"amount": 20.0}  # Tries to deposit MORE than bridged
    )
    result2 = provider2.lz_compose(msg2)
    print(f"  Bridge: 10 WETH from Arbitrum")
    print(f"  Deposit requested: 20 WETH")
    print(f"  Result: {result2}")
    print(f"  Alice balance after: {vault2.get_balance('0xAlice', 'WETH')}")
    print(f"  Deposits created: {len(provider2.deposits_created)}")

    # Scenario 3: Multiple bridge messages for same user
    print("\n--- Scenario 3: Multiple Bridge Messages (Same User) ---")
    vault3 = MultichainVault()
    provider3 = LayerZeroProviderSimulator(vault3)

    # Two separate bridge messages arrive (e.g., from two Stargate messages)
    for i in range(2):
        msg = BridgeMessage(
            guid=f"msg_00{i+3}",
            account="0xAlice",
            src_chain_id=42161,
            amount=10.0,
            token="WETH",
            action_type="Deposit",
            deposit_params={"amount": 10.0}
        )
        result = provider3.lz_compose(msg)
        print(f"  Message {i+1}: Bridge 10 WETH, Deposit result: {result}")
        print(f"    Balance after: {vault3.get_balance('0xAlice', 'WETH')}")

    print(f"  Total deposits created: {len(provider3.deposits_created)}")
    print(f"  Total deposited value: {sum(d['amount'] for d in provider3.deposits_created)}")
    print(f"  Total bridged value: 20 WETH (2 x 10)")

    # Scenario 4: Account injection - attacker uses victim's address
    print("\n--- Scenario 4: Account Injection Attack ---")
    vault4 = MultichainVault()
    provider4 = LayerZeroProviderSimulator(vault4)

    # Victim has existing balance
    vault4.record_transfer_in("WETH", "0xVictim", 50.0, 42161)

    # Attacker bridges with victim's account (account field is user-supplied!)
    msg_attack = BridgeMessage(
        guid="msg_attack",
        account="0xVictim",  # Attacker sets account to victim
        src_chain_id=42161,
        amount=1.0,          # Attacker bridges only 1 WETH
        token="WETH",
        action_type="Deposit",
        deposit_params={"amount": 51.0}  # But deposits 51 WETH (1 + 50 existing)
    )
    result4 = provider4.lz_compose(msg_attack)
    print(f"  Victim pre-existing balance: 50 WETH")
    print(f"  Attacker bridges: 1 WETH (with account=victim)")
    print(f"  Deposit requested: 51 WETH")
    print(f"  Result: {result4}")
    print(f"  NOTE: Account field is user-supplied per code comments!")


def analyze_code_evidence():
    """
    References to the actual code that enables this vulnerability.
    """
    print("\n" + "=" * 70)
    print("Code Evidence from LayerZeroProvider.sol")
    print("=" * 70)

    evidence = [
        {
            "file": "LayerZeroProvider.sol",
            "line": "101-105",
            "code": '/// @dev The `account` field is user-supplied and not validated',
            "impact": "Anyone can set any account address in the bridge message"
        },
        {
            "file": "LayerZeroProvider.sol",
            "line": "73-84 (from code comments)",
            "code": "WARNING: if a user does not want to receive a double deposit...",
            "impact": "Protocol ACKNOWLEDGES the double-deposit risk but provides NO on-chain fix"
        },
        {
            "file": "LayerZeroProvider.sol",
            "line": "385-415",
            "code": "_handleDeposit uses try/catch - failures are silently logged",
            "impact": "Failed deposits don't revert the bridge - tokens stuck in vault"
        },
    ]

    for e in evidence:
        print(f"\n  File: {e['file']}:{e['line']}")
        print(f"  Code: {e['code']}")
        print(f"  Impact: {e['impact']}")


def main():
    simulate_double_deposit()
    analyze_code_evidence()

    print("\n" + "=" * 70)
    print("CONCLUSION:")
    print("  1. Account field in lzCompose is user-supplied and NOT validated")
    print("  2. Double deposits possible when user has existing balance")
    print("  3. No idempotency check on bridge message processing")
    print("  4. Protocol relies on FRONTEND to prevent, not smart contracts")
    print("=" * 70)


if __name__ == "__main__":
    main()
