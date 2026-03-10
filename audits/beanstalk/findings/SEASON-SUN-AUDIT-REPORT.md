# Beanstalk Season/Sun System Security Audit Report

**Protocol:** Beanstalk (Immunefi, max bounty $1.1M)
**Scope:** Season advancement (Sunrise), Bean minting, Weather/Temperature, Gauge system, Flood/SOP, Shipment mechanism
**Date:** 2026-03-02

---

## Executive Summary

Audited the complete Sunrise economic flow: deltaB calculation -> case evaluation -> minting -> distribution, plus the Flood/SOP mechanism, incentive rewards, and Gauge system. Identified **1 confirmed vulnerability** (Medium-High) and **10 false positives** with detailed reasoning.

---

## HYPOTHESIS 1: Sunrise MEV/Front-Running (DeltaB Oracle Manipulation)

**Verdict: FALSE POSITIVE**

**Reasoning:**

The deltaB oracle reading used for Bean minting is computed via TWA (Time-Weighted Average) reserves from the Multi-Flow Pump, NOT instantaneous reserves. The flow in `Oracle.stepOracle()` (line 21-27) calls `LibWellMinting.capture()` which calls `twaDeltaB()` which reads `ICumulativePump.readTwaReserves()` using the last snapshot timestamp.

The TWA reserves are resistant to single-block manipulation because:
1. The Multi-Flow Pump uses cumulative reserves over the entire season period (~1 hour).
2. `LibMinting.checkForMaxDeltaB()` caps deltaB at 1% of total Bean supply, limiting the impact of any oracle manipulation.
3. An attacker would need to sustain manipulation across an entire season to meaningfully affect the TWA.

Additionally, the sunrise caller cannot choose WHICH deltaB to use -- it's deterministic based on pump state at call time. Sandwiching the sunrise call does not change the TWA reserves.

---

## HYPOTHESIS 2: Gauge Point Manipulation

**Verdict: FALSE POSITIVE**

**Reasoning:**

Gauge points are calculated in `LibGauge.updateGaugePoints()` based on `depositedBdv` from storage, which is the total BDV of deposits in the Silo. Due to the **Germination** mechanism (2-season delay), any deposits made just before sunrise do NOT immediately count toward `depositedBdv`:

- `endTotalGermination(season, ...)` at line 63 of SeasonFacet only finalizes deposits from `season - 2`.
- Gauge points use `s.sys.silo.balances[token].depositedBdv` which excludes germinating deposits.
- The `defaultGaugePointFunction` in `GaugePointFacet.sol` adjusts gauge points by at most 5e18 per season, with MAX_GAUGE_POINTS capped at 1000e18.

Depositing/withdrawing around season boundaries would not affect gauge points for 2 seasons, and the max adjustment per season is bounded.

---

## HYPOTHESIS 3: Bean Minting Overflow

**Verdict: FALSE POSITIVE**

**Reasoning:**

In `Sun.stepSun()` (line 41-56), deltaB is an `int256`. When deltaB > 0, it's cast to `uint256` for minting:
```solidity
BeanstalkERC20(s.sys.tokens.bean).mint(address(this), uint256(deltaB));
```

DeltaB is bounded by `LibMinting.checkForMaxDeltaB()` which caps it at `totalSupply / 100`. Since Bean is a 6-decimal token:
- Max total supply that fits uint256 is ~1.15e71 Beans
- 1% of that is ~1.15e69, well within uint256 range
- All downstream math uses `LibRedundantMath256` (SafeMath-equivalent) which reverts on overflow

The `setSoil` function uses `SafeCast.toUint128()` which would revert if soil exceeds uint128 -- but since soil is derived from `newHarvestable * 100 / (100 + temp)`, it's always <= deltaB which is bounded at 1% of supply.

---

## HYPOTHESIS 4: SOP/Flood Zero-Slippage Swap -- CONFIRMED MEDIUM-HIGH

**Verdict: CONFIRMED -- Medium-High Severity**

**File:** `/root/defi-audit-targets/audits/beanstalk/Beanstalk/protocol/contracts/libraries/Silo/LibFlood.sol`
**Lines:** 358-365

### Bug Description

The `sopWell()` function performs a swap of Beans for the non-Bean token in a Well with **zero slippage protection**:

```solidity
uint256 amountOut = IWell(wellDeltaB.well).swapFrom(
    BeanstalkERC20(s.sys.tokens.bean),
    sopToken,
    sopBeans,
    0,        // <--- minAmountOut = 0, NO SLIPPAGE PROTECTION
    address(this),
    type(uint256).max
);
```

**Additionally, the deltaB used to determine SOP amounts is based on INSTANTANEOUS (spot) reserves, not TWA reserves.** The `getWellsByDeltaB()` function (line 269) calls `LibDeltaB.currentDeltaB(wells[i])` which calls `IWell(well).getReserves()` -- the current spot reserves, which are trivially manipulable.

### Attack Vector

1. Attacker monitors for conditions where Flood will trigger (raining=true, P>1, pod rate < 5% for 2+ consecutive seasons).
2. Before calling `sunrise()`, attacker front-runs by performing a large swap in the target Well, pushing the Bean price UP (increasing spot deltaB). This makes `currentDeltaB` return a larger positive value than the actual economic imbalance.
3. `calculateSopPerWell()` allocates more beans to flood into the well based on this inflated instantaneous deltaB.
4. `sopWell()` mints the inflated number of Beans and swaps them with `minAmountOut = 0`.
5. The large Bean sell into an already-manipulated pool results in very poor execution, with the attacker's prior position capturing the value.
6. Attacker back-runs by swapping back, profiting from the difference.

The value at risk is the entire `sopBeans` amount for that season's flood. If total deltaB across wells is, say, 100,000 Beans, an attacker could inflate it and extract significant MEV from the zero-slippage swap.

### Impact

- **Severity:** Medium-High
- **Financial Impact:** Value extraction from Stalkholders. The "plenty" (WETH or other non-Bean tokens) distributed to Stalkholders is reduced because the swap executes at a worse rate. MEV bots can sandwich the swap for profit.
- **Affected Users:** All Stalkholders who are entitled to Flood proceeds.
- **Conditions:** Requires Flood state (P>1, pod rate <5%, raining 2+ seasons) — uncommon but natural protocol state.

### Recommendation

1. Use TWA reserves (from Multi-Flow Pump) instead of instantaneous reserves for calculating SOP amounts per well.
2. Set a minimum `amountOut` based on the deltaB and expected exchange rate from the TWA reserves:
```solidity
// Calculate minimum expected output with slippage tolerance
uint256 minAmountOut = expectedAmountFromTwaReserves * 95 / 100; // 5% slippage
uint256 amountOut = IWell(wellDeltaB.well).swapFrom(
    BeanstalkERC20(s.sys.tokens.bean),
    sopToken,
    sopBeans,
    minAmountOut,
    address(this),
    type(uint256).max
);
```

---

## HYPOTHESIS 5: Shipment Routing Exploit

**Verdict: FALSE POSITIVE**

**Reasoning:**

The `ShipmentPlanner` contract is called via `staticcall` (line 105 of LibShipping.sol), so it cannot modify state. The routing is determined by three plan getters: `getBarnPlan`, `getFieldPlan`, `getSiloPlan`, which return fixed points (each 1/3 = 333...e15) and caps based on current protocol state.

- `setShipmentRoutes()` in `Distribution.sol` requires `LibDiamond.enforceIsOwnerOrContract()` -- only governance/diamond owner can change routes.
- The ShipmentPlanner's plan getters are pure/view functions that query Beanstalk state.
- The `LibShipping.ship()` function handles caps properly: if one route hits its cap, excess is redistributed proportionally.
- There is rounding-down on `shipmentAmounts[i] = (beansToShip * shipmentPlans[i].points) / totalPoints`, which could leave a few dust beans unshipped, but this is negligible.

The only potential issue is if `totalPoints == 0` (all plans return 0 points), but in that case `getBeansFromPoints` skips all routes (due to `if (shipmentPlans[i].points == 0) continue`), and the minted Beans remain in the Beanstalk contract. This does not cause loss -- the Beans are simply held by the protocol and accounted for via the `Invariable.fundsSafu` modifier.

---

## HYPOTHESIS 6: Weather/Temperature Gaming

**Verdict: FALSE POSITIVE**

**Reasoning:**

The Temperature adjustment is deterministic based on the case system. An attacker would need to control:
1. deltaB (TWA, not manipulable in one block)
2. Pod Rate (requires changing total Pods vs. Bean supply)
3. Delta Soil Demand (how fast Soil sold out last season)
4. L2SR (requires manipulating TWA liquidity)

The only parameter somewhat gameable is Delta Soil Demand via strategic sowing. However:
- `thisSowTime` only records the FIRST time Soil drops below threshold, not the last (line 181 of LibDibbler: `s.sys.weather.thisSowTime < type(uint32).max` prevents overwriting).
- The maximum temperature change per season is +/-3 (int8 bT), which is a very gradual adjustment.
- Temperature has a floor of 1 (line 133 of Weather.sol: `s.sys.weather.temp = 1`).

The cost of manipulating Soil demand (buying and sowing Beans) is likely greater than the benefit of a marginal Temperature change.

---

## HYPOTHESIS 7: Oracle Manipulation via Well Reserves

**Verdict: FALSE POSITIVE**

**Reasoning:**

Beanstalk uses Multi-Flow Pump for TWA reserves. The pump implements geometric EMA (Exponential Moving Average) with configurable alpha parameter. Key protections:

1. `readTwaReserves()` returns the geometric mean of reserves over the season period, making single-block manipulation ineffective.
2. `readInstantaneousReserves()` is only used for `setSoilBelowPeg()` (which takes the MINIMUM of TWA and instantaneous deltaB), limiting downside.
3. `readCappedReserves()` provides inter-block MEV-resistant reserves for convert operations.
4. `checkForMaxDeltaB()` caps the oracle output at 1% of supply.

**Exception:** The Flood mechanism (Hypothesis 4) uses `currentDeltaB` with spot reserves. This is the actual vulnerability -- see Hypothesis 4.

---

## HYPOTHESIS 8: Incentive Reward Gaming

**Verdict: FALSE POSITIVE**

**Reasoning:**

The incentive reward in `LibIncentive.determineReward()` is based solely on:
1. `s.sys.evaluationParameters.baseReward` -- set by governance
2. `secondsLate` -- how many seconds after the expected sunrise time

Key protections:
- `secondsLate` is capped at 300 seconds (MAX_SECONDS_LATE), giving a maximum multiplier of ~19.79x
- The reward uses a lookup table (if-ladder), not a dynamic calculation, so there's no overflow risk
- Gas prices and ETH prices are NOT used in the calculation (unlike older versions)
- Block timestamps on Arbitrum are provided by the sequencer and cannot be manipulated by users

The max reward is `baseReward * 19.788466`. For a typical baseReward of ~100 Beans (1e8), the max is ~1,979 Beans. This is economically rational: someone who calls sunrise 5 minutes late gets compensated more to incentivize timely calls.

An attacker cannot inflate the reward because:
- They cannot make `secondsLate` larger than actual time elapsed
- They cannot modify `baseReward` without governance authority
- `block.timestamp` is determined by the Arbitrum sequencer, not the caller

---

## HYPOTHESIS 9: Season Boundary Atomicity

**Verdict: FALSE POSITIVE**

**Reasoning:**

The `_gm()` function executes all season-update logic atomically within a single transaction:

```solidity
function _gm(address account, LibTransfer.To mode) private returns (uint256) {
    require(!s.sys.paused, "Season: Paused.");
    require(seasonTime() > s.sys.season.current, "Season: Still current Season.");
    checkSeasonTime();         // prevents multiple sunrises
    uint32 season = stepSeason();  // increments season
    int256 deltaB = stepOracle();  // captures oracle
    LibGerminate.endTotalGermination(season, ...);
    uint256 caseId = calcCaseIdandUpdate(deltaB);  // weather + flood
    LibGauge.stepGauge();      // gauge points
    stepSun(deltaB, caseId);   // mint + ship
    return incentivize(account, mode);  // reward + reset
}
```

Protections:
- `nonReentrant` modifier prevents reentrance during the sunrise transaction
- `checkSeasonTime()` adjusts `s.sys.season.start` to prevent multiple sunrises if multiple periods elapsed
- `stepSeason()` increments `current` to the next season, and the first require checks `seasonTime() > current`
- The paused check and season time check are duplicated (once in `_gm` and once in `checkSeasonTime`), which is redundant but not harmful

There are no race conditions because Ethereum transactions are atomic.

---

## HYPOTHESIS 10: Evaluation Case Selection Gaming

**Verdict: FALSE POSITIVE**

**Reasoning:**

The case selection in `LibEvaluate.evaluateBeanstalk()` is a pure function of four state variables:
1. Pod Rate (debt/supply) -- 4 ranges: Excessively Low/Reasonably Low/Reasonably High/Excessively High
2. Price (deltaB) -- 3 states: P < 1, P > 1, P > excessive threshold
3. Delta Pod Demand -- 3 states: Decreasing/Steady/Increasing
4. LP-to-Supply Ratio -- 4 ranges

This produces 4 * 3 * 3 * 4 = 144 cases. The case thresholds are stored in `EvaluationParameters` which is governance-controlled. An attacker cannot game the case selection without controlling the underlying economic state variables, which require sustained manipulation over entire seasons (not single blocks).

The `evalPrice()` function at line 79 has an interesting "excessive price" check that uses `getTokenBeanPriceFromTwaReserves` -- this is TWA-based, not manipulable.

---

## HYPOTHESIS 11: L2 Block Number Dependency

**Verdict: FALSE POSITIVE (with note)**

**Reasoning:**

Beanstalk uses `LibArbitrum.blockNumber()` which calls `IArbitrumSys(0x64).arbBlockNumber()` to get the Arbitrum L2 block number. This is used in:

1. `stepSeason()` -- stores `sunriseBlock` for Morning Auction temperature scaling
2. `morningTemperature()` in `LibDibbler` -- calculates block delta for temperature scaling

The L2 block time adjustment is handled in `morningTemperature()`:
```solidity
uint256 delta = LibArbitrum.blockNumber()
    .sub(s.sys.season.sunriseBlock)
    .mul(L2_BLOCK_TIME)    // 25
    .div(L1_BLOCK_TIME);   // 1200
```

This scales the L2 block delta down by 25/1200 to approximate L1 behavior. On Arbitrum:
- L2 blocks are ~0.25 seconds
- 1200 seconds / 0.25 seconds = 4800 L2 blocks to reach the equivalent of 25 L1 blocks
- `4800 * 25 / 1200 = 100` -- but temperature maxes out at delta=25

The scaling is conservative and works correctly. The only concern is if Arbitrum block times change significantly, but this is a known operational risk, not a bug.

**Note:** `sunriseBlock` is stored as `uint64`, which will overflow after 2^64 blocks. At 4 blocks/second, this is ~146 billion years -- no practical concern.

---

## RETRACTED FINDING: calculateSopPerWell Division by Zero -- FALSE POSITIVE

**Verdict: FALSE POSITIVE (retracted after mathematical verification)**

**File:** `contracts/libraries/Silo/LibFlood.sol`, Line 429

### Original Hypothesis

The code at line 429 performs `(shaveToLevel - uint256(wellDeltaBs[i - 1].deltaB)) / (i - 1)`. When i=1, this would divide by zero.

### Why It's Unreachable

The guard at line 406 ensures `totalPositiveDeltaB >= totalNegativeDeltaB`. Under this constraint, the accumulated shaveToLevel at i=1 can NEVER exceed wellDeltaBs[0].deltaB (the largest positive deltaB).

**Proof:** For k positive wells, the total redistribution across all wells is bounded by totalNeg. Since each well absorbs at most its own deltaB, the remainder for well 0 is at most `totalNeg - sum(deltaBs for wells 1..k-1) = totalNeg - (totalPos - d_0)`. For the trigger we need `totalNeg - totalPos + d_0 > d_0`, which requires `totalNeg > totalPos` — contradicting the guard.

The example `[+20, +1, -30]` from the original analysis has totalPos=21, totalNeg=30, which FAILS the guard at line 406 (21 < 30 → returns zeros). Integer truncation from Solidity's floor division only reduces values, strengthening the bound.

**Note:** Lines 416-421 contain unreachable dead code (duplicate condition already checked at line 406).

---

## Additional Observations (Informational)

### OBS-1: Redundant Season Checks in `_gm()`

`_gm()` at lines 58-60 performs two require checks (paused, season time) and then calls `checkSeasonTime()` which repeats both checks. This wastes gas but is not a vulnerability.

### OBS-2: Flood Uses Spot DeltaB for SOP Amount Calculation

As detailed in Hypothesis 4, `getWellsByDeltaB()` uses `LibDeltaB.currentDeltaB()` which reads instantaneous reserves. While the TWA deltaB is positive (otherwise Flood wouldn't trigger), the per-well allocation of SOP beans uses manipulable spot prices. This is the core of the Hypothesis 4 vulnerability.

### OBS-3: ShipmentPlanner Points Don't Sum to 1e18

Each of the three shipment recipients (Barn, Field, Silo) gets `333_333_333_333_333_333` points. The sum is `999_999_999_999_999_999`, not `1e18`. This means 1 wei of precision is lost per Bean minted. Over billions of Beans this is negligible.

### OBS-4: `floodPodline()` Mints Beans Before SOP Swap

In `handleRain()`, `floodPodline()` (which mints 0.1% of supply as beans) executes BEFORE the SOP well swaps. This slightly inflates total supply before the `maxDeltaB` cap is calculated for the next season, but since Flood and minting happen in the same transaction, this has no practical impact.

### OBS-5: Duplicate Dead Code in calculateSopPerWell

Lines 416-421 contain a duplicate check `if (totalPositiveDeltaB < totalNegativeDeltaB)` that is unreachable because the same condition is already handled at line 406. This is dead code.

---

## Summary Table

| # | Hypothesis | Verdict | Severity |
|---|-----------|---------|----------|
| 1 | Sunrise MEV/front-running | FALSE POSITIVE | N/A |
| 2 | Gauge point manipulation | FALSE POSITIVE | N/A |
| 3 | Bean minting overflow | FALSE POSITIVE | N/A |
| 4 | **SOP/Flood zero-slippage** | **CONFIRMED** | **Medium-High** |
| 5 | Shipment routing exploit | FALSE POSITIVE | N/A |
| 6 | Weather/Temperature gaming | FALSE POSITIVE | N/A |
| 7 | Oracle manipulation via Well reserves | FALSE POSITIVE | N/A |
| 8 | Incentive reward gaming | FALSE POSITIVE | N/A |
| 9 | Season boundary atomicity | FALSE POSITIVE | N/A |
| 10 | Evaluation case selection gaming | FALSE POSITIVE | N/A |
| 11 | L2 block.number dependency | FALSE POSITIVE | N/A |
| -- | calculateSopPerWell div-by-zero | FALSE POSITIVE (retracted) | N/A |
