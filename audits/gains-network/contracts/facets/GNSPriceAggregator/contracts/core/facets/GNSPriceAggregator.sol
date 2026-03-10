// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../abstract/GNSAddressStore.sol";
import "../abstract/GNSReentrancyGuard.sol";

import "../../interfaces/libraries/IPriceAggregatorUtils.sol";

import "../../libraries/PriceAggregatorUtils.sol";
import "../../libraries/SignedPricesUtils.sol";

/**
 * @dev Facet #10: Price aggregator (does the requests to the Chainlink DON, takes the median, and executes callbacks)
 */
contract GNSPriceAggregator is GNSAddressStore, GNSReentrancyGuard, IPriceAggregatorUtils {
    // Initialization

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IPriceAggregatorUtils
    function initializePriceAggregator(
        address _linkToken,
        IChainlinkFeed _linkUsdPriceFeed,
        uint24 _twapInterval,
        uint8 _minAnswers,
        address[] memory _nodes,
        bytes32[2] memory _jobIds,
        uint8[] calldata _collateralIndices,
        LiquidityPoolInput[] calldata _gnsCollateralLiquidityPools,
        IChainlinkFeed[] memory _collateralUsdPriceFeeds
    ) external reinitializer(11) {
        PriceAggregatorUtils.initializePriceAggregator(
            _linkToken,
            _linkUsdPriceFeed,
            _twapInterval,
            _minAnswers,
            _nodes,
            _jobIds,
            _collateralIndices,
            _gnsCollateralLiquidityPools,
            _collateralUsdPriceFeeds
        );
    }

    /// @inheritdoc IPriceAggregatorUtils
    function initializeLimitJobCount(uint8 _limitJobCount) external reinitializer(19) {
        PriceAggregatorUtils.initializeLimitJobCount(_limitJobCount);
    }

    /// @inheritdoc IPriceAggregatorUtils
    function initializeMaxDeviationsP(
        uint24 _maxMarketDeviationP,
        uint24 _maxLookbackDeviationP
    ) external reinitializer(22) {
        PriceAggregatorUtils.initializeMaxDeviationsP(_maxMarketDeviationP, _maxLookbackDeviationP);
    }

    // Management Setters

    /// @inheritdoc IPriceAggregatorUtils
    function updateLinkUsdPriceFeed(IChainlinkFeed _value) external onlyRoles(Role.GOV_TIMELOCK, Role.GOV_EMERGENCY) {
        PriceAggregatorUtils.updateLinkUsdPriceFeed(_value);
    }

    /// @inheritdoc IPriceAggregatorUtils
    function updateCollateralUsdPriceFeed(
        uint8 _collateralIndex,
        IChainlinkFeed _value
    ) external onlyRoles(Role.GOV_TIMELOCK, Role.GOV_EMERGENCY) {
        PriceAggregatorUtils.updateCollateralUsdPriceFeed(_collateralIndex, _value);
    }

    /// @inheritdoc IPriceAggregatorUtils
    function updateCollateralGnsLiquidityPool(
        uint8 _collateralIndex,
        LiquidityPoolInput calldata _liquidityPoolInput
    ) external onlyRoles(Role.GOV_TIMELOCK, Role.GOV_EMERGENCY) {
        PriceAggregatorUtils.updateCollateralGnsLiquidityPool(_collateralIndex, _liquidityPoolInput);
    }

    /// @inheritdoc IPriceAggregatorUtils
    function updateTwapInterval(uint24 _twapInterval) external onlyRoles(Role.GOV_TIMELOCK, Role.GOV_EMERGENCY) {
        PriceAggregatorUtils.updateTwapInterval(_twapInterval);
    }

    /// @inheritdoc IPriceAggregatorUtils
    function updateMinAnswers(uint8 _value) external onlyRoles(Role.GOV_TIMELOCK, Role.GOV_EMERGENCY) {
        PriceAggregatorUtils.updateMinAnswers(_value);
    }

    /// @inheritdoc IPriceAggregatorUtils
    function addOracle(address _a) external onlyRole(Role.GOV_TIMELOCK) {
        PriceAggregatorUtils.addOracle(_a);
    }

    /// @inheritdoc IPriceAggregatorUtils
    function replaceOracle(uint256 _index, address _a) external onlyRoles(Role.GOV_TIMELOCK, Role.GOV_EMERGENCY) {
        PriceAggregatorUtils.replaceOracle(_index, _a);
    }

    /// @inheritdoc IPriceAggregatorUtils
    function removeOracle(uint256 _index) external onlyRoles(Role.GOV_TIMELOCK, Role.GOV_EMERGENCY) {
        PriceAggregatorUtils.removeOracle(_index);
    }

    /// @inheritdoc IPriceAggregatorUtils
    function setMarketJobId(bytes32 _jobId) external onlyRoles(Role.GOV_TIMELOCK, Role.GOV_EMERGENCY) {
        PriceAggregatorUtils.setMarketJobId(_jobId);
    }

    /// @inheritdoc IPriceAggregatorUtils
    function setLimitJobId(bytes32 _jobId) external onlyRoles(Role.GOV_TIMELOCK, Role.GOV_EMERGENCY) {
        PriceAggregatorUtils.setLimitJobId(_jobId);
    }

    /// @inheritdoc IPriceAggregatorUtils
    function setLimitJobCount(uint8 _limitJobCount) external onlyRoles(Role.GOV_TIMELOCK, Role.GOV_EMERGENCY) {
        PriceAggregatorUtils.setLimitJobCount(_limitJobCount);
    }

    /// @inheritdoc IPriceAggregatorUtils
    function setMaxMarketDeviationP(uint24 _maxMarketDeviationP) external onlyRoles(Role.GOV, Role.GOV_EMERGENCY) {
        PriceAggregatorUtils.setMaxMarketDeviationP(_maxMarketDeviationP);
    }

    /// @inheritdoc IPriceAggregatorUtils
    function setMaxLookbackDeviationP(uint24 _maxLookbackDeviationP) external onlyRoles(Role.GOV, Role.GOV_EMERGENCY) {
        PriceAggregatorUtils.setMaxLookbackDeviationP(_maxLookbackDeviationP);
    }

    // Interactions

    /// @inheritdoc IPriceAggregatorUtils
    function getPrice(
        IPriceAggregator.GetPriceInput memory _input
    ) external virtual onlySelf returns (ITradingStorage.Id memory) {
        return PriceAggregatorUtils.getPrice(_input);
    }

    /// @inheritdoc IPriceAggregatorUtils
    function fulfill(bytes32 _requestId, uint256 _priceData) external nonReentrant {
        PriceAggregatorUtils.fulfill(_requestId, _priceData); // access control handled by library (validates chainlink callback)
    }

    /// @inheritdoc IPriceAggregatorUtils
    function claimBackLink() external onlyRole(Role.GOV_TIMELOCK) {
        PriceAggregatorUtils.claimBackLink();
    }

    /// @inheritdoc IPriceAggregatorUtils
    function validateSignedPairPrices(
        IPriceAggregator.SignedPairPrices[] calldata _signedPairPrices,
        bool _isLookback
    ) external virtual onlySelf {
        SignedPricesUtils.validateSignedPairPrices(_signedPairPrices, _isLookback);
    }

    /// @inheritdoc IPriceAggregatorUtils
    function cleanUpSignedPairPrices() external virtual onlySelf {
        SignedPricesUtils.cleanUpSignedPairPrices();
    }

    // Getters

    /// @inheritdoc IPriceAggregatorUtils
    function getLinkFee(
        uint8 _collateralIndex,
        address _trader,
        uint16 _pairIndex,
        uint256 _positionSizeCollateral,
        bool _isCounterTrade
    ) external view returns (uint256) {
        return
            PriceAggregatorUtils.getLinkFee(
                _collateralIndex,
                _trader,
                _pairIndex,
                _positionSizeCollateral,
                _isCounterTrade
            );
    }

    /// @inheritdoc IPriceAggregatorUtils
    function getCollateralPriceUsd(uint8 _collateralIndex) external view returns (uint256) {
        return PriceAggregatorUtils.getCollateralPriceUsd(_collateralIndex);
    }

    /// @inheritdoc IPriceAggregatorUtils
    function getUsdNormalizedValue(uint8 _collateralIndex, uint256 _collateralValue) external view returns (uint256) {
        return PriceAggregatorUtils.getUsdNormalizedValue(_collateralIndex, _collateralValue);
    }

    /// @inheritdoc IPriceAggregatorUtils
    function getCollateralFromUsdNormalizedValue(
        uint8 _collateralIndex,
        uint256 _normalizedValue
    ) external view returns (uint256) {
        return PriceAggregatorUtils.getCollateralFromUsdNormalizedValue(_collateralIndex, _normalizedValue);
    }

    /// @inheritdoc IPriceAggregatorUtils
    function getGnsPriceUsd(uint8 _collateralIndex) external view virtual returns (uint256) {
        return PriceAggregatorUtils.getGnsPriceUsd(_collateralIndex);
    }

    /// @inheritdoc IPriceAggregatorUtils
    function getGnsPriceUsd(uint8 _collateralIndex, uint256 _gnsPriceCollateral) external view returns (uint256) {
        return PriceAggregatorUtils.getGnsPriceUsd(_collateralIndex, _gnsPriceCollateral);
    }

    /// @inheritdoc IPriceAggregatorUtils
    function getGnsPriceCollateralIndex(uint8 _collateralIndex) external view virtual returns (uint256) {
        return PriceAggregatorUtils.getGnsPriceCollateralIndex(_collateralIndex);
    }

    /// @inheritdoc IPriceAggregatorUtils
    function getGnsPriceCollateralAddress(address _collateral) external view virtual returns (uint256) {
        return PriceAggregatorUtils.getGnsPriceCollateralAddress(_collateral);
    }

    /// @inheritdoc IPriceAggregatorUtils
    function getLinkUsdPriceFeed() external view returns (IChainlinkFeed) {
        return PriceAggregatorUtils.getLinkUsdPriceFeed();
    }

    /// @inheritdoc IPriceAggregatorUtils
    function getTwapInterval() external view returns (uint24) {
        return PriceAggregatorUtils.getTwapInterval();
    }

    /// @inheritdoc IPriceAggregatorUtils
    function getMinAnswers() external view returns (uint8) {
        return PriceAggregatorUtils.getMinAnswers();
    }

    /// @inheritdoc IPriceAggregatorUtils
    function getMarketJobId() external view returns (bytes32) {
        return PriceAggregatorUtils.getMarketJobId();
    }

    /// @inheritdoc IPriceAggregatorUtils
    function getLimitJobId() external view returns (bytes32) {
        return PriceAggregatorUtils.getLimitJobId();
    }

    /// @inheritdoc IPriceAggregatorUtils
    function getOracle(uint256 _index) external view returns (address) {
        return PriceAggregatorUtils.getOracle(_index);
    }

    /// @inheritdoc IPriceAggregatorUtils
    function getOracles() external view returns (address[] memory) {
        return PriceAggregatorUtils.getOracles();
    }

    /// @inheritdoc IPriceAggregatorUtils
    function getCollateralGnsLiquidityPool(uint8 _collateralIndex) external view returns (LiquidityPoolInfo memory) {
        return PriceAggregatorUtils.getCollateralGnsLiquidityPool(_collateralIndex);
    }

    /// @inheritdoc IPriceAggregatorUtils
    function getCollateralUsdPriceFeed(uint8 _collateralIndex) external view returns (IChainlinkFeed) {
        return PriceAggregatorUtils.getCollateralUsdPriceFeed(_collateralIndex);
    }

    /// @inheritdoc IPriceAggregatorUtils
    function getPriceAggregatorOrder(bytes32 _requestId) external view returns (Order memory) {
        return PriceAggregatorUtils.getPriceAggregatorOrder(_requestId);
    }

    /// @inheritdoc IPriceAggregatorUtils
    function getPriceAggregatorOrderAnswers(
        ITradingStorage.Id calldata _orderId
    ) external view returns (OrderAnswer[] memory) {
        return PriceAggregatorUtils.getPriceAggregatorOrderAnswers(_orderId);
    }

    /// @inheritdoc IPriceAggregatorUtils
    function getChainlinkToken() external view returns (address) {
        return PriceAggregatorUtils.getChainlinkToken();
    }

    /// @inheritdoc IPriceAggregatorUtils
    function getRequestCount() external view returns (uint256) {
        return PriceAggregatorUtils.getRequestCount();
    }

    /// @inheritdoc IPriceAggregatorUtils
    function getPendingRequest(bytes32 _id) external view returns (address) {
        return PriceAggregatorUtils.getPendingRequest(_id);
    }

    /// @inheritdoc IPriceAggregatorUtils
    function getLimitJobCount() external view returns (uint8) {
        return PriceAggregatorUtils.getLimitJobCount();
    }

    /// @inheritdoc IPriceAggregatorUtils
    function getLimitJobIndex() external view returns (uint88) {
        return PriceAggregatorUtils.getLimitJobIndex();
    }

    /// @inheritdoc IPriceAggregatorUtils
    function getMaxMarketDeviationP() external view returns (uint24) {
        return PriceAggregatorUtils.getMaxMarketDeviationP();
    }

    function getMaxLookbackDeviationP() external view returns (uint24) {
        return PriceAggregatorUtils.getMaxLookbackDeviationP();
    }

    /// @inheritdoc IPriceAggregatorUtils
    function getPairSignedOrderAnswersTemporary(
        uint16 _pairIndex
    ) external view returns (IPriceAggregator.OrderAnswer[] memory) {
        return PriceAggregatorUtils.getPairSignedOrderAnswersTemporary(_pairIndex);
    }

    /// @inheritdoc IPriceAggregatorUtils
    function getPairSignedMedianTemporary(
        uint16 _pairIndex
    ) external view returns (ITradingCallbacks.AggregatorAnswer memory) {
        return PriceAggregatorUtils.getPairSignedMedianTemporary(_pairIndex);
    }

    /// @inheritdoc IPriceAggregatorUtils
    function getSignedPairIndicesTemporary() external view returns (uint16[] memory) {
        return PriceAggregatorUtils.getSignedPairIndicesTemporary();
    }
}
