# Agent Report: Oracle + Bank/Vault + Deposit/Withdrawal + Utils

**Scope:** `oracle/*`, `bank/*`, `deposit/*`, `withdrawal/*`, `utils/*`, `gas/GasUtils.sol`, `exchange/BaseHandler.sol`, `exchange/DepositHandler.sol`, `exchange/WithdrawalHandler.sol`

## Findings Summary

No new submittable vulnerabilities found.

### GmOracleProvider Price Validation: SAFE
Comprehensive validation: signers sorted, min ≤ max per signer, median > 0, min signers enforced, per-signer index uniqueness, signature over all price data including chain salt. Median price computation prevents any single compromised signer from dictating price.

### VULN-009 Re-Verification: CONFIRMED FALSE POSITIVE
`Oracle.sol:297` — timestamp adjustment `validatedPrice.timestamp -= timestampAdjustment` makes the effective timestamp SMALLER, which causes the `if (effective_timestamp + maxPriceAge < block.timestamp)` check to fail SOONER. Adjustment makes validation STRICTER, not looser. Confirmed false positive.

### StrictBank Token Donation: SAFE BY DESIGN
Direct ERC20 transfers to `StrictBank` (DepositVault, WithdrawalVault, OrderVault) above the recorded `tokenBalances` are credited to whoever triggers `recordTransferIn` next. There is no way for the donor to recover donated tokens. `transferOut` is `onlyController`. This is a documented design property.

### Withdrawal Minimum Output: SAFE
`ExecuteWithdrawalUtils.sol:316,328` correctly passes `withdrawal.minLongTokenAmount()` and `withdrawal.minShortTokenAmount()` as `minOutputAmount` to both withdrawal swap legs.

### ExecuteDepositUtils Intermediate Swap minOutput=0: SAFE (mitigated)
`ExecuteDepositUtils.sol:555` — intermediate pre-deposit swap uses `0` as `minOutputAmount`. However, the final guard `cache.receivedMarketTokens < deposit.minMarketTokens()` at line 229 catches any shortfall and reverts. End-to-end slippage protection exists through the minMarketTokens check.

### GlobalReentrancyGuard: SAFE
Uses DataStore storage slot for cross-contract reentrancy protection. Applied to all user-facing entry points. `executeDepositFromController`/`executeWithdrawalFromController` use local `nonReentrant` instead (correctly, since they're called from CONTROLLER that already holds the global lock, preventing deadlock).

### Cancel Access Control: SAFE
`DepositHandler.cancelDeposit` and `WithdrawalHandler.cancelWithdrawal` require `onlyController`. `validateRequestCancellation` enforces time-lock (`requestAge >= requestExpirationTime`). Premature keeper-initiated cancellation requires the time-lock to pass.

### Gas Limit Attack on Handlers: SAFE
`GasUtils.validateExecutionErrorGas` provides OOG protection for `eth_estimateGas`. `callbackGasLimit` is validated at deposit creation time and caps gas allocated to callbacks, preventing callback-based gas manipulation.

### EdgeDataStreamVerifier Signing Format: OPERATIONAL RISK (LOW)
`EdgeDataStreamVerifier.sol:116` — uses `ECDSA.tryRecover(rawKeccak256, signature)` without `toEthSignedMessageHash` prefix. Contrasts with `GmOracleUtils.sol` which uses `ECDSA.toEthSignedMessageHash`. If server and verifier are consistent (designed together), this is functional. Risk: if the Edge oracle server is ever updated independently and applies prefix, all Edge price updates would silently fail (liveness risk, not theft). Additionally, commented-out dead code in `Cast.sol` shows a format change (1-byte to 32-byte ABI encoding) that must match the server.

### Oracle Timestamp Adjustment Underflow: SAFE
`Oracle.sol:297` — `validatedPrice.timestamp -= timestampAdjustment` would revert with underflow panic if adjustment > timestamp (Solidity 0.8). Revert prevents incorrect price acceptance. CONFIG_KEEPER could misconfigure this to DoS price updates for a token. Admin-level risk only.

### ChainlinkDataStreamProvider: SAFE
On-chain verification via Chainlink's verifier contract. `feedId`, bid, ask validations applied. Spread reduction factor and multiplier validated for bounds.

### AccountUtils Zero Address: SAFE
`validateAccount(address)` correctly reverts on `address(0)`. Called at deposit and withdrawal creation.

## Conclusion

Oracle, vault, and deposit/withdrawal systems are well-implemented. VULN-009 re-confirmed as false positive. The Edge oracle format inconsistency is a liveness risk documented as operational concern. No new submittable financial findings.
