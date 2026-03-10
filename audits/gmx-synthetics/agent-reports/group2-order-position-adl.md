# Agent Report: Order Execution + Position Management + ADL + Liquidation

**Scope:** `order/*`, `position/*`, `adl/AdlUtils.sol`, `liquidation/LiquidationUtils.sol`, `exchange/OrderHandler.sol`, `exchange/JitOrderHandler.sol`, `exchange/LiquidationHandler.sol`, `exchange/AdlHandler.sol`

## Findings Summary

Two acknowledged design limitations documented in code. No new submittable financial findings.

### Liquidation Access Control: SAFE
`LiquidationHandler.executeLiquidation` is `onlyLiquidationKeeper`. Arbitrary users cannot trigger liquidations.

### Order Removal Before Processing: SAFE
`ExecuteOrderUtils.sol:36` removes order before processing, but any revert rolls back ALL state changes (Solidity atomicity). No permanent order loss possible.

### CEI Violations: SAFE
`GlobalReentrancyGuard` prevents reentrancy into any handler during callbacks. All state-modifying entry points protected.

### Stop-Loss Cancellation: BY DESIGN
Users can cancel their own stop-loss orders through the router. This is intentional — users must control their own orders. External parties cannot cancel another user's orders.

### ADL Targeting Not Enforced (LOW — KNOWN DESIGN)
`AdlHandler.sol:77-163` — Code comment explicitly states: "there is no validation that ADL is executed in order of position profit or position size, this is due to the limitation of the gas overhead required to check this ordering." ADL keepers can ADL losing positions when aggregate PnL ratio is high. Post-execution check `nextPnlToPoolFactor < pnlToPoolFactor` is satisfied by closing any position. Trusted keeper model — ADL keepers are authorized roles. **Acknowledged known limitation, not a code bug.**

### updateAdlState Spam Can Block ADL Execution (MEDIUM — KNOWN DESIGN)
`AdlUtils.sol:122` — Code comment explicitly states: "an ADL keeper could continually cause the latest ADL time to be updated and prevent ADL orders from being executed." Any ADL keeper can call `updateAdlState` repeatedly, keeping `latestAdlAt` current and forcing all ADL execution attempts to require fresher oracle prices. Requires compromised ADL keeper. **Acknowledged known design limitation, documented in source.**

### Position Accounting (sizeInTokens=0 edge case): SAFE
Eliminated by `MIN_POSITION_SIZE_USD` enforcement. The `sizeInUsd == sizeDeltaUsd` guard on partial closes also prevents the edge case.

### JIT Order Dust Amount: SAFE
User's `acceptablePrice` guards against bad execution regardless of GLV shift amount. JIT system is an optimization, not a guarantee.

### Oracle Timestamp for LimitDecrease: SAFE (intentional design)
`positionDecreasedAtTime` intentionally excluded from oracle freshness requirement to allow multiple pending stop-loss/limit orders without requiring fresh prices after each partial close.

## Conclusion

Order/position system is correct. The two ADL limitations are explicitly documented in source code as known design trade-offs. No new submittable findings.
