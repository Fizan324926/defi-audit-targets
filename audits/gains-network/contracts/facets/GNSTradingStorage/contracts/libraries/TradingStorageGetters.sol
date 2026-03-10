// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../interfaces/IGNSMultiCollatDiamond.sol";
import "./StorageUtils.sol";

/**
 * @dev External library for array getters to save bytecode size in facet libraries
 */

library TradingStorageGetters {
    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function getCollateral(uint8 _index) external view returns (ITradingStorage.Collateral memory) {
        return _getStorage().collaterals[_index];
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function isCollateralActive(uint8 _index) public view returns (bool) {
        return _getStorage().collaterals[_index].isActive;
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function isCollateralListed(uint8 _index) external view returns (bool) {
        return _getStorage().collaterals[_index].precision > 0;
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function isCollateralGns(uint8 _index) external view returns (bool) {
        uint8 gnsIndex = _getStorage().gnsCollateralIndex;

        return gnsIndex > 0 && gnsIndex == _index;
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function getCollateralsCount() external view returns (uint8) {
        return _getStorage().lastCollateralIndex;
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function getCollaterals() external view returns (ITradingStorage.Collateral[] memory) {
        ITradingStorage.TradingStorage storage s = _getStorage();
        ITradingStorage.Collateral[] memory collaterals = new ITradingStorage.Collateral[](s.lastCollateralIndex);

        for (uint8 i = 1; i <= s.lastCollateralIndex; ++i) {
            collaterals[i - 1] = s.collaterals[i];
        }

        return collaterals;
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function getCollateralIndex(address _collateral) external view returns (uint8) {
        return _getStorage().collateralIndex[_collateral];
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function getGnsCollateralIndex() external view returns (uint8) {
        return _getStorage().gnsCollateralIndex;
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function getTradingActivated() external view returns (ITradingStorage.TradingActivated) {
        return _getStorage().tradingActivated;
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function getTraderStored(address _trader) external view returns (bool) {
        return _getStorage().traderStored[_trader];
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function getTradersCount() external view returns (uint256) {
        return _getStorage().traders.length;
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function getTraders(uint32 _offset, uint32 _limit) public view returns (address[] memory) {
        ITradingStorage.TradingStorage storage s = _getStorage();

        if (s.traders.length == 0) return new address[](0);

        uint256 lastIndex = s.traders.length - 1;
        _limit = _limit == 0 || _limit > lastIndex ? uint32(lastIndex) : _limit;

        address[] memory traders = new address[](_limit - _offset + 1);

        uint32 currentIndex;
        for (uint32 i = _offset; i <= _limit; ++i) {
            address trader = s.traders[i];
            if (
                s.userCounters[trader][ITradingStorage.CounterType.TRADE].openCount > 0 ||
                s.userCounters[trader][ITradingStorage.CounterType.PENDING_ORDER].openCount > 0
            ) {
                traders[currentIndex++] = trader;
            }
        }

        return traders;
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function getTrade(address _trader, uint32 _index) internal view returns (ITradingStorage.Trade memory) {
        return _getStorage().trades[_trader][_index];
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function getTrades(address _trader) public view returns (ITradingStorage.Trade[] memory) {
        ITradingStorage.TradingStorage storage s = _getStorage();
        ITradingStorage.Counter memory traderCounter = s.userCounters[_trader][ITradingStorage.CounterType.TRADE];
        ITradingStorage.Trade[] memory trades = new ITradingStorage.Trade[](traderCounter.openCount);

        uint32 currentIndex;
        for (uint32 i; i < traderCounter.currentIndex; ++i) {
            ITradingStorage.Trade storage trade = s.trades[_trader][i];

            if (trade.isOpen) {
                trades[currentIndex++] = trade;

                // Exit loop if all open trades have been found
                if (currentIndex == traderCounter.openCount) break;
            }
        }

        return trades;
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function getAllTradesForTraders(
        address[] memory _traders,
        uint256 _offset,
        uint256 _limit
    ) public view returns (ITradingStorage.Trade[] memory) {
        ITradingStorage.TradingStorage storage s = _getStorage();

        uint256 currentTradeIndex; // current global trade index
        uint256 currentArrayIndex; // current index in returned trades array

        ITradingStorage.Trade[] memory trades = new ITradingStorage.Trade[](_limit - _offset + 1);

        // Fetch all trades for each trader
        for (uint256 i; i < _traders.length; ++i) {
            // Exit loop if limit is reached
            if (currentTradeIndex > _limit) break;

            // Skip if next trader address is 0; `getTraders` can return address(0)
            address trader = _traders[i];
            if (trader == address(0)) continue;

            // Fetch trader trade counter
            ITradingStorage.Counter memory traderCounter = s.userCounters[trader][ITradingStorage.CounterType.TRADE];

            // Exit if user has no open trades
            // We check because `getTraders` also traders with pending orders
            if (traderCounter.openCount == 0) continue;

            // If current trade index + openCount is lte to offset, skip to next trader
            if (currentTradeIndex + traderCounter.openCount <= _offset) {
                currentTradeIndex += traderCounter.openCount;
                continue;
            }

            ITradingStorage.Trade[] memory traderTrades = getTrades(trader);

            // Add trader trades to final trades array only if within _offset and _limit
            for (uint256 j; j < traderTrades.length; ++j) {
                if (currentTradeIndex > _limit) break; // Exit loop if limit is reached

                // Only process trade if currentTradeIndex is >= offset
                if (currentTradeIndex >= _offset) {
                    trades[currentArrayIndex++] = traderTrades[j];
                }

                currentTradeIndex++;
            }
        }

        return trades;
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function getAllTrades(uint256 _offset, uint256 _limit) external view returns (ITradingStorage.Trade[] memory) {
        // Fetch all traders with open trades (no pagination, return size is not an issue here)
        address[] memory traders = getTraders(0, 0);
        return getAllTradesForTraders(traders, _offset, _limit);
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function getTradeInfo(address _trader, uint32 _index) internal view returns (ITradingStorage.TradeInfo memory) {
        return _getStorage().tradeInfos[_trader][_index];
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function getTradeInfos(address _trader) public view returns (ITradingStorage.TradeInfo[] memory) {
        ITradingStorage.TradingStorage storage s = _getStorage();
        ITradingStorage.Counter memory traderCounter = s.userCounters[_trader][ITradingStorage.CounterType.TRADE];
        ITradingStorage.TradeInfo[] memory tradeInfos = new ITradingStorage.TradeInfo[](traderCounter.openCount);

        uint32 currentIndex;
        for (uint32 i; i < traderCounter.currentIndex; ++i) {
            if (s.trades[_trader][i].isOpen) {
                tradeInfos[currentIndex++] = s.tradeInfos[_trader][i];

                // Exit loop if all open trade infos have been found
                if (currentIndex == traderCounter.openCount) break;
            }
        }

        return tradeInfos;
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function getAllTradeInfosForTraders(
        address[] memory _traders,
        uint256 _offset,
        uint256 _limit
    ) public view returns (ITradingStorage.TradeInfo[] memory) {
        ITradingStorage.TradingStorage storage s = _getStorage();

        uint256 currentTradeIndex; // current global trade index
        uint256 currentArrayIndex; // current index in returned trades array

        ITradingStorage.TradeInfo[] memory tradesInfos = new ITradingStorage.TradeInfo[](_limit - _offset + 1);

        // Fetch all trades for each trader
        for (uint256 i; i < _traders.length; ++i) {
            // Exit loop if limit is reached
            if (currentTradeIndex > _limit) break;

            // Skip if next trader address is 0; `getTraders` can return address(0)
            address trader = _traders[i];
            if (trader == address(0)) continue;

            // Fetch trader trade counter
            ITradingStorage.Counter memory traderCounter = s.userCounters[trader][ITradingStorage.CounterType.TRADE];

            // Exit if user has no open trades
            // We check because `getTraders` also traders with pending orders
            if (traderCounter.openCount == 0) continue;

            // If current trade index + openCount is lte to offset, skip to next trader
            if (currentTradeIndex + traderCounter.openCount <= _offset) {
                currentTradeIndex += traderCounter.openCount;
                continue;
            }

            ITradingStorage.TradeInfo[] memory traderTradesInfos = getTradeInfos(trader);

            // Add trader trades to final trades array only if within _offset and _limit
            for (uint256 j; j < traderTradesInfos.length; ++j) {
                if (currentTradeIndex > _limit) break; // Exit loop if limit is reached

                if (currentTradeIndex >= _offset) {
                    tradesInfos[currentArrayIndex++] = traderTradesInfos[j];
                }

                currentTradeIndex++;
            }
        }

        return tradesInfos;
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function getAllTradeInfos(
        uint256 _offset,
        uint256 _limit
    ) external view returns (ITradingStorage.TradeInfo[] memory) {
        // Fetch all traders with open trades (no pagination, return size is not an issue here)
        address[] memory traders = getTraders(0, 0);
        return getAllTradeInfosForTraders(traders, _offset, _limit);
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function getPendingOrder(
        ITradingStorage.Id memory _orderId
    ) external view returns (ITradingStorage.PendingOrder memory) {
        return _getStorage().pendingOrders[_orderId.user][_orderId.index];
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function getPendingOrders(address _trader) public view returns (ITradingStorage.PendingOrder[] memory) {
        ITradingStorage.TradingStorage storage s = _getStorage();
        ITradingStorage.Counter memory traderCounter = s.userCounters[_trader][
            ITradingStorage.CounterType.PENDING_ORDER
        ];
        ITradingStorage.PendingOrder[] memory pendingOrders = new ITradingStorage.PendingOrder[](
            traderCounter.openCount
        );

        // Return early
        if (traderCounter.openCount == 0) return pendingOrders;

        uint32 currentIndex;
        for (uint32 i; i < traderCounter.currentIndex; ++i) {
            if (s.pendingOrders[_trader][i].isOpen) {
                pendingOrders[currentIndex++] = s.pendingOrders[_trader][i];

                // Exit loop if all open pending orders have been found
                if (currentIndex == traderCounter.openCount) break;
            }
        }

        return pendingOrders;
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function getAllPendingOrdersForTraders(
        address[] memory _traders,
        uint256 _offset,
        uint256 _limit
    ) public view returns (ITradingStorage.PendingOrder[] memory) {
        ITradingStorage.TradingStorage storage s = _getStorage();

        uint256 currentPendingOrderIndex; // current global pending order index
        uint256 currentArrayIndex; // current index in returned pending orders array

        ITradingStorage.PendingOrder[] memory pendingOrders = new ITradingStorage.PendingOrder[](_limit - _offset + 1);

        // Fetch all trades for each trader
        for (uint256 i; i < _traders.length; ++i) {
            // Exit loop if limit is reached
            if (currentPendingOrderIndex > _limit) break;

            // Skip if next trader address is 0; `getTraders` can return address(0)
            address trader = _traders[i];
            if (trader == address(0)) continue;

            // Fetch trader trade counter
            ITradingStorage.Counter memory traderCounter = s.userCounters[trader][
                ITradingStorage.CounterType.PENDING_ORDER
            ];

            // Exit if user has no open pending orders
            // We check because `getTraders` also traders with pending orders
            if (traderCounter.openCount == 0) continue;

            // If current trade index + openCount is lte to offset, skip to next trader
            if (currentPendingOrderIndex + traderCounter.openCount <= _offset) {
                currentPendingOrderIndex += traderCounter.openCount;
                continue;
            }

            ITradingStorage.PendingOrder[] memory traderPendingOrders = getPendingOrders(trader);

            // Add trader trades to final trades array only if within _offset and _limit
            for (uint256 j; j < traderPendingOrders.length; ++j) {
                if (currentPendingOrderIndex > _limit) break; // Exit loop if limit is reached

                if (currentPendingOrderIndex >= _offset) {
                    pendingOrders[currentArrayIndex++] = traderPendingOrders[j];
                }

                currentPendingOrderIndex++;
            }
        }

        return pendingOrders;
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function getAllPendingOrders(
        uint256 _offset,
        uint256 _limit
    ) external view returns (ITradingStorage.PendingOrder[] memory) {
        // Fetch all traders with open trades (no pagination, return size is not an issue here)
        address[] memory traders = getTraders(0, 0);
        return getAllPendingOrdersForTraders(traders, _offset, _limit);
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function getTradePendingOrderBlock(
        ITradingStorage.Id memory _tradeId,
        ITradingStorage.PendingOrderType _orderType
    ) external view returns (uint256) {
        return _getStorage().tradePendingOrderBlock[_tradeId.user][_tradeId.index][_orderType];
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function getCounters(
        address _trader,
        ITradingStorage.CounterType _type
    ) external view returns (ITradingStorage.Counter memory) {
        return _getStorage().userCounters[_trader][_type];
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function getCountersForTraders(
        address[] calldata _traders,
        ITradingStorage.CounterType _counterType
    ) external view returns (ITradingStorage.Counter[] memory) {
        ITradingStorage.TradingStorage storage s = _getStorage();
        ITradingStorage.Counter[] memory counters = new ITradingStorage.Counter[](_traders.length);

        for (uint256 i; i < _traders.length; ++i) {
            counters[i] = s.userCounters[_traders[i]][_counterType];
        }

        return counters;
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function getGToken(uint8 _collateralIndex) external view returns (address) {
        return _getStorage().gTokens[_collateralIndex];
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function getTradeLiquidationParams(
        address _trader,
        uint32 _index
    ) external view returns (IPairsStorage.GroupLiquidationParams memory) {
        return _getStorage().tradeLiquidationParams[_trader][_index];
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function getTradesLiquidationParams(
        address _trader
    ) public view returns (IPairsStorage.GroupLiquidationParams[] memory) {
        ITradingStorage.TradingStorage storage s = _getStorage();
        ITradingStorage.Counter memory traderCounter = s.userCounters[_trader][ITradingStorage.CounterType.TRADE];
        IPairsStorage.GroupLiquidationParams[]
            memory tradeLiquidationParams = new IPairsStorage.GroupLiquidationParams[](traderCounter.openCount);

        uint32 currentIndex;
        for (uint32 i; i < traderCounter.currentIndex; ++i) {
            if (s.trades[_trader][i].isOpen) {
                tradeLiquidationParams[currentIndex++] = s.tradeLiquidationParams[_trader][i];

                // Exit loop if all open trades have been found
                if (currentIndex == traderCounter.openCount) break;
            }
        }

        return tradeLiquidationParams;
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function getAllTradesLiquidationParamsForTraders(
        address[] memory _traders,
        uint256 _offset,
        uint256 _limit
    ) public view returns (IPairsStorage.GroupLiquidationParams[] memory) {
        ITradingStorage.TradingStorage storage s = _getStorage();

        uint256 currentTradeLiquidationParamIndex; // current global trade liquidation params index
        uint256 currentArrayIndex; // current index in returned trade liquidation params array

        IPairsStorage.GroupLiquidationParams[]
            memory tradeLiquidationParams = new IPairsStorage.GroupLiquidationParams[](_limit - _offset + 1);

        // Fetch all trades for each trader
        for (uint256 i; i < _traders.length; ++i) {
            // Exit loop if limit is reached
            if (currentTradeLiquidationParamIndex > _limit) break;

            // Skip if next trader address is 0; `getTraders` can return address(0)
            address trader = _traders[i];
            if (trader == address(0)) continue;

            // Fetch trader trade counter
            ITradingStorage.Counter memory traderCounter = s.userCounters[trader][ITradingStorage.CounterType.TRADE];

            // Exit if user has no open trades
            // We check because `getTraders` also traders with pending orders
            if (traderCounter.openCount == 0) continue;

            // If current trade index + openCount is lte to offset, skip to next trader
            if (currentTradeLiquidationParamIndex + traderCounter.openCount <= _offset) {
                currentTradeLiquidationParamIndex += traderCounter.openCount;
                continue;
            }

            IPairsStorage.GroupLiquidationParams[] memory traderLiquidationParams = getTradesLiquidationParams(trader);

            // Add trader trades to final trades array only if within _offset and _limit
            for (uint256 j; j < traderLiquidationParams.length; ++j) {
                if (currentTradeLiquidationParamIndex > _limit) break; // Exit loop if limit is reached

                if (currentTradeLiquidationParamIndex >= _offset) {
                    tradeLiquidationParams[currentArrayIndex++] = traderLiquidationParams[j];
                }

                currentTradeLiquidationParamIndex++;
            }
        }

        return tradeLiquidationParams;
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function getAllTradesLiquidationParams(
        uint256 _offset,
        uint256 _limit
    ) external view returns (IPairsStorage.GroupLiquidationParams[] memory) {
        // Fetch all traders with open trades (no pagination, return size is not an issue here)
        address[] memory traders = getTraders(0, 0);
        return getAllTradesLiquidationParamsForTraders(traders, _offset, _limit);
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function getCurrentContractsVersion() external pure returns (ITradingStorage.ContractsVersion) {
        return ITradingStorage.ContractsVersion.V10;
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function getTradeContractsVersion(
        address _trader,
        uint32 _index
    ) external view returns (ITradingStorage.ContractsVersion) {
        return _getStorage().tradeInfos[_trader][_index].contractsVersion;
    }

    /**
     * @dev Check ITradingStorageUtils interface for documentation
     */
    function getLookbackFromBlock(
        address _trader,
        uint32 _index,
        ITradingStorage.PendingOrderType _orderType
    ) external view returns (uint32) {
        ITradingStorage.TradeInfo memory tradeInfo = getTradeInfo(_trader, _index);

        return
            _orderType == ITradingStorage.PendingOrderType.SL_CLOSE
                ? tradeInfo.slLastUpdatedBlock
                : _orderType == ITradingStorage.PendingOrderType.TP_CLOSE
                    ? tradeInfo.tpLastUpdatedBlock
                    : tradeInfo.createdBlock;
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
}
