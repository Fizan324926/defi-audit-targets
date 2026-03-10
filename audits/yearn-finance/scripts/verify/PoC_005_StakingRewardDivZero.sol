// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

// Simulates the StakingRewardDistributor._sync_integral() logic
contract StakingRewardDistributorPoC is Test {
    uint256 constant PRECISION = 1e18;
    uint256 constant EPOCH_LENGTH = 14 days;

    // Simulated storage
    uint256 public reward_integral;
    mapping(uint256 => uint256) public reward_integral_snapshot;
    uint256 public total_weight;

    struct EpochRewards {
        uint256 timestamp;
        uint256 rewards;
    }
    EpochRewards public epoch_rewards;

    uint256 public genesis;

    function setUp() public {
        genesis = block.timestamp;
        total_weight = 1e12; // Dead shares initialization
        reward_integral = 0;
        epoch_rewards = EpochRewards({timestamp: 0, rewards: 0});
    }

    // Simulates _sync_integral (vulnerable version)
    function _sync_integral_vulnerable(uint256, uint256 new_rewards) internal {
        uint256 unlocked = new_rewards;

        if (unlocked == 0) return;

        // THIS IS THE VULNERABLE LINE
        reward_integral = reward_integral + unlocked * PRECISION / total_weight;
    }

    // Simulates _sync_integral (fixed version)
    function _sync_integral_fixed(uint256, uint256 new_rewards) internal {
        uint256 unlocked = new_rewards;

        if (unlocked == 0) return;

        // FIX: skip if total_weight is zero
        if (total_weight > 0) {
            reward_integral = reward_integral + unlocked * PRECISION / total_weight;
        }
        // else: rewards are lost (no one to distribute to)
    }

    function test_NormalOperation() public {
        // Normal case: stakers present
        total_weight = 100e18;

        // 1000 tokens to distribute
        _sync_integral_vulnerable(1, 1000e18);

        // Integral should be: 1000e18 * 1e18 / 100e18 = 10e18
        assertEq(reward_integral, 10e18);
    }

    function test_DivisionByZero_AllStakersExit() public {
        // All stakers have exited
        total_weight = 0;

        // Rewards arrive for this epoch
        uint256 newRewards = 500e18;

        // This REVERTS with division by zero
        vm.expectRevert();
        _sync_integral_vulnerable(1, newRewards);
    }

    function test_Fixed_HandlesZeroWeight() public {
        // All stakers have exited
        total_weight = 0;

        // Rewards arrive for this epoch
        uint256 newRewards = 500e18;

        // Fixed version does NOT revert
        _sync_integral_fixed(1, newRewards);

        // Integral unchanged (rewards lost since no one to distribute to)
        assertEq(reward_integral, 0);
    }

    function test_DeadSharesProtection() public {
        // With dead shares: weight is 10^12, not zero
        total_weight = 1e12;

        // This works but distributes to "nobody" (dead shares)
        _sync_integral_vulnerable(1, 1000e18);

        // Integral is very large (rewards / tiny weight)
        // 1000e18 * 1e18 / 1e12 = 1e24
        assertEq(reward_integral, 1e24);
        // Rewards are effectively absorbed by dead shares -- not exploitable but wasteful
    }

    function test_ScenarioWhereDeadSharesInsufficient() public {
        // Start with dead shares
        total_weight = 1e12;

        // Large staker joins: total = 1e12 + 100e18
        total_weight += 100e18;

        // Staker leaves: total should return to 1e12
        total_weight -= 100e18;
        assertEq(total_weight, 1e12); // Dead shares protect

        // Dead shares provide protection as long as the accounting is correct
        assertTrue(total_weight > 0, "Dead shares protect against normal exit");
    }
}
