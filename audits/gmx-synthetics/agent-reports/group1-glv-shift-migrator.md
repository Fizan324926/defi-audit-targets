# Agent Report: GLV System + Shift + GlpMigrator

**Scope:** `glv/*`, `shift/*`, `migration/GlpMigrator.sol`, `router/GlvRouter.sol`, `exchange/GlvDepositHandler.sol`, `exchange/GlvWithdrawalHandler.sol`, `exchange/GlvShiftHandler.sol`

## Findings Summary

All findings eliminated. No new submittable vulnerabilities found.

### ERC-4626 / Share Inflation Attack: SAFE
`StrictBank.tokenBalances` tracks actual protocol-recorded balances, not raw `balanceOf`. Direct ERC20 transfers to GLV address do NOT update `tokenBalances`. `syncTokenBalance` is `onlyController`. Inflation attacks require `syncTokenBalance` which is inaccessible to attackers. The `minGlvTokens` first-deposit check is optional but the StrictBank provides primary defense.

### Price Manipulation: SAFE
Oracle-based signed prices are used — no AMM spot prices. Flash loans cannot manipulate off-chain signed oracle prices. The GLV oracle price shortcut is bounded by oracle security.

### Reentrancy: SAFE
Global reentrancy guard in all handlers. Try-catch in execution functions. Callbacks are gas-limited. State removal before external calls within try-catch scope.

### GlvWithdrawalUtils poolValue SafeCast (LOW — ELIMINATED)
`GlvWithdrawalUtils.sol:317` — `poolValue.toUint256()` would revert if `poolValue < 0`. However, the try-catch in `GlvWithdrawalHandler.executeGlvWithdrawal` catches this, triggers `cancelGlvWithdrawal`, and safely returns user's GLV tokens (burn happens AFTER `_getMarketTokenAmount`). No permanent fund loss. Temporary inability to withdraw from one market when that market has negative pool value.

### Ordering (glvValue stale pre-sync): SAFE (by design)
`ExecuteGlvDepositUtils.sol:62-70` — `getGlvValue` is called before `syncTokenBalance`. This is correct standard LP math: `mintAmount = existingSupply × depositUSD / existingPoolValue`. The newly deposited tokens are intentionally excluded from the denominator.

### GlpMigrator receiver user-controlled: LOW — DOCUMENTED KNOWN DESIGN
`GlpMigrator.sol` explicitly documents (lines 190-197) that users can set receivers for redeemed tokens to their own wallets, bypassing the deposit vault for one side. The GLP is pre-burned so no free-mint exists. Known protocol design tradeoff.

### Access Control: SAFE
All GLV operations properly role-gated: `createGlv` → `onlyMarketKeeper`, `addMarket/removeMarket` → `onlyConfigKeeper`, `createGlvDeposit` → CONTROLLER (via routers), `executeGlvDeposit/Withdrawal` → `onlyOrderKeeper`.

### Market Shift Math: SAFE
Post-execution `fromMarket` pool values algebraically equal pre-execution values (`x * P_after / S_after = x * P / S`). No numeric discrepancy.

## Conclusion

GLV system is well-designed. The `StrictBank` pattern provides inflation attack protection. Access control is properly layered. No submittable findings.
