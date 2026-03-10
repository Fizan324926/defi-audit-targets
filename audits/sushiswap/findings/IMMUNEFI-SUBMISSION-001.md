# Immunefi Bug Report: CLMigrator Incorrect amount1Consumed Calculation

## Bug Description

In `CLMigrator._addLiquidityToTargetPool()`, when the position's tick range is entirely below the current pool price (`activeTick >= tickUpper`), the `amount1Consumed` calculation incorrectly uses `sqrtPriceX96` (the current pool price) instead of `sqrtRatioBX96` (the upper tick boundary of the position).

### Vulnerable Code

**File:** `v4-periphery/src/pool-cl/CLMigrator.sol` (lines 143-151)

```solidity
// Calculate amt0/amt1 from liquidity, similar to CLPool modifyLiquidity logic
if (activeTick < params.tickLower) {
    amount0Consumed = SqrtPriceMath.getAmount0Delta(sqrtRatioAX96, sqrtRatioBX96, liquidity, true);
} else if (activeTick < params.tickUpper) {
    amount0Consumed = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtRatioBX96, liquidity, true);
    amount1Consumed = SqrtPriceMath.getAmount1Delta(sqrtRatioAX96, sqrtPriceX96, liquidity, true);
} else {
    // BUG: Uses sqrtPriceX96 instead of sqrtRatioBX96
    amount1Consumed = SqrtPriceMath.getAmount1Delta(sqrtRatioAX96, sqrtPriceX96, liquidity, true);
}
```

### Correct Code (from CLPool.modifyLiquidity, lines 129-134)

```solidity
} else {
    // current tick is above the passed range
    amount1 = SqrtPriceMath.getAmount1Delta(
        TickMath.getSqrtRatioAtTick(tickLower), TickMath.getSqrtRatioAtTick(tickUpper), liquidityDelta
    ).toInt128();
}
```

The correct calculation uses `sqrtRatioBX96` (derived from `tickUpper`), not `sqrtPriceX96` (the current price).

### Call Chain

1. User calls `CLMigrator.migrateFromV2()` or `CLMigrator.migrateFromV3()`
2. These call `_addLiquidityToTargetPool()`
3. The function reads `sqrtPriceX96` and `activeTick` from the pool
4. When `activeTick >= tickUpper` (position entirely below current price), it calculates `amount1Consumed` using `sqrtPriceX96` instead of `sqrtRatioBX96`
5. Since `sqrtPriceX96 > sqrtRatioBX96` in this case, `getAmount1Delta(sqrtRatioAX96, sqrtPriceX96, ...)` > `getAmount1Delta(sqrtRatioAX96, sqrtRatioBX96, ...)`
6. The inflated `amount1Consumed` causes incorrect refund calculation:
   ```solidity
   if (amount1In > amount1Consumed) {
       v4PoolParams.poolKey.currency1.transfer(v4PoolParams.recipient, amount1In - amount1Consumed);
   }
   ```
7. User receives a smaller refund (or no refund) for token1 -- the difference remains trapped in the CLMigrator contract

## Impact

**Severity: Medium**

- **Financial impact:** Users migrating positions that are entirely below the current price (out-of-range on the token1 side) will lose a portion of their token1 due to inflated `amount1Consumed` calculation. The loss amount equals `getAmount1Delta(sqrtRatioAX96, sqrtPriceX96) - getAmount1Delta(sqrtRatioAX96, sqrtRatioBX96)`, which grows with the price gap between `sqrtPriceX96` and `sqrtRatioBX96`.

- **Affected users:** Any user migrating an out-of-range position from V2/V3 to V4 where the position's tick range is entirely below the current pool price.

- **Stuck funds:** The unrefunded tokens remain in the CLMigrator contract with no recovery mechanism for the specific user (only the general `refundETH()` for native ETH exists, and there is no ERC20 sweep function).

- **Likelihood:** Moderate -- out-of-range positions are common in concentrated liquidity, especially during volatile market conditions.

## Risk Breakdown

- **Difficulty to exploit:** Low (any migration of an out-of-range position triggers this)
- **Weakness type:** CWE-682 (Incorrect Calculation)
- **CVSS:** 5.3 (Medium) -- Availability/Integrity impact with no authentication required

## Recommendation

Replace `sqrtPriceX96` with `sqrtRatioBX96` in the else branch:

```diff
} else {
-    amount1Consumed = SqrtPriceMath.getAmount1Delta(sqrtRatioAX96, sqrtPriceX96, liquidity, true);
+    amount1Consumed = SqrtPriceMath.getAmount1Delta(sqrtRatioAX96, sqrtRatioBX96, liquidity, true);
}
```

Additionally, consider adding an ERC20 sweep function to the CLMigrator to recover any accidentally trapped tokens.

## Proof of Concept

The following demonstrates the calculation discrepancy. In a real PoC, this would be a Foundry test that:

1. Creates a V4 CL pool with a price at tick 1000
2. Migrates a V2 position with tick range [0, 500] (entirely below current price)
3. Shows that amount1Consumed is inflated because sqrtPriceX96(tick=1000) > sqrtRatioBX96(tick=500)
4. Shows that the user receives less refund than expected

```solidity
// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {SqrtPriceMath} from "v4-core/src/pool-cl/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/src/pool-cl/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/src/pool-cl/libraries/LiquidityAmounts.sol";

contract CLMigratorBugPoC is Test {
    function test_incorrectAmount1Consumed() public pure {
        // Setup: pool at tick 1000, position range [0, 500]
        int24 activeTick = 1000;
        int24 tickLower = 0;
        int24 tickUpper = 500;

        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(activeTick);
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);

        // Position is entirely below current price (activeTick >= tickUpper)
        assert(activeTick >= tickUpper);
        // Therefore sqrtPriceX96 > sqrtRatioBX96
        assert(sqrtPriceX96 > sqrtRatioBX96);

        uint128 liquidity = 1e18;

        // BUGGY calculation (uses sqrtPriceX96)
        uint256 amount1Consumed_buggy = SqrtPriceMath.getAmount1Delta(
            sqrtRatioAX96, sqrtPriceX96, liquidity, true
        );

        // CORRECT calculation (uses sqrtRatioBX96)
        uint256 amount1Consumed_correct = SqrtPriceMath.getAmount1Delta(
            sqrtRatioAX96, sqrtRatioBX96, liquidity, true
        );

        // The buggy calculation is LARGER, meaning less refund to user
        assert(amount1Consumed_buggy > amount1Consumed_correct);

        // The difference is the amount of token1 the user loses
        uint256 userLoss = amount1Consumed_buggy - amount1Consumed_correct;
        assert(userLoss > 0);

        // Log the values for verification
        // amount1Consumed_buggy uses price range [tick 0 -> tick 1000] instead of [tick 0 -> tick 500]
        // This approximately doubles the amount for small tick values
    }
}
```

## References

- Vulnerable code: https://github.com/nicefutures/v4-periphery/blob/main/src/pool-cl/CLMigrator.sol#L143-L151
- Correct reference implementation (CLPool.modifyLiquidity): https://github.com/nicefutures/v4-core/blob/main/src/pool-cl/libraries/CLPool.sol#L129-L134
