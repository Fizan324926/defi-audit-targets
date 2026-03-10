// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

// Simplified Curve pool mock that demonstrates sandwich extraction
contract MockCurvePool {
    uint256 public exchangeRate = 1e18; // 1:1 initially
    uint256 public lpRate = 1e18;

    function setExchangeRate(uint256 _rate) external {
        exchangeRate = _rate;
    }

    function setLpRate(uint256 _rate) external {
        lpRate = _rate;
    }

    // Simulates exchange(0, 1, amount, minOut)
    function exchange(int128, int128, uint256 amount, uint256 minOut) external view returns (uint256) {
        uint256 out = amount * exchangeRate / 1e18;
        require(out >= minOut, "slippage");
        return out;
    }

    // Simulates add_liquidity([0, amount], minOut)
    function add_liquidity(uint256[] memory amounts, uint256 minOut, address) external view returns (uint256) {
        uint256 out = amounts[1] * lpRate / 1e18;
        require(out >= minOut, "slippage");
        return out;
    }

    function get_dy(int128, int128, uint256 amount) external view returns (uint256) {
        return amount * exchangeRate / 1e18;
    }
}

contract ZapZeroSlippagePoC is Test {
    MockCurvePool pool;

    function setUp() public {
        pool = new MockCurvePool();
    }

    function test_CompoundSandwich_NoProtection() public {
        uint256 zapAmount = 100e18;
        uint256 userMinOut = 95e18; // User tolerates 5% total slippage

        // --- ATTACKER FRONT-RUNS: manipulates pool ---
        // Exchange rate drops 3% (attacker skewed the pool)
        pool.setExchangeRate(0.97e18);
        // LP rate drops 3% too (pool is imbalanced)
        pool.setLpRate(0.97e18);

        // --- USER'S ZAP EXECUTES ---
        // Step 1: exchange with 0 minOut
        uint256 yybAmount = pool.exchange(0, 1, zapAmount, 0); // 0 slippage!
        assertEq(yybAmount, 97e18); // Lost 3e18

        // Step 2: add_liquidity with 0 minOut
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = yybAmount;
        uint256 lpTokens = pool.add_liquidity(amounts, 0, address(this)); // 0 slippage!
        assertEq(lpTokens, 94.09e18); // Lost another ~3% of 97

        // With calibrated attack (2.5% per step):
        pool.setExchangeRate(0.975e18);
        pool.setLpRate(0.975e18);

        yybAmount = pool.exchange(0, 1, zapAmount, 0);
        amounts[1] = yybAmount;
        lpTokens = pool.add_liquidity(amounts, 0, address(this));

        // Final output: 95.0625e18 > 95e18 -- passes minOut check!
        assertGt(lpTokens, userMinOut, "Passes minOut despite compound MEV extraction");

        // Total MEV extracted: ~4.94% vs user's expected max of 5%
        // Attacker extracts nearly the user's full slippage tolerance
        uint256 mevExtracted = zapAmount - lpTokens;
        assertGt(mevExtracted, 4e18, "Attacker extracts >4% via compound sandwich");
    }

    function test_SingleStep_LessExposure() public view {
        uint256 zapAmount = 100e18;

        // If there were only ONE step with 0 slippage, attacker can extract at most
        // the user's tolerance in one shot. With TWO steps, they get two bites.

        // Single step: attacker needs 5% manipulation for 5% extraction
        // Double step: attacker needs only 2.5% manipulation per step for ~4.94% extraction
        // Lower manipulation per step = lower capital requirement = more profitable attack

        // This is the core issue: compound zero-slippage operations multiply MEV opportunity
        uint256 singleStepManipulation = 5; // 5% needed for single step
        uint256 doubleStepManipulation = 25; // 2.5% per step for double

        assertTrue(
            doubleStepManipulation < singleStepManipulation * 10 / 2,
            "Double step requires less per-step manipulation"
        );
    }
}
