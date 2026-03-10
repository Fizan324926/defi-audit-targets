// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

/**
 * @title RETRACTED: calculateSopPerWell Division by Zero — FALSE POSITIVE
 * @notice Mathematical proof shows the division-by-zero at i=1 is UNREACHABLE
 *         when the guard (totalPositiveDeltaB >= totalNegativeDeltaB) holds.
 *
 * @dev Proof summary:
 *   For any k positive wells, the accumulated shaveToLevel at i=1 is bounded by:
 *     shaveToLevel <= totalNeg - sum_of_actual_shaves(wells 2..k)
 *   Since each well's actual shave <= its deltaB, and totalNeg <= totalPos = sum(all deltaBs):
 *     shaveToLevel <= totalNeg - (totalPos - d_1) = totalNeg - totalPos + d_1 <= d_1
 *   Therefore shaveToLevel <= d_1 (the largest positive deltaB), and the condition
 *   `shaveToLevel > d_1` that triggers the division is never true.
 *
 *   Solidity integer truncation only REDUCES intermediate values, strengthening this bound.
 */
contract PoC_CalculateSopDivByZero_FalsePositive is Test {

    struct WellDeltaB {
        address well;
        int256 deltaB;
    }

    // Exact reproduction of LibFlood.calculateSopPerWell
    function calculateSopPerWell(
        WellDeltaB[] memory wellDeltaBs,
        uint256 totalPositiveDeltaB,
        uint256 totalNegativeDeltaB,
        uint256 positiveDeltaBCount
    ) internal pure returns (WellDeltaB[] memory) {
        if (positiveDeltaBCount == wellDeltaBs.length) {
            return wellDeltaBs;
        }
        if (totalPositiveDeltaB < totalNegativeDeltaB || positiveDeltaBCount == 0) {
            for (uint256 i = 0; i < positiveDeltaBCount; i++) {
                wellDeltaBs[i].deltaB = 0;
            }
            return wellDeltaBs;
        }
        if (totalPositiveDeltaB < totalNegativeDeltaB) {
            for (uint256 i = 0; i < positiveDeltaBCount; i++) {
                wellDeltaBs[i].deltaB = 0;
            }
            return wellDeltaBs;
        }

        uint256 shaveToLevel = totalNegativeDeltaB / positiveDeltaBCount;
        for (uint256 i = positiveDeltaBCount; i > 0; i--) {
            if (shaveToLevel > uint256(wellDeltaBs[i - 1].deltaB)) {
                shaveToLevel += (shaveToLevel - uint256(wellDeltaBs[i - 1].deltaB)) / (i - 1);
                wellDeltaBs[i - 1].deltaB = 0;
            } else {
                wellDeltaBs[i - 1].deltaB = wellDeltaBs[i - 1].deltaB - int256(shaveToLevel);
            }
        }
        return wellDeltaBs;
    }

    /// @notice Test with 2 positive wells — mathematically proven safe
    function test_2wells_noDivByZero() public pure {
        WellDeltaB[] memory wells = new WellDeltaB[](3);
        wells[0] = WellDeltaB(address(0x1), int256(100)); // largest positive
        wells[1] = WellDeltaB(address(0x2), int256(1));   // tiny positive
        wells[2] = WellDeltaB(address(0x3), int256(-100)); // large negative

        // totalPos=101, totalNeg=100, positiveCount=2
        // shaveToLevel = 100/2 = 50
        // i=2: 50 > 1 → yes → shaveToLevel += (50-1)/1 = 49 → shaveToLevel = 99
        // i=1: 99 > 100 → NO → well[0] = 100 - 99 = 1. SAFE.
        WellDeltaB[] memory result = calculateSopPerWell(wells, 101, 100, 2);
        assertEq(result[0].deltaB, 1);
        assertEq(result[1].deltaB, 0);
    }

    /// @notice Test with 3 positive wells — proven safe even with extreme skew
    function test_3wells_noDivByZero() public pure {
        WellDeltaB[] memory wells = new WellDeltaB[](4);
        wells[0] = WellDeltaB(address(0x1), int256(1000));
        wells[1] = WellDeltaB(address(0x2), int256(1));
        wells[2] = WellDeltaB(address(0x3), int256(1));
        wells[3] = WellDeltaB(address(0x4), int256(-1001));

        // totalPos=1002, totalNeg=1001, positiveCount=3
        // shaveToLevel = 1001/3 = 333
        // i=3: 333 > 1 → shaveToLevel += (333-1)/2 = 166 → shaveToLevel = 499
        // i=2: 499 > 1 → shaveToLevel += (499-1)/1 = 498 → shaveToLevel = 997
        // i=1: 997 > 1000 → NO → well[0] = 1000 - 997 = 3. SAFE.
        WellDeltaB[] memory result = calculateSopPerWell(wells, 1002, 1001, 3);
        assertEq(result[0].deltaB, 3);
        assertEq(result[1].deltaB, 0);
        assertEq(result[2].deltaB, 0);
    }

    /// @notice Extreme case: totalPos barely exceeds totalNeg
    function test_extremeCase_noDivByZero() public pure {
        WellDeltaB[] memory wells = new WellDeltaB[](3);
        wells[0] = WellDeltaB(address(0x1), int256(20));
        wells[1] = WellDeltaB(address(0x2), int256(1));
        wells[2] = WellDeltaB(address(0x3), int256(-20));

        // totalPos=21, totalNeg=20, positiveCount=2
        // shaveToLevel = 20/2 = 10
        // i=2: 10 > 1 → shaveToLevel += (10-1)/1 = 9 → shaveToLevel = 19
        // i=1: 19 > 20 → NO → well[0] = 20 - 19 = 1. SAFE.
        WellDeltaB[] memory result = calculateSopPerWell(wells, 21, 20, 2);
        assertEq(result[0].deltaB, 1);
        assertEq(result[1].deltaB, 0);
    }

    /// @notice Guard catches totalNeg > totalPos
    function test_guardCatchesTotalNegExceedsTotalPos() public pure {
        WellDeltaB[] memory wells = new WellDeltaB[](3);
        wells[0] = WellDeltaB(address(0x1), int256(20));
        wells[1] = WellDeltaB(address(0x2), int256(1));
        wells[2] = WellDeltaB(address(0x3), int256(-30));

        // totalPos=21, totalNeg=30 → guard catches: 21 < 30, return zeros
        WellDeltaB[] memory result = calculateSopPerWell(wells, 21, 30, 2);
        assertEq(result[0].deltaB, 0);
        assertEq(result[1].deltaB, 0);
    }
}
