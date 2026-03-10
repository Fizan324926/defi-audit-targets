// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../abstract/GNSAddressStore.sol";
import "../abstract/GNSReentrancyGuard.sol";

import "../../interfaces/libraries/ITradingInteractionsUtils.sol";
import "../../interfaces/types/ITradingStorage.sol";

import "../../libraries/TradingInteractionsUtils.sol";

/**
 * @dev Facet #7: Trading (user interactions)
 */
contract GNSTradingInteractions is GNSAddressStore, GNSReentrancyGuard, ITradingInteractionsUtils {
    // Initialization

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc ITradingInteractionsUtils
    function initializeTrading(
        uint16 _marketOrdersTimeoutBlocks,
        address[] memory _usersByPassTriggerLink
    ) external reinitializer(8) {
        TradingInteractionsUtils.initializeTrading(_marketOrdersTimeoutBlocks, _usersByPassTriggerLink);
    }

    // Management Setters

    /// @inheritdoc ITradingInteractionsUtils
    function updateMarketOrdersTimeoutBlocks(uint16 _valueBlocks) external onlyRole(Role.GOV) {
        TradingInteractionsUtils.updateMarketOrdersTimeoutBlocks(_valueBlocks);
    }

    /// @inheritdoc ITradingInteractionsUtils
    function updateByPassTriggerLink(
        address[] memory _users,
        bool[] memory _shouldByPass
    ) external onlyRoles(Role.GOV_TIMELOCK, Role.GOV_EMERGENCY) {
        TradingInteractionsUtils.updateByPassTriggerLink(_users, _shouldByPass);
    }

    // Interactions

    /// @inheritdoc ITradingInteractionsUtils
    function initiateManualNegativePnlRealization(
        address _trader,
        uint32 _index,
        bool _isHoldingFees
    ) external nonReentrant onlyRoles(Role.GOV, Role.MANAGER) {
        TradingInteractionsUtils.initiateManualNegativePnlRealization(_trader, _index, _isHoldingFees);
    }

    /// @inheritdoc ITradingInteractionsUtils
    function setTradingDelegate(address _delegate) external nonReentrant {
        TradingInteractionsUtils.setTradingDelegate(_delegate);
    }

    /// @inheritdoc ITradingInteractionsUtils
    function removeTradingDelegate() external nonReentrant {
        TradingInteractionsUtils.removeTradingDelegate();
    }

    /// @inheritdoc ITradingInteractionsUtils
    function delegatedTradingAction(address _trader, bytes calldata _callData) external returns (bytes memory) {
        return TradingInteractionsUtils.delegatedTradingAction(_trader, _callData);
    }

    /// @inheritdoc ITradingInteractionsUtils
    function openTrade(
        ITradingStorage.Trade memory _trade,
        uint16 _maxSlippageP,
        address _referrer
    ) external nonReentrant {
        TradingInteractionsUtils.openTrade(_trade, _maxSlippageP, _referrer);
    }

    /// @inheritdoc ITradingInteractionsUtils
    function openTradeNative(
        ITradingStorage.Trade memory _trade,
        uint16 _maxSlippageP,
        address _referrer
    ) external payable nonReentrant {
        TradingInteractionsUtils.openTradeNative(_trade, _maxSlippageP, _referrer);
    }

    /// @inheritdoc ITradingInteractionsUtils
    function updateMaxClosingSlippageP(uint32 _index, uint16 _maxSlippageP) external nonReentrant {
        TradingInteractionsUtils.updateMaxClosingSlippageP(_index, _maxSlippageP);
    }

    /// @inheritdoc ITradingInteractionsUtils
    function closeTradeMarket(uint32 _index, uint64 _expectedPrice) external nonReentrant {
        TradingInteractionsUtils.closeTradeMarket(_index, _expectedPrice);
    }

    /// @inheritdoc ITradingInteractionsUtils
    function updateOpenOrder(
        uint32 _index,
        uint64 _triggerPrice,
        uint64 _tp,
        uint64 _sl,
        uint16 _maxSlippageP
    ) external nonReentrant {
        TradingInteractionsUtils.updateOpenOrder(_index, _triggerPrice, _tp, _sl, _maxSlippageP);
    }

    /// @inheritdoc ITradingInteractionsUtils
    function cancelOpenOrder(uint32 _index) external nonReentrant {
        TradingInteractionsUtils.cancelOpenOrder(_index);
    }

    /// @inheritdoc ITradingInteractionsUtils
    function updateTp(uint32 _index, uint64 _newTp) external nonReentrant {
        TradingInteractionsUtils.updateTp(_index, _newTp);
    }

    /// @inheritdoc ITradingInteractionsUtils
    function updateSl(uint32 _index, uint64 _newSl) external nonReentrant {
        TradingInteractionsUtils.updateSl(_index, _newSl);
    }

    /// @inheritdoc ITradingInteractionsUtils
    function updateLeverage(uint32 _index, uint24 _newLeverage) external nonReentrant {
        TradingInteractionsUtils.updateLeverage(_index, _newLeverage);
    }

    /// @inheritdoc ITradingInteractionsUtils
    function updateLeverageNative(uint32 _index, uint24 _newLeverage) external payable nonReentrant {
        TradingInteractionsUtils.updateLeverageNative(_index, _newLeverage);
    }

    /// @inheritdoc ITradingInteractionsUtils
    function increasePositionSize(
        uint32 _index,
        uint120 _collateralDelta,
        uint24 _leverageDelta,
        uint64 _expectedPrice,
        uint16 _maxSlippageP
    ) external nonReentrant {
        TradingInteractionsUtils.increasePositionSize(
            _index,
            _collateralDelta,
            _leverageDelta,
            _expectedPrice,
            _maxSlippageP
        );
    }

    /// @inheritdoc ITradingInteractionsUtils
    function increasePositionSizeNative(
        uint32 _index,
        uint120 _collateralDelta,
        uint24 _leverageDelta,
        uint64 _expectedPrice,
        uint16 _maxSlippageP
    ) external payable nonReentrant {
        TradingInteractionsUtils.increasePositionSizeNative(
            _index,
            _collateralDelta,
            _leverageDelta,
            _expectedPrice,
            _maxSlippageP
        );
    }

    /// @inheritdoc ITradingInteractionsUtils
    function decreasePositionSize(
        uint32 _index,
        uint120 _collateralDelta,
        uint24 _leverageDelta,
        uint64 _expectedPrice
    ) external nonReentrant {
        TradingInteractionsUtils.decreasePositionSize(_index, _collateralDelta, _leverageDelta, _expectedPrice);
    }

    /// @inheritdoc ITradingInteractionsUtils
    function withdrawPositivePnl(uint32 _index, uint120 _amountCollateral) external nonReentrant {
        TradingInteractionsUtils.withdrawPositivePnl(_index, _amountCollateral);
    }

    /// @inheritdoc ITradingInteractionsUtils
    function triggerOrder(uint256 _packed) external nonReentrant {
        TradingInteractionsUtils.triggerOrder(_packed);
    }

    /// @inheritdoc ITradingInteractionsUtils
    function triggerOrderWithSignatures(
        uint256 _packed,
        IPriceAggregator.SignedPairPrices[] calldata _signedPairPrices
    ) external nonReentrant {
        TradingInteractionsUtils.triggerOrderWithSignatures(_packed, _signedPairPrices);
    }

    /// @inheritdoc ITradingInteractionsUtils
    function cancelOrderAfterTimeout(uint32 _orderIndex) external nonReentrant {
        TradingInteractionsUtils.cancelOrderAfterTimeout(_orderIndex);
    }

    // Getters

    /// @inheritdoc ITradingInteractionsUtils
    function getWrappedNativeToken() external view returns (address) {
        return TradingInteractionsUtils.getWrappedNativeToken();
    }

    /// @inheritdoc ITradingInteractionsUtils
    function isWrappedNativeToken(address _token) external view returns (bool) {
        return TradingInteractionsUtils.isWrappedNativeToken(_token);
    }

    /// @inheritdoc ITradingInteractionsUtils
    function getTradingDelegate(address _trader) external view returns (address) {
        return TradingInteractionsUtils.getTradingDelegate(_trader);
    }

    /// @inheritdoc ITradingInteractionsUtils
    function getMarketOrdersTimeoutBlocks() external view returns (uint16) {
        return TradingInteractionsUtils.getMarketOrdersTimeoutBlocks();
    }

    /// @inheritdoc ITradingInteractionsUtils
    function getByPassTriggerLink(address _user) external view returns (bool) {
        return TradingInteractionsUtils.getByPassTriggerLink(_user);
    }
}
