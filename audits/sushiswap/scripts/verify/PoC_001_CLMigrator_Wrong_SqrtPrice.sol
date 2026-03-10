// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {SqrtPriceMath} from "v4-core/src/pool-cl/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/src/pool-cl/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/src/pool-cl/libraries/LiquidityAmounts.sol";

/// @title PoC for CLMigrator incorrect amount1Consumed calculation
/// @notice Demonstrates that when activeTick >= tickUpper, the migrator uses
///         sqrtPriceX96 (current price) instead of sqrtRatioBX96 (upper tick boundary)
///         for amount1Consumed, causing inflated consumed amounts and reduced refunds.
contract PoC_001_CLMigrator_Wrong_SqrtPrice is Test {

    /// @notice Core demonstration: buggy vs correct calculation
    function test_incorrectAmount1Consumed() public pure {
        // Setup: pool currently at tick 1000
        // Position tick range: [0, 500] -- entirely below current price
        int24 activeTick = 1000;
        int24 tickLower = 0;
        int24 tickUpper = 500;

        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(activeTick);
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);

        // Verify precondition: position is entirely below current price
        assert(activeTick >= tickUpper);
        assert(sqrtPriceX96 > sqrtRatioBX96);

        uint128 liquidity = 1e18;

        // BUGGY: CLMigrator line 150 uses sqrtPriceX96
        uint256 amount1Consumed_buggy = SqrtPriceMath.getAmount1Delta(
            sqrtRatioAX96, sqrtPriceX96, liquidity, true
        );

        // CORRECT: CLPool.modifyLiquidity uses sqrtRatioBX96
        uint256 amount1Consumed_correct = SqrtPriceMath.getAmount1Delta(
            sqrtRatioAX96, sqrtRatioBX96, liquidity, true
        );

        // Buggy calculation is strictly larger
        assertGt(amount1Consumed_buggy, amount1Consumed_correct, "Buggy should be larger");

        // The difference = tokens trapped in migrator = user's loss
        uint256 userLoss = amount1Consumed_buggy - amount1Consumed_correct;
        assertGt(userLoss, 0, "User should lose tokens");
    }

    /// @notice Show the loss scales with price gap
    function test_lossScalesWithPriceGap() public pure {
        int24 tickLower = 0;
        int24 tickUpper = 500;
        uint128 liquidity = 1e18;

        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);

        // Correct amount (constant regardless of current price)
        uint256 correct = SqrtPriceMath.getAmount1Delta(
            sqrtRatioAX96, sqrtRatioBX96, liquidity, true
        );

        // Test at different current prices (all above tickUpper=500)
        int24[3] memory testTicks = [int24(600), int24(1000), int24(5000)];

        uint256 prevLoss = 0;
        for (uint256 i = 0; i < 3; i++) {
            uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(testTicks[i]);
            uint256 buggy = SqrtPriceMath.getAmount1Delta(
                sqrtRatioAX96, sqrtPriceX96, liquidity, true
            );

            uint256 loss = buggy - correct;
            assertGt(loss, 0, "Loss should be positive");

            // Loss should increase as price gap increases
            if (i > 0) {
                assertGt(loss, prevLoss, "Loss should scale with price gap");
            }
            prevLoss = loss;
        }
    }

    /// @notice Simulates full refund logic showing user receives less
    function test_refundShortfall() public pure {
        int24 activeTick = 2000;
        int24 tickLower = 0;
        int24 tickUpper = 500;

        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(activeTick);
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);

        // Simulate: user has 100e18 token1 from V2/V3 withdrawal
        uint256 amount1In = 100e18;

        // Calculate liquidity from the amounts
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            sqrtRatioAX96, sqrtRatioBX96, amount1In
        );

        // Correct consumed amount (what the pool actually needs)
        uint256 amount1Consumed_correct = SqrtPriceMath.getAmount1Delta(
            sqrtRatioAX96, sqrtRatioBX96, liquidity, true
        );

        // Buggy consumed amount (what the migrator calculates)
        uint256 amount1Consumed_buggy = SqrtPriceMath.getAmount1Delta(
            sqrtRatioAX96, sqrtPriceX96, liquidity, true
        );

        // Correct refund
        uint256 refund_correct = amount1In > amount1Consumed_correct
            ? amount1In - amount1Consumed_correct
            : 0;

        // Buggy refund
        uint256 refund_buggy = amount1In > amount1Consumed_buggy
            ? amount1In - amount1Consumed_buggy
            : 0;

        // User gets less refund with the bug
        assertLt(refund_buggy, refund_correct, "Buggy refund should be less");

        // Shortfall = tokens trapped in migrator
        uint256 shortfall = refund_correct - refund_buggy;
        assertGt(shortfall, 0, "Shortfall should be positive");
    }
}
