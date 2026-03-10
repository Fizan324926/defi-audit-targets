# False Positive: GemJoin9 Front-Running Attack

**Claimed:** MEDIUM — attacker can steal tokens by front-running join(address usr)
**Verdict:** FALSE POSITIVE — self-documented known design, atomic proxy usage required

## Why This Is Not a Valid Finding

`GemJoin9.join(address usr)` credits all excess tokens in the contract (above the tracked `total`) to `usr`. The code at line 98–100 explicitly documents:

```
// Allow dss-proxy-actions to send the gems with only 1 transfer
// This should be called via token.transfer() followed by gemJoin.join() atomically or
// someone else can steal your tokens
```

This is a **self-documented known design choice**. The contract is designed to be called via a proxy that performs `token.transfer()` and `gemJoin.join()` atomically in a single transaction. Users who send tokens directly without using the proxy accept this documented risk.

Sky's program rules state that issues requiring non-standard usage patterns that are explicitly documented as unsafe are out of scope. This is precisely such a case.

### Conclusion

The contract explicitly warns about this in its source code. Expected usage (via proxy, atomically) is safe. FALSE POSITIVE.
