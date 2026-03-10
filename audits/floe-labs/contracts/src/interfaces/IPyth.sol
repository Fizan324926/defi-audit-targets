// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8;

/// @title IPyth
/// @notice Interface for Pyth Network price feeds
/// @dev Based on Pyth Network's standard interface
interface IPyth {
    /// @notice Returns the price of a price feed with a time.
    /// @param id The Pyth Price Feed ID of which to fetch the price and confidence interval.
    /// @return price - please read the documentation of PythStructs.Price to understand how to use this safely.
    function getPrice(bytes32 id) external view returns (PythStructs.Price memory price);

    /// @notice Returns the price of a price feed with a time, and the price is considered valid only if it has been updated within `age` seconds of the current time.
    /// @param id The Pyth Price Feed ID of which to fetch the price and confidence interval.
    /// @param age The maximum age of the price in seconds.
    /// @return price - please read the documentation of PythStructs.Price to understand how to use this safely.
    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (PythStructs.Price memory price);

    /// @notice Returns the latest price information for a given price feed ID.
    /// @param id The Pyth Price Feed ID of which to fetch the price and confidence interval.
    /// @return price - please read the documentation of PythStructs.Price to understand how to use this safely.
    function getLatestPrice(bytes32 id) external view returns (PythStructs.Price memory price);
}

/// @title PythStructs
/// @notice Structs for Pyth Network price data
library PythStructs {
    /// @notice A price with a degree of uncertainty, represented as a price +- a confidence interval.
    /// @dev The confidence interval roughly corresponds to the standard error of a normal distribution.
    /// Both the price and confidence are stored in a fixed-point numeric representation,
    /// `x * (10^expo)`, where `expo` is the exponent.
    /// @param price The price
    /// @param conf The confidence interval around the price
    /// @param expo The exponent used to convert price and confidence to fixed-point representation
    /// @param publishTime The publish time of the price
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }
}

