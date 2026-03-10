// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import "../../interfaces/IGNSMultiCollatDiamond.sol";
import "../../interfaces/IERC20.sol";

import "../ConstantsUtils.sol";
import "../TradingCommonUtils.sol";

/**
 *
 * @dev This is an internal utils library for position size decreases
 * @dev Used by UpdatePositionSizeLifecycles internal library
 */
library DecreasePositionSizeUtils {
    /**
     * @dev Validates decrease position size request
     *
     * @dev Possible inputs: collateral delta > 0 and leverage delta = 0 (decrease collateral by collateral delta)
     *                       collateral delta = 0 and leverage delta > 0 (decrease leverage by leverage delta)
     *
     *  @param _trade trade of request
     *  @param _input input values
     */
    function validateRequest(
        ITradingStorage.Trade memory _trade,
        IUpdatePositionSizeUtils.DecreasePositionSizeInput memory _input
    ) internal view returns (uint256 positionSizeCollateralDelta) {
        // 1. Revert if both collateral and leverage are zero or if both are non-zero
        if (
            (_input.collateralDelta == 0 && _input.leverageDelta == 0) ||
            (_input.collateralDelta > 0 && _input.leverageDelta > 0)
        ) revert IUpdatePositionSizeUtils.InvalidDecreasePositionSizeInput();

        // 2. If we update the leverage, check new leverage is above the minimum
        bool isLeverageUpdate = _input.leverageDelta > 0;
        if (
            isLeverageUpdate &&
            !TradingCommonUtils.validateAdjustedInitialLeverage(_trade.leverage - _input.leverageDelta)
        ) revert ITradingInteractionsUtils.WrongLeverage();

        // 3. Revert if expected price is zero
        if (_input.expectedPrice == 0) revert IGeneralErrors.ZeroValue();

        // 4. Validate new collateral amount (enough to pay min closing fee)
        if (
            _trade.collateralAmount - _input.collateralDelta <
            TradingCommonUtils.getPairMinFeeCollateral(_trade.collateralIndex, _trade.pairIndex)
        ) revert ITradingInteractionsUtils.InsufficientCollateral();

        // 5. Calculate position size collateral delta
        positionSizeCollateralDelta = TradingCommonUtils.getPositionSizeCollateral(
            isLeverageUpdate ? _trade.collateralAmount : _input.collateralDelta,
            isLeverageUpdate ? _input.leverageDelta : _trade.leverage
        );
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
    ) internal view returns (IUpdatePositionSizeUtils.DecreasePositionSizeValues memory values) {
        // 1. Calculate position size delta and existing position size
        values.isLeverageUpdate = _partialTrade.leverage > 0;
        values.positionSizeCollateralDelta = TradingCommonUtils.getPositionSizeCollateral(
            values.isLeverageUpdate ? _existingTrade.collateralAmount : _partialTrade.collateralAmount,
            values.isLeverageUpdate ? _partialTrade.leverage : _existingTrade.leverage
        );
        values.existingPositionSizeCollateral = TradingCommonUtils.getPositionSizeCollateral(
            _existingTrade.collateralAmount,
            _existingTrade.leverage
        );

        // 2. Apply spread and price impact to answer.current
        (values.priceImpact, ) = TradingCommonUtils.getTradeClosingPriceImpact(
            ITradingCommonUtils.TradePriceImpactInput(
                _existingTrade,
                _answer.current,
                values.positionSizeCollateralDelta,
                _answer.current,
                true
            )
        );

        // 3. Calculate existing trade pnl
        values.existingPnlPercent = TradingCommonUtils.getPnlPercent(
            _existingTrade.openPrice,
            values.priceImpact.priceAfterImpact,
            _existingTrade.long,
            _existingTrade.leverage
        );
        values.partialRawPnlCollateral =
            (values.existingPnlPercent *
                int256(uint256(_existingTrade.collateralAmount)) *
                int256(uint256(values.positionSizeCollateralDelta))) /
            int256(uint256(values.existingPositionSizeCollateral)) /
            1e10 /
            100;
        values.partialNetPnlCollateral =
            ((int256(
                TradingCommonUtils.getTradeValueCollateral(
                    _existingTrade,
                    values.existingPnlPercent,
                    0, // don't apply closing fee here, we apply it after (otherwise min fee wouldn't work)
                    _answer.current
                )
            ) - int256(uint256(_existingTrade.collateralAmount))) * int256(values.positionSizeCollateralDelta)) /
            int256(values.existingPositionSizeCollateral);

        // 3. Calculate partial trade closing fees
        values.closingFeeCollateral = TradingCommonUtils.getTotalTradeFeesCollateral(
            _existingTrade.collateralIndex,
            _existingTrade.user,
            _existingTrade.pairIndex,
            values.positionSizeCollateralDelta,
            _existingTrade.isCounterTrade
        );

        // 4. Calculate value sent to trader
        values.collateralSentToTrader =
            int256(uint256(_partialTrade.collateralAmount)) +
            values.partialNetPnlCollateral -
            int256(values.closingFeeCollateral); /// @dev can't be <= 0 for collateral decreases because trade could be liquidated, unless collateral delta is < min fee

        if (values.isLeverageUpdate) {
            values.pnlToRealizeCollateral =
                values.partialRawPnlCollateral -
                (values.collateralSentToTrader > 0 ? values.collateralSentToTrader : int256(0));
        }

        // 5. Calculate new collateral amount and leverage
        values.newCollateralAmount = _existingTrade.collateralAmount - _partialTrade.collateralAmount;
        values.newLeverage = _existingTrade.leverage - _partialTrade.leverage;

        // 6. Calculate existing and new trade liquidation price
        values.existingLiqPrice = TradingCommonUtils.getTradeLiquidationPrice(_existingTrade, _answer.current);
        values.newLiqPrice = TradingCommonUtils.getTradeLiquidationPrice(
            _existingTrade,
            _existingTrade.openPrice,
            values.newCollateralAmount,
            values.newLeverage,
            values.isLeverageUpdate ? int256(values.closingFeeCollateral) - values.pnlToRealizeCollateral : int256(0),
            _getMultiCollatDiamond().getTradeLiquidationParams(_existingTrade.user, _existingTrade.index),
            _answer.current,
            values.isLeverageUpdate
                ? 1e18
                : ((values.existingPositionSizeCollateral - values.positionSizeCollateralDelta) * 1e18) /
                    values.existingPositionSizeCollateral,
            false
        );

        /// @dev Other calculations are in separate helper called after realizing pending holding fees
        // Because they can be impacted by pending holding fees realization (eg. available in diamond calc)
    }

    /**
     * @dev Calculates remaining values for success callback
     * @param _existingTrade existing trade data
     * @param _partialTrade partial trade data
     * @param _values existing values struct (will be updated in-place)
     */
    function prepareSuccessCallbackValues(
        ITradingStorage.Trade memory _existingTrade,
        ITradingStorage.Trade memory _partialTrade,
        IUpdatePositionSizeUtils.DecreasePositionSizeValues memory _values
    ) internal view {
        // 1. Fetch existing trade available in diamond (after pending holding fees are realized)
        _values.totalAvailableCollateralInDiamond = TradingCommonUtils.getTradeAvailableCollateralInDiamond(
            _existingTrade.user,
            _existingTrade.index,
            _existingTrade.collateralAmount
        );

        // 2.1 Calculate available collateral in diamond (collateral decrease)
        // Collateral decreases are simpler because it's like scaling down the whole trade
        // Trader receives proportional collateral + net pnl - partial closing fee, available in diamond is proportional to total available in diamond
        // Then the whole trade's value is scaled down (including available in diamond)
        if (!_values.isLeverageUpdate) {
            uint256 missingCollateralFromDiamond = uint256(_existingTrade.collateralAmount) -
                _values.totalAvailableCollateralInDiamond;

            _values.availableCollateralInDiamond =
                int256(uint256(_partialTrade.collateralAmount)) -
                int256(
                    Math.mulDiv(
                        missingCollateralFromDiamond,
                        _values.positionSizeCollateralDelta,
                        _values.existingPositionSizeCollateral,
                        Math.Rounding.Up
                    )
                ) -
                int256(_values.closingFeeCollateral); /// @dev can be negative if partial available in diamond < closing fee
        } else if (_values.collateralSentToTrader < 0) {
            // 2.2 Leverage decreases are more complex, available collateral in diamond is always 0 (we just settle pnl)
            // We send net PnL to trader, and realize (unrealized partial pnl - what we sent to trader)
            // So that new trade value = old trade value - what we sent to trader (no value created or destroyed)
            // When net PnL is negative, we only send the raw negative PnL to vault (unrealized + realized PnL - manually realized - already sent)
            // And store it as already transferred to vault so we don't transfer it again later and reduce available in diamond

            IFundingFees.TradeFeesData memory tradeFeesData = _getMultiCollatDiamond().getTradeFeesData(
                _existingTrade.user,
                _existingTrade.index
            );

            int256 pnlCollateralToSendToVault = _values.partialRawPnlCollateral +
                (tradeFeesData.realizedPnlCollateral * int256(uint256(_values.positionSizeCollateralDelta))) /
                int256(_values.existingPositionSizeCollateral) +
                int256(
                    Math.mulDiv(
                        uint256(tradeFeesData.manuallyRealizedNegativePnlCollateral) +
                            uint256(tradeFeesData.alreadyTransferredNegativePnlCollateral),
                        _values.positionSizeCollateralDelta,
                        _values.existingPositionSizeCollateral,
                        Math.Rounding.Up
                    )
                );

            // Re-check if there is any negative pnl to send to vault (net pnl could be negative because of trading fees for example)
            _values.collateralSentToTrader = pnlCollateralToSendToVault < 0 ? pnlCollateralToSendToVault : int256(0);

            // Make sure we never send more than what we have in diamond to vault
            // This is probably unreachable because we already remove manually realized and already transferred negative pnl
            // And the only other thing that impacts available collateral in diamond is realized trading fees
            // But in this case we should always have enough in diamond because if net PnL < -available in diamond, trade can be liquidated
            _values.collateralSentToTrader = _values.collateralSentToTrader <
                -int256(_values.totalAvailableCollateralInDiamond)
                ? -int256(_values.totalAvailableCollateralInDiamond)
                : _values.collateralSentToTrader;
        }
    }

    /**
     * @dev Validates callback, and returns corresponding cancel reason
     * @param _values pre-calculated useful values
     */
    function validateCallback(
        ITradingStorage.Trade memory _existingTrade,
        ITradingStorage.PendingOrder memory _pendingOrder,
        IUpdatePositionSizeUtils.DecreasePositionSizeValues memory _values,
        ITradingCallbacks.AggregatorAnswer memory _answer
    ) internal view returns (ITradingCallbacks.CancelReason) {
        // Max slippage calculations
        uint256 expectedPrice = _pendingOrder.trade.openPrice;
        uint256 maxSlippageP = _getMultiCollatDiamond()
            .getTradeInfo(_existingTrade.user, _existingTrade.index)
            .maxSlippageP;
        uint256 maxSlippage = (expectedPrice *
            (maxSlippageP > 0 ? maxSlippageP : ConstantsUtils.DEFAULT_MAX_CLOSING_SLIPPAGE_P)) /
            100 /
            1e3;

        return
            (
                _existingTrade.long
                    ? (_answer.current <= _values.existingLiqPrice || _answer.current <= _values.newLiqPrice)
                    : (_answer.current >= _values.existingLiqPrice || _answer.current >= _values.newLiqPrice)
            )
                ? ITradingCallbacks.CancelReason.LIQ_REACHED
                : (
                    _existingTrade.long
                        ? _values.priceImpact.priceAfterImpact < expectedPrice - maxSlippage
                        : _values.priceImpact.priceAfterImpact > expectedPrice + maxSlippage
                )
                    ? ITradingCallbacks.CancelReason.SLIPPAGE
                    : !_values.isLeverageUpdate && _values.collateralSentToTrader < 0
                        ? ITradingCallbacks.CancelReason.WRONG_TRADE // possible if collateral delta < min fee
                        : ITradingCallbacks.CancelReason.NONE;
    }

    /**
     * @dev Updates trade (for successful request)
     * @param _existingTrade existing trade data
     * @param _partialTrade partial trade data
     * @param _values pre-calculated useful values
     * @param _answer price aggregator answer
     */
    function updateTradeSuccess(
        ITradingStorage.Trade memory _existingTrade,
        ITradingStorage.Trade memory _partialTrade,
        IUpdatePositionSizeUtils.DecreasePositionSizeValues memory _values,
        ITradingCallbacks.AggregatorAnswer memory _answer
    ) internal {
        // 1. Update trade in storage (realizes pending holding fees)
        _getMultiCollatDiamond().updateTradePosition(
            ITradingStorage.Id(_existingTrade.user, _existingTrade.index),
            _values.newCollateralAmount,
            _values.newLeverage,
            _existingTrade.openPrice, // open price stays the same
            ITradingStorage.PendingOrderType.MARKET_PARTIAL_CLOSE, // don't refresh liquidation params
            _values.priceImpact.positionSizeToken,
            _values.existingPnlPercent > 0,
            _answer.current
        );

        // 2. Calculate remaining success callback values
        prepareSuccessCallbackValues(_existingTrade, _partialTrade, _values);

        // 3. Handle collateral/pnl transfers with vault/diamond/user
        TradingCommonUtils.handleTradeValueTransfer(
            _existingTrade,
            _values.collateralSentToTrader,
            int256(_values.availableCollateralInDiamond)
        );

        if (_values.isLeverageUpdate) {
            // 4.1.1 Realize pnl so new trade value + collateral sent to trader = previous trade value (no value created or destroyed)
            // First we realize the partial pnl amount so prev raw pnl = new raw pnl, and then we remove what we sent from trader
            _getMultiCollatDiamond().realizePnlOnOpenTrade(
                _existingTrade.user,
                _existingTrade.index,
                _values.pnlToRealizeCollateral
            );

            // 4.1.2 Decrease collat available in diamond (if we've sent negative PnL to vault)
            if (_values.collateralSentToTrader < 0) {
                _getMultiCollatDiamond().storeAlreadyTransferredNegativePnl(
                    _existingTrade.user,
                    _existingTrade.index,
                    uint256(-_values.collateralSentToTrader)
                );
            }

            // 4.1.3 Realize trading fee (if leverage decrease)
            // Not needed for collateral decreases because closing fee is removed from available collateral in diamond and trade value
            // So vault sends as much as if there was no closing fee, but we send less to the trader, so we always have the partial closing fee in diamond
            // This is especially important for lev decreases when nothing is available in diamond, this will transfer the closing fee from vault
            _getMultiCollatDiamond().realizeTradingFeesOnOpenTrade(
                _existingTrade.user,
                _existingTrade.index,
                _values.closingFeeCollateral,
                _answer.current
            );
        } else {
            // 4.2.1 Proportionally reduce realized pnl and available collateral in diamond (if collat decrease)
            // So that new trade value + collateral sent to trader = previous trade value (no value created or destroyed)
            // For leverage decreases we have to use another approach since it only settles net PnL and doesn't touch collateral
            _getMultiCollatDiamond().downscaleTradeFeesData(
                _existingTrade.user,
                _existingTrade.index,
                _values.positionSizeCollateralDelta,
                _values.existingPositionSizeCollateral,
                _values.newCollateralAmount
            );

            // 4.2.2 Store realized trading fees for UI
            // Since we don't call realizeTradingFeesOnOpenTrade (partial close fee taken from amount sent to trader)
            _getMultiCollatDiamond().storeUiRealizedTradingFeesCollateral(
                _existingTrade.user,
                _existingTrade.index,
                _values.closingFeeCollateral
            );
        }

        // 5. Store partial realized pnl for UI
        // collateral sent to trader >= 0: the trade net pnl decreases by partial net pnl (which was sent to trader)
        // either by scaling all values down (collat decrease) or adjusting realized pnl (lev decrease)
        // collateral sent to trader < 0: the trade net pnl stays the same, but it's shifted from raw pnl to realized pnl
        _getMultiCollatDiamond().storeUiRealizedPnlPartialCloseCollateral(
            _existingTrade.user,
            _existingTrade.index,
            _values.collateralSentToTrader >= 0
                ? _values.partialNetPnlCollateral - int256(_values.closingFeeCollateral)
                : _values.partialRawPnlCollateral
        );
    }

    /**
     * @dev Handles callback canceled case (for failed request)
     * @param _existingTrade trade to update
     * @param _cancelReason cancel reason
     * @param _answer price aggregator answer
     */
    function handleCanceled(
        ITradingStorage.Trade memory _existingTrade,
        ITradingCallbacks.CancelReason _cancelReason,
        ITradingCallbacks.AggregatorAnswer memory _answer
    ) internal {
        if (_cancelReason != ITradingCallbacks.CancelReason.NO_TRADE) {
            // 1. Distribute gov fee
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
    }

    /**
     * @dev Returns current address as multi-collateral diamond interface to call other facets functions.
     */
    function _getMultiCollatDiamond() internal view returns (IGNSMultiCollatDiamond) {
        return IGNSMultiCollatDiamond(address(this));
    }
}
