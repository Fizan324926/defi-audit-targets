# FP-004: SEND_AND_CALL Compose Reentrancy

## Classification: FALSE POSITIVE

## Location
- `/root/defi-audit-targets/audits/layerzero/LayerZero-v2/packages/layerzero-v2/evm/oapp/contracts/oft/OFTCore.sol` lines 240-271
- `/root/defi-audit-targets/audits/layerzero/LayerZero-v2/packages/layerzero-v2/evm/protocol/contracts/MessagingComposer.sol` lines 23-58

## Hypothesis
SEND_AND_CALL messages trigger compose execution that could re-enter the OFT and double-mint tokens.

## Why Not Exploitable

### Two-Phase Compose Architecture
The compose flow is deliberately split into two separate transactions:

**Phase 1 (during lzReceive):**
```solidity
// OFTCore._lzReceive():
uint256 amountReceivedLD = _credit(toAddress, _toLD(_message.amountSD()), _origin.srcEid);
// Tokens are ALREADY minted/unlocked
endpoint.sendCompose(toAddress, _guid, 0, composeMsg);
// sendCompose() only writes to storage - NO external call
```

**Phase 2 (separate transaction, called by executor):**
```solidity
// MessagingComposer.lzCompose():
composeQueue[_from][_to][_guid][_index] = RECEIVED_MESSAGE_HASH; // Mark BEFORE call
ILayerZeroComposer(_to).lzCompose{...}(...);                      // External call AFTER mark
```

### Protection Chain
1. `sendCompose()` only writes a hash to `composeQueue` -- no external call, no reentrancy vector.
2. `lzCompose()` is a separate transaction, not callable during `lzReceive`.
3. `lzCompose()` sets `RECEIVED_MESSAGE_HASH` BEFORE the external call (check-effect-interaction).
4. `lzCompose()` verifies `keccak256(_message) == composeQueue[...]` -- replay impossible.
5. The endpoint's `lzReceive()` calls `_clearPayload()` first, deleting the payload hash, preventing `lzReceive` replay.

### Conclusion
Even if a malicious composer tries to callback during `lzCompose`, it cannot trigger another `lzReceive` (would need endpoint to call it, which requires a new verified message).
