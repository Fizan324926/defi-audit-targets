# Gains Network (gTrade) Security Audit: PriceImpact, TradingInteractions, PriceAggregator

**Auditor:** Senior Smart Contract Security Auditor
**Date:** 2026-03-02
**Scope:** GNSPriceImpact, GNSTradingInteractions, GNSPriceAggregator facets + libraries
**Contracts Version:** Solidity 0.8.23

---

## Executive Summary

This audit covers the price impact calculation engine, trading interaction entry points, and price aggregator/oracle subsystem of the Gains Network gTrade Diamond. The codebase is mature and well-engineered with multiple layers of defense (reentrancy guards, delegation controls, oracle outlier filtering). After thorough analysis of 6 primary source files and supporting interfaces/libraries, the following findings were identified:

**Critical:** 0
**High:** 0
**Medium:** 2
**Low:** 3
**Informational:** 4

Total: 9 findings

---

## FINDING-001: Missing Chainlink Price Feed Staleness and Negative Price Validation

**Severity:** MEDIUM

**File:** `/root/defi-audit-targets/audits/gains-network/contracts/facets/GNSPriceAggregator/contracts/libraries/PriceAggregatorUtils.sol`

**Lines:** 508-512, 482

### Description

The `getCollateralPriceUsd()` function reads from a Chainlink price feed but performs no validation on the returned data:

```solidity
// Line 508-512
function getCollateralPriceUsd(uint8 _collateralIndex) public view returns (uint256) {
    (, int256 collateralPriceUsd, , , ) = _getStorage().collateralUsdPriceFeed[_collateralIndex].latestRoundData();
    return uint256(collateralPriceUsd);
}
```

Similarly, `getLinkFee()` at line 482:
```solidity
(, int256 linkPriceUsd, , , ) = _getStorage().linkUsdPriceFeed.latestRoundData(); // 1e8
```

**Issues:**
1. **No staleness check:** The `updatedAt` timestamp (3rd return value) is discarded. If the Chainlink feed is stale (sequencer down, feed paused, etc.), the contract will use an outdated price.
2. **No negative/zero price check:** If `collateralPriceUsd` is zero or negative (which Chainlink can return in extreme conditions), `uint256(collateralPriceUsd)` for a negative value wraps to an extremely large number due to two's complement. A zero price leads to division-by-zero in `getCollateralFromUsdNormalizedValue()` (line 532-534).
3. **No roundId validation:** The `roundId` and `answeredInRound` values are discarded, preventing detection of incomplete rounds.

**Impact:** If Chainlink returns stale or invalid data:
- **Stale price:** Trades could be opened/closed at incorrect valuations, causing the protocol's vault to absorb losses.
- **Negative price cast:** A negative `int256` cast to `uint256` would produce a value near `type(uint256).max`, inflating all USD-denominated calculations by orders of magnitude. Every collateral-to-USD conversion downstream (OI calculations, fee calculations, position sizing) would be corrupted.
- **Zero price:** Division by zero in `getCollateralFromUsdNormalizedValue()` would revert all trades for that collateral.

**Exploitability:** Low difficulty on L2s where sequencer downtime is a known risk. L2 sequencer feeds would mitigate but are not checked.

**Recommendation:**
```solidity
function getCollateralPriceUsd(uint8 _collateralIndex) public view returns (uint256) {
    (uint80 roundId, int256 collateralPriceUsd, , uint256 updatedAt, uint80 answeredInRound) =
        _getStorage().collateralUsdPriceFeed[_collateralIndex].latestRoundData();

    if (collateralPriceUsd <= 0) revert IGeneralErrors.InvalidPrice();
    if (updatedAt == 0) revert IGeneralErrors.InvalidPrice();
    if (answeredInRound < roundId) revert IGeneralErrors.StalePrice();
    if (block.timestamp - updatedAt > MAX_PRICE_STALENESS) revert IGeneralErrors.StalePrice();

    return uint256(collateralPriceUsd);
}
```

---

## FINDING-002: `delegatedTradingAction` Missing `nonReentrant` Guard Creates Subtle Attack Surface

**Severity:** MEDIUM

**File:** `/root/defi-audit-targets/audits/gains-network/contracts/facets/GNSTradingInteractions/contracts/core/facets/GNSTradingInteractions.sol`

**Line:** 68

### Description

The `delegatedTradingAction()` function in the facet contract is the ONLY user-facing function that does NOT have the `nonReentrant` modifier:

```solidity
// Line 68 - NO nonReentrant modifier
function delegatedTradingAction(address _trader, bytes calldata _callData) external returns (bytes memory) {
    return TradingInteractionsUtils.delegatedTradingAction(_trader, _callData);
}
```

Compare with all other functions:
```solidity
function openTrade(...) external nonReentrant { ... }
function closeTradeMarket(...) external nonReentrant { ... }
function triggerOrder(...) external nonReentrant { ... }
// ... etc, all have nonReentrant
```

The inner `delegatecall` at `TradingInteractionsUtils.sol:177` calls back into `address(this)`, which routes through the diamond to a facet function that DOES have `nonReentrant`. So in practice, reentrancy is blocked by the inner function's guard. However:

1. The `senderOverride` is set BEFORE the delegatecall (line 176) and cleared AFTER (line 188). If the delegatecall succeeds but some future code path were added that doesn't hit `nonReentrant`, the `senderOverride` could be exploited.
2. Future diamond upgrades could add facet functions without `nonReentrant`, and `delegatedTradingAction` would become the attack vector since it's the only function that allows arbitrary calldata execution.
3. A delegate could encode calldata targeting a non-trading function selector that might exist on the diamond but lacks reentrancy protection.

**Current mitigation:** The `notDelegatedAction` modifier on `delegatedTradingAction` itself prevents nesting. The inner functions all have `nonReentrant`. So this is not currently exploitable.

**Impact:** Currently no direct exploit, but represents a defense-in-depth gap. The function accepts arbitrary `_callData` and executes it via `delegatecall` -- it should have the strongest protections.

**Recommendation:** Add `nonReentrant` to `delegatedTradingAction()`:
```solidity
function delegatedTradingAction(address _trader, bytes calldata _callData)
    external nonReentrant returns (bytes memory) {
    return TradingInteractionsUtils.delegatedTradingAction(_trader, _callData);
}
```

---

## FINDING-003: Depth Bands Price Impact Overflow in Trapezoidal Calculation When Trade Exceeds 100% Band Depth

**Severity:** LOW

**File:** `/root/defi-audit-targets/audits/gains-network/contracts/facets/GNSPriceImpact/contracts/libraries/PriceImpactUtils.sol`

**Lines:** 1212-1227

### Description

In `_calculateDepthBandsPriceImpact()`, when the last band has `bandLiquidityPercentageBps == HUNDRED_P_BPS` (100%), ALL remaining trade size is consumed regardless of the band's actual available depth:

```solidity
// Line 1212-1214
if (bandLiquidityPercentageBps == HUNDRED_P_BPS || remainingSizeUsd <= bandAvailableDepthUsd) {
    depthConsumedUsd = remainingSizeUsd;
    remainingSizeUsd = 0;
}
```

Then the trapezoidal calculation at line 1227:
```solidity
uint256 avgImpactP = lowOffsetP + ((offsetRangeP * depthConsumedUsd) / bandAvailableDepthUsd) / 2;
```

When `depthConsumedUsd >> bandAvailableDepthUsd` (trade size much larger than the band's depth), the ratio `depthConsumedUsd / bandAvailableDepthUsd` becomes very large. With extremely large trades relative to depth, the multiplication `offsetRangeP * depthConsumedUsd` could overflow uint256 in theory.

**Concrete scenario:**
- `offsetRangeP` = max uint16 value from mapping * 1e6 = 65535 * 1e6 = 6.5535e10
- `depthConsumedUsd` could be 1e30+ (for an extreme trade size)
- Product: 6.5535e10 * 1e30 = 6.5535e40, well within uint256 (max ~1.15e77)

So the multiplication itself won't overflow in practice, but the resulting `avgImpactP` can be astronomically high (far exceeding 100% price impact), which would cause `totalWeightedPriceImpactP` to overflow in the cumulation at line 1229.

Specifically: `totalWeightedPriceImpactP += avgImpactP * depthConsumedUsd` where both values can be very large.
- avgImpactP could be ~6.5e40 (from above)
- depthConsumedUsd could be ~1e30
- Product: ~6.5e70, still within uint256

So in realistic scenarios, this doesn't overflow. But it results in extreme price impact values that would prevent trade execution via the MAX_OPEN_NEGATIVE_PNL_P check anyway.

**Impact:** Low. Extreme trades would be rejected by other guards (MAX_OPEN_NEGATIVE_PNL_P = 40%). The trapezoidal extrapolation beyond the band depth is mathematically imprecise but harmless because the protection system rejects trades with excessive price impact.

**Recommendation:** Consider capping the trapezoidal ratio: `min(depthConsumedUsd, bandAvailableDepthUsd)` when calculating the in-band impact, with the excess mapped to the maximum offset. This would give more predictable behavior for extreme trade sizes.

---

## FINDING-004: OI Window Reset Timing Can Be Exploited to Reduce Cumulative Volume Price Impact

**Severity:** LOW

**File:** `/root/defi-audit-targets/audits/gains-network/contracts/facets/GNSPriceImpact/contracts/libraries/PriceImpactUtils.sol`

**Lines:** 530-546, 1039-1061

### Description

The cumulative volume price impact system uses time-windowed OI tracking. Active OI is the sum of the last `windowsCount` windows (max 5, each 1-10 minutes). When a window expires (falls outside the active range), its OI is effectively forgotten.

```solidity
// Line 530-546: Only sums windows within active range
function getPriceImpactOi(uint256 _pairIndex, bool _long) internal view returns (uint256 activeOi) {
    // ...
    uint256 currentWindowId = _getCurrentWindowId(settings);
    uint256 earliestWindowId = _getEarliestActiveWindowId(currentWindowId, settings.windowsCount);

    for (uint256 i = earliestWindowId; i <= currentWindowId; ++i) {
        IPriceImpact.PairOi memory _pairOi = priceImpactStorage.windows[settings.windowsDuration][_pairIndex][i];
        activeOi += _long ? _pairOi.oiLongUsd : _pairOi.oiShortUsd;
    }
}
```

**Attack scenario:**
A trader wanting to open a large position with minimal price impact can:
1. Wait for a window boundary (observable from `startTs` and `windowsDuration` settings, which are public)
2. Ensure their trade lands in a fresh window right after existing high-OI windows expire
3. The cumulative volume (used as `_cumulativeVolumeUsd` in `_getDepthBandsPriceImpactP`) resets lower, reducing their price impact

With `windowsDuration = 1 minute` and `windowsCount = 5`, the total lookback is only 5 minutes. A trader who waits 5 minutes after a burst of trading activity can open with significantly reduced cumulative volume price impact.

**Impact:** The attack reduces price impact costs for a strategic trader. With the anti-splitting mechanism (the `/2` at line 1137), the benefit is halved, but the trader still gets a better execution price than they should. The financial impact depends on:
- Window configuration (shorter windows = easier to exploit)
- Trade size relative to depth bands
- How much OI expires at the boundary

For a pair with $10M daily volume and 5-minute windows, the cumulative volume could swing by millions of dollars at window boundaries.

**Mitigations already in place:**
- The `cumulativeFactor` can be set > 1.0 to weight historical OI more heavily
- The `protectionCloseFactor` prevents same-block profitable closes
- The skew price impact (separate from cumul vol) is based on actual OI, not windowed volume

**Recommendation:** This is a known architectural tradeoff of windowed systems. Consider adding partial decay within windows (linear interpolation) rather than cliff expiry, or increasing `windowsCount` for high-value pairs.

---

## FINDING-005: Protection Close Factor Bypassed for Whitelisted Addresses and Exempt Pairs

**Severity:** LOW

**File:** `/root/defi-audit-targets/audits/gains-network/contracts/facets/GNSPriceImpact/contracts/libraries/PriceImpactUtils.sol`

**Lines:** 571-581

### Description

The protection close factor is designed to penalize traders who close profitable positions very quickly (same-block or near-block) after opening or increasing position size:

```solidity
// Lines 571-576
v.protectionCloseFactorActive =
    _isPnlPositive &&
    !_open &&
    v.pairFactors.protectionCloseFactor != 0 &&
    ChainUtils.getBlockNumber() <= _lastPosIncreaseBlock + v.pairFactors.protectionCloseFactorBlocks &&
    !v.protectionCloseFactorWhitelist;
```

```solidity
// Lines 578-581
if (
    (_open && v.pairFactors.exemptOnOpen) ||
    (!_open && !v.protectionCloseFactorActive && v.pairFactors.exemptAfterProtectionCloseFactor)
) return 0;
```

Two bypass paths exist:
1. **Whitelisted traders** (`protectionCloseFactorWhitelist[trader] = true`): Completely bypass protection close factor regardless of timing
2. **Exempt pairs** (`exemptAfterProtectionCloseFactor = true`): When protection close factor is not active (i.e., sufficient blocks have passed), the entire cumul vol price impact returns 0

For whitelisted addresses, the bypass is by design (trusted market makers). For exempt pairs with `exemptAfterProtectionCloseFactor`, once the protection window expires, closing ANY position on that pair incurs ZERO cumulative volume price impact.

**Impact:** For `exemptAfterProtectionCloseFactor = true` pairs, after the protection window (max 10 minutes), traders can close with zero cumul vol price impact. This means the cumulative volume price impact system is effectively disabled for closes on these pairs beyond the protection window. The only closing impact comes from the fixed spread and skew price impact.

**Recommendation:** Ensure governance understands that `exemptAfterProtectionCloseFactor = true` disables cumul vol price impact on closes for the pair. This is clearly an intentional governance toggle but should be documented as having this significant effect.

---

## FINDING-006: Signed Price Validation Does Not Check `fromBlock` Against Current Block for Staleness

**Severity:** INFORMATIONAL

**File:** `/root/defi-audit-targets/audits/gains-network/contracts/facets/GNSPriceAggregator/contracts/libraries/SignedPricesUtils.sol`

**Lines:** 39-52

### Description

In `validateSignedPairPrices()`, the signed prices include a `fromBlock` parameter that must match across all signers:

```solidity
uint32 fromBlock = _signedPairPrices[0].fromBlock;
// ...
if (signedData.fromBlock != fromBlock) revert IPriceAggregatorUtils.FromBlockMismatch();
```

The `fromBlock` is validated against the trade's lookback block in `_executeTriggerOrderWithSignature` (TradingInteractionsUtils.sol:528-530):
```solidity
if (
    _signedPairPrices[0].fromBlock !=
    _getMultiCollatDiamond().getLookbackFromBlock(_t.user, _t.index, _orderType)
) revert ITradingInteractionsUtils.WrongFromBlock();
```

However, in `validateSignedPairPrices` itself, there is no check that `fromBlock` is within a reasonable range of the current block. The expiry timestamp check (`block.timestamp > signedData.expiryTs` and `signedData.expiryTs > block.timestamp + 1 hours`) provides a time-based staleness bound, but the `fromBlock` could theoretically reference an arbitrarily old block.

**Impact:** The `expiryTs` check limits the time window to 1 hour, which provides adequate staleness protection. The `fromBlock` is additionally validated against the trade's stored lookback block in the trigger execution path. This is defense-in-depth; the existing protections are sufficient.

**Recommendation:** No action needed. The expiry timestamp and the per-trade `fromBlock` validation in the trigger execution path provide sufficient protection.

---

## FINDING-007: `addPriceImpactOpenInterest` Only Adds to OI Windows -- Never Subtracts

**Severity:** INFORMATIONAL

**File:** `/root/defi-audit-targets/audits/gains-network/contracts/facets/GNSPriceImpact/contracts/libraries/PriceImpactUtils.sol`

**Lines:** 415-468

### Description

The `addPriceImpactOpenInterest` function only ever ADDS OI to the current window, regardless of whether a trade is opening or closing:

```solidity
// Line 443
bool long = (trade.long && _open) || (!trade.long && !_open);

if (long) {
    currentWindow.oiLongUsd += oiDeltaUsd;  // Always adds
} else {
    currentWindow.oiShortUsd += oiDeltaUsd;  // Always adds
}
```

When a long is closed, OI is added to the SHORT side of the current window. When a short is closed, OI is added to the LONG side. This means cumulative volume always grows, and both opens and closes contribute to price impact for future trades on the same side.

**Impact:** This is intentional design -- the system tracks cumulative volume, not net OI. Each trade (open or close) adds to the "pressure" on one side. The windows naturally expire to reset this. However, this means:
1. A trader opening and immediately closing on the same pair increases cumulative volume on BOTH sides
2. High closing volume on one side increases price impact for new opens on that same side
3. The `negPnlCumulVolMultiplier` reduces the OI added for losing closes (multiplier < 1.0), which is a sensible incentive: losing trades contribute less to price impact than winning ones

**Recommendation:** No action needed. This is a documented design choice. The system is explicitly described as tracking cumulative volume with time-decay windows.

---

## FINDING-008: Potential Precision Loss in `_getTradePriceImpactP` for Small Trades

**Severity:** INFORMATIONAL

**File:** `/root/defi-audit-targets/audits/gains-network/contracts/facets/GNSPriceImpact/contracts/libraries/PriceImpactUtils.sol`

**Lines:** 1081-1094

### Description

The legacy `_getTradePriceImpactP` function (used by skew price impact) performs integer division:

```solidity
function _getTradePriceImpactP(
    int256 _startOpenInterest,
    int256 _tradeOpenInterest,
    uint256 _onePercentDepth,
    uint256 _priceImpactFactor,
    uint256 _cumulativeFactor
) internal pure returns (int256 priceImpactP) {
    if (_onePercentDepth == 0) return 0;

    priceImpactP =
        (((_startOpenInterest * int256(_cumulativeFactor)) / int256(ConstantsUtils.P_10) + _tradeOpenInterest / 2) *
            int256(_priceImpactFactor)) /
        int256(_onePercentDepth);
}
```

For `getTradeSkewPriceImpactP`, the result is further divided by 2:
```solidity
// Line 646
return _getTradePriceImpactP(...) / v.priceImpactDivider;  // priceImpactDivider = 2
```

When `_onePercentDepth` is large (deep market) and trade size is small, the division can truncate to 0, meaning small trades pay zero skew price impact.

**Impact:** Negligible. Small trades on deep markets should indeed have near-zero price impact. The truncation to zero is economically appropriate -- the actual impact would be sub-basis-point.

**Recommendation:** No action needed. The precision loss aligns with the economic intent.

---

## FINDING-009: Delegation System Allows Delegate to Execute Any Diamond Function Via Arbitrary Calldata

**Severity:** INFORMATIONAL

**File:** `/root/defi-audit-targets/audits/gains-network/contracts/facets/GNSTradingInteractions/contracts/libraries/TradingInteractionsUtils.sol`

**Lines:** 168-191

### Description

The `delegatedTradingAction` function accepts arbitrary `_callData` and executes it via `delegatecall` on `address(this)` (the diamond):

```solidity
s.senderOverride = _trader;
(bool success, bytes memory result) = address(this).delegatecall(_callData);
```

This means a delegate can call ANY function on the diamond on behalf of the trader, not just trading functions. The only restriction is the `notDelegatedAction` modifier on certain functions (like `openTradeNative`, `triggerOrder`, `triggerOrderWithSignatures`).

Functions that CAN be called via delegation (they use `_msgSender()` which returns `senderOverride`):
- `openTrade` - opens trades on behalf of trader (from trader's collateral)
- `closeTradeMarket` - closes trader's positions
- `updateTp` / `updateSl` - changes TP/SL
- `updateLeverage` - changes leverage
- `increasePositionSize` - increases position from trader's collateral
- `decreasePositionSize` - decreases positions
- `withdrawPositivePnl` - withdraws PnL (funds go to trader)
- `cancelOpenOrder` - cancels orders (returns collateral to SENDER override, i.e., the trader)

Functions that CANNOT be called via delegation (have `notDelegatedAction`):
- `openTradeNative` - prevents native token theft
- `updateLeverageNative` - prevents native token theft
- `increasePositionSizeNative` - prevents native token theft
- `triggerOrder` - prevents unauthorized trigger execution
- `triggerOrderWithSignatures` - prevents unauthorized trigger execution

**Current protections:**
1. The trader explicitly sets the delegate: `setTradingDelegate(_delegate)`
2. `notDelegatedAction` blocks sensitive operations
3. `cancelOpenOrder` returns collateral to `sender` (the trader's address via override), not `msg.sender`
4. `withdrawPositivePnl` sends funds through the standard flow to the trade owner

**Impact:** A malicious delegate could:
- Open undesirable positions for the trader (using trader's collateral)
- Close the trader's positions at unfavorable times
- Change SL/TP to unfavorable values
- Increase leverage to dangerous levels

However, all of these require the trader to have explicitly authorized the delegate. The trader can revoke delegation at any time via `removeTradingDelegate()`.

**Recommendation:** This is by design and the trust model is clearly "the trader trusts their delegate completely." Consider adding an optional per-function delegation mask (bitmask of allowed function selectors) for more granular control, but this adds complexity with marginal security benefit given the explicit trust relationship.

---

## Areas Analyzed With No Findings

### Trade Splitting to Avoid Price Impact
The depth bands system at `_getDepthBandsPriceImpactP` (lines 1105-1142) explicitly prevents trade splitting via the formula:
```solidity
uint256 unscaledPriceImpactP = cumulativeVolPriceImpactP +
    (totalSizePriceImpactP - cumulativeVolPriceImpactP) / 2;
```
The cumulative volume is factored into both the starting point (`cumulativeVolPriceImpactP`) and the total (`totalSizePriceImpactP`). Splitting a trade into N pieces results in the same or higher total impact because each subsequent piece starts from a higher cumulative volume. Verified: anti-splitting is mathematically sound.

### Open+Close Same Block Asymmetric Impact
The protection close factor (lines 571-576) correctly identifies same-block profitable closes and applies a penalty factor. The `protectionCloseFactorBlocks` extends this to a configurable number of blocks. Opening a position and immediately closing it profitably would be penalized. Verified: the protection is symmetric and effective.

### Leverage Limit Bypass
The leverage is checked both at order time (TradingInteractionsUtils.sol:681-683) and at callback time (TradingCallbacksUtils.sol:898). Using `pairMinLeverage` and `pairMaxLeverage` from PairsStorage. Counter-trades have an additional `getPairCounterTradeMaxLeverage` check (line 686-688). Verified: no bypass path.

### SL/TP Guaranteed Profit
The `updateTp` and `updateSl` functions (lines 323-346) simply delegate to `updateTradeTp` and `updateTradeSl` in TradingStorage. The TP/SL validation logic is in the storage layer. The SL and TP checks at execution time (TradingCallbacksUtils.sol) use lookback prices with fromBlock verification, preventing manipulation. Verified: no guaranteed profit via TP/SL.

### Oracle Callback Authorization
The `fulfill` callback in PriceAggregatorUtils.sol (line 354) uses `ChainlinkClientUtils.validateChainlinkCallback(_requestId)` which verifies the caller is a registered oracle node. The request ID must match a pending request. Verified: unauthorized callback injection is not possible.

### Median Price Calculation Manipulation
The sorting and median calculation (lines 775-857) uses a standard quicksort + median approach. The outlier filtering (`_filterOutliersAndReturnMedian`) first computes a median, then removes answers outside `maxDeviationP` of that median, then recomputes the median on filtered answers. The `minAnswers` requirement ensures enough oracles agree. Verified: with N >= minAnswers honest oracles, the median is manipulation-resistant.

### Signed Price Replay / Cross-chain Replay
The signed price system in `SignedPricesUtils.sol` includes:
- Ascending signer ID enforcement (line 46) -- prevents duplicate oracles
- Expiry timestamp check (line 49-50) -- 1 hour max
- `isLookback` match enforcement (line 51)
- `fromBlock` consistency check (line 52)
- Signature recovery against oracle authorization status (line 65)
- Pair indices uniqueness and sorting (line 100)
- Cleanup after use (line 137-148) -- prevents re-use of temporary storage

The only concern is no `chainId` in the signed message, but the oracle authorization is chain-specific (each chain has its own oracle contracts). Verified: replay attacks are prevented.

### `updatePairOiAfterV10` Negative OI Clamping
Lines 490-509 use `int128` arithmetic with clamping to 0 for negative values. This prevents underflow when rounding causes OI removal to exceed recorded OI. Verified: handles rounding correctly.

---

## Summary

The Gains Network codebase for these facets is well-engineered with strong security properties:

1. **Global reentrancy guard** on the diamond prevents cross-facet reentrancy
2. **Outlier-filtered median oracle** with minimum answer requirements provides robust pricing
3. **Anti-splitting price impact** design correctly prevents trade fragmentation attacks
4. **Protection close factor** blocks same-block profitable closes
5. **Delegation system** has appropriate `notDelegatedAction` guards on sensitive functions

The two MEDIUM findings (Chainlink staleness validation, missing `nonReentrant` on delegation) represent defense-in-depth gaps rather than directly exploitable vulnerabilities. The LOW findings are architectural tradeoffs that are acknowledged in the system design. No critical or high-severity issues were found.
