// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../../interfaces/IGNSMultiCollatDiamond.sol";

import "../TradingCommonUtils.sol";

/**
 *
 * @dev This is an external library for leverage update lifecycles
 * @dev Used by GNSTrading and GNSTradingCallbacks facets
 */
library UpdateLeverageLifecycles {
    /**
     * @dev Initiate update leverage order, done in 2 steps because need to cancel if liquidation price reached
     * @param _input request decrease leverage input
     * @param _isNative whether this request is using native tokens
     * @param _nativeBalance amount of native tokens available. Always 0 when `_isNative` is false, and >0 when true.
     */
    function requestUpdateLeverage(
        IUpdateLeverageUtils.UpdateLeverageInput memory _input,
        bool _isNative,
        uint120 _nativeBalance
    ) external returns (uint120) {
        // 1. Request validation
        (ITradingStorage.Trade memory trade, bool isIncrease, uint256 collateralDelta) = _validateRequest(_input);

        // 2. If decrease leverage, transfer collateral delta to diamond
        if (!isIncrease) {
            // If it's native, we have already transferred the balance
            if (_isNative) {
                // If the request uses more balance (`collateralDelta`) than is available (`_nativeBalance`) then revert
                if (collateralDelta > _nativeBalance) revert ITradingInteractionsUtils.InsufficientCollateral();

                // Deduct `collateralDelta` from native collateral
                _nativeBalance -= uint120(collateralDelta);
            } else {
                // Transfer in collateral
                TradingCommonUtils.transferCollateralFrom(trade.collateralIndex, trade.user, collateralDelta);
            }
        }

        // 3. Create pending order and make price aggregator request
        ITradingStorage.Id memory orderId = _initiateRequest(trade, _input.newLeverage, collateralDelta);

        emit IUpdateLeverageUtils.LeverageUpdateInitiated(
            orderId,
            _input.user,
            trade.pairIndex,
            _input.index,
            isIncrease,
            _input.newLeverage
        );

        // Return the amount of native collateral remaining
        return _nativeBalance;
    }

    /**
     * @dev Execute update leverage callback
     * @param _order pending order struct
     * @param _answer price aggregator request answer
     */
    function executeUpdateLeverage(
        ITradingStorage.PendingOrder memory _order,
        ITradingCallbacks.AggregatorAnswer memory _answer
    ) external {
        // 1. Prepare values
        ITradingStorage.Trade memory pendingTrade = _order.trade;
        ITradingStorage.Trade memory existingTrade = TradingCommonUtils.getTrade(pendingTrade.user, pendingTrade.index);
        bool isIncrease = pendingTrade.leverage > existingTrade.leverage;

        // 2. Refresh trader fee tier cache
        TradingCommonUtils.updateFeeTierPoints(
            existingTrade.collateralIndex,
            existingTrade.user,
            existingTrade.pairIndex,
            0
        );

        // 3. Prepare useful values
        IUpdateLeverageUtils.UpdateLeverageValues memory values = _prepareCallbackValues(
            existingTrade,
            pendingTrade,
            isIncrease,
            _answer
        );

        // 4. Callback validation
        ITradingCallbacks.CancelReason cancelReason = _validateCallback(existingTrade, values, _answer, isIncrease);

        // 5. Handle callback
        _handleCallback(existingTrade, pendingTrade, values, cancelReason, isIncrease, _answer);

        emit IUpdateLeverageUtils.LeverageUpdateExecuted(
            _answer.orderId,
            isIncrease,
            cancelReason,
            existingTrade.collateralIndex,
            existingTrade.user,
            existingTrade.pairIndex,
            existingTrade.index,
            _answer.current,
            pendingTrade.collateralAmount,
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
     * @dev Returns new trade collateral amount based on new leverage (collateral precision)
     * @param _existingCollateralAmount existing trade collateral amount (collateral precision)
     * @param _existingLeverage existing trade leverage (1e3)
     * @param _newLeverage new trade leverage (1e3)
     */
    function _getNewCollateralAmount(
        uint256 _existingCollateralAmount,
        uint256 _existingLeverage,
        uint256 _newLeverage
    ) internal pure returns (uint120) {
        return uint120((_existingCollateralAmount * _existingLeverage) / _newLeverage);
    }

    /**
     * @dev Fetches trade, does validation for update leverage request, and returns useful data
     * @param _input request input struct
     */
    function _validateRequest(
        IUpdateLeverageUtils.UpdateLeverageInput memory _input
    ) internal view returns (ITradingStorage.Trade memory trade, bool isIncrease, uint256 collateralDelta) {
        trade = TradingCommonUtils.getTrade(_input.user, _input.index);
        isIncrease = _input.newLeverage > trade.leverage;

        // 1. Check trade exists
        if (!trade.isOpen) revert IGeneralErrors.DoesntExist();

        // 2. Revert if any market order (market close, increase leverage, partial open, partial close) already exists for trade
        TradingCommonUtils.revertIfTradeHasPendingMarketOrder(_input.user, _input.index);

        // 3. Revert if collateral not active
        if (!_getMultiCollatDiamond().isCollateralActive(trade.collateralIndex))
            revert IGeneralErrors.InvalidCollateralIndex();

        // 4. Validate leverage update
        if (
            _input.newLeverage == trade.leverage ||
            !TradingCommonUtils.validateAdjustedInitialLeverage(_input.newLeverage)
        ) revert ITradingInteractionsUtils.WrongLeverage();

        // 5. Validate new collateral amount (enough to pay min closing fee)
        uint256 newCollateralAmount = _getNewCollateralAmount(
            trade.collateralAmount,
            trade.leverage,
            _input.newLeverage
        );

        if (newCollateralAmount < TradingCommonUtils.getPairMinFeeCollateral(trade.collateralIndex, trade.pairIndex))
            revert ITradingInteractionsUtils.InsufficientCollateral();

        // 6. Calculate collateral delta
        collateralDelta = isIncrease
            ? trade.collateralAmount - newCollateralAmount
            : newCollateralAmount - trade.collateralAmount;
    }

    /**
     * @dev Stores pending update leverage order and makes price aggregator request
     * @param _trade trade struct
     * @param _newLeverage new leverage (1e3)
     * @param _collateralDelta trade collateral delta (collateral precision)
     */
    function _initiateRequest(
        ITradingStorage.Trade memory _trade,
        uint24 _newLeverage,
        uint256 _collateralDelta
    ) internal returns (ITradingStorage.Id memory) {
        // 1. Store pending order
        ITradingStorage.PendingOrder memory pendingOrder;
        {
            ITradingStorage.Trade memory pendingOrderTrade;
            pendingOrderTrade.user = _trade.user;
            pendingOrderTrade.index = _trade.index;
            pendingOrderTrade.leverage = _newLeverage;
            pendingOrderTrade.collateralAmount = uint120(_collateralDelta);

            pendingOrder.trade = pendingOrderTrade;
            pendingOrder.user = _trade.user;
            pendingOrder.orderType = ITradingStorage.PendingOrderType.UPDATE_LEVERAGE;
        }

        // 2. Request price
        return
            _getMultiCollatDiamond().getPrice(
                IPriceAggregator.GetPriceInput(
                    _trade.collateralIndex,
                    _trade.pairIndex,
                    pendingOrder,
                    TradingCommonUtils.getMinPositionSizeCollateral(_trade.collateralIndex, _trade.pairIndex) / 2,
                    0,
                    _trade.isCounterTrade
                )
            );
    }

    /**
     * @dev Calculates values for callback
     * @param _existingTrade existing trade struct
     * @param _pendingTrade pending trade struct
     * @param _isIncrease true if increase leverage, false if decrease leverage
     * @param _answer price aggregator answer
     */
    function _prepareCallbackValues(
        ITradingStorage.Trade memory _existingTrade,
        ITradingStorage.Trade memory _pendingTrade,
        bool _isIncrease,
        ITradingCallbacks.AggregatorAnswer memory _answer
    ) internal view returns (IUpdateLeverageUtils.UpdateLeverageValues memory values) {
        if (_existingTrade.isOpen == false) return values;

        values.newLeverage = _pendingTrade.leverage;
        values.govFeeCollateral = TradingCommonUtils.getMinGovFeeCollateral(
            _existingTrade.collateralIndex,
            _existingTrade.user,
            _existingTrade.pairIndex
        );
        values.newCollateralAmount = (
            _isIncrease
                ? _existingTrade.collateralAmount - _pendingTrade.collateralAmount
                : _existingTrade.collateralAmount + _pendingTrade.collateralAmount
        );
        values.existingLiqPrice = TradingCommonUtils.getTradeLiquidationPrice(_existingTrade, _answer.current);
        values.newLiqPrice = TradingCommonUtils.getTradeLiquidationPrice(
            _existingTrade,
            _existingTrade.openPrice,
            values.newCollateralAmount,
            values.newLeverage,
            int256(values.govFeeCollateral),
            _getMultiCollatDiamond().getTradeLiquidationParams(_existingTrade.user, _existingTrade.index),
            _answer.current,
            0, // not partial close
            false
        );
        if (_isIncrease) {
            values.newEffectiveLeverage = TradingCommonUtils.getTradeNewEffectiveLeverage(
                _existingTrade,
                _existingTrade.openPrice,
                uint120(values.newCollateralAmount),
                uint24(values.newLeverage),
                _answer.current,
                values.govFeeCollateral
            );
            values.totalTradeAvailableCollateralInDiamond = TradingCommonUtils.getTradeAvailableCollateralInDiamond(
                _existingTrade.user,
                _existingTrade.index,
                _existingTrade.collateralAmount
            );
            values.availableCollateralInDiamond = _pendingTrade.collateralAmount >
                values.totalTradeAvailableCollateralInDiamond
                ? values.totalTradeAvailableCollateralInDiamond
                : _pendingTrade.collateralAmount;
        }
    }

    /**
     * @dev Validates callback, and returns corresponding cancel reason
     * @param _existingTrade existing trade struct
     * @param _values pre-calculated useful values
     * @param _answer price aggregator answer
     * @param _isIncrease true if increase leverage, false if decrease leverage
     */
    function _validateCallback(
        ITradingStorage.Trade memory _existingTrade,
        IUpdateLeverage.UpdateLeverageValues memory _values,
        ITradingCallbacks.AggregatorAnswer memory _answer,
        bool _isIncrease
    ) internal view returns (ITradingCallbacks.CancelReason) {
        return
            !_existingTrade.isOpen
                ? ITradingCallbacks.CancelReason.NO_TRADE
                : (
                    _existingTrade.long
                        ? (_answer.current <= _values.existingLiqPrice || _answer.current <= _values.newLiqPrice)
                        : (_answer.current >= _values.existingLiqPrice || _answer.current >= _values.newLiqPrice)
                )
                    ? ITradingCallbacks.CancelReason.LIQ_REACHED
                    : _isIncrease &&
                        _values.newEffectiveLeverage >
                        _getMultiCollatDiamond().pairMaxLeverage(_existingTrade.pairIndex)
                        ? ITradingCallbacks.CancelReason.MAX_LEVERAGE
                        : _isIncrease &&
                            _existingTrade.isCounterTrade &&
                            _values.newEffectiveLeverage >
                            _getMultiCollatDiamond().getPairCounterTradeMaxLeverage(_existingTrade.pairIndex)
                            ? ITradingCallbacks.CancelReason.COUNTER_TRADE_CANCELED
                            : ITradingCallbacks.CancelReason.NONE;
    }

    /**
     * @dev Handles trade update, removes gov fee OI, and transfers collateral delta (for both successful and failed requests)
     * @param _trade trade struct
     * @param _pendingTrade pending trade struct
     * @param _values pre-calculated useful values
     * @param _cancelReason cancel reason
     * @param _isIncrease true if increase leverage, false if decrease leverage
     */
    function _handleCallback(
        ITradingStorage.Trade memory _trade,
        ITradingStorage.Trade memory _pendingTrade,
        IUpdateLeverageUtils.UpdateLeverageValues memory _values,
        ITradingCallbacks.CancelReason _cancelReason,
        bool _isIncrease,
        ITradingCallbacks.AggregatorAnswer memory _answer
    ) internal {
        // 1. Request successful
        if (_cancelReason == ITradingCallbacks.CancelReason.NONE) {
            // 1.1 Update trade collateral and leverage, openPrice stays the same
            _getMultiCollatDiamond().updateTradePosition(
                ITradingStorage.Id(_trade.user, _trade.index),
                uint120(_values.newCollateralAmount),
                uint24(_values.newLeverage),
                _trade.openPrice,
                ITradingStorage.PendingOrderType.UPDATE_LEVERAGE, // ignore dust OI deltas
                0,
                false,
                _answer.current
            );

            // 1.2 If leverage increase, transfer collateral delta to trader
            if (_isIncrease) {
                TradingCommonUtils.handleTradeValueTransfer(
                    _trade,
                    int256(uint256(_pendingTrade.collateralAmount)),
                    int256(_values.availableCollateralInDiamond)
                );
                _getMultiCollatDiamond().storeVirtualAvailableCollateralInDiamond(
                    _trade.user,
                    _trade.index,
                    _values.newCollateralAmount
                ); /// @dev don't allow available collateral in diamond to be negative after withdrawal
            }
        } else if (!_isIncrease) {
            // 2. Request failed (decrease leverage)
            TradingCommonUtils.transferCollateralTo(
                _trade.collateralIndex,
                _trade.user,
                _pendingTrade.collateralAmount
            );
        }

        // 3. If trade exists, charge and distribute gov fee
        if (_cancelReason != ITradingCallbacks.CancelReason.NO_TRADE) {
            uint256 finalGovFeeCollateral = _getMultiCollatDiamond().realizeTradingFeesOnOpenTrade(
                _trade.user,
                _trade.index,
                _values.govFeeCollateral,
                _answer.current
            );
            TradingCommonUtils.distributeExactGovFeeCollateral(
                _trade.collateralIndex,
                _trade.user,
                finalGovFeeCollateral
            );
        }
    }
}
