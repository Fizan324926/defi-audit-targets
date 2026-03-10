// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8;

/// @title IFallbackPriceOracleGetter
/// @dev Interface for a fallback price oracle getter. This interface allows retrieval of base currency information and asset prices.
interface IFallbackPriceOracleGetter {
    /// @notice Returns the base currency address
    /// @return The address of the base currency.
    function BASE_CURRENCY() external view returns (address);

    /// @notice Returns the base currency unit
    /// @return The base currency unit value.
    function BASE_CURRENCY_UNIT() external view returns (uint256);

    /// @notice Returns the price of an asset in the base currency
    /// @dev This function provides the price of the specified asset in the base currency.
    /// @param asset The address of the asset to get the price for.
    /// @return The price of the asset in the base currency unit.
    function getAssetPrice(address asset) external view returns (uint256);
}

/// @title IEthUsdPriceProvider
/// @dev Interface for getting ETH/USD price from fallback oracle (Pyth)
/// @dev Separated from IFallbackPriceOracleGetter because only the fallback oracle implements this
interface IEthUsdPriceProvider {
    /// @notice Returns the ETH/USD price from Pyth (for fallback conversion)
    /// @dev Used by PriceOracle when Chainlink ETH/USD is stale
    /// @return The ETH/USD price scaled to 18 decimals
    function getEthUsdPrice() external view returns (uint256);
}
