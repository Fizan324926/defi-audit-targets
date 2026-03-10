// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import "../../interfaces/IGNSMultiCollatDiamond.sol";
import "../../interfaces/IERC20.sol";

import "../ConstantsUtils.sol";
import "../TradingCommonUtils.sol";

/**
 *
 * @dev This is an internal utils library for position size increases
 * @dev Used by UpdatePositionSizeLifecycles internal library
 */
library IncreasePositionSizeUtils {
    /**
     * @dev Validates increase position request.
     *
     * @dev Possible inputs: collateral delta > 0 and leverage delta > 0 (increase position size by collateral delta * leverage delta)
     *                       collateral delta = 0 and leverage delta > 0 (increase trade leverage by leverage delta)
     *
     * @param _trade trade of request
     * @param _input input values
     */
    function validateRequest(
        ITradingStorage.Trade memory _trade,
        IUpdatePositionSizeUtils.IncreasePositionSizeInput memory _input
    ) internal view returns (uint256 positionSizeCollateralDelta) {
        // 0. Make sure trade is opened after v10 (otherwise can bypass funding fees / skew price impact)
        if (
            _getMultiCollatDiamond().getTradeContractsVersion(_trade.user, _trade.index) <
            ITradingStorage.ContractsVersion.V10
        ) revert IGeneralErrors.NotAuthorized();

        // 1. Zero values checks
        if (_input.leverageDelta == 0 || _input.expectedPrice == 0 || _input.maxSlippageP == 0)
            revert IUpdatePositionSizeUtils.InvalidIncreasePositionSizeInput();

        // 2. Revert if adjusted initial leverage is invalid
        bool isLeverageUpdate = _input.collateralDelta == 0;

        positionSizeCollateralDelta = TradingCommonUtils.getPositionSizeCollateral(
            isLeverageUpdate ? _trade.collateralAmount : _input.collateralDelta,
            _input.leverageDelta
        );

        uint256 newLeverage = isLeverageUpdate
            ? uint256(_trade.leverage) + _input.leverageDelta
            : ((TradingCommonUtils.getPositionSizeCollateral(_trade.collateralAmount, _trade.leverage) +
                positionSizeCollateralDelta) * 1e3) / (_trade.collateralAmount + _input.collateralDelta);

        if (!TradingCommonUtils.validateAdjustedInitialLeverage(newLeverage))
            revert ITradingInteractionsUtils.WrongLeverage();
    }

    /**
     * @dev Calculates values for callback
     * @param _existingTrade existing trade data
     * @param _partialTrade partial trade data
     * @param _answer price aggregator answer
     */
    function prepareCallbackValues(
        ITradingStorage.Trade memory _existingTrade,
        ITradingStorage.Trade memory _partialTrade,
        ITradingCallbacks.AggregatorAnswer memory _answer
    ) internal view returns (IUpdatePositionSizeUtils.IncreasePositionSizeValues memory values) {
        // 1.1 Calculate position size delta
        bool isLeverageUpdate = _partialTrade.collateralAmount == 0;
        values.positionSizeCollateralDelta = TradingCommonUtils.getPositionSizeCollateral(
            isLeverageUpdate ? _existingTrade.collateralAmount : _partialTrade.collateralAmount,
            _partialTrade.leverage
        );

        // 1.2 Validate counter trade and update position size delta if needed
        if (_existingTrade.isCounterTrade) {
            (values.isCounterTradeValidated, values.exceedingPositionSizeCollateral) = TradingCommonUtils
                .validateCounterTrade(_existingTrade, values.positionSizeCollateralDelta, _answer.current);

            if (values.isCounterTradeValidated && values.exceedingPositionSizeCollateral > 0) {
                if (isLeverageUpdate) {
                    // For leverage updates, simply reduce leverage delta to reach 0 skew
                    _partialTrade.leverage -= uint24(
                        Math.mulDiv(
                            values.exceedingPositionSizeCollateral,
                            1e3,
                            _existingTrade.collateralAmount,
                            Math.Rounding.Up
                        )
                    );
                } else {
                    // For collateral adds, reduce collateral delta to reach 0 skew
                    values.counterTradeCollateralToReturn = Math.mulDiv(
                        values.exceedingPositionSizeCollateral,
                        1e3,
                        _partialTrade.leverage,
                        Math.Rounding.Up
                    );
                    _partialTrade.collateralAmount -= uint120(values.counterTradeCollateralToReturn);
                }

                values.positionSizeCollateralDelta = TradingCommonUtils.getPositionSizeCollateral(
                    isLeverageUpdate ? _existingTrade.collateralAmount : _partialTrade.collateralAmount,
                    _partialTrade.leverage
                );
            }
        }

        values.existingPositionSizeCollateral = TradingCommonUtils.getPositionSizeCollateral(
            _existingTrade.collateralAmount,
            _existingTrade.leverage
        );
        values.newPositionSizeCollateral = values.existingPositionSizeCollateral + values.positionSizeCollateralDelta;

        // 2.1 Calculate new collateral amount and leverage
        values.newCollateralAmount = _existingTrade.collateralAmount + _partialTrade.collateralAmount;
        values.newLeverage = isLeverageUpdate
            ? _existingTrade.leverage + _partialTrade.leverage
            : (values.newPositionSizeCollateral * 1e3) / values.newCollateralAmount;

        // 2.2 Re-calculate new position size and position size delta due to potential new leverage rounding issues
        values.newPositionSizeCollateral = (values.newCollateralAmount * values.newLeverage) / 1e3;
        if (values.newPositionSizeCollateral < values.existingPositionSizeCollateral) return values;

        values.positionSizeCollateralDelta = values.newPositionSizeCollateral - values.existingPositionSizeCollateral;

        // 3. Calculate price impact values
        values.priceImpact = TradingCommonUtils.getTradeOpeningPriceImpact(
            ITradingCommonUtils.TradePriceImpactInput(
                _existingTrade,
                _answer.current,
                values.positionSizeCollateralDelta,
                0,
                true
            )
        );

        // 4. Calculate existing trade pnl
        values.existingPnlCollateral = TradingCommonUtils.getTradeUnrealizedRawPnlCollateral(
            _existingTrade,
            values.priceImpact.priceAfterImpact
        );

        // 5. Calculate partial trade opening fees
        values.openingFeesCollateral = TradingCommonUtils.getTotalTradeFeesCollateral(
            _existingTrade.collateralIndex,
            _existingTrade.user,
            _existingTrade.pairIndex,
            values.positionSizeCollateralDelta,
            _existingTrade.isCounterTrade
        );

        // 6. Calculate new open price
        values.oldPosSizePlusPnlCollateral = uint256(
            int256(values.existingPositionSizeCollateral) +
                values.existingPnlCollateral *
                (_existingTrade.long ? int256(1) : int256(-1))
        ); // longs: min pnl = -collateral <= position size, shorts: max pnl = collateral * leverage = position size => no underflow

        values.newOpenPrice = Math.mulDiv(
            values.oldPosSizePlusPnlCollateral *
                uint256(_existingTrade.openPrice) +
                values.positionSizeCollateralDelta *
                values.priceImpact.priceAfterImpact,
            1,
            values.oldPosSizePlusPnlCollateral + values.positionSizeCollateralDelta,
            _existingTrade.long ? Math.Rounding.Up : Math.Rounding.Down
        );

        // 7. Calculate existing and new liq price
        values.existingLiqPrice = TradingCommonUtils.getTradeLiquidationPrice(_existingTrade, _answer.current);
        values.newLiqPrice = TradingCommonUtils.getTradeLiquidationPrice(
            _existingTrade,
            uint64(values.newOpenPrice),
            values.newCollateralAmount,
            values.newLeverage,
            int256(values.openingFeesCollateral),
            _getMultiCollatDiamond().getPairLiquidationParams(_existingTrade.pairIndex), // new liquidation params
            _answer.current,
            0, // not partial close
            false
        );

        // 8. Calculate new effective leverage
        values.newEffectiveLeverage = TradingCommonUtils.getTradeNewEffectiveLeverage(
            _existingTrade,
            uint64(values.newOpenPrice),
            uint120(values.newCollateralAmount),
            uint24(values.newLeverage),
            _answer.current,
            values.openingFeesCollateral
        );
    }

    /**
     * @dev Validates callback, and returns corresponding cancel reason
     * @param _existingTrade existing trade data
     * @param _values pre-calculated useful values
     * @param _expectedPrice user expected price before callback (1e10)
     * @param _maxSlippageP maximum slippage percentage from expected price (1e3)
     */
    function validateCallback(
        ITradingStorage.Trade memory _existingTrade,
        IUpdatePositionSizeUtils.IncreasePositionSizeValues memory _values,
        ITradingCallbacks.AggregatorAnswer memory _answer,
        uint256 _expectedPrice,
        uint256 _maxSlippageP
    ) internal view returns (ITradingCallbacks.CancelReason cancelReason) {
        uint256 maxSlippage = (uint256(_expectedPrice) * _maxSlippageP) / 100 / 1e3;

        cancelReason = _values.newPositionSizeCollateral <= _values.existingPositionSizeCollateral
            ? ITradingCallbacks.CancelReason.WRONG_TRADE
            : (
                _existingTrade.long
                    ? _values.priceImpact.priceAfterImpact > _expectedPrice + maxSlippage
                    : _values.priceImpact.priceAfterImpact < _expectedPrice - maxSlippage
            )
                ? ITradingCallbacks.CancelReason.SLIPPAGE
                : _existingTrade.tp > 0 &&
                    (_existingTrade.long ? _answer.current >= _existingTrade.tp : _answer.current <= _existingTrade.tp)
                    ? ITradingCallbacks.CancelReason.TP_REACHED
                    : _existingTrade.sl > 0 &&
                        (
                            _existingTrade.long
                                ? _answer.current <= _existingTrade.sl
                                : _answer.current >= _existingTrade.sl
                        )
                        ? ITradingCallbacks.CancelReason.SL_REACHED
                        : (
                            _existingTrade.long
                                ? (_answer.current <= _values.existingLiqPrice ||
                                    _answer.current <= _values.newLiqPrice)
                                : (_answer.current >= _values.existingLiqPrice ||
                                    _answer.current >= _values.newLiqPrice)
                        )
                            ? ITradingCallbacks.CancelReason.LIQ_REACHED
                            : !TradingCommonUtils.isWithinExposureLimits(
                                _existingTrade.collateralIndex,
                                _existingTrade.pairIndex,
                                _existingTrade.long,
                                _values.positionSizeCollateralDelta,
                                _answer.current
                            )
                                ? ITradingCallbacks.CancelReason.EXPOSURE_LIMITS
                                : _values.newEffectiveLeverage >
                                    _getMultiCollatDiamond().pairMaxLeverage(_existingTrade.pairIndex)
                                    ? ITradingCallbacks.CancelReason.MAX_LEVERAGE
                                    : _existingTrade.isCounterTrade &&
                                        (!_values.isCounterTradeValidated ||
                                            _values.newEffectiveLeverage >
                                            _getMultiCollatDiamond().getPairCounterTradeMaxLeverage(
                                                _existingTrade.pairIndex
                                            ))
                                        ? ITradingCallbacks.CancelReason.COUNTER_TRADE_CANCELED
                                        : ITradingCallbacks.CancelReason.NONE;
    }

    /**
     * @dev Updates trade (for successful request)
     * @param _existingTrade existing trade data
     * @param _values pre-calculated useful values
     * @param _answer price aggregator answer
     */
    function updateTradeSuccess(
        ITradingStorage.Trade memory _existingTrade,
        IUpdatePositionSizeUtils.IncreasePositionSizeValues memory _values,
        ITradingCallbacks.AggregatorAnswer memory _answer
    ) internal {
        // 1. Update trade in storage (realizes pending holding fees)
        _getMultiCollatDiamond().updateTradePosition(
            ITradingStorage.Id(_existingTrade.user, _existingTrade.index),
            uint120(_values.newCollateralAmount),
            uint24(_values.newLeverage),
            uint64(_values.newOpenPrice),
            ITradingStorage.PendingOrderType.MARKET_PARTIAL_OPEN, // refresh liquidation params
            _values.priceImpact.positionSizeToken,
            false,
            _answer.current
        );

        // 2. Charge opening fees on trade
        _getMultiCollatDiamond().realizeTradingFeesOnOpenTrade(
            _existingTrade.user,
            _existingTrade.index,
            _values.openingFeesCollateral,
            _answer.current
        );

        // 3. Return any exceeding collateral to trader (for counter trades)
        if (_existingTrade.isCounterTrade && _values.counterTradeCollateralToReturn > 0) {
            TradingCommonUtils.transferCollateralTo(
                _existingTrade.collateralIndex,
                _existingTrade.user,
                _values.counterTradeCollateralToReturn
            );

            emit ITradingCallbacksUtils.CounterTradeCollateralReturned(
                _answer.orderId,
                _existingTrade.collateralIndex,
                _existingTrade.user,
                _values.counterTradeCollateralToReturn
            );
        }
    }

    /**
     * @dev Handles callback canceled case (for failed request)
     * @param _existingTrade existing trade data
     * @param _partialTrade partial trade data
     * @param _cancelReason cancel reason
     * @param _answer price aggregator answer
     * @param _values values struct
     */
    function handleCanceled(
        ITradingStorage.Trade memory _existingTrade,
        ITradingStorage.Trade memory _partialTrade,
        ITradingCallbacks.CancelReason _cancelReason,
        ITradingCallbacks.AggregatorAnswer memory _answer,
        IUpdatePositionSizeUtils.IncreasePositionSizeValues memory _values
    ) internal {
        // 1. Charge gov fee on trade (if trade exists)
        if (_cancelReason != ITradingCallbacks.CancelReason.NO_TRADE) {
            // 1.1 Distribute gov fee
            uint256 govFeeCollateral = TradingCommonUtils.getMinGovFeeCollateral(
                _existingTrade.collateralIndex,
                _existingTrade.user,
                _existingTrade.pairIndex
            );
            uint256 finalGovFeeCollateral = _getMultiCollatDiamond().realizeTradingFeesOnOpenTrade(
                _existingTrade.user,
                _existingTrade.index,
                govFeeCollateral,
                _answer.current
            );
            TradingCommonUtils.distributeExactGovFeeCollateral(
                _existingTrade.collateralIndex,
                _existingTrade.user,
                finalGovFeeCollateral
            );
        }

        // 2. Send back partial collateral to trader
        TradingCommonUtils.transferCollateralTo(
            _existingTrade.collateralIndex,
            _existingTrade.user,
            _partialTrade.collateralAmount + _values.counterTradeCollateralToReturn
        );
    }

    /**
     * @dev Returns current address as multi-collateral diamond interface to call other facets functions.
     */
    function _getMultiCollatDiamond() internal view returns (IGNSMultiCollatDiamond) {
        return IGNSMultiCollatDiamond(address(this));
    }
}
