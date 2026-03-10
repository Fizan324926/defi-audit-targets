// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @title PoC: OETHOracleRouter Unsafe int256 Cast
 * @notice Demonstrates that OETHOracleRouter's raw uint256() cast on Chainlink's
 *         int256 price wraps negative values to near-max uint256, while
 *         AbstractOracleRouter's SafeCast.toUint256() correctly reverts.
 *
 * Run:
 *   forge test --match-test testNegativePriceCast -vvv
 */
contract PoC_OETHOracleNegativePrice {
    using SafeCast for int256;

    /// @notice Simulates OETHOracleRouter behavior (VULNERABLE)
    /// Line 44: uint256 _price = uint256(_iprice).scaleBy(18, decimals);
    function oethRouterCast(int256 _iprice) external pure returns (uint256) {
        return uint256(_iprice);
    }

    /// @notice Simulates AbstractOracleRouter behavior (SAFE)
    /// Line 63: uint256 _price = _iprice.toUint256().scaleBy(18, decimals);
    function abstractRouterCast(int256 _iprice) external pure returns (uint256) {
        return _iprice.toUint256();
    }

    /// @notice Demonstrates the vulnerability with a negative price
    function testNegativePriceCast() external pure {
        int256 negativePrice = -1;

        // OETHOracleRouter path: wraps to max uint256
        uint256 oethResult = uint256(negativePrice);
        assert(oethResult == type(uint256).max);
        // This would be ~1.15e77 in 18-decimal units -- an astronomical "price"
        // that would pass through scaleBy and be returned to the vault

        // AbstractOracleRouter path: SafeCast reverts
        // Uncommenting the next line would revert with SafeCastOverflowedIntToUint
        // negativePrice.toUint256();

        // Demonstrate with a more realistic negative value
        int256 slightlyNegative = -100;
        uint256 oethResult2 = uint256(slightlyNegative);
        assert(oethResult2 == type(uint256).max - 99);
        // Still an astronomically large price

        // Demonstrate that positive prices work identically in both paths
        int256 normalPrice = 1e8; // $1.00 in 8 decimals (typical Chainlink format)
        assert(uint256(normalPrice) == normalPrice.toUint256());
    }
}
