// SPDX-License-Identifier: Unlicense
pragma solidity >=0.8.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Demonstrates predictability of Heart.beat() price updates
/// @dev Run with: forge test --match-test test_predictMovingAverageShift -vv
contract PoC_010_HeartBeatFrontRun is Test {

    uint256 constant NUM_OBSERVATIONS = 90;
    uint256 constant WALL_SPREAD = 2000;
    uint256 constant BPS = 10000;

    function test_predictMovingAverageShift() public {
        uint256 currentMA = 10e18;
        uint256 cumulativeObs = currentMA * NUM_OBSERVATIONS;
        uint256 oldestObs = 9.5e18;
        uint256 newChainlinkPrice = 11e18;

        uint256 newCumulativeObs = cumulativeObs + newChainlinkPrice - oldestObs;
        uint256 newMA = newCumulativeObs / NUM_OBSERVATIONS;

        console2.log("Current MA:", currentMA);
        console2.log("New predicted MA:", newMA);
        console2.log("MA shift bps:", (newMA - currentMA) * BPS / currentMA);

        uint256 currentLowWall = currentMA * (BPS - WALL_SPREAD) / BPS;
        uint256 newLowWall = newMA * (BPS - WALL_SPREAD) / BPS;
        uint256 currentHighWall = currentMA * (BPS + WALL_SPREAD) / BPS;
        uint256 newHighWall = newMA * (BPS + WALL_SPREAD) / BPS;

        console2.log("Low wall shift:", newLowWall - currentLowWall);
        console2.log("High wall shift:", newHighWall - currentHighWall);

        assertGt(newMA, currentMA, "MA should increase");
        assertGt(newLowWall, currentLowWall, "Low wall should increase");
    }
}
