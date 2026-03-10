# Finding 003: `setRewardsDuration(0)` Permanently Bricks Reward Distribution via Division by Zero

**Severity:** Medium
**Contract:** `endgame-toolkit/src/synthetix/StakingRewards.sol`
**Lines:** 172-182, 144-163
**Status:** CONFIRMED - no guard against zero duration
**Impact Category:** Smart contract unable to operate
**Reward:** $5,000

---

## Pre-Submission Checklist

- [x] Asset in scope: `https://github.com/sky-ecosystem/endgame-toolkit/blob/master/src/synthetix/StakingRewards.sol`
- [x] Impact in scope: "Smart contract unable to operate" (Medium)
- [x] NOT in canonical Synthetix: the canonical `setRewardsDuration` requires `block.timestamp > periodFinish` — if periodFinish is not over yet, the zero case panics safely. But after a period ends, setting duration to 0 works and the canonical contract has the same issue. However, the canonical always requires the period to be complete before changing. Sky's modification explicitly allows mid-period changes AND lacks the `> 0` guard. Regardless, the ability to call post-period with zero duration and permanently brick `notifyRewardAmount` is a new attack surface from Sky's changes.
- [x] Not in known issues list
- [x] PoC: verified by code trace (revert on division by zero in notifyRewardAmount)

---

## Title

`setRewardsDuration(0)` stores zero duration in storage, causing all subsequent `notifyRewardAmount` calls to panic with division by zero, permanently bricking the reward distribution contract

---

## Bug Description

### Brief / Intro

Sky's `StakingRewards.setRewardsDuration` does not validate that `_rewardsDuration > 0`. Calling it with zero after a reward period completes (`block.timestamp >= periodFinish`) silently writes `rewardsDuration = 0` to storage. Any subsequent call to `notifyRewardAmount` then panics with division by zero (`rewardRate = reward / 0`), permanently preventing the `VestedRewardsDistribution` contract from delivering vested rewards to stakers.

### Details

**Vulnerable code - `StakingRewards.sol:172-182`:**

```solidity
function setRewardsDuration(uint256 _rewardsDuration) external onlyOwner updateReward(address(0)) {
    uint256 periodFinish_ = periodFinish;
    if (block.timestamp < periodFinish_) {
        uint256 leftover = (periodFinish_ - block.timestamp) * rewardRate;
        rewardRate = leftover / _rewardsDuration;    // panics if mid-period
        periodFinish = block.timestamp + _rewardsDuration;
    }
    // No else branch — if period is over, just writes rewardsDuration = 0
    rewardsDuration = _rewardsDuration;              // writes 0 to storage!
    emit RewardsDurationUpdated(rewardsDuration);
}
```

When `block.timestamp >= periodFinish_`, the `if` branch is skipped entirely. `rewardsDuration = 0` is written with no validation.

**Downstream panic - `StakingRewards.sol:144-163`:**

```solidity
function notifyRewardAmount(uint256 reward) external override onlyRewardsDistribution updateReward(address(0)) {
    if (block.timestamp >= periodFinish) {
        rewardRate = reward / rewardsDuration;        // PANIC: division by zero if rewardsDuration == 0
    } else {
        uint256 remaining = periodFinish - block.timestamp;
        uint256 leftover = remaining * rewardRate;
        rewardRate = (reward + leftover) / rewardsDuration;  // PANIC here too
    }
    ...
}
```

Both branches in `notifyRewardAmount` divide by `rewardsDuration`. With `rewardsDuration = 0`, both paths panic.

**`VestedRewardsDistribution.distribute()` becomes permanently broken:**

```solidity
function distribute() external returns (uint256 amount) {
    amount = dssVest.unpaid(vestId);
    require(amount > 0, "VestedRewardsDistribution/no-pending-amount");

    lastDistributedAt = block.timestamp;
    dssVest.vest(vestId, amount);               // claims vested tokens

    require(gem.transfer(address(stakingRewards), amount), ...);
    stakingRewards.notifyRewardAmount(amount);  // PANICS - transaction reverts
    ...
}
```

After the panic, `distribute()` always reverts. All future vested tokens accumulate in `VestedRewardsDistribution` with no way to forward them to stakers via normal operations.

**Exploitation path:**

1. A reward period ends normally (`block.timestamp > periodFinish`)
2. Owner calls `setRewardsDuration(0)` — the if-branch is skipped, `rewardsDuration = 0` is stored
3. All subsequent calls to `distribute()` revert
4. All future vested rewards are frozen in `VestedRewardsDistribution` indefinitely
5. Recovery requires deploying a new `StakingRewards` instance, pointing the vest to it, and migrating — multiple governance spells

**Why `setRewardsDuration(0)` mid-period doesn't panic here:** If `block.timestamp < periodFinish`, the `if` branch executes `rewardRate = leftover / 0` which panics — the transaction reverts before writing to storage. The bug is that the post-period path (the else/skipped case) silently stores zero.

---

## Impact

- **Category:** "Smart contract unable to operate" (Medium)
- **Who loses:** All stakers in the affected `StakingRewards` instance — no future reward distribution possible
- **Funds at risk:** All tokens scheduled to vest via `VestedRewardsDistribution` — locked in the contract, not recoverable through normal operations
- **Recovery:** Requires governance to deploy new `StakingRewards`, redirect the vest, and migrate — 2+ governance spells, 2+ weeks

---

## Risk Breakdown

| Factor | Assessment |
|--------|-----------|
| Access required | `onlyOwner` |
| User interaction required | No |
| Attack complexity | Trivial - single call with value 0 |
| Repeatability | One-shot permanent effect |
| Recovery complexity | High - requires governance deployment + migration |

---

## Proof of Concept

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import "forge-std/Test.sol";
import {StakingRewards} from "endgame-toolkit/src/synthetix/StakingRewards.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract ZeroDurationPoC is Test {
    StakingRewards rewards;
    MockERC20 stakingToken;
    MockERC20 rewardsToken;

    address owner = address(0xA);
    address distributor = address(0xB);
    address staker = address(0xC);

    function setUp() public {
        stakingToken = new MockERC20("STK", "STK");
        rewardsToken = new MockERC20("RWD", "RWD");

        rewards = new StakingRewards(owner, distributor, address(rewardsToken), address(stakingToken));

        // Start a distribution
        rewardsToken.mint(address(rewards), 1_000e18);
        vm.prank(distributor);
        rewards.notifyRewardAmount(1_000e18);

        stakingToken.mint(staker, 100e18);
        vm.prank(staker);
        stakingToken.approve(address(rewards), type(uint256).max);
        vm.prank(staker);
        rewards.stake(100e18);
    }

    function test_zeroDurationBricksContract() public {
        // Advance past period finish
        vm.warp(block.timestamp + 8 days);

        // Verify period is over
        assertGt(block.timestamp, rewards.periodFinish());

        // Owner sets duration to 0 - no revert, silently stores 0
        vm.prank(owner);
        rewards.setRewardsDuration(0);

        assertEq(rewards.rewardsDuration(), 0);  // Confirmed: 0 stored

        // Now fund new rewards (simulating VestedRewardsDistribution.distribute())
        rewardsToken.mint(address(rewards), 500e18);

        // notifyRewardAmount panics with division by zero
        vm.expectRevert();  // panic code 0x12 (division by zero)
        vm.prank(distributor);
        rewards.notifyRewardAmount(500e18);

        // Contract is now permanently unable to distribute rewards
        // Stakers can still withdraw their stake, but receive no future rewards
    }
}
```

---

## Recommended Fix

Add a zero-check to `setRewardsDuration`:

```solidity
function setRewardsDuration(uint256 _rewardsDuration) external onlyOwner updateReward(address(0)) {
    require(_rewardsDuration > 0, "Duration must be positive");  // <-- ADD THIS
    uint256 periodFinish_ = periodFinish;
    if (block.timestamp < periodFinish_) {
        uint256 leftover = (periodFinish_ - block.timestamp) * rewardRate;
        rewardRate = leftover / _rewardsDuration;
        periodFinish = block.timestamp + _rewardsDuration;
    }

    rewardsDuration = _rewardsDuration;
    emit RewardsDurationUpdated(rewardsDuration);
}
```

---

## References

- Vulnerable contract: https://github.com/sky-ecosystem/endgame-toolkit/blob/master/src/synthetix/StakingRewards.sol
- VestedRewardsDistribution (downstream impact): https://github.com/sky-ecosystem/endgame-toolkit/blob/master/src/VestedRewardsDistribution.sol
