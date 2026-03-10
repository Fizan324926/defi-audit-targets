// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.15;

import "forge-std/Test.sol";

/// @title PoC: Clearinghouse multiple rebalances after missed cadences
/// @notice Demonstrates that if rebalance cadences are missed, multiple rebalances
///         can be triggered in the same block, each funding up to FUND_AMOUNT
contract PoC_005_RebalanceAccumulation is Test {
    uint256 constant FUND_CADENCE = 7 days;
    uint256 constant FUND_AMOUNT = 18_000_000e18;

    uint256 public fundTime;

    function activate() public {
        fundTime = block.timestamp;
    }

    function rebalance() public returns (bool) {
        if (fundTime > block.timestamp) return false;
        fundTime += FUND_CADENCE;
        return true;
    }

    function test_multipleRebalancesAfterMissedCadences() public {
        activate();
        vm.warp(block.timestamp + 3 * FUND_CADENCE + 1);

        uint256 successCount;
        for (uint256 i = 0; i < 10; i++) {
            if (rebalance()) {
                successCount++;
            } else {
                break;
            }
        }

        assertEq(successCount, 3, "Should allow exactly 3 rebalances for 3 missed weeks");
        assertFalse(rebalance(), "Fourth rebalance should fail");

        emit log_named_uint("Rebalances in one block", successCount);
        emit log_named_uint("Max treasury exposure (in millions)", successCount * 18);
    }
}
