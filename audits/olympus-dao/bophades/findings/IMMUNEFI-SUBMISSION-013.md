# Immunefi Bug Report: Operator `_regenerate` Low Side Withdrawal Approval Desync via ERC4626 Rounding Gap

## Bug Description

The `Operator._regenerate(false)` function manages TRSRY withdrawal approval for sReserve tokens. It converts shares to assets via `previewRedeem()` (rounds DOWN per ERC4626), compares against desired capacity, then converts the deficit back via `previewWithdraw()` (rounds UP). This creates a systematic rounding bias that accumulates over repeated regeneration cycles.

### Vulnerable Code

**File:** `src/policies/Operator.sol`, lines 657-690

```solidity
} else {
    _status.low.count = uint32(0);
    _status.low.observations = new bool[](_config.regenObserve);
    _status.low.nextObservation = uint32(0);
    _status.low.lastRegen = uint48(block.timestamp);

    uint256 capacity = fullCapacity(false);

    uint256 currentApproval = sReserve.previewRedeem(      // rounds DOWN
        TRSRY.withdrawApproval(address(this), sReserve)
    );
    unchecked {
        if (currentApproval < capacity) {
            TRSRY.increaseWithdrawApproval(
                address(this),
                sReserve,
                sReserve.previewWithdraw(capacity - currentApproval)  // rounds UP
            );
        } else if (currentApproval > capacity) {
            TRSRY.decreaseWithdrawApproval(
                address(this),
                sReserve,
                sReserve.previewWithdraw(currentApproval - capacity)  // rounds UP
            );
        }
    }

    RANGE.regenerate(false, capacity);
}
```

### Rounding Bias Analysis

1. `previewRedeem(shares)` → assets, rounds DOWN: actual value is `result + epsilon_1` where `0 <= epsilon_1 < 1`
2. When `currentApproval < capacity`: deficit is overestimated by up to `epsilon_1`
3. `previewWithdraw(deficit)` rounds UP: adds up to 1 more share than needed
4. Net per-cycle error: up to 2 shares (2 wei of sReserve) upward drift in approval

In the `currentApproval > capacity` branch: `previewWithdraw` rounds UP, meaning MORE shares are subtracted than necessary, creating the opposite bias (over-decremented).

## Impact

**Severity: Low**

- Per-cycle rounding error: 1-2 wei of sReserve shares (negligible in USD)
- Accumulates over thousands of regeneration cycles to hundreds/thousands of wei
- The asymmetric rounding in the decrease branch could cause approval under-provisioning, leading to swap reverts at capacity boundaries

## Risk Breakdown

- **Difficulty to exploit:** Very High — not directly exploitable, accumulates naturally
- **Weakness type:** CWE-682 (Incorrect Calculation), CWE-197 (Numeric Truncation Error)
- **CVSS:** 2.0 (Low)

## Recommendation

Compare in share terms to avoid round-trip conversion:

```diff
  uint256 capacity = fullCapacity(false);
+ uint256 capacityInShares = sReserve.previewWithdraw(capacity);
- uint256 currentApproval = sReserve.previewRedeem(
-     TRSRY.withdrawApproval(address(this), sReserve)
- );
+ uint256 currentApprovalShares = TRSRY.withdrawApproval(address(this), sReserve);
  unchecked {
-     if (currentApproval < capacity) {
+     if (currentApprovalShares < capacityInShares) {
          TRSRY.increaseWithdrawApproval(
              address(this), sReserve,
-             sReserve.previewWithdraw(capacity - currentApproval)
+             capacityInShares - currentApprovalShares
          );
-     } else if (currentApproval > capacity) {
+     } else if (currentApprovalShares > capacityInShares) {
          TRSRY.decreaseWithdrawApproval(
              address(this), sReserve,
-             sReserve.previewWithdraw(currentApproval - capacity)
+             currentApprovalShares - capacityInShares
          );
      }
  }
```

## Proof of Concept

```solidity
// SPDX-License-Identifier: Unlicense
pragma solidity >=0.8.0;

import {Test} from "forge-std/Test.sol";

contract PoC_013_RegenerateDesync is Test {
    uint256 totalAssets = 100_000_000e18 + 1;
    uint256 totalSupply = 100_000_000e18;

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return shares * totalAssets / totalSupply; // rounds DOWN
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return (assets * totalSupply + totalAssets - 1) / totalAssets; // rounds UP
    }

    function test_roundingDrift() public {
        uint256 approval = 10_000_000e18;
        uint256 capacity = 10_000_000e18;

        for (uint256 i = 0; i < 100; i++) {
            uint256 approvalAssets = previewRedeem(approval);
            if (approvalAssets < capacity) {
                approval += previewWithdraw(capacity - approvalAssets);
            } else if (approvalAssets > capacity) {
                uint256 excess = previewWithdraw(approvalAssets - capacity);
                approval = approval > excess ? approval - excess : 0;
            }
        }

        assertGt(approval, 10_000_000e18, "Approval drifted upward");
    }
}
```

## References

- [Operator._regenerate](https://github.com/OlympusDAO/bophades/blob/main/src/policies/Operator.sol#L657-L690)
- [ERC4626 rounding spec](https://eips.ethereum.org/EIPS/eip-4626)
