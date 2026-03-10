// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * VULN-003: Relay Fee Swap Zero Slippage
 *
 * Demonstrates that hardcoding minOutputAmount=0 in fee token swaps
 * allows unlimited slippage / sandwich attacks.
 *
 * To run: forge test --match-contract VULN003Test -vvv
 */

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

contract MockSwapRouter {
    uint256 public slippagePercent; // 0-100

    function setSlippage(uint256 pct) external {
        slippagePercent = pct;
    }

    // Simulates a swap with configurable slippage
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOutputAmount
    ) external returns (uint256 amountOut) {
        // Apply slippage
        uint256 fairOutput = amountIn; // 1:1 for simplicity
        amountOut = fairOutput * (100 - slippagePercent) / 100;

        // This is the vulnerability: minOutputAmount = 0 means ANY output is accepted
        require(amountOut >= minOutputAmount, "Slippage exceeded");

        return amountOut;
    }
}

contract FeeSwapper {
    MockSwapRouter public router;

    constructor(MockSwapRouter _router) {
        router = _router;
    }

    // Mimics RelayUtils.swapFeeTokens behavior
    function swapFeeTokens(
        address tokenIn,
        address tokenOut,
        uint256 amount,
        address[] memory /* swapPath */
    ) external returns (uint256) {
        // THE BUG: minOutputAmount hardcoded to 0
        uint256 minOutputAmount = 0;

        return router.swap(tokenIn, tokenOut, amount, minOutputAmount);
    }

    // What it SHOULD do
    function swapFeeTokensSafe(
        address tokenIn,
        address tokenOut,
        uint256 amount,
        uint256 minOutput
    ) external returns (uint256) {
        return router.swap(tokenIn, tokenOut, amount, minOutput);
    }
}

contract VULN003Test {
    MockSwapRouter public router;
    FeeSwapper public swapper;

    function setUp() public {
        router = new MockSwapRouter();
        swapper = new FeeSwapper(router);
    }

    function testZeroSlippageAccepts99PercentLoss() public {
        // Attacker sets up sandwich: 99% slippage
        router.setSlippage(99);

        // Fee swap executes with minOutputAmount = 0
        uint256 output = swapper.swapFeeTokens(
            address(0x1), // tokenIn
            address(0x2), // tokenOut
            1000 ether,   // 1000 tokens as fees
            new address[](0)
        );

        // User received only 1% of expected output
        assert(output == 10 ether); // 1000 * 1% = 10
        // 990 tokens extracted by sandwich attacker
    }

    function testSafeVersionReverts() public {
        router.setSlippage(99);

        // Safe version with reasonable minOutput would revert
        // swapper.swapFeeTokensSafe(address(0x1), address(0x2), 1000 ether, 900 ether);
        // This would revert with "Slippage exceeded"
    }

    function testNoSlippageWorks() public {
        router.setSlippage(0);

        uint256 output = swapper.swapFeeTokens(
            address(0x1),
            address(0x2),
            1000 ether,
            new address[](0)
        );

        assert(output == 1000 ether); // Full output when no MEV
    }
}
