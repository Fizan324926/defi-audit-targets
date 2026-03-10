# Second-Pass Audit: Cross-Bridge Supply Accounting

## Executive Summary

This report analyzes the dual bridge system in Olympus V3 (Legacy LayerZero + CCIP) for supply accounting vulnerabilities. The core hypothesis was that an attacker could mint unbacked OHM on L2 via the Legacy bridge and extract locked OHM on mainnet via the CCIP bridge. **The primary cross-bridge attack vector described in the hypothesis is not exploitable in the current mainnet production deployment**, but this report identifies several architectural risks and a concrete finding related to the disable-bypass pattern.

---

## 1. Architecture Analysis

### 1.1 Two Bridge Systems

**Legacy LayerZero Bridge (`CrossChainBridge.sol`)**
- Burn/mint model on BOTH sides
- On send: burns OHM on source chain
- On receive: mints new OHM on destination chain via `MINTR.increaseMintApproval()` + `MINTR.mintOhm()`
- No lock/release mechanism whatsoever
- Uses the Bophades Kernel for mint permissions

**CCIP Bridge System (two components)**
- `CCIPCrossChainBridge.sol` (periphery): User-facing bridge that transfers OHM to/from the CCIP router
- Token Pools (per-chain):
  - **Mainnet**: `LockReleaseTokenPool` (standard Chainlink contract) -- locks OHM on send, releases on receive
  - **L2 chains**: `CCIPBurnMintTokenPool` (custom Bophades policy) -- burns OHM on send, mints on receive

### 1.2 Deployment Map (from `env.json`)

| Chain | Legacy CrossChainBridge | CCIPBurnMintTokenPool | CCIPLockReleaseTokenPool | CCIPCrossChainBridge |
|---|---|---|---|---|
| **mainnet** | 0x45e5...9543a | -- | 0xa558...3aD | 0xFbf6...3D |
| **arbitrum** | 0x20B3...285c | -- | -- | -- |
| **base** | 0x6CA1...8B4c | -- | -- | -- |
| **optimism** | 0x22AE...aB4c | -- | -- | -- |
| **berachain** | 0xBA42...eA47 | -- | -- | -- |
| **base-sepolia** (test) | 0xBA42...eA47 | 0x6577...8360 | -- | 0xD28D...B3 |
| **sepolia** (test) | 0x79A0...9A | 0x3024...7de7 | 0xF166...dbc | 0xCfe7...6a5 |

**Critical observation**: On mainnet production, the CCIP bridge is configured with `"chains": ["solana"]` only. The Solana bridge uses a completely separate token system (SPL token on Solana, not EVM). The mainnet `LockReleaseTokenPool` is currently configured only for the Solana chain route.

On production L2 chains (Arbitrum, Base, Optimism, Berachain), **only the Legacy bridge is deployed** -- there is no `CCIPBurnMintTokenPool` on any production L2 chain.

---

## 2. Primary Hypothesis: Cross-Bridge OHM Theft

### 2.1 The Attack Theory

1. Attacker uses Legacy bridge to mint OHM on L2 (which just calls `MINTR.mintOhm()`)
2. Attacker bridges that OHM back to mainnet via CCIP
3. On mainnet, `LockReleaseTokenPool` releases locked OHM that was deposited by legitimate users
4. Result: attacker gets real, backed OHM; legitimate users' locked OHM is stolen

### 2.2 Why This Does NOT Work in Current Production

**The attack requires both bridge systems to be active on the same L2 chain, and both connected to mainnet.** This is NOT the case in production:

1. **No production L2 has `CCIPBurnMintTokenPool` deployed.** Arbitrum, Base, Optimism, and Berachain only have the Legacy bridge.

2. **Mainnet CCIP is configured for Solana only.** The `CCIPCrossChainBridge.chains` config on mainnet is `["solana"]`. The `LockReleaseTokenPool` on mainnet does not have chain updates for any EVM L2.

3. **Even if both existed on the same L2**, the CCIP token pool system requires the `TokenAdminRegistry` to map OHM to a specific pool. On L2, the pool would be the `CCIPBurnMintTokenPool`. The CCIP router calls `lockOrBurn` on the registered pool. For OHM to be bridged back to mainnet via CCIP, it must go through the `CCIPBurnMintTokenPool._burn()` which burns it via `MINTR.burnOhm()`. This burn would succeed on OHM minted by the Legacy bridge.

4. **On mainnet, `LockReleaseTokenPool` would need sufficient locked liquidity.** The pool only holds OHM that was locked when users bridged FROM mainnet TO the L2 via CCIP. If no one bridged via CCIP to that L2, the pool would be empty and the release would fail (insufficient balance).

### 2.3 Testnet Confirmation of Dual-Bridge Coexistence

On **base-sepolia** and **sepolia**, both bridge systems ARE deployed simultaneously. This confirms the architecture CAN support dual bridges and represents a **latent risk** if Olympus ever deploys `CCIPBurnMintTokenPool` on a production L2 that already has the Legacy bridge.

---

## 3. Finding: Legacy Bridge `_receiveMessage` Does Not Check `bridgeActive`

### 3.1 Description

In `CrossChainBridge.sol`, the `bridgeActive` flag is only checked in `sendOhm()` (line 135):

```solidity
function sendOhm(uint16 dstChainId_, address to_, uint256 amount_) external payable {
    if (!bridgeActive) revert Bridge_Deactivated();
    // ...
}
```

However, the receive path -- `lzReceive()` -> `_receiveMessage()` -- does NOT check `bridgeActive`:

```solidity
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

Similarly, `retryMessage()` (line 216-233) does not check `bridgeActive`.

### 3.2 Impact

When the bridge admin sets `bridgeActive = false` (via `setBridgeStatus(false)`), the intent is to halt all bridge operations. However:

1. **Pending messages from LayerZero still get processed**, minting new OHM on the receiving chain
2. **Failed messages can be retried** via `retryMessage()` even when the bridge is deactivated, minting OHM
3. The only way to truly stop receiving is to deactivate the policy in the Kernel (removing MINTR permissions), which is a much more drastic action

### 3.3 Severity Assessment

**Medium/Low**: This is a design issue rather than an exploitable vulnerability. The `bridgeActive` flag gives a false sense of security -- an admin thinking they've disabled the bridge may not realize incoming messages can still mint OHM. However, this requires a legitimate LayerZero message to already be in-flight or stored as a failed message, so it cannot be triggered by an external attacker without controlling the LayerZero endpoint.

The real risk materializes in an incident response scenario: if the bridge is being disabled due to a detected exploit, in-flight messages from the compromised chain can still mint OHM.

---

## 4. Finding: CCIP `retryFailedMessage` Does Not Check `isEnabled`

### 4.1 Description

In `CCIPCrossChainBridge.sol`, when a message fails to process, it is stored in `_failedMessages`. The `retryFailedMessage()` function calls `_receiveMessage()`, which DOES check `isEnabled`:

```solidity
function _receiveMessage(Client.Any2EVMMessage memory message_) internal {
    if (!isEnabled) revert NotEnabled();
    // ...
}
```

This means retrying failed messages correctly enforces the enabled check. However, there is a subtler issue:

### 4.2 The `_ccipReceive` Stores Failed Messages Even When Disabled

```solidity
function _ccipReceive(Client.Any2EVMMessage memory message_) internal override {
    try this.receiveMessage(message_) {
        // Message received successfully
    } catch {
        // Store as failed message - THIS HAPPENS WHEN DISABLED TOO
        Client.Any2EVMMessage storage failedMessage = _failedMessages[message_.messageId];
        // ...
    }
}
```

When the bridge is disabled:
1. `_ccipReceive` is called by the CCIP router
2. `this.receiveMessage()` is called, which calls `_receiveMessage()`
3. `_receiveMessage()` reverts with `NotEnabled()`
4. The catch block stores the message as a failed message
5. At this point, the OHM has ALREADY been released/minted by the token pool (on the CCIP infrastructure layer)
6. The OHM sits in the `CCIPCrossChainBridge` contract

The tokens are now in the bridge contract but not delivered to the recipient. When the bridge is re-enabled, anyone can call `retryFailedMessage()` to deliver them. **This is actually correct behavior** -- it prevents token loss. But it means disabling the bridge does NOT prevent CCIP token pool operations (lock/release or burn/mint). Those happen at the CCIP router/pool layer, before the bridge contract even receives the message.

### 4.3 Severity Assessment

**Informational**: This is expected behavior per the CCIP architecture. The bridge contract is a message handler, not a gatekeeper for the token pool. Disabling the bridge only stops the final delivery step, not the underlying lock/release or burn/mint. This is documented and by design.

---

## 5. Finding: Latent Dual-Bridge Risk in Future Deployments

### 5.1 Description

The Olympus deployment process supports both bridge systems coexisting on the same chain (proven by base-sepolia and sepolia testnets). If in the future, `CCIPBurnMintTokenPool` is deployed on a production L2 that already has an active `CrossChainBridge`:

1. Legacy bridge mints OHM on L2 (no backing requirement)
2. CCIP bridge burns that OHM on L2 and releases locked OHM from mainnet's `LockReleaseTokenPool`
3. This creates unbacked OHM on mainnet IF the locked pool has a balance from other users

### 5.2 Pre-conditions for Exploitation

All of the following must be true simultaneously:
- Legacy `CrossChainBridge` is active (policy activated in Kernel + `bridgeActive == true`) on the L2
- `CCIPBurnMintTokenPool` is active (policy activated in Kernel + `isEnabled == true`) on the same L2
- The mainnet `LockReleaseTokenPool` has the L2 chain configured as a supported chain
- The mainnet `LockReleaseTokenPool` has OHM locked (from legitimate users bridging TO the L2)
- The `TokenAdminRegistry` on the L2 has OHM mapped to the `CCIPBurnMintTokenPool`

### 5.3 Why the OHM Accounting Breaks

- **Legacy bridge model**: When OHM is sent from Chain A to Chain B, OHM is burned on A and minted on B. Total cross-chain supply is preserved.
- **CCIP bridge model**: When OHM is sent from mainnet to L2, OHM is locked on mainnet and minted on L2. The locked amount on mainnet represents the maximum that can flow back.
- **Dual bridge model (broken)**: An attacker on Chain A sends OHM via Legacy to L2 (burned on A, minted on L2). Then the attacker sends the minted OHM from L2 back to mainnet via CCIP (burned on L2, released from lock pool on mainnet). The lock pool's balance decreases, but the OHM that was released was locked by someone else who bridged via CCIP. The attacker has effectively stolen the locked OHM.

### 5.4 Severity Assessment

**Informational (currently) / Critical (if dual deployment happens)**: This is not exploitable today but would be Critical if the deployment pattern changes. The codebase has no invariant check or deployment safeguard preventing both bridges from being active on the same L2 simultaneously.

---

## 6. Analysis: Legacy Bridge Deactivation Does Not Block Retries

### 6.1 Description

`CrossChainBridge.retryMessage()` (line 216-233) allows anyone to retry a stored failed message:

```solidity
function retryMessage(
    uint16 srcChainId_,
    bytes calldata srcAddress_,
    uint64 nonce_,
    bytes calldata payload_
) public payable virtual {
    bytes32 payloadHash = failedMessages[srcChainId_][srcAddress_][nonce_];
    if (payloadHash == bytes32(0)) revert Bridge_NoStoredMessage();
    if (keccak256(payload_) != payloadHash) revert Bridge_InvalidPayload();
    failedMessages[srcChainId_][srcAddress_][nonce_] = bytes32(0);
    _receiveMessage(srcChainId_, srcAddress_, nonce_, payload_);
    emit RetryMessageSuccess(srcChainId_, srcAddress_, nonce_, payloadHash);
}
```

Neither `bridgeActive` nor any role check is enforced. If a message fails due to a transient issue (e.g., MINTR was temporarily deactivated), the message is stored. When MINTR is reactivated, anyone can retry and force the mint -- even if `bridgeActive` was set to false in the interim.

### 6.2 Severity Assessment

**Low**: Requires a failed message to already be stored. The payload is hashed, so the caller must know the exact payload (recipient + amount). Since the original message was a legitimate cross-chain transfer, the minting is expected. The issue is purely about admin control during incident response.

---

## 7. Analysis: PeripheryEnabler Bypass Check

### 7.1 Description

The `CCIPCrossChainBridge` inherits from `PeripheryEnabler`. The `enable()` and `disable()` functions are gated by `_onlyOwner()`:

```solidity
function _onlyOwner() internal view override {
    if (msg.sender != owner) revert("UNAUTHORIZED");
}
```

The `sendToEVM()` and `sendToSVM()` functions use the `onlyEnabled` modifier:

```solidity
function sendToEVM(...) external payable onlyEnabled returns (bytes32) { ... }
```

Can `onlyEnabled` be bypassed? No -- `isEnabled` is a simple boolean that can only be changed via `enable()` or `disable()`, both of which require the owner.

However, note that `retryFailedMessage()` has NO access control:
```solidity
function retryFailedMessage(bytes32 messageId_) external {
```

This is by design (anyone should be able to retry a failed delivery), but it means that when the bridge is disabled, failed messages can still be retried (since `_receiveMessage` checks `isEnabled`, retries will also fail). When re-enabled, they become retryable. This is correct behavior.

### 7.2 Verdict

No bypass found. The enable/disable mechanism works correctly for `CCIPCrossChainBridge`.

---

## 8. Summary of Findings

| # | Finding | Severity | Status |
|---|---------|----------|--------|
| 1 | Legacy bridge `_receiveMessage` does not check `bridgeActive` | Medium/Low | Confirmed - design issue |
| 2 | CCIP `_ccipReceive` stores failed messages when disabled | Informational | By design |
| 3 | Dual-bridge coexistence creates unbacked OHM risk | Informational (latent Critical) | Not exploitable in production |
| 4 | Legacy bridge `retryMessage` ignores `bridgeActive` | Low | Confirmed |
| 5 | PeripheryEnabler bypass | Not found | N/A |

---

## 9. Recommendations

1. **Add `bridgeActive` check to `_receiveMessage` in `CrossChainBridge.sol`**: The receive path should respect the deactivation flag. At minimum, log a warning; ideally, revert (the message will be stored as failed by LayerZero's `failedMessages` mechanism and can be retried later).

2. **Add access control to `retryMessage` in `CrossChainBridge.sol`**: Either require `bridgeActive == true` for retries, or gate retries behind a role check.

3. **Add deployment invariant**: When deploying `CCIPBurnMintTokenPool` to any chain, verify that no active `CrossChainBridge` exists with mint permissions on the same OHM token. This could be a deployment script check.

4. **Consider decommissioning Legacy bridges**: Since CCIP is the preferred path forward and the Legacy bridges are on chains that don't yet have CCIP, plan a migration that ensures both systems are never simultaneously active on the same L2.

5. **Document the dual-bridge risk**: Add to the deployment runbook that the `LockReleaseTokenPool` on mainnet must NEVER be configured with a remote chain that also has an active Legacy `CrossChainBridge`.

---

## 10. Files Analyzed

- `/root/immunefi/audits/olympus-v3/src/policies/CrossChainBridge.sol` - Legacy LZ bridge
- `/root/immunefi/audits/olympus-v3/src/periphery/bridge/CCIPCrossChainBridge.sol` - CCIP bridge
- `/root/immunefi/audits/olympus-v3/src/policies/bridge/CCIPBurnMintTokenPool.sol` - L2 CCIP pool
- `/root/immunefi/audits/olympus-v3/src/policies/bridge/BurnMintTokenPoolBase.sol` - Pool base
- `/root/immunefi/audits/olympus-v3/src/modules/MINTR/OlympusMinter.sol` - Minting module
- `/root/immunefi/audits/olympus-v3/src/scripts/ops/batches/CCIPTokenPool.sol` - Pool config batch
- `/root/immunefi/audits/olympus-v3/src/scripts/ops/batches/CCIPBridge.sol` - Bridge config batch
- `/root/immunefi/audits/olympus-v3/src/scripts/env.json` - Deployment addresses
- `/root/immunefi/audits/olympus-v3/src/periphery/PeripheryEnabler.sol` - Enable/disable base
- `/root/immunefi/audits/olympus-v3/src/policies/utils/PolicyEnabler.sol` - Policy enable/disable base
- `/root/immunefi/audits/olympus-v3/src/Kernel.sol` - Kernel (policy activation, permissions)
- `/root/immunefi/audits/olympus-v3/src/test/periphery/CCIPLockReleaseTokenPool.t.sol` - LR pool tests
- `/root/immunefi/audits/olympus-v3/src/test/policies/bridge/CCIPBurnMintTokenPoolFork.t.sol` - Fork tests
- `/root/immunefi/audits/olympus-v3/src/proposals/CCIPBridgeSolana.sol` - Solana CCIP proposal
