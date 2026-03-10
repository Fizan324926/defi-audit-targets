// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../interfaces/IGNSMultiCollatDiamond.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/IWETH9.sol";

import "./StorageUtils.sol";
import "./PackingUtils.sol";
import "./ChainUtils.sol";
import "./ConstantsUtils.sol";

import "./updateLeverage/UpdateLeverageLifecycles.sol";
import "./updatePositionSize/UpdatePositionSizeLifecycles.sol";

/**
 * @dev GNSTradingInteractions facet external library
 */

library TradingInteractionsUtils {
    using PackingUtils for uint256;
    using SafeERC20 for IERC20;

    uint256 private constant MIN_MARKET_TIMEOUT_SECONDS = 1 minutes;
    uint256 private constant MAX_MARKET_TIMEOUT_SECONDS = 5 minutes;
    uint256 private constant FIXED_LINK_PER_TRIGGER = 1e18;

    /**
     * @dev Modifier to only allow trading action when trading is activated (= revert if not activated)
     */
    modifier tradingActivated() {
        _tradingActivated();
        _;
    }

    /**
     * @dev Modifier to only allow trading action when trading is activated or close only (= revert if paused)
     */
    modifier tradingActivatedOrCloseOnly() {
        _tradingActivatedOrCloseOnly();
        _;
    }

    /**
     * @dev Modifier to prevent calling function from delegated action
     */
    modifier notDelegatedAction() {
        _notDelegatedAction();
        _;
    }

    /**
     * @dev Validates, temporarly stores, and cleans up signed market pair prices.
     */
    modifier useSignedLookbackPrices(IPriceAggregator.SignedPairPrices[] calldata _signedPairPrices) {
        bool isLookback = true;
        _getMultiCollatDiamond().validateSignedPairPrices(_signedPairPrices, isLookback);
        _;
        _getMultiCollatDiamond().cleanUpSignedPairPrices();
    }

    /**
     * @dev Check ITradingInteractionsUtils interface for documentation
     */
    function initializeTrading(uint16 _marketOrdersTimeoutBlocks, address[] memory _usersByPassTriggerLink) external {
        updateMarketOrdersTimeoutBlocks(_marketOrdersTimeoutBlocks);

        bool[] memory shouldByPass = new bool[](_usersByPassTriggerLink.length);
        for (uint256 i = 0; i < _usersByPassTriggerLink.length; i++) {
            shouldByPass[i] = true;
        }
        updateByPassTriggerLink(_usersByPassTriggerLink, shouldByPass);
    }

    /**
     * @dev Check ITradingInteractionsUtils interface for documentation
     */
    function updateMarketOrdersTimeoutBlocks(uint16 _valueBlocks) public {
        if (_valueBlocks == 0) revert IGeneralErrors.ZeroValue();

        uint256 timeoutSeconds = ChainUtils.convertBlocksToSeconds(uint256(_valueBlocks));

        if (timeoutSeconds < MIN_MARKET_TIMEOUT_SECONDS) revert IGeneralErrors.BelowMin();
        if (timeoutSeconds > MAX_MARKET_TIMEOUT_SECONDS) revert IGeneralErrors.AboveMax();

        _getStorage().marketOrdersTimeoutBlocks = _valueBlocks;

        emit ITradingInteractionsUtils.MarketOrdersTimeoutBlocksUpdated(_valueBlocks);
    }

    /**
     * @dev Check ITradingInteractionsUtils interface for documentation
     */
    function updateByPassTriggerLink(address[] memory _users, bool[] memory _shouldByPass) public {
        ITradingInteractions.TradingInteractionsStorage storage s = _getStorage();

        if (_users.length != _shouldByPass.length) revert IGeneralErrors.WrongLength();

        for (uint256 i = 0; i < _users.length; i++) {
            address user = _users[i];
            bool value = _shouldByPass[i];

            s.byPassTriggerLink[user] = value;

            emit ITradingInteractionsUtils.ByPassTriggerLinkUpdated(user, value);
        }
    }

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function initiateManualNegativePnlRealization(
        address _trader,
        uint32 _index,
        bool _isHoldingFeesRealization
    ) external tradingActivatedOrCloseOnly {
        ITradingStorage.Trade memory trade = TradingCommonUtils.getTrade(_trader, _index);
        if (!trade.isOpen) revert ITradingInteractionsUtils.NoTrade();
        if (trade.tradeType != ITradingStorage.TradeType.TRADE) revert IGeneralErrors.WrongTradeType();

        ITradingStorage.PendingOrder memory pendingOrder;
        pendingOrder.trade.user = trade.user;
        pendingOrder.trade.index = trade.index;
        pendingOrder.user = msg.sender;
        pendingOrder.orderType = _isHoldingFeesRealization
            ? ITradingStorage.PendingOrderType.MANUAL_HOLDING_FEES_REALIZATION
            : ITradingStorage.PendingOrderType.MANUAL_NEGATIVE_PNL_REALIZATION;

        ITradingStorage.Id memory orderId = _getMultiCollatDiamond().getPrice(
            IPriceAggregator.GetPriceInput(
                trade.collateralIndex,
                trade.pairIndex,
                pendingOrder,
                0, /// no LINK fee
                ChainUtils.getBlockNumber(),
                false
            )
        );

        emit ITradingInteractionsUtils.ManualNegativePnlRealizationInitiated(
            orderId,
            _trader,
            _index,
            _isHoldingFeesRealization
        );
    }

    /**
     * @dev Check ITradingInteractionsUtils interface for documentation
     */
    function setTradingDelegate(address _delegate) external {
        if (_delegate == address(0)) revert IGeneralErrors.ZeroAddress();
        _getStorage().delegations[msg.sender] = _delegate;
    }

    /**
     * @dev Check ITradingInteractionsUtils interface for documentation
     */
    function removeTradingDelegate() external {
        delete _getStorage().delegations[msg.sender];
    }

    /**
     * @dev Check ITradingInteractionsUtils interface for documentation
     */
    function delegatedTradingAction(
        address _trader,
        bytes calldata _callData
    ) external notDelegatedAction returns (bytes memory) {
        ITradingInteractions.TradingInteractionsStorage storage s = _getStorage();

        if (s.delegations[_trader] != msg.sender) revert ITradingInteractionsUtils.DelegateNotApproved();

        s.senderOverride = _trader;
        (bool success, bytes memory result) = address(this).delegatecall(_callData);

        if (!success) {
            if (result.length < 4) revert(); // not a custom error (4 byte signature) or require() message

            assembly {
                let len := mload(result)
                revert(add(result, 0x20), len)
            }
        }

        s.senderOverride = address(0);

        return result;
    }

    /**
     * @dev Check ITradingInteractionsUtils interface for documentation
     */
    function openTrade(
        ITradingStorage.Trade memory _trade,
        uint16 _maxSlippageP,
        address _referrer
    ) external tradingActivated {
        _openTrade(_trade, _maxSlippageP, _referrer, false);
    }

    /**
     * @dev Check ITradingInteractionsUtils interface for documentation
     */
    function openTradeNative(
        ITradingStorage.Trade memory _trade,
        uint16 _maxSlippageP,
        address _referrer
    ) external tradingActivated notDelegatedAction {
        _trade.collateralAmount = _wrapNativeToken(_trade.collateralIndex);

        _openTrade(_trade, _maxSlippageP, _referrer, true);
    }

    /**
     * @dev Check ITradingInteractionsUtils interface for documentation
     */
    function updateMaxClosingSlippageP(
        uint32 _index,
        uint16 _maxClosingSlippageP
    ) external tradingActivatedOrCloseOnly {
        ITradingStorage.Id memory tradeId = ITradingStorage.Id(_msgSender(), _index);

        _checkNoPendingTrigger(tradeId, ITradingStorage.PendingOrderType.TP_CLOSE);
        _checkNoPendingTrigger(tradeId, ITradingStorage.PendingOrderType.SL_CLOSE);

        _getMultiCollatDiamond().updateTradeMaxClosingSlippageP(tradeId, _maxClosingSlippageP);
    }

    /**
     * @dev Check ITradingInteractionsUtils interface for documentation
     */
    function closeTradeMarket(uint32 _index, uint64 _expectedPrice) external tradingActivatedOrCloseOnly {
        if (_expectedPrice == 0) revert IGeneralErrors.ZeroValue();

        address sender = _msgSender();
        TradingCommonUtils.revertIfTradeHasPendingMarketOrder(sender, _index);

        ITradingStorage.Trade memory t = TradingCommonUtils.getTrade(sender, _index);
        ITradingStorage.PendingOrder memory pendingOrder;
        pendingOrder.trade.user = t.user;
        pendingOrder.trade.index = t.index;
        pendingOrder.trade.pairIndex = t.pairIndex;
        pendingOrder.trade.openPrice = _expectedPrice;
        pendingOrder.user = sender;
        pendingOrder.orderType = ITradingStorage.PendingOrderType.MARKET_CLOSE;

        ITradingStorage.Id memory orderId = _getMultiCollatDiamond().getPrice(
            IPriceAggregator.GetPriceInput(
                t.collateralIndex,
                t.pairIndex,
                pendingOrder,
                TradingCommonUtils.getPositionSizeCollateral(t.collateralAmount, t.leverage),
                ChainUtils.getBlockNumber(),
                t.isCounterTrade
            )
        );

        emit ITradingInteractionsUtils.MarketOrderInitiated(orderId, sender, t.pairIndex, false);
    }

    /**
     * @dev Check ITradingInteractionsUtils interface for documentation
     */
    function updateOpenOrder(
        uint32 _index,
        uint64 _openPrice,
        uint64 _tp,
        uint64 _sl,
        uint16 _maxSlippageP
    ) external tradingActivated {
        address sender = _msgSender();
        ITradingStorage.Trade memory o = TradingCommonUtils.getTrade(sender, _index);

        _checkNoPendingTrigger(
            ITradingStorage.Id({user: o.user, index: o.index}),
            ConstantsUtils.getPendingOpenOrderType(o.tradeType)
        );

        _getMultiCollatDiamond().updateOpenOrderDetails(
            ITradingStorage.Id({user: o.user, index: o.index}),
            _openPrice,
            _tp,
            _sl,
            _maxSlippageP
        );

        emit ITradingInteractionsUtils.OpenLimitUpdated(
            sender,
            o.pairIndex,
            _index,
            _openPrice,
            _tp,
            _sl,
            _maxSlippageP
        );
    }

    /**
     * @dev Check ITradingInteractionsUtils interface for documentation
     */
    function cancelOpenOrder(uint32 _index) external tradingActivatedOrCloseOnly {
        address sender = _msgSender();
        ITradingStorage.Trade memory o = TradingCommonUtils.getTrade(sender, _index);
        ITradingStorage.Id memory tradeId = ITradingStorage.Id({user: o.user, index: o.index});

        if (o.tradeType == ITradingStorage.TradeType.TRADE) revert IGeneralErrors.WrongTradeType();

        _checkNoPendingTrigger(tradeId, ConstantsUtils.getPendingOpenOrderType(o.tradeType));

        _getMultiCollatDiamond().closeTrade(tradeId, false, 0);

        TradingCommonUtils.transferCollateralTo(o.collateralIndex, sender, o.collateralAmount);

        emit ITradingInteractionsUtils.OpenLimitCanceled(sender, o.pairIndex, _index);
    }

    /**
     * @dev Check ITradingInteractionsUtils interface for documentation
     */
    function updateTp(uint32 _index, uint64 _newTp) external tradingActivated {
        address sender = _msgSender();

        ITradingStorage.Trade memory t = TradingCommonUtils.getTrade(sender, _index);
        ITradingStorage.Id memory tradeId = ITradingStorage.Id({user: t.user, index: t.index});

        _checkNoPendingTrigger(tradeId, ITradingStorage.PendingOrderType.TP_CLOSE);

        _getMultiCollatDiamond().updateTradeTp(tradeId, _newTp);
    }

    /**
     * @dev Check ITradingInteractionsUtils interface for documentation
     */
    function updateSl(uint32 _index, uint64 _newSl) external tradingActivated {
        address sender = _msgSender();

        ITradingStorage.Trade memory t = TradingCommonUtils.getTrade(sender, _index);
        ITradingStorage.Id memory tradeId = ITradingStorage.Id({user: t.user, index: t.index});

        _checkNoPendingTrigger(tradeId, ITradingStorage.PendingOrderType.SL_CLOSE);

        _getMultiCollatDiamond().updateTradeSl(tradeId, _newSl);
    }

    /**
     * @dev Check ITradingInteractionsUtils interface for documentation
     */
    function updateLeverage(uint32 _index, uint24 _newLeverage) external tradingActivated {
        _updateLeverage(_index, _newLeverage, false, 0);
    }

    /**
     * @dev Check ITradingInteractionsUtils interface for documentation
     */
    function updateLeverageNative(uint32 _index, uint24 _newLeverage) external tradingActivated notDelegatedAction {
        // If msg.value is 0, process as non-native.
        if (msg.value == 0) {
            _updateLeverage(_index, _newLeverage, false, 0);
            return;
        }

        // Track native balance available and ensure collateralIndex is a valid native token
        uint8 collateralIndex = TradingCommonUtils.getTrade(_msgSender(), _index).collateralIndex;
        uint120 nativeBalance = _wrapNativeToken(collateralIndex);

        // Perform updateLeverage request
        uint120 unusedBalance = _updateLeverage(_index, _newLeverage, true, nativeBalance);

        // Return any remaining balance to the sender
        TradingCommonUtils.transferCollateralTo(collateralIndex, _msgSender(), unusedBalance);
    }

    /**
     * @dev Check ITradingInteractionsUtils interface for documentation
     */
    function increasePositionSize(
        uint32 _index,
        uint120 _collateralDelta,
        uint24 _leverageDelta,
        uint64 _expectedPrice,
        uint16 _maxSlippageP
    ) external tradingActivated {
        _increasePositionSize(_index, _collateralDelta, _leverageDelta, _expectedPrice, _maxSlippageP, false);
    }

    /**
     * @dev Check ITradingInteractionsUtils interface for documentation
     */
    function increasePositionSizeNative(
        uint32 _index,
        uint120 _collateralDelta,
        uint24 _leverageDelta,
        uint64 _expectedPrice,
        uint16 _maxSlippageP
    ) external tradingActivated notDelegatedAction {
        // If msg.value is zero then redirect the call to the non-native version of this function
        if (msg.value == 0) {
            return
                _increasePositionSize(_index, _collateralDelta, _leverageDelta, _expectedPrice, _maxSlippageP, false);
        }

        // Ensure `_collateralDelta` matches msg.value and that collateralIndex is a valid native token
        _collateralDelta = _wrapNativeToken(TradingCommonUtils.getTrade(_msgSender(), _index).collateralIndex);

        // Process position size increase request
        _increasePositionSize(_index, _collateralDelta, _leverageDelta, _expectedPrice, _maxSlippageP, true);
    }

    /**
     * @dev Check ITradingInteractionsUtils interface for documentation
     */
    function decreasePositionSize(
        uint32 _index,
        uint120 _collateralDelta,
        uint24 _leverageDelta,
        uint64 _expectedPrice
    ) external tradingActivatedOrCloseOnly {
        UpdatePositionSizeLifecycles.requestDecreasePositionSize(
            IUpdatePositionSize.DecreasePositionSizeInput(
                _msgSender(),
                _index,
                _collateralDelta,
                _leverageDelta,
                _expectedPrice
            )
        );
    }

    /**
     * @dev Check ITradingInteractionsUtils interface for documentation
     */
    function withdrawPositivePnl(uint32 _index, uint120 _amountCollateral) external tradingActivatedOrCloseOnly {
        if (_amountCollateral == 0) revert IGeneralErrors.ZeroValue();

        address sender = _msgSender();
        TradingCommonUtils.revertIfTradeHasPendingMarketOrder(sender, _index);

        ITradingStorage.Trade memory t = TradingCommonUtils.getTrade(sender, _index);
        if (!t.isOpen) revert ITradingInteractionsUtils.NoTrade();
        if (t.tradeType != ITradingStorage.TradeType.TRADE) revert IGeneralErrors.WrongTradeType();

        ITradingStorage.PendingOrder memory pendingOrder;
        pendingOrder.trade.user = t.user;
        pendingOrder.trade.index = t.index;
        pendingOrder.trade.collateralAmount = _amountCollateral;
        pendingOrder.user = sender;
        pendingOrder.orderType = ITradingStorage.PendingOrderType.PNL_WITHDRAWAL;

        ITradingStorage.Id memory orderId = _getMultiCollatDiamond().getPrice(
            IPriceAggregator.GetPriceInput(
                t.collateralIndex,
                t.pairIndex,
                pendingOrder,
                TradingCommonUtils.getMinPositionSizeCollateral(t.collateralIndex, t.pairIndex) / 2,
                ChainUtils.getBlockNumber(),
                t.isCounterTrade
            )
        );

        emit ITradingInteractionsUtils.PositivePnlWithdrawalInitiated(orderId, sender, _index, _amountCollateral);
    }

    /**
     * @dev Check ITradingInteractionsUtils interface for documentation
     */
    function triggerOrder(uint256 _packed) external notDelegatedAction {
        (
            address sender,
            bool byPassesLinkCost,
            ITradingStorage.Trade memory t,
            ITradingStorage.PendingOrderType orderType
        ) = _validateTriggerOrder(_packed);

        if (!byPassesLinkCost) {
            IERC20(_getMultiCollatDiamond().getChainlinkToken()).safeTransferFrom(
                sender,
                address(this),
                FIXED_LINK_PER_TRIGGER
            );
        }

        ITradingStorage.PendingOrder memory pendingOrder;
        pendingOrder.trade.user = t.user;
        pendingOrder.trade.index = t.index;
        pendingOrder.trade.pairIndex = t.pairIndex;
        pendingOrder.user = sender;
        pendingOrder.orderType = orderType;

        ITradingStorage.Id memory orderId = _getPriceTriggerOrder(t, pendingOrder);

        emit ITradingInteractionsUtils.TriggerOrderInitiated(orderId, t.user, t.pairIndex, byPassesLinkCost);
    }

    /**
     * @dev Check ITradingInteractionsUtils interface for documentation
     */
    function triggerOrderWithSignatures(
        uint256 _packed,
        IPriceAggregator.SignedPairPrices[] calldata _signedPairPrices
    ) external notDelegatedAction {
        (
            address sender,
            bool byPassesLinkCost,
            ITradingStorage.Trade memory t,
            ITradingStorage.PendingOrderType orderType
        ) = _validateTriggerOrder(_packed);

        if (!byPassesLinkCost) revert IGeneralErrors.NotAuthorized();

        // Execute trigger. Signature validation is done in this function's modifier
        _executeTriggerOrderWithSignature(sender, t, orderType, _signedPairPrices);
    }

    function _executeTriggerOrderWithSignature(
        address _sender,
        ITradingStorage.Trade memory _t,
        ITradingStorage.PendingOrderType _orderType,
        IPriceAggregator.SignedPairPrices[] calldata _signedPairPrices
    ) internal useSignedLookbackPrices(_signedPairPrices) {
        ITradingCallbacks.AggregatorAnswer memory finalAnswer = _getMultiCollatDiamond().getPairSignedMedianTemporary(
            _t.pairIndex
        );

        if (
            _signedPairPrices[0].fromBlock !=
            _getMultiCollatDiamond().getLookbackFromBlock(_t.user, _t.index, _orderType)
        ) revert ITradingInteractionsUtils.WrongFromBlock();

        if (
            _orderType == ITradingStorage.PendingOrderType.LIMIT_OPEN ||
            _orderType == ITradingStorage.PendingOrderType.STOP_OPEN
        ) {
            _getMultiCollatDiamond().executeTriggerOpenOrderCallbackDirect(finalAnswer, _t, _orderType, _sender);
        } else if (
            _orderType == ITradingStorage.PendingOrderType.TP_CLOSE ||
            _orderType == ITradingStorage.PendingOrderType.SL_CLOSE ||
            _orderType == ITradingStorage.PendingOrderType.LIQ_CLOSE
        ) {
            _getMultiCollatDiamond().executeTriggerCloseOrderCallbackDirect(finalAnswer, _t, _orderType, _sender);
        }
    }
    /**
     * @dev Check ITradingInteractionsUtils interface for documentation
     */
    function cancelOrderAfterTimeout(uint32 _orderIndex) external tradingActivatedOrCloseOnly {
        address sender = _msgSender();

        ITradingStorage.Id memory orderId = ITradingStorage.Id({user: sender, index: _orderIndex});
        ITradingStorage.PendingOrder memory order = _getMultiCollatDiamond().getPendingOrder(orderId);
        ITradingStorage.Trade memory pendingTrade = order.trade;
        ITradingStorage.Trade memory trade = TradingCommonUtils.getTrade(pendingTrade.user, pendingTrade.index);

        if (!order.isOpen) revert ITradingInteractionsUtils.NoOrder();

        if (!ConstantsUtils.isOrderTypeMarket(order.orderType)) revert IGeneralErrors.WrongOrderType();

        if (ChainUtils.getBlockNumber() < order.createdBlock + _getStorage().marketOrdersTimeoutBlocks)
            revert ITradingInteractionsUtils.WaitTimeout();

        _getMultiCollatDiamond().closePendingOrder(orderId);

        bool isMarketOpen = order.orderType == ITradingStorage.PendingOrderType.MARKET_OPEN;

        if (
            isMarketOpen ||
            (order.orderType == ITradingStorage.PendingOrderType.UPDATE_LEVERAGE &&
                pendingTrade.leverage < trade.leverage) ||
            order.orderType == ITradingStorage.PendingOrderType.MARKET_PARTIAL_OPEN
        ) {
            uint8 collateralIndex = isMarketOpen ? pendingTrade.collateralIndex : trade.collateralIndex;

            TradingCommonUtils.transferCollateralTo(collateralIndex, pendingTrade.user, pendingTrade.collateralAmount);

            emit ITradingInteractionsUtils.CollateralReturnedAfterTimeout(
                orderId,
                collateralIndex,
                pendingTrade.user,
                pendingTrade.collateralAmount
            );
        }

        emit ITradingInteractionsUtils.ChainlinkCallbackTimeout(
            orderId,
            isMarketOpen ? pendingTrade.pairIndex : trade.pairIndex
        );
    }

    /**
     * @dev Check ITradingInteractionsUtils interface for documentation
     */
    function getWrappedNativeToken() internal view returns (address) {
        return ChainUtils.getWrappedNativeToken();
    }

    /**
     * @dev Check ITradingInteractionsUtils interface for documentation
     */
    function isWrappedNativeToken(address _token) external view returns (bool) {
        return ChainUtils.isWrappedNativeToken(_token);
    }

    /**
     * @dev Check ITradingInteractionsUtils interface for documentation
     */
    function getTradingDelegate(address _trader) external view returns (address) {
        return _getStorage().delegations[_trader];
    }

    /**
     * @dev Check ITradingInteractionsUtils interface for documentation
     */
    function getMarketOrdersTimeoutBlocks() external view returns (uint16) {
        return _getStorage().marketOrdersTimeoutBlocks;
    }

    /**
     * @dev Check ITradingInteractionsUtils interface for documentation
     */
    function getByPassTriggerLink(address _user) external view returns (bool) {
        return _getStorage().byPassTriggerLink[_user];
    }

    /**
     * @dev Returns storage slot to use when fetching storage relevant to library
     */
    function _getSlot() internal pure returns (uint256) {
        return StorageUtils.GLOBAL_TRADING_SLOT;
    }

    /**
     * @dev Returns storage pointer for storage struct in diamond contract, at defined slot
     */
    function _getStorage() internal pure returns (ITradingInteractions.TradingInteractionsStorage storage s) {
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
     * @dev Internal function for openTrade and openTradeNative
     * @param _trade trade data
     * @param _maxSlippageP max slippage percentage (1e3 precision)
     * @param _referrer referrer address
     * @param _isNative if true we skip the collateral transfer from user to contract
     */
    function _openTrade(
        ITradingStorage.Trade memory _trade,
        uint16 _maxSlippageP,
        address _referrer,
        bool _isNative
    ) internal {
        address sender = _msgSender();
        _trade.user = sender;
        _trade.index = 0; // this will be defined once trade is stored
        _trade.positionSizeToken = 0; // will be overriden in callback
        _trade.__placeholder = 0;

        uint256 positionSizeCollateral = TradingCommonUtils.getPositionSizeCollateral(
            _trade.collateralAmount,
            _trade.leverage
        );

        // Trade collateral needs to be >= 5x min trading fee
        if (
            _trade.collateralAmount <
            TradingCommonUtils.getPairMinOpeningCollateral(_trade.collateralIndex, _trade.pairIndex)
        ) revert ITradingInteractionsUtils.InsufficientCollateral();

        if (
            _trade.leverage < _getMultiCollatDiamond().pairMinLeverage(_trade.pairIndex) ||
            _trade.leverage > _getMultiCollatDiamond().pairMaxLeverage(_trade.pairIndex)
        ) revert ITradingInteractionsUtils.WrongLeverage();

        if (
            (_trade.isCounterTrade &&
                _trade.leverage > _getMultiCollatDiamond().getPairCounterTradeMaxLeverage(_trade.pairIndex))
        ) revert IGeneralErrors.WrongTradeType();

        ITradingCommonUtils.TradePriceImpact memory priceImpact = TradingCommonUtils.getTradeOpeningPriceImpact(
            ITradingCommonUtils.TradePriceImpactInput(_trade, _trade.openPrice, positionSizeCollateral, 0, true)
        );

        if (
            TradingCommonUtils.getNegativePnlFromOpeningPriceImpactP(
                priceImpact.fixedSpreadP,
                priceImpact.cumulVolPriceImpactP,
                _trade.leverage,
                _trade.long
            ) > int256(ConstantsUtils.MAX_OPEN_NEGATIVE_PNL_P)
        ) revert ITradingInteractionsUtils.PriceImpactTooHigh();

        if (!_isNative)
            TradingCommonUtils.transferCollateralFrom(_trade.collateralIndex, sender, _trade.collateralAmount);

        if (_trade.tradeType != ITradingStorage.TradeType.TRADE) {
            ITradingStorage.TradeInfo memory tradeInfo;
            tradeInfo.maxSlippageP = _maxSlippageP;

            _trade = _getMultiCollatDiamond().storeTrade(_trade, tradeInfo, 0);

            emit ITradingInteractionsUtils.OpenOrderPlaced(sender, _trade.pairIndex, _trade.index);
        } else {
            ITradingStorage.PendingOrder memory pendingOrder;
            pendingOrder.trade = _trade;
            pendingOrder.user = sender;
            pendingOrder.orderType = ITradingStorage.PendingOrderType.MARKET_OPEN;
            pendingOrder.maxSlippageP = _maxSlippageP;

            ITradingStorage.Id memory orderId = _getMultiCollatDiamond().getPrice(
                IPriceAggregator.GetPriceInput(
                    _trade.collateralIndex,
                    _trade.pairIndex,
                    pendingOrder,
                    positionSizeCollateral,
                    ChainUtils.getBlockNumber(),
                    _trade.isCounterTrade
                )
            );

            emit ITradingInteractionsUtils.MarketOrderInitiated(orderId, sender, _trade.pairIndex, true);
        }

        if (_referrer != address(0)) {
            _getMultiCollatDiamond().registerPotentialReferrer(sender, _referrer);
        }
    }

    /**
     * @dev Internal function for updateLeverage and updateLeverageNative
     * @param _index index of trade
     * @param _newLeverage new leverage (1e3)
     * @param _isNative whether the collateral transfer is with native tokens
     * @param _nativeValue how much native collateral is available
     */
    function _updateLeverage(
        uint32 _index,
        uint24 _newLeverage,
        bool _isNative,
        uint120 _nativeValue
    ) internal returns (uint120) {
        return
            UpdateLeverageLifecycles.requestUpdateLeverage(
                IUpdateLeverage.UpdateLeverageInput(_msgSender(), _index, _newLeverage),
                _isNative,
                _nativeValue
            );
    }

    /**
     * @dev Internal function for increasePositionSize and increasePositionSizeNative
     * @param _index index of trade
     * @param _collateralDelta collateral to add (collateral precision)
     * @param _leverageDelta partial trade leverage (1e3)
     * @param _expectedPrice expected price of execution (1e10 precision)
     * @param _maxSlippageP max slippage % (1e3)
     * @param _isNative whether the collateral transfer is native
     */
    function _increasePositionSize(
        uint32 _index,
        uint120 _collateralDelta,
        uint24 _leverageDelta,
        uint64 _expectedPrice,
        uint16 _maxSlippageP,
        bool _isNative
    ) internal {
        UpdatePositionSizeLifecycles.requestIncreasePositionSize(
            IUpdatePositionSize.IncreasePositionSizeInput(
                _msgSender(),
                _index,
                _collateralDelta,
                _leverageDelta,
                _expectedPrice,
                _maxSlippageP
            ),
            _isNative
        );
    }

    /**
     * @dev Revert if there is an active pending order for the trade
     * @param _tradeId trade id
     * @param _orderType order type
     */
    function _checkNoPendingTrigger(
        ITradingStorage.Id memory _tradeId,
        ITradingStorage.PendingOrderType _orderType
    ) internal view {
        if (
            _getMultiCollatDiamond().hasActiveOrder(
                _getMultiCollatDiamond().getTradePendingOrderBlock(_tradeId, _orderType)
            )
        ) revert ITradingInteractionsUtils.PendingTrigger();
    }

    /**
     * @dev Validates trigger order
     * @param _packed packed trigger order data
     */
    function _validateTriggerOrder(
        uint256 _packed
    )
        internal
        view
        returns (
            address sender,
            bool byPassesLinkCost,
            ITradingStorage.Trade memory t,
            ITradingStorage.PendingOrderType orderType
        )
    {
        (uint8 _orderType, address _trader, uint32 _index) = _packed.unpackTriggerOrder();

        orderType = ITradingStorage.PendingOrderType(_orderType);

        if (ConstantsUtils.isOrderTypeMarket(orderType)) revert IGeneralErrors.WrongOrderType();

        bool isOpenLimit = orderType == ITradingStorage.PendingOrderType.LIMIT_OPEN ||
            orderType == ITradingStorage.PendingOrderType.STOP_OPEN;

        ITradingStorage.TradingActivated activated = _getMultiCollatDiamond().getTradingActivated();
        if (
            (isOpenLimit && activated != ITradingStorage.TradingActivated.ACTIVATED) ||
            (!isOpenLimit && activated == ITradingStorage.TradingActivated.PAUSED)
        ) {
            revert IGeneralErrors.Paused();
        }

        t = TradingCommonUtils.getTrade(_trader, _index);
        if (!t.isOpen) revert ITradingInteractionsUtils.NoTrade();

        _checkNoPendingTrigger(ITradingStorage.Id({user: t.user, index: t.index}), orderType);

        sender = msg.sender; // can't be a delegated action anyway
        byPassesLinkCost = _getStorage().byPassTriggerLink[sender];

        uint256 positionSizeCollateral = TradingCommonUtils.getPositionSizeCollateral(t.collateralAmount, t.leverage);

        if (isOpenLimit) {
            ITradingCommonUtils.TradePriceImpact memory priceImpact = TradingCommonUtils.getTradeOpeningPriceImpact(
                ITradingCommonUtils.TradePriceImpactInput(t, t.openPrice, positionSizeCollateral, 0, true)
            );

            if (
                TradingCommonUtils.getNegativePnlFromOpeningPriceImpactP(
                    priceImpact.fixedSpreadP,
                    priceImpact.cumulVolPriceImpactP,
                    t.leverage,
                    t.long
                ) > int256(ConstantsUtils.MAX_OPEN_NEGATIVE_PNL_P)
            ) revert ITradingInteractionsUtils.PriceImpactTooHigh();
        }

        _getMultiCollatDiamond().validateOpenTradeOrder(t, orderType);
    }

    /**
     * @dev Initiate price aggregator request for trigger order
     * @param _trade trade
     * @param _pendingOrder pending order to store
     */
    function _getPriceTriggerOrder(
        ITradingStorage.Trade memory _trade,
        ITradingStorage.PendingOrder memory _pendingOrder
    ) internal returns (ITradingStorage.Id memory) {
        return
            _getMultiCollatDiamond().getPrice(
                IPriceAggregator.GetPriceInput(
                    _trade.collateralIndex,
                    _trade.pairIndex,
                    _pendingOrder,
                    0,
                    _getMultiCollatDiamond().getLookbackFromBlock(_trade.user, _trade.index, _pendingOrder.orderType),
                    _trade.isCounterTrade
                )
            );
    }

    /**
     * @dev Receives native token and sends back wrapped token to user
     * @param _collateralIndex index of the collateral
     */
    function _wrapNativeToken(uint8 _collateralIndex) internal returns (uint120) {
        address collateral = _getMultiCollatDiamond().getCollateral(_collateralIndex).collateral;
        uint256 nativeValue = msg.value;

        if (nativeValue == 0) {
            revert IGeneralErrors.ZeroValue();
        }

        if (nativeValue > type(uint120).max) {
            revert IGeneralErrors.Overflow();
        }

        if (!ChainUtils.isWrappedNativeToken(collateral)) {
            revert ITradingInteractionsUtils.NotWrappedNativeToken();
        }

        IWETH9(collateral).deposit{value: nativeValue}();

        emit ITradingInteractionsUtils.NativeTokenWrapped(msg.sender, nativeValue);

        return uint120(nativeValue);
    }

    /**
     * @dev Returns the caller of the transaction (overriden by trader address if delegatedAction is called)
     */
    function _msgSender() internal view returns (address) {
        address senderOverride = _getStorage().senderOverride;
        if (senderOverride == address(0)) {
            return msg.sender;
        } else {
            return senderOverride;
        }
    }

    /**
     * @dev Modifier helper for `tradingActivated()`. Saves bytecode size.
     */
    function _tradingActivated() internal view {
        if (_getMultiCollatDiamond().getTradingActivated() != ITradingStorage.TradingActivated.ACTIVATED)
            revert IGeneralErrors.Paused();
    }

    /**
     * @dev Modifier helper for `tradingActivatedOrCloseOnly()`. Saves bytecode size.
     */
    function _tradingActivatedOrCloseOnly() internal view {
        if (_getMultiCollatDiamond().getTradingActivated() == ITradingStorage.TradingActivated.PAUSED)
            revert IGeneralErrors.Paused();
    }

    /**
     * @dev Modifier helper for `notDelegatedAction()`. Saves bytecode size.
     */
    function _notDelegatedAction() internal view {
        if (_getStorage().senderOverride != address(0)) revert ITradingInteractionsUtils.DelegatedActionNotAllowed();
    }
}
