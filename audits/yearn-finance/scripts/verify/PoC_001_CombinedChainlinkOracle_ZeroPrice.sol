// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

// Mock Chainlink aggregator that can return arbitrary answers
contract MockChainlinkOracle {
    int256 public price;
    uint256 public updatedAt;
    uint8 public decimals_ = 8;

    constructor(int256 _price) {
        price = _price;
        updatedAt = block.timestamp;
    }

    function setPrice(int256 _price) external {
        price = _price;
        updatedAt = block.timestamp;
    }

    function decimals() external view returns (uint8) {
        return decimals_;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt_,
            uint80 answeredInRound
        )
    {
        return (1, price, block.timestamp, updatedAt, 1);
    }
}

contract CombinedChainlinkOraclePoC is Test {
    MockChainlinkOracle yfiOracle;
    MockChainlinkOracle ethOracle;

    int256 constant SCALE = 1e18;

    function setUp() public {
        // Normal prices: YFI = $7000, ETH = $3500
        yfiOracle = new MockChainlinkOracle(700000000000); // 7000 * 1e8
        ethOracle = new MockChainlinkOracle(350000000000); // 3500 * 1e8
    }

    // Simulates the CombinedChainlinkOracle.latestRoundData() logic from line 30
    function _getPrice() internal view returns (int256) {
        (, int256 yfiAnswer,,,) = yfiOracle.latestRoundData();
        (, int256 ethAnswer,,,) = ethOracle.latestRoundData();
        // This is the vulnerable line from CombinedChainlinkOracle.vy:30
        return yfiAnswer * SCALE / ethAnswer;
    }

    function test_NormalPrice() public view {
        int256 price = _getPrice();
        // YFI/ETH = 7000/3500 = 2.0 ETH per YFI
        assertEq(price, 2e18);
    }

    function test_DivisionByZero_ETH_ZeroPrice() public {
        // Simulate ETH/USD returning 0 (circuit breaker event)
        ethOracle.setPrice(0);

        // This REVERTS with division by zero, bricking all redemptions
        vm.expectRevert();
        _getPrice();
    }

    function test_NegativePrice_BothFeeds() public {
        // Both feeds return negative (extreme anomaly)
        yfiOracle.setPrice(-700000000000);
        ethOracle.setPrice(-350000000000);

        // negative / negative = positive -- produces VALID-LOOKING but WRONG price
        int256 price = _getPrice();
        // Result is 2e18 (same as normal!), completely masking the anomaly
        assertEq(price, 2e18);
    }

    function test_NegativeETH_PositiveYFI() public {
        // ETH feed returns negative, YFI stays positive
        ethOracle.setPrice(-350000000000);

        // positive / negative = negative
        int256 price = _getPrice();
        // Price is -2e18, which when converted to uint256 in Vyper 0.3.7 would REVERT
        // This bricks redemptions just like the zero case
        assertTrue(price < 0);
    }
}
