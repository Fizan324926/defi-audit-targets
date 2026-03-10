# False Positive: L1TokenGateway.finalizeInboundTransfer No l1Token Registry Validation

**Claimed:** HIGH — arbitrary l1Token can release any escrowed token
**Verdict:** FALSE POSITIVE — L2 validates token before encoding; onlyCounterpartGateway prevents forgery

## Why This Is Not Exploitable

`L1TokenGateway.finalizeInboundTransfer` at line 265 calls:
```solidity
TokenLike(l1Token).transferFrom(escrow, to, amount);
```
without checking `l1ToL2Token[l1Token] != address(0)`. The agent claimed an attacker could craft a message with an arbitrary `l1Token` to drain the escrow.

### The Gate: L2 Validates Token + onlyCounterpartGateway

The `l1Token` value in the message payload comes from `L2TokenGateway.outboundTransfer()` which explicitly validates:
```solidity
address l2Token = l1ToL2Token[l1Token];
require(l2Token != address(0), "L2TokenGateway/invalid-token");
```

The `l1Token` is only accepted by the L2 gateway if it's registered in `l1ToL2Token`. The token value is then encoded into the Arbitrum ArbSys message payload and delivered to L1 through the Arbitrum outbox.

`L1TokenGateway.finalizeInboundTransfer` is gated by `onlyCounterpartGateway` which verifies the message was delivered from the canonical L2 gateway address. An attacker cannot forge this — it requires Arbitrum's outbox to have recorded a message from the actual L2 gateway.

### Conclusion

The L2 validates the token → the message is signed by the Arbitrum cross-chain system → L1 verifies the signer is the L2 counterpart. An attacker cannot submit an arbitrary `l1Token` value through this path without controlling the L2 gateway itself (which is a separate, higher-level compromise). FALSE POSITIVE.
