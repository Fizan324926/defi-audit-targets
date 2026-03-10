// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../interfaces/IGNSMultiCollatDiamond.sol";

import "./StorageUtils.sol";
import "./AddressStoreUtils.sol";
import "./CollateralUtils.sol";
import "./ChainUtils.sol";
import "./TradingCommonUtils.sol";
import "./ConstantsUtils.sol";

/**
 * @dev GNSTradingStorage facet external library
 */

library TradingStorageUtils {
    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function initializeTradingStorage(
        address _gns,
        address _gnsStaking,
        address[] memory _collaterals,
        address[] memory _gTokens
    ) external {
        if (_gns == address(0) || _gnsStaking == address(0)) revert IGeneralErrors.ZeroAddress();

        if (_collaterals.length < 1) revert ITradingStorageUtils.MissingCollaterals();
        if (_collaterals.length != _gTokens.length) revert IGeneralErrors.WrongLength();

        // Set addresses
        IGNSAddressStore.Addresses storage addresses = AddressStoreUtils.getAddresses();
        addresses.gns = _gns;
        addresses.gnsStaking = _gnsStaking;

        emit IGNSAddressStore.AddressesUpdated(addresses);

        // Add collaterals
        for (uint256 i; i < _collaterals.length; ++i) {
            addCollateral(_collaterals[i], _gTokens[i]);
        }

        // Trading is paused by default for state copy
        updateTradingActivated(ITradingStorage.TradingActivated.PAUSED);
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function updateTradingActivated(ITradingStorage.TradingActivated _activated) public {
        _getStorage().tradingActivated = _activated;

        emit ITradingStorageUtils.TradingActivatedUpdated(_activated);
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function addCollateral(address _collateral, address _gToken) public {
        ITradingStorage.TradingStorage storage s = _getStorage();
        IAddressStore.Addresses storage addresses = AddressStoreUtils.getAddresses();

        if (s.collateralIndex[_collateral] != 0) revert IGeneralErrors.AlreadyExists();
        if (_collateral == address(0) || _gToken == address(0)) revert IGeneralErrors.ZeroAddress();

        CollateralUtils.CollateralConfig memory collateralConfig = CollateralUtils.getCollateralConfig(_collateral);

        uint8 index = ++s.lastCollateralIndex;

        s.collaterals[index] = ITradingStorage.Collateral({
            collateral: _collateral,
            isActive: false,
            __placeholder: 0,
            precision: collateralConfig.precision,
            precisionDelta: collateralConfig.precisionDelta
        });
        s.gTokens[index] = _gToken;

        s.collateralIndex[_collateral] = index;

        if (_collateral == addresses.gns) s.gnsCollateralIndex = index;

        // Setup Staking and GToken approvals
        IERC20 collateral = IERC20(_collateral);
        collateral.approve(_gToken, type(uint256).max);
        collateral.approve(addresses.gnsStaking, type(uint256).max);

        emit ITradingStorageUtils.CollateralAdded(_collateral, index, _gToken);
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function toggleCollateralActiveState(uint8 _collateralIndex) external {
        ITradingStorage.TradingStorage storage s = _getStorage();
        ITradingStorage.Collateral storage collateral = s.collaterals[_collateralIndex];

        if (collateral.precision == 0) revert IGeneralErrors.DoesntExist();

        bool toggled = !collateral.isActive;
        collateral.isActive = toggled;

        emit ITradingStorageUtils.CollateralUpdated(_collateralIndex, toggled);
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function updateGToken(address _collateral, address _gToken) external {
        ITradingStorage.TradingStorage storage s = _getStorage();

        uint8 index = s.collateralIndex[_collateral];

        if (index == 0) revert IGeneralErrors.DoesntExist();
        if (_gToken == address(0)) revert IGeneralErrors.ZeroAddress();

        // Revoke old vault and approve new vault
        IERC20 collateral = IERC20(_collateral);
        collateral.approve(s.gTokens[index], 0);
        collateral.approve(_gToken, type(uint256).max);

        s.gTokens[index] = _gToken;

        emit ITradingStorageUtils.GTokenUpdated(_collateral, index, _gToken);
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function storeTrade(
        ITradingStorage.Trade memory _trade,
        ITradingStorage.TradeInfo memory _tradeInfo,
        uint64 _currentPairPrice
    ) external returns (ITradingStorage.Trade memory) {
        ITradingStorage.TradingStorage storage s = _getStorage();

        _validateTrade(_trade);

        if (_trade.tradeType != ITradingStorage.TradeType.TRADE && _tradeInfo.maxSlippageP == 0)
            revert ITradingStorageUtils.MaxSlippageZero();

        ITradingStorage.Counter memory counter = s.userCounters[_trade.user][ITradingStorage.CounterType.TRADE];
        _trade.index = counter.currentIndex;
        _trade.isOpen = true;

        IPairsStorage.GroupLiquidationParams memory liquidationParams = _getMultiCollatDiamond()
            .getPairLiquidationParams(_trade.pairIndex);
        s.tradeLiquidationParams[_trade.user][_trade.index] = liquidationParams;

        _trade.sl = _limitTradeSlDistance(_trade, _trade.sl);

        _tradeInfo.createdBlock = uint32(ChainUtils.getBlockNumber());
        _tradeInfo.tpLastUpdatedBlock = _tradeInfo.createdBlock;
        _tradeInfo.slLastUpdatedBlock = _tradeInfo.createdBlock;

        _tradeInfo.contractsVersion = _getMultiCollatDiamond().getCurrentContractsVersion();
        _tradeInfo.lastPosIncreaseBlock = _tradeInfo.createdBlock;

        counter.currentIndex++;
        counter.openCount++;

        s.trades[_trade.user][_trade.index] = _trade;
        s.tradeInfos[_trade.user][_trade.index] = _tradeInfo;
        s.userCounters[_trade.user][ITradingStorage.CounterType.TRADE] = counter;

        if (!s.traderStored[_trade.user]) {
            s.traders.push(_trade.user);
            s.traderStored[_trade.user] = true;
        }

        if (_trade.tradeType == ITradingStorage.TradeType.TRADE)
            TradingCommonUtils.addNewTradeOi(_trade, _currentPairPrice);

        emit ITradingStorageUtils.TradeStored(_trade.user, _trade.index, _trade, _tradeInfo, liquidationParams);

        return _trade;
    }

    function updateTradeMaxClosingSlippageP(ITradingStorage.Id memory _tradeId, uint16 _maxClosingSlippageP) external {
        ITradingStorage.TradingStorage storage s = _getStorage();
        ITradingStorage.Trade storage t = s.trades[_tradeId.user][_tradeId.index];

        if (!t.isOpen) revert IGeneralErrors.DoesntExist();
        if (t.tradeType != ITradingStorage.TradeType.TRADE) revert IGeneralErrors.WrongTradeType();
        if (_maxClosingSlippageP == 0) revert ITradingStorageUtils.MaxSlippageZero();

        s.tradeInfos[_tradeId.user][_tradeId.index].maxSlippageP = _maxClosingSlippageP;

        emit ITradingStorageUtils.TradeMaxClosingSlippagePUpdated(_tradeId.user, _tradeId.index, _maxClosingSlippageP);
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function updateTradePosition(
        ITradingStorage.Id memory _tradeId,
        uint120 _collateralAmount,
        uint24 _leverage,
        uint64 _openPrice,
        ITradingStorage.PendingOrderType _pendingOrderType,
        uint256 _positionSizeTokenDelta,
        bool _isPnlPositive,
        uint64 _currentPairPrice
    ) external {
        ITradingStorage.TradingStorage storage s = _getStorage();
        ITradingStorage.Trade storage t = s.trades[_tradeId.user][_tradeId.index];
        ITradingStorage.TradeInfo storage i = s.tradeInfos[_tradeId.user][_tradeId.index];

        if (!t.isOpen) revert IGeneralErrors.DoesntExist();
        if (t.tradeType != ITradingStorage.TradeType.TRADE) revert IGeneralErrors.WrongTradeType();
        if (_collateralAmount * _leverage == 0) revert ITradingStorageUtils.TradePositionSizeZero();
        if (_openPrice == 0) revert ITradingStorageUtils.TradeOpenPriceZero();

        if (_pendingOrderType != ITradingStorage.PendingOrderType.UPDATE_LEVERAGE) {
            TradingCommonUtils.handleOiDelta(
                t,
                TradingCommonUtils.getPositionSizeCollateral(_collateralAmount, _leverage),
                _positionSizeTokenDelta,
                _isPnlPositive,
                _currentPairPrice
            );
        }

        ITradingStorage.UpdateTradePositionValues memory v;
        v.blockNumber = uint32(ChainUtils.getBlockNumber());

        if (_pendingOrderType == ITradingStorage.PendingOrderType.MARKET_PARTIAL_OPEN) {
            s.tradeLiquidationParams[_tradeId.user][_tradeId.index] = _getMultiCollatDiamond().getPairLiquidationParams(
                t.pairIndex
            );
            i.lastPosIncreaseBlock = v.blockNumber;
        }

        t.collateralAmount = _collateralAmount;
        t.leverage = _leverage;
        t.openPrice = _openPrice;

        v.newSl = _limitTradeSlDistance(t, t.sl);
        t.sl = v.newSl;

        v.newPositionSizeToken = _pendingOrderType == ITradingStorage.PendingOrderType.MARKET_PARTIAL_OPEN
            ? t.positionSizeToken + uint160(_positionSizeTokenDelta)
            : _pendingOrderType == ITradingStorage.PendingOrderType.MARKET_PARTIAL_CLOSE
                ? t.positionSizeToken - uint160(_positionSizeTokenDelta)
                : t.positionSizeToken;
        t.positionSizeToken = v.newPositionSizeToken;

        i.createdBlock = v.blockNumber;
        i.tpLastUpdatedBlock = v.blockNumber;
        i.slLastUpdatedBlock = v.blockNumber;

        emit ITradingStorageUtils.TradePositionUpdated(
            _tradeId.user,
            _tradeId.index,
            _collateralAmount,
            _leverage,
            _openPrice,
            v.newSl,
            v.newPositionSizeToken,
            _pendingOrderType,
            _isPnlPositive
        );
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function updateOpenOrderDetails(
        ITradingStorage.Id memory _tradeId,
        uint64 _openPrice,
        uint64 _tp,
        uint64 _sl,
        uint16 _maxSlippageP
    ) external {
        ITradingStorage.TradingStorage storage s = _getStorage();

        ITradingStorage.Trade storage t = s.trades[_tradeId.user][_tradeId.index];
        ITradingStorage.TradeInfo memory i = s.tradeInfos[_tradeId.user][_tradeId.index];

        if (!t.isOpen) revert IGeneralErrors.DoesntExist();
        if (t.tradeType == ITradingStorage.TradeType.TRADE) revert IGeneralErrors.WrongTradeType();
        if (_openPrice == 0) revert ITradingStorageUtils.TradeOpenPriceZero();
        if (_tp > 0 && (t.long ? _tp <= _openPrice : _tp >= _openPrice)) revert ITradingStorageUtils.TradeTpInvalid();
        if (_sl > 0 && (t.long ? _sl >= _openPrice : _sl <= _openPrice)) revert ITradingStorageUtils.TradeSlInvalid();
        if (_maxSlippageP == 0) revert ITradingStorageUtils.MaxSlippageZero();

        t.openPrice = _openPrice;

        _sl = _limitTradeSlDistance(t, _sl);

        t.tp = _tp;
        t.sl = _sl;

        i.maxSlippageP = _maxSlippageP;
        i.createdBlock = uint32(ChainUtils.getBlockNumber());
        i.tpLastUpdatedBlock = i.createdBlock;
        i.slLastUpdatedBlock = i.createdBlock;

        s.tradeInfos[_tradeId.user][_tradeId.index] = i;

        emit ITradingStorageUtils.OpenOrderDetailsUpdated(
            _tradeId.user,
            _tradeId.index,
            _openPrice,
            _tp,
            _sl,
            _maxSlippageP
        );
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function updateTradeTp(ITradingStorage.Id memory _tradeId, uint64 _newTp) external {
        ITradingStorage.TradingStorage storage s = _getStorage();

        ITradingStorage.Trade storage t = s.trades[_tradeId.user][_tradeId.index];
        ITradingStorage.TradeInfo storage i = s.tradeInfos[_tradeId.user][_tradeId.index];

        if (!t.isOpen) revert IGeneralErrors.DoesntExist();
        if (t.tradeType != ITradingStorage.TradeType.TRADE) revert IGeneralErrors.WrongTradeType();

        t.tp = _newTp;
        i.tpLastUpdatedBlock = uint32(ChainUtils.getBlockNumber());

        emit ITradingStorageUtils.TradeTpUpdated(_tradeId.user, _tradeId.index, _newTp);
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function updateTradeSl(ITradingStorage.Id memory _tradeId, uint64 _newSl) external {
        ITradingStorage.TradingStorage storage s = _getStorage();

        ITradingStorage.Trade storage t = s.trades[_tradeId.user][_tradeId.index];
        ITradingStorage.TradeInfo storage i = s.tradeInfos[_tradeId.user][_tradeId.index];

        if (!t.isOpen) revert IGeneralErrors.DoesntExist();
        if (t.tradeType != ITradingStorage.TradeType.TRADE) revert IGeneralErrors.WrongTradeType();

        _newSl = _limitTradeSlDistance(t, _newSl);

        t.sl = _newSl;
        i.slLastUpdatedBlock = uint32(ChainUtils.getBlockNumber());

        emit ITradingStorageUtils.TradeSlUpdated(_tradeId.user, _tradeId.index, _newSl);
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function closeTrade(ITradingStorage.Id memory _tradeId, bool _isPnlPositive, uint64 _currentPairPrice) external {
        ITradingStorage.TradingStorage storage s = _getStorage();
        ITradingStorage.Trade storage t = s.trades[_tradeId.user][_tradeId.index];

        if (!t.isOpen) revert IGeneralErrors.DoesntExist();

        t.isOpen = false;
        s.userCounters[_tradeId.user][ITradingStorage.CounterType.TRADE].openCount--;

        if (t.tradeType == ITradingStorage.TradeType.TRADE)
            TradingCommonUtils.removeTradeOi(t, _isPnlPositive, _currentPairPrice);

        emit ITradingStorageUtils.TradeClosed(_tradeId.user, _tradeId.index, _isPnlPositive);
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function storePendingOrder(
        ITradingStorage.PendingOrder memory _pendingOrder
    ) external returns (ITradingStorage.PendingOrder memory) {
        if (_pendingOrder.user == address(0)) revert IGeneralErrors.ZeroAddress();

        ITradingStorage.TradingStorage storage s = _getStorage();
        ITradingStorage.Trade storage t = s.trades[_pendingOrder.trade.user][_pendingOrder.trade.index];

        if (_pendingOrder.orderType == ITradingStorage.PendingOrderType.MARKET_OPEN) {
            _validateTrade(_pendingOrder.trade);

            if (_pendingOrder.maxSlippageP == 0) revert ITradingStorageUtils.MaxSlippageZero();
        } else if (_pendingOrder.orderType != ITradingStorage.PendingOrderType.PARAM_UPDATE) {
            validateOpenTradeOrder(t, _pendingOrder.orderType);
        }

        uint256 blockNumber = ChainUtils.getBlockNumber();
        ITradingStorage.Counter memory counter = s.userCounters[_pendingOrder.user][
            ITradingStorage.CounterType.PENDING_ORDER
        ];

        _pendingOrder.index = counter.currentIndex;
        _pendingOrder.isOpen = true;
        _pendingOrder.createdBlock = uint32(blockNumber);

        counter.currentIndex++;
        counter.openCount++;

        s.pendingOrders[_pendingOrder.user][_pendingOrder.index] = _pendingOrder;
        s.userCounters[_pendingOrder.user][ITradingStorage.CounterType.PENDING_ORDER] = counter;

        if (_pendingOrder.orderType != ITradingStorage.PendingOrderType.MARKET_OPEN) {
            s.tradePendingOrderBlock[_pendingOrder.trade.user][_pendingOrder.trade.index][
                _pendingOrder.orderType
            ] = blockNumber;
        }

        if (!s.traderStored[_pendingOrder.user]) {
            s.traders.push(_pendingOrder.user);
            s.traderStored[_pendingOrder.user] = true;
        }

        emit ITradingStorageUtils.PendingOrderStored(_pendingOrder);

        return _pendingOrder;
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function closePendingOrder(ITradingStorage.Id memory _orderId) external {
        ITradingStorage.TradingStorage storage s = _getStorage();
        ITradingStorage.PendingOrder storage pendingOrder = s.pendingOrders[_orderId.user][_orderId.index];

        if (!pendingOrder.isOpen) revert IGeneralErrors.DoesntExist();

        pendingOrder.isOpen = false;
        s.userCounters[_orderId.user][ITradingStorage.CounterType.PENDING_ORDER].openCount--;

        if (pendingOrder.orderType != ITradingStorage.PendingOrderType.MARKET_OPEN) {
            delete s.tradePendingOrderBlock[pendingOrder.trade.user][pendingOrder.trade.index][pendingOrder.orderType];
        }

        emit ITradingStorageUtils.PendingOrderClosed(_orderId);
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function validateOpenTradeOrder(
        ITradingStorage.Trade memory _trade,
        ITradingStorage.PendingOrderType _orderType
    ) public pure {
        if (!_trade.isOpen) revert IGeneralErrors.DoesntExist();

        if (
            _orderType == ITradingStorage.PendingOrderType.LIMIT_OPEN
                ? _trade.tradeType != ITradingStorage.TradeType.LIMIT
                : _orderType == ITradingStorage.PendingOrderType.STOP_OPEN
                    ? _trade.tradeType != ITradingStorage.TradeType.STOP
                    : _trade.tradeType != ITradingStorage.TradeType.TRADE
        ) revert IGeneralErrors.WrongTradeType();

        if (_orderType == ITradingStorage.PendingOrderType.SL_CLOSE && _trade.sl == 0)
            revert ITradingInteractionsUtils.NoSl();

        if (_orderType == ITradingStorage.PendingOrderType.TP_CLOSE && _trade.tp == 0)
            revert ITradingInteractionsUtils.NoTp();
    }

    /**
     * @dev Returns storage slot to use when fetching storage relevant to library
     */
    function _getSlot() internal pure returns (uint256) {
        return StorageUtils.GLOBAL_TRADING_STORAGE_SLOT;
    }

    /**
     * @dev Returns storage pointer for storage struct in diamond contract, at defined slot
     */
    function _getStorage() internal pure returns (ITradingStorage.TradingStorage storage s) {
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
     * @dev Limits stop loss price distance for long/short based on '_openPrice', '_sl, '_leverage'.
     * @param _openPrice trade open price (1e10 precision)
     * @param _leverage trade leverage (1e3 precision)
     * @param _sl trade stop loss price (1e10 precision)
     * @param _long trade direction
     * @param _liqPnlThresholdP liquidation pnl threshold percentage (1e10)
     * @param _totalPositionSizeFeeP position size fee percentage (1e10)
     */
    function _limitSlDistance(
        uint64 _openPrice,
        uint24 _leverage,
        uint64 _sl,
        bool _long,
        uint256 _liqPnlThresholdP,
        uint256 _totalPositionSizeFeeP
    ) internal pure returns (uint64) {
        uint256 pnlFromFeesAndBufferP = (2 * _totalPositionSizeFeeP * _leverage) / 1e3 + ConstantsUtils.SL_LIQ_BUFFER_P;

        // It should never be the case where pnlFromFeesAndBufferP >= _liqPnlThresholdP, with a MIN_LIQ_THRESHOLD_P of 50%
        // However we still check to cover any potential underflow scenarios in the future
        if (pnlFromFeesAndBufferP >= _liqPnlThresholdP) {
            return uint64(0);
        }

        uint256 minSlPnlP = _liqPnlThresholdP - pnlFromFeesAndBufferP;

        if (_sl > 0 && TradingCommonUtils.getPnlPercent(_openPrice, _sl, _long, _leverage) < int256(minSlPnlP) * -1) {
            uint256 openPrice = uint256(_openPrice);
            uint256 slDiff = (openPrice * minSlPnlP * 1e3) / _leverage / 100 / ConstantsUtils.P_10;
            uint256 newSl = _long ? openPrice - slDiff : openPrice + slDiff;

            // Here an overflow (for shorts) is actually impossible because _sl is uint64
            // And the new stop loss is always closer (= lower for shorts) than the _sl input

            return uint64(newSl);
        }

        return _sl;
    }

    /**
     * @dev Limits trade stop loss price distance
     * @param _trade trade struct
     */
    function _limitTradeSlDistance(ITradingStorage.Trade memory _trade, uint64 _newSl) public view returns (uint64) {
        return
            _limitSlDistance(
                _trade.openPrice,
                _trade.leverage,
                _newSl,
                _trade.long,
                TradingCommonUtils.getTradeLiqPnlThresholdP(_trade),
                _getMultiCollatDiamond().getEffectiveTotalPositionSizeFeeP(_trade.pairIndex, _trade.isCounterTrade)
            );
    }

    /**
     * @dev Validation for trade struct (used by storeTrade and storePendingOrder for market open orders)
     * @param _trade trade struct to validate
     */
    function _validateTrade(ITradingStorage.Trade memory _trade) internal view {
        if (_trade.user == address(0)) revert IGeneralErrors.ZeroAddress();

        if (!_getMultiCollatDiamond().isPairIndexListed(_trade.pairIndex))
            revert ITradingStorageUtils.TradePairNotListed();

        if (TradingCommonUtils.getPositionSizeCollateral(_trade.collateralAmount, _trade.leverage) == 0)
            revert ITradingStorageUtils.TradePositionSizeZero();

        if (!_getStorage().collaterals[_trade.collateralIndex].isActive) revert IGeneralErrors.InvalidCollateralIndex();

        if (_trade.openPrice == 0) revert ITradingStorageUtils.TradeOpenPriceZero();

        if (_trade.tp != 0 && (_trade.long ? _trade.tp <= _trade.openPrice : _trade.tp >= _trade.openPrice))
            revert ITradingStorageUtils.TradeTpInvalid();

        if (_trade.sl != 0 && (_trade.long ? _trade.sl >= _trade.openPrice : _trade.sl <= _trade.openPrice))
            revert ITradingStorageUtils.TradeSlInvalid();
    }
}
