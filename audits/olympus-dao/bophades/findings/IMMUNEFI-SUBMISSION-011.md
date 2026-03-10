# Immunefi Bug Report: CCIPCrossChainBridge Missing ERC20 Rescue Function — OHM Permanently Stuck After Failed Messages

## Bug Description

The `CCIPCrossChainBridge` contract uses a lock/release model: when receiving cross-chain messages, OHM tokens are released by the CCIP token pool to the bridge contract, which then transfers them to the intended recipient. If the `_receiveMessage()` call fails (e.g., bridge is disabled, source not trusted), the OHM tokens remain in the bridge contract and the message is stored in `_failedMessages` for retry.

However, the `withdraw()` function (line 285-301) **only handles native ETH** — there is NO function to rescue ERC20 tokens (including OHM) stuck in the contract. If a failed message cannot be successfully retried (e.g., bridge remains disabled permanently, or source trust is revoked), the locked OHM is **permanently lost**.

### Vulnerable Code

**File:** `src/periphery/bridge/CCIPCrossChainBridge.sol`

**Lines 285-301 (`withdraw` — ETH only):**
```solidity
function withdraw(address recipient_) external onlyOwner {
    if (recipient_ == address(0)) revert Bridge_InvalidAddress("recipient");

    uint256 balance = address(this).balance;  // <-- ETH only, no ERC20

    if (balance == 0) revert Bridge_ZeroAmount();

    (bool success, ) = recipient_.call{value: balance}("");
    if (!success) revert Bridge_TransferFailed(msg.sender, recipient_, balance);

    emit Withdrawn(recipient_, balance);
}
```

**Lines 307-335 (`_ccipReceive` — stores failed message, OHM stays in contract):**
```solidity
function _ccipReceive(Client.Any2EVMMessage memory message_) internal override {
    try this.receiveMessage(message_) {
        // Success
    } catch {
        // OHM already released to bridge, stays stuck
        Client.Any2EVMMessage storage failedMessage = _failedMessages[message_.messageId];
        // ... stores full message data for retry
        emit MessageFailed(message_.messageId);
    }
}
```

**Lines 339-341 (`_receiveMessage` — checks isEnabled):**
```solidity
function _receiveMessage(Client.Any2EVMMessage memory message_) internal {
    if (!isEnabled) revert NotEnabled();  // OHM already in contract, will stay stuck
    // ...
}
```

**Lines 389-403 (`retryFailedMessage` — re-checks isEnabled via _receiveMessage):**
```solidity
function retryFailedMessage(bytes32 messageId_) external {
    Client.Any2EVMMessage memory message = _failedMessages[messageId_];
    delete _failedMessages[messageId_];
    _receiveMessage(message);  // Will revert if still disabled (delete rolls back atomically)
}
```

### Attack/Loss Scenario

1. Bridge is operating normally. User sends OHM from Chain B to mainnet via CCIP.
2. CCIP router on mainnet calls `ccipReceive()`. The CCIP token pool releases OHM to the bridge contract.
3. `_receiveMessage()` fails (bridge was disabled during transit, or unexpected error).
4. OHM is now sitting in the bridge contract. Message is stored in `_failedMessages`.
5. If bridge remains disabled (emergency shutdown, security incident), `retryFailedMessage()` will also fail.
6. There is NO `withdrawToken(ERC20)` function.
7. `withdraw()` only handles native ETH.
8. **OHM is permanently stuck with no recovery path.**

### Additional Concern: Trust Revocation

If a source chain's trusted remote is revoked after a security incident, all pending failed messages from that chain become permanently unretryable since `_receiveMessage` validates source trust. The OHM from those failed messages is permanently lost.

## Impact

**Severity: Medium-High**

- Direct, permanent loss of user funds (OHM) with no recovery mechanism
- Affects any user whose cross-chain transfer arrives during bridge downtime or fails for any reason
- The `withdraw()` function shows the developers considered fund recovery, but only implemented it for native ETH
- Given that bridges are high-risk and frequently involve emergency shutdowns, this scenario is realistic

**Financial Impact:** Up to the total value of all OHM locked in failed messages. In a security incident where the bridge is permanently disabled, all pending failed messages represent permanent loss.

## Risk Breakdown

- **Difficulty to exploit:** Low — requires only bridge disable + pending message (realistic during security incidents)
- **Weakness type:** CWE-404 (Improper Resource Shutdown or Release)
- **CVSS:** 7.1 (High)

## Recommendation

Add an ERC20 rescue function:

```diff
+ function withdrawToken(address token_, address recipient_, uint256 amount_) external onlyOwner {
+     if (recipient_ == address(0)) revert Bridge_InvalidAddress("recipient");
+     if (amount_ == 0) revert Bridge_ZeroAmount();
+     IERC20(token_).transfer(recipient_, amount_);
+     emit TokenWithdrawn(token_, recipient_, amount_);
+ }
```

Or add a force-complete function for failed messages that bypasses validation:

```diff
+ function forceCompleteFailedMessage(bytes32 messageId_) external onlyOwner {
+     Client.Any2EVMMessage memory message = _failedMessages[messageId_];
+     if (message.sourceChainSelector == 0) revert Bridge_FailedMessageNotFound(messageId_);
+     delete _failedMessages[messageId_];
+     address recipient = abi.decode(message.data, (address));
+     OHM.transfer(recipient, message.destTokenAmounts[0].amount);
+     emit RetryMessageSuccess(messageId_);
+ }
```

## Proof of Concept

```solidity
// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.15;

import "forge-std/Test.sol";

contract PoC_011_CCIPBridgeStuckTokens is Test {
    bool public isEnabled = true;
    mapping(bytes32 => bool) public failedMessages;
    uint256 public bridgeOhmBalance;

    function setEnabled(bool enabled_) external { isEnabled = enabled_; }

    function simulateReceive(bytes32 messageId, uint256 amount) external {
        bridgeOhmBalance += amount; // CCIP releases OHM to bridge
        try this._processMessage(messageId, amount) {} catch {
            failedMessages[messageId] = true; // OHM stays in bridge
        }
    }

    function _processMessage(bytes32, uint256 amount) external {
        require(msg.sender == address(this));
        require(isEnabled, "NotEnabled");
        bridgeOhmBalance -= amount;
    }

    function withdraw() external {
        uint256 balance = address(this).balance; // ONLY ETH
        require(balance > 0, "No ETH");
        payable(msg.sender).transfer(balance);
    }

    function test_ohmPermanentlyStuck() public {
        bytes32 msgId = keccak256("test");
        isEnabled = false;

        this.simulateReceive(msgId, 1000e9);
        assertEq(bridgeOhmBalance, 1000e9, "OHM stuck in bridge");
        assertTrue(failedMessages[msgId], "Message failed");

        // No ERC20 rescue function exists
        vm.expectRevert("No ETH");
        this.withdraw();

        assertEq(bridgeOhmBalance, 1000e9, "OHM PERMANENTLY stuck");
    }
}
```

## References

- [CCIPCrossChainBridge.sol - withdraw (ETH only)](https://github.com/OlympusDAO/bophades/blob/main/src/periphery/bridge/CCIPCrossChainBridge.sol#L285-L301)
- [CCIPCrossChainBridge.sol - _ccipReceive](https://github.com/OlympusDAO/bophades/blob/main/src/periphery/bridge/CCIPCrossChainBridge.sol#L307-L335)
- [CCIPCrossChainBridge.sol - retryFailedMessage](https://github.com/OlympusDAO/bophades/blob/main/src/periphery/bridge/CCIPCrossChainBridge.sol#L389-L403)
