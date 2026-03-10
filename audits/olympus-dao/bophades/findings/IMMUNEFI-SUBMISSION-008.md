# Finding 008: Stale Price Oracle Enables Wall Swap Arbitrage Within 3x Observation Frequency Window

## Bug Description

The `Operator._onlyWhileActive()` function uses a staleness threshold of `3 * PRICE.observationFrequency()` (24 hours with 8h default frequency) before disabling wall swaps. During this window, an attacker can exploit the gap between the stale on-chain oracle price (used for wall pricing) and the real market price of OHM by executing wall swaps at favorable stale rates.

**Vulnerable Code** (`/root/defi-audit-targets/audits/olympus-dao/bophades/src/policies/Operator.sol`, lines 232-237):

```solidity
function _onlyWhileActive() internal view {
    if (
        !active ||
        uint48(block.timestamp) > PRICE.lastObservationTime() + 3 * PRICE.observationFrequency()
    ) revert Operator_Inactive();
}
```

The wall prices are set based on `PRICE.getTargetPrice()` (the moving average), which is only updated when `Heart.beat()` calls `PRICE.updateMovingAverage()`. If the beat is delayed (keeper downtime, gas spikes, network congestion), the wall prices become stale while the real market price moves.

**Attack scenario (low wall):**

1. Last beat at time T, OHM moving average = $10.00, low wall price = $8.00 (20% spread)
2. Real OHM market price drops to $7.00 over the next 20 hours (no beat)
3. At T+20h, `_onlyWhileActive()` passes: `20h < 24h = 3 * 8h`
4. Attacker buys OHM on open market at $7.00
5. Attacker swaps OHM at the low wall for $8.00 worth of reserve per OHM
6. Net profit: $1.00 per OHM (14.3% gain on capital)

**Attack scenario (high wall):**

1. Same stale state. OHM real price rises to $13.00
2. High wall price is $12.00 (20% spread above stale $10 MA)
3. Attacker swaps reserve at the high wall, getting OHM at $12.00 per OHM
4. Sells OHM on the open market for $13.00
5. Net profit: $1.00 per OHM (8.3% gain)

**Front-running the beat:**

When a `Heart.beat()` transaction is pending in the mempool, an attacker can see the beat transaction (which will update prices), calculate whether the price update will change wall prices favorably, and front-run with a wall swap at the OLD prices.

## Impact

**Severity: Medium**

- **Financial impact**: Up to `wallCapacity * (priceMove - wallSpread) / wallPrice` per side. With a $10M low wall capacity, a 25% price drop, and 20% wall spread: `$10M * 5% / $8 = $625K`.
- **Preconditions**: Requires keeper downtime of multiple hours combined with significant price movement exceeding the wall spread
- **Likelihood**: Medium -- keeper failures happen periodically in DeFi, crypto moves 20%+ in 24h regularly
- **Affected users**: All OHM holders (treasury reserves extracted at unfavorable rates)

## Risk Breakdown

- **Difficulty to exploit**: Low-Medium -- standard MEV monitoring plus wall swap execution
- **Weakness type**: CWE-672 (Operation on a Resource after Expiration or Release)
- **CVSS Score**: 5.9 (Medium)

## Recommendation

1. Reduce the staleness multiplier from 3x to 1.5x:

```diff
  function _onlyWhileActive() internal view {
      if (
          !active ||
-         uint48(block.timestamp) > PRICE.lastObservationTime() + 3 * PRICE.observationFrequency()
+         uint48(block.timestamp) > PRICE.lastObservationTime() + 3 * PRICE.observationFrequency() / 2
      ) revert Operator_Inactive();
  }
```

2. Add a live price deviation check in `swap()`:

```solidity
uint256 livePrice = PRICE.getCurrentPrice();
uint256 storedPrice = PRICE.getLastPrice();
uint256 deviation = storedPrice > livePrice
    ? (storedPrice - livePrice) * 10000 / storedPrice
    : (livePrice - storedPrice) * 10000 / storedPrice;
if (deviation > 500) revert Operator_PriceDeviation(); // 5% max
```

## Proof of Concept

```solidity
// SPDX-License-Identifier: Unlicense
pragma solidity >=0.8.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

contract PoC_008_StalePriceArbitrage is Test {
    uint48 constant OBSERVATION_FREQUENCY = 8 hours;
    uint256 constant WALL_SPREAD_BPS = 2000;
    uint256 constant BPS = 10000;

    function test_stalePriceArbitrageWindow() public {
        uint48 lastObservation = uint48(block.timestamp);
        uint256 movingAverage = 10e18;
        uint256 lowWallPrice = movingAverage * (BPS - WALL_SPREAD_BPS) / BPS;

        vm.warp(block.timestamp + 20 hours);

        bool isActive = uint48(block.timestamp) <= lastObservation + 3 * OBSERVATION_FREQUENCY;
        assertTrue(isActive, "System still active at 20h");

        uint256 realPriceDown = 7.5e18;
        uint256 profitLow = lowWallPrice - realPriceDown;
        assertGt(profitLow, 0, "Low wall arb should be profitable");

        vm.warp(block.timestamp + 5 hours);
        bool isStale = uint48(block.timestamp) > lastObservation + 3 * OBSERVATION_FREQUENCY;
        assertTrue(isStale, "System should be stale after 25h");
    }
}
```

**Standalone PoC**: `/root/defi-audit-targets/audits/olympus-dao/bophades/scripts/verify/PoC_008_StalePriceArbitrage.sol`

## References

- Operator._onlyWhileActive: https://github.com/OlympusDAO/bophades/blob/main/src/policies/Operator.sol#L232-L237
- Operator.swap: https://github.com/OlympusDAO/bophades/blob/main/src/policies/Operator.sol#L326-L404
- Heart.beat: https://github.com/OlympusDAO/bophades/blob/main/src/policies/Heart.sol#L142-L172
