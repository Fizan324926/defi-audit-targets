// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../abstract/GNSAddressStore.sol";

import "../../interfaces/libraries/ITradingCallbacksUtils.sol";
import "../../interfaces/types/ITradingStorage.sol";

import "../../libraries/TradingCallbacksUtils.sol";

/**
 * @dev Facet #8: Callbacks (to execute actions after receiving median price from price aggregator)
 */
contract GNSTradingCallbacks is GNSAddressStore, ITradingCallbacksUtils {
    // Initialization

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc ITradingCallbacksUtils
    function initializeCallbacks(uint8 _vaultClosingFeeP) external reinitializer(9) {
        TradingCallbacksUtils.initializeCallbacks(_vaultClosingFeeP);
    }

    /// @inheritdoc ITradingCallbacksUtils
    function initializeTreasuryAddress(address _treasury) external reinitializer(15) {
        TradingCallbacksUtils.updateTreasuryAddress(_treasury);
    }

    // Management Setters

    /// @inheritdoc ITradingCallbacksUtils
    function updateVaultClosingFeeP(uint8 _valueP) external onlyRole(Role.GOV) {
        TradingCallbacksUtils.updateVaultClosingFeeP(_valueP);
    }

    /// @inheritdoc ITradingCallbacksUtils
    function updateTreasuryAddress(address _treasury) external onlyRole(Role.GOV_TIMELOCK) {
        TradingCallbacksUtils.updateTreasuryAddress(_treasury);
    }

    /// @inheritdoc ITradingCallbacksUtils
    function claimPendingGovFees() external onlyRole(Role.GOV) {
        TradingCallbacksUtils.claimPendingGovFees();
    }

    // Interactions

    /// @inheritdoc ITradingCallbacksUtils
    function openTradeMarketCallback(AggregatorAnswer memory _a) external virtual onlySelf {
        TradingCallbacksUtils.openTradeMarketCallback(_a);
    }

    /// @inheritdoc ITradingCallbacksUtils
    function closeTradeMarketCallback(AggregatorAnswer memory _a) external virtual onlySelf {
        TradingCallbacksUtils.closeTradeMarketCallback(_a);
    }

    /// @inheritdoc ITradingCallbacksUtils
    function executeTriggerOpenOrderCallback(AggregatorAnswer memory _a) external virtual onlySelf {
        TradingCallbacksUtils.executeTriggerOpenOrderCallback(_a);
    }

    /// @inheritdoc ITradingCallbacksUtils
    function executeTriggerOpenOrderCallbackDirect(
        ITradingCallbacks.AggregatorAnswer memory _a,
        ITradingStorage.Trade memory _trade,
        ITradingStorage.PendingOrderType _orderType,
        address _initiator
    ) external virtual onlySelf {
        TradingCallbacksUtils.executeTriggerOpenOrderCallbackDirect(_a, _trade, _orderType, _initiator);
    }

    /// @inheritdoc ITradingCallbacksUtils
    function executeTriggerCloseOrderCallback(AggregatorAnswer memory _a) external virtual onlySelf {
        TradingCallbacksUtils.executeTriggerCloseOrderCallback(_a);
    }

    /// @inheritdoc ITradingCallbacksUtils
    function executeTriggerCloseOrderCallbackDirect(
        ITradingCallbacks.AggregatorAnswer memory _a,
        ITradingStorage.Trade memory _trade,
        ITradingStorage.PendingOrderType _orderType,
        address _initiator
    ) external virtual onlySelf {
        TradingCallbacksUtils.executeTriggerCloseOrderCallbackDirect(_a, _trade, _orderType, _initiator);
    }

    /// @inheritdoc ITradingCallbacksUtils
    function updateLeverageCallback(AggregatorAnswer memory _a) external virtual onlySelf {
        TradingCallbacksUtils.updateLeverageCallback(_a);
    }

    /// @inheritdoc ITradingCallbacksUtils
    function increasePositionSizeMarketCallback(AggregatorAnswer memory _a) external virtual onlySelf {
        TradingCallbacksUtils.increasePositionSizeMarketCallback(_a);
    }

    /// @inheritdoc ITradingCallbacksUtils
    function decreasePositionSizeMarketCallback(AggregatorAnswer memory _a) external virtual onlySelf {
        TradingCallbacksUtils.decreasePositionSizeMarketCallback(_a);
    }

    /// @inheritdoc ITradingCallbacksUtils
    function pnlWithdrawalCallback(AggregatorAnswer memory _a) external virtual onlySelf {
        TradingCallbacksUtils.pnlWithdrawalCallback(_a);
    }

    /// @inheritdoc ITradingCallbacksUtils
    function manualHoldingFeesRealizationCallback(AggregatorAnswer memory _a) external virtual onlySelf {
        TradingCallbacksUtils.manualHoldingFeesRealizationCallback(_a);
    }

    /// @inheritdoc ITradingCallbacksUtils
    function manualNegativePnlRealizationCallback(AggregatorAnswer memory _a) external virtual onlySelf {
        TradingCallbacksUtils.manualNegativePnlRealizationCallback(_a);
    }

    // Getters

    /// @inheritdoc ITradingCallbacksUtils
    function getVaultClosingFeeP() external view returns (uint8) {
        return TradingCallbacksUtils.getVaultClosingFeeP();
    }

    /// @inheritdoc ITradingCallbacksUtils
    function getPendingGovFeesCollateral(uint8 _collateralIndex) external view returns (uint256) {
        return TradingCallbacksUtils.getPendingGovFeesCollateral(_collateralIndex);
    }

    /// @inheritdoc ITradingCallbacksUtils
    function validateTriggerOpenOrderCallback(
        ITradingStorage.Id memory _tradeId,
        ITradingStorage.PendingOrderType _orderType,
        uint64 _open,
        uint64 _high,
        uint64 _low,
        uint64 _currentPairPrice
    ) external view returns (ITradingStorage.Trade memory t, ITradingCallbacks.Values memory v) {
        return
            TradingCallbacksUtils.validateTriggerOpenOrderCallback(
                _tradeId,
                _orderType,
                _open,
                _high,
                _low,
                _currentPairPrice
            );
    }

    /// @inheritdoc ITradingCallbacksUtils
    function validateTriggerCloseOrderCallback(
        ITradingStorage.Id memory _tradeId,
        ITradingStorage.PendingOrderType _orderType,
        uint64 _open,
        uint64 _high,
        uint64 _low,
        uint64 _currentPairPrice
    ) external view returns (ITradingStorage.Trade memory t, ITradingCallbacks.Values memory v) {
        return
            TradingCallbacksUtils.validateTriggerCloseOrderCallback(
                _tradeId,
                _orderType,
                _open,
                _high,
                _low,
                _currentPairPrice
            );
    }
}
