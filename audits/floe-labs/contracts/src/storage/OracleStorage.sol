// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

/// @title OracleStorage
/// @notice ERC-7201 namespaced storage for the PriceOracle contract
/// @dev Implements ERC-7201 storage layout for safe upgrades
///      Namespace ID: floe.storage.OracleStorage
library OracleStorageLib {
    /// @dev Storage slot for OracleStorage namespace
    /// @dev Computed via: keccak256(abi.encode(uint256(keccak256("floe.storage.OracleStorage")) - 1)) & ~bytes32(uint256(0xff))
    /// @dev Verified by: script/ComputeSlots.s.sol
    bytes32 internal constant ORACLE_STORAGE_SLOT =
        0x346ee9d38ecd1a4fbc337f3e7556ebcb0bab72163d4c927070ae025741ee9700;

    /// @custom:storage-location erc7201:floe.storage.OracleStorage
    struct OracleStorage {
        // ============ Price Sources ============
        /// @notice Maps asset addresses to their Chainlink aggregator addresses
        mapping(address asset => address chainlinkAggregator) assetPriceSources;

        // ============ Fallback Oracle ============
        /// @notice Address of the fallback oracle (Pyth)
        address fallbackOracle;

        // ============ Configuration ============
        /// @notice Staleness timeout for Chainlink price feeds (in seconds)
        uint256 stalenessTimeout;

        // ============ ETH/USD Conversion ============
        /// @notice ETH/USD Chainlink price feed for USD→WETH conversion
        address ethUsdPriceFeed;

        // ============ Price Deviation Protection ============
        /// @notice Maximum allowed price deviation in basis points (e.g., 1500 = 15%)
        uint256 maxDeviationBps;
        /// @notice Maps asset addresses to their last validated price
        mapping(address asset => uint256 lastValidPrice) lastValidPrices;

        // ============ L2 Sequencer Uptime Check ============
        /// @notice L2 Sequencer Uptime Feed address (Chainlink)
        /// @dev Only applicable for L2 chains (Arbitrum, Optimism, Base, etc.)
        /// @dev Set to address(0) to disable sequencer check (for L1 or unsupported L2s)
        address sequencerUptimeFeed;
        /// @notice Grace period after sequencer comes back up (in seconds)
        /// @dev Prices are rejected during this period to allow feeds to update
        uint256 sequencerGracePeriod;

        // ============ Circuit Breaker ============
        /// @notice Whether circuit breaker is currently active
        bool circuitBreakerActive;
        /// @notice Reason code for circuit breaker activation (0-6)
        uint8 circuitBreakerReason;
        /// @notice Timestamp when circuit breaker was activated
        uint64 circuitBreakerActivatedAt;

        // ============ Reserved for Future Upgrades ============
        /// @dev Storage gap for future upgrades (45 slots reserved)
        /// @dev Reduced from 46: circuit breaker fields (bool + uint8 + uint64) pack into 1 slot
        uint256[45] __gap;
    }

    /// @notice Returns the storage pointer to the OracleStorage struct
    /// @return $ Storage pointer to OracleStorage
    function _getOracleStorage() internal pure returns (OracleStorage storage $) {
        assembly {
            $.slot := ORACLE_STORAGE_SLOT
        }
    }
}
