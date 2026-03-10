# Olympus V3 Cross-Chain Bridge Security Audit Report

**Scope**: CrossChainBridge (LayerZero), CCIPCrossChainBridge, CCIPBurnMintTokenPool, BurnMintTokenPoolBase, MINTR module, and supporting contracts.

**Auditor**: Smart Contract Security Agent
**Date**: 2026-03-01
**Program**: Olympus V3 Immunefi Bug Bounty ($3.33M max)

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Findings Summary](#findings-summary)
3. [Detailed Findings](#detailed-findings)
4. [Areas Analyzed With No Issues Found](#areas-analyzed-with-no-issues-found)

---

## Architecture Overview

Olympus V3 has **two distinct bridge systems**:

### 1. Legacy LayerZero Bridge (`CrossChainBridge.sol`)
- Burns OHM on source chain via `MINTR.burnOhm()`
- Mints OHM on destination chain via `MINTR.increaseMintApproval()` + `MINTR.mintOhm()`
- Uses LayerZero endpoints for cross-chain messaging
- Protected by trusted remote validation + bridge_admin role

### 2. CCIP Bridge (New System)
Two sub-components:

**a) `CCIPCrossChainBridge.sol` (Periphery - on all chains)**
- Intermediary contract for EVM-to-EVM bridging
- Does NOT mint/burn -- it transfers OHM to/from the CCIP router
- On receive: validates trusted remote, then transfers OHM from contract balance to recipient
- On send: pulls OHM from sender, approves router, sends via CCIP

**b) `CCIPBurnMintTokenPool.sol` (Policy - on non-canonical chains only)**
- Called by CCIP OffRamp/OnRamp infrastructure (not by users directly)
- Burns OHM via MINTR on outbound (source) and mints OHM via MINTR on inbound (destination)
- On canonical chain (mainnet): a standard `LockReleaseTokenPool` (from Chainlink library) is used instead -- it locks/releases OHM without minting

**Minting Module (`OlympusMinter.sol`)**
- All minting goes through `mintOhm()` which requires: (1) caller is a permissioned policy, (2) caller has sufficient `mintApproval`, (3) module is active
- `increaseMintApproval()` also requires permissioned caller
- The bridge policies (CrossChainBridge, CCIPBurnMintTokenPool) both request permissions for `mintOhm`, `burnOhm`, and `increaseMintApproval`

---

## Findings Summary

| # | Title | Severity | Status |
|---|-------|----------|--------|
| 1 | [Legacy Bridge: No Rate Limiting on Minting via `_receiveMessage`](#finding-1) | Medium | Confirmed |
| 2 | [Legacy Bridge: `retryMessage` Callable by Anyone -- Potential Timing/Front-Running Issues](#finding-2) | Low | Confirmed |
| 3 | [CCIPBurnMintTokenPool: Unbounded Mint Approval on Non-Canonical Chains](#finding-3) | Informational | Confirmed |
| 4 | [CCIP Bridge: Rate Limiter Disabled by Default in Token Pool Configuration](#finding-4) | Informational | Confirmed |
| 5 | [CCIPCrossChainBridge: `_receiveMessage` Does Not Validate Recipient Is Not Zero Address](#finding-5) | Low | Confirmed |
| 6 | [Legacy Bridge: Dual Bridge Systems Create Supply Accounting Complexity](#finding-6) | Informational | Confirmed |

---

## Detailed Findings

---

### Finding 1: Legacy Bridge: No Rate Limiting on Minting via `_receiveMessage` {#finding-1}

**Severity**: Medium
**File**: `/root/immunefi/audits/olympus-v3/src/policies/CrossChainBridge.sol`, lines 148-160
**File**: `/root/immunefi/audits/olympus-v3/src/modules/MINTR/OlympusMinter.sol`, lines 34-47, 62-68

**Description**:

The legacy `CrossChainBridge._receiveMessage()` function mints unlimited OHM on the destination chain by calling `MINTR.increaseMintApproval()` followed by `MINTR.mintOhm()`:

```solidity
// CrossChainBridge.sol, lines 148-160
function _receiveMessage(
    uint16 srcChainId_,
    bytes memory,
    uint64,
    bytes memory payload_
) internal {
    (address to, uint256 amount) = abi.decode(payload_, (address, uint256));

    MINTR.increaseMintApproval(address(this), amount);
    MINTR.mintOhm(to, amount);

    emit BridgeReceived(to, amount, srcChainId_);
}
```

The bridge increases its own mint approval by the exact amount needed, then immediately mints. There is **no rate limit**, **no maximum bridge amount per transaction**, and **no cooldown**. The only guard is that the message must originate from a trusted remote via the LayerZero endpoint.

In `OlympusMinter.increaseMintApproval()` (line 62-68):
```solidity
function increaseMintApproval(address policy_, uint256 amount_) external override permissioned {
    uint256 approval = mintApproval[policy_];
    uint256 newAmount = type(uint256).max - approval <= amount_
        ? type(uint256).max
        : approval + amount_;
    mintApproval[policy_] = newAmount;
}
```

The approval can be increased to `type(uint256).max` without any cap. This is a permissioned function, but the bridge policy itself calls it on every received message.

**Contrast with the CCIP system**: The newer CCIP system uses Chainlink's `TokenPool` which has built-in rate limiters (configurable via `RateLimiter.Config`). The legacy bridge has no such mechanism.

**Attack Scenario**:

If the LayerZero endpoint is compromised, or a trusted remote is misconfigured/compromised on a remote chain:
1. Attacker sends a forged message through the LayerZero endpoint with an arbitrary `amount` (e.g., 1 billion OHM).
2. The bridge calls `MINTR.increaseMintApproval(address(this), 1_000_000_000e9)`.
3. The bridge calls `MINTR.mintOhm(attacker, 1_000_000_000e9)`.
4. Unlimited OHM is minted in a single transaction.

With the CCIP pool, rate limiters would cap the damage. The legacy bridge provides no such protection.

**Impact**: If the LayerZero infrastructure or a trusted remote on any connected chain is compromised, unlimited OHM can be minted in a single transaction. The lack of rate limiting means there is no damage cap. However, this requires compromising the LayerZero trusted path, which is an external dependency.

**Note**: This is a design concern rather than a direct code vulnerability. The trusted remote mechanism is the primary security control. However, defense-in-depth would suggest having rate limits as a secondary control, which the legacy bridge lacks. The newer CCIP bridge correctly addresses this with configurable rate limiters.

**PoC Feasibility**: Yes -- a Foundry test could demonstrate that a single message can mint an arbitrary amount. However, triggering this in production requires compromising the LayerZero endpoint or a trusted remote, which is out of scope per program rules (third-party oracle/messaging issues).

---

### Finding 2: Legacy Bridge: `retryMessage` Callable by Anyone {#finding-2}

**Severity**: Low
**File**: `/root/immunefi/audits/olympus-v3/src/policies/CrossChainBridge.sol`, lines 216-234

**Description**:

The `retryMessage()` function has no access control -- it is callable by anyone:

```solidity
// Lines 216-234
function retryMessage(
    uint16 srcChainId_,
    bytes calldata srcAddress_,
    uint64 nonce_,
    bytes calldata payload_
) public payable virtual {
    // Assert there is message to retry
    bytes32 payloadHash = failedMessages[srcChainId_][srcAddress_][nonce_];
    if (payloadHash == bytes32(0)) revert Bridge_NoStoredMessage();
    if (keccak256(payload_) != payloadHash) revert Bridge_InvalidPayload();

    // Clear the stored message
    failedMessages[srcChainId_][srcAddress_][nonce_] = bytes32(0);

    // Execute the message. revert if it fails again
    _receiveMessage(srcChainId_, srcAddress_, nonce_, payload_);

    emit RetryMessageSuccess(srcChainId_, srcAddress_, nonce_, payloadHash);
}
```

While the payload must match the stored hash (so the caller cannot change the amount or recipient), anyone can trigger the retry. The failed message details (srcChainId, srcAddress, nonce) are emitted in the `MessageFailed` event, and the payload is also emitted. An attacker can thus front-run the intended retry or trigger retries at inconvenient times.

The payload integrity is preserved (the hash check is correct), so this cannot be used to alter amounts or recipients. But it does allow anyone to force minting of OHM that was in a failed state. If a message intentionally failed and the admin wanted to use `forceResumeReceive()` instead, a front-runner could call `retryMessage()` first.

**Impact**: Low. The retry will execute the original intended mint to the original intended recipient. No fund theft is possible. The main concern is that a griefing actor can trigger mints before the admin decides whether to retry or force-resume.

**PoC Feasibility**: Yes -- straightforward to demonstrate in a Foundry test.

---

### Finding 3: CCIPBurnMintTokenPool: Unbounded Mint Approval on Non-Canonical Chains {#finding-3}

**Severity**: Informational
**File**: `/root/immunefi/audits/olympus-v3/src/policies/bridge/CCIPBurnMintTokenPool.sol`, lines 114-122

**Description**:

The `_mint()` function in `CCIPBurnMintTokenPool` increases the mint approval by the exact amount needed before minting:

```solidity
// Lines 114-122
function _mint(address receiver_, uint256 amount_) internal override onlyEnabled {
    // Increment the mint approval
    // Although this permits infinite minting on the non-mainnet chain, it would not be possible to bridge back to mainnet due to checks on that side of the bridge
    MINTR.increaseMintApproval(address(this), amount_);

    // Mint to the receiver
    // Will revert if amount is 0
    MINTR.mintOhm(receiver_, amount_);
}
```

The code comment explicitly acknowledges that this "permits infinite minting on the non-mainnet chain." The design rationale is that the mainnet `LockReleaseTokenPool` provides a hard cap: only as much OHM can be bridged back as was locked in the pool. This is a sound economic invariant.

However, on the non-canonical chain itself, OHM supply is effectively unbounded by the bridge. The only protection is that `releaseOrMint()` can only be called by the CCIP OffRamp (validated in `TokenPool._validateReleaseOrMint()`), and that the OffRamp only processes legitimate CCIP messages.

This is an accepted design trade-off, well-documented in the code.

**Impact**: Informational. The design is intentional. The mainnet lock/release pool provides the economic security boundary. Even if unlimited OHM were minted on an L2, bridging it back to mainnet is capped by the locked liquidity.

---

### Finding 4: CCIP Bridge: Rate Limiter Disabled by Default in Token Pool Configuration {#finding-4}

**Severity**: Informational
**File**: `/root/immunefi/audits/olympus-v3/src/scripts/ops/batches/CCIPTokenPool.sol`, lines 61-63

**Description**:

The deployment scripts configure the token pool rate limiter as **disabled by default**:

```solidity
// Lines 61-63
function _getRateLimiterConfigDefault() internal pure returns (RateLimiter.Config memory) {
    return RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0});
}
```

While an emergency shutdown function exists (lines 490-509) that enables a very restrictive rate limiter:

```solidity
function _getRateLimiterConfigEmergencyShutdown() internal pure returns (RateLimiter.Config memory) {
    return RateLimiter.Config({isEnabled: true, capacity: 2, rate: 1});
}
```

The fact that rate limiting is disabled by default means the CCIP token pool relies entirely on CCIP's own message validation for security. If the rate limiter were enabled with reasonable bounds, it would serve as a secondary defense against any compromise of the CCIP messaging layer.

**Impact**: Informational. This is a design choice. The Chainlink CCIP infrastructure provides its own security guarantees. However, enabling rate limiters would provide defense-in-depth.

---

### Finding 5: CCIPCrossChainBridge: `_receiveMessage` Does Not Validate Recipient Is Not Zero Address {#finding-5}

**Severity**: Low
**File**: `/root/immunefi/audits/olympus-v3/src/periphery/bridge/CCIPCrossChainBridge.sol`, lines 339-370

**Description**:

When receiving a message in `_receiveMessage()`, the recipient address is decoded from the message data:

```solidity
// Line 358
address recipient = abi.decode(message_.data, (address));

// Line 361
OHM.transfer(recipient, message_.destTokenAmounts[0].amount);
```

There is no validation that `recipient != address(0)`. While the sending side (`_getEVMData()`, line 119) validates `to_ == address(0)`, a failed-then-retried message or a message from a compromised trusted remote could contain a zero address recipient.

The OHM token's `_transfer()` function (from `OlympusERC20.sol`, line 738-739) does check:
```solidity
require(sender != address(0), "ERC20: transfer from the zero address");
require(recipient != address(0), "ERC20: transfer to the zero address");
```

So the transfer to `address(0)` would revert, causing the message to be stored as a failed message. The OHM would remain in the bridge contract. However, the failed message can never be retried successfully (it will always revert), effectively locking the OHM in the bridge contract permanently.

**Attack Scenario**:

1. A message arrives with `data = abi.encode(address(0))` (from a compromised trusted remote or edge case).
2. `_receiveMessage` decodes `recipient = address(0)`.
3. `OHM.transfer(address(0), amount)` reverts.
4. The message is stored as failed in `_failedMessages`.
5. `retryFailedMessage()` is called, but it will always revert.
6. The OHM tokens (already minted/released by the TokenPool to the bridge contract) are permanently locked.

**Impact**: Low. This requires a compromised trusted remote to send a message with zero-address data. The OHM would be locked but not stolen. On the send side, the validation prevents legitimate users from triggering this.

**PoC Feasibility**: Yes -- a Foundry test simulating a CCIP message with zero-address data.

---

### Finding 6: Legacy Bridge: Dual Bridge Systems Create Supply Accounting Complexity {#finding-6}

**Severity**: Informational

**Description**:

The codebase contains two independent bridge systems:

1. **Legacy LayerZero Bridge** (`CrossChainBridge.sol`): Burns and mints OHM directly via MINTR. No lock/release mechanism. No global supply cap.
2. **CCIP Bridge** (`CCIPCrossChainBridge.sol` + `CCIPBurnMintTokenPool.sol`): Uses lock/release on mainnet and burn/mint on non-canonical chains. Has inherent supply cap via locked liquidity.

Both systems can be active simultaneously. The legacy bridge's burn-mint model means OHM can be minted on non-canonical chains via the LayerZero bridge without any corresponding lock on mainnet. This OHM could then be bridged back to mainnet via the CCIP bridge's lock/release pool, potentially draining locked liquidity that was deposited by CCIP bridge users.

However, this requires the legacy bridge to be active on the non-canonical chain with trusted remotes configured, and the CCIP bridge to also be configured for the same chain pair. The deployment scripts suggest these are managed carefully.

**Impact**: Informational. Cross-system supply inconsistency is a design complexity. If the legacy bridge is decommissioned (all trusted remotes removed, bridge deactivated), this concern is eliminated.

---

## Areas Analyzed With No Issues Found

### 1. Mint-Without-Burn (Primary Concern)

**Legacy Bridge**: Burn occurs first (`MINTR.burnOhm(msg.sender, amount_)` on line 140 of `CrossChainBridge.sol`), then the message is sent. On receive, mint occurs. If the LayerZero message fails, the failed message mechanism allows retry but NOT double-mint (the nonce-based storage is cleared on retry). The burn-then-send ordering is correct.

**CCIP Bridge**: On the send side, OHM is transferred from the sender to the router (which routes to the TokenPool). The TokenPool either locks (mainnet) or burns (non-canonical) the OHM. On the receive side, the destination TokenPool mints (non-canonical) or releases (mainnet) OHM. The CCIP infrastructure ensures atomicity of the message delivery. The bridge contract only handles the intermediary transfer.

**Verdict**: No mint-without-burn vulnerability found. Both systems correctly enforce burn/lock before send.

### 2. Double-Spend / Message Replay

**Legacy Bridge**: The `failedMessages` mapping uses `[srcChainId][srcAddress][nonce]` as the key. The nonce is unique per message from LayerZero. On retry, the entry is cleared (`failedMessages[srcChainId_][srcAddress_][nonce_] = bytes32(0)`). A second retry for the same nonce will hit `Bridge_NoStoredMessage()`. The `lzReceive` function stores failed messages by nonce, and the internal call to `_receiveMessage` is done via `address(this).call(...)` which processes the message. If it succeeds in `lzReceive`, no failed message is stored. If it fails, the hash is stored exactly once.

**CCIP Bridge**: The `_failedMessages` mapping uses `messageId` as the key (unique per CCIP message). On retry, `delete _failedMessages[messageId_]` clears the entry. A second retry will hit `Bridge_FailedMessageNotFound`.

**Verdict**: No double-spend possible. Both systems correctly clear stored messages on successful retry.

### 3. Message Forgery

**Legacy Bridge**: `lzReceive()` validates `msg.sender == address(lzEndpoint)` (line 172) and checks `srcAddress_` against `trustedRemoteLookup[srcChainId_]` (lines 176-181). Both checks are necessary and sufficient to prevent forgery, assuming the LayerZero endpoint is secure.

**CCIP Bridge**: `ccipReceive()` (inherited from `CCIPReceiver`) validates `msg.sender == i_ccipRouter`. Then `_receiveMessage()` validates the source bridge address against `_trustedRemoteEVM` (lines 347-349). For the TokenPool, `_validateReleaseOrMint()` validates the caller is an authorized OffRamp.

**Verdict**: No message forgery vulnerability found. Both systems properly validate message sources.

### 4. Access Control on Minting

**MINTR Module**: `mintOhm()` requires (1) `permissioned` modifier (caller must be an activated policy with the `mintOhm.selector` permission), (2) `onlyWhileActive` modifier, (3) sufficient `mintApproval[msg.sender]`. The `increaseMintApproval()` function also requires `permissioned` access.

The bridge policies request exactly three permissions: `mintOhm`, `burnOhm`, `increaseMintApproval`. These are granted by the Kernel when the policy is activated. No external caller can directly call MINTR to mint OHM without being a registered, permissioned policy.

**Verdict**: MINTR access control is sound. Only registered policies can mint, and they must have sufficient approval.

### 5. Chain ID Confusion

**Legacy Bridge**: Uses LayerZero's `uint16` chain IDs. Trusted remotes are configured per chain ID. The `trustedRemoteLookup` maps chain IDs to expected remote addresses. A message from chain A cannot be mistaken for chain B because the LayerZero endpoint tags messages with the correct source chain ID.

**CCIP Bridge**: Uses `uint64` chain selectors. Trusted remotes are configured per chain selector. The CCIP infrastructure ensures chain selector integrity.

**Verdict**: No chain ID confusion vulnerability found.

### 6. Token Pool Imbalance

The mainnet `LockReleaseTokenPool` locks OHM when bridging out and releases OHM when bridging in. The non-canonical `CCIPBurnMintTokenPool` burns on outbound and mints on inbound. Under normal operation, the locked amount on mainnet always equals the total minted on all non-canonical chains. The CCIP infrastructure ensures this invariant.

**Verdict**: No pool imbalance vulnerability found under normal operation. (The dual-bridge system noted in Finding 6 is a theoretical concern.)

### 7. `receiveMessage` Access Control

**Legacy Bridge**: `receiveMessage()` (the public wrapper) checks `msg.sender != address(this)` (line 211). It can only be called via the `address(this).call(...)` in `lzReceive()`. External callers are rejected.

**CCIP Bridge**: `receiveMessage()` checks `msg.sender != address(this)` (line 376). It can only be called via `this.receiveMessage(message_)` in `_ccipReceive()`.

**Verdict**: Access control is correct on both internal message receivers.

### 8. OHM Approval Handling in CCIP Bridge

In `CCIPCrossChainBridge._sendOhm()`:
```solidity
OHM.transferFrom(msg.sender, address(this), amount_);
OHM.approve(address(i_ccipRouter), amount_);
```

The bridge approves exactly the amount needed for each send. No stale approvals accumulate. This is safe.

In `CCIPBurnMintTokenPool._burn()`:
```solidity
i_token.approve(address(MINTR), amount_);
MINTR.burnOhm(address(this), amount_);
```

Same pattern -- approve exactly what's needed.

**Verdict**: No approval-related vulnerabilities found.

### 9. Excess Native Token Handling

`CCIPCrossChainBridge._sendOhm()` checks `msg.value < fees` and reverts if insufficient. If `msg.value > fees`, the excess is **not** returned to the sender. A `withdraw()` function (lines 285-301) exists for the owner to sweep excess ETH. The code comments explain this design choice: "Sending the excess native token to the sender can create problems if the sender cannot receive it."

**Verdict**: This is a documented design choice, not a vulnerability. Users should use `getFeeEVM()`/`getFeeSVM()` to determine exact fees before sending.

---

## Conclusion

The Olympus V3 cross-chain bridge infrastructure is well-designed with layered security controls. The CCIP bridge system is particularly robust, leveraging Chainlink's battle-tested infrastructure with additional trusted remote validation and enable/disable mechanisms.

The most notable concern is the legacy LayerZero bridge's lack of rate limiting (Finding 1), which creates a larger blast radius in the event of a LayerZero compromise compared to the CCIP system. However, this requires compromising a third-party messaging protocol, which is out of scope per the program rules.

No critical or high-severity vulnerabilities were identified that would allow unauthorized minting, double-spending, or fund theft through the bridge contracts alone.

**Key Security Properties Verified**:
- Burn/lock always happens before cross-chain message send
- Message replay is prevented by nonce/messageId-based storage
- Message forgery is prevented by endpoint/router + trusted remote validation
- MINTR access control prevents unauthorized minting
- Token pool economics are balanced (lock/release on mainnet, burn/mint on L2)
- Enable/disable mechanisms provide emergency shutdown capability
