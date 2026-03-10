// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8;

/// @title IChainlinkAggregatorV2V3
/// @dev Interface for interacting with a Chainlink Aggregator contract,
/// providing methods for retrieving the latest price data and related information.
interface IChainlinkAggregatorV2V3 {
    /// @notice Fetches the number of decimals used in the price or answer returned by the aggregator.
    /// @dev This function allows users to understand the precision of the price feed.
    /// @return The number of decimals (uint8) used in the answer provided by the aggregator.
    function decimals() external view returns (uint8);

    /// @notice Fetches a brief description of the Chainlink price feed.
    /// @dev This function can return information about the feed's source, asset, or any additional relevant details.
    /// @return A string containing the description of the aggregator.
    function description() external view returns (string memory);

    /// @notice Fetches the latest price or answer from the Chainlink Aggregator.
    /// @dev This function returns the most recent value provided by the aggregator, which may represent
    /// prices or other data depending on the implementation.
    /// @return The latest price or value as an int256, usually expressed in the aggregator's defined format.
    function latestAnswer() external view returns (int256);

    /// @notice Fetches the timestamp of when the latest answer was reported.
    /// @dev This function provides the timestamp in seconds since the Unix epoch.
    /// @return The timestamp (uint256) when the latest answer was last updated.
    function latestTimestamp() external view returns (uint256);

    /// @notice Fetches the latest round's detailed data from the Chainlink Aggregator.
    /// @dev This function returns comprehensive round data including roundId, answer, timestamps, and answeredInRound.
    /// This is the recommended method for fetching prices as it allows validation of staleness and frozen rounds.
    /// @return roundId The latest round ID.
    /// @return answer The latest price or value as an int256.
    /// @return startedAt Timestamp when the latest round started.
    /// @return updatedAt Timestamp when the latest round was updated.
    /// @return answeredInRound The round ID in which the latest answer was computed.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
