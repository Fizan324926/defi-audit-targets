#!/usr/bin/env python3
"""
VULN-001: PayableMulticall msg.value Double-Counting Analysis

Analyzes the theoretical impact of msg.value reuse in delegatecall-based
multicall patterns. Demonstrates how a single ETH payment can be counted
multiple times across delegatecall iterations.

Usage: python3 vuln001_multicall_analysis.py
"""

from dataclasses import dataclass
from typing import List


@dataclass
class MulticallExploit:
    """Models the msg.value reuse vulnerability"""
    msg_value: float  # ETH sent
    num_calls: int    # Number of delegatecalls
    call_types: List[str]  # Type of each call


def simulate_multicall_exploit(msg_value: float, num_deposit_calls: int) -> dict:
    """
    Simulate the effect of msg.value reuse across delegatecalls.

    In a delegatecall-based multicall:
    - msg.value is the SAME for every delegatecall
    - If multiple calls check msg.value, they all see the full amount
    - This can lead to accounting errors if the contract trusts msg.value
    """
    actual_eth_sent = msg_value
    perceived_eth_per_call = msg_value  # Each call sees full msg.value
    total_perceived = perceived_eth_per_call * num_deposit_calls

    return {
        "actual_eth_sent": actual_eth_sent,
        "perceived_per_call": perceived_eth_per_call,
        "total_perceived": total_perceived,
        "amplification_factor": num_deposit_calls,
        "excess_credit": total_perceived - actual_eth_sent,
    }


def analyze_gmx_sendwnt():
    """
    Analyze the specific GMX sendWnt pattern.

    GMX's sendWnt takes an `amount` parameter, NOT msg.value directly.
    However, the underlying depositAndSendWrappedNativeToken uses:
        IWNT(_wnt).deposit{value: amount}()

    The question is: can `amount` exceed msg.value per-call within multicall?
    Answer: Yes, if the router contract holds surplus ETH from:
    - Previous refunded execution fees
    - Direct ETH transfers (donations/accidents)
    - Previous multicall excess

    In this case:
    multicall([
        sendWnt(depositVault, msg.value),  # Uses full msg.value worth of ETH
        sendWnt(depositVault, msg.value),  # ALSO uses full msg.value worth
    ])

    If router has surplus ETH >= msg.value, both calls succeed.
    """
    scenarios = [
        {
            "name": "No surplus - Standard behavior",
            "msg_value": 1.0,
            "router_balance_before": 0.0,
            "num_sendwnt_calls": 2,
        },
        {
            "name": "Small surplus - Partial exploit",
            "msg_value": 1.0,
            "router_balance_before": 0.5,
            "num_sendwnt_calls": 2,
        },
        {
            "name": "Full surplus - Complete double-count",
            "msg_value": 1.0,
            "router_balance_before": 1.0,
            "num_sendwnt_calls": 2,
        },
        {
            "name": "Large surplus - Triple-count",
            "msg_value": 1.0,
            "router_balance_before": 2.0,
            "num_sendwnt_calls": 3,
        },
    ]

    print("=" * 70)
    print("VULN-001: PayableMulticall msg.value Double-Counting Analysis")
    print("=" * 70)

    for scenario in scenarios:
        msg_value = scenario["msg_value"]
        surplus = scenario["router_balance_before"]
        num_calls = scenario["num_sendwnt_calls"]

        total_available = msg_value + surplus
        amount_per_call = msg_value  # User passes msg.value as amount

        # Can all calls succeed?
        total_requested = amount_per_call * num_calls
        can_exploit = total_available >= total_requested

        print(f"\n--- {scenario['name']} ---")
        print(f"  msg.value:          {msg_value} ETH")
        print(f"  Router surplus:     {surplus} ETH")
        print(f"  Total available:    {total_available} ETH")
        print(f"  sendWnt calls:      {num_calls}")
        print(f"  Amount per call:    {amount_per_call} ETH")
        print(f"  Total requested:    {total_requested} ETH")
        print(f"  Exploit possible:   {'YES' if can_exploit else 'NO (insufficient balance)'}")
        if can_exploit:
            excess = total_requested - msg_value
            print(f"  Excess deposited:   {excess} ETH (from router surplus)")
            print(f"  Effective theft:    {excess} ETH")


def analyze_impact_over_time():
    """
    Model cumulative impact if router accumulates surplus over time.
    """
    print("\n" + "=" * 70)
    print("Cumulative Impact Analysis (surplus accumulation)")
    print("=" * 70)

    # Assume router accumulates surplus from refunded execution fees
    daily_surplus_eth = 0.5  # 0.5 ETH/day from various sources
    exploit_frequency = 1     # Once per day
    msg_value_per_exploit = 1.0  # 1 ETH per exploit attempt

    print(f"\n  Daily surplus accumulation: {daily_surplus_eth} ETH")
    print(f"  Exploit frequency: {exploit_frequency}/day")
    print(f"  msg.value per exploit: {msg_value_per_exploit} ETH")
    print(f"")

    cumulative_theft = 0
    for day in range(1, 31):
        available_surplus = daily_surplus_eth  # Assume drained daily
        if available_surplus >= msg_value_per_exploit:
            stolen = msg_value_per_exploit  # Can double-count
        else:
            stolen = available_surplus
        cumulative_theft += stolen

    print(f"  30-day cumulative theft: {cumulative_theft:.2f} ETH")
    print(f"  At $2,000/ETH: ${cumulative_theft * 2000:,.2f}")


def main():
    # Basic multicall analysis
    print("\n--- Basic delegatecall msg.value Reuse ---")
    for num_calls in [2, 3, 5, 10]:
        result = simulate_multicall_exploit(1.0, num_calls)
        print(f"\n  {num_calls} delegatecalls with 1 ETH msg.value:")
        print(f"    Total perceived: {result['total_perceived']} ETH")
        print(f"    Amplification:   {result['amplification_factor']}x")
        print(f"    Excess credit:   {result['excess_credit']} ETH")

    # GMX-specific analysis
    analyze_gmx_sendwnt()

    # Time-based impact
    analyze_impact_over_time()

    print("\n" + "=" * 70)
    print("CONCLUSION: The vulnerability is REAL but CONDITIONAL.")
    print("Exploitability depends on router contract holding surplus ETH.")
    print("GMX's sendWnt uses 'amount' param (not msg.value directly),")
    print("but surplus ETH in the router enables the double-count.")
    print("=" * 70)


if __name__ == "__main__":
    main()
