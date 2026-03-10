// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../interfaces/IGNSMultiCollatDiamond.sol";

import "./StorageUtils.sol";
import "./AddressStoreUtils.sol";
import "./TradingCommonUtils.sol";

/**
 * @dev GNSTradingCallbacks facet external library #2
 */
library TradeManagementCallbacksUtils {
    /**
     * @dev Executes pending order callback for pnl withdrawal
     * @param _order Pending order
     * @param _a Aggregator answer
     */
    function executePnlWithdrawalCallback(
        ITradingStorage.PendingOrder memory _order,
        ITradingCallbacks.AggregatorAnswer memory _a
    ) external {
        ITradingCallbacks.PnlWithdrawalValues memory v;

        v.trade = _getTrade(_order.trade.user, _order.trade.index);
        v.currentPairPrice = _a.current;

        if (!v.trade.isOpen) return;

        TradingCommonUtils.updateFeeTierPoints(v.trade.collateralIndex, v.trade.user, v.trade.pairIndex, 0);

        v.positionSizeCollateral = TradingCommonUtils.getPositionSizeCollateral(
            v.trade.collateralAmount,
            v.trade.leverage
        );

        (v.priceImpact, ) = TradingCommonUtils.getTradeClosingPriceImpact(
            ITradingCommonUtils.TradePriceImpactInput(
                v.trade,
                v.currentPairPrice,
                v.positionSizeCollateral,
                v.currentPairPrice,
                true
            )
        );
        v.pnlPercent = TradingCommonUtils.getPnlPercent(
            v.trade.openPrice,
            v.priceImpact.priceAfterImpact,
            v.trade.long,
            v.trade.leverage
        );

        v.withdrawablePositivePnlCollateral =
            int256(
                TradingCommonUtils.getTradeValueCollateral(
                    v.trade,
                    v.pnlPercent,
                    TradingCommonUtils.getTotalTradeFeesCollateral(
                        v.trade.collateralIndex,
                        v.trade.user,
                        v.trade.pairIndex,
                        v.positionSizeCollateral,
                        v.trade.isCounterTrade
                    ),
                    v.currentPairPrice
                )
            ) -
            int256(uint256(v.trade.collateralAmount));

        v.pnlInputCollateral = _order.trade.collateralAmount;

        v.withdrawablePositivePnlCollateralUint = v.withdrawablePositivePnlCollateral > 0
            ? uint256(v.withdrawablePositivePnlCollateral)
            : 0;

        v.pnlWithdrawnCollateral = v.pnlInputCollateral > v.withdrawablePositivePnlCollateralUint
            ? v.withdrawablePositivePnlCollateralUint
            : v.pnlInputCollateral;

        if (v.pnlWithdrawnCollateral > 0) {
            _getMultiCollatDiamond().realizePnlOnOpenTrade(
                v.trade.user,
                v.trade.index,
                -int256(v.pnlWithdrawnCollateral)
            );

            TradingCommonUtils.receiveCollateralFromVault(v.trade.collateralIndex, v.pnlWithdrawnCollateral);
            TradingCommonUtils.transferCollateralTo(v.trade.collateralIndex, v.trade.user, v.pnlWithdrawnCollateral);

            _getMultiCollatDiamond().storeUiPnlWithdrawnCollateral(
                v.trade.user,
                v.trade.index,
                v.pnlWithdrawnCollateral
            );
        }

        v.finalGovFeeCollateral = _getMultiCollatDiamond().realizeTradingFeesOnOpenTrade(
            v.trade.user,
            v.trade.index,
            TradingCommonUtils.getMinGovFeeCollateral(v.trade.collateralIndex, v.trade.user, v.trade.pairIndex),
            v.currentPairPrice
        );
        TradingCommonUtils.distributeExactGovFeeCollateral(
            v.trade.collateralIndex,
            v.trade.user,
            v.finalGovFeeCollateral
        );

        emit ITradingCallbacksUtils.TradePositivePnlWithdrawn(
            _a.orderId,
            v.trade.collateralIndex,
            v.trade.user,
            v.trade.index,
            v.priceImpact,
            v.pnlPercent,
            v.withdrawablePositivePnlCollateral,
            v.currentPairPrice,
            v.pnlInputCollateral,
            v.pnlWithdrawnCollateral
        );
    }

    /**
     * @dev Executes pending order callback for holding fees realization
     * @param _order Pending order
     * @param _a Aggregator answer
     */
    function executeManualHoldingFeesRealizationCallback(
        ITradingStorage.PendingOrder memory _order,
        ITradingCallbacks.AggregatorAnswer memory _a
    ) external {
        ITradingStorage.Trade memory trade = _getTrade(_order.trade.user, _order.trade.index);

        if (!trade.isOpen) return;

        _getMultiCollatDiamond().realizeHoldingFeesOnOpenTrade(trade.user, trade.index, _a.current);
        _getMultiCollatDiamond().storeTradeInitialAccFees(
            trade.user,
            trade.index,
            trade.collateralIndex,
            trade.pairIndex,
            trade.long,
            _a.current
        );
        _getMultiCollatDiamond().handleTradeBorrowingCallback(
            trade.collateralIndex,
            trade.user,
            trade.pairIndex,
            trade.index,
            0, // no OI change
            false, // doesn't matter since pos size = 0
            trade.long,
            _a.current
        );

        emit ITradingCallbacksUtils.TradeHoldingFeesManuallyRealized(
            _a.orderId,
            trade.collateralIndex,
            trade.user,
            trade.index,
            _a.current
        );
    }

    /**
     * @dev Executes pending order callback for negative pnl realization
     * @param _order Pending order
     * @param _a Aggregator answer
     */
    function executeManualNegativePnlRealizationCallback(
        ITradingStorage.PendingOrder memory _order,
        ITradingCallbacks.AggregatorAnswer memory _a
    ) external {
        ITradingStorage.Trade memory trade = _getTrade(_order.trade.user, _order.trade.index);

        if (!trade.isOpen) return;

        (ITradingCommonUtils.TradePriceImpact memory priceImpact, ) = TradingCommonUtils.getTradeClosingPriceImpact(
            ITradingCommonUtils.TradePriceImpactInput(
                trade,
                _a.current,
                TradingCommonUtils.getPositionSizeCollateral(trade.collateralAmount, trade.leverage),
                _a.current,
                false // don't use cumulative volume price impact
            )
        );

        IFundingFees.TradeFeesData memory tradeFeesData = _getMultiCollatDiamond().getTradeFeesData(
            trade.user,
            trade.index
        );
        int256 totalPnlCollateral = TradingCommonUtils.getTradeUnrealizedRawPnlCollateral(
            trade,
            priceImpact.priceAfterImpact
        ) +
            tradeFeesData.realizedPnlCollateral +
            int256(uint256(tradeFeesData.alreadyTransferredNegativePnlCollateral));

        uint256 totalNegativePnlCollateral = totalPnlCollateral < 0 ? uint256(-totalPnlCollateral) : uint256(0);

        uint128 existingManuallyRealizedNegativePnlCollateral = tradeFeesData.manuallyRealizedNegativePnlCollateral;
        uint256 newManuallyRealizedNegativePnlCollateral = existingManuallyRealizedNegativePnlCollateral;

        if (totalNegativePnlCollateral > existingManuallyRealizedNegativePnlCollateral) {
            uint256 maxRealizableNegativePnlCollateral = TradingCommonUtils.getTradeAvailableCollateralInDiamond(
                trade.user,
                trade.index,
                trade.collateralAmount
            );

            uint256 negativePnlToRealizeCollateral = totalNegativePnlCollateral -
                existingManuallyRealizedNegativePnlCollateral;

            negativePnlToRealizeCollateral = negativePnlToRealizeCollateral > maxRealizableNegativePnlCollateral
                ? maxRealizableNegativePnlCollateral
                : negativePnlToRealizeCollateral;

            TradingCommonUtils.transferCollateralToVault(
                trade.collateralIndex,
                negativePnlToRealizeCollateral,
                trade.user,
                false // don't burn unrealized pnl since it's not final
            );

            newManuallyRealizedNegativePnlCollateral += negativePnlToRealizeCollateral;
        } else {
            uint256 realizedNegativePnlToCancelCollateral = existingManuallyRealizedNegativePnlCollateral -
                totalNegativePnlCollateral;

            TradingCommonUtils.receiveCollateralFromVault(trade.collateralIndex, realizedNegativePnlToCancelCollateral);

            newManuallyRealizedNegativePnlCollateral -= realizedNegativePnlToCancelCollateral;
        }

        _getMultiCollatDiamond().storeManuallyRealizedNegativePnlCollateral(
            trade.user,
            trade.index,
            newManuallyRealizedNegativePnlCollateral
        );

        emit ITradingCallbacksUtils.TradeNegativePnlManuallyRealized(
            _a.orderId,
            trade.collateralIndex,
            trade.user,
            trade.index,
            totalNegativePnlCollateral,
            existingManuallyRealizedNegativePnlCollateral,
            newManuallyRealizedNegativePnlCollateral,
            _a.current
        );
    }

    /**
     * @dev Returns current address as multi-collateral diamond interface to call other facets functions.
     */
    function _getMultiCollatDiamond() internal view returns (IGNSMultiCollatDiamond) {
        return IGNSMultiCollatDiamond(address(this));
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
}
