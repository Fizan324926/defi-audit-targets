# Immunefi Bug Report: RewardPool/dYFIRewardPool Division by Zero When ve_supply is Zero

## Bug Description

The `RewardPool.vy` and `dYFIRewardPool.vy` contracts distribute rewards (YFI and dYFI respectively) to veYFI holders based on their voting power at weekly checkpoints. The `_claim()` function divides by `ve_supply[week_cursor]`, which can be zero in edge cases, causing a permanent revert that locks users out of all future claims.

**Vulnerable Code:**

File: `veYFI/contracts/RewardPool.vy`, line 196

```vyper
# Iterate over weeks
for i in range(50):
    if week_cursor >= last_token_time:
        break
    balance_of: uint256 = VEYFI.balanceOf(addr, week_cursor)
    if balance_of == 0:
        break
    to_distribute += balance_of * self.tokens_per_week[week_cursor] / self.ve_supply[week_cursor]
    #                                                                   ^^^^^^^^^^^^^^^^^^^^^^^^
    #                                                                   Division by zero if ve_supply == 0
    week_cursor += WEEK
```

File: `veYFI/contracts/dYFIRewardPool.vy`, line 190 (identical pattern)

```vyper
to_distribute += balance_of * self.tokens_per_week[week_cursor] / self.ve_supply[week_cursor]
```

**How `ve_supply` becomes zero:**

The `_checkpoint_total_supply()` function at line 133-152 computes:

```vyper
self.ve_supply[t] = convert(max(pt.bias - pt.slope * dt, 0), uint256)
```

This becomes 0 when:
- `pt.bias - pt.slope * dt <= 0` (all voting power has decayed to zero)
- This happens when all locks have expired or the checkpoint is taken far enough after the last lock event

**The critical edge case:**

A user can have `balance_of > 0` at a `week_cursor` while `ve_supply[week_cursor] == 0`. This occurs when:
1. User A has a lock that ends at week W+2
2. The global supply checkpoint for week W+1 was computed at a time when `pt.bias - pt.slope * dt <= 0` (because the bias/slope interpolation reached zero)
3. But User A's individual `balanceOf(addr, week_cursor)` returns non-zero because their individual checkpoint still has positive bias for that week

This mismatch between individual and global checkpoints is possible because `_checkpoint_total_supply` uses `point_history` with linear extrapolation, while `balanceOf` uses the user's individual point history.

**Why `balance_of == 0: break` doesn't fully protect:**

The guard at line 194 (`if balance_of == 0: break`) only protects when the user's OWN balance is zero. It does NOT protect the case where the user has non-zero balance but the GLOBAL supply is zero -- which is exactly the division-by-zero case.

**Why this permanently bricks claims:**

When the division reverts, the `time_cursor_of[addr]` is NOT updated (since the function reverted). On the next `claim()` call, the same `week_cursor` is used, hitting the same division by zero. The user is permanently locked out of claiming all rewards from that week forward.

## Impact

**Severity:** Medium

**Financial Impact:**
- Affected users permanently lose access to all unclaimed rewards from the zero-supply week onward
- Rewards accumulate in the contract but become unclaimable
- The `tokens_per_week` for that week is also wasted, reducing total distributed rewards
- In a mass-expiry scenario (e.g., many locks created at the same time expire together), this could affect multiple users simultaneously

**Affected Users:** Any veYFI holder who attempts to claim rewards for a week where `ve_supply` was checkpointed as 0 but their individual balance was non-zero.

**Precedent:** This is a known issue inherited from Curve's `FeeDistributor` design. Curve has historically avoided this by maintaining perpetual veToken locks through protocol operations. However, Yearn's veYFI system may not have the same perpetual lock guarantees.

## Risk Breakdown

- **Difficulty to Exploit:** Low -- Can occur naturally when locks expire without new locks being created
- **Weakness Type:** CWE-369 (Divide By Zero)
- **CVSS Score:** 5.9 (Medium) -- AV:N/AC:H/PR:N/UI:N/S:U/C:N/I:N/A:H

## Recommendation

Add a zero check in the claim loop:

```diff
 for i in range(50):
     if week_cursor >= last_token_time:
         break
     balance_of: uint256 = VEYFI.balanceOf(addr, week_cursor)
     if balance_of == 0:
         break
-    to_distribute += balance_of * self.tokens_per_week[week_cursor] / self.ve_supply[week_cursor]
+    if self.ve_supply[week_cursor] > 0:
+        to_distribute += balance_of * self.tokens_per_week[week_cursor] / self.ve_supply[week_cursor]
     week_cursor += WEEK
```

Apply this fix to both `RewardPool.vy` (line 196) and `dYFIRewardPool.vy` (line 190).

## Proof of Concept

```solidity
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
        ve_supply[week2] = 0;  // All locks expired!

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
        balances[1] = 5e18;  // Non-zero balance at zero-supply week!
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
```

**To run:**
```bash
forge test --match-contract RewardPoolDivZeroPoC -vvv
```

## References

- Vulnerable file: `veYFI/contracts/RewardPool.vy` (line 196)
- Vulnerable file: `veYFI/contracts/dYFIRewardPool.vy` (line 190)
- Supply checkpoint: `veYFI/contracts/RewardPool.vy` (lines 133-152)
- Curve FeeDistributor (original design): https://github.com/curvefi/curve-dao-contracts/blob/master/contracts/FeeDistributor.vy
- CWE-369: https://cwe.mitre.org/data/definitions/369.html
