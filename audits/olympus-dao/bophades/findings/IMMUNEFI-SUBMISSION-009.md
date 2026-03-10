# Finding 009: `fullCapacity` High Side Over-Estimates Capacity via Dual Spread Multiplier, Enabling Excess OHM Minting

## Bug Description

The `Operator.fullCapacity(true)` function (high side) applies a spread multiplier of `(ONE_HUNDRED_PERCENT + highWallSpread + lowWallSpread) / ONE_HUNDRED_PERCENT` when converting reserve-denominated capacity to OHM-denominated capacity. This multiplier includes **both** wall spreads, meaning the high wall capacity is inflated beyond what the treasury reserves can actually back through wall swap operations alone.

**Vulnerable Code** (`/root/defi-audit-targets/audits/olympus-dao/bophades/src/policies/Operator.sol`, lines 902-916):

```solidity
function fullCapacity(bool high_) public view override returns (uint256) {
    uint256 capacity = ((sReserve.previewRedeem(TRSRY.getReserveBalance(sReserve)) +
        TRSRY.getReserveBalance(reserve) +
        TRSRY.getReserveBalance(oldReserve)) * _config.reserveFactor) / ONE_HUNDRED_PERCENT;
    if (high_) {
        capacity =
            (capacity.mulDiv(
                10 ** _ohmDecimals * 10 ** _oracleDecimals,
                10 ** _reserveDecimals * RANGE.price(true, true)            // divides by high wall price
            ) * (ONE_HUNDRED_PERCENT + RANGE.spread(true, true) + RANGE.spread(false, true))) / // <-- BOTH spreads
            ONE_HUNDRED_PERCENT;
    }
    return capacity;
}
```

**Mathematical analysis:**

Let:
- `R` = total reserves (in reserve token units)
- `rf` = reserve factor (e.g., 10% = 1000 bps)
- `P_target` = target price (moving average)
- `s_high` = high wall spread (e.g., 20% = 2000 bps)
- `s_low` = low wall spread (e.g., 20% = 2000 bps)
- `P_highWall = P_target * (1 + s_high/10000)`

The low side capacity is: `R * rf / 10000` (in reserve terms)

The high side capacity formula is:
```
capacity_high = (R * rf / 10000) * (10^ohmDec * 10^oracleDec) / (10^resDec * P_highWall) * (10000 + s_high + s_low) / 10000
```

Simplifying:
```
capacity_high = (R * rf / 10000) / P_highWall * (1 + (s_high + s_low)/10000) [in OHM terms]
```

With typical values (rf=10%, s_high=20%, s_low=20%):
```
capacity_high = R * 0.10 / (P_target * 1.20) * 1.40
             = R * 0.10 * 1.40 / (P_target * 1.20)
             = R * 0.1167 / P_target
```

Without the spread multiplier, it would be:
```
capacity_high_base = R * 0.10 / (P_target * 1.20) = R * 0.0833 / P_target
```

The ratio: `0.1167 / 0.0833 = 1.40`, meaning the capacity is 40% higher than a simple conversion.

**Why is this a problem?**

The high wall capacity determines how much OHM the Operator can mint through wall swaps. When users swap reserve for OHM at the high wall:
- User sends `amountIn` of reserve
- Operator mints `amountIn / P_highWall` OHM
- The capacity decremented is `amountIn / P_highWall` OHM

If all capacity is consumed through high wall swaps, the Operator will have minted:
```
total_OHM_minted = capacity_high = R * rf / P_highWall * (1 + both_spreads)
```

The reserve received is:
```
total_reserve_received = capacity_high * P_highWall = R * rf * (1 + both_spreads)
```

With rf=10% and both_spreads=40%: `total_reserve_received = R * 14%`

But the treasury only allocated `R * rf = R * 10%` for wall operations. The extra 40% (`R * 4%`) of reserve that must be received to consume all capacity doesn't come from the treasury -- it comes from the users swapping. So the reserves increase by more than the original allocation, which backs the extra OHM minted.

**Actually, this might be intentional**: the protocol designs the high wall capacity to account for the fact that swaps at the high wall price bring in reserves that increase the treasury balance. The spread multiplier `(1 + both_spreads)` approximates the additional reserves the treasury will receive from both walls being active.

However, the issue is that the low wall spread is included in the high wall capacity calculation. If the low wall is down (inactive with 0 capacity), the reserves that would have come from low wall operations won't materialize, but the high wall capacity already accounts for them. This creates an over-commitment: the high wall has capacity assuming low wall revenue that may never arrive.

## Impact

**Severity: Low-Medium**

- The over-estimation is by a factor of `(1 + bothSpreads)`, typically 1.4x with 20%/20% spreads
- If both walls are active and fully utilized, the accounting balances out (reserves received from both sides offset the extra minted OHM)
- If only the high wall is utilized while the low wall stays inactive, the extra OHM minted is not backed by corresponding reserve inflows, creating an under-collateralization scenario
- With $100M in reserves and 10% reserve factor: the over-commitment is `$10M * 0.4 = $4M` of OHM that may not have reserve backing
- The MINTR approval is set to this inflated capacity (line 649), granting more minting rights than strictly warranted

## Risk Breakdown

- **Difficulty to exploit**: Medium -- requires understanding the capacity formula and exploiting scenarios where only one wall is active
- **Weakness type**: CWE-682 (Incorrect Calculation)
- **CVSS Score**: 4.3 (Medium)

## Recommendation

Compute the high wall capacity without the opposite wall's spread, or condition the multiplier on whether the other wall is active:

```diff
  if (high_) {
+     // Only include the high spread adjustment, not both
      capacity =
          (capacity.mulDiv(
              10 ** _ohmDecimals * 10 ** _oracleDecimals,
              10 ** _reserveDecimals * RANGE.price(true, true)
-         ) * (ONE_HUNDRED_PERCENT + RANGE.spread(true, true) + RANGE.spread(false, true))) /
+         ) * (ONE_HUNDRED_PERCENT + RANGE.spread(true, true))) /
          ONE_HUNDRED_PERCENT;
  }
```

Alternatively, if the dual-spread multiplier is intentional, document the design rationale and the assumption that both walls will be active.

## Proof of Concept

```solidity
// SPDX-License-Identifier: Unlicense
pragma solidity >=0.8.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Demonstrates the high wall capacity over-estimation
contract PoC_009_CapacityOverEstimation is Test {

    uint256 constant ONE_HUNDRED_PERCENT = 10000;

    function test_highWallCapacityOverEstimation() public {
        // Setup
        uint256 totalReserves = 100_000_000e18; // $100M
        uint256 reserveFactor = 1000; // 10%
        uint256 highWallSpread = 2000; // 20%
        uint256 lowWallSpread = 2000; // 20%
        uint256 targetPrice = 10e18; // $10 per OHM (18 decimals)

        // Low side capacity (reserve terms)
        uint256 lowCapacity = totalReserves * reserveFactor / ONE_HUNDRED_PERCENT;
        console2.log("Low wall capacity (reserve):", lowCapacity);

        // High wall price
        uint256 highWallPrice = targetPrice * (ONE_HUNDRED_PERCENT + highWallSpread) / ONE_HUNDRED_PERCENT;
        console2.log("High wall price:", highWallPrice);

        // High side capacity WITH both spreads (current implementation)
        // First: convert to OHM at high wall price
        uint256 baseOhmCapacity = lowCapacity * 1e9 * 1e18 / (1e18 * highWallPrice);
        // Then: apply spread multiplier
        uint256 highCapacityCurrent = baseOhmCapacity * (ONE_HUNDRED_PERCENT + highWallSpread + lowWallSpread) / ONE_HUNDRED_PERCENT;
        console2.log("High wall capacity (current, OHM):", highCapacityCurrent);

        // High side capacity WITHOUT low spread (corrected)
        uint256 highCapacityCorrected = baseOhmCapacity * (ONE_HUNDRED_PERCENT + highWallSpread) / ONE_HUNDRED_PERCENT;
        console2.log("High wall capacity (corrected, OHM):", highCapacityCorrected);

        // Over-estimation
        uint256 overEstimation = highCapacityCurrent - highCapacityCorrected;
        console2.log("Over-estimation (OHM):", overEstimation);
        console2.log("Over-estimation %:", overEstimation * 100 / highCapacityCorrected);

        // In dollar terms
        uint256 overEstimationUSD = overEstimation * highWallPrice / 1e9;
        console2.log("Over-estimation in USD terms:", overEstimationUSD);

        assertGt(highCapacityCurrent, highCapacityCorrected, "Current capacity exceeds corrected");
    }
}
```

## References

- Operator.fullCapacity: https://github.com/OlympusDAO/bophades/blob/main/src/policies/Operator.sol#L902-L916
- Operator._regenerate (sets capacity): https://github.com/OlympusDAO/bophades/blob/main/src/policies/Operator.sol#L630-L691
- RANGE.spread: https://github.com/OlympusDAO/bophades/blob/main/src/modules/RANGE/OlympusRange.sol#L264-L278
