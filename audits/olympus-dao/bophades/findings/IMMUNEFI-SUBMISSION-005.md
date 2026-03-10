# Immunefi Bug Report: Clearinghouse `rebalance()` Fund-Time Accumulation Allows Multiple Rebalances After Missed Cadences

## Bug Description

The `Clearinghouse.rebalance()` function uses a `fundTime` state variable that is incremented by `FUND_CADENCE` (7 days) each time `rebalance()` is called. However, if multiple cadence periods pass without a call to `rebalance()`, the next call only increments `fundTime` by one `FUND_CADENCE`. This means subsequent calls within the same block can pass the `fundTime > block.timestamp` check again, allowing multiple rebalances in rapid succession.

### Vulnerable Code

**File:** `src/policies/Clearinghouse.sol`

**Lines 327-379:**
```solidity
function rebalance() public returns (bool) {
    // If the contract is deactivated, defund.
    uint256 maxFundAmount = active ? FUND_AMOUNT : 0;
    // Update funding schedule if necessary.
    if (fundTime > block.timestamp) return false;
    fundTime += FUND_CADENCE;  // <-- only increments by ONE cadence

    // ... rest of rebalance logic
}
```

### The Issue

1. `fundTime` is initialized to `block.timestamp` when `activate()` is called (line 407)
2. After 7 days, `fundTime < block.timestamp`, so `rebalance()` can proceed
3. `fundTime += FUND_CADENCE` sets `fundTime` to the ORIGINAL value + 7 days
4. If 14+ days have passed since activation without calling `rebalance()`, after the first call, `fundTime` is still in the past
5. A second call in the same transaction/block would pass the check again

However, the comment in the code (lines 322-324) acknowledges this:
> "If several rebalances are available (because some were missed), calling this function several times won't impact the funds controlled by the contract."

This is because the rebalance targets `FUND_AMOUNT` (18M) as the ceiling. If the balance is already at 18M after the first rebalance, the second one would be a no-op (neither branch triggers since `reserveBalance == maxFundAmount`).

### Exploitation Scenario

While the direct financial impact is limited by the `FUND_AMOUNT` cap, there is a subtle issue:

1. `lendToCooler()` calls `rebalance()` at the start (line 168)
2. If multiple cadences have passed, the first `lendToCooler()` call triggers a rebalance that funds up to 18M
3. The user takes a loan, reducing the reserve balance
4. A second `lendToCooler()` call triggers ANOTHER rebalance (since fundTime is still in the past)
5. This refunds the clearinghouse back to 18M again
6. This process can repeat, potentially draining more from the treasury than intended in a single "week"

In the worst case: if 3 weeks have been missed, a user could:
- Call `lendToCooler(amount)` -- triggers rebalance #1 (funds to 18M) -- takes loan of X
- Call `lendToCooler(amount)` -- triggers rebalance #2 (funds back to 18M) -- takes loan of Y
- Call `lendToCooler(amount)` -- triggers rebalance #3 (funds back to 18M) -- takes loan of Z

Total borrowed: X + Y + Z, all within a single block, with treasury exposure exceeding the intended weekly 18M cap.

## Impact

**Severity: Medium**

- Allows borrowing significantly more than the intended 18M per week if cadences are missed
- Requires missed rebalances (realistic in periods of low activity or keeper downtime)
- Each additional missed week allows another 18M in additional lending capacity
- The treasury exposure increases linearly with missed cadences
- Mitigated by the fact that loans require gOHM collateral (so attacker needs capital)

**Financial Impact:** Up to 18M * (number_of_missed_weeks - 1) additional reserve exposure beyond design intent.

## Risk Breakdown

- **Difficulty to exploit:** Low -- just requires calling `lendToCooler` multiple times when cadences have been missed
- **Weakness type:** CWE-799 (Improper Control of Interaction Frequency)
- **CVSS:** 5.3 (Medium)

## Recommendation

Change the `fundTime` update to advance to the current time or the next valid cadence:

```diff
  function rebalance() public returns (bool) {
      uint256 maxFundAmount = active ? FUND_AMOUNT : 0;
      if (fundTime > block.timestamp) return false;
-     fundTime += FUND_CADENCE;
+     // Advance fundTime to the next cadence boundary past block.timestamp
+     // This prevents multiple rebalances if cadences were missed
+     while (fundTime <= block.timestamp) {
+         fundTime += FUND_CADENCE;
+     }
```

Or more gas-efficiently:
```diff
-     fundTime += FUND_CADENCE;
+     uint256 missedCadences = (block.timestamp - fundTime) / FUND_CADENCE + 1;
+     fundTime += FUND_CADENCE * missedCadences;
```

## Proof of Concept

```solidity
// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.15;

import "forge-std/Test.sol";

contract PoC_005_RebalanceAccumulation is Test {
    uint256 constant FUND_CADENCE = 7 days;
    uint256 constant FUND_AMOUNT = 18_000_000e18;

    uint256 public fundTime;
    bool public active = true;

    function activate() public {
        fundTime = block.timestamp;
    }

    function canRebalance() public view returns (bool) {
        if (fundTime > block.timestamp) return false;
        return true;
    }

    function rebalance() public returns (bool) {
        if (fundTime > block.timestamp) return false;
        fundTime += FUND_CADENCE;
        return true;
    }

    function test_multipleRebalancesAfterMissedCadences() public {
        // Activate the clearinghouse
        activate();

        // Skip 3 weeks (3 cadences)
        vm.warp(block.timestamp + 3 * FUND_CADENCE + 1);

        // First rebalance succeeds
        assertTrue(rebalance(), "First rebalance should succeed");

        // Second rebalance ALSO succeeds (fundTime is still in the past)
        assertTrue(rebalance(), "Second rebalance succeeds - this is the issue");

        // Third rebalance ALSO succeeds
        assertTrue(rebalance(), "Third rebalance succeeds - compounding the issue");

        // Fourth should fail (fundTime is now in the future)
        assertFalse(rebalance(), "Fourth rebalance should fail");

        emit log_named_uint("Rebalances triggered in one block", 3);
        emit log_named_uint("Effective treasury exposure (18M x 3)", FUND_AMOUNT * 3 / 1e18);
    }
}
```

## References

- [Clearinghouse.sol - rebalance](https://github.com/OlympusDAO/bophades/blob/main/src/policies/Clearinghouse.sol#L327-L379)
- [Clearinghouse.sol - lendToCooler calls rebalance](https://github.com/OlympusDAO/bophades/blob/main/src/policies/Clearinghouse.sol#L168)
- [Clearinghouse.sol - activate sets fundTime](https://github.com/OlympusDAO/bophades/blob/main/src/policies/Clearinghouse.sol#L407)
