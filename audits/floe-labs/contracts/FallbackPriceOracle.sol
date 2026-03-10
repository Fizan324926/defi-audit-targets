// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Roles} from "../governance/Roles.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IFallbackPriceOracleGetter, IEthUsdPriceProvider} from "../interfaces/IFallbackPriceOracleGetter.sol";
import {IPyth, PythStructs} from "../interfaces/IPyth.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {EventsLib} from "../libraries/EventsLib.sol";

/// @title FallbackPriceOracleUpgradeable
/// @notice UUPS upgradeable fallback price oracle using Pyth Network price feeds
/// @dev Implements ERC-7201 namespaced storage
/// @dev Converts USD-denominated Pyth prices to WETH base currency for consistency
contract FallbackPriceOracleUpgradeable is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    IFallbackPriceOracleGetter,
    IEthUsdPriceProvider
{
    // ============ ERC-7201 Storage ============
    /// @custom:storage-location erc7201:floe.storage.FallbackPriceOracle
    struct FallbackOracleStorage {
        /// @notice Maximum age for price updates (staleness timeout in seconds)
        uint256 maxPriceAge;
        /// @notice Maximum confidence interval as a percentage (basis points)
        uint256 maxConfidenceBps;
        /// @notice Mapping from asset address to Pyth price feed ID
        mapping(address asset => bytes32 priceFeedId) assetPriceFeedIds;
        /// @notice ETH/USD price feed ID for converting USD prices to WETH
        bytes32 ethUsdPriceFeedId;
        /// @dev Reserved for future upgrades (50 slots standard)
        uint256[50] __gap;
    }

    /// @dev Computed via: keccak256(abi.encode(uint256(keccak256("floe.storage.FallbackPriceOracle")) - 1)) & ~bytes32(uint256(0xff))
    /// @dev Verified by: script/ComputeSlots.s.sol
    bytes32 private constant FALLBACK_ORACLE_STORAGE_SLOT =
        0x74a3e6e822cd5fc69b8c3f336b517ba762d9d787cd09b7f580265d1020437a00;

    function _getFallbackOracleStorage() private pure returns (FallbackOracleStorage storage $) {
        assembly {
            $.slot := FALLBACK_ORACLE_STORAGE_SLOT
        }
    }

    // ============ Immutables ============
    /// @notice Base currency (WETH)
    address public immutable BASE_CURRENCY;
    /// @notice Base currency unit (1e18 for WETH)
    uint256 public constant BASE_CURRENCY_UNIT = 1 ether;
    /// @notice Pyth Network contract address
    IPyth public immutable pyth;

    // ============ Constructor ============
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address baseCurrency_, address pyth_) {
        if (baseCurrency_ == address(0)) revert ErrorsLib.ZeroAddress();
        if (pyth_ == address(0)) revert ErrorsLib.ZeroAddress();

        BASE_CURRENCY = baseCurrency_;
        pyth = IPyth(pyth_);

        _disableInitializers();
    }

    // ============ Initializer ============
    /// @notice Initializes the upgradeable fallback oracle
    /// @param admin_ The default admin address (can grant/revoke roles)
    /// @param oracleAdmin_ The oracle admin address (manages oracle config)
    /// @param upgrader_ The upgrader address (should be TimelockController)
    /// @param maxPriceAge_ Maximum age for price updates in seconds
    /// @param maxConfidenceBps_ Maximum confidence interval in basis points
    /// @param ethUsdPriceFeedId_ The Pyth ETH/USD price feed ID for USD→WETH conversion
    function initialize(
        address admin_,
        address oracleAdmin_,
        address upgrader_,
        uint256 maxPriceAge_,
        uint256 maxConfidenceBps_,
        bytes32 ethUsdPriceFeedId_
    ) external initializer {
        if (maxPriceAge_ == 0) revert ErrorsLib.ZeroAmount();

        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        // Grant roles
        _grantRole(Roles.DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(Roles.ORACLE_ADMIN_ROLE, oracleAdmin_);
        _grantRole(Roles.UPGRADER_ROLE, upgrader_);

        FallbackOracleStorage storage $ = _getFallbackOracleStorage();
        $.maxPriceAge = maxPriceAge_;
        $.maxConfidenceBps = maxConfidenceBps_;
        $.ethUsdPriceFeedId = ethUsdPriceFeedId_;

        emit EventsLib.LogMaxPriceAgeUpdated(0, maxPriceAge_);
        emit EventsLib.LogMaxConfidenceUpdated(0, maxConfidenceBps_);
        emit EventsLib.LogEthUsdPriceFeedIdSet(ethUsdPriceFeedId_);
    }

    // ============ Upgrade Authorization ============
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(Roles.UPGRADER_ROLE) {}

    // ============ Price Functions ============
    /// @notice Gets the asset price from Pyth Network
    /// @param asset The asset address
    /// @return price The price of the asset in base currency units (wei)
    function getAssetPrice(address asset) external view override returns (uint256 price) {
        FallbackOracleStorage storage $ = _getFallbackOracleStorage();

        // Base currency always returns base unit
        if (asset == BASE_CURRENCY) {
            return BASE_CURRENCY_UNIT;
        }

        // Get price feed ID for asset
        bytes32 priceFeedId = $.assetPriceFeedIds[asset];
        if (priceFeedId == bytes32(0)) {
            revert ErrorsLib.InvalidPrice(); // No price feed configured
        }

        // Get price from Pyth with staleness check
        PythStructs.Price memory pythPrice = pyth.getPriceNoOlderThan(priceFeedId, $.maxPriceAge);

        // Validate price
        if (pythPrice.price <= 0) {
            revert ErrorsLib.InvalidPrice();
        }

        // Validate confidence interval
        uint256 priceAbs =
            uint256(uint64(int64(pythPrice.price) < 0 ? -int64(pythPrice.price) : int64(pythPrice.price)));
        uint256 conf = uint256(pythPrice.conf);

        // Calculate confidence as basis points: (conf * 10000) / price
        if (priceAbs > 0 && $.maxConfidenceBps > 0) {
            uint256 confidenceBps = (conf * 10000) / priceAbs;
            if (confidenceBps > $.maxConfidenceBps) {
                revert ErrorsLib.InvalidPrice(); // Confidence too high
            }
        }

        // Convert Pyth price to wei scale
        int32 expo = pythPrice.expo;
        int256 priceValue = int256(pythPrice.price);
        int256 scalingExponent = int256(18) + int256(expo);

        if (scalingExponent < 0) {
            revert ErrorsLib.InvalidPrice();
        }

        require(scalingExponent >= 0 && scalingExponent <= 77, "Scaling exponent out of bounds");
        uint256 scalingFactor = 10 ** uint256(scalingExponent);
        require(scalingFactor <= uint256(type(int256).max), "Scaling factor overflow");
        int256 priceScaled = priceValue * int256(scalingFactor);

        if (priceScaled <= 0) {
            revert ErrorsLib.InvalidPrice();
        }

        // Convert USD prices to base currency (WETH) using ETH/USD feed
        if ($.ethUsdPriceFeedId != bytes32(0)) {
            price = _convertUsdToWeth(uint256(priceScaled), $);
        } else {
            // If ETH/USD feed is not configured, return price as-is
            // This should NOT be used in production
            require(priceScaled > 0, "Price must be positive");
            price = uint256(priceScaled);
        }
    }

    /// @notice Gets the ETH/USD price from Pyth, scaled to 18 decimals
    /// @dev Internal helper used by both _convertUsdToWeth() and getEthUsdPrice()
    /// @param $ Storage pointer
    /// @return ethPriceScaled The ETH/USD price scaled to 18 decimals
    function _getEthUsdPriceScaled(FallbackOracleStorage storage $) internal view returns (uint256 ethPriceScaled) {
        if ($.ethUsdPriceFeedId == bytes32(0)) {
            revert ErrorsLib.InvalidPrice();
        }

        // Get ETH/USD price from Pyth
        PythStructs.Price memory ethUsdPrice = pyth.getPriceNoOlderThan($.ethUsdPriceFeedId, $.maxPriceAge);

        // Validate ETH/USD price
        if (ethUsdPrice.price <= 0) {
            revert ErrorsLib.InvalidPrice();
        }

        // Convert ETH/USD price to 18 decimals
        int32 ethExpo = ethUsdPrice.expo;
        int256 ethPriceValue = int256(ethUsdPrice.price);
        int256 ethScalingExponent = int256(18) + int256(ethExpo);

        if (ethScalingExponent < 0 || ethScalingExponent > 77) {
            revert ErrorsLib.InvalidPrice();
        }

        uint256 ethScalingFactor = 10 ** uint256(ethScalingExponent);
        require(ethScalingFactor <= uint256(type(int256).max), "ETH scaling factor overflow");
        int256 priceScaled = ethPriceValue * int256(ethScalingFactor);

        if (priceScaled <= 0) {
            revert ErrorsLib.InvalidPrice();
        }

        ethPriceScaled = uint256(priceScaled);
    }

    /// @notice Converts a USD-denominated price to WETH (base currency)
    /// @dev Uses the Pyth ETH/USD feed for conversion
    /// @param priceInUsd The price in USD (already scaled to 18 decimals)
    /// @param $ Storage pointer
    /// @return priceInWeth The price in WETH (wei units)
    function _convertUsdToWeth(uint256 priceInUsd, FallbackOracleStorage storage $)
        internal
        view
        returns (uint256 priceInWeth)
    {
        uint256 ethPriceScaled = _getEthUsdPriceScaled($);

        // Convert: priceInWETH = (priceInUSD * BASE_CURRENCY_UNIT) / ethPriceInUSD
        int256 priceWeth = (int256(priceInUsd) * int256(BASE_CURRENCY_UNIT)) / int256(ethPriceScaled);

        if (priceWeth <= 0) {
            revert ErrorsLib.InvalidPrice();
        }

        priceInWeth = uint256(priceWeth);
    }

    // ============ Admin Functions ============
    /// @notice Sets the Pyth price feed ID for an asset
    /// @param asset The asset address
    /// @param priceFeedId The Pyth price feed ID (bytes32)
    function setAssetPriceFeedId(address asset, bytes32 priceFeedId) external onlyRole(Roles.ORACLE_ADMIN_ROLE) {
        if (asset == address(0)) revert ErrorsLib.ZeroAddress();
        FallbackOracleStorage storage $ = _getFallbackOracleStorage();
        $.assetPriceFeedIds[asset] = priceFeedId;
        emit EventsLib.LogPriceFeedIdSet(asset, priceFeedId);
    }

    /// @notice Sets multiple asset price feed IDs
    /// @param assets Array of asset addresses
    /// @param priceFeedIds Array of Pyth price feed IDs
    function setAssetPriceFeedIds(address[] calldata assets, bytes32[] calldata priceFeedIds) external onlyRole(Roles.ORACLE_ADMIN_ROLE) {
        if (assets.length != priceFeedIds.length) revert ErrorsLib.ArrayLengthMismatch();
        FallbackOracleStorage storage $ = _getFallbackOracleStorage();
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i] == address(0)) revert ErrorsLib.ZeroAddress();
            $.assetPriceFeedIds[assets[i]] = priceFeedIds[i];
            emit EventsLib.LogPriceFeedIdSet(assets[i], priceFeedIds[i]);
        }
    }

    /// @notice Sets the maximum price age (staleness timeout)
    /// @param newMaxPriceAge New maximum price age in seconds
    function setMaxPriceAge(uint256 newMaxPriceAge) external onlyRole(Roles.ORACLE_ADMIN_ROLE) {
        if (newMaxPriceAge == 0) revert ErrorsLib.ZeroAmount();
        FallbackOracleStorage storage $ = _getFallbackOracleStorage();
        uint256 oldMaxPriceAge = $.maxPriceAge;
        $.maxPriceAge = newMaxPriceAge;
        emit EventsLib.LogMaxPriceAgeUpdated(oldMaxPriceAge, newMaxPriceAge);
    }

    /// @notice Sets the maximum confidence interval
    /// @param newMaxConfidenceBps New maximum confidence in basis points
    function setMaxConfidence(uint256 newMaxConfidenceBps) external onlyRole(Roles.ORACLE_ADMIN_ROLE) {
        FallbackOracleStorage storage $ = _getFallbackOracleStorage();
        uint256 oldMaxConfidence = $.maxConfidenceBps;
        $.maxConfidenceBps = newMaxConfidenceBps;
        emit EventsLib.LogMaxConfidenceUpdated(oldMaxConfidence, newMaxConfidenceBps);
    }

    /// @notice Sets the ETH/USD price feed ID for converting USD prices to WETH
    /// @param priceFeedId The Pyth ETH/USD price feed ID (bytes32)
    function setEthUsdPriceFeedId(bytes32 priceFeedId) external onlyRole(Roles.ORACLE_ADMIN_ROLE) {
        FallbackOracleStorage storage $ = _getFallbackOracleStorage();
        $.ethUsdPriceFeedId = priceFeedId;
        emit EventsLib.LogEthUsdPriceFeedIdSet(priceFeedId);
    }

    // ============ View Functions ============
    /// @notice Gets the price feed ID for an asset
    function getAssetPriceFeedId(address asset) external view returns (bytes32) {
        FallbackOracleStorage storage $ = _getFallbackOracleStorage();
        return $.assetPriceFeedIds[asset];
    }

    /// @notice Gets the ETH/USD price feed ID
    function getEthUsdPriceFeedId() external view returns (bytes32) {
        FallbackOracleStorage storage $ = _getFallbackOracleStorage();
        return $.ethUsdPriceFeedId;
    }

    /// @notice Gets the max price age
    function getMaxPriceAge() external view returns (uint256) {
        FallbackOracleStorage storage $ = _getFallbackOracleStorage();
        return $.maxPriceAge;
    }

    /// @notice Gets the max confidence in basis points
    function getMaxConfidenceBps() external view returns (uint256) {
        FallbackOracleStorage storage $ = _getFallbackOracleStorage();
        return $.maxConfidenceBps;
    }

    /// @notice Returns the ETH/USD price from Pyth for fallback conversion
    /// @dev Used by PriceOracle when Chainlink ETH/USD is stale
    /// @return ethUsdPrice The ETH/USD price scaled to 18 decimals
    function getEthUsdPrice() external view returns (uint256 ethUsdPrice) {
        FallbackOracleStorage storage $ = _getFallbackOracleStorage();
        ethUsdPrice = _getEthUsdPriceScaled($);
    }
}
