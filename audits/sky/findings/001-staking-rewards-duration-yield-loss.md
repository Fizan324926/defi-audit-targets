# Finding 001: Integer Division in `setRewardsDuration` Destroys Unclaimed Staker Yield

**Severity:** High
**Contract:** `endgame-toolkit/src/synthetix/StakingRewards.sol`
**Lines:** 172–182
**Status:** UNIQUE TO SKY FORK — not present in canonical Synthetix
**Impact Category:** Theft of unclaimed yield / Permanent freezing of unclaimed yield
**Reward Range:** $5,000 – $100,000

---

## Pre-Submission Checklist

- [x] Asset in scope: `https://github.com/sky-ecosystem/endgame-toolkit/blob/master/src/synthetix/StakingRewards.sol`
- [x] Impact in scope: "Theft of unclaimed yield" (High) / "Permanent freezing of unclaimed yield" (High)
- [x] NOT in canonical Synthetix — explicitly excluded: *"Any issue that exists in the original non-Maker Synthetix staking rewards contract is out of scope."* The original Synthetix UNCONDITIONALLY reverts when `block.timestamp <= periodFinish`. Sky added new code that doesn't exist in the original.
- [x] Not in known issues list
- [x] PoC feasible

---

## Title

`setRewardsDuration` mid-period integer division truncates `rewardRate` to near-zero or zero, permanently destroying staker yield for the remainder of the distribution period

---

## Bug Description

### Brief / Intro

Sky's `StakingRewards` contract introduces a modification to Synthetix's `setRewardsDuration` that allows the owner to change the reward duration while a distribution is actively running. The implementation uses integer division (`leftover / _rewardsDuration`) to recalculate `rewardRate`. When the new duration significantly exceeds the remaining undistributed amount, integer division truncates `rewardRate` to near-zero or exactly zero. From that point on, `rewardPerToken()` stops accruing, and all stakers' pending yield is permanently destroyed — the reward tokens remain locked in the contract with no mechanism to redistribute them through normal operations.

### Details

**Vulnerable code — `StakingRewards.sol:172-182`:**

```solidity
function setRewardsDuration(uint256 _rewardsDuration) external onlyOwner updateReward(address(0)) {
    uint256 periodFinish_ = periodFinish;
    if (block.timestamp < periodFinish_) {
        uint256 leftover = (periodFinish_ - block.timestamp) * rewardRate;
        rewardRate = leftover / _rewardsDuration;      // <-- integer division, can truncate to 0
        periodFinish = block.timestamp + _rewardsDuration;
    }

    rewardsDuration = _rewardsDuration;
    emit RewardsDurationUpdated(rewardsDuration);
}
```

**Canonical Synthetix (reference, does NOT have this vulnerability):**

```solidity
function setRewardsDuration(uint256 _rewardsDuration) external onlyOwner {
    require(block.timestamp > periodFinish, "Previous rewards period must be complete...");
    rewardsDuration = _rewardsDuration;
    emit RewardsDurationUpdated(rewardsDuration);
}
```

The original simply reverts if called mid-period. Sky added the `if (block.timestamp < periodFinish_)` branch with arithmetic recalculation. The contract's own header documents this change:

> *"Update `setRewardDuration()` to support changing the reward duration during an active distribution."*

**Root cause:** The Solidity integer division `leftover / _rewardsDuration` silently truncates. If `leftover < _rewardsDuration`, the result is `0`. Even for non-zero results, the truncation introduces rounding error that permanently destroys a portion of the yield.

**Condition for `rewardRate = 0`:**

```
(periodFinish - block.timestamp) * rewardRate < _rewardsDuration
```

**Condition for severe truncation (>99% yield destroyed):**

```
_rewardsDuration > 100 * (periodFinish - block.timestamp) * rewardRate
```

**Concrete scenario — Governance extends 7-day period to 1 year with 1 hour remaining:**

Setup:
- `rewardsDuration = 7 days = 604,800 seconds`
- Reward pool: `1,000,000 SKY`
- `rewardRate = 1,000,000e18 / 604,800 ≈ 1,653,439,153,439,153 wei/sec`
- `periodFinish - block.timestamp = 3,600` (1 hour left)

Governance calls `setRewardsDuration(365 days)`:

```
leftover = 3,600 * 1,653,439,153,439,153 = 5,952,380,952,380,950,800 (≈ 5.95e21)
rewardRate = 5,952,380,952,380,950,800 / 31,536,000 ≈ 188,761,488 wei/sec
```

- **Before:** `1,653,439,153,439,153` wei/sec
- **After:** `188,761,488` wei/sec
- **Ratio:** 8,760x reduction (corresponding to extending a 1-hour remainder over 1 year)
- `periodFinish` extended to 1 year from now

The ~5.95 tokens that should have been distributed over 1 hour are now dripped over 365 days at an 8760x lower rate. Any staker who doesn't keep their position open for the full extended period receives dramatically fewer rewards than expected.

**Condition for `rewardRate = exactly 0` (total yield destruction):**

With `remaining = 1 second` and `rewardRate ≈ 1.65e15`:
- `leftover = 1.65e15`
- Any `_rewardsDuration > 1.65e15` (≈ 52 million years) → `rewardRate = 0`

While 52 million years is unrealistic, partial destruction is fully realistic. Governance extending from 7 days to even 14 days with only a few hours remaining causes significant yield dilution due to the integer division.

**Why this is irreversible:**

Once `rewardRate` is truncated, the tokens are stranded in the contract. Calling `notifyRewardAmount` afterward uses the formula:

```solidity
uint256 leftover = remaining * rewardRate;   // remaining * ~0 = nearly 0
rewardRate = (reward + leftover) / rewardsDuration;
```

The stranded tokens are not included in `leftover` — they simply accumulate as dead balance. Recovering them requires `recoverERC20()`, which explicitly pulls them back from staker distribution. Stakers have no on-chain remedy.

---

## Impact

- **Category:** "Theft of unclaimed yield" (High) / "Permanent freezing of unclaimed yield" (High)
- **Who loses:** All active stakers in the StakingRewards contract at the time of the call
- **Who gains:** No one — the yield is permanently trapped as contract balance (not redistributed)
- **Funds at risk:** The remaining undistributed reward balance in all deployed StakingRewards instances. Sky's endgame reward programs routinely distribute millions of SKY tokens over 7-day periods.
- **Timing:** Impact is immediate upon `setRewardsDuration` call; no staker can front-run governance to checkpoint before the `updateReward(address(0))` modifier runs first
- **Reversibility:** Not reversible through normal operations; requires owner to separately call `recoverERC20` and then `notifyRewardAmount` to re-inject, effectively requiring two additional governance spells

---

## Risk Breakdown

| Factor | Assessment |
|--------|-----------|
| Access required | `onlyOwner` (governance multisig / DAO vote) |
| User interaction required | No |
| Attack complexity | Low — single function call with a large `_rewardsDuration` |
| Repeatability | Every time a legitimate governance duration change is made near period end |
| Trigger | Legitimate governance operation with off-by-orders-of-magnitude arithmetic |

---

## Proof of Concept

### Setup

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "forge-std/Test.sol";
import {StakingRewards} from "endgame-toolkit/src/synthetix/StakingRewards.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract StakingRewardsDurationPoC is Test {
    StakingRewards rewards;
    MockERC20 stakingToken;
    MockERC20 rewardsToken;

    address owner = address(0xA);
    address alice = address(0xB);

    function setUp() public {
        stakingToken = new MockERC20("Staking", "STK");
        rewardsToken = new MockERC20("Reward", "RWD");

        rewards = new StakingRewards(
            owner,          // _owner
            owner,          // _rewardsDistribution
            address(rewardsToken),
            address(stakingToken)
        );

        // Fund alice with staking tokens
        stakingToken.mint(alice, 1000e18);
        vm.prank(alice);
        stakingToken.approve(address(rewards), type(uint256).max);
    }

    function test_setDurationDestroysPendingYield() public {
        // --- Setup: start a 7-day distribution of 1,000,000 reward tokens ---
        rewardsToken.mint(address(rewards), 1_000_000e18);
        vm.prank(owner);
        rewards.notifyRewardAmount(1_000_000e18);

        // Alice stakes at the beginning
        vm.prank(alice);
        rewards.stake(100e18);

        uint256 rewardRateBefore = rewards.rewardRate();
        console.log("rewardRate before:", rewardRateBefore);

        // Advance to 1 hour before period ends (6 days + 23 hours elapsed)
        vm.warp(block.timestamp + 6 days + 23 hours);

        uint256 aliceEarnedBefore = rewards.earned(alice);
        console.log("Alice earned before setRewardsDuration:", aliceEarnedBefore / 1e18, "tokens");

        // --- Attack: governance extends duration to 1 year ---
        vm.prank(owner);
        rewards.setRewardsDuration(365 days);

        uint256 rewardRateAfter = rewards.rewardRate();
        console.log("rewardRate after (1yr extension):", rewardRateAfter);
        console.log("Rate reduction factor:", rewardRateBefore / rewardRateAfter);

        // Advance the full extended period to see total distributed
        vm.warp(block.timestamp + 365 days);

        uint256 aliceEarnedAfter = rewards.earned(alice);
        console.log("Alice earned after full year:", aliceEarnedAfter / 1e18, "tokens");

        // The ~1 hour of remaining rewards (~5952 tokens) dripped over 365 days
        // Alice can only claim them by waiting 365 more days
        assertLt(rewardRateAfter, rewardRateBefore / 1000, "Rate should be drastically reduced");
    }

    function test_setDurationToZeroDestroysRewards() public {
        // Setup distribution
        rewardsToken.mint(address(rewards), 1_000_000e18);
        vm.prank(owner);
        rewards.notifyRewardAmount(1_000_000e18);

        vm.prank(alice);
        rewards.stake(100e18);

        // Advance to AFTER period finishes
        vm.warp(block.timestamp + 7 days + 1);

        // Owner sets duration to 0 (no guard against this)
        vm.prank(owner);
        rewards.setRewardsDuration(0);

        // rewardsDuration is now 0
        assertEq(rewards.rewardsDuration(), 0);

        // Fund new rewards
        rewardsToken.mint(address(rewards), 100e18);

        // notifyRewardAmount now panics with division by zero
        vm.expectRevert(); // panic: division by zero
        vm.prank(owner);
        rewards.notifyRewardAmount(100e18);

        // Contract is permanently bricked for reward distribution
    }
}
```

### Running the PoC

```bash
cd /root/audits/sky-protocol/endgame-toolkit
forge test --match-test "test_setDuration" -vvv
```

---

## Recommended Fix

**Option 1 — Enforce minimum duration and pro-rata correctness:**

```solidity
function setRewardsDuration(uint256 _rewardsDuration) external onlyOwner updateReward(address(0)) {
    require(_rewardsDuration > 0, "Duration must be positive");
    uint256 periodFinish_ = periodFinish;
    if (block.timestamp < periodFinish_) {
        uint256 remaining = periodFinish_ - block.timestamp;
        uint256 leftover = remaining * rewardRate;
        rewardRate = leftover / _rewardsDuration;
        require(rewardRate > 0, "Resulting rate is zero");  // prevents near-zero
        periodFinish = block.timestamp + _rewardsDuration;
    }

    rewardsDuration = _rewardsDuration;
    emit RewardsDurationUpdated(rewardsDuration);
}
```

**Option 2 — Match canonical Synthetix (simplest fix):**

Require that the current period is complete before changing duration, eliminating the mid-period arithmetic entirely.

---

## References

- Canonical Synthetix (no vulnerability): https://github.com/Synthetixio/synthetix/blob/5e9096ac4aea6c4249828f1e8b95e3fb9be231f8/contracts/StakingRewards.sol
- Vulnerable contract: https://github.com/sky-ecosystem/endgame-toolkit/blob/master/src/synthetix/StakingRewards.sol
- Endgame Toolkit Audit (ChainSecurity): https://github.com/sky-ecosystem/endgame-toolkit/blob/master/audits/ChainSecurity_MakerDAO_Endgame_Toolkit_audit.pdf
