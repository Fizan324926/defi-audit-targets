// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Chainlink} from "@chainlink/contracts/src/v0.8/Chainlink.sol";

import "../interfaces/IGNSMultiCollatDiamond.sol";
import "../interfaces/IChainlinkFeed.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/ILiquidityPool.sol";

import "./AddressStoreUtils.sol";
import "./StorageUtils.sol";
import "./ChainlinkClientUtils.sol";
import "./PackingUtils.sol";
import "./ConstantsUtils.sol";
import "./TradingCommonUtils.sol";
import "./LiquidityPoolUtils.sol";

/**
 * @dev GNSPriceAggregator facet external library
 */
library PriceAggregatorUtils {
    using PackingUtils for uint256;
    using SafeERC20 for IERC20;
    using Chainlink for Chainlink.Request;
    using LiquidityPoolUtils for IPriceAggregator.LiquidityPoolInput;
    using LiquidityPoolUtils for IPriceAggregator.LiquidityPoolInfo;

    uint256 private constant MAX_ORACLE_NODES = 20;
    uint256 private constant MIN_ANSWERS = 2;
    uint32 private constant MIN_TWAP_PERIOD = 1 hours / 2;
    uint32 private constant MAX_TWAP_PERIOD = 4 hours;
    uint256 private constant REQUEST_TIMEOUT_SECONDS = 1 hours;

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function initializePriceAggregator(
        address _linkErc677,
        IChainlinkFeed _linkUsdPriceFeed,
        uint24 _twapInterval,
        uint8 _minAnswers,
        address[] memory _oracles,
        bytes32[2] memory _jobIds,
        uint8[] calldata _collateralIndices,
        IPriceAggregator.LiquidityPoolInput[] calldata _gnsCollateralLiquidityPools,
        IChainlinkFeed[] memory _collateralUsdPriceFeeds
    ) internal {
        if (
            _collateralIndices.length != _gnsCollateralLiquidityPools.length ||
            _collateralIndices.length != _collateralUsdPriceFeeds.length
        ) revert IGeneralErrors.WrongLength();

        ChainlinkClientUtils.setChainlinkToken(_linkErc677);
        updateLinkUsdPriceFeed(_linkUsdPriceFeed);
        updateTwapInterval(_twapInterval);
        updateMinAnswers(_minAnswers);

        for (uint256 i = 0; i < _oracles.length; ++i) {
            addOracle(_oracles[i]);
        }

        setMarketJobId(_jobIds[0]);
        setLimitJobId(_jobIds[1]);

        for (uint8 i = 0; i < _collateralIndices.length; ++i) {
            updateCollateralGnsLiquidityPool(_collateralIndices[i], _gnsCollateralLiquidityPools[i]);
            updateCollateralUsdPriceFeed(_collateralIndices[i], _collateralUsdPriceFeeds[i]);
        }
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function initializeLimitJobCount(uint8 _limitJobCount) internal {
        setLimitJobCount(_limitJobCount);
        _getStorage().limitJobIndex = 0; // Ensure limit job index starts at 0
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function initializeMaxDeviationsP(uint24 _maxMarketDeviationP, uint24 _maxLookbackDeviationP) internal {
        setMaxMarketDeviationP(_maxMarketDeviationP);
        setMaxLookbackDeviationP(_maxLookbackDeviationP);
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function updateLinkUsdPriceFeed(IChainlinkFeed _value) internal {
        if (address(_value) == address(0)) revert IGeneralErrors.ZeroValue();

        _getStorage().linkUsdPriceFeed = _value;

        emit IPriceAggregatorUtils.LinkUsdPriceFeedUpdated(address(_value));
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function updateCollateralUsdPriceFeed(
        uint8 _collateralIndex,
        IChainlinkFeed _value
    ) internal validCollateralIndex(_collateralIndex) {
        if (address(_value) == address(0)) revert IGeneralErrors.ZeroValue();
        if (_value.decimals() != 8) revert IPriceAggregatorUtils.WrongCollateralUsdDecimals();

        _getStorage().collateralUsdPriceFeed[_collateralIndex] = _value;

        emit IPriceAggregatorUtils.CollateralUsdPriceFeedUpdated(_collateralIndex, address(_value));
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function updateCollateralGnsLiquidityPool(
        uint8 _collateralIndex,
        IPriceAggregator.LiquidityPoolInput calldata _liquidityPoolInput
    ) internal validCollateralIndex(_collateralIndex) {
        if (
            address(_liquidityPoolInput.pool) == address(0) &&
            _liquidityPoolInput.poolType != IPriceAggregator.PoolType.CONSTANT_VALUE
        ) revert IGeneralErrors.ZeroValue();

        if (
            (_liquidityPoolInput.poolType == IPriceAggregator.PoolType.CONSTANT_VALUE) !=
            _getMultiCollatDiamond().isCollateralGns(_collateralIndex)
        ) revert IGeneralErrors.WrongParams();

        // Fetch LiquidityPoolInfo from LP utils library
        IPriceAggregator.LiquidityPoolInfo memory poolInfo = _liquidityPoolInput.getLiquidityPoolInfo();

        // Update liquidity pool storage for collateral
        _getStorage().collateralGnsLiquidityPools[_collateralIndex] = poolInfo;

        emit IPriceAggregatorUtils.CollateralGnsLiquidityPoolUpdated(_collateralIndex, poolInfo);
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function updateTwapInterval(uint24 _twapInterval) internal {
        if (_twapInterval < MIN_TWAP_PERIOD || _twapInterval > MAX_TWAP_PERIOD) revert IGeneralErrors.WrongParams();

        _getStorage().twapInterval = _twapInterval;

        emit IPriceAggregatorUtils.TwapIntervalUpdated(_twapInterval);
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function updateMinAnswers(uint8 _value) internal {
        if (_value < MIN_ANSWERS) revert IGeneralErrors.BelowMin();

        _getStorage().minAnswers = _value;

        emit IPriceAggregatorUtils.MinAnswersUpdated(_value);
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function addOracle(address _a) internal {
        IPriceAggregator.PriceAggregatorStorage storage s = _getStorage();

        if (_a == address(0)) revert IGeneralErrors.ZeroValue();
        if (s.oracles.length >= MAX_ORACLE_NODES) revert IGeneralErrors.AboveMax();

        for (uint256 i; i < s.oracles.length; ++i) {
            if (s.oracles[i] == _a) revert IPriceAggregatorUtils.OracleAlreadyListed();
        }

        s.oracles.push(_a);

        emit IPriceAggregatorUtils.OracleAdded(s.oracles.length - 1, _a);
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function replaceOracle(uint256 _index, address _a) internal {
        IPriceAggregator.PriceAggregatorStorage storage s = _getStorage();

        if (_index >= s.oracles.length) revert IGeneralErrors.WrongIndex();
        if (_a == address(0)) revert IGeneralErrors.ZeroValue();

        address oldNode = s.oracles[_index];
        s.oracles[_index] = _a;

        emit IPriceAggregatorUtils.OracleReplaced(_index, oldNode, _a);
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function removeOracle(uint256 _index) internal {
        IPriceAggregator.PriceAggregatorStorage storage s = _getStorage();

        if (_index >= s.oracles.length) revert IGeneralErrors.WrongIndex();

        address oldNode = s.oracles[_index];

        s.oracles[_index] = s.oracles[s.oracles.length - 1];
        s.oracles.pop();

        emit IPriceAggregatorUtils.OracleRemoved(_index, oldNode);
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function setMarketJobId(bytes32 _jobId) internal {
        if (_jobId == bytes32(0)) revert IGeneralErrors.ZeroValue();

        _getStorage().jobIds[0] = _jobId;

        emit IPriceAggregatorUtils.JobIdUpdated(0, _jobId);
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function setLimitJobId(bytes32 _jobId) internal {
        if (_jobId == bytes32(0)) revert IGeneralErrors.ZeroValue();

        _getStorage().jobIds[1] = _jobId;

        emit IPriceAggregatorUtils.JobIdUpdated(1, _jobId);
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function setLimitJobCount(uint8 _limitJobCount) internal {
        if (_limitJobCount == 0) revert IGeneralErrors.ZeroValue();

        _getStorage().limitJobCount = _limitJobCount;

        emit IPriceAggregatorUtils.LimitJobCountUpdated(_limitJobCount);
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function setMaxMarketDeviationP(uint24 _maxMarketDeviationP) internal {
        _getStorage().maxMarketDeviationP = _maxMarketDeviationP;

        emit IPriceAggregatorUtils.MaxMarketDeviationPUpdated(_maxMarketDeviationP);
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function setMaxLookbackDeviationP(uint24 _maxLookbackDeviationP) internal {
        _getStorage().maxLookbackDeviationP = _maxLookbackDeviationP;

        emit IPriceAggregatorUtils.MaxLookbackDeviationPUpdated(_maxLookbackDeviationP);
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function getPrice(
        IPriceAggregator.GetPriceInput memory _input
    ) external validCollateralIndex(_input.collateralIndex) returns (ITradingStorage.Id memory) {
        IPriceAggregator.PriceAggregatorStorage storage s = _getStorage();

        // 1. Store pending order in storage
        _input.pendingOrder = _getMultiCollatDiamond().storePendingOrder(_input.pendingOrder);

        // 2. Build chainlink request
        bool isLookback = !ConstantsUtils.isOrderTypeMarket(_input.pendingOrder.orderType);

        Chainlink.Request memory linkRequest = ChainlinkClientUtils.buildChainlinkRequest(
            _getJobId(isLookback),
            address(this),
            IPriceAggregatorUtils.fulfill.selector
        );

        {
            (string memory from, string memory to) = _getMultiCollatDiamond().pairJob(_input.pairIndex);

            linkRequest.add("from", from);
            linkRequest.add("to", to);

            if (isLookback) {
                linkRequest.addUint("fromBlock", _input.fromBlock);
                linkRequest.addBytes("trader", abi.encodePacked(_input.pendingOrder.trade.user));
                linkRequest.addUint("index", uint256(_input.pendingOrder.trade.index));
                linkRequest.addUint("orderType", uint256(_input.pendingOrder.orderType));
            }

            emit IPriceAggregatorUtils.LinkRequestCreated(linkRequest);
        }

        // 2. Calculate link fee for each oracle
        TradingCommonUtils.updateFeeTierPoints(
            _input.collateralIndex,
            _input.pendingOrder.trade.user,
            _input.pairIndex,
            0
        );
        uint256 linkFeePerNode = getLinkFee(
            _input.collateralIndex,
            _input.pendingOrder.trade.user,
            _input.pairIndex,
            _input.positionSizeCollateral,
            _input.isCounterTrade
        ) / s.oracles.length;

        // 4. Send request to all oracles
        {
            IPriceAggregator.Order memory order = IPriceAggregator.Order({
                user: _input.pendingOrder.user,
                index: _input.pendingOrder.index,
                orderType: _input.pendingOrder.orderType,
                pairIndex: uint16(_input.pairIndex),
                isLookback: isLookback,
                __placeholder: 0
            });

            for (uint256 i; i < s.oracles.length; ++i) {
                bytes32 requestId = ChainlinkClientUtils.sendChainlinkRequestTo(
                    s.oracles[i],
                    linkRequest,
                    linkFeePerNode
                );
                s.orders[requestId] = order;
            }
        }

        emit IPriceAggregatorUtils.PriceRequested(
            _input.collateralIndex,
            _input.pairIndex,
            _input.pendingOrder,
            _input.positionSizeCollateral,
            _input.fromBlock,
            _input.isCounterTrade,
            isLookback,
            linkRequest.id,
            linkFeePerNode,
            s.oracles.length
        );

        return ITradingStorage.Id(_input.pendingOrder.user, _input.pendingOrder.index);
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function fulfill(bytes32 _requestId, uint256 _priceData) external {
        ChainlinkClientUtils.validateChainlinkCallback(_requestId);

        IPriceAggregator.PriceAggregatorStorage storage s = _getStorage();

        IPriceAggregator.Order memory order = s.orders[_requestId];
        ITradingStorage.Id memory orderId = ITradingStorage.Id({user: order.user, index: order.index});

        ITradingStorage.PendingOrder memory pendingOrder = _getMultiCollatDiamond().getPendingOrder(orderId);
        if (
            ChainUtils.convertBlocksToSeconds(ChainUtils.getBlockNumber() - pendingOrder.createdBlock) >
            REQUEST_TIMEOUT_SECONDS
        ) revert IGeneralErrors.DoesntExist();

        bool usedInMedian = pendingOrder.isOpen;
        bool minAnswersReached;
        bool minFilteredAnswersReached;

        IPriceAggregator.OrderAnswer[] memory unfilteredAnswers;
        IPriceAggregator.OrderAnswer[] memory filteredAnswers;

        if (usedInMedian) {
            IPriceAggregator.OrderAnswer memory newAnswer;
            (newAnswer.current, newAnswer.open, newAnswer.high, newAnswer.low, newAnswer.ts) = _priceData
                .unpackAggregatorAnswer();

            _validateAggregatorAnswer(newAnswer, order.isLookback);

            IPriceAggregator.OrderAnswer[] storage orderAnswers = s.orderAnswers[orderId.user][orderId.index];
            orderAnswers.push(newAnswer);

            unfilteredAnswers = orderAnswers;
            filteredAnswers = unfilteredAnswers;

            uint8 minAnswers = s.minAnswers;
            minAnswersReached = orderAnswers.length >= minAnswers;

            if (minAnswersReached) {
                ITradingCallbacks.AggregatorAnswer memory finalAnswer;

                {
                    uint256 maxDeviationP = order.isLookback ? s.maxLookbackDeviationP : s.maxMarketDeviationP;
                    (filteredAnswers, minFilteredAnswersReached, finalAnswer) = _filterOutliersAndReturnMedian(
                        unfilteredAnswers,
                        order.isLookback,
                        minAnswers,
                        maxDeviationP
                    );
                }

                finalAnswer.orderId = orderId;

                if (minFilteredAnswersReached) {
                    if (order.orderType == ITradingStorage.PendingOrderType.MARKET_OPEN)
                        _getMultiCollatDiamond().openTradeMarketCallback(finalAnswer);
                    else if (order.orderType == ITradingStorage.PendingOrderType.MARKET_CLOSE)
                        _getMultiCollatDiamond().closeTradeMarketCallback(finalAnswer);
                    else if (
                        order.orderType == ITradingStorage.PendingOrderType.LIMIT_OPEN ||
                        order.orderType == ITradingStorage.PendingOrderType.STOP_OPEN
                    ) _getMultiCollatDiamond().executeTriggerOpenOrderCallback(finalAnswer);
                    else if (
                        order.orderType == ITradingStorage.PendingOrderType.TP_CLOSE ||
                        order.orderType == ITradingStorage.PendingOrderType.SL_CLOSE ||
                        order.orderType == ITradingStorage.PendingOrderType.LIQ_CLOSE
                    ) _getMultiCollatDiamond().executeTriggerCloseOrderCallback(finalAnswer);
                    else if (order.orderType == ITradingStorage.PendingOrderType.UPDATE_LEVERAGE)
                        _getMultiCollatDiamond().updateLeverageCallback(finalAnswer);
                    else if (order.orderType == ITradingStorage.PendingOrderType.MARKET_PARTIAL_OPEN)
                        _getMultiCollatDiamond().increasePositionSizeMarketCallback(finalAnswer);
                    else if (order.orderType == ITradingStorage.PendingOrderType.MARKET_PARTIAL_CLOSE)
                        _getMultiCollatDiamond().decreasePositionSizeMarketCallback(finalAnswer);
                    else if (order.orderType == ITradingStorage.PendingOrderType.PNL_WITHDRAWAL)
                        _getMultiCollatDiamond().pnlWithdrawalCallback(finalAnswer);
                    else if (order.orderType == ITradingStorage.PendingOrderType.MANUAL_HOLDING_FEES_REALIZATION)
                        _getMultiCollatDiamond().manualHoldingFeesRealizationCallback(finalAnswer);
                    else if (order.orderType == ITradingStorage.PendingOrderType.MANUAL_NEGATIVE_PNL_REALIZATION)
                        _getMultiCollatDiamond().manualNegativePnlRealizationCallback(finalAnswer);

                    _getMultiCollatDiamond().closePendingOrder(orderId);

                    emit IPriceAggregatorUtils.TradingCallbackExecuted(finalAnswer, order.orderType);
                }
            }
        }

        emit IPriceAggregatorUtils.PriceReceived(
            orderId,
            order.pairIndex,
            _requestId,
            _priceData,
            order.isLookback,
            usedInMedian,
            minAnswersReached,
            minFilteredAnswersReached,
            unfilteredAnswers,
            filteredAnswers
        );
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function claimBackLink() external {
        address treasury = AddressStoreUtils.getAddresses().treasury;

        if (treasury == address(0)) revert IGeneralErrors.ZeroAddress();

        IERC20 link = IERC20(getChainlinkToken());
        uint256 linkAmount = link.balanceOf(address(this));

        link.safeTransfer(treasury, linkAmount);

        emit IPriceAggregatorUtils.LinkClaimedBack(linkAmount);
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function getLinkFee(
        uint8 _collateralIndex,
        address _trader,
        uint16 _pairIndex,
        uint256 _positionSizeCollateral, // collateral precision
        bool _isCounterTrade
    ) public view returns (uint256) {
        if (_positionSizeCollateral == 0) return 0;

        (, int256 linkPriceUsd, , , ) = _getStorage().linkUsdPriceFeed.latestRoundData(); // 1e8

        uint256 feeRateMultiplier = _isCounterTrade
            ? _getMultiCollatDiamond().getPairCounterTradeFeeRateMultiplier(_pairIndex)
            : 1e3;

        uint256 linkFeeCollateral = _getMultiCollatDiamond().pairOraclePositionSizeFeeP(_pairIndex) *
            TradingCommonUtils.getPositionSizeCollateralBasis(
                _collateralIndex,
                _pairIndex,
                _positionSizeCollateral,
                feeRateMultiplier
            ); // 1e10 (%) * collateral precision * 1e3

        uint256 rawLinkFee = (getUsdNormalizedValue(_collateralIndex, linkFeeCollateral) * 1e8) /
            uint256(linkPriceUsd) /
            ConstantsUtils.P_10 /
            100 /
            1e3; // 1e18

        return _getMultiCollatDiamond().calculateFeeAmount(_trader, rawLinkFee);
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function getCollateralPriceUsd(uint8 _collateralIndex) public view returns (uint256) {
        (, int256 collateralPriceUsd, , , ) = _getStorage().collateralUsdPriceFeed[_collateralIndex].latestRoundData();

        return uint256(collateralPriceUsd);
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function getUsdNormalizedValue(uint8 _collateralIndex, uint256 _collateralValue) public view returns (uint256) {
        return
            (_collateralValue *
                _getCollateralPrecisionDelta(_collateralIndex) *
                getCollateralPriceUsd(_collateralIndex)) / 1e8;
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function getCollateralFromUsdNormalizedValue(
        uint8 _collateralIndex,
        uint256 _normalizedValue
    ) external view returns (uint256) {
        return
            (_normalizedValue * 1e8) /
            getCollateralPriceUsd(_collateralIndex) /
            _getCollateralPrecisionDelta(_collateralIndex);
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function getGnsPriceUsd(uint8 _collateralIndex) external view returns (uint256) {
        return getGnsPriceUsd(_collateralIndex, getGnsPriceCollateralIndex(_collateralIndex));
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function getGnsPriceUsd(uint8 _collateralIndex, uint256 _gnsPriceCollateral) public view returns (uint256) {
        return (_gnsPriceCollateral * getCollateralPriceUsd(_collateralIndex)) / 1e8;
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function getGnsPriceCollateralAddress(address _collateral) external view returns (uint256 _price) {
        return getGnsPriceCollateralIndex(_getMultiCollatDiamond().getCollateralIndex(_collateral));
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function getGnsPriceCollateralIndex(uint8 _collateralIndex) public view returns (uint256 _price) {
        IPriceAggregator.PriceAggregatorStorage storage s = _getStorage();
        uint32 twapInterval = uint32(s.twapInterval);

        return
            s.collateralGnsLiquidityPools[_collateralIndex].getTimeWeightedAveragePrice(
                twapInterval,
                _getCollateralPrecisionDelta(_collateralIndex)
            );
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function getLinkUsdPriceFeed() external view returns (IChainlinkFeed) {
        return _getStorage().linkUsdPriceFeed;
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function getTwapInterval() external view returns (uint24) {
        return _getStorage().twapInterval;
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function getMinAnswers() external view returns (uint8) {
        return _getStorage().minAnswers;
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function getMarketJobId() external view returns (bytes32) {
        return _getStorage().jobIds[0];
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function getLimitJobId() external view returns (bytes32) {
        return _getStorage().jobIds[1];
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function getOracle(uint256 _index) external view returns (address) {
        return _getStorage().oracles[_index];
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function getOracles() external view returns (address[] memory) {
        return _getStorage().oracles;
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function getCollateralGnsLiquidityPool(
        uint8 _collateralIndex
    ) external view returns (IPriceAggregator.LiquidityPoolInfo memory) {
        return _getStorage().collateralGnsLiquidityPools[_collateralIndex];
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function getCollateralUsdPriceFeed(uint8 _collateralIndex) external view returns (IChainlinkFeed) {
        return _getStorage().collateralUsdPriceFeed[_collateralIndex];
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function getPriceAggregatorOrder(bytes32 _requestId) external view returns (IPriceAggregator.Order memory) {
        return _getStorage().orders[_requestId];
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function getPriceAggregatorOrderAnswers(
        ITradingStorage.Id calldata _orderId
    ) external view returns (IPriceAggregator.OrderAnswer[] memory) {
        return _getStorage().orderAnswers[_orderId.user][_orderId.index];
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function getChainlinkToken() public view returns (address) {
        return address(_getStorage().linkErc677);
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function getRequestCount() external view returns (uint256) {
        return _getStorage().requestCount;
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function getPendingRequest(bytes32 _id) external view returns (address) {
        return _getStorage().pendingRequests[_id];
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function getLimitJobCount() external view returns (uint8) {
        return _getStorage().limitJobCount;
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function getLimitJobIndex() external view returns (uint88) {
        return _getStorage().limitJobIndex;
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function getMaxMarketDeviationP() external view returns (uint24) {
        return _getStorage().maxMarketDeviationP;
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function getMaxLookbackDeviationP() external view returns (uint24) {
        return _getStorage().maxLookbackDeviationP;
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function getPairSignedOrderAnswersTemporary(
        uint16 _pairIndex
    ) external view returns (IPriceAggregator.OrderAnswer[] memory) {
        return _getStorage().signedOrderAnswersTemporary[_pairIndex];
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function getPairSignedMedianTemporary(
        uint16 _pairIndex
    ) external view returns (ITradingCallbacks.AggregatorAnswer memory) {
        ITradingCallbacks.AggregatorAnswer memory answer = _getStorage().signedMediansTemporary[_pairIndex];
        if (answer.current == 0) revert IPriceAggregatorUtils.MinAnswersNotReached();
        return answer;
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function getSignedPairIndicesTemporary() external view returns (uint16[] memory) {
        return _getStorage().signedPairIndicesTemporary;
    }

    /**
     * @dev Returns storage slot to use when fetching storage relevant to library
     */
    function _getSlot() internal pure returns (uint256) {
        return StorageUtils.GLOBAL_PRICE_AGGREGATOR_SLOT;
    }

    /**
     * @dev Returns storage pointer for storage struct in diamond contract, at defined slot
     */
    function _getStorage() internal pure returns (IPriceAggregator.PriceAggregatorStorage storage s) {
        uint256 storageSlot = _getSlot();
        assembly {
            s.slot := storageSlot
        }
    }

    /**
     * @dev Returns current address as multi-collateral diamond interface to call other facets functions.
     */
    function _getMultiCollatDiamond() internal view returns (IGNSMultiCollatDiamond) {
        return IGNSMultiCollatDiamond(address(this));
    }

    /**
     * @dev Modifier to revert if collateral index is not valid
     */
    modifier validCollateralIndex(uint8 _collateralIndex) {
        _validCollateralIndex(_collateralIndex);
        _;
    }

    /**
     * @dev Reverts if collateral index is not valid
     * @param _collateralIndex collateral index
     */
    function _validCollateralIndex(uint8 _collateralIndex) internal view {
        if (!_getMultiCollatDiamond().isCollateralListed(_collateralIndex)) {
            revert IGeneralErrors.InvalidCollateralIndex();
        }
    }

    /**
     * @dev returns median price of array (1 price only)
     * @param _array array of values
     */
    function _median(IPriceAggregator.OrderAnswer[] memory _array) internal pure returns (uint64) {
        uint256 length = _array.length;

        uint256[] memory prices = new uint256[](length);

        for (uint256 i; i < length; ++i) {
            prices[i] = _array[i].current;
        }

        _sort(prices, 0, length);

        return uint64(length % 2 == 0 ? (prices[length / 2 - 1] + prices[length / 2]) / 2 : prices[length / 2]);
    }

    /**
     * @dev returns median prices of array (open, high, low)
     * @param _array array of values
     */
    function _medianLookbacks(
        IPriceAggregator.OrderAnswer[] memory _array
    ) internal pure returns (uint64 open, uint64 high, uint64 low, uint64 current) {
        uint256 length = _array.length;

        uint256[] memory opens = new uint256[](length);
        uint256[] memory highs = new uint256[](length);
        uint256[] memory lows = new uint256[](length);
        uint256[] memory currents = new uint256[](length);

        for (uint256 i; i < length; ++i) {
            opens[i] = _array[i].open;
            highs[i] = _array[i].high;
            lows[i] = _array[i].low;
            currents[i] = _array[i].current;
        }

        _sort(opens, 0, length);
        _sort(highs, 0, length);
        _sort(lows, 0, length);
        _sort(currents, 0, length);

        bool isLengthEven = length % 2 == 0;
        uint256 halfLength = length / 2;

        open = uint64(isLengthEven ? (opens[halfLength - 1] + opens[halfLength]) / 2 : opens[halfLength]);
        high = uint64(isLengthEven ? (highs[halfLength - 1] + highs[halfLength]) / 2 : highs[halfLength]);
        low = uint64(isLengthEven ? (lows[halfLength - 1] + lows[halfLength]) / 2 : lows[halfLength]);
        current = uint64(isLengthEven ? (currents[halfLength - 1] + currents[halfLength]) / 2 : currents[halfLength]);
    }

    /**
     * @dev swaps two elements in array
     * @param _array array of values
     * @param _i index of first element
     * @param _j index of second element
     */
    function _swap(uint256[] memory _array, uint256 _i, uint256 _j) internal pure {
        (_array[_i], _array[_j]) = (_array[_j], _array[_i]);
    }

    /**
     * @dev sorts array of uint256 values
     * @param _array array of values
     * @param begin start index
     * @param end end index
     */
    function _sort(uint256[] memory _array, uint256 begin, uint256 end) internal pure {
        if (begin >= end) {
            return;
        }

        uint256 j = begin;
        uint256 pivot = _array[j];

        for (uint256 i = begin + 1; i < end; ++i) {
            if (_array[i] < pivot) {
                _swap(_array, i, ++j);
            }
        }

        _swap(_array, begin, j);
        _sort(_array, begin, j);
        _sort(_array, j + 1, end);
    }

    /**
     * @dev Returns precision delta of collateral as uint256
     * @param _collateralIndex index of collateral
     */
    function _getCollateralPrecisionDelta(uint8 _collateralIndex) internal view returns (uint256) {
        return uint256(_getMultiCollatDiamond().getCollateral(_collateralIndex).precisionDelta);
    }

    /**
     * @dev Calculates and returns the appropriate job id for a request
     * @param _isLookback whether the request is a lookback job
     */
    function _getJobId(bool _isLookback) internal returns (bytes32) {
        IPriceAggregator.PriceAggregatorStorage storage s = _getStorage();

        if (!_isLookback) return s.jobIds[0];

        bytes32 limitJobId = s.jobIds[1];

        // Return early if limitJobCount is not configured
        if (s.limitJobCount == 0) return limitJobId;

        // Increment the limit job id in an unchecked block so if `limitJobId` is type(bytes32).max it won't revert
        unchecked {
            return bytes32(uint256(limitJobId) + (s.limitJobIndex++ % s.limitJobCount));
        }
    }

    /**
     * @dev Returns whether the price is within the max deviation from the median price
     * @param _price price to check (1e10)
     * @param _medianPrice median price (1e10)
     * @param _maxDeviationP max deviation in percentage (1e3, %)
     */
    function _isPriceWithinMaxDeviationFromMedianP(
        uint256 _price,
        uint256 _medianPrice,
        uint256 _maxDeviationP
    ) internal pure returns (bool) {
        return
            ((_price > _medianPrice ? _price - _medianPrice : _medianPrice - _price) * 100 * 1e3) / _medianPrice <=
            _maxDeviationP;
    }

    /**
     * @dev Returns market oracle answers within the max deviation from median
     * @param _orderAnswers array of oracle answers (1e10)
     * @param _medianMarket median market price (1e10)
     * @param _maxMarketDeviationP max deviation (1e3, %)
     */
    function _filterOutMarketAnswersOutsideMaxDeviationFromMedianP(
        IPriceAggregator.OrderAnswer[] memory _orderAnswers,
        uint64 _medianMarket,
        uint256 _maxMarketDeviationP
    ) internal pure returns (IPriceAggregator.OrderAnswer[] memory) {
        uint256 answersCount = _orderAnswers.length;
        uint256 validAnswersCount;
        bool[] memory isAnswerValid = new bool[](answersCount);

        for (uint256 i; i < answersCount; ++i) {
            uint256 marketPrice = _orderAnswers[i].current;
            bool isValid = _isPriceWithinMaxDeviationFromMedianP(marketPrice, _medianMarket, _maxMarketDeviationP);

            isAnswerValid[i] = isValid;
            if (isValid) ++validAnswersCount;
        }

        IPriceAggregator.OrderAnswer[] memory filteredAnswers = new IPriceAggregator.OrderAnswer[](validAnswersCount);
        uint256 lastFilteredAnswerIndex;

        for (uint256 i; i < answersCount; ++i) {
            if (isAnswerValid[i]) filteredAnswers[lastFilteredAnswerIndex++] = _orderAnswers[i];
        }

        return filteredAnswers;
    }

    /**
     * @dev Returns lookback oracle answers within the max deviation from median
     * @param _orderAnswers array of oracle answers (1e10)
     * @param _medianPrices median open/high/low prices (1e10)
     * @param _maxLookbackDeviationP max deviation (1e3, %)
     */
    function _filterOutLookbackAnswersOutsideMaxDeviationFromMedianP(
        IPriceAggregator.OrderAnswer[] memory _orderAnswers,
        ITradingCallbacks.AggregatorAnswer memory _medianPrices,
        uint256 _maxLookbackDeviationP
    ) internal pure returns (IPriceAggregator.OrderAnswer[] memory) {
        uint256 answersCount = _orderAnswers.length;
        uint256 validAnswersCount;
        bool[] memory isAnswerValid = new bool[](answersCount);

        uint256 medianOpen = _medianPrices.open;
        uint256 medianHigh = _medianPrices.high;
        uint256 medianLow = _medianPrices.low;
        uint256 medianCurrent = _medianPrices.current;

        for (uint256 i; i < answersCount; ++i) {
            IPriceAggregator.OrderAnswer memory answer = _orderAnswers[i];

            bool isValid = _isPriceWithinMaxDeviationFromMedianP(answer.open, medianOpen, _maxLookbackDeviationP) &&
                _isPriceWithinMaxDeviationFromMedianP(answer.high, medianHigh, _maxLookbackDeviationP) &&
                _isPriceWithinMaxDeviationFromMedianP(answer.low, medianLow, _maxLookbackDeviationP) &&
                _isPriceWithinMaxDeviationFromMedianP(answer.current, medianCurrent, _maxLookbackDeviationP);

            isAnswerValid[i] = isValid;
            if (isValid) ++validAnswersCount;
        }

        IPriceAggregator.OrderAnswer[] memory filteredAnswers = new IPriceAggregator.OrderAnswer[](validAnswersCount);
        uint256 lastFilteredAnswerIndex;

        for (uint256 i; i < answersCount; ++i) {
            if (isAnswerValid[i]) filteredAnswers[lastFilteredAnswerIndex++] = _orderAnswers[i];
        }

        return filteredAnswers;
    }

    /**
     * @dev Validates an aggregator answer
     * @param _answer the answer to validate
     * @param _isLookback whether the answer is for a lookback order
     */
    function _validateAggregatorAnswer(IPriceAggregator.OrderAnswer memory _answer, bool _isLookback) internal pure {
        // Valid inputs:
        // 1. non-lookback:
        // - current > 0 => open/high/low ignored
        // 2. lookback:
        // - open > 0, high > 0, low > 0 (high >= open, low <= open), current > 0
        if (
            _answer.current == 0 ||
            (_isLookback &&
                (_answer.high < _answer.open || _answer.low > _answer.open || _answer.open == 0 || _answer.low == 0))
        ) revert IPriceAggregatorUtils.InvalidCandle();
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function _filterOutliersAndReturnMedian(
        IPriceAggregator.OrderAnswer[] memory _unfilteredAnswers,
        bool _isLookback,
        uint8 _minAnswers,
        uint256 _maxDeviationP
    )
        internal
        pure
        returns (
            IPriceAggregator.OrderAnswer[] memory filteredAnswers,
            bool minFilteredAnswersReached,
            ITradingCallbacks.AggregatorAnswer memory median
        )
    {
        if (_isLookback) {
            (median.open, median.high, median.low, median.current) = _medianLookbacks(_unfilteredAnswers);

            if (_maxDeviationP > 0) {
                filteredAnswers = _filterOutLookbackAnswersOutsideMaxDeviationFromMedianP(
                    _unfilteredAnswers,
                    median,
                    _maxDeviationP
                );

                minFilteredAnswersReached = filteredAnswers.length >= _minAnswers;

                if (minFilteredAnswersReached)
                    (median.open, median.high, median.low, median.current) = _medianLookbacks(filteredAnswers);
            } else {
                filteredAnswers = _unfilteredAnswers;
                minFilteredAnswersReached = true;
            }
        } else {
            median.current = _median(_unfilteredAnswers);

            if (_maxDeviationP > 0) {
                filteredAnswers = _filterOutMarketAnswersOutsideMaxDeviationFromMedianP(
                    _unfilteredAnswers,
                    median.current,
                    _maxDeviationP
                );

                minFilteredAnswersReached = filteredAnswers.length >= _minAnswers;

                if (minFilteredAnswersReached) median.current = _median(filteredAnswers);
            } else {
                filteredAnswers = _unfilteredAnswers;
                minFilteredAnswersReached = true;
            }
        }
    }
}
