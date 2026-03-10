// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import "../interfaces/IGNSMultiCollatDiamond.sol";

import "./StorageUtils.sol";
import "./TradingCommonUtils.sol";

/**
 * @dev GNSFundingFees facet external library
 */
library FundingFeesUtils {
    uint256 constant MAX_BORROWING_RATE_PER_SECOND = 317097; // => 1,000% APR (1e10)
    uint256 constant MAX_FUNDING_RATE_PER_SECOND = 3170979; // 10,000% APR (1e10)
    uint256 constant FUNDING_APR_MULTIPLIER_CAP = 100 * 1e20; // Smaller side can earn up to 100x more APR than the dominant side
    int256 constant ONE_YEAR = 365 days; // 1 year in seconds

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function setMaxSkewCollateral(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex,
        uint80[] calldata _maxSkewCollateral
    ) external {
        if (_collateralIndex.length != _pairIndex.length || _pairIndex.length != _maxSkewCollateral.length)
            revert IGeneralErrors.InvalidInputLength();

        for (uint256 i = 0; i < _collateralIndex.length; ++i) {
            _getStorage().pairGlobalParams[_collateralIndex[i]][_pairIndex[i]].maxSkewCollateral = _maxSkewCollateral[
                i
            ];

            emit IFundingFeesUtils.MaxSkewCollateralUpdated(_collateralIndex[i], _pairIndex[i], _maxSkewCollateral[i]);
        }
    }

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function setSkewCoefficientPerYear(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex,
        uint112[] calldata _skewCoefficientPerYear,
        IPriceAggregator.SignedPairPrices[] calldata _signedPairPrices
    ) external useSignedMarketPrices(_signedPairPrices) {
        if (_collateralIndex.length != _pairIndex.length || _pairIndex.length != _skewCoefficientPerYear.length)
            revert IGeneralErrors.InvalidInputLength();

        for (uint256 i = 0; i < _collateralIndex.length; ++i) {
            if (_skewCoefficientPerYear[i] == 0) revert IGeneralErrors.ZeroValue();

            paramUpdateCallbackWithSignedPrices(
                IFundingFees.PendingParamUpdate(
                    _collateralIndex[i],
                    _pairIndex[i],
                    IFundingFees.ParamUpdateType.SKEW_COEFFICIENT_PER_YEAR,
                    _skewCoefficientPerYear[i]
                )
            );
        }
    }

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function setAbsoluteVelocityPerYearCap(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex,
        uint24[] calldata _absoluteVelocityPerYearCap,
        IPriceAggregator.SignedPairPrices[] calldata _signedPairPrices
    ) external useSignedMarketPrices(_signedPairPrices) {
        if (_collateralIndex.length != _pairIndex.length || _pairIndex.length != _absoluteVelocityPerYearCap.length)
            revert IGeneralErrors.InvalidInputLength();

        for (uint256 i = 0; i < _collateralIndex.length; ++i) {
            if (_absoluteVelocityPerYearCap[i] == 0) revert IGeneralErrors.ZeroValue();

            paramUpdateCallbackWithSignedPrices(
                IFundingFees.PendingParamUpdate(
                    _collateralIndex[i],
                    _pairIndex[i],
                    IFundingFees.ParamUpdateType.ABSOLUTE_VELOCITY_PER_YEAR_CAP,
                    _absoluteVelocityPerYearCap[i]
                )
            );
        }
    }

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function setAbsoluteRatePerSecondCap(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex,
        uint24[] calldata _absoluteRatePerSecondCap,
        IPriceAggregator.SignedPairPrices[] calldata _signedPairPrices
    ) internal useSignedMarketPrices(_signedPairPrices) {
        if (_collateralIndex.length != _pairIndex.length || _pairIndex.length != _absoluteRatePerSecondCap.length)
            revert IGeneralErrors.InvalidInputLength();

        for (uint256 i = 0; i < _collateralIndex.length; ++i) {
            if (_absoluteRatePerSecondCap[i] == 0) revert IGeneralErrors.ZeroValue();
            if (_absoluteRatePerSecondCap[i] > MAX_FUNDING_RATE_PER_SECOND) revert IGeneralErrors.AboveMax();

            paramUpdateCallbackWithSignedPrices(
                IFundingFees.PendingParamUpdate(
                    _collateralIndex[i],
                    _pairIndex[i],
                    IFundingFees.ParamUpdateType.ABSOLUTE_RATE_PER_SECOND_CAP,
                    _absoluteRatePerSecondCap[i]
                )
            );
        }
    }

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function setThetaThresholdUsd(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex,
        uint32[] calldata _thetaThresholdUsd,
        IPriceAggregator.SignedPairPrices[] calldata _signedPairPrices
    ) internal useSignedMarketPrices(_signedPairPrices) {
        if (_collateralIndex.length != _pairIndex.length || _pairIndex.length != _thetaThresholdUsd.length)
            revert IGeneralErrors.InvalidInputLength();

        for (uint256 i = 0; i < _collateralIndex.length; ++i) {
            if (_thetaThresholdUsd[i] == 0) revert IGeneralErrors.ZeroValue();

            paramUpdateCallbackWithSignedPrices(
                IFundingFees.PendingParamUpdate(
                    _collateralIndex[i],
                    _pairIndex[i],
                    IFundingFees.ParamUpdateType.THETA_THRESHOLD_USD,
                    _thetaThresholdUsd[i]
                )
            );
        }
    }

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function setFundingFeesEnabled(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex,
        bool[] calldata _fundingFeesEnabled,
        IPriceAggregator.SignedPairPrices[] calldata _signedPairPrices
    ) internal useSignedMarketPrices(_signedPairPrices) {
        if (_collateralIndex.length != _pairIndex.length || _pairIndex.length != _fundingFeesEnabled.length)
            revert IGeneralErrors.InvalidInputLength();

        for (uint256 i = 0; i < _collateralIndex.length; ++i) {
            paramUpdateCallbackWithSignedPrices(
                IFundingFees.PendingParamUpdate(
                    _collateralIndex[i],
                    _pairIndex[i],
                    IFundingFees.ParamUpdateType.FUNDING_FEES_ENABLED,
                    _fundingFeesEnabled[i] ? 1 : 0
                )
            );
        }
    }

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function setAprMultiplierEnabled(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex,
        bool[] calldata _aprMultiplierEnabled,
        IPriceAggregator.SignedPairPrices[] calldata _signedPairPrices
    ) internal useSignedMarketPrices(_signedPairPrices) {
        if (_collateralIndex.length != _pairIndex.length || _pairIndex.length != _aprMultiplierEnabled.length)
            revert IGeneralErrors.InvalidInputLength();

        for (uint256 i = 0; i < _collateralIndex.length; ++i) {
            paramUpdateCallbackWithSignedPrices(
                IFundingFees.PendingParamUpdate(
                    _collateralIndex[i],
                    _pairIndex[i],
                    IFundingFees.ParamUpdateType.APR_MULTIPLIER_ENABLED,
                    _aprMultiplierEnabled[i] ? 1 : 0
                )
            );
        }
    }

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function setBorrowingRatePerSecondP(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex,
        uint24[] calldata _borrowingRatePerSecondP,
        IPriceAggregator.SignedPairPrices[] calldata _signedPairPrices
    ) external useSignedMarketPrices(_signedPairPrices) {
        if (_collateralIndex.length != _pairIndex.length || _pairIndex.length != _borrowingRatePerSecondP.length)
            revert IGeneralErrors.InvalidInputLength();

        for (uint256 i = 0; i < _collateralIndex.length; ++i) {
            if (_borrowingRatePerSecondP[i] > MAX_BORROWING_RATE_PER_SECOND) revert IGeneralErrors.AboveMax();

            paramUpdateCallbackWithSignedPrices(
                IFundingFees.PendingParamUpdate(
                    _collateralIndex[i],
                    _pairIndex[i],
                    IFundingFees.ParamUpdateType.BORROWING_RATE_PER_SECOND_P,
                    _borrowingRatePerSecondP[i]
                )
            );
        }
    }

    /**
     * @dev Executes param update with signed prices stored in temporary storage
     * @param _paramUpdate param update data
     */
    function paramUpdateCallbackWithSignedPrices(IFundingFees.PendingParamUpdate memory _paramUpdate) public {
        // If temporary/atomic price is not set, `getPairSignedMedianTemporary()` reverts
        uint64 currentPairPrice = _getMultiCollatDiamond().getPairSignedMedianTemporary(_paramUpdate.pairIndex).current;

        if (_paramUpdate.updateType == IFundingFees.ParamUpdateType.BORROWING_PAIR) {
            _getMultiCollatDiamond().borrowingParamUpdateCallback(_paramUpdate, currentPairPrice);
            return;
        }

        if (_paramUpdate.updateType == IFundingFees.ParamUpdateType.BORROWING_RATE_PER_SECOND_P) {
            _storePendingAccBorrowingFees(_paramUpdate.collateralIndex, _paramUpdate.pairIndex, currentPairPrice);
        } else {
            _storePendingAccFundingFees(_paramUpdate.collateralIndex, _paramUpdate.pairIndex, currentPairPrice);
        }

        IFundingFees.FundingParamCallbackInput memory input;
        input.collateralIndex = _paramUpdate.collateralIndex;
        input.pairIndex = _paramUpdate.pairIndex;
        input.newValue = _paramUpdate.newValue;

        if (_paramUpdate.updateType == IFundingFees.ParamUpdateType.SKEW_COEFFICIENT_PER_YEAR)
            _setSkewCoefficientPerYearCallback(input);
        else if (_paramUpdate.updateType == IFundingFees.ParamUpdateType.ABSOLUTE_VELOCITY_PER_YEAR_CAP)
            _setAbsoluteVelocityPerYearCapCallback(input);
        else if (_paramUpdate.updateType == IFundingFees.ParamUpdateType.ABSOLUTE_RATE_PER_SECOND_CAP)
            _setAbsoluteRatePerSecondCapCallback(input);
        else if (_paramUpdate.updateType == IFundingFees.ParamUpdateType.THETA_THRESHOLD_USD)
            _setThetaThresholdUsdCallback(input);
        else if (_paramUpdate.updateType == IFundingFees.ParamUpdateType.FUNDING_FEES_ENABLED)
            _setFundingFeesEnabledCallback(input);
        else if (_paramUpdate.updateType == IFundingFees.ParamUpdateType.APR_MULTIPLIER_ENABLED)
            _setAprMultiplierEnabledCallback(input);
        else if (_paramUpdate.updateType == IFundingFees.ParamUpdateType.BORROWING_RATE_PER_SECOND_P)
            _setBorrowingRatePerSecondPCallback(input);
    }

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function storeTradeInitialAccFees(
        address _trader,
        uint32 _index,
        uint8 _collateralIndex,
        uint16 _pairIndex,
        bool _long,
        uint64 _currentPairPrice
    ) external {
        IFundingFees.FundingFeesStorage storage s = _getStorage();

        (int128 accFundingFeeLongP, int128 accFundingFeeShortP) = _storePendingAccFundingFees(
            _collateralIndex,
            _pairIndex,
            _currentPairPrice
        );
        uint128 accBorrowingFeeP = _storePendingAccBorrowingFees(_collateralIndex, _pairIndex, _currentPairPrice);

        int128 newInitialAccFundingFeeP = _long ? accFundingFeeLongP : accFundingFeeShortP;
        IFundingFees.TradeFeesData storage tradeFeesData = s.tradeFeesData[_trader][_index];

        tradeFeesData.initialAccFundingFeeP = newInitialAccFundingFeeP;
        tradeFeesData.initialAccBorrowingFeeP = accBorrowingFeeP;

        emit IFundingFeesUtils.TradeInitialAccFeesStored(
            _trader,
            _index,
            _collateralIndex,
            _pairIndex,
            _long,
            _currentPairPrice,
            newInitialAccFundingFeeP,
            accBorrowingFeeP
        );
    }

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function realizeHoldingFeesOnOpenTrade(address _trader, uint32 _index, uint64 _currentPairPrice) external {
        IFundingFees.FundingFeesStorage storage s = _getStorage();
        IFundingFees.TradeFeesData storage tradeFeesData = s.tradeFeesData[_trader][_index];
        ITradingStorage.Trade memory trade = TradingCommonUtils.getTrade(_trader, _index);

        IFundingFees.TradeHoldingFees memory holdingFees = getTradePendingHoldingFeesCollateral(
            _trader,
            _index,
            _currentPairPrice
        );

        if (holdingFees.totalFeeCollateral > 0) {
            uint256 holdingFeesCollateral = uint256(holdingFees.totalFeeCollateral);
            uint256 availableCollateralInDiamond = TradingCommonUtils.getTradeAvailableCollateralInDiamond(
                _trader,
                _index,
                trade.collateralAmount
            );

            uint256 amountSentToVaultCollateral = holdingFeesCollateral > availableCollateralInDiamond
                ? availableCollateralInDiamond
                : holdingFeesCollateral;

            TradingCommonUtils.transferFeeToVault(trade.collateralIndex, amountSentToVaultCollateral, trade.user);

            uint128 newRealizedTradingFeesCollateral = tradeFeesData.realizedTradingFeesCollateral +
                uint128(amountSentToVaultCollateral);
            tradeFeesData.realizedTradingFeesCollateral = newRealizedTradingFeesCollateral;

            int128 newRealizedPnlCollateral = tradeFeesData.realizedPnlCollateral -
                int128(int256(holdingFeesCollateral - amountSentToVaultCollateral));
            tradeFeesData.realizedPnlCollateral = newRealizedPnlCollateral;

            emit IFundingFeesUtils.HoldingFeesChargedOnTrade(
                trade.collateralIndex,
                _trader,
                _index,
                _currentPairPrice,
                holdingFees,
                availableCollateralInDiamond,
                amountSentToVaultCollateral,
                newRealizedTradingFeesCollateral,
                newRealizedPnlCollateral
            );
        } else {
            int128 newRealizedPnlCollateral = tradeFeesData.realizedPnlCollateral -
                int128(holdingFees.totalFeeCollateral);

            tradeFeesData.realizedPnlCollateral = newRealizedPnlCollateral;

            emit IFundingFeesUtils.HoldingFeesRealizedOnTrade(
                trade.collateralIndex,
                _trader,
                _index,
                _currentPairPrice,
                holdingFees,
                newRealizedPnlCollateral
            );
        }

        IFundingFees.UiRealizedPnlData storage uiRealizedPnlData = s.tradeUiRealizedPnlData[_trader][_index];
        uiRealizedPnlData.realizedOldBorrowingFeesCollateral += uint128(holdingFees.borrowingFeeCollateral_old);
        uiRealizedPnlData.realizedNewBorrowingFeesCollateral += uint128(holdingFees.borrowingFeeCollateral);
        uiRealizedPnlData.realizedFundingFeesCollateral += int128(holdingFees.fundingFeeCollateral);

        /// @dev This makes the transaction revert in case new available collateral in diamond is < 0
        TradingCommonUtils.getTradeAvailableCollateralInDiamond(_trader, _index, trade.collateralAmount);
    }

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function storeManuallyRealizedNegativePnlCollateral(
        address _trader,
        uint32 _index,
        uint256 _amountCollateral
    ) external {
        IFundingFees.TradeFeesData storage tradeFeesData = _getStorage().tradeFeesData[_trader][_index];

        uint128 newManuallyRealizedNegativePnlCollateral = uint128(_amountCollateral);
        tradeFeesData.manuallyRealizedNegativePnlCollateral = newManuallyRealizedNegativePnlCollateral;

        /// @dev This makes the transaction revert in case new available collateral in diamond is < 0
        TradingCommonUtils.getTradeAvailableCollateralInDiamond(
            _trader,
            _index,
            TradingCommonUtils.getTrade(_trader, _index).collateralAmount
        );

        emit IFundingFeesUtils.ManuallyRealizedNegativePnlCollateralStored(
            _trader,
            _index,
            newManuallyRealizedNegativePnlCollateral
        );
    }

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function realizePnlOnOpenTrade(address _trader, uint32 _index, int256 _pnlCollateral) external {
        // No liquidation check, happens after successful partials which check liquidation already or when withdrawing net positive pnl

        IFundingFees.TradeFeesData storage tradeFeesData = _getStorage().tradeFeesData[_trader][_index];

        int128 newRealizedPnlCollateral = tradeFeesData.realizedPnlCollateral + int128(_pnlCollateral);
        tradeFeesData.realizedPnlCollateral = newRealizedPnlCollateral;

        emit IFundingFeesUtils.PnlRealizedOnOpenTrade(_trader, _index, _pnlCollateral, newRealizedPnlCollateral);
    }

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function realizeTradingFeesOnOpenTrade(
        address _trader,
        uint32 _index,
        uint256 _feesCollateral,
        uint64 _currentPairPrice
    ) external returns (uint256 finalFeesCollateral) {
        IFundingFees.FundingFeesStorage storage s = _getStorage();
        IFundingFees.RealizeTradingFeesValues memory v;

        v.trade = TradingCommonUtils.getTrade(_trader, _index);
        v.liqPrice = TradingCommonUtils.getTradeLiquidationPrice(v.trade, int256(_feesCollateral), _currentPairPrice);

        IFundingFees.TradeFeesData storage tradeFeesData = s.tradeFeesData[_trader][_index];
        v.newRealizedFeesCollateral = tradeFeesData.realizedTradingFeesCollateral;
        v.newRealizedPnlCollateral = tradeFeesData.realizedPnlCollateral;

        // 1. Check if trade can be liquidated after charging trading fee
        if ((v.trade.long && _currentPairPrice <= v.liqPrice) || (!v.trade.long && _currentPairPrice >= v.liqPrice)) {
            TradingCallbacksUtils._unregisterTrade(
                v.trade,
                0,
                ITradingStorage.PendingOrderType.LIQ_CLOSE,
                _currentPairPrice,
                v.liqPrice,
                _currentPairPrice
            );

            uint256 collateralPriceUsd = _getMultiCollatDiamond().getCollateralPriceUsd(v.trade.collateralIndex);

            emit ITradingCallbacksUtils.LimitExecuted(
                ITradingStorage.Id(address(0), 0),
                v.trade.user,
                v.trade.index,
                0,
                v.trade,
                address(0),
                ITradingStorage.PendingOrderType.LIQ_CLOSE,
                _currentPairPrice,
                _currentPairPrice,
                v.liqPrice,
                ITradingCommonUtils.TradePriceImpact(0, 0, 0, 0, 0, 0),
                -100 * 1e10,
                0,
                collateralPriceUsd,
                false
            );
        } else {
            finalFeesCollateral = _feesCollateral;

            // 2. Send fee delta from vault if total realized fees are above trade collateral, so collateral in diamond always >= 0
            uint256 availableCollateralInDiamond = TradingCommonUtils.getTradeAvailableCollateralInDiamond(
                _trader,
                _index,
                v.trade.collateralAmount
            );

            if (finalFeesCollateral > availableCollateralInDiamond) {
                v.amountSentFromVaultCollateral = finalFeesCollateral - availableCollateralInDiamond;
                TradingCommonUtils.receiveCollateralFromVault(v.trade.collateralIndex, v.amountSentFromVaultCollateral);

                v.newRealizedPnlCollateral -= int128(int256(v.amountSentFromVaultCollateral));
                tradeFeesData.realizedPnlCollateral = v.newRealizedPnlCollateral;
            }

            // 3. Register new realized fees
            v.newRealizedFeesCollateral += uint128(finalFeesCollateral - v.amountSentFromVaultCollateral);
            tradeFeesData.realizedTradingFeesCollateral = v.newRealizedFeesCollateral;

            /// @dev This makes the transaction revert in case new available collateral in diamond is < 0
            TradingCommonUtils.getTradeAvailableCollateralInDiamond(_trader, _index, v.trade.collateralAmount);

            // 4. Update UI realized pnl mapping
            s.tradeUiRealizedPnlData[_trader][_index].realizedTradingFeesCollateral += uint128(finalFeesCollateral);
        }

        emit IFundingFeesUtils.TradingFeesRealized(
            v.trade.collateralIndex,
            _trader,
            _index,
            _feesCollateral,
            finalFeesCollateral,
            v.newRealizedFeesCollateral,
            v.newRealizedPnlCollateral,
            v.amountSentFromVaultCollateral
        );
    }

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function downscaleTradeFeesData(
        address _trader,
        uint32 _index,
        uint256 _positionSizeCollateralDelta,
        uint256 _existingPositionSizeCollateral,
        uint256 _newCollateralAmount
    ) external {
        if (_positionSizeCollateralDelta > _existingPositionSizeCollateral) revert IGeneralErrors.AboveMax();

        IFundingFees.FundingFeesStorage storage s = _getStorage();
        IFundingFees.TradeFeesData memory data = s.tradeFeesData[_trader][_index];

        bool existingRealizedPnlPositive = data.realizedPnlCollateral > 0;

        data.realizedTradingFeesCollateral =
            data.realizedTradingFeesCollateral -
            uint128(
                (_positionSizeCollateralDelta * data.realizedTradingFeesCollateral) / _existingPositionSizeCollateral
            );

        data.realizedPnlCollateral =
            data.realizedPnlCollateral +
            int128(
                int256(
                    Math.mulDiv(
                        _positionSizeCollateralDelta,
                        uint256(data.realizedPnlCollateral * (existingRealizedPnlPositive ? int256(1) : -1)),
                        _existingPositionSizeCollateral,
                        existingRealizedPnlPositive ? Math.Rounding.Up : Math.Rounding.Down
                    )
                ) * (existingRealizedPnlPositive ? int256(-1) : int256(1))
            );

        data.manuallyRealizedNegativePnlCollateral =
            data.manuallyRealizedNegativePnlCollateral -
            uint128(
                (_positionSizeCollateralDelta * data.manuallyRealizedNegativePnlCollateral) /
                    _existingPositionSizeCollateral
            );

        data.alreadyTransferredNegativePnlCollateral =
            data.alreadyTransferredNegativePnlCollateral -
            uint128(
                (_positionSizeCollateralDelta * data.alreadyTransferredNegativePnlCollateral) /
                    _existingPositionSizeCollateral
            );

        data.virtualAvailableCollateralInDiamond =
            data.virtualAvailableCollateralInDiamond -
            uint128(
                Math.mulDiv(
                    _positionSizeCollateralDelta,
                    data.virtualAvailableCollateralInDiamond,
                    _existingPositionSizeCollateral,
                    Math.Rounding.Up
                )
            );

        s.tradeFeesData[_trader][_index] = data;

        emit IFundingFeesUtils.TradeFeesDataDownscaled(
            _trader,
            _index,
            _positionSizeCollateralDelta,
            _existingPositionSizeCollateral,
            _newCollateralAmount,
            data
        );

        /// @dev Due to rounding errors, it is possible for new collateral available in diamond to be below 0
        // Since we round up everything that decreases available in diamond to make sure we don't overestimate what we have in diamond
        // So we need to compensate with virtual available in diamond in this case (it's a matter of a few wei maximum)
        storeVirtualAvailableCollateralInDiamond(_trader, _index, _newCollateralAmount);
    }

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function storeAlreadyTransferredNegativePnl(address _trader, uint32 _index, uint256 _deltaCollateral) external {
        IFundingFees.TradeFeesData storage tradeFeesData = _getStorage().tradeFeesData[_trader][_index];

        uint128 newAlreadyTransferredNegativePnlCollateral = tradeFeesData.alreadyTransferredNegativePnlCollateral +
            uint128(_deltaCollateral);
        tradeFeesData.alreadyTransferredNegativePnlCollateral = newAlreadyTransferredNegativePnlCollateral;

        /// @dev This makes the transaction revert in case new available collateral in diamond is < 0
        TradingCommonUtils.getTradeAvailableCollateralInDiamond(
            _trader,
            _index,
            TradingCommonUtils.getTrade(_trader, _index).collateralAmount
        );

        emit IFundingFeesUtils.AlreadyTransferredNegativePnlStored(
            _trader,
            _index,
            _deltaCollateral,
            newAlreadyTransferredNegativePnlCollateral
        );
    }

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function storeVirtualAvailableCollateralInDiamond(
        address _trader,
        uint32 _index,
        uint256 _newTradeCollateralAmount
    ) public {
        IFundingFees.TradeFeesData storage tradeFeesData = _getStorage().tradeFeesData[_trader][_index];

        uint256 currentManuallyRealizedNegativePnlCollateral = tradeFeesData.manuallyRealizedNegativePnlCollateral;
        bool manuallyRealizedNegativePnlCollateralCapped = currentManuallyRealizedNegativePnlCollateral >
            _newTradeCollateralAmount;

        // Make sure new manually realized negative pnl <= new trade collateral amount, or it will send too much back from vault if pnl becomes 0
        // Eg. prev collateral = 10, manually realized negative pnl = 6, current pnl = 0, new collateral = 3, new manually realized negative pnl should be 3
        // The 7 withdrawn collateral are split between 4 taken from diamond and 3 from vault, so manually realized negative pnl costed the vault 3 collateral
        // So if we call manual negative pnl realization function, it should only send 3 collateral back from vault, not 6
        if (manuallyRealizedNegativePnlCollateralCapped) {
            tradeFeesData.manuallyRealizedNegativePnlCollateral = uint128(_newTradeCollateralAmount);
        }

        int256 newAvailableCollateralInDiamondRaw = TradingCommonUtils.getTradeAvailableCollateralInDiamondRaw(
            _trader,
            _index,
            _newTradeCollateralAmount
        );

        uint128 virtualAvailableCollateralInDiamondDelta = newAvailableCollateralInDiamondRaw >= 0
            ? 0
            : uint128(uint256(-newAvailableCollateralInDiamondRaw));

        uint128 newVirtualAvailableCollateralInDiamond = tradeFeesData.virtualAvailableCollateralInDiamond +
            virtualAvailableCollateralInDiamondDelta;

        tradeFeesData.virtualAvailableCollateralInDiamond = newVirtualAvailableCollateralInDiamond;

        /// @dev This makes the transaction revert in case new available collateral in diamond is < 0
        TradingCommonUtils.getTradeAvailableCollateralInDiamond(_trader, _index, _newTradeCollateralAmount);

        emit IFundingFeesUtils.VirtualAvailableCollateralInDiamondStored(
            _trader,
            _index,
            _newTradeCollateralAmount,
            currentManuallyRealizedNegativePnlCollateral,
            manuallyRealizedNegativePnlCollateralCapped,
            virtualAvailableCollateralInDiamondDelta,
            newVirtualAvailableCollateralInDiamond
        );
    }

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function storeUiRealizedPnlPartialCloseCollateral(
        address _trader,
        uint32 _index,
        int256 _deltaCollateral
    ) external {
        _getStorage().tradeUiRealizedPnlData[_trader][_index].realizedPnlPartialCloseCollateral += int128(
            _deltaCollateral
        );
    }

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function storeUiPnlWithdrawnCollateral(address _trader, uint32 _index, uint256 _deltaCollateral) external {
        _getStorage().tradeUiRealizedPnlData[_trader][_index].pnlWithdrawnCollateral += uint128(_deltaCollateral);
    }

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function storeUiRealizedTradingFeesCollateral(address _trader, uint32 _index, uint256 _deltaCollateral) external {
        _getStorage().tradeUiRealizedPnlData[_trader][_index].realizedTradingFeesCollateral += uint128(
            _deltaCollateral
        );
    }

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function getTradeFundingFeesCollateral(
        address _trader,
        uint32 _index,
        uint64 _currentPairPrice
    ) public view returns (int256) {
        // Funding fees are only charged on post-v10 trades and only take into account post-v10 OI
        if (_getMultiCollatDiamond().getTradeContractsVersion(_trader, _index) < ITradingStorage.ContractsVersion.V10)
            return 0;

        ITradingStorage.Trade memory trade = TradingCommonUtils.getTrade(_trader, _index);

        uint256 positionSizeCollateral = TradingCommonUtils.getPositionSizeCollateral(
            trade.collateralAmount,
            trade.leverage
        );

        (int128 accFundingFeeLongP, int128 accFundingFeeShortP, ) = getPairPendingAccFundingFees(
            trade.collateralIndex,
            trade.pairIndex,
            _currentPairPrice
        );
        int128 currentAccFundingFeeP = trade.long ? accFundingFeeLongP : accFundingFeeShortP;
        int128 initialAccFundingFeeP = _getStorage().tradeFeesData[_trader][_index].initialAccFundingFeeP;

        return
            (int256(positionSizeCollateral) * (currentAccFundingFeeP - initialAccFundingFeeP)) /
            int256(int64(trade.openPrice)) /
            1e10 /
            100;
    }

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function getTradeBorrowingFeesCollateral(
        address _trader,
        uint32 _index,
        uint64 _currentPairPrice
    ) public view returns (uint256) {
        ITradingStorage.Trade memory trade = TradingCommonUtils.getTrade(_trader, _index);
        uint256 positionSizeCollateral = TradingCommonUtils.getPositionSizeCollateral(
            trade.collateralAmount,
            trade.leverage
        );

        uint128 accBorrowingFeeP = getPairPendingAccBorrowingFees(
            trade.collateralIndex,
            trade.pairIndex,
            _currentPairPrice
        );
        uint128 initialAccBorrowingFeeP = _getStorage().tradeFeesData[_trader][_index].initialAccBorrowingFeeP;

        return (positionSizeCollateral * (accBorrowingFeeP - initialAccBorrowingFeeP)) / trade.openPrice / 1e10 / 100;
    }

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function getTradePendingHoldingFeesCollateral(
        address _trader,
        uint32 _index,
        uint64 _currentPairPrice
    ) public view returns (IFundingFees.TradeHoldingFees memory tradeHoldingFees) {
        ITradingStorage.Trade memory trade = TradingCommonUtils.getTrade(_trader, _index);

        tradeHoldingFees.fundingFeeCollateral = getTradeFundingFeesCollateral(_trader, _index, _currentPairPrice);
        tradeHoldingFees.borrowingFeeCollateral = getTradeBorrowingFeesCollateral(_trader, _index, _currentPairPrice);
        tradeHoldingFees.borrowingFeeCollateral_old = TradingCommonUtils.getTradeBorrowingFeeCollateral_old(
            trade,
            _currentPairPrice
        );
        tradeHoldingFees.totalFeeCollateral =
            tradeHoldingFees.fundingFeeCollateral +
            int256(tradeHoldingFees.borrowingFeeCollateral + tradeHoldingFees.borrowingFeeCollateral_old);
    }

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function getPairPendingAccFundingFees(
        uint8 _collateralIndex,
        uint16 _pairIndex,
        uint64 _currentPairPrice
    ) public view returns (int128 accFundingFeeLongP, int128 accFundingFeeShortP, int56 currentFundingRatePerSecondP) {
        IFundingFees.FundingFeesStorage storage s = _getStorage();
        IFundingFees.FundingFeeParams memory fundingFeeParams = s.pairFundingFeeParams[_collateralIndex][_pairIndex];
        IFundingFees.PairFundingFeeData memory fundingFeeData = s.pairFundingFeeData[_collateralIndex][_pairIndex];

        accFundingFeeLongP = fundingFeeData.accFundingFeeLongP;
        accFundingFeeShortP = fundingFeeData.accFundingFeeShortP;

        /// @dev At first update acc fees will always be 0 since fundingFeesEnabled is false by default
        /// Then acc fees will increase from there accurately from lastFundingUpdateTs
        if (!fundingFeeParams.fundingFeesEnabled)
            return (
                accFundingFeeLongP,
                accFundingFeeShortP,
                fundingFeeData.lastFundingRatePerSecondP // we still remember the last rate after disabling for when we re-reenable
            );

        IFundingFees.FundingFeeValues memory v; // to avoid stack too deep

        v.pairOiToken = _getMultiCollatDiamond().getPairOiAfterV10Token(_collateralIndex, _pairIndex); // 1e18
        v.netExposureToken = TradingCommonUtils.getPairV10OiTokenSkewCollateral(_collateralIndex, _pairIndex); // 1e18
        v.netExposureUsd =
            (TradingCommonUtils.getPairV10OiDynamicSkewCollateral(_collateralIndex, _pairIndex, _currentPairPrice) *
                int256(_getMultiCollatDiamond().getCollateralPriceUsd(_collateralIndex))) /
            1e8; // 1e10

        v.secondsSinceLastUpdate = block.timestamp - fundingFeeData.lastFundingUpdateTs;

        v.currentVelocityPerYear = _getCurrentFundingVelocityPerYear(
            v.netExposureToken,
            v.netExposureUsd,
            fundingFeeParams.skewCoefficientPerYear,
            fundingFeeParams.absoluteVelocityPerYearCap,
            fundingFeeParams.thetaThresholdUsd
        ); // 1e10

        (v.avgFundingRatePerSecondP, currentFundingRatePerSecondP) = _getAvgFundingRatePerSecondP(
            fundingFeeData.lastFundingRatePerSecondP,
            fundingFeeParams.absoluteRatePerSecondCap,
            v.currentVelocityPerYear,
            v.secondsSinceLastUpdate
        ); // 1e18 (%)

        v.currentPairPriceInt = int256(uint256(_currentPairPrice)); // 1e10

        if (
            fundingFeeParams.aprMultiplierEnabled &&
            ((currentFundingRatePerSecondP > 0 && fundingFeeData.lastFundingRatePerSecondP < 0) ||
                (currentFundingRatePerSecondP < 0 && fundingFeeData.lastFundingRatePerSecondP > 0))
        ) {
            // If the funding rate changed sign since last update and APR multiplier is enabled, we need to split into two deltas

            // 1. From last update to rate = 0
            v.secondsToReachZeroRate = _getSecondsToReachZeroRate(
                fundingFeeData.lastFundingRatePerSecondP,
                v.currentVelocityPerYear
            );
            v.avgFundingRatePerSecondP = fundingFeeData.lastFundingRatePerSecondP / 2;
            v.fundingFeesDeltaP =
                (v.avgFundingRatePerSecondP * int256(v.secondsToReachZeroRate) * v.currentPairPriceInt) /
                1e8; // 1e20 (%)
            (v.longAprMultiplier, v.shortAprMultiplier) = _getLongShortAprMultiplier(
                v.avgFundingRatePerSecondP,
                v.pairOiToken.oiLongToken,
                v.pairOiToken.oiShortToken,
                true
            ); // 1e20
            accFundingFeeLongP += int128((v.fundingFeesDeltaP * int256(v.longAprMultiplier)) / 1e20); // 1e20 (%)
            accFundingFeeShortP -= int128((v.fundingFeesDeltaP * int256(v.shortAprMultiplier)) / 1e20); // 1e20 (%)

            // 2. From rate = 0 to current rate
            v.avgFundingRatePerSecondP = currentFundingRatePerSecondP / 2;
            v.fundingFeesDeltaP =
                (v.avgFundingRatePerSecondP *
                    int256(v.secondsSinceLastUpdate - v.secondsToReachZeroRate) *
                    v.currentPairPriceInt) /
                1e8; // 1e20 (%)
            (v.longAprMultiplier, v.shortAprMultiplier) = _getLongShortAprMultiplier(
                v.avgFundingRatePerSecondP,
                v.pairOiToken.oiLongToken,
                v.pairOiToken.oiShortToken,
                true
            ); // 1e20
            accFundingFeeLongP += int128((v.fundingFeesDeltaP * int256(v.longAprMultiplier)) / 1e20); // 1e20 (%)
            accFundingFeeShortP -= int128((v.fundingFeesDeltaP * int256(v.shortAprMultiplier)) / 1e20); // 1e20 (%)
        } else {
            // If the funding rate didn't change sign since last update or APR multiplier is disabled, we can do a single delta
            v.fundingFeesDeltaP =
                (v.avgFundingRatePerSecondP * int256(v.secondsSinceLastUpdate) * v.currentPairPriceInt) /
                1e8; // 1e20 (%)
            (v.longAprMultiplier, v.shortAprMultiplier) = _getLongShortAprMultiplier(
                v.avgFundingRatePerSecondP,
                v.pairOiToken.oiLongToken,
                v.pairOiToken.oiShortToken,
                fundingFeeParams.aprMultiplierEnabled
            ); // 1e20
            accFundingFeeLongP += int128((v.fundingFeesDeltaP * int256(v.longAprMultiplier)) / 1e20); // 1e20 (%)
            accFundingFeeShortP -= int128((v.fundingFeesDeltaP * int256(v.shortAprMultiplier)) / 1e20); // 1e20 (%)
        }
    }

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function getPairPendingAccBorrowingFees(
        uint8 _collateralIndex,
        uint16 _pairIndex,
        uint64 _currentPairPrice
    ) public view returns (uint128 accBorrowingFeeP) {
        IFundingFees.FundingFeesStorage storage s = _getStorage();
        IFundingFees.BorrowingFeeParams memory borrowingFeeParams = s.pairBorrowingFeeParams[_collateralIndex][
            _pairIndex
        ];
        IFundingFees.PairBorrowingFeeData memory borrowingFeeData = s.pairBorrowingFeeData[_collateralIndex][
            _pairIndex
        ];

        /// @dev At first update acc fees will always be 0 since borrowingRatePerSecondP is 0 by default
        /// Then acc fees will increase from there accurately from lastBorrowingUpdateTs
        uint256 accBorrowingFeeDeltaP = uint256(borrowingFeeParams.borrowingRatePerSecondP) *
            (block.timestamp - borrowingFeeData.lastBorrowingUpdateTs) *
            _currentPairPrice; // 1e20 (%)

        accBorrowingFeeP = borrowingFeeData.accBorrowingFeeP + uint128(accBorrowingFeeDeltaP);
    }

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function getMaxSkewCollateral(uint8 _collateralIndex, uint16 _pairIndex) public view returns (uint80) {
        return _getStorage().pairGlobalParams[_collateralIndex][_pairIndex].maxSkewCollateral;
    }

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function getPairGlobalParamsArray(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex
    ) internal view returns (IFundingFees.PairGlobalParams[] memory) {
        if (_collateralIndex.length != _pairIndex.length) revert IGeneralErrors.InvalidInputLength();

        IFundingFees.PairGlobalParams[] memory pairGlobalParams = new IFundingFees.PairGlobalParams[](
            _pairIndex.length
        );

        for (uint256 i = 0; i < _pairIndex.length; ++i) {
            pairGlobalParams[i] = _getStorage().pairGlobalParams[_collateralIndex[i]][_pairIndex[i]];
        }

        return pairGlobalParams;
    }

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function getPairFundingFeeParams(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex
    ) internal view returns (IFundingFees.FundingFeeParams[] memory) {
        if (_collateralIndex.length != _pairIndex.length) revert IGeneralErrors.InvalidInputLength();

        IFundingFees.FundingFeeParams[] memory fundingFeeParams = new IFundingFees.FundingFeeParams[](
            _pairIndex.length
        );

        for (uint256 i = 0; i < _pairIndex.length; ++i) {
            fundingFeeParams[i] = _getStorage().pairFundingFeeParams[_collateralIndex[i]][_pairIndex[i]];
        }

        return fundingFeeParams;
    }

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function getPairBorrowingFeeParams(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex
    ) internal view returns (IFundingFees.BorrowingFeeParams[] memory) {
        if (_collateralIndex.length != _pairIndex.length) revert IGeneralErrors.InvalidInputLength();

        IFundingFees.BorrowingFeeParams[] memory borrowingFeeParams = new IFundingFees.BorrowingFeeParams[](
            _pairIndex.length
        );

        for (uint256 i = 0; i < _pairIndex.length; ++i) {
            borrowingFeeParams[i] = _getStorage().pairBorrowingFeeParams[_collateralIndex[i]][_pairIndex[i]];
        }

        return borrowingFeeParams;
    }

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function getPairFundingFeeData(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex
    ) internal view returns (IFundingFees.PairFundingFeeData[] memory) {
        if (_collateralIndex.length != _pairIndex.length) revert IGeneralErrors.InvalidInputLength();

        IFundingFees.PairFundingFeeData[] memory fundingFeeData = new IFundingFees.PairFundingFeeData[](
            _collateralIndex.length
        );

        for (uint256 i = 0; i < _collateralIndex.length; ++i) {
            fundingFeeData[i] = _getStorage().pairFundingFeeData[_collateralIndex[i]][_pairIndex[i]];
        }

        return fundingFeeData;
    }

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function getPairBorrowingFeeData(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex
    ) internal view returns (IFundingFees.PairBorrowingFeeData[] memory) {
        if (_collateralIndex.length != _pairIndex.length) revert IGeneralErrors.InvalidInputLength();

        IFundingFees.PairBorrowingFeeData[] memory borrowingFeeData = new IFundingFees.PairBorrowingFeeData[](
            _collateralIndex.length
        );

        for (uint256 i = 0; i < _collateralIndex.length; ++i) {
            borrowingFeeData[i] = _getStorage().pairBorrowingFeeData[_collateralIndex[i]][_pairIndex[i]];
        }

        return borrowingFeeData;
    }

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function getTradeFeesData(
        address _trader,
        uint32 _index
    ) internal view returns (IFundingFees.TradeFeesData memory) {
        return _getStorage().tradeFeesData[_trader][_index];
    }

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function getTradeFeesDataArray(
        address[] calldata _trader,
        uint32[] calldata _index
    ) internal view returns (IFundingFees.TradeFeesData[] memory) {
        if (_trader.length != _index.length) revert IGeneralErrors.InvalidInputLength();

        IFundingFees.TradeFeesData[] memory tradeFeesData = new IFundingFees.TradeFeesData[](_trader.length);

        for (uint256 i = 0; i < _trader.length; ++i) {
            tradeFeesData[i] = getTradeFeesData(_trader[i], _index[i]);
        }

        return tradeFeesData;
    }

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function getTradeUiRealizedPnlDataArray(
        address[] calldata _trader,
        uint32[] calldata _index
    ) external view returns (IFundingFees.UiRealizedPnlData[] memory) {
        if (_trader.length != _index.length) revert IGeneralErrors.InvalidInputLength();

        IFundingFees.UiRealizedPnlData[] memory uiRealizedPnlData = new IFundingFees.UiRealizedPnlData[](
            _trader.length
        );

        for (uint256 i = 0; i < _trader.length; ++i) {
            uiRealizedPnlData[i] = _getStorage().tradeUiRealizedPnlData[_trader[i]][_index[i]];
        }

        return uiRealizedPnlData;
    }

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function getTradeManuallyRealizedNegativePnlCollateral(
        address _trader,
        uint32 _index
    ) external view returns (uint256) {
        return _getStorage().tradeFeesData[_trader][_index].manuallyRealizedNegativePnlCollateral;
    }

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function getPendingParamUpdates(
        uint32[] calldata _index
    ) internal view returns (IFundingFees.PendingParamUpdate[] memory) {
        IFundingFees.PendingParamUpdate[] memory pendingParamUpdates = new IFundingFees.PendingParamUpdate[](
            _index.length
        );

        for (uint256 i = 0; i < _index.length; ++i) {
            pendingParamUpdates[i] = _getStorage().pendingParamUpdates[_index[i]];
        }

        return pendingParamUpdates;
    }

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function getTradeRealizedPnlCollateral(
        address _trader,
        uint32 _index
    )
        external
        view
        returns (int256 realizedPnlCollateral, uint256 realizedTradingFeesCollateral, int256 totalRealizedPnlCollateral)
    {
        IFundingFees.TradeFeesData storage tradeFeesData = _getStorage().tradeFeesData[_trader][_index];
        realizedPnlCollateral = tradeFeesData.realizedPnlCollateral;
        realizedTradingFeesCollateral = tradeFeesData.realizedTradingFeesCollateral;
        totalRealizedPnlCollateral = realizedPnlCollateral - int256(realizedTradingFeesCollateral);
    }

    /**
     * @dev Check IFundingFeesUtils interface for documentation
     */
    function getTradeRealizedTradingFeesCollateral(address _trader, uint32 _index) external view returns (uint256) {
        return _getStorage().tradeFeesData[_trader][_index].realizedTradingFeesCollateral;
    }

    /**
     * @dev Returns storage slot to use when fetching storage relevant to library
     */
    function _getSlot() internal pure returns (uint256) {
        return StorageUtils.GLOBAL_FUNDING_FEES_SLOT;
    }

    /**
     * @dev Returns storage pointer for storage struct in diamond contract, at defined slot
     */
    function _getStorage() internal pure returns (IFundingFees.FundingFeesStorage storage s) {
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
     * @dev Validates, temporarily stores, and cleans up signed market pair prices.
     */
    modifier useSignedMarketPrices(IPriceAggregator.SignedPairPrices[] calldata _signedPairPrices) {
        _validateSignedPairPrices(_signedPairPrices);
        _;
        _cleanUpSignedPairPrices();
    }

    /**
     * @dev Wrapper for `useSignedMarketPrices` modifier action to reduce contract size.
     */
    function _validateSignedPairPrices(IPriceAggregator.SignedPairPrices[] calldata _signedPairPrices) private {
        bool isLookback = false;
        _getMultiCollatDiamond().validateSignedPairPrices(_signedPairPrices, isLookback);
    }

    /**
     * @dev Wrapper for `useSignedMarketPrices` modifier action to reduce contract size.
     */
    function _cleanUpSignedPairPrices() private {
        _getMultiCollatDiamond().cleanUpSignedPairPrices();
    }

    /**
     * @dev Callback for setting skew coefficient per year
     * @param _input input data
     */
    function _setSkewCoefficientPerYearCallback(IFundingFees.FundingParamCallbackInput memory _input) internal {
        uint112 skewCoefficientPerYear = uint112(_input.newValue);

        _getStorage()
        .pairFundingFeeParams[_input.collateralIndex][_input.pairIndex].skewCoefficientPerYear = skewCoefficientPerYear;

        emit IFundingFeesUtils.SkewCoefficientPerYearUpdated(
            _input.collateralIndex,
            _input.pairIndex,
            skewCoefficientPerYear
        );
    }

    /**
     * @dev Callback for setting absolute velocity per year cap
     * @param _input input data
     */
    function _setAbsoluteVelocityPerYearCapCallback(IFundingFees.FundingParamCallbackInput memory _input) internal {
        uint24 absoluteVelocityPerYearCap = uint24(_input.newValue);

        _getStorage()
        .pairFundingFeeParams[_input.collateralIndex][_input.pairIndex]
            .absoluteVelocityPerYearCap = absoluteVelocityPerYearCap;

        emit IFundingFeesUtils.AbsoluteVelocityPerYearCapUpdated(
            _input.collateralIndex,
            _input.pairIndex,
            absoluteVelocityPerYearCap
        );
    }

    /**
     * @dev Callback for setting absolute rate per second cap
     * @param _input input data
     */
    function _setAbsoluteRatePerSecondCapCallback(IFundingFees.FundingParamCallbackInput memory _input) internal {
        uint24 absoluteRatePerSecondCap = uint24(_input.newValue);

        _getStorage()
        .pairFundingFeeParams[_input.collateralIndex][_input.pairIndex]
            .absoluteRatePerSecondCap = absoluteRatePerSecondCap;

        emit IFundingFeesUtils.AbsoluteRatePerSecondCapUpdated(
            _input.collateralIndex,
            _input.pairIndex,
            absoluteRatePerSecondCap
        );
    }

    /**
     * @dev Callback for setting theta threshold USD
     * @param _input input data
     */
    function _setThetaThresholdUsdCallback(IFundingFees.FundingParamCallbackInput memory _input) internal {
        uint32 thetaThresholdUsd = uint32(_input.newValue);

        _getStorage()
        .pairFundingFeeParams[_input.collateralIndex][_input.pairIndex].thetaThresholdUsd = thetaThresholdUsd;

        emit IFundingFeesUtils.ThetaThresholdUsdUpdated(_input.collateralIndex, _input.pairIndex, thetaThresholdUsd);
    }

    /**
     * @dev Callback for setting whether funding fees are enabled
     * @param _input input data
     */
    function _setFundingFeesEnabledCallback(IFundingFees.FundingParamCallbackInput memory _input) internal {
        bool fundingFeesEnabled = _input.newValue == 1;

        _getStorage()
        .pairFundingFeeParams[_input.collateralIndex][_input.pairIndex].fundingFeesEnabled = fundingFeesEnabled;

        emit IFundingFeesUtils.FundingFeesEnabledUpdated(_input.collateralIndex, _input.pairIndex, fundingFeesEnabled);
    }

    /**
     * @dev Callback for setting whether apr multiplier are enabled
     * @param _input input data
     */
    function _setAprMultiplierEnabledCallback(IFundingFees.FundingParamCallbackInput memory _input) internal {
        bool aprMultiplierEnabled = _input.newValue == 1;

        _getStorage()
        .pairFundingFeeParams[_input.collateralIndex][_input.pairIndex].aprMultiplierEnabled = aprMultiplierEnabled;

        emit IFundingFeesUtils.AprMultiplierEnabledUpdated(
            _input.collateralIndex,
            _input.pairIndex,
            aprMultiplierEnabled
        );
    }

    /**
     * @dev Callback for setting borrowing rate per second %
     * @param _input input data
     */
    function _setBorrowingRatePerSecondPCallback(IFundingFees.FundingParamCallbackInput memory _input) internal {
        uint24 borrowingRatePerSecondP = uint24(_input.newValue);

        _getStorage()
        .pairBorrowingFeeParams[_input.collateralIndex][_input.pairIndex]
            .borrowingRatePerSecondP = borrowingRatePerSecondP;

        emit IFundingFeesUtils.BorrowingRatePerSecondPUpdated(
            _input.collateralIndex,
            _input.pairIndex,
            borrowingRatePerSecondP
        );
    }

    /**
     * @dev Stores pending acc funding fees for a pair
     * @dev HAS TO BE CALLED before a funding fee parameter changes and before OIs change
     * @param _collateralIndex index of the collateral
     * @param _pairIndex index of the pair
     * @param _currentPairPrice current price of pair (1e10)
     */
    function _storePendingAccFundingFees(
        uint8 _collateralIndex,
        uint16 _pairIndex,
        uint64 _currentPairPrice
    ) internal returns (int128 accFundingFeeLongP, int128 accFundingFeeShortP) {
        IFundingFees.FundingFeesStorage storage s = _getStorage();
        IFundingFees.PairFundingFeeData memory fundingFeeData = s.pairFundingFeeData[_collateralIndex][_pairIndex];

        uint32 currentTs = uint32(block.timestamp);

        int56 currentFundingRatePerSecondP;
        (accFundingFeeLongP, accFundingFeeShortP, currentFundingRatePerSecondP) = getPairPendingAccFundingFees(
            _collateralIndex,
            _pairIndex,
            _currentPairPrice
        );

        // No need to update state if 0 seconds elapsed since last update
        if (currentTs == fundingFeeData.lastFundingUpdateTs) return (accFundingFeeLongP, accFundingFeeShortP);

        fundingFeeData.accFundingFeeLongP = accFundingFeeLongP;
        fundingFeeData.accFundingFeeShortP = accFundingFeeShortP;
        fundingFeeData.lastFundingRatePerSecondP = currentFundingRatePerSecondP;
        fundingFeeData.lastFundingUpdateTs = currentTs;

        s.pairFundingFeeData[_collateralIndex][_pairIndex] = fundingFeeData;

        emit IFundingFeesUtils.PendingAccFundingFeesStored(_collateralIndex, _pairIndex, fundingFeeData);
    }

    /**
     * @dev Stores pending acc borrowing fees for a pair
     * @dev HAS TO BE CALLED before the borrowing rate per second changes
     * @param _collateralIndex index of the collateral
     * @param _pairIndex index of the pair
     * @param _currentPairPrice current price of pair (1e10)
     */
    function _storePendingAccBorrowingFees(
        uint8 _collateralIndex,
        uint16 _pairIndex,
        uint64 _currentPairPrice
    ) internal returns (uint128 accBorrowingFeeP) {
        IFundingFees.FundingFeesStorage storage s = _getStorage();
        IFundingFees.PairBorrowingFeeData memory borrowingFeeData = s.pairBorrowingFeeData[_collateralIndex][
            _pairIndex
        ];

        uint32 currentTs = uint32(block.timestamp);

        accBorrowingFeeP = getPairPendingAccBorrowingFees(_collateralIndex, _pairIndex, _currentPairPrice);

        // No need to update state if 0 seconds elapsed since last update
        if (currentTs == borrowingFeeData.lastBorrowingUpdateTs) return accBorrowingFeeP;

        borrowingFeeData.accBorrowingFeeP = accBorrowingFeeP;
        borrowingFeeData.lastBorrowingUpdateTs = currentTs;

        s.pairBorrowingFeeData[_collateralIndex][_pairIndex] = borrowingFeeData;

        emit IFundingFeesUtils.PendingAccBorrowingFeesStored(_collateralIndex, _pairIndex, borrowingFeeData);
    }

    /**
     * @dev Returns avg funding rate between last update and now
     * @dev Maximum value should be >= type(uint24).max * 1e8 = 1.67e15, type(int56).max = 36.02e15
     * @param _lastFundingRatePerSecondP last funding rate % per second (1e18)
     * @param _absoluteRatePerSecondCap absolute cap on funding rate % per second (1e10)
     * @param _currentVelocityPerYear current funding rate velocity per year (1e10)
     * @param _secondsSinceLastUpdate seconds elapsed since last update
     * @return avgFundingRatePerSecondP average funding rate % per second since last update (1e18)
     * @return currentFundingRatePerSecondP current funding rate % per second (1e18)
     */
    function _getAvgFundingRatePerSecondP(
        int56 _lastFundingRatePerSecondP,
        uint24 _absoluteRatePerSecondCap,
        int40 _currentVelocityPerYear,
        uint256 _secondsSinceLastUpdate
    ) internal pure returns (int56 avgFundingRatePerSecondP, int56 currentFundingRatePerSecondP) {
        // If cap is uninitialized, there are no funding fees
        if (_absoluteRatePerSecondCap == 0) return (0, 0);

        // If velocity is 0 or no time elapsed, funding rate is still the same
        if (_currentVelocityPerYear == 0 || _secondsSinceLastUpdate == 0)
            return (_lastFundingRatePerSecondP, _lastFundingRatePerSecondP);

        int56 ratePerSecondCap = int56(uint56(_absoluteRatePerSecondCap)) *
            1e8 *
            (_currentVelocityPerYear < 0 ? int56(-1) : int56(1)); // 1e18

        // If rate is already at cap, just return it
        if (ratePerSecondCap == _lastFundingRatePerSecondP) return (ratePerSecondCap, ratePerSecondCap);

        uint256 secondsToReachCap = uint256(
            ((int256(ratePerSecondCap) - int256(_lastFundingRatePerSecondP)) * ONE_YEAR) /
                int256(_currentVelocityPerYear) /
                1e8
        ); // This is always positive because (ratePerSecondCap - _lastFundingRatePerSecondP) is always the same sign as _currentVelocityPerYear

        if (_secondsSinceLastUpdate > secondsToReachCap) {
            currentFundingRatePerSecondP = ratePerSecondCap; // 1e18

            // We split the avg funding rate per second into two parts: the rate up to the cap, and the rate at the cap
            // Then we take a weighted average of both parts depending on how much time was spent at each average rate
            int56 avgFundingRatePerSecondP_1 = (_lastFundingRatePerSecondP + ratePerSecondCap) / 2; // 1e18
            avgFundingRatePerSecondP = int56(
                (int256(avgFundingRatePerSecondP_1) *
                    int256(secondsToReachCap) +
                    int256(ratePerSecondCap) *
                    int256(_secondsSinceLastUpdate - secondsToReachCap)) / int256(_secondsSinceLastUpdate)
            ); // 1e18
        } else {
            // Even at minimum velocity per year of 1e-10, this increases every second, so no issues with rounding down
            currentFundingRatePerSecondP = int56(
                int256(_lastFundingRatePerSecondP) +
                    (int256(_secondsSinceLastUpdate) * int256(_currentVelocityPerYear) * 1e8) /
                    ONE_YEAR
            ); // 1e18

            avgFundingRatePerSecondP = (_lastFundingRatePerSecondP + currentFundingRatePerSecondP) / 2; // 1e18
        }
    }

    /**
     * @dev Returns current funding rate % / second velocity per year
     * @dev Maximum value should be >= type(uint24).max * 1e3 = 1.67e10, type(int40).max = 54.97e10
     * @param _netExposureToken net exposure in tokens (1e18)
     * @param _netExposureUsd net exposure in USD (1e10)
     * @param _skewCoefficientPerYear skew coefficient per year (1e26)
     * @param _absoluteVelocityPerYearCap cap on velocity per year (1e7)
     * @param _thetaThresholdUsd theta threshold (USD)
     * @return currentFundingVelocityPerYear current yearly funding rate % / second velocity (1e10)
     */
    function _getCurrentFundingVelocityPerYear(
        int256 _netExposureToken,
        int256 _netExposureUsd,
        uint112 _skewCoefficientPerYear,
        uint24 _absoluteVelocityPerYearCap,
        uint32 _thetaThresholdUsd
    ) internal pure returns (int40 currentFundingVelocityPerYear) {
        // If no exposure or skew coefficient 0 or velocity cap 0, velocity is 0
        if (_netExposureToken == 0 || _skewCoefficientPerYear == 0 || _absoluteVelocityPerYearCap == 0) return 0;

        int256 exposureSign = _netExposureUsd < 0 ? int256(-1) : int256(1);
        if (uint256(_netExposureUsd * exposureSign) < uint256(_thetaThresholdUsd) * 1e10) return 0;

        uint256 absoluteVelocityPerYear = (uint256(_netExposureToken * exposureSign) *
            uint256(_skewCoefficientPerYear)) / 1e34; // 1e10

        uint40 absoluteVelocityPerYearCap = uint40(_absoluteVelocityPerYearCap) * 1e3; // 1e10

        currentFundingVelocityPerYear = absoluteVelocityPerYear > absoluteVelocityPerYearCap
            ? int40(absoluteVelocityPerYearCap) * int40(exposureSign)
            : int40(int256(absoluteVelocityPerYear) * exposureSign);
    }

    /**
     * @dev Returns the APR multiplier for longs and shorts based on the OI ratio
     * @param _avgFundingRatePerSecondP avg funding rate % per second since last update (1e18)
     * @param _pairOiLongToken OI of the long side in tokens (1e18)
     * @param _pairOiShortToken OI of the short side in tokens (1e18)
     * @param _aprMultiplierEnabled whether the APR multiplier is enabled
     * @return longSideAprMultiplier APR multiplier for the long side (1e20)
     * @return shortSideAprMultiplier APR multiplier for the short side (1e20)
     */
    function _getLongShortAprMultiplier(
        int256 _avgFundingRatePerSecondP,
        uint256 _pairOiLongToken,
        uint256 _pairOiShortToken,
        bool _aprMultiplierEnabled
    ) internal pure returns (uint256 longSideAprMultiplier, uint256 shortSideAprMultiplier) {
        // If _avgFundingRatePerSecondP = 0 then APR multiplier doesn't matter anyway since delta will always be 0
        if (_avgFundingRatePerSecondP == 0) return (1e20, 1e20); // 1e20

        bool longsEarned = _avgFundingRatePerSecondP < 0;

        longSideAprMultiplier = _pairOiLongToken == 0
            ? 0
            : longsEarned && _aprMultiplierEnabled
                ? (_pairOiShortToken * 1e20) / _pairOiLongToken
                : 1e20; // 1e20
        shortSideAprMultiplier = _pairOiShortToken == 0
            ? 0
            : !longsEarned && _aprMultiplierEnabled
                ? (_pairOiLongToken * 1e20) / _pairOiShortToken
                : 1e20; // 1e20

        longSideAprMultiplier = longSideAprMultiplier > FUNDING_APR_MULTIPLIER_CAP
            ? FUNDING_APR_MULTIPLIER_CAP
            : longSideAprMultiplier; // 1e20

        shortSideAprMultiplier = shortSideAprMultiplier > FUNDING_APR_MULTIPLIER_CAP
            ? FUNDING_APR_MULTIPLIER_CAP
            : shortSideAprMultiplier; // 1e20
    }

    /**
     * @dev Returns the number of seconds until the funding rate reaches 0
     * @param _lastFundingRatePerSecondP last funding rate % per second (1e18)
     * @param _currentVelocityPerYear current yearly funding rate % / second velocity (1e10)
     */
    function _getSecondsToReachZeroRate(
        int56 _lastFundingRatePerSecondP,
        int40 _currentVelocityPerYear
    ) internal pure returns (uint256) {
        // note: velocity can't be zero here because it's only called when rate changed signs since last update
        int256 secondsToReachZeroRate = int256(
            (-_lastFundingRatePerSecondP * ONE_YEAR) / _currentVelocityPerYear / 1e8
        );
        if (secondsToReachZeroRate < 0) revert IGeneralErrors.BelowMin();
        return uint256(secondsToReachZeroRate);
    }
}
