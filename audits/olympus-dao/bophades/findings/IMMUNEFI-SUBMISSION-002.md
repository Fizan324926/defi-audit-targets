# Immunefi Bug Report: EmissionManager `_updateBacking` Precision Loss via Integer Division

## Bug Description

The `EmissionManager._updateBacking()` function calculates the new backing price using percentage-based arithmetic that suffers from precision loss through sequential integer divisions. The calculation computes `percentIncreaseReserves` and `percentIncreaseSupply` as separate divisions, then divides one by the other. Each division truncates, compounding precision loss.

### Vulnerable Code

**File:** `src/policies/EmissionManager.sol`

**Lines 449-464:**
```solidity
function _updateBacking(uint256 supplyAdded, uint256 reservesAdded) internal {
    uint256 previousReserves = getReserves();
    uint256 previousSupply = getSupply();

    uint256 percentIncreaseReserves = ((previousReserves + reservesAdded) *
        10 ** _reserveDecimals) / previousReserves;
    uint256 percentIncreaseSupply = ((previousSupply + supplyAdded) * 10 ** _reserveDecimals) /
        previousSupply; // scaled to reserve decimals to match

    backing =
        (backing * percentIncreaseReserves) / // price multiplied by percent increase reserves in reserve scale
        percentIncreaseSupply; // divided by percent increase supply in reserve scale

    // Emit event to track backing changes and results of sales offchain
    emit BackingUpdated(backing, supplyAdded, reservesAdded);
}
```

### Precision Loss Analysis

The mathematically correct formula for the new backing is:

```
new_backing = backing * (previousReserves + reservesAdded) / previousReserves
                      * previousSupply / (previousSupply + supplyAdded)
```

Which simplifies to:
```
new_backing = backing * (previousReserves + reservesAdded) * previousSupply
              / (previousReserves * (previousSupply + supplyAdded))
```

However, the implementation computes two intermediate ratios, each of which truncates:

1. `percentIncreaseReserves = ((R + dR) * 1e18) / R`  -- truncation #1
2. `percentIncreaseSupply = ((S + dS) * 1e18) / S`  -- truncation #2
3. `backing = (backing * percentIncreaseReserves) / percentIncreaseSupply`  -- truncation #3

Each truncation loses up to 1 unit of the least significant digit. With `_reserveDecimals = 18`, the scaling provides adequate precision for individual operations, but the compound error across three sequential divisions can accumulate.

### Critical Edge Case: Supply Increase > Reserve Increase

When `percentIncreaseSupply > percentIncreaseReserves` (which happens when OHM is sold at a price close to backing), the final division truncates downward. This means **backing is rounded down** each time. Over many callback cycles, this creates a systematic downward bias in the `backing` variable.

Since `backing` directly determines:
- The minimum price for bond markets (`_createMarket` line 408)
- The premium calculation (`getPremium` line 724)
- The emission rate (`getNextEmission`)

A systematically decreasing `backing` value leads to:
- Lower minimum prices for bond markets, allowing OHM to be purchased at below-true-backing prices
- Higher premiums being reported (since price/backing increases as backing decreases)
- Higher emission rates, causing more OHM to enter circulation

### Quantified Impact

With reserve decimals = 18, worst-case truncation per operation is 1 wei in 18-decimal scale. However:
- `backing * percentIncreaseReserves` can overflow into very large numbers (backing is ~11e18, percentIncreaseReserves is ~1e18), and the final division by `percentIncreaseSupply` (also ~1e18) means the truncation error is in the `backing` scale
- Each callback truncates `backing` by up to 1 wei (in reserve-decimal scale)
- With daily callbacks and multiple bond purchases per day, this accumulates to ~365 wei/year per callback
- Over years, with thousands of callbacks, the drift could become material

## Impact

**Severity: Low-Medium (Informational/Low)**

The precision loss is small per operation (1 wei in 18-decimal scale) but is systematic and always in one direction (downward). Over long time horizons with many callbacks, the cumulative effect creates a backing value that is lower than reality, causing:
- Slightly higher emission rates than intended
- Slightly lower bond market minimum prices
- Gradual dilution of protocol value

The impact is primarily theoretical at short time horizons but compounds over the lifetime of the protocol.

## Risk Breakdown

- **Difficulty to exploit:** High -- requires natural protocol operation over extended periods; cannot be directly triggered by an attacker
- **Weakness type:** CWE-682 (Incorrect Calculation)
- **CVSS:** 3.7 (Low)

## Recommendation

Use `FullMath.mulDiv` to perform the computation in a single step, avoiding intermediate truncation:

```diff
  function _updateBacking(uint256 supplyAdded, uint256 reservesAdded) internal {
      uint256 previousReserves = getReserves();
      uint256 previousSupply = getSupply();

-     uint256 percentIncreaseReserves = ((previousReserves + reservesAdded) *
-         10 ** _reserveDecimals) / previousReserves;
-     uint256 percentIncreaseSupply = ((previousSupply + supplyAdded) * 10 ** _reserveDecimals) /
-         previousSupply;
-
-     backing =
-         (backing * percentIncreaseReserves) /
-         percentIncreaseSupply;
+     // Single-step calculation to minimize precision loss
+     // new_backing = old_backing * (R + dR) * S / (R * (S + dS))
+     backing = backing.mulDiv(
+         (previousReserves + reservesAdded) * previousSupply,
+         previousReserves * (previousSupply + supplyAdded)
+     );

      emit BackingUpdated(backing, supplyAdded, reservesAdded);
  }
```

Note: Overflow protection should be considered for the intermediate multiplications, potentially using FullMath's 512-bit intermediate representation.

## Proof of Concept

```solidity
// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.15;

import "forge-std/Test.sol";

contract PoC_002_BackingPrecision is Test {
    uint256 constant RESERVE_DECIMALS = 18;

    function test_precisionLossInBacking() public {
        // Initial state
        uint256 backing = 11_33e16; // $11.33 in 18 decimals
        uint256 previousReserves = 100_000_000e18; // $100M reserves
        uint256 previousSupply = 8_000_000e9; // 8M OHM (9 decimals)

        // Small bond purchase: 100 OHM sold, 1200 DAI received
        uint256 supplyAdded = 100e9; // 100 OHM
        uint256 reservesAdded = 1200e18; // $1200

        // Current implementation (3 divisions)
        uint256 percentIncreaseReserves = ((previousReserves + reservesAdded) *
            10 ** RESERVE_DECIMALS) / previousReserves;
        uint256 percentIncreaseSupply = ((previousSupply + supplyAdded) *
            10 ** RESERVE_DECIMALS) / previousSupply;

        uint256 backingCurrent = (backing * percentIncreaseReserves) / percentIncreaseSupply;

        // Ideal calculation (single step, higher precision)
        // new_backing = backing * (R + dR) / R * S / (S + dS)
        // Using larger intermediate values for precision
        uint256 numerator = backing * (previousReserves + reservesAdded);
        uint256 denominator = previousReserves;
        uint256 intermediate = numerator / denominator;
        uint256 backingIdeal = (intermediate * previousSupply) / (previousSupply + supplyAdded);

        // Log the difference
        emit log_named_uint("Backing (current impl)", backingCurrent);
        emit log_named_uint("Backing (ideal)", backingIdeal);

        if (backingIdeal > backingCurrent) {
            emit log_named_uint("Precision loss (wei)", backingIdeal - backingCurrent);
        }

        // Show that over many iterations, the bias accumulates
        uint256 backingA = backing;
        uint256 backingB = backing;
        for (uint256 i = 0; i < 100; i++) {
            // Current implementation
            uint256 pir = ((previousReserves + reservesAdded) * 10 ** RESERVE_DECIMALS) /
                previousReserves;
            uint256 pis = ((previousSupply + supplyAdded) * 10 ** RESERVE_DECIMALS) /
                previousSupply;
            backingA = (backingA * pir) / pis;

            // Better implementation
            backingB = (backingB * (previousReserves + reservesAdded) * previousSupply) /
                (previousReserves * (previousSupply + supplyAdded));

            previousReserves += reservesAdded;
            previousSupply += supplyAdded;
        }

        emit log_named_uint("Backing after 100 callbacks (current)", backingA);
        emit log_named_uint("Backing after 100 callbacks (better)", backingB);

        if (backingB > backingA) {
            emit log_named_uint("Accumulated drift (wei)", backingB - backingA);
        }
    }
}
```

## References

- [EmissionManager.sol - _updateBacking](https://github.com/OlympusDAO/bophades/blob/main/src/policies/EmissionManager.sol#L449-L464)
- [EmissionManager.sol - callback](https://github.com/OlympusDAO/bophades/blob/main/src/policies/EmissionManager.sol#L374-L397)
