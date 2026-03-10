// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../../interfaces/IGNSMultiCollatDiamond.sol";

import "./IncreasePositionSizeUtils.sol";
import "./DecreasePositionSizeUtils.sol";

import "../ChainUtils.sol";
import "../ConstantsUtils.sol";
import "../TradingCommonUtils.sol";

/**
 *
 * @dev This is an external library for position size updates lifecycles
 * @dev Used by GNSTrading and GNSTradingCallbacks facets
 */
library UpdatePositionSizeLifecycles {
    /**
     * @dev Initiate increase position size order, done in 2 steps because position size changes
     * @param _input request increase position size input struct
     */
    function requestIncreasePositionSize(
        IUpdatePositionSizeUtils.IncreasePositionSizeInput memory _input,
        bool _isNative
    ) external {
        // 1. Base validation
        ITradingStorage.Trade memory trade = _baseValidateRequest(_input.user, _input.index);

        // 2. Increase position size validation
        uint256 positionSizeCollateralDelta = IncreasePositionSizeUtils.validateRequest(trade, _input);

        // 3. Transfer collateral delta from trader to diamond contract (nothing transferred for leverage update)
        // When `_isNative` is true, then payment has already been transferred in as native tokens and wrapped
        if (!_isNative)
            TradingCommonUtils.transferCollateralFrom(trade.collateralIndex, _input.user, _input.collateralDelta);

        // 4. Create pending order and make price aggregator request
        ITradingStorage.Id memory orderId = _initiateRequest(
            trade,
            true,
            _input.collateralDelta,
            _input.leverageDelta,
            positionSizeCollateralDelta,
            _input.expectedPrice,
            _input.maxSlippageP
        );

        emit IUpdatePositionSizeUtils.PositionSizeUpdateInitiated(
            orderId,
            trade.user,
            trade.pairIndex,
            trade.index,
            true,
            _input.collateralDelta,
            _input.leverageDelta
        );
    }

    /**
     * @dev Initiate decrease position size order, done in 2 steps because position size changes
     * @param _input request decrease position size input struct
     */
    function requestDecreasePositionSize(IUpdatePositionSizeUtils.DecreasePositionSizeInput memory _input) external {
        // 1. Base validation
        ITradingStorage.Trade memory trade = _baseValidateRequest(_input.user, _input.index);

        // 2. Decrease position size validation
        uint256 positionSizeCollateralDelta = DecreasePositionSizeUtils.validateRequest(trade, _input);

        // 3. Store pending order and make price aggregator request
        ITradingStorage.Id memory orderId = _initiateRequest(
            trade,
            false,
            _input.collateralDelta,
            _input.leverageDelta,
            positionSizeCollateralDelta,
            _input.expectedPrice,
            0
        );

        emit IUpdatePositionSizeUtils.PositionSizeUpdateInitiated(
            orderId,
            trade.user,
            trade.pairIndex,
            trade.index,
            false,
            _input.collateralDelta,
            _input.leverageDelta
        );
    }

    /**
     * @dev Execute increase position size market callback
     * @param _order corresponding pending order
     * @param _answer price aggregator answer
     */
    function executeIncreasePositionSizeMarket(
        ITradingStorage.PendingOrder memory _order,
        ITradingCallbacks.AggregatorAnswer memory _answer
    ) external {
        // 1. Prepare vars
        ITradingStorage.Trade memory partialTrade = _order.trade;
        ITradingStorage.Trade memory existingTrade = TradingCommonUtils.getTrade(partialTrade.user, partialTrade.index);
        IUpdatePositionSizeUtils.IncreasePositionSizeValues memory values;

        // 2. Refresh trader fee tier cache
        TradingCommonUtils.updateFeeTierPoints(
            existingTrade.collateralIndex,
            existingTrade.user,
            existingTrade.pairIndex,
            0
        );

        // 3. Base validation (trade open, market open)
        ITradingCallbacks.CancelReason cancelReason = _validateBaseFulfillment(existingTrade);

        // 4. If passes base validation, validate further
        if (cancelReason == ITradingCallbacks.CancelReason.NONE) {
            // 4.1 Prepare useful values (position size delta, pnl, fees, new open price, etc.)
            values = IncreasePositionSizeUtils.prepareCallbackValues(existingTrade, partialTrade, _answer);

            // 4.2 Further validation
            cancelReason = IncreasePositionSizeUtils.validateCallback(
                existingTrade,
                values,
                _answer,
                partialTrade.openPrice,
                _order.maxSlippageP
            );

            // 5. If passes further validation, execute callback
            if (cancelReason == ITradingCallbacks.CancelReason.NONE) {
                IncreasePositionSizeUtils.updateTradeSuccess(existingTrade, values, _answer);
                TradingCommonUtils.processFees(
                    existingTrade,
                    values.positionSizeCollateralDelta,
                    _order.orderType,
                    values.openingFeesCollateral
                );
            }
        }

        // 6. If didn't pass validation, charge gov fee (if trade exists) and return partial collateral (if any)
        if (cancelReason != ITradingCallbacks.CancelReason.NONE)
            IncreasePositionSizeUtils.handleCanceled(existingTrade, partialTrade, cancelReason, _answer, values);

        emit IUpdatePositionSizeUtils.PositionSizeIncreaseExecuted(
            _answer.orderId,
            cancelReason,
            existingTrade.collateralIndex,
            existingTrade.user,
            existingTrade.pairIndex,
            existingTrade.index,
            existingTrade.long,
            _answer.current,
            _getMultiCollatDiamond().getCollateralPriceUsd(existingTrade.collateralIndex),
            partialTrade.collateralAmount,
            partialTrade.leverage,
            values
        );
    }

    /**
     * @dev Execute decrease position size market callback
     * @param _order corresponding pending order
     * @param _answer price aggregator answer
     */
    function executeDecreasePositionSizeMarket(
        ITradingStorage.PendingOrder memory _order,
        ITradingCallbacks.AggregatorAnswer memory _answer
    ) external {
        // 1. Prepare vars
        ITradingStorage.Trade memory partialTrade = _order.trade;
        ITradingStorage.Trade memory existingTrade = TradingCommonUtils.getTrade(partialTrade.user, partialTrade.index);
        IUpdatePositionSizeUtils.DecreasePositionSizeValues memory values;

        // 2. Refresh trader fee tier cache
        TradingCommonUtils.updateFeeTierPoints(
            existingTrade.collateralIndex,
            existingTrade.user,
            existingTrade.pairIndex,
            0
        );

        // 3. Base validation (trade open, market open)
        ITradingCallbacks.CancelReason cancelReason = _validateBaseFulfillment(existingTrade);

        // 4. If passes base validation, validate further
        if (cancelReason == ITradingCallbacks.CancelReason.NONE) {
            // 4.1 Prepare useful values (position size delta, closing fees, borrowing fees, etc.)
            values = DecreasePositionSizeUtils.prepareCallbackValues(existingTrade, partialTrade, _answer);

            // 4.2 Further validation
            cancelReason = DecreasePositionSizeUtils.validateCallback(existingTrade, _order, values, _answer);

            // 5. If passes further validation, execute callback
            if (cancelReason == ITradingCallbacks.CancelReason.NONE) {
                DecreasePositionSizeUtils.updateTradeSuccess(existingTrade, partialTrade, values, _answer);
                TradingCommonUtils.processFees(
                    existingTrade,
                    values.positionSizeCollateralDelta,
                    _order.orderType,
                    values.closingFeeCollateral
                );
            }
        }

        // 6. If didn't pass validation and trade exists, charge gov fee and remove corresponding OI
        if (cancelReason != ITradingCallbacks.CancelReason.NONE)
            DecreasePositionSizeUtils.handleCanceled(existingTrade, cancelReason, _answer);

        emit IUpdatePositionSizeUtils.PositionSizeDecreaseExecuted(
            _answer.orderId,
            cancelReason,
            existingTrade.collateralIndex,
            existingTrade.user,
            existingTrade.pairIndex,
            existingTrade.index,
            existingTrade.long,
            _answer.current,
            _getMultiCollatDiamond().getCollateralPriceUsd(existingTrade.collateralIndex),
            partialTrade.collateralAmount,
            partialTrade.leverage,
            values
        );
    }

    /**
     * @dev Returns current address as multi-collateral diamond interface to call other facets functions.
     */
    function _getMultiCollatDiamond() internal view returns (IGNSMultiCollatDiamond) {
        return IGNSMultiCollatDiamond(address(this));
    }

    /**
     * @dev Basic validation for increase/decrease position size request
     * @param _trader trader address
     * @param _index trade index
     */
    function _baseValidateRequest(
        address _trader,
        uint32 _index
    ) internal view returns (ITradingStorage.Trade memory trade) {
        trade = TradingCommonUtils.getTrade(_trader, _index);

        // 1. Check trade exists
        if (!trade.isOpen) revert IGeneralErrors.DoesntExist();

        // 2. Revert if any market order (market close, increase leverage, partial open, partial close) already exists for trade
        TradingCommonUtils.revertIfTradeHasPendingMarketOrder(_trader, _index);

        // 3. Revert if collateral not active
        if (!_getMultiCollatDiamond().isCollateralActive(trade.collateralIndex))
            revert IGeneralErrors.InvalidCollateralIndex();
    }

    /**
     * @dev Creates pending order, makes price aggregator request, and returns corresponding pending order id
     * @param _trade trade to update
     * @param _isIncrease whether is increase or decrease position size order
     * @param _collateralAmount partial trade collateral amount (collateral precision)
     * @param _leverage partial trade leverage (1e3)
     * @param _positionSizeCollateralDelta position size delta in collateral tokens (collateral precision)
     * @param _expectedPrice reference price for max slippage check (1e10), only useful for increase position size
     * @param _maxSlippageP max slippage % (1e3), only useful for increase position size
     */
    function _initiateRequest(
        ITradingStorage.Trade memory _trade,
        bool _isIncrease,
        uint120 _collateralAmount,
        uint24 _leverage,
        uint256 _positionSizeCollateralDelta,
        uint64 _expectedPrice,
        uint16 _maxSlippageP
    ) internal returns (ITradingStorage.Id memory) {
        // 1. Initialize partial trade
        ITradingStorage.Trade memory pendingOrderTrade;
        pendingOrderTrade.user = _trade.user;
        pendingOrderTrade.index = _trade.index;
        pendingOrderTrade.collateralAmount = _collateralAmount;
        pendingOrderTrade.leverage = _leverage;
        pendingOrderTrade.openPrice = _expectedPrice; // useful for max slippage checks

        // 2. Store pending order
        ITradingStorage.PendingOrder memory pendingOrder;
        pendingOrder.trade = pendingOrderTrade;
        pendingOrder.user = _trade.user;
        pendingOrder.orderType = _isIncrease
            ? ITradingStorage.PendingOrderType.MARKET_PARTIAL_OPEN
            : ITradingStorage.PendingOrderType.MARKET_PARTIAL_CLOSE;
        pendingOrder.maxSlippageP = _maxSlippageP;

        // 3. Make price aggregator request
        return
            _getMultiCollatDiamond().getPrice(
                IPriceAggregator.GetPriceInput(
                    _trade.collateralIndex,
                    _trade.pairIndex,
                    pendingOrder,
                    _positionSizeCollateralDelta,
                    0,
                    _trade.isCounterTrade
                )
            );
    }

    /**
     * @dev Basic validation for callbacks, returns corresponding cancel reason
     * @param _trade trade struct
     */
    function _validateBaseFulfillment(
        ITradingStorage.Trade memory _trade
    ) internal pure returns (ITradingCallbacks.CancelReason) {
        return !_trade.isOpen ? ITradingCallbacks.CancelReason.NO_TRADE : ITradingCallbacks.CancelReason.NONE;
    }
}
