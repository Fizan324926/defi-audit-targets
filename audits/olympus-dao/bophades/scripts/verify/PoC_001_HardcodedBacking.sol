// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.15;

import "forge-std/Test.sol";

/// @title PoC: YieldRepurchaseFacility Hardcoded backingPerToken
/// @notice Demonstrates how the hardcoded $11.33 backingPerToken creates an accounting
///         drift as actual backing diverges from the hardcoded value over time.
contract PoC_001_HardcodedBacking is Test {
    uint256 constant backingPerToken = 1133 * 1e7; // $11.33 hardcoded in YieldRepo

    function test_underWithdrawalWhenBackingRises() public {
        // Scenario: actual backing is $15 per OHM (has risen over time)
        uint256 actualBacking = 15e18; // $15 in 18 decimals per OHM
        uint256 ohmPurchased = 1_000_000e9; // 1M OHM purchased (9 decimals)

        // What YieldRepo calculates (hardcoded)
        uint256 hardcodedWithdrawal = ohmPurchased * backingPerToken;

        // What should actually be withdrawn based on real backing
        uint256 correctWithdrawal = (ohmPurchased * actualBacking) / 1e9;

        // The difference: under-withdrawal when backing increases
        uint256 underWithdrawal = correctWithdrawal - hardcodedWithdrawal;

        // $3.67M in reserves left attributed to non-existent supply
        assertGt(underWithdrawal, 0, "Under-withdrawal should be positive");

        emit log_named_uint("Hardcoded withdrawal", hardcodedWithdrawal);
        emit log_named_uint("Correct withdrawal at $15", correctWithdrawal);
        emit log_named_uint("Under-withdrawn at $15 backing", underWithdrawal);
    }

    function test_overWithdrawalWhenBackingDrops() public {
        // Dangerous scenario: backing drops below $11.33
        uint256 droppedBacking = 8e18; // $8 backing
        uint256 ohmPurchased = 1_000_000e9; // 1M OHM (9 decimals)

        uint256 hardcodedWithdrawal = ohmPurchased * backingPerToken;
        uint256 correctWithdrawal = (ohmPurchased * droppedBacking) / 1e9;

        // Over-withdrawal: draining more reserves than the OHM was backed by
        uint256 overWithdrawal = hardcodedWithdrawal - correctWithdrawal;
        assertGt(overWithdrawal, 0, "Over-withdrawal should be positive when backing drops");

        emit log_named_uint("Hardcoded withdrawal", hardcodedWithdrawal);
        emit log_named_uint("Correct withdrawal at $8", correctWithdrawal);
        emit log_named_uint("Over-withdrawn at $8 backing (treasury drain)", overWithdrawal);
    }
}
