// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../abstract/GNSAddressStore.sol";

import "../../interfaces/libraries/ITradingStorageUtils.sol";

import "../../libraries/TradingStorageUtils.sol";
import "../../libraries/TradingStorageGetters.sol";

/**
 * @dev Facet #5: Trading storage
 */
contract GNSTradingStorage is GNSAddressStore, ITradingStorageUtils {
    // Initialization

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc ITradingStorageUtils
    function initializeTradingStorage(
        address _gns,
        address _gnsStaking,
        address[] memory _collaterals,
        address[] memory _gTokens
    ) external reinitializer(6) {
        TradingStorageUtils.initializeTradingStorage(_gns, _gnsStaking, _collaterals, _gTokens);
    }

    // Management Setters

    /// @inheritdoc ITradingStorageUtils
    function updateTradingActivated(
        TradingActivated _activated
    ) external onlyRoles(Role.GOV_TIMELOCK, Role.GOV_EMERGENCY) {
        TradingStorageUtils.updateTradingActivated(_activated);
    }

    /// @inheritdoc ITradingStorageUtils
    function addCollateral(address _collateral, address _gToken) external onlyRole(Role.GOV_TIMELOCK) {
        TradingStorageUtils.addCollateral(_collateral, _gToken);
    }

    /// @inheritdoc ITradingStorageUtils
    function toggleCollateralActiveState(
        uint8 _collateralIndex
    ) external onlyRoles(Role.GOV_TIMELOCK, Role.GOV_EMERGENCY) {
        TradingStorageUtils.toggleCollateralActiveState(_collateralIndex);
    }

    function updateGToken(
        address _collateral,
        address _gToken
    ) external onlyRoles(Role.GOV_TIMELOCK, Role.GOV_EMERGENCY) {
        TradingStorageUtils.updateGToken(_collateral, _gToken);
    }

    // Interactions

    /// @inheritdoc ITradingStorageUtils
    function storeTrade(
        Trade memory _trade,
        TradeInfo memory _tradeInfo,
        uint64 _currentPairPrice
    ) external virtual onlySelf returns (Trade memory) {
        return TradingStorageUtils.storeTrade(_trade, _tradeInfo, _currentPairPrice);
    }

    /// @inheritdoc ITradingStorageUtils
    function updateTradeMaxClosingSlippageP(
        ITradingStorage.Id memory _tradeId,
        uint16 _maxSlippageP
    ) external virtual onlySelf {
        TradingStorageUtils.updateTradeMaxClosingSlippageP(_tradeId, _maxSlippageP);
    }

    /// @inheritdoc ITradingStorageUtils
    function updateTradePosition(
        ITradingStorage.Id memory _tradeId,
        uint120 _collateralAmount,
        uint24 _leverage,
        uint64 _openPrice,
        ITradingStorage.PendingOrderType _pendingOrderType,
        uint256 _positionSizeTokenDelta,
        bool _isPnlPositive,
        uint64 _currentPairPrice
    ) external virtual onlySelf {
        TradingStorageUtils.updateTradePosition(
            _tradeId,
            _collateralAmount,
            _leverage,
            _openPrice,
            _pendingOrderType,
            _positionSizeTokenDelta,
            _isPnlPositive,
            _currentPairPrice
        );
    }

    /// @inheritdoc ITradingStorageUtils
    function updateOpenOrderDetails(
        ITradingStorage.Id memory _tradeId,
        uint64 _openPrice,
        uint64 _tp,
        uint64 _sl,
        uint16 _maxSlippageP
    ) external virtual onlySelf {
        TradingStorageUtils.updateOpenOrderDetails(_tradeId, _openPrice, _tp, _sl, _maxSlippageP);
    }

    /// @inheritdoc ITradingStorageUtils
    function updateTradeTp(Id memory _tradeId, uint64 _newTp) external virtual onlySelf {
        TradingStorageUtils.updateTradeTp(_tradeId, _newTp);
    }

    /// @inheritdoc ITradingStorageUtils
    function updateTradeSl(Id memory _tradeId, uint64 _newSl) external virtual onlySelf {
        TradingStorageUtils.updateTradeSl(_tradeId, _newSl);
    }

    /// @inheritdoc ITradingStorageUtils
    function closeTrade(Id memory _tradeId, bool _isPnlPositive, uint64 _currentPairPrice) external virtual onlySelf {
        TradingStorageUtils.closeTrade(_tradeId, _isPnlPositive, _currentPairPrice);
    }

    /// @inheritdoc ITradingStorageUtils
    function storePendingOrder(
        PendingOrder memory _pendingOrder
    ) external virtual onlySelf returns (PendingOrder memory) {
        return TradingStorageUtils.storePendingOrder(_pendingOrder);
    }

    /// @inheritdoc ITradingStorageUtils
    function closePendingOrder(Id memory _orderId) external virtual onlySelf {
        TradingStorageUtils.closePendingOrder(_orderId);
    }

    /// @inheritdoc ITradingStorageUtils
    function validateOpenTradeOrder(Trade memory _trade, PendingOrderType _orderType) external pure {
        TradingStorageUtils.validateOpenTradeOrder(_trade, _orderType);
    }

    // Getters

    /// @inheritdoc ITradingStorageUtils
    function getCollateral(uint8 _index) external view returns (Collateral memory) {
        return TradingStorageGetters.getCollateral(_index);
    }

    /// @inheritdoc ITradingStorageUtils
    function isCollateralActive(uint8 _index) external view returns (bool) {
        return TradingStorageGetters.isCollateralActive(_index);
    }

    /// @inheritdoc ITradingStorageUtils
    function isCollateralListed(uint8 _index) external view returns (bool) {
        return TradingStorageGetters.isCollateralListed(_index);
    }

    /// @inheritdoc ITradingStorageUtils
    function isCollateralGns(uint8 _index) external view returns (bool) {
        return TradingStorageGetters.isCollateralGns(_index);
    }

    /// @inheritdoc ITradingStorageUtils
    function getCollateralsCount() external view returns (uint8) {
        return TradingStorageGetters.getCollateralsCount();
    }

    /// @inheritdoc ITradingStorageUtils
    function getCollaterals() external view returns (Collateral[] memory) {
        return TradingStorageGetters.getCollaterals();
    }

    /// @inheritdoc ITradingStorageUtils
    function getCollateralIndex(address _collateral) external view returns (uint8) {
        return TradingStorageGetters.getCollateralIndex(_collateral);
    }

    /// @inheritdoc ITradingStorageUtils
    function getGnsCollateralIndex() external view returns (uint8) {
        return TradingStorageGetters.getGnsCollateralIndex();
    }

    /// @inheritdoc ITradingStorageUtils
    function getTradingActivated() external view returns (TradingActivated) {
        return TradingStorageGetters.getTradingActivated();
    }

    /// @inheritdoc ITradingStorageUtils
    function getTraderStored(address _trader) external view returns (bool) {
        return TradingStorageGetters.getTraderStored(_trader);
    }

    /// @inheritdoc ITradingStorageUtils
    function getTradersCount() external view returns (uint256) {
        return TradingStorageGetters.getTradersCount();
    }

    /// @inheritdoc ITradingStorageUtils
    function getTraders(uint32 _offset, uint32 _limit) external view returns (address[] memory) {
        return TradingStorageGetters.getTraders(_offset, _limit);
    }

    /// @inheritdoc ITradingStorageUtils
    function getTrade(address _trader, uint32 _index) external view returns (Trade memory) {
        return TradingStorageGetters.getTrade(_trader, _index);
    }

    /// @inheritdoc ITradingStorageUtils
    function getTrades(address _trader) external view returns (Trade[] memory) {
        return TradingStorageGetters.getTrades(_trader);
    }

    /// @inheritdoc ITradingStorageUtils
    function getAllTradesForTraders(
        address[] memory _traders,
        uint256 _offset,
        uint256 _limit
    ) external view returns (Trade[] memory) {
        return TradingStorageGetters.getAllTradesForTraders(_traders, _offset, _limit);
    }

    /// @inheritdoc ITradingStorageUtils
    function getAllTrades(uint256 _offset, uint256 _limit) external view returns (Trade[] memory) {
        return TradingStorageGetters.getAllTrades(_offset, _limit);
    }

    /// @inheritdoc ITradingStorageUtils
    function getTradeInfo(address _trader, uint32 _index) external view returns (TradeInfo memory) {
        return TradingStorageGetters.getTradeInfo(_trader, _index);
    }

    /// @inheritdoc ITradingStorageUtils
    function getTradeInfos(address _trader) external view returns (TradeInfo[] memory) {
        return TradingStorageGetters.getTradeInfos(_trader);
    }

    /// @inheritdoc ITradingStorageUtils
    function getAllTradeInfosForTraders(
        address[] memory _traders,
        uint256 _offset,
        uint256 _limit
    ) external view returns (TradeInfo[] memory) {
        return TradingStorageGetters.getAllTradeInfosForTraders(_traders, _offset, _limit);
    }

    /// @inheritdoc ITradingStorageUtils
    function getAllTradeInfos(uint256 _offset, uint256 _limit) external view returns (TradeInfo[] memory) {
        return TradingStorageGetters.getAllTradeInfos(_offset, _limit);
    }

    /// @inheritdoc ITradingStorageUtils
    function getPendingOrder(Id memory _orderId) external view returns (PendingOrder memory) {
        return TradingStorageGetters.getPendingOrder(_orderId);
    }

    /// @inheritdoc ITradingStorageUtils
    function getPendingOrders(address _user) external view returns (PendingOrder[] memory) {
        return TradingStorageGetters.getPendingOrders(_user);
    }

    /// @inheritdoc ITradingStorageUtils
    function getAllPendingOrdersForTraders(
        address[] memory _traders,
        uint256 _offset,
        uint256 _limit
    ) external view returns (PendingOrder[] memory) {
        return TradingStorageGetters.getAllPendingOrdersForTraders(_traders, _offset, _limit);
    }

    /// @inheritdoc ITradingStorageUtils
    function getAllPendingOrders(uint256 _offset, uint256 _limit) external view returns (PendingOrder[] memory) {
        return TradingStorageGetters.getAllPendingOrders(_offset, _limit);
    }

    /// @inheritdoc ITradingStorageUtils
    function getTradePendingOrderBlock(
        Id memory _tradeId,
        PendingOrderType _orderType
    ) external view returns (uint256) {
        return TradingStorageGetters.getTradePendingOrderBlock(_tradeId, _orderType);
    }

    /// @inheritdoc ITradingStorageUtils
    function getCounters(address _trader, CounterType _type) external view returns (Counter memory) {
        return TradingStorageGetters.getCounters(_trader, _type);
    }

    /// @inheritdoc ITradingStorageUtils
    function getCountersForTraders(
        address[] calldata _traders,
        CounterType _type
    ) external view returns (Counter[] memory) {
        return TradingStorageGetters.getCountersForTraders(_traders, _type);
    }

    /// @inheritdoc ITradingStorageUtils
    function getGToken(uint8 _collateralIndex) external view returns (address) {
        return TradingStorageGetters.getGToken(_collateralIndex);
    }

    /// @inheritdoc ITradingStorageUtils
    function getTradeLiquidationParams(
        address _trader,
        uint32 _index
    ) external view returns (IPairsStorage.GroupLiquidationParams memory) {
        return TradingStorageGetters.getTradeLiquidationParams(_trader, _index);
    }

    /// @inheritdoc ITradingStorageUtils
    function getTradesLiquidationParams(
        address _trader
    ) external view returns (IPairsStorage.GroupLiquidationParams[] memory) {
        return TradingStorageGetters.getTradesLiquidationParams(_trader);
    }

    /// @inheritdoc ITradingStorageUtils
    function getAllTradesLiquidationParamsForTraders(
        address[] memory _traders,
        uint256 _offset,
        uint256 _limit
    ) external view returns (IPairsStorage.GroupLiquidationParams[] memory) {
        return TradingStorageGetters.getAllTradesLiquidationParamsForTraders(_traders, _offset, _limit);
    }

    /// @inheritdoc ITradingStorageUtils
    function getAllTradesLiquidationParams(
        uint256 _offset,
        uint256 _limit
    ) external view returns (IPairsStorage.GroupLiquidationParams[] memory) {
        return TradingStorageGetters.getAllTradesLiquidationParams(_offset, _limit);
    }

    /// @inheritdoc ITradingStorageUtils
    function getCurrentContractsVersion() external view virtual returns (ITradingStorage.ContractsVersion) {
        return TradingStorageGetters.getCurrentContractsVersion();
    }

    /// @inheritdoc ITradingStorageUtils
    function getTradeContractsVersion(
        address _trader,
        uint32 _index
    ) external view returns (ITradingStorage.ContractsVersion) {
        return TradingStorageGetters.getTradeContractsVersion(_trader, _index);
    }

    /// @inheritdoc ITradingStorageUtils
    function getLookbackFromBlock(
        address _trader,
        uint32 _index,
        ITradingStorage.PendingOrderType _orderType
    ) external view returns (uint32) {
        return TradingStorageGetters.getLookbackFromBlock(_trader, _index, _orderType);
    }
}
