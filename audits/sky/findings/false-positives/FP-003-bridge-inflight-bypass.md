# False Positive: Bridge isOpen Bypass for In-Flight Messages

**Claimed:** HIGH — L2TokenGateway.finalizeInboundTransfer mints tokens when bridge is closed
**Verdict:** FALSE POSITIVE — inherent L1/L2 messaging design constraint

## Why This Is Not Exploitable

Both `L2TokenGateway.finalizeInboundTransfer` (Arbitrum) and `L2TokenBridge.finalizeBridgeERC20` (Optimism) lack an `isOpen == 1` check. Messages that were submitted before a governance `close()` call continue to be processed after the bridge is closed.

### Why This Is Intentional

This is an inherent property of L1↔L2 messaging on both Arbitrum and Optimism:

- **Arbitrum**: Retryable tickets submitted to the inbox are irreversible. Once a retryable ticket is created, it WILL be redeemed on L2 — there is no mechanism to retroactively cancel it. The Arbitrum outbox similarly cannot be stopped for messages already in the challenge period.

- **Optimism**: Messages sent via the CrossDomainMessenger are committed to the L2 state root and cannot be unilaterally cancelled after submission.

The `isOpen` flag correctly prevents NEW deposits/withdrawals from being initiated after the close. It cannot — and by the underlying infrastructure's design, should not be expected to — retroactively stop messages already in transit.

### Bridge Design Is Correct

The bridge's `close()` function is meant to prevent NEW cross-chain operations, not to retroactively halt the underlying messaging infrastructure. Any bridge deployed on Arbitrum/Optimism has this same property. It is not a bug unique to Sky's bridge implementation.

### Conclusion

Not a valid finding. Governance closing the bridge achieves its stated purpose (blocking new operations). In-flight messages completing after a close is an inherent property of the underlying L1/L2 infrastructure that cannot be guarded against at the bridge contract level.
