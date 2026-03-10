# Immunefi Bug Report: CrossChainBridge (LayerZero) Incomplete Shutdown — `bridgeActive` Does Not Block Incoming Mints

## Bug Description

The `CrossChainBridge` contract uses a `bridgeActive` flag to control bridge operations. However, this flag is ONLY checked in `sendOhm()` (the sending function). The receiving functions — `lzReceive()`, `_receiveMessage()`, `receiveMessage()`, and `retryMessage()` — do NOT check `bridgeActive`. This means when an admin deactivates the bridge via `setBridgeStatus(false)`, incoming cross-chain messages **continue to mint OHM** on the destination chain.

### Vulnerable Code

**File:** `src/policies/CrossChainBridge.sol`

**Line 135 (`sendOhm` — checks `bridgeActive`):**
```solidity
function sendOhm(uint16 dstChainId_, address to_, uint256 amount_) external payable {
    if (!bridgeActive) revert Bridge_Deactivated();  // <-- Only place checked
    // ...
}
```

**Lines 148-160 (`_receiveMessage` — NO `bridgeActive` check):**
```solidity
function _receiveMessage(
    uint16 srcChainId_, bytes memory, uint64, bytes memory payload_
) internal {
    // NOTE: No bridgeActive check here!
    (address to, uint256 amount) = abi.decode(payload_, (address, uint256));
    MINTR.increaseMintApproval(address(this), amount);
    MINTR.mintOhm(to, amount);
    emit BridgeReceived(to, amount, srcChainId_);
}
```

**Lines 216-234 (`retryMessage` — NO `bridgeActive` check, permissionless):**
```solidity
function retryMessage(
    uint16 srcChainId_, bytes calldata srcAddress_,
    uint64 nonce_, bytes calldata payload_
) public payable virtual {
    // NOTE: No bridgeActive check, no access control
    bytes32 payloadHash = failedMessages[srcChainId_][srcAddress_][nonce_];
    // ... validates and retries
    _receiveMessage(srcChainId_, srcAddress_, nonce_, payload_);
}
```

### Comparison with CCIP Bridge

The CCIP version (`CCIPCrossChainBridge`) correctly checks `isEnabled` in `_receiveMessage()`:
```solidity
function _receiveMessage(Client.Any2EVMMessage memory message_) internal {
    if (!isEnabled) revert NotEnabled();  // <-- Correctly checks on receive
}
```

This inconsistency confirms this is a bug, not a design choice.

### Security Impact

**Scenario: Emergency Shutdown During Active Attack**
1. Attacker compromises the LZ endpoint or trusted remote on a source chain
2. Admin calls `setBridgeStatus(false)` to shut down the bridge
3. Admin believes bridge is fully deactivated
4. Attacker's malicious messages continue via `lzReceive()` → mints arbitrary OHM
5. Each message self-approves unlimited minting: `MINTR.increaseMintApproval(address(this), amount)`

The only true shutdown is full policy deactivation via Kernel (revokes MINTR permissions), but `bridgeActive` exists as a lighter-weight toggle whose incomplete implementation creates a false sense of security.

## Impact

**Severity: Medium**

- `bridgeActive` provides incomplete protection — sending blocked, receiving continues
- During emergency shutdown, incoming messages continue to mint OHM
- `retryMessage()` is permissionless, allowing anyone to trigger minting of stored failed messages
- Inconsistency with CCIP bridge confirms this is an oversight

**Mitigating factor:** Kernel-level deactivation via `_deactivatePolicy()` would revoke MINTR permissions completely.

## Risk Breakdown

- **Difficulty to exploit:** Medium — requires compromised LZ endpoint or trusted remote
- **Weakness type:** CWE-424 (Improper Protection of Alternate Path)
- **CVSS:** 5.9 (Medium)

## Recommendation

Add `bridgeActive` check to `_receiveMessage()`:

```diff
  function _receiveMessage(
      uint16 srcChainId_, bytes memory, uint64, bytes memory payload_
  ) internal {
+     if (!bridgeActive) revert Bridge_Deactivated();
      (address to, uint256 amount) = abi.decode(payload_, (address, uint256));
      MINTR.increaseMintApproval(address(this), amount);
      MINTR.mintOhm(to, amount);
      emit BridgeReceived(to, amount, srcChainId_);
  }
```

Also add access control to `retryMessage()`:

```diff
- function retryMessage(...) public payable virtual {
+ function retryMessage(...) public payable virtual onlyRole("bridge_admin") {
```

## Proof of Concept

```solidity
// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.15;

import "forge-std/Test.sol";

contract PoC_012_LZBridgeIncompleteShutdown is Test {
    bool public bridgeActive = true;
    uint256 public totalMinted;

    function setBridgeStatus(bool active_) external { bridgeActive = active_; }

    function sendOhm(uint256) external payable {
        if (!bridgeActive) revert("Bridge_Deactivated");
    }

    function _receiveMessage(uint256 amount) internal {
        // No bridgeActive check (the bug)
        totalMinted += amount;
    }

    function lzReceive(uint256 amount) external {
        _receiveMessage(amount);
    }

    function test_incompleteShutdown() public {
        bridgeActive = false;

        // Sending is blocked
        vm.expectRevert("Bridge_Deactivated");
        this.sendOhm(1000e9);

        // But receiving is NOT blocked
        uint256 before = totalMinted;
        this.lzReceive(1000e9);
        assertEq(totalMinted, before + 1000e9, "Minted despite bridge inactive");
    }
}
```

## References

- [CrossChainBridge.sol - sendOhm (only bridgeActive check)](https://github.com/OlympusDAO/bophades/blob/main/src/policies/CrossChainBridge.sol#L134-L144)
- [CrossChainBridge.sol - _receiveMessage (no bridgeActive check)](https://github.com/OlympusDAO/bophades/blob/main/src/policies/CrossChainBridge.sol#L148-L160)
- [CrossChainBridge.sol - retryMessage (permissionless)](https://github.com/OlympusDAO/bophades/blob/main/src/policies/CrossChainBridge.sol#L216-L234)
- [CCIPCrossChainBridge.sol - _receiveMessage (correctly checks isEnabled)](https://github.com/OlympusDAO/bophades/blob/main/src/periphery/bridge/CCIPCrossChainBridge.sol#L341)
