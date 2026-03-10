// SPDX-License-Identifier: Unlicense
pragma solidity >=0.8.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Demonstrates the stale price arbitrage window in Operator
/// @dev Run with: forge test --match-test test_stalePriceArbitrageWindow -vv
contract PoC_008_StalePriceArbitrage is Test {

    uint48 constant OBSERVATION_FREQUENCY = 8 hours;
    uint256 constant WALL_SPREAD_BPS = 2000; // 20%
    uint256 constant BPS = 10000;

    function test_stalePriceArbitrageWindow() public {
        uint48 lastObservation = uint48(block.timestamp);
        uint256 movingAverage = 10e18;
        uint256 lowWallPrice = movingAverage * (BPS - WALL_SPREAD_BPS) / BPS;
        uint256 highWallPrice = movingAverage * (BPS + WALL_SPREAD_BPS) / BPS;

        console2.log("Moving average (stale):", movingAverage);
        console2.log("Low wall price:", lowWallPrice);
        console2.log("High wall price:", highWallPrice);

        // 20 hours pass without a beat
        vm.warp(block.timestamp + 20 hours);

        bool isActive = uint48(block.timestamp) <= lastObservation + 3 * OBSERVATION_FREQUENCY;
        assertTrue(isActive, "System still active at 20h");

        // OHM dumps 25%
        uint256 realPriceDown = 7.5e18;
        uint256 profitLow = lowWallPrice - realPriceDown;
        console2.log("LOW WALL ARB: buy at", realPriceDown, "sell to wall at", lowWallPrice);
        console2.log("Profit per OHM:", profitLow);
        assertGt(profitLow, 0);

        // OHM pumps 30%
        uint256 realPriceUp = 13e18;
        uint256 profitHigh = realPriceUp - highWallPrice;
        console2.log("HIGH WALL ARB: buy from wall at", highWallPrice, "sell at", realPriceUp);
        console2.log("Profit per OHM:", profitHigh);
        assertGt(profitHigh, 0);

        // At 25h, system should deactivate
        vm.warp(block.timestamp + 5 hours);
        bool isStale = uint48(block.timestamp) > lastObservation + 3 * OBSERVATION_FREQUENCY;
        assertTrue(isStale);
    }
}
