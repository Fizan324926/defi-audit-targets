// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.0;

import "forge-std/Test.sol";

/// @title PoC for IndexPool._pow() broken binary exponentiation
/// @notice Demonstrates two bugs:
///   1. Dead code: output*a never executes after loop (n always 0)
///   2. Overflow revert: a*a without fixed-point scaling overflows uint256
/// @dev Run: forge test --match-contract PoC_002 -vvv
contract PoC_002_IndexPool_Broken_Pow is Test {
    uint256 constant BASE = 10**18;

    // ==========================================
    // Exact copy of IndexPool math functions
    // ==========================================

    function _mul(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b) / BASE;
    }

    function _div(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * BASE) / b;
    }

    // EXACT COPY of IndexPool._pow (the buggy version)
    function _pow_buggy(uint256 a, uint256 n) internal pure returns (uint256 output) {
        output = n % 2 != 0 ? a : BASE;
        for (n /= 2; n != 0; n /= 2) a = a * a;
        if (n % 2 != 0) output = output * a; // DEAD CODE
    }

    // ==========================================
    // Bug 1: Dead code demonstration
    // ==========================================

    /// @notice For small integer exponents, _pow returns wrong results
    function test_bug1_deadCode_n2() public pure {
        // _pow(0.5e18, 2) should return _mul(0.5e18, 0.5e18) = 0.25e18
        // But since n=2 is even, output=BASE, and the loop squares a
        // but never multiplies into output (dead code after loop)
        uint256 result = _pow_buggy(0.5e18, 2);
        // Bug: returns BASE (1e18) instead of 0.25e18
        assertEq(result, BASE, "Bug: _pow(0.5e18, 2) returns BASE instead of 0.25e18");
    }

    /// @notice For n=3, _pow returns only `a` instead of a^3
    function test_bug1_deadCode_n3() public pure {
        // _pow(2e18, 3) should be 8e18 in fixed-point
        // But n=3 is odd, so output=a=2e18
        // Loop: n/2=1, a=2e18*2e18=4e36 (NOT fixed-point: should be 4e18)
        // After loop: n=0, dead code, output stays 2e18
        uint256 result = _pow_buggy(2e18, 3);
        assertEq(result, 2e18, "Bug: _pow(2e18, 3) returns 2e18 instead of 8e18");
    }

    /// @notice For n=1, _pow happens to be correct
    function test_correct_for_n1() public pure {
        uint256 result = _pow_buggy(0.7e18, 1);
        assertEq(result, 0.7e18, "_pow is correct for n=1");
    }

    /// @notice For n=0, _pow is correct (returns BASE)
    function test_correct_for_n0() public pure {
        uint256 result = _pow_buggy(0.7e18, 0);
        assertEq(result, BASE, "_pow is correct for n=0");
    }

    // ==========================================
    // Bug 2: Overflow revert in realistic usage
    // ==========================================

    /// @notice Demonstrates the overflow when called with realistic parameters
    /// This is what happens when burnSingle() is called on an IndexPool
    function test_bug2_overflowRevert_realistic() public {
        // Realistic parameters from _computeSingleOutGivenPoolIn:
        // - poolRatio = 0.95e18 (burning 5% of supply)
        // - normalizedWeight = 0.5e18 (50% weight token)
        // - exponent = _div(BASE, 0.5e18) = 2e18

        uint256 poolRatio = 0.95e18;
        uint256 normalizedWeight = 0.5e18;
        uint256 exponent = _div(BASE, normalizedWeight); // = 2e18

        // This MUST revert with arithmetic overflow
        // Because: a*a without /BASE causes overflow on iteration 3
        // Iteration 1: a = 0.9025e36    (fits)
        // Iteration 2: a = 0.8145e72    (fits)
        // Iteration 3: a = 6.63e143     (OVERFLOW! > 1.16e77 = uint256.max)
        vm.expectRevert();
        _pow_buggy(poolRatio, exponent);
    }

    /// @notice Even for 4 equal-weight tokens, it reverts
    function test_bug2_overflowRevert_fourTokens() public {
        uint256 poolRatio = 0.95e18;
        uint256 normalizedWeight = 0.25e18; // 25% weight (4 equal tokens)
        uint256 exponent = _div(BASE, normalizedWeight); // = 4e18

        vm.expectRevert();
        _pow_buggy(poolRatio, exponent);
    }

    // ==========================================
    // Impact: burnSingle always reverts
    // ==========================================

    /// @notice Simulates _computeSingleOutGivenPoolIn to show burnSingle DOS
    function test_burnSingleDOS() public {
        uint256 tokenOutBalance = 1000e18;
        uint256 tokenOutWeight = 50;
        uint256 totalSupply = 100e18;
        uint256 totalWeight = 100;
        uint256 toBurn = 5e18; // burn 5 LP tokens
        uint256 swapFee = 0.003e18; // 0.3% fee

        // This is the exact computation from _computeSingleOutGivenPoolIn
        uint256 normalizedWeight = _div(tokenOutWeight, totalWeight);
        uint256 newPoolSupply = totalSupply - toBurn;
        uint256 poolRatio = _div(newPoolSupply, totalSupply);

        // This call will revert, making burnSingle impossible
        vm.expectRevert();
        _pow_buggy(poolRatio, _div(BASE, normalizedWeight));
    }

    // ==========================================
    // Correct implementation for reference
    // ==========================================

    function _pow_fixed(uint256 a, uint256 n) internal pure returns (uint256 output) {
        output = n % 2 != 0 ? a : BASE;
        for (n /= 2; n != 0; n /= 2) {
            a = _mul(a, a);  // fixed-point squaring
            if (n % 2 != 0) output = _mul(output, a);
        }
    }

    /// @notice Demonstrate the fixed version works
    function test_fixedPow_works() public pure {
        uint256 poolRatio = 0.95e18;
        uint256 exponent = 2; // integer exponent

        uint256 result = _pow_fixed(poolRatio, exponent);
        // 0.95^2 = 0.9025
        assertApproxEqAbs(result, 0.9025e18, 1, "Fixed _pow should compute 0.95^2 correctly");
    }
}
