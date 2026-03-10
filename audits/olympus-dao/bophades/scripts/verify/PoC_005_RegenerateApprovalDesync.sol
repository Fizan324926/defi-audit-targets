// SPDX-License-Identifier: Unlicense
pragma solidity >=0.8.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Demonstrates the Clearinghouse rebalance accumulation issue
/// @dev Corresponds to Finding 005 (Clearinghouse fund-time accumulation)
contract PoC_005_RebalanceAccumulation is Test {
    uint256 constant FUND_CADENCE = 7 days;
    uint256 public fundTime;

    function activate() public {
        fundTime = block.timestamp;
    }

    function rebalance() public returns (bool) {
        if (fundTime > block.timestamp) return false;
        fundTime += FUND_CADENCE;
        return true;
    }

    function test_multipleRebalances() public {
        activate();
        vm.warp(block.timestamp + 3 * FUND_CADENCE + 1);

        assertTrue(rebalance(), "First rebalance succeeds");
        assertTrue(rebalance(), "Second rebalance succeeds");
        assertTrue(rebalance(), "Third rebalance succeeds");
        assertFalse(rebalance(), "Fourth rebalance fails");
    }
}
