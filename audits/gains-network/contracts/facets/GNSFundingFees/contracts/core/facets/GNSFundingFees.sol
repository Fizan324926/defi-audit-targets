// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../abstract/GNSAddressStore.sol";

import "../../interfaces/libraries/IFundingFeesUtils.sol";

import "../../libraries/FundingFeesUtils.sol";

/**
 * @dev Facet #14: Funding Fees
 */
contract GNSFundingFees is GNSAddressStore, IFundingFeesUtils {
    // Initialization

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // Management Setters

    /// @inheritdoc IFundingFeesUtils
    function setMaxSkewCollateral(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex,
        uint80[] calldata _maxSkewCollateral
    ) external onlyRoles(Role.MANAGER, Role.GOV_EMERGENCY) {
        FundingFeesUtils.setMaxSkewCollateral(_collateralIndex, _pairIndex, _maxSkewCollateral);
    }

    /// @inheritdoc IFundingFeesUtils
    function setSkewCoefficientPerYear(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex,
        uint112[] calldata _skewCoefficientPerYear,
        IPriceAggregator.SignedPairPrices[] calldata _signedPairPrices
    ) external onlyRoles(Role.MANAGER, Role.GOV_EMERGENCY) {
        FundingFeesUtils.setSkewCoefficientPerYear(
            _collateralIndex,
            _pairIndex,
            _skewCoefficientPerYear,
            _signedPairPrices
        );
    }

    /// @inheritdoc IFundingFeesUtils
    function setAbsoluteVelocityPerYearCap(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex,
        uint24[] calldata _absoluteVelocityPerYearCap,
        IPriceAggregator.SignedPairPrices[] calldata _signedPairPrices
    ) external onlyRoles(Role.MANAGER, Role.GOV_EMERGENCY) {
        FundingFeesUtils.setAbsoluteVelocityPerYearCap(
            _collateralIndex,
            _pairIndex,
            _absoluteVelocityPerYearCap,
            _signedPairPrices
        );
    }

    /// @inheritdoc IFundingFeesUtils
    function setAbsoluteRatePerSecondCap(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex,
        uint24[] calldata _absoluteRatePerSecondCap,
        IPriceAggregator.SignedPairPrices[] calldata _signedPairPrices
    ) external onlyRoles(Role.MANAGER, Role.GOV_EMERGENCY) {
        FundingFeesUtils.setAbsoluteRatePerSecondCap(
            _collateralIndex,
            _pairIndex,
            _absoluteRatePerSecondCap,
            _signedPairPrices
        );
    }

    /// @inheritdoc IFundingFeesUtils
    function setThetaThresholdUsd(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex,
        uint32[] calldata _thetaThresholdUsd,
        IPriceAggregator.SignedPairPrices[] calldata _signedPairPrices
    ) external onlyRoles(Role.MANAGER, Role.GOV_EMERGENCY) {
        FundingFeesUtils.setThetaThresholdUsd(_collateralIndex, _pairIndex, _thetaThresholdUsd, _signedPairPrices);
    }

    /// @inheritdoc IFundingFeesUtils
    function setFundingFeesEnabled(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex,
        bool[] calldata _fundingFeesEnabled,
        IPriceAggregator.SignedPairPrices[] calldata _signedPairPrices
    ) external onlyRoles(Role.MANAGER, Role.GOV_EMERGENCY) {
        FundingFeesUtils.setFundingFeesEnabled(_collateralIndex, _pairIndex, _fundingFeesEnabled, _signedPairPrices);
    }

    /// @inheritdoc IFundingFeesUtils
    function setAprMultiplierEnabled(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex,
        bool[] calldata _aprMultiplierEnabled,
        IPriceAggregator.SignedPairPrices[] calldata _signedPairPrices
    ) external onlyRoles(Role.MANAGER, Role.GOV_EMERGENCY) {
        FundingFeesUtils.setAprMultiplierEnabled(
            _collateralIndex,
            _pairIndex,
            _aprMultiplierEnabled,
            _signedPairPrices
        );
    }

    /// @inheritdoc IFundingFeesUtils
    function setBorrowingRatePerSecondP(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex,
        uint24[] calldata _borrowingRatePerSecondP,
        IPriceAggregator.SignedPairPrices[] calldata _signedPairPrices
    ) external onlyRoles(Role.MANAGER, Role.GOV_EMERGENCY) {
        FundingFeesUtils.setBorrowingRatePerSecondP(
            _collateralIndex,
            _pairIndex,
            _borrowingRatePerSecondP,
            _signedPairPrices
        );
    }

    /// @inheritdoc IFundingFeesUtils
    function paramUpdateCallbackWithSignedPrices(
        IFundingFees.PendingParamUpdate memory _paramUpdate
    ) external onlySelf {
        FundingFeesUtils.paramUpdateCallbackWithSignedPrices(_paramUpdate);
    }

    // Interactions

    /// @inheritdoc IFundingFeesUtils
    function storeTradeInitialAccFees(
        address _trader,
        uint32 _index,
        uint8 _collateralIndex,
        uint16 _pairIndex,
        bool _long,
        uint64 _currentPairPrice
    ) external virtual onlySelf {
        FundingFeesUtils.storeTradeInitialAccFees(
            _trader,
            _index,
            _collateralIndex,
            _pairIndex,
            _long,
            _currentPairPrice
        );
    }

    /// @inheritdoc IFundingFeesUtils
    function realizeHoldingFeesOnOpenTrade(
        address _trader,
        uint32 _index,
        uint64 _currentPairPrice
    ) external virtual onlySelf {
        FundingFeesUtils.realizeHoldingFeesOnOpenTrade(_trader, _index, _currentPairPrice);
    }

    /// @inheritdoc IFundingFeesUtils
    function storeManuallyRealizedNegativePnlCollateral(
        address _trader,
        uint32 _index,
        uint256 _amountCollateral
    ) external virtual onlySelf {
        FundingFeesUtils.storeManuallyRealizedNegativePnlCollateral(_trader, _index, _amountCollateral);
    }

    /// @inheritdoc IFundingFeesUtils
    function realizePnlOnOpenTrade(address _trader, uint32 _index, int256 _pnlCollateral) external virtual onlySelf {
        FundingFeesUtils.realizePnlOnOpenTrade(_trader, _index, _pnlCollateral);
    }

    /// @inheritdoc IFundingFeesUtils
    function realizeTradingFeesOnOpenTrade(
        address _trader,
        uint32 _index,
        uint256 _feesCollateral,
        uint64 _currentPairPrice
    ) external virtual onlySelf returns (uint256 finalFeesCollateral) {
        return FundingFeesUtils.realizeTradingFeesOnOpenTrade(_trader, _index, _feesCollateral, _currentPairPrice);
    }

    /// @inheritdoc IFundingFeesUtils
    function downscaleTradeFeesData(
        address _trader,
        uint32 _index,
        uint256 _positionSizeCollateralDelta,
        uint256 _existingPositionSizeCollateral,
        uint256 _newCollateralAmount
    ) external virtual onlySelf {
        return
            FundingFeesUtils.downscaleTradeFeesData(
                _trader,
                _index,
                _positionSizeCollateralDelta,
                _existingPositionSizeCollateral,
                _newCollateralAmount
            );
    }

    /// @inheritdoc IFundingFeesUtils
    function storeAlreadyTransferredNegativePnl(
        address _trader,
        uint32 _index,
        uint256 _deltaCollateral
    ) external virtual onlySelf {
        return FundingFeesUtils.storeAlreadyTransferredNegativePnl(_trader, _index, _deltaCollateral);
    }

    /// @inheritdoc IFundingFeesUtils
    function storeVirtualAvailableCollateralInDiamond(
        address _trader,
        uint32 _index,
        uint256 _newTradeCollateralAmount
    ) external virtual onlySelf {
        return FundingFeesUtils.storeVirtualAvailableCollateralInDiamond(_trader, _index, _newTradeCollateralAmount);
    }

    /// @inheritdoc IFundingFeesUtils
    function storeUiRealizedPnlPartialCloseCollateral(
        address _trader,
        uint32 _index,
        int256 _deltaCollateral
    ) external virtual onlySelf {
        return FundingFeesUtils.storeUiRealizedPnlPartialCloseCollateral(_trader, _index, _deltaCollateral);
    }

    /// @inheritdoc IFundingFeesUtils
    function storeUiPnlWithdrawnCollateral(
        address _trader,
        uint32 _index,
        uint256 _deltaCollateral
    ) external virtual onlySelf {
        return FundingFeesUtils.storeUiPnlWithdrawnCollateral(_trader, _index, _deltaCollateral);
    }

    /// @inheritdoc IFundingFeesUtils
    function storeUiRealizedTradingFeesCollateral(
        address _trader,
        uint32 _index,
        uint256 _deltaCollateral
    ) external virtual onlySelf {
        return FundingFeesUtils.storeUiRealizedTradingFeesCollateral(_trader, _index, _deltaCollateral);
    }

    // Getters

    /// @inheritdoc IFundingFeesUtils
    function getTradeFundingFeesCollateral(
        address _trader,
        uint32 _index,
        uint64 _currentPairPrice
    ) external view returns (int256) {
        return FundingFeesUtils.getTradeFundingFeesCollateral(_trader, _index, _currentPairPrice);
    }

    /// @inheritdoc IFundingFeesUtils
    function getTradeBorrowingFeesCollateral(
        address _trader,
        uint32 _index,
        uint64 _currentPairPrice
    ) external view returns (uint256) {
        return FundingFeesUtils.getTradeBorrowingFeesCollateral(_trader, _index, _currentPairPrice);
    }

    /// @inheritdoc IFundingFeesUtils
    function getTradePendingHoldingFeesCollateral(
        address _trader,
        uint32 _index,
        uint64 _currentPairPrice
    ) external view returns (IFundingFees.TradeHoldingFees memory tradeHoldingFees) {
        return FundingFeesUtils.getTradePendingHoldingFeesCollateral(_trader, _index, _currentPairPrice);
    }

    /// @inheritdoc IFundingFeesUtils
    function getPairPendingAccFundingFees(
        uint8 _collateralIndex,
        uint16 _pairIndex,
        uint64 _currentPairPrice
    )
        external
        view
        returns (int128 accFundingFeeLongP, int128 accFundingFeeShortP, int56 currentFundingRatePerSecondP)
    {
        return FundingFeesUtils.getPairPendingAccFundingFees(_collateralIndex, _pairIndex, _currentPairPrice);
    }

    /// @inheritdoc IFundingFeesUtils
    function getPairPendingAccBorrowingFees(
        uint8 _collateralIndex,
        uint16 _pairIndex,
        uint64 _currentPairPrice
    ) external view returns (uint128 accBorrowingFeeP) {
        return FundingFeesUtils.getPairPendingAccBorrowingFees(_collateralIndex, _pairIndex, _currentPairPrice);
    }

    /// @inheritdoc IFundingFeesUtils
    function getMaxSkewCollateral(uint8 _collateralIndex, uint16 _pairIndex) external view returns (uint80) {
        return FundingFeesUtils.getMaxSkewCollateral(_collateralIndex, _pairIndex);
    }

    /// @inheritdoc IFundingFeesUtils
    function getPairGlobalParamsArray(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex
    ) external view returns (PairGlobalParams[] memory) {
        return FundingFeesUtils.getPairGlobalParamsArray(_collateralIndex, _pairIndex);
    }

    /// @inheritdoc IFundingFeesUtils
    function getPairFundingFeeParams(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex
    ) external view returns (IFundingFees.FundingFeeParams[] memory) {
        return FundingFeesUtils.getPairFundingFeeParams(_collateralIndex, _pairIndex);
    }

    /// @inheritdoc IFundingFeesUtils
    function getPairBorrowingFeeParams(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex
    ) external view returns (IFundingFees.BorrowingFeeParams[] memory) {
        return FundingFeesUtils.getPairBorrowingFeeParams(_collateralIndex, _pairIndex);
    }

    /// @inheritdoc IFundingFeesUtils
    function getPairFundingFeeData(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex
    ) external view returns (IFundingFees.PairFundingFeeData[] memory) {
        return FundingFeesUtils.getPairFundingFeeData(_collateralIndex, _pairIndex);
    }

    /// @inheritdoc IFundingFeesUtils
    function getPairBorrowingFeeData(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex
    ) external view returns (IFundingFees.PairBorrowingFeeData[] memory) {
        return FundingFeesUtils.getPairBorrowingFeeData(_collateralIndex, _pairIndex);
    }

    /// @inheritdoc IFundingFeesUtils
    function getTradeFeesData(
        address _trader,
        uint32 _index
    ) external view returns (IFundingFees.TradeFeesData memory) {
        return FundingFeesUtils.getTradeFeesData(_trader, _index);
    }

    /// @inheritdoc IFundingFeesUtils
    function getTradeFeesDataArray(
        address[] calldata _trader,
        uint32[] calldata _index
    ) external view returns (IFundingFees.TradeFeesData[] memory) {
        return FundingFeesUtils.getTradeFeesDataArray(_trader, _index);
    }

    /// @inheritdoc IFundingFeesUtils
    function getTradeUiRealizedPnlDataArray(
        address[] calldata _trader,
        uint32[] calldata _index
    ) external view returns (IFundingFees.UiRealizedPnlData[] memory) {
        return FundingFeesUtils.getTradeUiRealizedPnlDataArray(_trader, _index);
    }

    /// @inheritdoc IFundingFeesUtils
    function getTradeManuallyRealizedNegativePnlCollateral(
        address _trader,
        uint32 _index
    ) external view returns (uint256) {
        return FundingFeesUtils.getTradeManuallyRealizedNegativePnlCollateral(_trader, _index);
    }

    /// @inheritdoc IFundingFeesUtils
    function getPendingParamUpdates(
        uint32[] calldata _index
    ) external view returns (IFundingFees.PendingParamUpdate[] memory) {
        return FundingFeesUtils.getPendingParamUpdates(_index);
    }

    /// @inheritdoc IFundingFeesUtils
    function getTradeRealizedPnlCollateral(
        address _trader,
        uint32 _index
    )
        external
        view
        returns (int256 realizedPnlCollateral, uint256 realizedTradingFeesCollateral, int256 totalRealizedPnlCollateral)
    {
        return FundingFeesUtils.getTradeRealizedPnlCollateral(_trader, _index);
    }

    /// @inheritdoc IFundingFeesUtils
    function getTradeRealizedTradingFeesCollateral(address _trader, uint32 _index) external view returns (uint256) {
        return FundingFeesUtils.getTradeRealizedTradingFeesCollateral(_trader, _index);
    }
}
