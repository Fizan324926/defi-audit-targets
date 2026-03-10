// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Roles} from "../governance/Roles.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {OracleStorageLib} from "../storage/OracleStorage.sol";
import {IChainlinkAggregatorV2V3} from "../interfaces/IChainlinkAggregatorV2V3.sol";
import {IFallbackPriceOracleGetter, IEthUsdPriceProvider} from "../interfaces/IFallbackPriceOracleGetter.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {IERC20Decimals} from "../interfaces/IERC20Decimals.sol";

import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {EventsLib} from "../libraries/EventsLib.sol";
import {CHAINLINK_STALENESS_TIMEOUT, DEFAULT_MAX_PRICE_DEVIATION_BPS, DEFAULT_SEQUENCER_GRACE_PERIOD, BASIS_POINTS} from "../libraries/ConstantsLib.sol";

/// @title PriceOracleUpgradeable
/// @notice UUPS upgradeable price oracle with Chainlink primary and fallback support
/// @dev Implements ERC-7201 namespaced storage
/// @dev FIXED: Converts Chainlink USD prices to WETH base currency for consistency with fallback oracle
contract PriceOracleUpgradeable is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    IPriceOracle,
    IFallbackPriceOracleGetter
{
    using OracleStorageLib for OracleStorageLib.OracleStorage;

    uint256 private constant SCALING_FACTOR = 1e36;

    // ============ Modifiers ============

    /// @notice Reverts if circuit breaker is active
    modifier onlyWhenCircuitBreakerNotActive() {
        OracleStorageLib.OracleStorage storage $ = OracleStorageLib._getOracleStorage();
        if ($.circuitBreakerActive) {
            revert ErrorsLib.CircuitBreakerActive($.circuitBreakerReason);
        }
        _;
    }

    // ============ Immutables ============
    /// @notice Base currency (e.g., WETH)
    address public immutable BASE_CURRENCY;
    /// @notice Base currency unit (e.g., 1e18 for WETH)
    uint256 public immutable BASE_CURRENCY_UNIT;

    // ============ Constructor ============
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address baseCurrency_, uint256 baseCurrencyUnit_) {
        if (baseCurrency_ == address(0)) revert ErrorsLib.ZeroAddress();
        BASE_CURRENCY = baseCurrency_;
        BASE_CURRENCY_UNIT = baseCurrencyUnit_;
        _disableInitializers();
    }

    // ============ Initializer ============
    /// @notice Initializes the upgradeable price oracle
    /// @param admin_ The default admin address (can grant/revoke roles)
    /// @param oracleAdmin_ The oracle admin address (manages oracle config)
    /// @param guardian_ The guardian address (can activate/reset circuit breaker)
    /// @param upgrader_ The upgrader address (should be TimelockController)
    /// @param fallbackOracle_ The fallback oracle address (Pyth)
    /// @param ethUsdPriceFeed_ The ETH/USD Chainlink price feed for USD→WETH conversion
    /// @param assets_ Initial asset addresses
    /// @param sources_ Initial Chainlink source addresses
    /// @param sequencerUptimeFeed_ L2 sequencer uptime feed (Base: 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433)
    function initialize(
        address admin_,
        address oracleAdmin_,
        address guardian_,
        address upgrader_,
        address fallbackOracle_,
        address ethUsdPriceFeed_,
        address[] calldata assets_,
        address[] calldata sources_,
        address sequencerUptimeFeed_
    ) external initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        // Grant roles
        _grantRole(Roles.DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(Roles.ORACLE_ADMIN_ROLE, oracleAdmin_);
        _grantRole(Roles.GUARDIAN_ROLE, guardian_);
        _grantRole(Roles.UPGRADER_ROLE, upgrader_);

        OracleStorageLib.OracleStorage storage $ = OracleStorageLib._getOracleStorage();

        if (fallbackOracle_ != address(0)) {
            $.fallbackOracle = fallbackOracle_;
            emit EventsLib.LogFallbackOracleUpdated(fallbackOracle_);
        }

        if (ethUsdPriceFeed_ != address(0)) {
            $.ethUsdPriceFeed = ethUsdPriceFeed_;
            emit EventsLib.LogEthUsdPriceFeedUpdated(ethUsdPriceFeed_);
        }

        if (sequencerUptimeFeed_ != address(0)) {
            $.sequencerUptimeFeed = sequencerUptimeFeed_;
            $.sequencerGracePeriod = DEFAULT_SEQUENCER_GRACE_PERIOD;
            emit EventsLib.LogSequencerUptimeFeedUpdated(address(0), sequencerUptimeFeed_);
            emit EventsLib.LogSequencerGracePeriodUpdated(0, DEFAULT_SEQUENCER_GRACE_PERIOD);
        }

        $.stalenessTimeout = CHAINLINK_STALENESS_TIMEOUT;
        $.maxDeviationBps = DEFAULT_MAX_PRICE_DEVIATION_BPS;

        if (assets_.length > 0) {
            _setAssetPriceSources(assets_, sources_);
        }

        emit EventsLib.LogBaseCurrencySet(BASE_CURRENCY, BASE_CURRENCY_UNIT);
    }

    // ============ Upgrade Authorization ============
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(Roles.UPGRADER_ROLE) {}

    // ============ Price Functions ============

    /// @inheritdoc IPriceOracle
    /// @notice Returns the price of 1 collateral token in terms of loan tokens, scaled by 1e36
    function getPrice(address collateralToken, address loanToken) external view returns (uint256) {
        uint256 collateralPrice = getAssetPrice(collateralToken);
        uint256 loanPrice = getAssetPrice(loanToken);
        uint8 collateralDecimals = getTokenDecimals(collateralToken);
        uint8 loanDecimals = getTokenDecimals(loanToken);

        uint8 precision = (36 + loanDecimals) - collateralDecimals;
        uint256 scalingFactor = 10 ** uint256(precision);
        uint256 tokenPairPrice = (collateralPrice * scalingFactor) / loanPrice;

        return tokenPairPrice;
    }

    /// @notice Gets the price of an asset in base currency (WETH) units
    /// @dev FIXED: Converts Chainlink USD prices to WETH for consistency
    /// @dev Includes L2 sequencer uptime check when configured
    /// @param asset The asset address
    /// @return assetPrice The price in base currency units (wei)
    function getAssetPrice(address asset) public view override onlyWhenCircuitBreakerNotActive returns (uint256 assetPrice) {
        // Check L2 sequencer status (skipped if not configured)
        _checkSequencerStatus();

        OracleStorageLib.OracleStorage storage $ = OracleStorageLib._getOracleStorage();

        // Base currency returns unit
        if (asset == BASE_CURRENCY) {
            return BASE_CURRENCY_UNIT;
        }

        address sourceAddr = $.assetPriceSources[asset];
        IChainlinkAggregatorV2V3 source = IChainlinkAggregatorV2V3(sourceAddr);

        if (sourceAddr == address(0)) {
            return _useFallbackOracle(asset);
        }

        // Fetch and validate Chainlink data
        (uint80 roundId, int256 chainlinkPrice, , uint256 updatedAt, uint80 answeredInRound) =
            source.latestRoundData();

        // Validate Chainlink price feed data
        if (chainlinkPrice <= 0) {
            return _useFallbackOracle(asset);
        }
        if (updatedAt == 0) {
            return _useFallbackOracle(asset);
        }
        if (block.timestamp < updatedAt) {
            return _useFallbackOracle(asset);
        }
        if (block.timestamp - updatedAt > $.stalenessTimeout) {
            return _useFallbackOracle(asset);
        }
        if (answeredInRound < roundId) {
            return _useFallbackOracle(asset);
        }

        uint256 priceUsd = uint256(chainlinkPrice);
        uint8 priceDecimals = source.decimals();

        // ============ FIX: Convert USD price to WETH ============
        // If ETH/USD feed is configured, convert the USD price to WETH
        if ($.ethUsdPriceFeed != address(0)) {
            assetPrice = _convertUsdToWeth(priceUsd, priceDecimals);
        } else {
            // If no ETH/USD feed, normalize to 18 decimals (legacy behavior)
            // This should NOT be used in production - ethUsdPriceFeed should always be set
            assetPrice = _normalizeToWei(priceUsd, priceDecimals);
        }
    }

    /// @notice Gets the price of an asset with deviation check and storage update
    /// @dev Non-view function that validates price against last stored price and updates storage
    /// @param asset The asset address
    /// @return assetPrice The validated price in base currency units (wei)
    function getAssetPriceChecked(address asset) public returns (uint256 assetPrice) {
        assetPrice = getAssetPrice(asset);
        _checkAndUpdatePrice(asset, assetPrice);
    }

    /// @notice Returns the price of 1 collateral token in terms of loan tokens with deviation check
    /// @dev Non-view function that validates prices against last stored prices
    /// @param collateralToken The collateral token address
    /// @param loanToken The loan token address
    /// @return tokenPairPrice The price scaled by 1e36
    function getPriceChecked(address collateralToken, address loanToken) external returns (uint256 tokenPairPrice) {
        uint256 collateralPrice = getAssetPriceChecked(collateralToken);
        uint256 loanPrice = getAssetPriceChecked(loanToken);
        uint8 collateralDecimals = getTokenDecimals(collateralToken);
        uint8 loanDecimals = getTokenDecimals(loanToken);

        uint8 precision = (36 + loanDecimals) - collateralDecimals;
        uint256 scalingFactor = 10 ** uint256(precision);
        tokenPairPrice = (collateralPrice * scalingFactor) / loanPrice;
    }

    /// @notice Checks price deviation and updates last valid price
    /// @dev Reverts if deviation exceeds maxDeviationBps (unless first price or deviation check disabled)
    /// @dev NOTE: Circuit breaker is NOT auto-activated here. The revert protects the current operation,
    ///      but CB activation requires external keeper/guardian action. This is intentional because:
    ///      1. EVM reverts roll back all state changes (including CB activation)
    ///      2. Returning stale prices is dangerous if the deviation is a real market move
    ///      3. Off-chain monitoring should detect PriceDeviationTooHigh reverts and call activateCircuitBreaker()
    /// @param asset The asset address
    /// @param newPrice The new price to validate
    function _checkAndUpdatePrice(address asset, uint256 newPrice) internal {
        OracleStorageLib.OracleStorage storage $ = OracleStorageLib._getOracleStorage();

        uint256 lastPrice = $.lastValidPrices[asset];
        uint256 maxDeviation = $.maxDeviationBps;

        // Skip check if:
        // 1. No previous price stored (first price fetch)
        // 2. Deviation check is disabled (maxDeviationBps == 0)
        if (lastPrice != 0 && maxDeviation != 0) {
            uint256 deviationBps;
            if (newPrice > lastPrice) {
                deviationBps = ((newPrice - lastPrice) * BASIS_POINTS) / lastPrice;
            } else {
                deviationBps = ((lastPrice - newPrice) * BASIS_POINTS) / lastPrice;
            }

            if (deviationBps > maxDeviation) {
                // Revert to protect this operation - no stale price returned
                // Off-chain keeper should monitor for this error and call guardian.activateCircuitBreaker()
                revert ErrorsLib.PriceDeviationTooHigh(asset, newPrice, lastPrice, deviationBps);
            }
        }

        // Update last valid price
        if (newPrice != lastPrice) {
            $.lastValidPrices[asset] = newPrice;
            emit EventsLib.LogPriceUpdated(asset, lastPrice, newPrice);
        }
    }

    /// @notice Converts a USD-denominated price to WETH (base currency)
    /// @dev Uses the ETH/USD Chainlink feed for conversion, falls back to Pyth if Chainlink fails
    /// @dev FIX (Bug #64352): Added missing Chainlink validation checks for consistency with getAssetPrice()
    /// @dev FIX (Bug #64658): Added Pyth fallback when Chainlink ETH/USD is stale/invalid
    /// @param priceUsd The price in USD (with Chainlink decimals)
    /// @param decimals The number of decimals in the USD price
    /// @return priceWeth The price in WETH (wei units)
    function _convertUsdToWeth(uint256 priceUsd, uint8 decimals) internal view returns (uint256 priceWeth) {
        OracleStorageLib.OracleStorage storage $ = OracleStorageLib._getOracleStorage();

        IChainlinkAggregatorV2V3 ethUsdFeed = IChainlinkAggregatorV2V3($.ethUsdPriceFeed);

        // FIX: Fetch ALL round data including roundId and answeredInRound for frozen feed detection
        (uint80 roundId, int256 ethUsdPrice, , uint256 ethUpdatedAt, uint80 answeredInRound) =
            ethUsdFeed.latestRoundData();

        // Try to use Chainlink ETH/USD, fall back to Pyth if validation fails
        bool useChainlink = true;

        // Check 1: Positive price
        if (ethUsdPrice <= 0) useChainlink = false;
        // Check 2: Feed initialized
        if (ethUpdatedAt == 0) useChainlink = false;
        // Check 3: Not future timestamp
        if (block.timestamp < ethUpdatedAt) useChainlink = false;
        // Check 4: Not stale - THE FIX: fall back instead of revert
        // Note: Only check if previous checks passed to avoid underflow when ethUpdatedAt > block.timestamp
        if (useChainlink && block.timestamp - ethUpdatedAt > $.stalenessTimeout) useChainlink = false;
        // Check 5: Not frozen (round completeness)
        if (answeredInRound < roundId) useChainlink = false;

        uint256 ethPriceNormalized;

        if (useChainlink) {
            // Use Chainlink ETH/USD price
            uint8 ethUsdDecimals = ethUsdFeed.decimals();
            if (ethUsdDecimals < 18) {
                ethPriceNormalized = uint256(ethUsdPrice) * (10 ** (18 - ethUsdDecimals));
            } else if (ethUsdDecimals > 18) {
                ethPriceNormalized = uint256(ethUsdPrice) / (10 ** (ethUsdDecimals - 18));
            } else {
                ethPriceNormalized = uint256(ethUsdPrice);
            }
        } else {
            // Fall back to Pyth ETH/USD price
            if ($.fallbackOracle == address(0)) {
                revert ErrorsLib.InvalidPrice();
            }
            ethPriceNormalized = IEthUsdPriceProvider($.fallbackOracle).getEthUsdPrice();
            if (ethPriceNormalized == 0) {
                revert ErrorsLib.InvalidPrice();
            }
        }

        // Normalize both prices to 18 decimals for calculation
        // Formula: assetPriceInWeth = (assetPriceUsd * 1e18) / ethPriceUsd
        // Both prices need to be in the same decimal scale first

        // Convert asset price to wei scale: priceUsd * 10^(18 - decimals)
        uint256 assetPriceNormalized;
        if (decimals < 18) {
            assetPriceNormalized = priceUsd * (10 ** (18 - decimals));
        } else if (decimals > 18) {
            assetPriceNormalized = priceUsd / (10 ** (decimals - 18));
        } else {
            assetPriceNormalized = priceUsd;
        }

        // Calculate: priceInWeth = (priceInUsd * BASE_CURRENCY_UNIT) / ethPriceInUsd
        priceWeth = (assetPriceNormalized * BASE_CURRENCY_UNIT) / ethPriceNormalized;
    }

    /// @notice Normalizes a price to wei (18 decimals)
    /// @param price The price value
    /// @param decimals The current number of decimals
    /// @return The price normalized to 18 decimals
    function _normalizeToWei(uint256 price, uint8 decimals) internal pure returns (uint256) {
        if (decimals < 18) {
            return price * (10 ** (18 - decimals));
        } else if (decimals > 18) {
            return price / (10 ** (decimals - 18));
        }
        return price;
    }

    /// @notice Uses fallback oracle with validation
    /// @param asset The asset address
    /// @return price The price from fallback oracle
    function _useFallbackOracle(address asset) internal view returns (uint256 price) {
        OracleStorageLib.OracleStorage storage $ = OracleStorageLib._getOracleStorage();

        if ($.fallbackOracle == address(0)) {
            revert ErrorsLib.InvalidPrice();
        }

        price = IFallbackPriceOracleGetter($.fallbackOracle).getAssetPrice(asset);
        if (price == 0) revert ErrorsLib.InvalidPrice();
    }

    /// @notice Checks if the L2 sequencer is up and grace period has passed
    /// @dev Only applies when sequencerUptimeFeed is configured (L2 chains)
    /// @dev Reverts if sequencer is down or still within grace period after coming back up
    function _checkSequencerStatus() internal view {
        OracleStorageLib.OracleStorage storage $ = OracleStorageLib._getOracleStorage();

        // Skip check if no sequencer feed is configured (L1 or unsupported L2)
        if ($.sequencerUptimeFeed == address(0)) {
            return;
        }

        IChainlinkAggregatorV2V3 sequencerFeed = IChainlinkAggregatorV2V3($.sequencerUptimeFeed);

        // Get the latest sequencer status
        // answer: 0 = sequencer is up, 1 = sequencer is down
        // startedAt: timestamp when the sequencer status last changed
        (, int256 answer, uint256 startedAt, , ) = sequencerFeed.latestRoundData();

        // Check if sequencer is down
        // Chainlink sequencer uptime feed: 0 = up, 1 = down
        if (answer != 0) {
            revert ErrorsLib.SequencerDown();
        }

        // Check grace period after sequencer comes back up
        // startedAt is the timestamp when sequencer came back up
        uint256 gracePeriod = $.sequencerGracePeriod;
        if (gracePeriod > 0) {
            uint256 timeSinceUp = block.timestamp - startedAt;
            if (timeSinceUp < gracePeriod) {
                revert ErrorsLib.SequencerGracePeriodNotOver(gracePeriod - timeSinceUp);
            }
        }
    }

    // ============ Getter Functions ============

    /// @notice Returns the token decimals
    function getTokenDecimals(address tokenAddress) public view returns (uint8) {
        return IERC20Decimals(tokenAddress).decimals();
    }

    /// @notice Gets prices for multiple assets
    function getAssetsPrices(address[] calldata assets) external view returns (uint256[] memory) {
        uint256[] memory prices = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            prices[i] = getAssetPrice(assets[i]);
        }
        return prices;
    }

    /// @notice Gets the source address for an asset
    function getAssetPriceSource(address asset) external view returns (address) {
        OracleStorageLib.OracleStorage storage $ = OracleStorageLib._getOracleStorage();
        return $.assetPriceSources[asset];
    }

    /// @notice Gets the fallback oracle address
    function getFallbackOracle() external view returns (address) {
        OracleStorageLib.OracleStorage storage $ = OracleStorageLib._getOracleStorage();
        return $.fallbackOracle;
    }

    /// @notice Gets the ETH/USD price feed address
    function getEthUsdPriceFeed() external view returns (address) {
        OracleStorageLib.OracleStorage storage $ = OracleStorageLib._getOracleStorage();
        return $.ethUsdPriceFeed;
    }

    /// @notice Gets the staleness timeout
    function getStalenessTimeout() external view returns (uint256) {
        OracleStorageLib.OracleStorage storage $ = OracleStorageLib._getOracleStorage();
        return $.stalenessTimeout;
    }

    /// @notice Gets the maximum price deviation threshold in basis points
    function getMaxDeviationBps() external view returns (uint256) {
        OracleStorageLib.OracleStorage storage $ = OracleStorageLib._getOracleStorage();
        return $.maxDeviationBps;
    }

    /// @notice Gets the last validated price for an asset
    /// @param asset The asset address
    /// @return The last validated price in base currency units
    function getLastValidPrice(address asset) external view returns (uint256) {
        OracleStorageLib.OracleStorage storage $ = OracleStorageLib._getOracleStorage();
        return $.lastValidPrices[asset];
    }

    /// @notice Gets the L2 sequencer uptime feed address
    /// @return The sequencer uptime feed address (address(0) if not configured)
    function getSequencerUptimeFeed() external view returns (address) {
        OracleStorageLib.OracleStorage storage $ = OracleStorageLib._getOracleStorage();
        return $.sequencerUptimeFeed;
    }

    /// @notice Gets the L2 sequencer grace period
    /// @return The grace period in seconds after sequencer comes back up
    function getSequencerGracePeriod() external view returns (uint256) {
        OracleStorageLib.OracleStorage storage $ = OracleStorageLib._getOracleStorage();
        return $.sequencerGracePeriod;
    }

    // ============ Circuit Breaker Getters ============

    /// @inheritdoc IPriceOracle
    function isCircuitBreakerActive() external view returns (bool) {
        return OracleStorageLib._getOracleStorage().circuitBreakerActive;
    }

    /// @inheritdoc IPriceOracle
    function getCircuitBreakerReason() external view returns (uint8) {
        return OracleStorageLib._getOracleStorage().circuitBreakerReason;
    }

    /// @notice Returns full circuit breaker state
    /// @return active Whether circuit breaker is active
    /// @return reason The reason code (0-6)
    /// @return activatedAt Timestamp when activated
    function getCircuitBreakerState() external view returns (
        bool active,
        uint8 reason,
        uint64 activatedAt
    ) {
        OracleStorageLib.OracleStorage storage $ = OracleStorageLib._getOracleStorage();
        return ($.circuitBreakerActive, $.circuitBreakerReason, $.circuitBreakerActivatedAt);
    }

    // ============ Circuit Breaker Controls ============

    /// @notice Manually activates circuit breaker (guardian only)
    function activateCircuitBreaker() external onlyRole(Roles.GUARDIAN_ROLE) {
        _activateCircuitBreaker(6); // GUARDIAN_TRIGGERED
    }

    /// @notice Resets circuit breaker (guardian only)
    function resetCircuitBreaker() external onlyRole(Roles.GUARDIAN_ROLE) {
        OracleStorageLib.OracleStorage storage $ = OracleStorageLib._getOracleStorage();
        if (!$.circuitBreakerActive) revert ErrorsLib.CircuitBreakerNotActive();

        uint8 previousReason = $.circuitBreakerReason;
        $.circuitBreakerActive = false;
        $.circuitBreakerReason = 0;
        $.circuitBreakerActivatedAt = 0;

        emit EventsLib.CircuitBreakerReset(previousReason, msg.sender);
    }

    // ============ Setter Functions (Restricted) ============

    /// @notice Sets price sources for assets
    function setAssetPriceSources(address[] calldata assets, address[] calldata sources) external onlyRole(Roles.ORACLE_ADMIN_ROLE) {
        _setAssetPriceSources(assets, sources);
    }

    /// @notice Sets the fallback oracle
    function setFallbackOracle(address fallbackOracle_) external onlyRole(Roles.ORACLE_ADMIN_ROLE) {
        OracleStorageLib.OracleStorage storage $ = OracleStorageLib._getOracleStorage();
        $.fallbackOracle = fallbackOracle_;
        emit EventsLib.LogFallbackOracleUpdated(fallbackOracle_);
    }

    /// @notice Sets the ETH/USD price feed for USD→WETH conversion
    function setEthUsdPriceFeed(address ethUsdPriceFeed_) external onlyRole(Roles.ORACLE_ADMIN_ROLE) {
        OracleStorageLib.OracleStorage storage $ = OracleStorageLib._getOracleStorage();
        $.ethUsdPriceFeed = ethUsdPriceFeed_;
        emit EventsLib.LogEthUsdPriceFeedUpdated(ethUsdPriceFeed_);
    }

    /// @notice Sets the staleness timeout
    function setStalenessTimeout(uint256 newTimeout) external onlyRole(Roles.ORACLE_ADMIN_ROLE) {
        if (newTimeout == 0) revert ErrorsLib.ZeroAmount();
        OracleStorageLib.OracleStorage storage $ = OracleStorageLib._getOracleStorage();
        uint256 oldTimeout = $.stalenessTimeout;
        $.stalenessTimeout = newTimeout;
        emit EventsLib.LogStalenessTimeoutUpdated(oldTimeout, newTimeout);
    }

    /// @notice Sets the maximum price deviation threshold in basis points
    /// @dev Set to 0 to disable deviation check
    /// @param newMaxDeviationBps The new maximum deviation in basis points (e.g., 1500 = 15%)
    function setMaxDeviationBps(uint256 newMaxDeviationBps) external onlyRole(Roles.ORACLE_ADMIN_ROLE) {
        OracleStorageLib.OracleStorage storage $ = OracleStorageLib._getOracleStorage();
        uint256 oldMaxDeviationBps = $.maxDeviationBps;
        $.maxDeviationBps = newMaxDeviationBps;
        emit EventsLib.LogMaxDeviationBpsUpdated(oldMaxDeviationBps, newMaxDeviationBps);
    }

    /// @notice Sets the L2 sequencer uptime feed address
    /// @dev Set to address(0) to disable sequencer check (for L1 or unsupported L2s)
    /// @dev Common addresses:
    /// @dev   Arbitrum: 0xFdB631F5EE196F0ed6FAa767959853A9F217697D
    /// @dev   Optimism: 0x371EAD81c9102C9BF4874A9075FFFf170F2Ee389
    /// @dev   Base: 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433
    /// @param newSequencerUptimeFeed The new sequencer uptime feed address
    function setSequencerUptimeFeed(address newSequencerUptimeFeed) external onlyRole(Roles.ORACLE_ADMIN_ROLE) {
        OracleStorageLib.OracleStorage storage $ = OracleStorageLib._getOracleStorage();
        address oldFeed = $.sequencerUptimeFeed;
        $.sequencerUptimeFeed = newSequencerUptimeFeed;

        // Initialize grace period to default if setting feed for first time
        if (oldFeed == address(0) && newSequencerUptimeFeed != address(0) && $.sequencerGracePeriod == 0) {
            $.sequencerGracePeriod = DEFAULT_SEQUENCER_GRACE_PERIOD;
            emit EventsLib.LogSequencerGracePeriodUpdated(0, DEFAULT_SEQUENCER_GRACE_PERIOD);
        }

        emit EventsLib.LogSequencerUptimeFeedUpdated(oldFeed, newSequencerUptimeFeed);
    }

    /// @notice Sets the L2 sequencer grace period
    /// @dev This is the time to wait after sequencer comes back up before trusting prices
    /// @dev Set to 0 to disable grace period check (not recommended)
    /// @param newGracePeriod The new grace period in seconds
    function setSequencerGracePeriod(uint256 newGracePeriod) external onlyRole(Roles.ORACLE_ADMIN_ROLE) {
        OracleStorageLib.OracleStorage storage $ = OracleStorageLib._getOracleStorage();
        uint256 oldGracePeriod = $.sequencerGracePeriod;
        $.sequencerGracePeriod = newGracePeriod;
        emit EventsLib.LogSequencerGracePeriodUpdated(oldGracePeriod, newGracePeriod);
    }

    // ============ Internal Functions ============

    function _setAssetPriceSources(address[] memory assets, address[] memory sources) internal {
        if (assets.length != sources.length) revert ErrorsLib.ArrayLengthMismatch();

        OracleStorageLib.OracleStorage storage $ = OracleStorageLib._getOracleStorage();

        for (uint256 i = 0; i < assets.length; i++) {
            if (sources[i] == address(0)) revert ErrorsLib.ZeroAddress();
            $.assetPriceSources[assets[i]] = sources[i];
            emit EventsLib.LogAssetPriceSourceUpdated(assets[i], sources[i]);
        }
    }

    /// @notice Activates circuit breaker with given reason
    /// @dev No-op if circuit breaker is already active (doesn't change timestamp/reason)
    /// @dev Reason codes:
    ///      0 = NOT_ACTIVE (default state, not a valid activation reason)
    ///      1-5 = Reserved for future automatic triggers (currently unused)
    ///      6 = GUARDIAN_TRIGGERED (manual activation via activateCircuitBreaker())
    /// @dev NOTE: All CB activations are currently MANUAL (guardian only). Automatic triggers
    ///      were considered but rejected because EVM reverts roll back state changes.
    ///      Off-chain keepers should monitor for oracle failures and call activateCircuitBreaker().
    /// @param reason The reason code (use 6 for guardian-triggered)
    function _activateCircuitBreaker(uint8 reason) internal {
        OracleStorageLib.OracleStorage storage $ = OracleStorageLib._getOracleStorage();
        if (!$.circuitBreakerActive) {
            $.circuitBreakerActive = true;
            $.circuitBreakerReason = reason;
            $.circuitBreakerActivatedAt = uint64(block.timestamp);
            emit EventsLib.CircuitBreakerActivated(reason, block.timestamp);
        }
    }
}
