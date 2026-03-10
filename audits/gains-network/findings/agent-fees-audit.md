# Gains Network (gTrade) - Fee Calculation Deep Audit

## Scope

Deep security review of the funding fee and borrowing fee calculation subsystems:

1. `GNSFundingFees/contracts/libraries/FundingFeesUtils.sol` -- Funding fee velocity model, APR multiplier, sign-change handling, borrowing fee (V2 time-based)
2. `GNSBorrowingFees/contracts/libraries/BorrowingFeesUtils.sol` -- Borrowing fee (V1 block-based), exponential OI weighting, MAX(pair, group) selection
3. `GNSFundingFees/contracts/core/facets/GNSFundingFees.sol` -- Facet entry points and access control
4. `GNSBorrowingFees/contracts/core/facets/GNSBorrowingFees.sol` -- Facet entry points and access control
5. `GNSTradingCallbacks/contracts/libraries/updatePositionSize/DecreasePositionSizeUtils.sol` -- Partial close logic
6. `GNSTradingCallbacks/contracts/libraries/updatePositionSize/IncreasePositionSizeUtils.sol` -- Partial add logic

---

## Finding 1: Funding Fee Undercharge During Sign-Change When Rate Hits Cap

**Severity: MEDIUM**

**File:** `/root/defi-audit-targets/audits/gains-network/contracts/facets/GNSFundingFees/contracts/libraries/FundingFeesUtils.sol`
**Lines:** 839-853

### Description

When the funding rate crosses zero (sign change) and the APR multiplier is enabled, the system splits the accumulated fee calculation into two periods: (1) from `lastRate` to 0, and (2) from 0 to `currentRate`. For period 2 (lines 840-853), the code computes the average rate as `currentFundingRatePerSecondP / 2`, assuming linear interpolation from 0 to the current rate.

However, `currentFundingRatePerSecondP` may have been capped at `ratePerSecondCap` by `_getAvgFundingRatePerSecondP()` (line 1369). When the cap is hit during period 2, the true average rate is NOT `cap / 2` -- it is higher, because the rate spent time at the cap value (a flat region) in addition to the ramp-up region.

```solidity
// Line 840 - INCORRECT when cap was hit during period 2
v.avgFundingRatePerSecondP = currentFundingRatePerSecondP / 2;
v.fundingFeesDeltaP =
    (v.avgFundingRatePerSecondP *
        int256(v.secondsSinceLastUpdate - v.secondsToReachZeroRate) *
        v.currentPairPriceInt) /
    1e8; // 1e20 (%)
```

**True average for period 2 should be:**
```
(tCapFrom0 * cap/2 + (T - t0 - tCapFrom0) * cap) / (T - t0)
```
Where `tCapFrom0` is the time from rate=0 to the cap, `t0` is `secondsToReachZeroRate`, and `T` is `secondsSinceLastUpdate`.

**Numerical example with max velocity:**
- `absoluteRatePerSecondCap` = 317097 (1000% APR)
- `absoluteVelocityPerYearCap` = 1e7 (=> velocity = 1e10)
- Rate goes from `-cap` through 0 to `+cap` in about 2000 seconds (33 minutes)
- For a 1-day interval without updates: the code uses `cap/2` as average for period 2, but the true average is approximately `cap` (since 99%+ of the time is spent at cap)
- **Undercharge: approximately 49.7%** of the period 2 funding fees

### Impact

The minority side earns approximately 50% less funding fees than it should when:
1. APR multiplier is enabled on the pair
2. The funding rate crosses zero during a single update interval
3. The rate also hits the cap during that same interval (requires high velocity + long interval)

This requires no active exploitation -- it occurs naturally on pairs with high velocity settings and infrequent updates (illiquid pairs). The financial impact scales with the total OI on the affected pair and the duration the rate sits at cap.

**Conditions for significant impact:**
- High velocity params (rate reaches cap within minutes/hours)
- Long update intervals (no trades for 1+ days)
- Significant OI on both sides (for the APR multiplier to matter)
- APR multiplier enabled

In practice, on actively-traded pairs this is unlikely to be material since updates happen frequently (every trade). On illiquid pairs, the OI is typically low so the dollar impact is limited. Nevertheless, the mathematical error is clear and the 50% undercharge is not negligible.

### Recommendation

Split period 2 into two sub-periods: the ramp from 0 to cap, and the flat region at cap. This requires computing `tCapFrom0` (seconds from rate=0 to the cap):

```solidity
// Period 2: From rate = 0 to current rate
uint256 period2Duration = v.secondsSinceLastUpdate - v.secondsToReachZeroRate;

if (currentFundingRatePerSecondP == ratePerSecondCap && period2Duration > 0) {
    // Rate hit the cap during period 2 - split further
    uint256 tCapFrom0 = uint256(
        (int256(ratePerSecondCap) * ONE_YEAR) / int256(v.currentVelocityPerYear) / 1e8
    );

    if (tCapFrom0 < period2Duration) {
        // Sub-period 2a: ramp from 0 to cap
        int256 avgRate2a = currentFundingRatePerSecondP / 2;
        int256 delta2a = (avgRate2a * int256(tCapFrom0) * v.currentPairPriceInt) / 1e8;

        // Sub-period 2b: flat at cap
        int256 delta2b = (int256(currentFundingRatePerSecondP) * int256(period2Duration - tCapFrom0) * v.currentPairPriceInt) / 1e8;

        v.fundingFeesDeltaP = delta2a + delta2b;
    } else {
        // Cap not actually reached in period 2 (shouldn't happen but safe)
        v.avgFundingRatePerSecondP = currentFundingRatePerSecondP / 2;
        v.fundingFeesDeltaP = (v.avgFundingRatePerSecondP * int256(period2Duration) * v.currentPairPriceInt) / 1e8;
    }
} else {
    // No cap hit, linear interpolation is correct
    v.avgFundingRatePerSecondP = currentFundingRatePerSecondP / 2;
    v.fundingFeesDeltaP = (v.avgFundingRatePerSecondP * int256(period2Duration) * v.currentPairPriceInt) / 1e8;
}
```

---

## Finding 2: Sign-Change Period 1 Also Undercharges When Last Rate Was at Cap

**Severity: LOW**

**File:** `/root/defi-audit-targets/audits/gains-network/contracts/facets/GNSFundingFees/contracts/libraries/FundingFeesUtils.sol`
**Lines:** 826-829

### Description

The first period of the sign-change split (from `lastRate` to 0) uses `lastFundingRatePerSecondP / 2` as the average (line 826). This is correct IF the rate changes linearly from `lastRate` to 0.

However, consider the scenario where `lastRate` was at the PREVIOUS cap (negative cap, e.g., `-cap`), and the velocity just flipped (OI changed). The new velocity is positive, pushing the rate from `-cap` through 0. In this case, the rate was sitting at `-cap` and may have been sitting there for some time before the velocity changed. But since the velocity changed (which only happens when an update occurs, resetting the `lastRate`), the stored `lastRate` already accounts for the cap.

Actually, upon deeper analysis, this period is computed correctly. The stored `lastFundingRatePerSecondP` already reflects the capped value, and the linear interpolation from that stored value to 0 is accurate because within this update interval, the velocity is constant. The rate truly does change linearly from `lastRate` to 0 during this sub-interval.

**Resolution: NOT A FINDING** (the period 1 calculation is correct)

---

## Finding 3: Borrowing Fee V1 `_getBorrowingPendingAccFeesDelta` -- Precision Loss for Small OI Ratios

**Severity: LOW**

**File:** `/root/defi-audit-targets/audits/gains-network/contracts/facets/GNSBorrowingFees/contracts/libraries/BorrowingFeesUtils.sol`
**Lines:** 849-867

### Description

The borrowing fee delta calculation uses integer exponentiation:

```solidity
uint256 _delta = _maxOi > 0 && _feeExponent > 0
    ? (_blockDistance * _feePerBlock * ((_netOi * 1e10) / _maxOi) ** _feeExponent) /
        (uint256(_collateralPrecision) ** _feeExponent)
    : 0;
```

When `_netOi` is very small relative to `_maxOi`, the ratio `(_netOi * 1e10) / _maxOi` can round to 0 before exponentiation. With `feeExponent = 1`, if `_netOi < _maxOi / 1e10`, the ratio is 0, meaning the fee delta is 0 even though there IS some net OI.

For 6-decimal collateral (USDC), `collateralPrecision = 1e6`:
- `_netOi` in collateral precision (1e6)
- `_maxOi` in 1e10
- Ratio = `(_netOi * 1e10) / _maxOi`
- If `_netOi = 1` (1 wei of USDC = $0.000001), ratio = `1e10 / _maxOi`
- For `_maxOi = 1e12` (corresponding to $100 in 1e10 precision), ratio = `1e10 / 1e12 = 0.01`, which rounds to 0 in integer division

This means borrowing fees are not charged when the net OI is below approximately `_maxOi / 1e10` in collateral tokens. For a `_maxOi` of $10M (= 1e17 in 1e10), the threshold is `1e17 / 1e10 = 1e7 = 10 USDC` of net OI. Below this, borrowing fees round to zero.

### Impact

Minimal practical impact. The threshold is very small in dollar terms (proportional to maxOi / 1e10). For typical parameter values, the rounding threshold is well below any meaningful position size. The protocol intentionally uses large maxOi values, keeping the threshold negligible.

With `feeExponent = 3`, the issue is amplified: the threshold becomes `(maxOi / 1e10)^(1/3)` which is even smaller.

### Recommendation

No fix needed. The precision loss is insignificant for any realistic parameters. If desired, the computation order could be rearranged to minimize intermediate rounding, but the gas cost increase is not justified.

---

## Finding 4: New Time-Based Borrowing Fee (V2) Is Side-Agnostic -- Both Sides Pay Equal Rate

**Severity: INFORMATIONAL**

**File:** `/root/defi-audit-targets/audits/gains-network/contracts/facets/GNSFundingFees/contracts/libraries/FundingFeesUtils.sol`
**Lines:** 873-893

### Description

The new borrowing fee system (V2, time-based) in `getPairPendingAccBorrowingFees` charges a single flat rate based on `borrowingRatePerSecondP * elapsedTime * pairPrice`. This rate applies equally to both longs and shorts -- there is a single `accBorrowingFeeP` accumulator, not separate long/short accumulators.

```solidity
uint256 accBorrowingFeeDeltaP = uint256(borrowingFeeParams.borrowingRatePerSecondP) *
    (block.timestamp - borrowingFeeData.lastBorrowingUpdateTs) *
    _currentPairPrice; // 1e20 (%)

accBorrowingFeeP = borrowingFeeData.accBorrowingFeeP + uint128(accBorrowingFeeDeltaP);
```

In contrast, the old borrowing fee system (V1, block-based) in `BorrowingFeesUtils._getBorrowingPendingAccFees` has separate long/short accumulators with different rates based on the net OI direction.

This is a design choice, not a bug. The V2 system is simpler and charges a uniform rate regardless of which side is dominant. The funding fee system (separate from borrowing fees) handles the directional incentive via the velocity model.

### Impact

No security impact. This is a design observation. Both sides paying the same borrowing rate is intentional -- the rate compensates the protocol for capital at risk, regardless of direction. The funding fee system handles skew incentives separately.

---

## Finding 5: `downscaleTradeFeesData` Rounding Analysis -- Conservative But Asymmetric

**Severity: INFORMATIONAL**

**File:** `/root/defi-audit-targets/audits/gains-network/contracts/facets/GNSFundingFees/contracts/libraries/FundingFeesUtils.sol`
**Lines:** 503-576

### Description

The `downscaleTradeFeesData` function (used during collateral decreases to proportionally reduce all fee-related state) uses a mix of rounding strategies:

1. **`realizedTradingFeesCollateral`** (line 517-521): Floor division. Removes LESS of the realized fees, keeping more fees realized. This reduces available collateral -- **conservative** (protocol-favored).

2. **`realizedPnlCollateral`** (line 523-534): Uses `Math.mulDiv` with conditional rounding. When PnL is positive (trader has gains), rounds UP the amount removed, leaving LESS positive PnL. When PnL is negative, rounds DOWN (towards zero), removing LESS of the negative value, keeping more negative PnL. Both directions are **conservative** (protocol-favored).

3. **`manuallyRealizedNegativePnlCollateral`** (line 536-541): Floor division. Removes LESS, keeping more negative PnL tracked. **Conservative**.

4. **`alreadyTransferredNegativePnlCollateral`** (line 543-548): Floor division. Same as above. **Conservative**.

5. **`virtualAvailableCollateralInDiamond`** (line 550-559): `Math.Rounding.Up`. Removes MORE of the virtual collateral, reducing available collateral faster. **Conservative**.

All rounding is consistently biased against the trader and in favor of the protocol. The comment at line 572-574 acknowledges this and uses `storeVirtualAvailableCollateralInDiamond` to compensate for any cases where the rounding causes available collateral to go slightly negative.

### Impact

No security impact. The rounding is consistently conservative and the compensating mechanism handles edge cases. The maximum rounding error per operation is a few wei.

---

## Finding 6: Funding Fee Computation Uses Current OI for Historical Period (By Design)

**Severity: INFORMATIONAL**

**File:** `/root/defi-audit-targets/audits/gains-network/contracts/facets/GNSFundingFees/contracts/libraries/FundingFeesUtils.sol`
**Lines:** 786-810

### Description

The funding fee velocity model computes the current velocity based on the CURRENT net exposure (OI skew), then applies this velocity over the entire elapsed interval since the last update. This means:

- `v.currentVelocityPerYear` is computed from current OI (line 797-803)
- `_getAvgFundingRatePerSecondP` uses this velocity to compute the average rate over the full interval (line 805-810)

If OI changed significantly during the interval (e.g., a large trade opened/closed between updates), the velocity used is the POST-change velocity applied to the PRE-change time period. This is a deliberate design choice common in lazy-update fee models.

The APR multiplier has the same characteristic: the multiplier is computed from current OI (line 830-834, 846-850), not the OI at the time the fees were accruing.

### Impact

No exploitable impact. This is a standard lazy-update pattern used by perpetual DEXes. Any trade that changes OI also triggers an update, so the stale velocity only applies to the interval BEFORE the trade. The approximation error is bounded by the interval length and the OI change magnitude. Frequent updates (every trade) minimize the error.

---

## Finding 7: Old Borrowing Fee (V1) MAX(pair, group) Selection Cannot Be Gamed

**Severity: INFORMATIONAL (Investigated, Not Vulnerable)**

**File:** `/root/defi-audit-targets/audits/gains-network/contracts/facets/GNSBorrowingFees/contracts/libraries/BorrowingFeesUtils.sol`
**Lines:** 281-330

### Description

The `getTradeBorrowingFee` function computes the borrowing fee as the sum of `MAX(pair_delta, group_delta)` over all historical pair-group assignments. The concern was whether a trader could choose a pair that belongs to a group with lower fees to avoid paying the pair-level fee.

**Analysis:** The trader cannot choose which group a pair belongs to -- this is set by governance (`setBorrowingPairParams`). The MAX operation ensures the higher of the two fees always applies. A pair with high pair-level fees and a low group-level fee will still pay the high pair-level fee. Similarly, a pair in a high-fee group with low pair-level fees will pay the group fee.

The group assignment can change during a trade's lifetime (governance action). The `pairGroups` array tracks historical group assignments, and the fee calculation correctly handles transitions by computing the MAX over each historical group period.

### Impact

No exploitable impact. The MAX selection is a security feature, not a vulnerability. Governance controls group assignments, and the trader has no ability to influence which fee tier applies.

---

## Summary

| # | Finding | Severity | Exploitable? |
|---|---------|----------|-------------|
| 1 | Funding fee undercharge during sign-change when rate hits cap | MEDIUM | No active exploit required; occurs naturally on illiquid pairs with aggressive velocity params and APR multiplier enabled. Up to 50% undercharge on period 2 fees. |
| 2 | (Investigated, not a finding) | N/A | N/A |
| 3 | Borrowing fee precision loss for small OI ratios | LOW | Not practically exploitable; threshold too small. |
| 4 | V2 borrowing fee is side-agnostic | INFORMATIONAL | Design choice. |
| 5 | downscaleTradeFeesData conservative rounding | INFORMATIONAL | Favors protocol; well-handled. |
| 6 | Lazy-update velocity uses current OI for historical period | INFORMATIONAL | Standard pattern; bounded error. |
| 7 | MAX(pair, group) selection cannot be gamed | INFORMATIONAL | Secure by design. |

## Areas Verified Safe

The following areas were investigated and confirmed to be correctly implemented:

1. **Integer overflow/underflow in accumulators:** All accumulators (`int128` for funding, `uint128` for borrowing, `uint64` for V1 borrowing) have sufficient range for their respective maximum values over any realistic timeframe. Verified mathematically.

2. **`int40` truncation in `_getCurrentFundingVelocityPerYear`:** The uncapped branch only runs when `absoluteVelocityPerYear <= absoluteVelocityPerYearCap`, and `absoluteVelocityPerYearCap` max (`uint24_max * 1e3 = 1.67e10`) fits well within `int40_max` (`5.49e11`).

3. **`int56` truncation in `_getAvgFundingRatePerSecondP`:** The `ratePerSecondCap` max (`3.17e14` in 1e18 precision) fits within `int56_max` (`3.6e16`).

4. **`secondsToReachZeroRate` underflow:** Cannot exceed `secondsSinceLastUpdate` because both use the same velocity, and integer division truncation only makes `secondsToReachZeroRate` smaller.

5. **Division by zero in APR multiplier:** All zero-OI cases are guarded by ternary checks (lines 1445-1454).

6. **Initial acc fee manipulation:** Computed atomically within the diamond, cannot be front-run.

7. **Borrowing fee exponential overflow:** Maximum intermediate value (`~4.29e70`) fits within `uint256` (`1.15e77`).

8. **Funding fee system balance:** Total paid by majority side equals total earned by minority side (APR multiplier adjusts per-unit rate but preserves total balance).

9. **Partial position changes:** `downscaleTradeFeesData` consistently rounds conservatively (against trader), with `storeVirtualAvailableCollateralInDiamond` compensating for any resulting sub-zero available collateral.

10. **V1/V2 borrowing fee transition:** Both systems contribute independently to total holding fees. No inconsistency or double-counting between the block-based (V1) and time-based (V2) accumulators.
