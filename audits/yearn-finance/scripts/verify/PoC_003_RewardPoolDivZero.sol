// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "forge-std/Test.sol";

// Simulates the RewardPool._claim() logic to demonstrate division by zero
contract RewardPoolDivZeroPoC is Test {
    uint256 constant WEEK = 7 * 86400;

    // Simulated storage
    mapping(uint256 => uint256) public tokens_per_week;
    mapping(uint256 => uint256) public ve_supply;

    function setUp() public {
        // Week 1: normal distribution -- 1000 tokens, 100 veYFI supply
        uint256 week1 = block.timestamp / WEEK * WEEK;
        tokens_per_week[week1] = 1000e18;
        ve_supply[week1] = 100e18;

        // Week 2: all locks expired -- 500 tokens, 0 veYFI supply
        uint256 week2 = week1 + WEEK;
        tokens_per_week[week2] = 500e18;
        ve_supply[week2] = 0; // All locks expired!

        // Week 3: new lock created -- 200 tokens, 50 veYFI supply
        uint256 week3 = week2 + WEEK;
        tokens_per_week[week3] = 200e18;
        ve_supply[week3] = 50e18;
    }

    // Simulates _claim for a user who has balance > 0 at the zero-supply week
    function _claim_vulnerable(
        uint256 start_week,
        uint256 last_token_time,
        uint256[] memory user_balances
    ) internal view returns (uint256) {
        uint256 to_distribute = 0;
        uint256 week_cursor = start_week;

        for (uint256 i = 0; i < 50; i++) {
            if (week_cursor >= last_token_time) break;
            uint256 balance_of = user_balances[i];
            if (balance_of == 0) break;

            // THIS IS THE VULNERABLE LINE -- divides by ve_supply which can be 0
            to_distribute += balance_of * tokens_per_week[week_cursor] / ve_supply[week_cursor];
            week_cursor += WEEK;
        }

        return to_distribute;
    }

    // Simulates _claim with the fix
    function _claim_fixed(
        uint256 start_week,
        uint256 last_token_time,
        uint256[] memory user_balances
    ) internal view returns (uint256) {
        uint256 to_distribute = 0;
        uint256 week_cursor = start_week;

        for (uint256 i = 0; i < 50; i++) {
            if (week_cursor >= last_token_time) break;
            uint256 balance_of = user_balances[i];
            if (balance_of == 0) break;

            // FIX: skip weeks with zero supply
            if (ve_supply[week_cursor] > 0) {
                to_distribute += balance_of * tokens_per_week[week_cursor] / ve_supply[week_cursor];
            }
            week_cursor += WEEK;
        }

        return to_distribute;
    }

    function test_DivisionByZero_Vulnerable() public {
        uint256 week1 = block.timestamp / WEEK * WEEK;
        uint256 last_token_time = week1 + 3 * WEEK;

        // User has: 10 veYFI in week1, 5 veYFI in week2 (their lock hasn't fully expired),
        // and 5 veYFI in week3
        uint256[] memory balances = new uint256[](3);
        balances[0] = 10e18;
        balances[1] = 5e18; // Non-zero balance at zero-supply week!
        balances[2] = 5e18;

        // This REVERTS with division by zero at week2
        vm.expectRevert();
        _claim_vulnerable(week1, last_token_time, balances);
    }

    function test_Fixed_SkipsZeroSupply() public view {
        uint256 week1 = block.timestamp / WEEK * WEEK;
        uint256 last_token_time = week1 + 3 * WEEK;

        uint256[] memory balances = new uint256[](3);
        balances[0] = 10e18;
        balances[1] = 5e18;
        balances[2] = 5e18;

        // Fixed version skips week2 and processes week1 + week3
        uint256 distributed = _claim_fixed(week1, last_token_time, balances);

        // Week1: 10e18 * 1000e18 / 100e18 = 100e18
        // Week2: skipped (ve_supply == 0)
        // Week3: 5e18 * 200e18 / 50e18 = 20e18
        assertEq(distributed, 120e18, "Should distribute from week1 and week3");
    }
}
