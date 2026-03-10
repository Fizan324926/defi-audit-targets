// SPDX-License-Identifier: Unlicense
pragma solidity >=0.8.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Demonstrates inverse price truncation in Operator._activate(false)
/// @dev Run with: forge test --match-test test_inversePriceTruncation -vv
contract PoC_007_InversePriceTruncation is Test {

    uint8 constant ORACLE_DECIMALS = 18;

    function test_inversePriceTruncationAtHighPrices() public {
        // Scenario: OHM at $333 per reserve unit, cushion at 10% below MA
        uint256 cushionPrice = 333e18;
        uint256 currentPrice = 340e18;

        uint256 invCushionCurrent = 10 ** (ORACLE_DECIMALS * 2) / cushionPrice;
        uint256 invPriceCurrent = 10 ** (ORACLE_DECIMALS * 2) / currentPrice;

        console2.log("=== OHM at $333-$340 ===");
        console2.log("invCushionPrice (truncated):", invCushionCurrent);
        console2.log("invCurrentPrice (truncated):", invPriceCurrent);
        console2.log("Price difference:", invCushionCurrent - invPriceCurrent);

        // Very close prices (1 wei apart)
        uint256 priceA = 100e18;
        uint256 priceB = 100e18 + 1;
        uint256 invA = 10 ** (ORACLE_DECIMALS * 2) / priceA;
        uint256 invB = 10 ** (ORACLE_DECIMALS * 2) / priceB;

        console2.log("=== Prices 1 wei apart ===");
        console2.log("invA:", invA);
        console2.log("invB:", invB);
        console2.log("Difference:", invA - invB);

        // Extreme case
        uint256 extremePrice = 1e35;
        uint256 extremePriceNear = 1e35 + 3e34;
        uint256 invExtreme = 10 ** (ORACLE_DECIMALS * 2) / extremePrice;
        uint256 invExtremeNear = 10 ** (ORACLE_DECIMALS * 2) / extremePriceNear;

        console2.log("=== Extreme price (10^35) ===");
        console2.log("invExtreme:", invExtreme);
        console2.log("invExtremeNear:", invExtremeNear);
        console2.log("Expected ratio ~1.3:1, actual:", invExtreme * 100 / invExtremeNear);
    }
}
