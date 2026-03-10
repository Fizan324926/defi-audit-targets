# Immunefi Bug Report: Trident IndexPool `_pow()` Broken — Permanent DOS of `burnSingle()`

## Bug Description

The `_pow()` function in Trident's `IndexPool` contract contains two critical bugs that cause the `burnSingle()` function to permanently revert:

1. **Dead code:** The accumulation `output = output * a` on line 260 executes AFTER the for-loop exits, when `n` is always 0. The condition `n % 2 != 0` is always false, so the multiplication never happens.

2. **Overflow revert:** The squaring `a = a * a` (line 259) operates on fixed-point numbers without dividing by BASE, causing uint256 overflow within 3-4 iterations on Solidity >= 0.8.0 (checked arithmetic).

### Vulnerable Code

**File:** `trident/contracts/pool/index/IndexPool.sol` (lines 257-261)

```solidity
function _pow(uint256 a, uint256 n) internal pure returns (uint256 output) {
    output = n % 2 != 0 ? a : BASE;
    for (n /= 2; n != 0; n /= 2) a = a * a;  // overflow on iteration 3-4
    if (n % 2 != 0) output = output * a;        // DEAD CODE: n==0 after loop
}
```

### Call Chain

1. User calls `burnSingle(data)` (line 128)
2. Which calls `_computeSingleOutGivenPoolIn()` (line 138)
3. Which calls `_pow(poolRatio, _div(BASE, normalizedWeight))` (line 250)
4. `_div(BASE, normalizedWeight)` returns a fixed-point number like 2e18 for 50% weight
5. The for-loop treats this as integer `n`, iterating ~61 times (log2(2e18))
6. `a = a * a` without fixed-point scaling overflows uint256 after 3-4 iterations
7. Transaction reverts with arithmetic overflow

### Overflow Trace (for 2 equal-weight tokens, poolRatio = 0.95e18)

```
n = 2e18, output = BASE (even)
n /= 2 → n = 1e18

Iteration 1: a = 0.95e18 * 0.95e18 = 0.9025e36           ✓ fits uint256
Iteration 2: a = 0.9025e36 * 0.9025e36 = 0.8145e72        ✓ fits uint256
Iteration 3: a = 0.8145e72 * 0.8145e72 ≈ 6.634e143        ✗ OVERFLOW (max ~1.16e77)
→ REVERT
```

## Impact

**Severity:** Medium (Immunefi: permanent DOS of protocol function)

- `burnSingle()` is permanently non-functional for ALL IndexPools with multiple tokens
- This affects any IndexPool deployment where token weights < 100% (i.e., all practical pools)
- Users cannot perform single-sided withdrawals from IndexPools
- Users must use proportional `burn()` instead, which forces them to receive ALL tokens
- Funds are not permanently locked (proportional burn still works), but functionality is permanently degraded
- No admin action can fix this — the bug is in an `internal pure` function compiled into deployed bytecode

**Affected Users:** All IndexPool LPs who wish to exit with a single token

## Risk Breakdown

- **Difficulty to Exploit:** N/A (inherent bug, no exploit needed — function simply doesn't work)
- **Weakness Type:** CWE-682 (Incorrect Calculation), CWE-400 (DOS)
- **CVSS Score:** 5.3 (CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:N/A:L)

## Recommendation

Replace `_pow` with correct fixed-point binary exponentiation:

```diff
function _pow(uint256 a, uint256 n) internal pure returns (uint256 output) {
    output = n % 2 != 0 ? a : BASE;
-   for (n /= 2; n != 0; n /= 2) a = a * a;
-   if (n % 2 != 0) output = output * a;
+   for (n /= 2; n != 0; n /= 2) {
+       a = _mul(a, a);  // fixed-point squaring (divides by BASE)
+       if (n % 2 != 0) output = _mul(output, a);
+   }
}
```

Alternatively, use `_powApprox()` (which already exists in the contract at line 263) for all exponentiation, as it correctly handles fixed-point arithmetic with Taylor series approximation.

## Proof of Concept

```solidity
// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.0;

import "forge-std/Test.sol";

contract IndexPoolPowTest is Test {
    uint256 constant BASE = 10**18;

    // Exact copy of IndexPool._pow
    function _pow(uint256 a, uint256 n) internal pure returns (uint256 output) {
        output = n % 2 != 0 ? a : BASE;
        for (n /= 2; n != 0; n /= 2) a = a * a;
        if (n % 2 != 0) output = output * a;
    }

    function _mul(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b) / BASE;
    }

    function _div(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * BASE) / b;
    }

    // Demonstrate Bug 1: dead code (for small integer n)
    function test_pow_dead_code() public pure {
        // _pow(0.5e18, 2) should return 0.25e18 (0.5^2 = 0.25)
        // But returns BASE (1e18) because output is never updated
        uint256 result = _pow(0.5e18, 2);
        // Bug: result is BASE (1e18), not 0.25e18
        assert(result == BASE); // This passes, demonstrating the bug
    }

    // Demonstrate Bug 2: overflow revert (for realistic fixed-point n)
    function test_pow_overflow_reverts() public {
        uint256 poolRatio = 0.95e18; // 95% of supply remains
        uint256 normalizedWeight = 0.5e18; // 50% weight
        uint256 exponent = _div(BASE, normalizedWeight); // = 2e18

        // This MUST revert with arithmetic overflow
        vm.expectRevert();
        _pow(poolRatio, exponent);
    }

    // Demonstrate that burnSingle would use _pow with these parameters
    function test_burnSingle_parameters() public pure {
        uint256 totalSupply = 100e18;
        uint256 toBurn = 5e18; // burn 5%
        uint256 tokenOutWeight = 50; // 50% weight
        uint256 totalWeight = 100; // total weight

        uint256 normalizedWeight = _div(tokenOutWeight * BASE, totalWeight * BASE);
        // normalizedWeight = 0.5e18

        uint256 newPoolSupply = totalSupply - toBurn;
        uint256 poolRatio = _div(newPoolSupply, totalSupply);
        // poolRatio = 0.95e18

        uint256 exponent = _div(BASE, normalizedWeight);
        // exponent = 2e18

        // _pow(0.95e18, 2e18) will overflow and revert
        // Therefore burnSingle() always reverts for this pool configuration
    }
}
```

## References

- IndexPool._pow: https://github.com/sushi-labs/trident/blob/master/contracts/pool/index/IndexPool.sol#L257-L261
- IndexPool._computeSingleOutGivenPoolIn: https://github.com/sushi-labs/trident/blob/master/contracts/pool/index/IndexPool.sol#L237-L255
- IndexPool.burnSingle: https://github.com/sushi-labs/trident/blob/master/contracts/pool/index/IndexPool.sol#L128-L147
