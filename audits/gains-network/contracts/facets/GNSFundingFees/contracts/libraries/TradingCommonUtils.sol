// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import "../interfaces/IGToken.sol";
import "../interfaces/IGNSMultiCollatDiamond.sol";
import "../interfaces/IGNSStaking.sol";
import "../interfaces/IERC20.sol";

import "./ConstantsUtils.sol";
import "./AddressStoreUtils.sol";
import "./ChainUtils.sol";
import "./ChainConfigUtils.sol";
import "./TradingCallbacksUtils.sol";
import "./TradingStorageGetters.sol";
import "./TokenTransferUtils.sol";

/**
 * @dev External library for helper functions commonly used in many places
 */
library TradingCommonUtils {
    using TokenTransferUtils for address;

    // Pure functions

    /**
     * @dev Returns the current percent profit of a trade (1e10 precision)
     * @param _openPrice trade open price (1e10 precision)
     * @param _currentPrice trade current price (1e10 precision)
     * @param _long true for long, false for short
     * @param _leverage trade leverage (1e3 precision)
     */
    function getPnlPercent(
        uint64 _openPrice,
        uint64 _currentPrice,
        bool _long,
        uint24 _leverage
    ) public pure returns (int256 p) {
        int256 pricePrecision = int256(ConstantsUtils.P_10);
        int256 minPnlP = -100 * int256(ConstantsUtils.P_10);

        int256 openPrice = int256(uint256(_openPrice));
        int256 currentPrice = int256(uint256(_currentPrice));
        int256 leverage = int256(uint256(_leverage));

        p = _openPrice > 0
            ? ((_long ? currentPrice - openPrice : openPrice - currentPrice) * 100 * pricePrecision * leverage) /
                openPrice /
                1e3
            : int256(0);

        p = p < minPnlP ? minPnlP : p;
    }

    /**
     * @dev Returns position size of trade in collateral tokens (avoids overflow from uint120 collateralAmount)
     * @param _collateralAmount collateral of trade
     * @param _leverage leverage of trade (1e3)
     */
    function getPositionSizeCollateral(uint120 _collateralAmount, uint24 _leverage) internal pure returns (uint256) {
        return (uint256(_collateralAmount) * _leverage) / 1e3;
    }

    /**
     * @dev Calculates final spread % (1e10) for a trade
     * @param _spreadP spread percentage (1e10)
     * @param _long true if long, false if short
     * @param _open true if open, false if close
     */
    function getFixedSpreadP(uint256 _spreadP, bool _long, bool _open) public pure returns (int256) {
        _spreadP = _spreadP / 2;

        if (!_open) _long = !_long; // reverse spread direction on close

        return int256(_spreadP) * int256(_long ? int256(1) : int256(-1));
    }

    /**
     * @dev Returns negative pnl % of collateral amount due to price impact (1e10 %)
     * @param _fixedSpreadP fixed spread percentage (1e10)
     * @param _cumulVolPriceImpactP cumulative volume price impact percentage (1e10)
     * @param _leverage trade leverage (1e3 precision)
     * @param _long true if long, false if short
     */
    function getNegativePnlFromOpeningPriceImpactP(
        int256 _fixedSpreadP,
        int256 _cumulVolPriceImpactP,
        uint24 _leverage,
        bool _long
    ) external pure returns (int256) {
        return
            ((_fixedSpreadP + _cumulVolPriceImpactP) * int256(uint256(_leverage)) * (_long ? int256(1) : (-1))) / 1e3;
    }

    /**
     * @dev Converts collateral value to USD (1e18 precision)
     * @param _collateralAmount amount of collateral (collateral precision)
     * @param _collateralPrecisionDelta precision delta of collateral (10^18/10^decimals)
     * @param _collateralPriceUsd price of collateral in USD (1e8)
     */
    function convertCollateralToUsd(
        uint256 _collateralAmount,
        uint128 _collateralPrecisionDelta,
        uint256 _collateralPriceUsd
    ) public pure returns (uint256) {
        return (_collateralAmount * _collateralPrecisionDelta * _collateralPriceUsd) / 1e8;
    }

    /**
     * @dev Converts collateral value to GNS (1e18 precision)
     * @param _collateralAmount amount of collateral (collateral precision)
     * @param _collateralPrecisionDelta precision delta of collateral (10^18/10^decimals)
     * @param _gnsPriceCollateral price of GNS in collateral (1e10)
     */
    function convertCollateralToGns(
        uint256 _collateralAmount,
        uint128 _collateralPrecisionDelta,
        uint256 _gnsPriceCollateral
    ) internal pure returns (uint256) {
        return ((_collateralAmount * _collateralPrecisionDelta * ConstantsUtils.P_10) / _gnsPriceCollateral);
    }

    /**
     * @dev Calculates trade value (useful when closing a trade)
     * @dev Important: does not calculate if trade can be liquidated or not, has to be done by calling function
     * @param _collateral amount of collateral (collateral precision)
     * @param _percentProfit unrealized profit percentage (1e10)
     * @param _feesCollateral pending holding fees - realized pnl + closing fee in collateral tokens (collateral precision)
     * @param _collateralPrecisionDelta precision delta of collateral (10^18/10^decimals)
     */
    function getTradeValuePure(
        uint256 _collateral,
        int256 _percentProfit,
        int256 _feesCollateral,
        uint128 _collateralPrecisionDelta
    ) public pure returns (uint256) {
        int256 precisionDelta = int256(uint256(_collateralPrecisionDelta));

        // Multiply collateral by precisionDelta so we don't lose precision for low decimals
        int256 value = (int256(_collateral) *
            precisionDelta +
            (int256(_collateral) * precisionDelta * _percentProfit) /
            int256(ConstantsUtils.P_10) /
            100) /
            precisionDelta -
            _feesCollateral;

        return value > 0 ? uint256(value) : uint256(0);
    }

    /**
     * @dev Pure function that returns the liquidation pnl % threshold for a trade (1e10)
     * @param _params trade liquidation params
     * @param _leverage trade leverage (1e3 precision)
     */
    function getLiqPnlThresholdP(
        IPairsStorage.GroupLiquidationParams memory _params,
        uint256 _leverage
    ) public pure returns (uint256) {
        // By default use legacy threshold if liquidation params not set (trades opened before v9.2)
        if (_params.maxLiqSpreadP == 0) return ConstantsUtils.LEGACY_LIQ_THRESHOLD_P;

        if (_leverage <= _params.startLeverage) return _params.startLiqThresholdP;
        if (_leverage >= _params.endLeverage) return _params.endLiqThresholdP;

        return
            _params.startLiqThresholdP -
            ((_leverage - _params.startLeverage) * (_params.startLiqThresholdP - _params.endLiqThresholdP)) /
            (_params.endLeverage - _params.startLeverage);
    }

    /**
     * @dev Returns price after impact (1e10)
     * @param _oraclePrice oracle price (1e10)
     * @param _totalPriceImpactP total price impact percentage (1e10)
     */
    function getPriceAfterImpact(uint256 _oraclePrice, int256 _totalPriceImpactP) public pure returns (uint64) {
        int256 priceAfterImpactRaw = int256(_oraclePrice) +
            (int256(_oraclePrice) * _totalPriceImpactP) /
            int256(ConstantsUtils.P_10) /
            100;
        if (priceAfterImpactRaw <= 0) revert IGeneralErrors.BelowMin();
        if (priceAfterImpactRaw > int256(uint256(type(uint64).max))) revert IGeneralErrors.AboveMax();

        return uint64(uint256(priceAfterImpactRaw));
    }

    /**
     * @dev Validates trade's new adjusted initial leverage
     * @param _adjustedInitialLeverage adjusted initial leverage (1e3)
     */
    function validateAdjustedInitialLeverage(uint256 _adjustedInitialLeverage) external pure returns (bool) {
        return !(_adjustedInitialLeverage > type(uint24).max || _adjustedInitialLeverage < ConstantsUtils.MIN_LEVERAGE);
    }

    /**
     * @dev Returns trade's unrealized raw pnl (without fees or realized pnl) in collateral tokens (collateral precision)
     * @param _trade trade struct
     * @param _currentPairPrice current price of pair (1e10)
     */
    function getTradeUnrealizedRawPnlCollateral(
        ITradingStorage.Trade memory _trade,
        uint64 _currentPairPrice
    ) external pure returns (int256) {
        return
            (getPnlPercent(_trade.openPrice, _currentPairPrice, _trade.long, _trade.leverage) *
                int256(uint256(_trade.collateralAmount))) /
            100 /
            int256(ConstantsUtils.P_10);
    }

    // View functions

    /**
     * @dev Returns trade
     * @param _user trade user
     * @param _index trade index
     */
    function getTrade(address _user, uint32 _index) internal view returns (ITradingStorage.Trade memory) {
        return TradingStorageGetters.getTrade(_user, _index);
    }

    /**
     * @dev Returns trade info
     * @param _user trade user
     * @param _index trade index
     */
    function getTradeInfo(address _user, uint32 _index) internal view returns (ITradingStorage.TradeInfo memory) {
        return TradingStorageGetters.getTradeInfo(_user, _index);
    }

    /**
     * @dev Returns minimum position size in collateral tokens for a pair (collateral precision)
     * @param _collateralIndex collateral index
     * @param _pairIndex pair index
     */
    function getMinPositionSizeCollateral(uint8 _collateralIndex, uint256 _pairIndex) public view returns (uint256) {
        return
            _getMultiCollatDiamond().getCollateralFromUsdNormalizedValue(
                _collateralIndex,
                _getMultiCollatDiamond().pairMinPositionSizeUsd(_pairIndex)
            );
    }

    /**
     * @dev Returns position size to use when charging fees (collateral precision * 1e3)
     * @param _collateralIndex collateral index
     * @param _pairIndex pair index
     * @param _positionSizeCollateral trade position size in collateral tokens (collateral precision)
     * @param _feeRateMultiplier fee rate multiplier (1e3)
     */
    function getPositionSizeCollateralBasis(
        uint8 _collateralIndex,
        uint256 _pairIndex,
        uint256 _positionSizeCollateral,
        uint256 _feeRateMultiplier
    ) public view returns (uint256) {
        uint256 minPositionSizeCollateral = getMinPositionSizeCollateral(_collateralIndex, _pairIndex) * 1e3;
        uint256 adjustedPositionSizeCollateral = _positionSizeCollateral * _feeRateMultiplier;
        return
            adjustedPositionSizeCollateral > minPositionSizeCollateral
                ? adjustedPositionSizeCollateral
                : minPositionSizeCollateral;
    }

    /**
     * @dev Checks if total position size is not higher than maximum allowed open interest for a pair
     * @param _collateralIndex index of collateral
     * @param _pairIndex index of pair
     * @param _long true if long, false if short
     * @param _positionSizeCollateralDelta position size delta in collateral tokens (collateral precision)
     * @param _currentPairPrice current pair price (1e10)
     */
    function isWithinExposureLimits(
        uint8 _collateralIndex,
        uint16 _pairIndex,
        bool _long,
        uint256 _positionSizeCollateralDelta,
        uint64 _currentPairPrice
    ) external view returns (bool) {
        int256 currentSkewCollateral = getPairV10OiDynamicSkewCollateral(
            _collateralIndex,
            _pairIndex,
            _currentPairPrice
        );
        int256 newSkewCollateral = currentSkewCollateral +
            ((int256(_positionSizeCollateralDelta) *
                int256(uint256(_getMultiCollatDiamond().getCollateral(_collateralIndex).precisionDelta))) / 1e8) *
            (_long ? int256(1) : -1); // 1e10
        uint256 maxSkewCollateral = _getMultiCollatDiamond().getMaxSkewCollateral(_collateralIndex, _pairIndex); // 1e10

        return
            getPairTotalOiDynamicCollateral(_collateralIndex, _pairIndex, _long, _currentPairPrice) +
                _positionSizeCollateralDelta <=
            _getMultiCollatDiamond().getPairMaxOiCollateral(_collateralIndex, _pairIndex) &&
            _getMultiCollatDiamond().withinMaxBorrowingGroupOi(
                _collateralIndex,
                _pairIndex,
                _long,
                _positionSizeCollateralDelta
            ) &&
            isWithinSkewLimits(currentSkewCollateral, newSkewCollateral, maxSkewCollateral);
    }

    /**
     * @dev Checks if new skew is within skew limits. New skew is considered within limits when any of the following are true:
     * @dev a) max skew collateral is not set (0)
     * @dev b) new skew collateral is within max skew collateral limits
     * @dev c) new skew collateral is an improvement on current skew collateral, and is within max skew collateral limits if it switches sides
     *
     * @param _currentSkewCollateral current skew collateral (1e10)
     * @param _newSkewCollateral new skew collateral (1e10)
     * @param _maxSkewCollateral maximum skew collateral (1e10)
     * @return true if new skew collateral is within limits, false otherwise
     */

    function isWithinSkewLimits(
        int256 _currentSkewCollateral,
        int256 _newSkewCollateral,
        uint256 _maxSkewCollateral
    ) internal pure returns (bool) {
        // New skew is considered valid when:
        return
            //     `_maxSkewCollateral` is zero (max skew is not set),
            _maxSkewCollateral == 0 ||
            // OR  `abs(_newSkewCollateral) <= _maxSkewCollateral` (new skew is within max)
            (uint256(_newSkewCollateral >= 0 ? _newSkewCollateral : -_newSkewCollateral) <= _maxSkewCollateral) ||
            // OR  `_newSkewCollateral` is an improvement on `_currentSkewCollateral` (current skew is above max, new skew is an improvement), AND
            //     `_newSkewCollateral` is within max skew limits if it has switched signs
            (
                _currentSkewCollateral >= 0
                    ? _newSkewCollateral < _currentSkewCollateral && -_newSkewCollateral <= int256(_maxSkewCollateral)
                    : _newSkewCollateral > _currentSkewCollateral && _newSkewCollateral <= int256(_maxSkewCollateral)
            );
    }

    /**
     * @dev Convenient wrapper to return trade borrowing fee in collateral tokens (collateral precision)
     * @param _trade trade input
     * @param _currentPairPrice current pair price (1e10)
     */
    function getTradeBorrowingFeeCollateral_old(
        ITradingStorage.Trade memory _trade,
        uint256 _currentPairPrice
    ) public view returns (uint256) {
        return
            _getMultiCollatDiamond().getTradeBorrowingFee(
                IBorrowingFees.BorrowingFeeInput(
                    _trade.collateralIndex,
                    _trade.user,
                    _trade.pairIndex,
                    _trade.index,
                    _trade.long,
                    _trade.collateralAmount,
                    _trade.leverage,
                    _currentPairPrice
                )
            );
    }

    /**
     * @dev Convenient wrapper to return trade liquidation price (1e10)
     * @param _trade trade input
     * @param _newOpenPrice new trade open price (1e10)
     * @param _newCollateralAmount new trade collateral amount (collateral precision)
     * @param _newLeverage new leverage (1e3)
     * @param _additionalFeeCollateral additional fee in collateral tokens (collateral precision)
     * @param _newLiquidationParams new trade liquidation params
     * @param _currentPairPrice current pair price (1e10)
     * @param _partialCloseMultiplier partial close multiplier (1e18)
     * @param _beforeOpened if before trade was opened
     */
    function getTradeLiquidationPrice(
        ITradingStorage.Trade memory _trade,
        uint64 _newOpenPrice,
        uint256 _newCollateralAmount,
        uint256 _newLeverage,
        int256 _additionalFeeCollateral,
        IPairsStorage.GroupLiquidationParams memory _newLiquidationParams,
        uint64 _currentPairPrice,
        uint256 _partialCloseMultiplier,
        bool _beforeOpened
    ) public view returns (uint256) {
        return
            _getMultiCollatDiamond().getTradeLiquidationPrice(
                IBorrowingFees.LiqPriceInput(
                    _trade.collateralIndex,
                    _trade.user,
                    _trade.pairIndex,
                    _trade.index,
                    _newOpenPrice,
                    _trade.long,
                    _newCollateralAmount,
                    _newLeverage,
                    _additionalFeeCollateral,
                    _newLiquidationParams,
                    _currentPairPrice,
                    _trade.isCounterTrade,
                    _partialCloseMultiplier > 0 ? _partialCloseMultiplier : 1e18,
                    _beforeOpened
                )
            );
    }

    /**
     * @dev Convenient wrapper to return trade liquidation price (1e10)
     * @param _trade trade input
     * @param _additionalFeeCollateral additional fee in collateral tokens (collateral precision)
     * @param _currentPairPrice current pair price (1e10)
     */
    function getTradeLiquidationPrice(
        ITradingStorage.Trade memory _trade,
        int256 _additionalFeeCollateral,
        uint64 _currentPairPrice
    ) public view returns (uint256) {
        return
            getTradeLiquidationPrice(
                _trade,
                _trade.openPrice,
                _trade.collateralAmount,
                _trade.leverage,
                _additionalFeeCollateral,
                _getMultiCollatDiamond().getTradeLiquidationParams(_trade.user, _trade.index),
                _currentPairPrice,
                0,
                false
            );
    }

    /**
     * @dev Convenient wrapper to return trade liquidation price (1e10)
     * @param _trade trade input
     * @param _currentPairPrice current pair price (1e10)
     */
    function getTradeLiquidationPrice(
        ITradingStorage.Trade memory _trade,
        uint64 _currentPairPrice
    ) public view returns (uint256) {
        return getTradeLiquidationPrice(_trade, 0, _currentPairPrice);
    }

    /**
     * @dev Convenient wrapper to return trade liquidation price before it was opened (1e10)
     * @param _trade trade input
     * @param _additionalFeeCollateral additional fee in collateral tokens (collateral precision)
     * @param _finalCollateralAmount trade final collateral amount (collateral precision)
     * @param _finalOpenPrice trade final open price (1e10)
     */
    function getTradeLiquidationPriceBeforeOpened(
        ITradingStorage.Trade memory _trade,
        int256 _additionalFeeCollateral,
        uint256 _finalCollateralAmount,
        uint64 _finalOpenPrice
    ) public view returns (uint256) {
        return
            getTradeLiquidationPrice(
                _trade,
                _finalOpenPrice,
                _finalCollateralAmount,
                _trade.leverage,
                _additionalFeeCollateral,
                _getMultiCollatDiamond().getPairLiquidationParams(_trade.pairIndex),
                0,
                0,
                true
            );
    }

    /**
     * @dev Returns net trade value in collateral tokens
     * @param _trade trade data
     * @param _percentProfit profit percentage (1e10)
     * @param _closingFeesCollateral closing fees in collateral tokens (collateral precision)
     * @param _currentPairPrice current price of pair (1e10)
     */
    function getTradeValueCollateral(
        ITradingStorage.Trade memory _trade,
        int256 _percentProfit,
        uint256 _closingFeesCollateral,
        uint64 _currentPairPrice
    ) public view returns (uint256 valueCollateral) {
        IFundingFees.TradeHoldingFees memory holdingFees = _getMultiCollatDiamond()
            .getTradePendingHoldingFeesCollateral(_trade.user, _trade.index, _currentPairPrice);

        (, , int256 totalRealizedPnlCollateral) = _getMultiCollatDiamond().getTradeRealizedPnlCollateral(
            _trade.user,
            _trade.index
        );

        valueCollateral = getTradeValuePure(
            _trade.collateralAmount,
            _percentProfit,
            int256(_closingFeesCollateral) + holdingFees.totalFeeCollateral - totalRealizedPnlCollateral,
            _getMultiCollatDiamond().getCollateral(_trade.collateralIndex).precisionDelta
        );
    }

    /**
     * @dev Returns trade opening price impact output
     * @param _input input data
     */
    function getTradeOpeningPriceImpact(
        ITradingCommonUtils.TradePriceImpactInput memory _input
    ) external view returns (ITradingCommonUtils.TradePriceImpact memory output) {
        ITradingStorage.Trade memory trade = _input.trade;

        bool open = true;
        uint256 positionSizeUsd = _getMultiCollatDiamond().getUsdNormalizedValue(
            trade.collateralIndex,
            _input.positionSizeCollateral
        );

        output.fixedSpreadP = getFixedSpreadP(
            _getMultiCollatDiamond().pairSpreadP(trade.user, trade.pairIndex),
            trade.long,
            open
        );
        output.cumulVolPriceImpactP = _getMultiCollatDiamond().getTradeCumulVolPriceImpactP(
            trade.user,
            trade.pairIndex,
            trade.long,
            positionSizeUsd,
            false,
            open,
            0
        );

        uint256 priceAfterSpreadAndCumulVolPriceImpact = getPriceAfterImpact(
            _input.oraclePrice,
            output.fixedSpreadP + output.cumulVolPriceImpactP
        );
        output.positionSizeToken =
            (_input.positionSizeCollateral *
                _getMultiCollatDiamond().getCollateral(trade.collateralIndex).precisionDelta *
                1e10) /
            priceAfterSpreadAndCumulVolPriceImpact;

        output.skewPriceImpactP = _getMultiCollatDiamond().getTradeSkewPriceImpactP(
            trade.collateralIndex,
            trade.pairIndex,
            trade.long,
            output.positionSizeToken,
            open
        );

        output.totalPriceImpactP = output.fixedSpreadP + output.cumulVolPriceImpactP + output.skewPriceImpactP;
        output.priceAfterImpact = getPriceAfterImpact(_input.oraclePrice, output.totalPriceImpactP);
    }

    /**
     * @dev Returns trade closing price impact output and trade value used to know if pnl is positive (collateral precision)
     * @param _input input data
     */
    function getTradeClosingPriceImpact(
        ITradingCommonUtils.TradePriceImpactInput memory _input
    ) public view returns (ITradingCommonUtils.TradePriceImpact memory output, uint256 tradeValueCollateralNoFactor) {
        ITradingStorage.Trade memory trade = _input.trade;
        ITradingStorage.TradeInfo memory tradeInfo = TradingCommonUtils.getTradeInfo(trade.user, trade.index);

        if (tradeInfo.contractsVersion < ITradingStorage.ContractsVersion.V9_2) {
            output.priceAfterImpact = uint64(_input.oraclePrice);
            return (output, 0);
        }

        bool open = false;
        uint256 positionSizeUsd = _getMultiCollatDiamond().getUsdNormalizedValue(
            trade.collateralIndex,
            _input.positionSizeCollateral
        );
        output.positionSizeToken =
            (_input.positionSizeCollateral * trade.positionSizeToken) /
            getPositionSizeCollateral(trade.collateralAmount, trade.leverage);

        output.fixedSpreadP = getFixedSpreadP(
            _getMultiCollatDiamond().pairSpreadP(trade.user, trade.pairIndex),
            trade.long,
            open
        );

        output.skewPriceImpactP = tradeInfo.contractsVersion < ITradingStorage.ContractsVersion.V10
            ? int256(0)
            : _getMultiCollatDiamond().getTradeSkewPriceImpactP(
                trade.collateralIndex,
                trade.pairIndex,
                trade.long,
                output.positionSizeToken,
                open
            );

        if (!_input.useCumulativeVolPriceImpact) {
            output.totalPriceImpactP = output.fixedSpreadP + output.skewPriceImpactP;
            output.priceAfterImpact = getPriceAfterImpact(_input.oraclePrice, output.totalPriceImpactP);

            return (output, 0);
        }

        // Calculate PnL without protection factor
        int256 cumulVolPriceImpactP = _getMultiCollatDiamond().getTradeCumulVolPriceImpactP(
            trade.user,
            trade.pairIndex,
            trade.long,
            positionSizeUsd,
            false, // assume pnl negative, so it doesn't use protection factor
            open,
            tradeInfo.lastPosIncreaseBlock
        );

        tradeValueCollateralNoFactor = getTradeValueCollateral(
            trade,
            getPnlPercent(
                trade.openPrice,
                getPriceAfterImpact(
                    _input.oraclePrice,
                    output.fixedSpreadP + cumulVolPriceImpactP + output.skewPriceImpactP
                ),
                trade.long,
                trade.leverage
            ),
            getTotalTradeFeesCollateral(
                trade.collateralIndex,
                trade.user,
                trade.pairIndex,
                getPositionSizeCollateral(trade.collateralAmount, trade.leverage),
                trade.isCounterTrade
            ),
            _input.currentPairPrice
        );

        // Calculate final cumulative vol based on net PnL
        output.cumulVolPriceImpactP = _getMultiCollatDiamond().getTradeCumulVolPriceImpactP(
            trade.user,
            trade.pairIndex,
            trade.long,
            positionSizeUsd,
            tradeValueCollateralNoFactor > trade.collateralAmount, // _isPnlPositive = true when net pnl after fees is positive
            open,
            tradeInfo.lastPosIncreaseBlock
        );

        output.totalPriceImpactP = output.fixedSpreadP + output.cumulVolPriceImpactP + output.skewPriceImpactP;
        output.priceAfterImpact = getPriceAfterImpact(_input.oraclePrice, output.totalPriceImpactP);
    }

    /**
     * @dev Returns a trade's liquidation threshold % (1e10)
     * @param _trade trade struct
     */
    function getTradeLiqPnlThresholdP(ITradingStorage.Trade memory _trade) public view returns (uint256) {
        return
            getLiqPnlThresholdP(
                _getMultiCollatDiamond().getTradeLiquidationParams(_trade.user, _trade.index),
                _trade.leverage
            );
    }

    /**
     * @dev Returns total fee for a trade in collateral tokens
     * @param _collateralIndex collateral index
     * @param _trader address of trader
     * @param _pairIndex index of pair
     * @param _positionSizeCollateral position size in collateral tokens (collateral precision)
     * @param _isCounterTrade whether trade is counter trade
     */
    function getTotalTradeFeesCollateral(
        uint8 _collateralIndex,
        address _trader,
        uint16 _pairIndex,
        uint256 _positionSizeCollateral,
        bool _isCounterTrade
    ) public view returns (uint256) {
        uint256 feeRateP = _getMultiCollatDiamond().pairTotalPositionSizeFeeP(_pairIndex);

        uint256 feeRateMultiplier = _isCounterTrade
            ? _getMultiCollatDiamond().getPairCounterTradeFeeRateMultiplier(_pairIndex)
            : 1e3;

        uint256 rawFeeCollateral = (getPositionSizeCollateralBasis(
            _collateralIndex,
            _pairIndex,
            _positionSizeCollateral,
            feeRateMultiplier
        ) * feeRateP) /
            ConstantsUtils.P_10 /
            100 /
            1e3;

        // Fee tier is applied on min fee, but counter trade fee rate multiplier doesn't impact min fee
        return _getMultiCollatDiamond().calculateFeeAmount(_trader, rawFeeCollateral);
    }

    /**
     * @dev Returns total liquidation fees for a trade in collateral tokens
     * @param _pairIndex index of pair
     * @param _collateralAmount trade collateral amount (collateral precision)
     */
    function getTotalTradeLiqFeesCollateral(
        uint16 _pairIndex,
        uint256 _collateralAmount
    ) public view returns (uint256) {
        uint256 totalLiqCollateralFeeP = _getMultiCollatDiamond().pairTotalLiqCollateralFeeP(_pairIndex);
        return (_collateralAmount * totalLiqCollateralFeeP) / ConstantsUtils.P_10 / 100;
    }

    /**
     * @dev Returns all fees for a trade in collateral tokens
     * @param _collateralIndex index of collateral
     * @param _pairIndex index of pair
     * @param _trader address of trader
     * @param _orderType corresponding order type
     * @param _totalFeeCollateral total fee in collateral tokens (collateral precision)
     */
    function getTradeFeesCollateral(
        uint8 _collateralIndex,
        uint16 _pairIndex,
        address _trader,
        ITradingStorage.PendingOrderType _orderType,
        uint256 _totalFeeCollateral
    ) public view returns (IPairsStorage.TradeFees memory tradeFees) {
        IPairsStorage.GlobalTradeFeeParams memory feeParams = _getMultiCollatDiamond().getTradeFeeParams(
            _collateralIndex,
            _pairIndex
        );
        tradeFees.totalFeeCollateral = _totalFeeCollateral;

        // 1.1 Calculate referral fee
        address referrer = _getMultiCollatDiamond().getTraderActiveReferrer(_trader);

        if (referrer != address(0)) {
            uint256 referralFeeP_override = _getMultiCollatDiamond()
                .getReferralSettingsOverrides(referrer)
                .referralFeeOverrideP;
            uint256 referralFeeP = referralFeeP_override > 0 ? referralFeeP_override : feeParams.referralFeeP;
            uint256 referralFeeRaw = (tradeFees.totalFeeCollateral * referralFeeP) / 1e3 / 100;

            tradeFees.referralFeeCollateral =
                (referralFeeRaw * _getMultiCollatDiamond().getReferrerFeeProgressP(referrer)) /
                ConstantsUtils.P_10 /
                100;
        }

        // 1.2 Remove referral fee from total used to calculate gov, trigger, otc, and gToken fees
        uint256 totalFeeCollateral = tradeFees.totalFeeCollateral - tradeFees.referralFeeCollateral;

        // 2. Gov fee
        tradeFees.govFeeCollateral = ((totalFeeCollateral * feeParams.govFeeP) / 1e3 / 100);

        // 3. Trigger fee
        uint256 triggerOrderFeeCollateral = (totalFeeCollateral * feeParams.triggerOrderFeeP) / 1e3 / 100;
        tradeFees.triggerOrderFeeCollateral = ConstantsUtils.isOrderTypeMarket(_orderType)
            ? 0
            : triggerOrderFeeCollateral;

        // 4. GNS OTC fee, gets the trigger fee when not charged (market orders)
        uint256 missingTriggerOrderFeeCollateral = triggerOrderFeeCollateral - tradeFees.triggerOrderFeeCollateral;
        tradeFees.gnsOtcFeeCollateral =
            ((totalFeeCollateral * feeParams.gnsOtcFeeP) / 1e3 / 100) +
            missingTriggerOrderFeeCollateral;

        // 5. gToken fee
        tradeFees.gTokenFeeCollateral = (totalFeeCollateral * feeParams.gTokenFeeP) / 1e3 / 100;

        // 6. gToken OC fee
        tradeFees.gTokenOcFeeCollateral = (totalFeeCollateral * feeParams.gTokenOcFeeP) / 1e3 / 100;
    }

    /**
     * @dev Returns minimum gov fee in collateral tokens (collateral precision)
     * @param _collateralIndex collateral index
     * @param _trader trader address
     * @param _pairIndex pair index
     */
    function getMinGovFeeCollateral(
        uint8 _collateralIndex,
        address _trader,
        uint16 _pairIndex
    ) public view returns (uint256) {
        uint256 totalFeeCollateral = getTotalTradeFeesCollateral(
            _collateralIndex,
            _trader,
            _pairIndex,
            0, // position size is 0 so it will use the minimum pos
            false
        ) / 2; // charge fee on min pos / 2

        return
            (totalFeeCollateral * _getMultiCollatDiamond().getTradeFeeParams(_collateralIndex, _pairIndex).govFeeP) /
            1e3 /
            100;
    }

    /**
     * @dev Reverts if user initiated any kind of pending market order on his trade
     * @param _user trade user
     * @param _index trade index
     */
    function revertIfTradeHasPendingMarketOrder(address _user, uint32 _index) public view {
        ITradingStorage.PendingOrderType[9] memory pendingOrderTypes = ConstantsUtils.getMarketOrderTypes();
        ITradingStorage.Id memory tradeId = ITradingStorage.Id(_user, _index);

        for (uint256 i; i < pendingOrderTypes.length; ++i) {
            ITradingStorage.PendingOrderType orderType = pendingOrderTypes[i];
            if (
                orderType == ITradingStorage.PendingOrderType.MANUAL_HOLDING_FEES_REALIZATION ||
                orderType == ITradingStorage.PendingOrderType.MANUAL_NEGATIVE_PNL_REALIZATION
            ) continue;

            if (_getMultiCollatDiamond().getTradePendingOrderBlock(tradeId, orderType) > 0)
                revert ITradingInteractionsUtils.ConflictingPendingOrder(orderType);
        }
    }

    /**
     * @dev Returns gToken contract for a collateral index
     * @param _collateralIndex collateral index
     */
    function getGToken(uint8 _collateralIndex) public view returns (IGToken) {
        return IGToken(_getMultiCollatDiamond().getGToken(_collateralIndex));
    }

    /**
     * @dev Returns pair total initial open interest (before v10 + after v10) in collateral tokens (collateral precision)
     * @param _collateralIndex index of collateral
     * @param _pairIndex index of pair
     */
    function getPairTotalOisCollateral(
        uint8 _collateralIndex,
        uint16 _pairIndex
    ) internal view returns (uint256 totalOiLongCollateral, uint256 totalOiShortCollateral) {
        (uint256 longOiBeforeV10Collateral, uint256 shortOiBeforeV10Collateral) = _getMultiCollatDiamond()
            .getPairOisBeforeV10Collateral(_collateralIndex, _pairIndex);

        IPriceImpact.PairOiCollateral memory pairOiAfterV10Collateral = _getMultiCollatDiamond()
            .getPairOiAfterV10Collateral(_collateralIndex, _pairIndex);

        return (
            longOiBeforeV10Collateral + pairOiAfterV10Collateral.oiLongCollateral,
            shortOiBeforeV10Collateral + pairOiAfterV10Collateral.oiShortCollateral
        );
    }

    /**
     * @dev Returns pair total dynamic open interest (before v10 + after v10) in collateral tokens (collateral precision)
     * @param _collateralIndex index of collateral
     * @param _pairIndex index of pair
     * @param _currentPairPrice current pair price (1e10)
     */
    function getPairTotalOisDynamicCollateral(
        uint8 _collateralIndex,
        uint16 _pairIndex,
        uint256 _currentPairPrice
    ) internal view returns (uint256 oiLongCollateralDynamicAfterV10, uint256 oiShortCollateralDynamicAfterV10) {
        // We have to use the initial collateral OIs for pre-v10 trades because we don't have OIs in token amount
        (uint256 oiLongCollateralBeforeV10, uint256 oiShortCollateralBeforeV10) = _getMultiCollatDiamond()
            .getPairOisBeforeV10Collateral(_collateralIndex, _pairIndex); // collateral precision

        IPriceImpact.PairOiToken memory pairOiAfterV10Token = _getMultiCollatDiamond().getPairOiAfterV10Token(
            _collateralIndex,
            _pairIndex
        );
        uint256 precisionDelta = _getMultiCollatDiamond().getCollateral(_collateralIndex).precisionDelta;

        oiLongCollateralDynamicAfterV10 =
            oiLongCollateralBeforeV10 +
            (pairOiAfterV10Token.oiLongToken * _currentPairPrice) /
            1e10 /
            precisionDelta; // collateral precision

        oiShortCollateralDynamicAfterV10 =
            oiShortCollateralBeforeV10 +
            (pairOiAfterV10Token.oiShortToken * _currentPairPrice) /
            1e10 /
            precisionDelta; // collateral precision
    }

    /**
     * @dev Returns pair total dynamic open interest (before v10 + after v10) in collateral tokens on one side only (collateral precision)
     * @param _collateralIndex index of collateral
     * @param _pairIndex index of pair
     * @param _long true if long, false if short
     * @param _currentPairPrice current pair price (1e10)
     */
    function getPairTotalOiDynamicCollateral(
        uint8 _collateralIndex,
        uint16 _pairIndex,
        bool _long,
        uint256 _currentPairPrice
    ) internal view returns (uint256) {
        (
            uint256 oiLongCollateralDynamicAfterV10,
            uint256 oiShortCollateralDynamicAfterV10
        ) = getPairTotalOisDynamicCollateral(_collateralIndex, _pairIndex, _currentPairPrice); // collateral precision

        return _long ? oiLongCollateralDynamicAfterV10 : oiShortCollateralDynamicAfterV10;
    }

    /**
     * @dev Returns pair open interest skew (v10 only) in tokens (1e18)
     * @param _collateralIndex index of collateral
     * @param _pairIndex index of pair
     */
    function getPairV10OiTokenSkewCollateral(uint8 _collateralIndex, uint16 _pairIndex) internal view returns (int256) {
        IPriceImpact.PairOiToken memory pairOiToken = _getMultiCollatDiamond().getPairOiAfterV10Token(
            _collateralIndex,
            _pairIndex
        );

        return int256(uint256(pairOiToken.oiLongToken)) - int256(uint256(pairOiToken.oiShortToken));
    }

    /**
     * @dev Returns pair dynamic skew (v10 only) in collateral tokens (1e10 precision)
     * @param _collateralIndex index of collateral
     * @param _pairIndex index of pair
     * @param _currentPairPrice current price of pair (1e10)
     */
    function getPairV10OiDynamicSkewCollateral(
        uint8 _collateralIndex,
        uint16 _pairIndex,
        uint256 _currentPairPrice
    ) internal view returns (int256) {
        return (getPairV10OiTokenSkewCollateral(_collateralIndex, _pairIndex) * int256(_currentPairPrice)) / 1e18; // 1e10
    }

    /**
     * @dev Returns min fee in collateral tokens for a pair (collateral precision)
     * @param _collateralIndex index of collateral
     * @param _pairIndex index of pair
     */
    function getPairMinFeeCollateral(uint8 _collateralIndex, uint16 _pairIndex) public view returns (uint256) {
        return
            _getMultiCollatDiamond().getCollateralFromUsdNormalizedValue(
                _collateralIndex,
                _getMultiCollatDiamond().pairMinFeeUsd(_pairIndex)
            );
    }

    /**
     * @dev Returns min opening collateral for a pair (collateral precision)
     * @param _collateralIndex index of collateral
     * @param _pairIndex index of pair
     */
    function getPairMinOpeningCollateral(uint8 _collateralIndex, uint16 _pairIndex) public view returns (uint256) {
        return 5 * getPairMinFeeCollateral(_collateralIndex, _pairIndex);
    }

    /**
     * @dev Validates a counter trade based on pair OI skew, and returns how much collateral to send back
     * @param _trade trade struct
     * @param _positionSizeCollateral position size in collateral tokens (collateral precision)
     * @param _currentPairPrice current pair price (1e10)
     */
    function validateCounterTrade(
        ITradingStorage.Trade memory _trade,
        uint256 _positionSizeCollateral,
        uint64 _currentPairPrice
    ) external view returns (bool isValidated, uint256 exceedingPositionSizeCollateral) {
        int256 positionSizeCollateralSigned = int256(_positionSizeCollateral) * (_trade.long ? int256(1) : int256(-1));
        int256 pairOiSkewCollateral = (getPairV10OiDynamicSkewCollateral(
            _trade.collateralIndex,
            _trade.pairIndex,
            _currentPairPrice
        ) * 1e8) / int256(uint256(_getMultiCollatDiamond().getCollateral(_trade.collateralIndex).precisionDelta)); // collateral precision

        // Signed position size of trade should be opposite sign of pair OI skew since it should lower exposure
        if (
            pairOiSkewCollateral == 0 ||
            (pairOiSkewCollateral > 0 && positionSizeCollateralSigned > 0) ||
            (pairOiSkewCollateral < 0 && positionSizeCollateralSigned < 0)
        ) return (false, 0);

        // Calculate exceeding position size to make skew 0
        uint256 maxPositionSizeCollateral = uint256(
            pairOiSkewCollateral < 0 ? -pairOiSkewCollateral : pairOiSkewCollateral
        );
        if (_positionSizeCollateral > maxPositionSizeCollateral)
            exceedingPositionSizeCollateral = _positionSizeCollateral - maxPositionSizeCollateral;

        return (true, exceedingPositionSizeCollateral);
    }

    /**
     * @dev Returns trade's effective leverage (1e3 precision)
     * @param _trade trade struct
     * @param _newOpenPrice new trade open price (1e10)
     * @param _newCollateralAmount new trade collateral amount (collateral precision)
     * @param _newLeverage new leverage (1e3)
     * @param _currentPairPrice current price of pair (1e10)
     * @param _additionalFeeCollateral additional fee / negative pnl in collateral tokens (collateral precision)
     */
    function getTradeNewEffectiveLeverage(
        ITradingStorage.Trade memory _trade,
        uint64 _newOpenPrice,
        uint120 _newCollateralAmount,
        uint24 _newLeverage,
        uint64 _currentPairPrice,
        uint256 _additionalFeeCollateral
    ) external view returns (uint24) {
        ITradingStorage.Trade memory newTrade = _trade;
        newTrade.openPrice = _newOpenPrice;
        newTrade.collateralAmount = _newCollateralAmount;
        newTrade.leverage = _newLeverage;

        uint256 newPosSizeCollateral = getPositionSizeCollateral(newTrade.collateralAmount, newTrade.leverage);
        (ITradingCommonUtils.TradePriceImpact memory priceImpact, ) = getTradeClosingPriceImpact(
            ITradingCommonUtils.TradePriceImpactInput(
                newTrade,
                _currentPairPrice,
                newPosSizeCollateral,
                _currentPairPrice,
                true
            )
        );

        uint256 newMarginValueCollateral = getTradeValueCollateral(
            newTrade,
            getPnlPercent(newTrade.openPrice, priceImpact.priceAfterImpact, newTrade.long, newTrade.leverage),
            getTotalTradeFeesCollateral(
                newTrade.collateralIndex,
                newTrade.user,
                newTrade.pairIndex,
                newPosSizeCollateral,
                newTrade.isCounterTrade
            ) + _additionalFeeCollateral,
            _currentPairPrice
        );

        if (newMarginValueCollateral == 0) return type(uint24).max;

        uint256 newPosSizeCollateralDynamic = (newPosSizeCollateral * _currentPairPrice) / _newOpenPrice;
        uint256 newEffectiveLeverage = (newPosSizeCollateralDynamic * 1e3) / newMarginValueCollateral;

        uint24 maxLeverage = type(uint24).max;
        return newEffectiveLeverage > maxLeverage ? maxLeverage : uint24(newEffectiveLeverage);
    }

    /**
     * @dev Returns a trade's available collateral in diamond contract (collateral precision)
     * @param _trader trader address
     * @param _index trade index
     * @param _collateralAmount trade collateral amount (collateral precision)
     */
    function getTradeAvailableCollateralInDiamond(
        address _trader,
        uint32 _index,
        uint256 _collateralAmount
    ) internal view returns (uint256) {
        int256 tradeAvailableCollateralInDiamondRaw = getTradeAvailableCollateralInDiamondRaw(
            _trader,
            _index,
            _collateralAmount
        );

        /// @dev Under no circumstance should the total available collateral in diamond be negative after a trading operation
        if (tradeAvailableCollateralInDiamondRaw < 0) {
            revert IGeneralErrors.BelowMin();
        }

        return uint256(tradeAvailableCollateralInDiamondRaw);
    }

    /**
     * @dev Returns a trade's raw available collateral in diamond contract (collateral precision)
     * @param _trader trader address
     * @param _index trade index
     * @param _collateralAmount trade collateral amount (collateral precision)
     */
    function getTradeAvailableCollateralInDiamondRaw(
        address _trader,
        uint32 _index,
        uint256 _collateralAmount
    ) internal view returns (int256) {
        IFundingFees.TradeFeesData memory tradeFeesData = _getMultiCollatDiamond().getTradeFeesData(_trader, _index);

        return
            int256(_collateralAmount + uint256(tradeFeesData.virtualAvailableCollateralInDiamond)) -
            int256(
                uint256(
                    tradeFeesData.realizedTradingFeesCollateral +
                        tradeFeesData.manuallyRealizedNegativePnlCollateral +
                        tradeFeesData.alreadyTransferredNegativePnlCollateral
                )
            );
    }

    /**
     * @dev Returns the current market price adjusted for skew impact
     * @param _collateralIndex index of collateral
     * @param _pairIndex index of pair
     * @param _currentPairPrice current pair price (1e10)
     */
    function getMarketPrice(
        uint8 _collateralIndex,
        uint16 _pairIndex,
        uint64 _currentPairPrice
    ) internal view returns (uint64 result) {
        int256 skewImpactP = _getMultiCollatDiamond().getTradeSkewPriceImpactP(
            _collateralIndex,
            _pairIndex,
            true, // Not used for size 0
            0, // Size 0 for current market price
            true // Not used for size 0
        );

        result = getPriceAfterImpact(_currentPairPrice, skewImpactP);
    }

    /**
     * @dev Reverse engineers oracle price from market price by removing skew impact
     * @param _collateralIndex Collateral index
     * @param _pairIndex Pair index
     * @param _marketPrice Market price (includes skew impact)
     * @return oraclePrice Oracle price without skew impact
     */
    function deriveOraclePrice(
        uint8 _collateralIndex,
        uint16 _pairIndex,
        uint64 _marketPrice
    ) internal view returns (uint64) {
        // Get current skew impact with position size 0
        int256 skewImpactP = _getMultiCollatDiamond().getTradeSkewPriceImpactP(
            _collateralIndex,
            _pairIndex,
            true, // Not used for size 0
            0, // Size 0 for current skew impact
            true // Not used for size 0
        );

        // Reverse getMarketPrice
        return
            uint64(
                Math.mulDiv(
                    uint256(_marketPrice),
                    ConstantsUtils.P_10 * 100,
                    uint256(int256(ConstantsUtils.P_10 * 100) + skewImpactP),
                    Math.Rounding.Up
                )
            );
    }

    // Transfers

    /**
     * @dev Transfers collateral from trader
     * @param _collateralIndex index of the collateral
     * @param _from sending address
     * @param _amountCollateral amount of collateral to receive (collateral precision)
     */
    function transferCollateralFrom(uint8 _collateralIndex, address _from, uint256 _amountCollateral) public {
        if (_amountCollateral > 0) {
            _getMultiCollatDiamond().getCollateral(_collateralIndex).collateral.transferFrom(
                _from,
                address(this),
                _amountCollateral
            );
        }
    }

    /**
     * @dev Transfers collateral to trader
     * @param _collateralIndex index of the collateral
     * @param _to receiving address
     * @param _amountCollateral amount of collateral to transfer (collateral precision)
     */
    function transferCollateralTo(uint8 _collateralIndex, address _to, uint256 _amountCollateral) internal {
        transferCollateralTo(_collateralIndex, _to, _amountCollateral, true);
    }

    /**
     * @dev Transfers collateral to trader
     * @param _collateralIndex index of the collateral
     * @param _to receiving address
     * @param _amountCollateral amount of collateral to transfer (collateral precision)
     * @param _unwrapNativeToken whether to try and unwrap native token before sending
     */
    function transferCollateralTo(
        uint8 _collateralIndex,
        address _to,
        uint256 _amountCollateral,
        bool _unwrapNativeToken
    ) internal {
        if (_amountCollateral > 0) {
            address collateral = _getMultiCollatDiamond().getCollateral(_collateralIndex).collateral;

            if (
                _unwrapNativeToken &&
                ChainUtils.isWrappedNativeToken(collateral) &&
                ChainConfigUtils.getNativeTransferEnabled()
            ) {
                collateral.unwrapAndTransferNative(
                    _to,
                    _amountCollateral,
                    uint256(ChainConfigUtils.getNativeTransferGasLimit())
                );
            } else {
                collateral.transfer(_to, _amountCollateral);
            }
        }
    }

    /**
     * @dev Transfers GNS to address
     * @param _to receiving address
     * @param _amountGns amount of GNS to transfer (1e18)
     */
    function transferGnsTo(address _to, uint256 _amountGns) internal {
        if (_amountGns > 0) {
            AddressStoreUtils.getAddresses().gns.transfer(_to, _amountGns);
        }
    }

    /**
     * @dev Transfers GNS from address
     * @param _from sending address
     * @param _amountGns amount of GNS to receive (1e18)
     */
    function transferGnsFrom(address _from, uint256 _amountGns) internal {
        if (_amountGns > 0) {
            AddressStoreUtils.getAddresses().gns.transferFrom(_from, address(this), _amountGns);
        }
    }

    /**
     * @dev Sends collateral to gToken vault
     * @param _collateralIndex collateral index
     * @param _amountCollateral amount of collateral to send to vault (collateral precision)
     * @param _trader trader address
     * @param _burn true if should burn
     */
    function transferCollateralToVault(
        uint8 _collateralIndex,
        uint256 _amountCollateral,
        address _trader,
        bool _burn
    ) public {
        if (_amountCollateral > 0) getGToken(_collateralIndex).receiveAssets(_amountCollateral, _trader, _burn);
    }

    /**
     * @dev Sends fee collateral to gToken vault
     * @param _collateralIndex collateral index
     * @param _amountCollateral amount of collateral to send to vault (collateral precision)
     * @param _trader trader address
     */
    function transferFeeToVault(uint8 _collateralIndex, uint256 _amountCollateral, address _trader) public {
        transferCollateralToVault(_collateralIndex, _amountCollateral, _trader, false); // don't burn fees
    }

    /**
     * @dev Receives collateral from gToken vault
     * @param _collateralIndex collateral index
     * @param _amountCollateral amount of collateral to receive from vault (collateral precision)
     */
    function receiveCollateralFromVault(uint8 _collateralIndex, uint256 _amountCollateral) public {
        if (_amountCollateral > 0) getGToken(_collateralIndex).sendAssets(_amountCollateral, address(this));
    }

    /**
     * @dev Handles value transfers based on amount to send to trader and available collateral in diamond
     * @param _trade trade struct
     * @param _collateralSentToTrader total amount to send to trader (collateral precision), can only be negative for partial closes (leverage decrease)
     * @param _availableCollateralInDiamond part of _collateralSentToTrader available in diamond balance (collateral precision), can be negative for full/partial closes (collateral decrease)
     */
    function handleTradeValueTransfer(
        ITradingStorage.Trade memory _trade,
        int256 _collateralSentToTrader,
        int256 _availableCollateralInDiamond
    ) external {
        if (_availableCollateralInDiamond < 0 && _collateralSentToTrader < 0) revert IGeneralErrors.NotAuthorized();

        if (_collateralSentToTrader > _availableCollateralInDiamond) {
            // Calculate amount to be received from gToken
            int256 collateralFromGToken = _collateralSentToTrader - _availableCollateralInDiamond;

            // Receive PNL from gToken; This is sent to the trader at a later point
            receiveCollateralFromVault(_trade.collateralIndex, uint256(collateralFromGToken));
        } else if (_collateralSentToTrader < _availableCollateralInDiamond) {
            // Send loss to gToken
            transferCollateralToVault(
                _trade.collateralIndex,
                uint256(_availableCollateralInDiamond - _collateralSentToTrader),
                _trade.user,
                // any amount sent to vault at this point is negative PnL, funding fees already sent with _burn = false
                // only use _burn = true if the pair does not have a skipBurn flag active
                !_getMultiCollatDiamond().getPairFlags(_trade.collateralIndex, _trade.pairIndex).skipBurn
            );
        }

        // Send collateral to trader, if any
        if (_collateralSentToTrader > 0) {
            transferCollateralTo(_trade.collateralIndex, _trade.user, uint256(_collateralSentToTrader));
        }

        emit ITradingCommonUtils.TradeValueTransferred(
            _trade.collateralIndex,
            _trade.user,
            _trade.index,
            _collateralSentToTrader,
            _availableCollateralInDiamond
        );
    }

    // Fees

    /**
     * @dev Updates a trader's fee tiers points based on his trade size
     * @param _collateralIndex collateral index
     * @param _trader address of trader
     * @param _positionSizeCollateral position size in collateral tokens (collateral precision)
     * @param _pairIndex index of pair
     */
    function updateFeeTierPoints(
        uint8 _collateralIndex,
        address _trader,
        uint256 _pairIndex,
        uint256 _positionSizeCollateral
    ) public {
        uint256 usdNormalizedPositionSize = _getMultiCollatDiamond().getUsdNormalizedValue(
            _collateralIndex,
            _positionSizeCollateral
        );
        _getMultiCollatDiamond().updateTraderPoints(_trader, usdNormalizedPositionSize, _pairIndex);
    }

    /**
     * @dev Distributes fee to gToken vault
     * @param _collateralIndex index of collateral
     * @param _trader address of trader
     * @param _valueCollateral fee in collateral tokens (collateral precision)
     */
    function distributeVaultFeeCollateral(uint8 _collateralIndex, address _trader, uint256 _valueCollateral) public {
        getGToken(_collateralIndex).distributeReward(_valueCollateral);
        emit ITradingCommonUtils.GTokenFeeCharged(_trader, _collateralIndex, _valueCollateral);
    }

    /**
     * @dev Distributes fee to gToken vault OC
     * @param _collateralIndex index of collateral
     * @param _trader address of trader
     * @param _valueCollateral fee in collateral tokens (collateral precision)
     */
    function distributeVaultOcFeeCollateral(
        uint8 _collateralIndex,
        address _trader,
        uint256 _valueCollateral
    ) internal {
        transferFeeToVault(_collateralIndex, _valueCollateral, _trader);
        emit ITradingCommonUtils.GTokenOcFeeCharged(_trader, _collateralIndex, _valueCollateral);
    }

    /**
     * @dev Distributes gov fees exact amount
     * @param _collateralIndex index of collateral
     * @param _trader address of trader
     * @param _govFeeCollateral position size in collateral tokens (collateral precision)
     */
    function distributeExactGovFeeCollateral(
        uint8 _collateralIndex,
        address _trader,
        uint256 _govFeeCollateral
    ) public {
        TradingCallbacksUtils._getStorage().pendingGovFees[_collateralIndex] += _govFeeCollateral;
        emit ITradingCommonUtils.GovFeeCharged(_trader, _collateralIndex, _govFeeCollateral);
    }

    /**
     * @dev Increases OTC balance to be distributed once OTC is executed
     * @param _collateralIndex collateral index
     * @param _trader trader address
     * @param _amountCollateral amount of collateral tokens to distribute (collateral precision)
     */
    function distributeGnsOtcFeeCollateral(uint8 _collateralIndex, address _trader, uint256 _amountCollateral) public {
        _getMultiCollatDiamond().addOtcCollateralBalance(_collateralIndex, _amountCollateral);
        emit ITradingCommonUtils.GnsOtcFeeCharged(_trader, _collateralIndex, _amountCollateral);
    }

    /**
     * @dev Distributes trigger fee in GNS tokens
     * @param _trader address of trader
     * @param _collateralIndex index of collateral
     * @param _triggerFeeCollateral trigger fee in collateral tokens (collateral precision)
     * @param _gnsPriceCollateral gns/collateral price (1e10 precision)
     * @param _collateralPrecisionDelta collateral precision delta (10^18/10^decimals)
     */
    function distributeTriggerFeeGns(
        address _trader,
        uint8 _collateralIndex,
        uint256 _triggerFeeCollateral,
        uint256 _gnsPriceCollateral,
        uint128 _collateralPrecisionDelta
    ) public {
        transferFeeToVault(_collateralIndex, _triggerFeeCollateral, _trader);

        uint256 triggerFeeGns = convertCollateralToGns(
            _triggerFeeCollateral,
            _collateralPrecisionDelta,
            _gnsPriceCollateral
        );
        _getMultiCollatDiamond().distributeTriggerReward(triggerFeeGns);

        emit ITradingCommonUtils.TriggerFeeCharged(_trader, _collateralIndex, _triggerFeeCollateral);
    }

    /**
     * @dev Distributes opening fees for trade and returns the trade fees charged in collateral tokens
     * @dev Before calling: should refresh fee tier points
     * @param _trade trade struct
     * @param _positionSizeCollateral position size in collateral tokens (collateral precision)
     * @param _orderType trade order type
     * @param _totalFeeCollateral total fee in collateral tokens (collateral precision)
     */
    function processFees(
        ITradingStorage.Trade memory _trade,
        uint256 _positionSizeCollateral,
        ITradingStorage.PendingOrderType _orderType,
        uint256 _totalFeeCollateral
    ) external returns (uint256) {
        uint128 collateralPrecisionDelta = _getMultiCollatDiamond()
            .getCollateral(_trade.collateralIndex)
            .precisionDelta;
        uint256 gnsPriceCollateral = _getMultiCollatDiamond().getGnsPriceCollateralIndex(_trade.collateralIndex);

        // 1. Calculate all fees
        IPairsStorage.TradeFees memory tradeFees = getTradeFeesCollateral(
            _trade.collateralIndex,
            _trade.pairIndex,
            _trade.user,
            _orderType,
            _totalFeeCollateral
        );

        // 2.1 Distribute referral fee
        if (tradeFees.referralFeeCollateral > 0) {
            distributeReferralFeeCollateral(
                _trade.collateralIndex,
                _trade.user,
                _positionSizeCollateral,
                tradeFees.referralFeeCollateral,
                gnsPriceCollateral
            );
        }

        // 2.2 Distribute gov fee
        distributeExactGovFeeCollateral(_trade.collateralIndex, _trade.user, tradeFees.govFeeCollateral);

        // 2.3 Distribute trigger fee
        if (tradeFees.triggerOrderFeeCollateral > 0) {
            distributeTriggerFeeGns(
                _trade.user,
                _trade.collateralIndex,
                tradeFees.triggerOrderFeeCollateral,
                gnsPriceCollateral,
                collateralPrecisionDelta
            );
        }

        // 2.4 Distribute GNS OTC fee
        distributeGnsOtcFeeCollateral(_trade.collateralIndex, _trade.user, tradeFees.gnsOtcFeeCollateral);

        // 2.5 Distribute GToken fees
        distributeVaultFeeCollateral(_trade.collateralIndex, _trade.user, tradeFees.gTokenFeeCollateral);

        // 2.6 Distribute GToken OC fees
        if (tradeFees.gTokenOcFeeCollateral > 0) {
            distributeVaultOcFeeCollateral(_trade.collateralIndex, _trade.user, tradeFees.gTokenOcFeeCollateral);
        }

        // 3. Credit fee tier points
        updateFeeTierPoints(_trade.collateralIndex, _trade.user, _trade.pairIndex, _positionSizeCollateral);

        emit ITradingCommonUtils.FeesProcessed(
            _trade.collateralIndex,
            _trade.user,
            _positionSizeCollateral,
            _orderType,
            tradeFees.totalFeeCollateral
        );

        return tradeFees.totalFeeCollateral;
    }

    /**
     * @dev Distributes referral rewards and returns the amount charged in collateral tokens
     * @param _collateralIndex collateral index
     * @param _trader address of trader
     * @param _positionSizeCollateral position size in collateral tokens (collateral precision)
     * @param _referralFeeCollateral referral fee in collateral tokens (collateral precision)
     * @param _gnsPriceCollateral gns/collateral price (1e10 precision)
     */
    function distributeReferralFeeCollateral(
        uint8 _collateralIndex,
        address _trader,
        uint256 _positionSizeCollateral,
        uint256 _referralFeeCollateral,
        uint256 _gnsPriceCollateral
    ) public {
        _getMultiCollatDiamond().distributeReferralReward(
            _trader,
            _getMultiCollatDiamond().getUsdNormalizedValue(_collateralIndex, _positionSizeCollateral),
            _getMultiCollatDiamond().getUsdNormalizedValue(_collateralIndex, _referralFeeCollateral),
            _getMultiCollatDiamond().getGnsPriceUsd(_collateralIndex, _gnsPriceCollateral)
        );

        transferFeeToVault(_collateralIndex, _referralFeeCollateral, _trader);

        emit ITradingCommonUtils.ReferralFeeCharged(_trader, _collateralIndex, _referralFeeCollateral);
    }

    // Open interests

    /**
     * @dev Update protocol open interest (any amount)
     * @param _trade trade struct
     * @param _positionSizeCollateral position size in collateral tokens (collateral precision)
     * @param _positionSizeToken position size in tokens (1e18)
     * @param _open whether it corresponds to a trade opening or closing
     * @param _isPnlPositive whether it corresponds to a positive pnl trade (only relevant when _open = false)
     * @param _currentPairPrice current pair price (1e10)
     * @param _isPartial whether it corresponds to a partial update
     */
    function _updateOi(
        ITradingStorage.Trade memory _trade,
        uint256 _positionSizeCollateral,
        uint256 _positionSizeToken,
        bool _open,
        bool _isPnlPositive,
        uint64 _currentPairPrice,
        bool _isPartial
    ) private {
        if (_isPartial || !_open)
            _getMultiCollatDiamond().realizeHoldingFeesOnOpenTrade(_trade.user, _trade.index, _currentPairPrice);

        _getMultiCollatDiamond().storeTradeInitialAccFees(
            _trade.user,
            _trade.index,
            _trade.collateralIndex,
            _trade.pairIndex,
            _trade.long,
            _currentPairPrice
        );

        _getMultiCollatDiamond().handleTradeBorrowingCallback(
            _trade.collateralIndex,
            _trade.user,
            _trade.pairIndex,
            _trade.index,
            _positionSizeCollateral,
            _open,
            _trade.long,
            _currentPairPrice
        ); // updates group OI

        _getMultiCollatDiamond().addPriceImpactOpenInterest(
            _trade.user,
            _trade.index,
            _positionSizeCollateral,
            _open,
            _isPnlPositive
        );

        if (_open) {
            _getMultiCollatDiamond().updatePairOiAfterV10(
                _trade.collateralIndex,
                _trade.pairIndex,
                _positionSizeCollateral,
                _positionSizeToken,
                true, // increase
                _trade.long
            );
        } else {
            if (
                _getMultiCollatDiamond().getTradeContractsVersion(_trade.user, _trade.index) <
                ITradingStorage.ContractsVersion.V10
            ) {
                _getMultiCollatDiamond().updatePairOiBeforeV10(
                    _trade.collateralIndex,
                    _trade.pairIndex,
                    _trade.long,
                    false, // decrease
                    _positionSizeCollateral
                );
            } else {
                _getMultiCollatDiamond().updatePairOiAfterV10(
                    _trade.collateralIndex,
                    _trade.pairIndex,
                    _positionSizeCollateral,
                    _positionSizeToken,
                    false, // decrease
                    _trade.long
                );
            }
        }
    }

    /**
     * @dev Handles all necessary OI-related callbacks for opening a new trade
     * @param _trade trade struct
     * @param _currentPairPrice current pair price (1e10)
     */
    function addNewTradeOi(ITradingStorage.Trade memory _trade, uint64 _currentPairPrice) external {
        uint256 positionSizeCollateral = getPositionSizeCollateral(_trade.collateralAmount, _trade.leverage);
        _updateOi(_trade, positionSizeCollateral, _trade.positionSizeToken, true, false, _currentPairPrice, false);
    }

    /**
     * @dev Handles all necessary OI-related callbacks for closing a trade
     * @param _trade trade struct
     * @param _isPnlPositive whether it corresponds to a positive pnl trade
     * @param _currentPairPrice current pair price (1e10)
     */
    function removeTradeOi(
        ITradingStorage.Trade memory _trade,
        bool _isPnlPositive,
        uint64 _currentPairPrice
    ) external {
        uint256 positionSizeCollateral = getPositionSizeCollateral(_trade.collateralAmount, _trade.leverage);
        _updateOi(
            _trade,
            positionSizeCollateral,
            _trade.positionSizeToken,
            false,
            _isPnlPositive,
            _currentPairPrice,
            false
        );
    }

    /**
     * @dev Handles OI delta for an existing trade (for trade updates)
     * @param _trade trade struct
     * @param _newPositionSizeCollateral new position size in collateral tokens (collateral precision)
     * @param _positionSizeTokenDelta position size delta in tokens (1e18)
     * @param _isPnlPositive whether it corresponds to a positive pnl trade (only relevant when closing)
     * @param _currentPairPrice current pair price (1e10)
     */
    function handleOiDelta(
        ITradingStorage.Trade memory _trade,
        uint256 _newPositionSizeCollateral,
        uint256 _positionSizeTokenDelta,
        bool _isPnlPositive,
        uint64 _currentPairPrice
    ) external {
        uint256 existingPositionSizeCollateral = getPositionSizeCollateral(_trade.collateralAmount, _trade.leverage);
        bool isIncrease = _newPositionSizeCollateral > existingPositionSizeCollateral;

        uint256 positionSizeCollateralDelta = isIncrease
            ? _newPositionSizeCollateral - existingPositionSizeCollateral
            : existingPositionSizeCollateral - _newPositionSizeCollateral;

        _updateOi(
            _trade,
            positionSizeCollateralDelta,
            _positionSizeTokenDelta,
            isIncrease,
            _isPnlPositive,
            _currentPairPrice,
            true
        );
    }

    /**
     * @dev Returns current address as multi-collateral diamond interface to call other facets functions.
     */
    function _getMultiCollatDiamond() internal view returns (IGNSMultiCollatDiamond) {
        return IGNSMultiCollatDiamond(address(this));
    }
}
