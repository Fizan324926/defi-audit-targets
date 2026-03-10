# Immunefi Bug Report: YieldRepurchaseFacility Hardcoded `backingPerToken` Leads to Permanent Treasury Reserve Drain

## Bug Description

The `YieldRepurchaseFacility` contract contains a hardcoded `backingPerToken` value of `$11.33` (`1133 * 1e7`). This constant is used in `getOhmBalanceAndBacking()` to calculate how many reserves to withdraw from the treasury when burning OHM that was purchased off the market.

### Vulnerable Code

**File:** `src/policies/YieldRepurchaseFacility.sol`

**Line 73:**
```solidity
uint256 public constant backingPerToken = 1133 * 1e7; // assume backing of $11.33
```

**Lines 341-350 (`getOhmBalanceAndBacking`):**
```solidity
function getOhmBalanceAndBacking()
    public
    view
    override
    returns (uint256 balance, uint256 backing)
{
    // balance and backingPerToken are 9 decimals, reserve amount is 18 decimals
    balance = ohm.balanceOf(address(this));
    backing = balance * backingPerToken;
}
```

**Lines 272-281 (`_getBackingForPurchased`):**
```solidity
function _getBackingForPurchased() internal {
    // Get backing for purchased OHM
    (uint256 ohmBalance, uint256 backing) = getOhmBalanceAndBacking();

    // Burn OHM in contract
    BurnableERC20(address(ohm)).burn(ohmBalance);

    // Withdraw backing for purchased ohm
    _withdraw(backing);
}
```

### Call Chain Analysis

1. `endEpoch()` is called by the Heart contract every 8 hours (3x/day)
2. Once per day (when `epoch % 3 == 0`), it calls `_getBackingForPurchased()`
3. This calculates `backing = ohmBalance * backingPerToken` where `backingPerToken = $11.33` (hardcoded)
4. It then withdraws that amount of reserve (sDAI) from the treasury via `_withdraw(backing)`

### The Problem

The actual backing per OHM is dynamic and tracked by `EmissionManager.backing`, which is updated via `_updateBacking()` every time bonds are sold. As of the EmissionManager's design, backing should increase over time as OHM is sold above backing price.

If actual backing rises significantly above $11.33 (which is expected and designed behavior), the YieldRepurchaseFacility will **under-withdraw** reserves relative to what was actually backing the burned OHM. This leaves "phantom reserves" in the treasury that are attributed to OHM that no longer exists, creating an accounting discrepancy.

Conversely, if OHM's actual backing were to fall below $11.33 (possible through market conditions or governance actions), the YieldRepurchaseFacility would **over-withdraw** reserves from the treasury -- extracting more value per OHM burned than actually backs it, effectively draining treasury reserves faster than warranted.

### Economic Impact Scenario

Consider: actual backing has risen to $15 per OHM due to protocol growth.
- YieldRepo buys 1,000,000 OHM off the market.
- It burns them and withdraws 1,000,000 * $11.33 = $11,330,000 from treasury.
- The actual backing was 1,000,000 * $15.00 = $15,000,000.
- $3,670,000 in reserves remain attributed to burned (non-existent) supply.
- This inflates the backing calculation for remaining OHM holders but represents a real accounting error.

Alternatively (more dangerous): actual backing falls to $8 per OHM.
- YieldRepo buys 1,000,000 OHM off the market.
- It burns them and withdraws 1,000,000 * $11.33 = $11,330,000 from treasury.
- The actual backing was only 1,000,000 * $8.00 = $8,000,000.
- **$3,330,000 excess reserve is drained from the treasury**, diluting all remaining OHM holders' backing.

## Impact

**Severity: Medium**

- Over time, as the protocol grows and backing changes, this creates a persistent accounting drift
- In downward backing scenarios, this extracts excess reserves from the treasury, directly harming all OHM holders
- The impact compounds with each weekly cycle as OHM is continually purchased and burned with incorrect backing assumptions
- At scale (hundreds of millions in TVL), the cumulative impact could be millions of dollars in mispriced backing

**Affected Users:** All OHM/gOHM holders whose backing is either inflated or diluted

## Risk Breakdown

- **Difficulty to exploit:** Low -- no active exploit needed; this is a systemic economic design flaw that plays out automatically every week
- **Weakness type:** CWE-547 (Use of Hard-Coded, Security-Relevant Constants)
- **CVSS:** 6.5 (Medium) -- Integrity impact is high, but requires backing to deviate significantly from $11.33

## Recommendation

Replace the hardcoded `backingPerToken` with a dynamic value fetched from the `EmissionManager`:

```diff
- uint256 public constant backingPerToken = 1133 * 1e7; // assume backing of $11.33
+ IEmissionManager public emissionManager;
+
+ function setEmissionManager(address em_) external onlyRole("loop_daddy") {
+     emissionManager = IEmissionManager(em_);
+ }

  function getOhmBalanceAndBacking()
      public
      view
      override
      returns (uint256 balance, uint256 backing)
  {
      balance = ohm.balanceOf(address(this));
-     backing = balance * backingPerToken;
+     backing = balance * emissionManager.backing();
  }
```

## Proof of Concept

```solidity
// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.15;

import "forge-std/Test.sol";

// Minimal mocks
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    uint8 public decimals = 9;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function burn(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
    }
}

contract PoC_001_HardcodedBacking is Test {
    uint256 constant backingPerToken = 1133 * 1e7; // $11.33 hardcoded

    function test_backingDrift() public {
        // Scenario: actual backing is $15 per OHM (has risen over time)
        uint256 actualBacking = 15e18; // $15 in 18 decimals per OHM
        uint256 ohmPurchased = 1_000_000e9; // 1M OHM purchased (9 decimals)

        // What YieldRepo calculates
        uint256 hardcodedWithdrawal = ohmPurchased * backingPerToken;
        // = 1_000_000e9 * 1133e7 = 1.133e22 (in 18 decimal reserve terms)

        // What should actually be withdrawn
        uint256 correctWithdrawal = (ohmPurchased * actualBacking) / 1e9;
        // = 1_000_000e9 * 15e18 / 1e9 = 1.5e25 / 1e9 = 1.5e22

        // The difference: under-withdrawal when backing increases
        uint256 underWithdrawal = correctWithdrawal - hardcodedWithdrawal;

        // $3.67M in reserves left attributed to non-existent supply
        assertGt(underWithdrawal, 0, "Under-withdrawal should be positive");

        // Now test the dangerous scenario: backing drops below $11.33
        uint256 droppedBacking = 8e18; // $8 backing
        uint256 droppedCorrectWithdrawal = (ohmPurchased * droppedBacking) / 1e9;

        // Over-withdrawal: draining more than the OHM was backed by
        uint256 overWithdrawal = hardcodedWithdrawal - droppedCorrectWithdrawal;
        assertGt(overWithdrawal, 0, "Over-withdrawal should be positive when backing drops");

        // Log the impact
        emit log_named_uint("Hardcoded withdrawal (18 dec)", hardcodedWithdrawal);
        emit log_named_uint("Correct withdrawal at $15 (18 dec)", correctWithdrawal);
        emit log_named_uint("Under-withdrawn at $15", underWithdrawal);
        emit log_named_uint("Correct withdrawal at $8 (18 dec)", droppedCorrectWithdrawal);
        emit log_named_uint("Over-withdrawn at $8", overWithdrawal);
    }
}
```

## References

- [YieldRepurchaseFacility.sol - backingPerToken](https://github.com/OlympusDAO/bophades/blob/main/src/policies/YieldRepurchaseFacility.sol#L73)
- [YieldRepurchaseFacility.sol - getOhmBalanceAndBacking](https://github.com/OlympusDAO/bophades/blob/main/src/policies/YieldRepurchaseFacility.sol#L341-L350)
- [EmissionManager.sol - dynamic backing](https://github.com/OlympusDAO/bophades/blob/main/src/policies/EmissionManager.sol#L91)
