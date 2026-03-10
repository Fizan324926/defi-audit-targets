// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import "../interfaces/IGNSMultiCollatDiamond.sol";
import "../interfaces/IGToken.sol";
import "../interfaces/IGNSStaking.sol";
import "../interfaces/IERC20.sol";

import "./StorageUtils.sol";
import "./AddressStoreUtils.sol";
import "./TradingCommonUtils.sol";
import "./updateLeverage/UpdateLeverageLifecycles.sol";
import "./updatePositionSize/UpdatePositionSizeLifecycles.sol";
import "./TradeManagementCallbacksUtils.sol";

/**
 * @dev GNSTradingCallbacks facet external library
 */
library TradingCallbacksUtils {
    /**
     * @dev Check ITradingCallbacksUtils interface for documentation
     */
    function initializeCallbacks(uint8 _vaultClosingFeeP) external {
        updateVaultClosingFeeP(_vaultClosingFeeP);
    }

    /**
     * @dev Check ITradingCallbacksUtils interface for documentation
     */
    function updateVaultClosingFeeP(uint8 _valueP) public {
        if (_valueP > 100) revert IGeneralErrors.AboveMax();

        _getStorage().vaultClosingFeeP = _valueP;

        emit ITradingCallbacksUtils.VaultClosingFeePUpdated(_valueP);
    }

    /**
     * @dev Check ITradingCallbacksUtils interface for documentation
     */
    function updateTreasuryAddress(address _treasury) external {
        if (_treasury == address(0)) revert IGeneralErrors.ZeroAddress();

        // Set treasury address
        IGNSAddressStore.Addresses storage addresses = AddressStoreUtils.getAddresses();
        addresses.treasury = _treasury;

        emit IGNSAddressStore.AddressesUpdated(addresses);
    }

    /**
     * @dev Check ITradingCallbacksUtils interface for documentation
     */
    function claimPendingGovFees() external {
        address treasury = AddressStoreUtils.getAddresses().treasury;

        if (treasury == address(0)) revert IGeneralErrors.ZeroAddress();

        uint8 collateralsCount = _getMultiCollatDiamond().getCollateralsCount();
        for (uint8 i = 1; i <= collateralsCount; ++i) {
            uint256 feesAmountCollateral = _getStorage().pendingGovFees[i];

            if (feesAmountCollateral > 0) {
                _getStorage().pendingGovFees[i] = 0;

                TradingCommonUtils.transferCollateralTo(i, treasury, feesAmountCollateral, false);

                emit ITradingCallbacksUtils.PendingGovFeesClaimed(i, feesAmountCollateral);
            }
        }
    }

    /**
     * @dev Check ITradingCallbacksUtils interface for documentation
     */
    function openTradeMarketCallback(ITradingCallbacks.AggregatorAnswer memory _a) external tradingActivated {
        ITradingStorage.PendingOrder memory o = _getPendingOrder(_a.orderId);

        _validatePendingOrderOpen(o);

        ITradingStorage.Trade memory t = o.trade;
        TradingCommonUtils.updateFeeTierPoints(t.collateralIndex, t.user, t.pairIndex, 0);

        ITradingCallbacks.Values memory v = _openTradePrep(t, _a.current, o.maxSlippageP, _a.current);

        t.openPrice = uint64(v.priceImpact.priceAfterImpact);

        if (v.cancelReason == ITradingCallbacks.CancelReason.NONE) {
            // Return excess counter trade collateral
            if (v.collateralToReturn > 0) {
                TradingCommonUtils.transferCollateralTo(t.collateralIndex, t.user, v.collateralToReturn);
                t.collateralAmount = v.newCollateralAmount;
                emit ITradingCallbacksUtils.CounterTradeCollateralReturned(
                    _a.orderId,
                    t.collateralIndex,
                    t.user,
                    v.collateralToReturn
                );
            }

            t = _registerTrade(t, v.openingFeeCollateral, v.priceImpact.positionSizeToken, o.orderType, _a.current);

            emit ITradingCallbacksUtils.MarketExecuted(
                _a.orderId,
                t.user,
                t.index,
                t,
                true,
                _a.current,
                t.openPrice,
                v.liqPrice,
                v.priceImpact,
                0,
                0,
                _getCollateralPriceUsd(t.collateralIndex)
            );
        } else {
            // Gov fee to pay for oracle cost
            uint256 govFeeCollateral = TradingCommonUtils.getMinGovFeeCollateral(
                t.collateralIndex,
                t.user,
                t.pairIndex
            );
            TradingCommonUtils.distributeExactGovFeeCollateral(t.collateralIndex, t.user, govFeeCollateral);

            uint256 collateralReturned = t.collateralAmount - govFeeCollateral;
            TradingCommonUtils.transferCollateralTo(t.collateralIndex, t.user, collateralReturned);

            emit ITradingCallbacksUtils.MarketOpenCanceled(
                _a.orderId,
                t.user,
                t.pairIndex,
                v.cancelReason,
                collateralReturned
            );
        }
    }

    /**
     * @dev Check ITradingCallbacksUtils interface for documentation
     */
    function closeTradeMarketCallback(
        ITradingCallbacks.AggregatorAnswer memory _a
    ) external tradingActivatedOrCloseOnly {
        ITradingStorage.PendingOrder memory o = _getPendingOrder(_a.orderId);

        _validatePendingOrderOpen(o);

        ITradingStorage.Trade memory t = _getTrade(o.trade.user, o.trade.index);
        ITradingStorage.TradeInfo memory i = _getTradeInfo(o.trade.user, o.trade.index);

        ITradingCommonUtils.TradePriceImpact memory priceImpact = _getTradeClosingPriceImpact(
            t,
            _a.current,
            _a.current,
            true
        );

        ITradingCallbacks.CancelReason cancelReason;
        {
            uint256 expectedPrice = o.trade.openPrice;
            uint256 maxSlippage = (expectedPrice *
                (i.maxSlippageP > 0 ? i.maxSlippageP : ConstantsUtils.DEFAULT_MAX_CLOSING_SLIPPAGE_P)) /
                100 /
                1e3;

            cancelReason = !t.isOpen
                ? ITradingCallbacks.CancelReason.NO_TRADE
                : (
                    t.long
                        ? priceImpact.priceAfterImpact < expectedPrice - maxSlippage
                        : priceImpact.priceAfterImpact > expectedPrice + maxSlippage
                )
                    ? ITradingCallbacks.CancelReason.SLIPPAGE
                    : ITradingCallbacks.CancelReason.NONE;
        }

        if (cancelReason != ITradingCallbacks.CancelReason.NO_TRADE) {
            ITradingCallbacks.Values memory v;

            if (cancelReason == ITradingCallbacks.CancelReason.NONE) {
                v.profitP = TradingCommonUtils.getPnlPercent(
                    t.openPrice,
                    priceImpact.priceAfterImpact,
                    t.long,
                    t.leverage
                );
                v.liqPrice = TradingCommonUtils.getTradeLiquidationPrice(t, _a.current);
                v.amountSentToTrader = _unregisterTrade(t, v.profitP, o.orderType, _a.current, v.liqPrice, _a.current);
                v.collateralPriceUsd = _getCollateralPriceUsd(t.collateralIndex);

                emit ITradingCallbacksUtils.MarketExecuted(
                    _a.orderId,
                    t.user,
                    t.index,
                    t,
                    false,
                    _a.current,
                    priceImpact.priceAfterImpact,
                    v.liqPrice,
                    priceImpact,
                    v.profitP,
                    v.amountSentToTrader,
                    v.collateralPriceUsd
                );
            } else {
                // Charge gov fee
                TradingCommonUtils.updateFeeTierPoints(t.collateralIndex, t.user, t.pairIndex, 0);
                uint256 govFeeCollateral = TradingCommonUtils.getMinGovFeeCollateral(
                    t.collateralIndex,
                    t.user,
                    t.pairIndex
                );
                uint256 finalGovFeeCollateral = _getMultiCollatDiamond().realizeTradingFeesOnOpenTrade(
                    t.user,
                    t.index,
                    govFeeCollateral,
                    _a.current
                );
                TradingCommonUtils.distributeExactGovFeeCollateral(t.collateralIndex, t.user, finalGovFeeCollateral);
            }
        }

        if (cancelReason != ITradingCallbacks.CancelReason.NONE) {
            emit ITradingCallbacksUtils.MarketCloseCanceled(_a.orderId, t.user, t.pairIndex, t.index, cancelReason);
        }
    }

    /**
     * @dev Check ITradingCallbacksUtils interface for documentation
     */
    function executeTriggerOpenOrderCallback(ITradingCallbacks.AggregatorAnswer memory _a) external tradingActivated {
        ITradingStorage.PendingOrder memory o = _getPendingOrder(_a.orderId);

        _validatePendingOrderOpen(o);

        executeTriggerOpenOrderCallbackDirect(_a, _getTrade(o.trade.user, o.trade.index), o.orderType, o.user);
    }

    /**
     * @dev Check ITradingCallbacksUtils interface for documentation
     */
    function executeTriggerOpenOrderCallbackDirect(
        ITradingCallbacks.AggregatorAnswer memory _a,
        ITradingStorage.Trade memory _trade,
        ITradingStorage.PendingOrderType _orderType,
        address _initiator
    ) public tradingActivated {
        TradingCommonUtils.updateFeeTierPoints(_trade.collateralIndex, _trade.user, _trade.pairIndex, 0);

        // Ensure state conditions for executing open order trigger are met
        ITradingCallbacks.Values memory v = _validateTriggerOpenOrderCallback(
            _trade,
            _orderType,
            _a.open,
            _a.high,
            _a.low,
            _a.current
        );

        if (v.cancelReason == ITradingCallbacks.CancelReason.NONE) {
            // Return excess counter trade collateral
            if (v.collateralToReturn > 0) {
                TradingCommonUtils.transferCollateralTo(_trade.collateralIndex, _trade.user, v.collateralToReturn);
                _trade.collateralAmount = v.newCollateralAmount;
                emit ITradingCallbacksUtils.CounterTradeCollateralReturned(
                    _a.orderId,
                    _trade.collateralIndex,
                    _trade.user,
                    v.collateralToReturn
                );
            }

            // Unregister open order
            v.limitIndex = _trade.index;
            _getMultiCollatDiamond().closeTrade(ITradingStorage.Id({user: _trade.user, index: v.limitIndex}), false, 0);

            // Store trade
            _trade.openPrice = uint64(v.executionPrice);
            _trade.tradeType = ITradingStorage.TradeType.TRADE;
            _trade = _registerTrade(
                _trade,
                v.openingFeeCollateral,
                v.priceImpact.positionSizeToken,
                _orderType,
                _a.current
            );

            v.collateralPriceUsd = _getCollateralPriceUsd(_trade.collateralIndex);

            emit ITradingCallbacksUtils.LimitExecuted(
                _a.orderId,
                _trade.user,
                _trade.index,
                v.limitIndex,
                _trade,
                _initiator,
                _orderType,
                v.executionPriceRaw,
                _trade.openPrice,
                v.liqPrice,
                v.priceImpact,
                0,
                0,
                v.collateralPriceUsd,
                v.exactExecution
            );
        } else {
            emit ITradingCallbacksUtils.TriggerOrderCanceled(_a.orderId, _initiator, _orderType, v.cancelReason);
        }
    }

    /**
     * @dev Check ITradingCallbacksUtils interface for documentation
     */
    function executeTriggerCloseOrderCallback(
        ITradingCallbacks.AggregatorAnswer memory _a
    ) external tradingActivatedOrCloseOnly {
        ITradingStorage.PendingOrder memory o = _getPendingOrder(_a.orderId);

        _validatePendingOrderOpen(o);

        executeTriggerCloseOrderCallbackDirect(_a, _getTrade(o.trade.user, o.trade.index), o.orderType, o.user);
    }

    /**
     * @dev Check ITradingCallbacksUtils interface for documentation
     */
    function executeTriggerCloseOrderCallbackDirect(
        ITradingCallbacks.AggregatorAnswer memory _a,
        ITradingStorage.Trade memory _trade,
        ITradingStorage.PendingOrderType _orderType,
        address _initiator
    ) public tradingActivatedOrCloseOnly {
        // Ensure state conditions for executing close order trigger are met
        ITradingCallbacks.Values memory v = _validateTriggerCloseOrderCallback(
            _trade,
            _orderType,
            _a.open,
            _a.high,
            _a.low,
            _a.current
        );

        if (v.cancelReason == ITradingCallbacks.CancelReason.NONE) {
            v.profitP = TradingCommonUtils.getPnlPercent(
                _trade.openPrice,
                uint64(v.executionPrice),
                _trade.long,
                _trade.leverage
            );
            v.amountSentToTrader = _unregisterTrade(
                _trade,
                v.profitP,
                _orderType,
                v.executionPriceRaw,
                v.liqPrice,
                _a.current
            );
            v.collateralPriceUsd = _getCollateralPriceUsd(_trade.collateralIndex);

            emit ITradingCallbacksUtils.LimitExecuted(
                _a.orderId,
                _trade.user,
                _trade.index,
                0,
                _trade,
                _initiator,
                _orderType,
                v.executionPriceRaw,
                v.executionPrice,
                v.liqPrice,
                v.priceImpact,
                v.profitP,
                v.amountSentToTrader,
                v.collateralPriceUsd,
                v.exactExecution
            );
        } else {
            emit ITradingCallbacksUtils.TriggerOrderCanceled(_a.orderId, _initiator, _orderType, v.cancelReason);
        }
    }

    /**
     * @dev Check ITradingCallbacksUtils interface for documentation
     */
    function updateLeverageCallback(ITradingCallbacks.AggregatorAnswer memory _a) external tradingActivated {
        ITradingStorage.PendingOrder memory order = _getMultiCollatDiamond().getPendingOrder(_a.orderId);

        _validatePendingOrderOpen(order);

        UpdateLeverageLifecycles.executeUpdateLeverage(order, _a);
    }

    /**
     * @dev Check ITradingCallbacksUtils interface for documentation
     */
    function increasePositionSizeMarketCallback(
        ITradingCallbacks.AggregatorAnswer memory _a
    ) external tradingActivated {
        ITradingStorage.PendingOrder memory order = _getMultiCollatDiamond().getPendingOrder(_a.orderId);

        _validatePendingOrderOpen(order);

        UpdatePositionSizeLifecycles.executeIncreasePositionSizeMarket(order, _a);
    }

    /**
     * @dev Check ITradingCallbacksUtils interface for documentation
     */
    function decreasePositionSizeMarketCallback(
        ITradingCallbacks.AggregatorAnswer memory _a
    ) external tradingActivatedOrCloseOnly {
        ITradingStorage.PendingOrder memory order = _getMultiCollatDiamond().getPendingOrder(_a.orderId);

        _validatePendingOrderOpen(order);

        UpdatePositionSizeLifecycles.executeDecreasePositionSizeMarket(order, _a);
    }

    /**
     * @dev Check ITradingCallbacksUtils interface for documentation
     */
    function pnlWithdrawalCallback(ITradingCallbacks.AggregatorAnswer memory _a) external tradingActivatedOrCloseOnly {
        ITradingStorage.PendingOrder memory order = _getMultiCollatDiamond().getPendingOrder(_a.orderId);

        _validatePendingOrderOpen(order);

        TradeManagementCallbacksUtils.executePnlWithdrawalCallback(order, _a);
    }

    /**
     * @dev Check ITradingCallbacksUtils interface for documentation
     */
    function manualHoldingFeesRealizationCallback(
        ITradingCallbacks.AggregatorAnswer memory _a
    ) external tradingActivatedOrCloseOnly {
        ITradingStorage.PendingOrder memory order = _getMultiCollatDiamond().getPendingOrder(_a.orderId);

        _validatePendingOrderOpen(order);

        TradeManagementCallbacksUtils.executeManualHoldingFeesRealizationCallback(order, _a);
    }

    /**
     * @dev Check ITradingCallbacksUtils interface for documentation
     */
    function manualNegativePnlRealizationCallback(
        ITradingCallbacks.AggregatorAnswer memory _a
    ) external tradingActivatedOrCloseOnly {
        ITradingStorage.PendingOrder memory order = _getMultiCollatDiamond().getPendingOrder(_a.orderId);

        _validatePendingOrderOpen(order);

        TradeManagementCallbacksUtils.executeManualNegativePnlRealizationCallback(order, _a);
    }

    /**
     * @dev Check ITradingCallbacksUtils interface for documentation
     */
    function getVaultClosingFeeP() external view returns (uint8) {
        return _getStorage().vaultClosingFeeP;
    }

    /**
     * @dev Check ITradingCallbacksUtils interface for documentation
     */
    function getPendingGovFeesCollateral(uint8 _collateralIndex) external view returns (uint256) {
        return _getStorage().pendingGovFees[_collateralIndex];
    }

    /**
     * @dev Check ITradingCallbacksUtils interface for documentation
     */
    function validateTriggerOpenOrderCallback(
        ITradingStorage.Id memory _tradeId,
        ITradingStorage.PendingOrderType _orderType,
        uint64 _open,
        uint64 _high,
        uint64 _low,
        uint64 _currentPairPrice
    ) public view returns (ITradingStorage.Trade memory t, ITradingCallbacks.Values memory v) {
        t = _getTrade(_tradeId.user, _tradeId.index);
        v = _validateTriggerOpenOrderCallback(t, _orderType, _open, _high, _low, _currentPairPrice);
    }

    /**
     * @dev Internal function for validateTriggerOpenOrderCallback that accepts `_trade`
     * @dev Check ITradingCallbacksUtils interface for documentation
     */
    function _validateTriggerOpenOrderCallback(
        ITradingStorage.Trade memory _trade,
        ITradingStorage.PendingOrderType _orderType,
        uint64 _open,
        uint64 _high,
        uint64 _low,
        uint64 _currentPairPrice
    ) internal view returns (ITradingCallbacks.Values memory v) {
        if (
            _orderType != ITradingStorage.PendingOrderType.LIMIT_OPEN &&
            _orderType != ITradingStorage.PendingOrderType.STOP_OPEN
        ) revert IGeneralErrors.WrongOrderType();

        // Return early if trade is not open
        if (!_trade.isOpen) {
            v.cancelReason = ITradingCallbacks.CancelReason.NO_TRADE;
            return v;
        }

        // Check exact execution using market prices
        uint64 highPrice = TradingCommonUtils.getMarketPrice(_trade.collateralIndex, _trade.pairIndex, _high);
        uint64 lowPrice = TradingCommonUtils.getMarketPrice(_trade.collateralIndex, _trade.pairIndex, _low);

        bool exactExecution = (highPrice >= _trade.openPrice && lowPrice <= _trade.openPrice);

        uint256 executionPriceRaw = exactExecution
            ? TradingCommonUtils.deriveOraclePrice(_trade.collateralIndex, _trade.pairIndex, uint64(_trade.openPrice))
            : _open;

        v = _openTradePrep(
            _trade,
            executionPriceRaw,
            _getTradeInfo(_trade.user, _trade.index).maxSlippageP,
            _currentPairPrice
        );

        v.exactExecution = exactExecution;
        v.executionPriceRaw = executionPriceRaw;
        v.executionPrice = v.priceImpact.priceAfterImpact;

        if (!v.exactExecution) {
            // Use market price for trigger validation for non-exact executions
            uint64 openPrice = TradingCommonUtils.getMarketPrice(_trade.collateralIndex, _trade.pairIndex, _open);

            if (
                _trade.tradeType == ITradingStorage.TradeType.STOP
                    ? (_trade.long ? openPrice < _trade.openPrice : openPrice > _trade.openPrice)
                    : (_trade.long ? openPrice > _trade.openPrice : openPrice < _trade.openPrice)
            ) v.cancelReason = ITradingCallbacks.CancelReason.NOT_HIT;
        }
    }

    /**
     * @dev Check ITradingCallbacksUtils interface for documentation
     */
    function validateTriggerCloseOrderCallback(
        ITradingStorage.Id memory _tradeId,
        ITradingStorage.PendingOrderType _orderType,
        uint64 _open,
        uint64 _high,
        uint64 _low,
        uint64 _currentPairPrice
    ) public view returns (ITradingStorage.Trade memory t, ITradingCallbacks.Values memory v) {
        t = _getTrade(_tradeId.user, _tradeId.index);
        v = _validateTriggerCloseOrderCallback(t, _orderType, _open, _high, _low, _currentPairPrice);
    }

    /**
     * @dev Internal function for validateTriggerCloseOrderCallback that accepts `_trade`
     * @dev Check ITradingCallbacksUtils interface for documentation
     */
    function _validateTriggerCloseOrderCallback(
        ITradingStorage.Trade memory _trade,
        ITradingStorage.PendingOrderType _orderType,
        uint64 _open,
        uint64 _high,
        uint64 _low,
        uint64 _currentPairPrice
    ) public view returns (ITradingCallbacks.Values memory v) {
        if (
            _orderType != ITradingStorage.PendingOrderType.TP_CLOSE &&
            _orderType != ITradingStorage.PendingOrderType.SL_CLOSE &&
            _orderType != ITradingStorage.PendingOrderType.LIQ_CLOSE
        ) revert IGeneralErrors.WrongOrderType();

        ITradingStorage.TradeInfo memory i = _getTradeInfo(_trade.user, _trade.index);

        v.cancelReason = !_trade.isOpen ? ITradingCallbacks.CancelReason.NO_TRADE : ITradingCallbacks.CancelReason.NONE;

        // Return early if trade is not open
        if (v.cancelReason != ITradingCallbacks.CancelReason.NONE) return v;

        v.liqPrice = TradingCommonUtils.getTradeLiquidationPrice(_trade, _currentPairPrice);
        uint256 triggerPrice = _orderType == ITradingStorage.PendingOrderType.TP_CLOSE
            ? _trade.tp
            : (_orderType == ITradingStorage.PendingOrderType.SL_CLOSE ? _trade.sl : v.liqPrice);

        // Convert prices to market prices for TP/SL orders (not liquidations)
        uint64 openPrice = _open;
        uint64 highPrice = _high;
        uint64 lowPrice = _low;

        if (_orderType != ITradingStorage.PendingOrderType.LIQ_CLOSE) {
            openPrice = TradingCommonUtils.getMarketPrice(_trade.collateralIndex, _trade.pairIndex, _open);
            highPrice = TradingCommonUtils.getMarketPrice(_trade.collateralIndex, _trade.pairIndex, _high);
            lowPrice = TradingCommonUtils.getMarketPrice(_trade.collateralIndex, _trade.pairIndex, _low);
        }

        v.exactExecution = triggerPrice > 0 && lowPrice <= triggerPrice && highPrice >= triggerPrice;
        v.executionPriceRaw = v.exactExecution
            ? (
                _orderType != ITradingStorage.PendingOrderType.LIQ_CLOSE
                    ? TradingCommonUtils.deriveOraclePrice(
                        _trade.collateralIndex,
                        _trade.pairIndex,
                        uint64(triggerPrice)
                    )
                    : triggerPrice
            )
            : _open;

        // Apply closing spread and price impact for TPs and SLs, not liquidations (because trade value is 0 already)
        if (_orderType != ITradingStorage.PendingOrderType.LIQ_CLOSE) {
            v.priceImpact = _getTradeClosingPriceImpact(_trade, v.executionPriceRaw, _currentPairPrice, true);
            v.executionPrice = v.priceImpact.priceAfterImpact;
        } else {
            v.executionPrice = v.executionPriceRaw;
        }

        uint256 maxSlippage = (triggerPrice *
            (i.maxSlippageP > 0 ? i.maxSlippageP : ConstantsUtils.DEFAULT_MAX_CLOSING_SLIPPAGE_P)) /
            100 /
            1e3;

        v.cancelReason = (v.exactExecution ||
            (_orderType == ITradingStorage.PendingOrderType.LIQ_CLOSE &&
                (_trade.long ? _open <= v.liqPrice : _open >= v.liqPrice)) ||
            (_orderType == ITradingStorage.PendingOrderType.TP_CLOSE &&
                _trade.tp > 0 &&
                (_trade.long ? openPrice >= _trade.tp : openPrice <= _trade.tp)) ||
            (_orderType == ITradingStorage.PendingOrderType.SL_CLOSE &&
                _trade.sl > 0 &&
                (_trade.long ? openPrice <= _trade.sl : openPrice >= _trade.sl)))
            ? (
                _orderType != ITradingStorage.PendingOrderType.LIQ_CLOSE &&
                    (
                        _trade.long
                            ? v.executionPrice < triggerPrice - maxSlippage
                            : v.executionPrice > triggerPrice + maxSlippage
                    )
                    ? ITradingCallbacks.CancelReason.SLIPPAGE
                    : ITradingCallbacks.CancelReason.NONE
            )
            : ITradingCallbacks.CancelReason.NOT_HIT;
    }

    /**
     * @dev Returns storage slot to use when fetching storage relevant to library
     */
    function _getSlot() internal pure returns (uint256) {
        return StorageUtils.GLOBAL_TRADING_CALLBACKS_SLOT;
    }

    /**
     * @dev Returns storage pointer for storage struct in diamond contract, at defined slot
     */
    function _getStorage() internal pure returns (ITradingCallbacks.TradingCallbacksStorage storage s) {
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
     * @dev Checks if trading is fully activated (not paused or close-only)
     */
    function _tradingActivated() private view {
        if (_getMultiCollatDiamond().getTradingActivated() != ITradingStorage.TradingActivated.ACTIVATED)
            revert IGeneralErrors.Paused();
    }

    /**
     * @dev Checks if trading is activated or close-only (not paused)
     */
    function _tradingActivatedOrCloseOnly() private view {
        if (_getMultiCollatDiamond().getTradingActivated() == ITradingStorage.TradingActivated.PAUSED)
            revert IGeneralErrors.Paused();
    }

    /**
     * @dev Registers a trade in storage, and handles all fees and rewards
     * @param _trade Trade to register
     * @param _openingFeeCollateral opening fee in collateral token (collateral precision)
     * @param _positionSizeToken position size in tokens (1e18)
     * @param _orderType Corresponding pending order type
     * @param _currentPairPrice current pair price (1e10)
     * @return Final registered trade
     */
    function _registerTrade(
        ITradingStorage.Trade memory _trade,
        uint256 _openingFeeCollateral,
        uint256 _positionSizeToken,
        ITradingStorage.PendingOrderType _orderType,
        uint64 _currentPairPrice
    ) internal returns (ITradingStorage.Trade memory) {
        // 1. Store final trade in storage contract
        ITradingStorage.TradeInfo memory tradeInfo;
        _trade.positionSizeToken = uint160(_positionSizeToken);
        _trade = _getMultiCollatDiamond().storeTrade(_trade, tradeInfo, _currentPairPrice);

        // 2.1 Charge opening fee
        _getMultiCollatDiamond().realizeTradingFeesOnOpenTrade(
            _trade.user,
            _trade.index,
            _openingFeeCollateral,
            _currentPairPrice
        );

        // 2.2 Distribute opening fee to recipients
        TradingCommonUtils.processFees(
            _trade,
            TradingCommonUtils.getPositionSizeCollateral(_trade.collateralAmount, _trade.leverage),
            _orderType,
            _openingFeeCollateral
        );

        return _trade;
    }

    /**
     * @dev Unregisters a trade from storage, and handles all fees and rewards
     * @param _trade Trade to unregister
     * @param _profitP Profit percentage (1e10)
     * @param _orderType pending order type
     * @param _executionPriceRaw execution price without closing spread/impact (1e10)
     * @param _liqPrice trade liquidation price (1e10)
     * @param _currentPairPrice current pair price (1e10)
     * @return tradeValueCollateral Amount of collateral sent to trader, collateral + pnl (collateral precision)
     */
    function _unregisterTrade(
        ITradingStorage.Trade memory _trade,
        int256 _profitP,
        ITradingStorage.PendingOrderType _orderType,
        uint256 _executionPriceRaw,
        uint256 _liqPrice,
        uint64 _currentPairPrice
    ) internal returns (uint256 tradeValueCollateral) {
        // 1. Mark trade as closed, realize pending holding fees, handle OI deltas
        //  Has to be called first for funding fees to be stored as trading fees, so available collateral in diamond calculation is accurate
        _getMultiCollatDiamond().closeTrade(
            ITradingStorage.Id({user: _trade.user, index: _trade.index}),
            _profitP > 0,
            _currentPairPrice
        );

        // 2. Calculate closing fees (refresh fee tier first)
        TradingCommonUtils.updateFeeTierPoints(_trade.collateralIndex, _trade.user, _trade.pairIndex, 0);
        uint256 positionSizeCollateral = TradingCommonUtils.getPositionSizeCollateral(
            _trade.collateralAmount,
            _trade.leverage
        );
        uint256 closingFeesCollateral = _orderType == ITradingStorage.PendingOrderType.LIQ_CLOSE
            ? TradingCommonUtils.getTotalTradeLiqFeesCollateral(_trade.pairIndex, _trade.collateralAmount)
            : TradingCommonUtils.getTotalTradeFeesCollateral(
                _trade.collateralIndex,
                _trade.user,
                _trade.pairIndex,
                positionSizeCollateral,
                _trade.isCounterTrade
            );

        // 3.1 Calculate net trade value (with pnl, closing fees, realized fees, realized pnl)
        // Note: there's no pending holding fees at that point since they were realized with closeTrade()
        tradeValueCollateral = TradingCommonUtils.getTradeValueCollateral(
            _trade,
            _profitP,
            closingFeesCollateral,
            _currentPairPrice
        );

        // 3.2 If trade is liquidated, set trade value to 0
        tradeValueCollateral = (_trade.long ? _executionPriceRaw <= _liqPrice : _executionPriceRaw >= _liqPrice)
            ? 0
            : tradeValueCollateral; /// @dev Only check with execution price not current price otherwise SL lookbacks wouldn't work (would be liquidated)

        // 4. Handle collateral transfers between diamond, vault, and trader
        int256 availableCollateralInDiamond = int256(
            TradingCommonUtils.getTradeAvailableCollateralInDiamond(_trade.user, _trade.index, _trade.collateralAmount)
        ) - int256(closingFeesCollateral);
        TradingCommonUtils.handleTradeValueTransfer(_trade, int256(tradeValueCollateral), availableCollateralInDiamond);

        // 5. Process closing fees
        TradingCommonUtils.processFees(_trade, positionSizeCollateral, _orderType, closingFeesCollateral);

        // 6. Store realized trading fees for UI (since we don't call realizeTradingFeesOnOpenTrade, closing fee is taken from amount sent to trader)
        _getMultiCollatDiamond().storeUiRealizedTradingFeesCollateral(_trade.user, _trade.index, closingFeesCollateral);
    }

    /**
     * @dev Makes pre-trade checks: price impact, if trade should be cancelled based on parameters like: PnL, leverage, slippage, etc.
     * @param _trade trade input
     * @param _executionPriceRaw execution price without closing spread/impact (1e10 precision)
     * @param _maxSlippageP max slippage % (1e3 precision)
     * @param _currentPairPrice current pair price (1e10)
     */
    function _openTradePrep(
        ITradingStorage.Trade memory _trade,
        uint256 _executionPriceRaw,
        uint256 _maxSlippageP,
        uint64 _currentPairPrice
    ) internal view returns (ITradingCallbacks.Values memory v) {
        uint256 positionSizeCollateral = TradingCommonUtils.getPositionSizeCollateral(
            _trade.collateralAmount,
            _trade.leverage
        );

        if (_trade.isCounterTrade) {
            (v.cancelReason, v.collateralToReturn, v.newCollateralAmount) = _validateCounterTrade(
                _trade,
                positionSizeCollateral,
                _currentPairPrice
            );

            positionSizeCollateral = TradingCommonUtils.getPositionSizeCollateral(
                v.newCollateralAmount,
                _trade.leverage
            );
        }

        v.priceImpact = TradingCommonUtils.getTradeOpeningPriceImpact(
            ITradingCommonUtils.TradePriceImpactInput(_trade, _executionPriceRaw, positionSizeCollateral, 0, true)
        );

        v.openingFeeCollateral = TradingCommonUtils.getTotalTradeFeesCollateral(
            _trade.collateralIndex,
            _trade.user,
            _trade.pairIndex,
            positionSizeCollateral,
            _trade.isCounterTrade
        );

        v.liqPrice = TradingCommonUtils.getTradeLiquidationPriceBeforeOpened(
            _trade,
            int256(v.openingFeeCollateral),
            v.newCollateralAmount > 0 ? v.newCollateralAmount : _trade.collateralAmount,
            v.priceImpact.priceAfterImpact
        );

        uint256 maxSlippage = (uint256(_trade.openPrice) * _maxSlippageP) / 100 / 1e3;

        v.cancelReason = (
            _trade.long
                ? v.priceImpact.priceAfterImpact > _trade.openPrice + maxSlippage
                : v.priceImpact.priceAfterImpact < _trade.openPrice - maxSlippage
        )
            ? ITradingCallbacks.CancelReason.SLIPPAGE
            : (_trade.tp > 0 &&
                (
                    _trade.long
                        ? v.priceImpact.priceAfterImpact >= _trade.tp
                        : v.priceImpact.priceAfterImpact <= _trade.tp
                ))
                ? ITradingCallbacks.CancelReason.TP_REACHED
                : (_trade.sl > 0 && (_trade.long ? _executionPriceRaw <= _trade.sl : _executionPriceRaw >= _trade.sl))
                    ? ITradingCallbacks.CancelReason.SL_REACHED
                    : (_trade.long ? _currentPairPrice <= v.liqPrice : _currentPairPrice >= v.liqPrice)
                        ? ITradingCallbacks.CancelReason.LIQ_REACHED
                        : !TradingCommonUtils.isWithinExposureLimits(
                            _trade.collateralIndex,
                            _trade.pairIndex,
                            _trade.long,
                            positionSizeCollateral,
                            _currentPairPrice
                        )
                            ? ITradingCallbacks.CancelReason.EXPOSURE_LIMITS
                            : TradingCommonUtils.getNegativePnlFromOpeningPriceImpactP(
                                v.priceImpact.fixedSpreadP,
                                v.priceImpact.cumulVolPriceImpactP,
                                _trade.leverage,
                                _trade.long
                            ) > int256(ConstantsUtils.MAX_OPEN_NEGATIVE_PNL_P)
                                ? ITradingCallbacks.CancelReason.PRICE_IMPACT
                                : _trade.leverage > _getMultiCollatDiamond().pairMaxLeverage(_trade.pairIndex)
                                    ? ITradingCallbacks.CancelReason.MAX_LEVERAGE
                                    : v.cancelReason;
    }

    /**
     * @dev Reverts if pending order is not open
     * @param _order Pending order
     */
    function _validatePendingOrderOpen(ITradingStorage.PendingOrder memory _order) internal pure {
        if (!_order.isOpen) revert ITradingCallbacksUtils.PendingOrderNotOpen();
    }

    /**
     * @dev Validates counter trade
     * @param _trade counter trade
     * @param _positionSizeCollateral position size in collateral tokens (collateral precision)
     * @param _currentPairPrice current pair price (1e10)
     */
    function _validateCounterTrade(
        ITradingStorage.Trade memory _trade,
        uint256 _positionSizeCollateral,
        uint64 _currentPairPrice
    )
        internal
        view
        returns (ITradingCallbacks.CancelReason cancelReason, uint256 collateralToReturn, uint120 newCollateralAmount)
    {
        (bool isValidated, uint256 exceedingPositionSizeCollateral) = TradingCommonUtils.validateCounterTrade(
            _trade,
            _positionSizeCollateral,
            _currentPairPrice
        );

        newCollateralAmount = _trade.collateralAmount;

        if (isValidated) {
            collateralToReturn = Math.mulDiv(exceedingPositionSizeCollateral, 1e3, _trade.leverage, Math.Rounding.Up);
            newCollateralAmount -= uint120(collateralToReturn);

            // Make sure new trade collateral is still > 5x min fee otherwise cancel whole trade
            if (
                newCollateralAmount <
                TradingCommonUtils.getPairMinOpeningCollateral(_trade.collateralIndex, _trade.pairIndex)
            ) {
                isValidated = false;
            }
        }

        cancelReason = isValidated
            ? ITradingCallbacks.CancelReason.NONE
            : ITradingCallbacks.CancelReason.COUNTER_TRADE_CANCELED;
    }

    /**
     * @dev Returns pending order from storage
     * @param _orderId Order ID
     * @return Pending order
     */
    function _getPendingOrder(
        ITradingStorage.Id memory _orderId
    ) internal view returns (ITradingStorage.PendingOrder memory) {
        return _getMultiCollatDiamond().getPendingOrder(_orderId);
    }

    /**
     * @dev Returns collateral price in USD
     * @param _collateralIndex Collateral index
     * @return Collateral price in USD
     */
    function _getCollateralPriceUsd(uint8 _collateralIndex) internal view returns (uint256) {
        return _getMultiCollatDiamond().getCollateralPriceUsd(_collateralIndex);
    }

    /**
     * @dev Returns trade from storage
     * @param _trader Trader address
     * @param _index Trade index
     * @return Trade
     */
    function _getTrade(address _trader, uint32 _index) internal view returns (ITradingStorage.Trade memory) {
        return TradingCommonUtils.getTrade(_trader, _index);
    }

    /**
     * @dev Returns trade info from storage
     * @param _trader Trader address
     * @param _index Trade index
     * @return TradeInfo
     */
    function _getTradeInfo(address _trader, uint32 _index) internal view returns (ITradingStorage.TradeInfo memory) {
        return TradingCommonUtils.getTradeInfo(_trader, _index);
    }

    /**
     * @dev Internal wrapper for `TradingCommonUtils.getTradeOpeningPriceImpact`. Avoids stack too deep.
     * @param _trade Trade
     * @param _oraclePrice the oracle price (1e10)
     * @param _currentPairPrice the current pair price (1e10)
     * @param _useCumulativeVolPriceImpact whether to use cumulative volume price impact
     * @return output
     */
    function _getTradeClosingPriceImpact(
        ITradingStorage.Trade memory _trade,
        uint256 _oraclePrice,
        uint64 _currentPairPrice,
        bool _useCumulativeVolPriceImpact
    ) internal view returns (ITradingCommonUtils.TradePriceImpact memory output) {
        (output, ) = TradingCommonUtils.getTradeClosingPriceImpact(
            ITradingCommonUtils.TradePriceImpactInput(
                _trade,
                _oraclePrice,
                TradingCommonUtils.getPositionSizeCollateral(_trade.collateralAmount, _trade.leverage),
                _currentPairPrice,
                _useCumulativeVolPriceImpact
            )
        );
    }
}
