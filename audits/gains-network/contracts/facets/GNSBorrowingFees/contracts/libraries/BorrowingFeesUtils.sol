// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../interfaces/IGNSMultiCollatDiamond.sol";

import "./PackingUtils.sol";
import "./StorageUtils.sol";
import "./ChainUtils.sol";
import "./ConstantsUtils.sol";
import "./TradingCommonUtils.sol";

/**
 *
 * @dev GNSBorrowingFees facet external library
 */
library BorrowingFeesUtils {
    uint32 private constant MAX_FEE_PER_BLOCK_CAP_P = 100e3; // 100%

    /**
     * @dev Check IBorrowingFeesUtils interface for documentation
     */
    function setBorrowingPairParams(
        uint8 _collateralIndex,
        uint16 _pairIndex,
        IBorrowingFees.BorrowingPairParams calldata _value,
        IPriceAggregator.SignedPairPrices[] calldata _signedPairPrices
    ) public validCollateralIndex(_collateralIndex) useSignedMarketPrices(_signedPairPrices) {
        _setBorrowingPairParamsWithSignedPrices(_collateralIndex, _pairIndex, _value);
    }

    /**
     * @dev Check IBorrowingFeesUtils interface for documentation
     */
    function setBorrowingPairParamsArray(
        uint8 _collateralIndex,
        uint16[] calldata _indices,
        IBorrowingFees.BorrowingPairParams[] calldata _values,
        IPriceAggregator.SignedPairPrices[] calldata _signedPairPrices
    ) external validCollateralIndex(_collateralIndex) useSignedMarketPrices(_signedPairPrices) {
        uint256 len = _indices.length;
        if (len != _values.length) revert IGeneralErrors.WrongLength();

        for (uint256 i; i < len; ++i) {
            _setBorrowingPairParamsWithSignedPrices(_collateralIndex, _indices[i], _values[i]);
        }
    }

    /**
     * @dev Check IBorrowingFeesUtils interface for documentation
     */
    function setBorrowingGroupParams(
        uint8 _collateralIndex,
        uint16 _groupIndex,
        IBorrowingFees.BorrowingGroupParams calldata _value
    ) external validCollateralIndex(_collateralIndex) {
        _setBorrowingGroupParams(_collateralIndex, _groupIndex, _value);
    }

    /**
     * @dev Check IBorrowingFeesUtils interface for documentation
     */
    function setBorrowingGroupParamsArray(
        uint8 _collateralIndex,
        uint16[] calldata _indices,
        IBorrowingFees.BorrowingGroupParams[] calldata _values
    ) external validCollateralIndex(_collateralIndex) {
        uint256 len = _indices.length;
        if (len != _values.length) {
            revert IGeneralErrors.WrongLength();
        }

        for (uint256 i; i < len; ++i) {
            _setBorrowingGroupParams(_collateralIndex, _indices[i], _values[i]);
        }
    }

    /**
     * @dev Check IBorrowingFeesUtils interface for documentation
     */
    function setBorrowingFeePerBlockCap(IBorrowingFees.BorrowingFeePerBlockCap memory _feePerBlockCap) external {
        _validateBorrowingFeePerBlockCap(_feePerBlockCap);

        _getStorage().feePerBlockCap = _feePerBlockCap;

        emit IBorrowingFeesUtils.BorrowingFeePerBlockCapUpdated(_feePerBlockCap.minP, _feePerBlockCap.maxP);
    }

    /**
     * @dev Check IBorrowingFeesUtils interface for documentation
     */
    function setBorrowingPairFeePerBlockCapArray(
        uint8 _collateralIndex,
        uint16[] calldata _indices,
        IBorrowingFees.BorrowingFeePerBlockCap[] calldata _values
    ) external validCollateralIndex(_collateralIndex) {
        uint256 len = _indices.length;

        if (len != _values.length) {
            revert IGeneralErrors.WrongLength();
        }

        for (uint256 i; i < len; ++i) {
            IBorrowingFees.BorrowingFeePerBlockCap memory value = _values[i];
            _validateBorrowingFeePerBlockCap(value);

            uint16 pairIndex = _indices[i];
            _getStorage().pairFeePerBlockCaps[_collateralIndex][pairIndex] = value;

            emit IBorrowingFeesUtils.BorrowingPairFeePerBlockCapUpdated(
                _collateralIndex,
                pairIndex,
                value.minP,
                value.maxP
            );
        }
    }

    /**
     * @dev Check IBorrowingFeesUtils interface for documentation
     */
    function borrowingParamUpdateCallback(
        IFundingFees.PendingParamUpdate memory _paramUpdate,
        uint256 _currentPairPrice
    ) external {
        uint256[] memory decodedValues = new uint256[](4);
        decodedValues = PackingUtils.unpack(uint256(_paramUpdate.newValue), _getBorrowingPairParamsBitLengths());

        IBorrowingFees.BorrowingPairParams memory decodedValue;
        decodedValue.groupIndex = uint16(decodedValues[0]);
        decodedValue.feePerBlock = uint32(decodedValues[1]);
        decodedValue.feeExponent = uint48(decodedValues[2]);
        decodedValue.maxOi = uint72(decodedValues[3]);

        _setBorrowingPairParams(_paramUpdate.collateralIndex, _paramUpdate.pairIndex, decodedValue, _currentPairPrice);
    }

    /**
     * @dev Check IBorrowingFeesUtils interface for documentation
     */
    function handleTradeBorrowingCallback(
        uint8 _collateralIndex,
        address _trader,
        uint16 _pairIndex,
        uint32 _index,
        uint256 _positionSizeCollateral,
        bool _open,
        bool _long,
        uint256 _currentPairPrice
    ) external validCollateralIndex(_collateralIndex) {
        // 1. Store pair and group pending acc fees until now
        uint256 blockNumber = ChainUtils.getBlockNumber();
        uint16 groupIndex = getBorrowingPairGroupIndex(_collateralIndex, _pairIndex);
        _setPairPendingAccFees(_collateralIndex, _pairIndex, blockNumber, _currentPairPrice);
        _setGroupPendingAccFees(_collateralIndex, groupIndex, blockNumber);

        // 2. Update group OI (pair OI handled separately)
        if (_positionSizeCollateral > 0)
            _updateGroupOi(_collateralIndex, groupIndex, _long, _open, _positionSizeCollateral);

        // 3. Set trade initial acc fees (resets trade borrowing fees to 0)
        _resetTradeBorrowingFees(_collateralIndex, _trader, _pairIndex, _index, _long, _currentPairPrice);

        emit IBorrowingFeesUtils.TradeBorrowingCallbackHandled(
            _collateralIndex,
            _trader,
            _pairIndex,
            _index,
            _open,
            _long,
            _currentPairPrice,
            _positionSizeCollateral
        );
    }

    /**
     * @dev Check IBorrowingFeesUtils interface for documentation
     */
    function updatePairOiBeforeV10(
        uint8 _collateralIndex,
        uint16 _pairIndex,
        bool _long,
        bool _increase,
        uint256 _amountCollateral
    ) external {
        (uint72 newOiLong, uint72 newOiShort, uint72 delta) = _updateOi(
            _getStorage().pairOisBeforeV10[_collateralIndex][_pairIndex],
            _long,
            _increase,
            _amountCollateral,
            _getMultiCollatDiamond().getCollateral(_collateralIndex).precision
        );

        emit IBorrowingFeesUtils.BorrowingPairOiBeforeV10Updated(
            _collateralIndex,
            _pairIndex,
            _long,
            _increase,
            delta,
            newOiLong,
            newOiShort
        );
    }

    /**
     * @dev Check IBorrowingFeesUtils interface for documentation
     */
    function getBorrowingPairPendingAccFees(
        uint8 _collateralIndex,
        uint16 _pairIndex,
        uint256 _currentBlock,
        uint256 _currentPairPrice
    )
        internal
        view
        returns (uint64 accFeeLong, uint64 accFeeShort, uint64 pairAccFeeLongDelta, uint64 pairAccFeeShortDelta)
    {
        IBorrowingFees.BorrowingFeesStorage storage s = _getStorage();
        IBorrowingFees.BorrowingData memory pair = s.pairs[_collateralIndex][_pairIndex];

        (uint256 pairOiLong, uint256 pairOiShort) = TradingCommonUtils.getPairTotalOisDynamicCollateral(
            _collateralIndex,
            _pairIndex,
            _currentPairPrice
        );

        IBorrowingFees.PendingBorrowingAccFeesInput memory input;
        input.accFeeLong = pair.accFeeLong;
        input.accFeeShort = pair.accFeeShort;
        input.oiLong = pairOiLong;
        input.oiShort = pairOiShort;
        input.feePerBlock = pair.feePerBlock;
        input.currentBlock = _currentBlock;
        input.accLastUpdatedBlock = pair.accLastUpdatedBlock;
        input.maxOi = s.pairOisBeforeV10[_collateralIndex][_pairIndex].max;
        input.feeExponent = pair.feeExponent;
        input.collateralPrecision = _getMultiCollatDiamond().getCollateral(_collateralIndex).precision;
        input.feePerBlockCap = getBorrowingPairFeePerBlockCap(_collateralIndex, _pairIndex);

        (accFeeLong, accFeeShort, pairAccFeeLongDelta, pairAccFeeShortDelta) = _getBorrowingPendingAccFees(input);
    }

    /**
     * @dev Check IBorrowingFeesUtils interface for documentation
     */
    function getBorrowingGroupPendingAccFees(
        uint8 _collateralIndex,
        uint16 _groupIndex,
        uint256 _currentBlock
    )
        internal
        view
        returns (uint64 accFeeLong, uint64 accFeeShort, uint64 groupAccFeeLongDelta, uint64 groupAccFeeShortDelta)
    {
        IBorrowingFees.BorrowingFeesStorage storage s = _getStorage();

        IBorrowingFees.BorrowingData memory group = s.groups[_collateralIndex][_groupIndex];
        IBorrowingFees.OpenInterest memory groupOi = s.groupOis[_collateralIndex][_groupIndex];

        uint128 collateralPrecision = _getMultiCollatDiamond().getCollateral(_collateralIndex).precision;

        (accFeeLong, accFeeShort, groupAccFeeLongDelta, groupAccFeeShortDelta) = _getBorrowingPendingAccFees(
            IBorrowingFees.PendingBorrowingAccFeesInput(
                group.accFeeLong,
                group.accFeeShort,
                (uint256(groupOi.long) * collateralPrecision) / ConstantsUtils.P_10,
                (uint256(groupOi.short) * collateralPrecision) / ConstantsUtils.P_10,
                group.feePerBlock,
                _currentBlock,
                group.accLastUpdatedBlock,
                groupOi.max,
                group.feeExponent,
                collateralPrecision,
                IBorrowingFees.BorrowingFeePerBlockCap(0, 0)
            )
        );
    }

    /**
     * @dev Check IBorrowingFeesUtils interface for documentation
     */
    function getTradeBorrowingFee(
        IBorrowingFees.BorrowingFeeInput memory _input
    ) internal view returns (uint256 feeAmountCollateral) {
        IBorrowingFees.GetTradeBorrowingFeeValues memory v;

        v.initialFees = _getStorage().initialAccFees[_input.collateralIndex][_input.trader][_input.index];
        IBorrowingFees.BorrowingPairGroup[] memory pairGroups = _getStorage().pairGroups[_input.collateralIndex][
            _input.pairIndex
        ];

        if (pairGroups.length > 0) {
            v.firstPairGroup = pairGroups[0];
        }

        // If pair has had no group after trade was opened, initialize with pair borrowing fee
        if (pairGroups.length == 0 || v.firstPairGroup.block > v.initialFees.block) {
            v.borrowingFeeP = ((
                pairGroups.length == 0
                    ? _getBorrowingPairPendingAccFee(
                        _input.collateralIndex,
                        _input.pairIndex,
                        ChainUtils.getBlockNumber(),
                        _input.long,
                        _input.currentPairPrice
                    )
                    : (_input.long ? v.firstPairGroup.pairAccFeeLong : v.firstPairGroup.pairAccFeeShort)
            ) - v.initialFees.accPairFee);
        }

        // Sum of max(pair fee, group fee) for all groups the pair was in while trade was open
        for (uint256 i = pairGroups.length; i > 0; --i) {
            (uint64 deltaGroup, uint64 deltaPair, bool beforeTradeOpen) = _getBorrowingPairGroupAccFeesDeltas(
                _input.collateralIndex,
                i - 1,
                pairGroups,
                v.initialFees,
                _input.pairIndex,
                _input.long,
                ChainUtils.getBlockNumber(),
                _input.currentPairPrice
            );

            v.borrowingFeeP += (deltaGroup > deltaPair ? deltaGroup : deltaPair);

            // Exit loop at first group before trade was open
            if (beforeTradeOpen) break;
        }

        feeAmountCollateral = (_input.collateral * _input.leverage * v.borrowingFeeP) / 1e3 / ConstantsUtils.P_10 / 100; // collateral precision
    }

    /**
     * @dev Check IBorrowingFeesUtils interface for documentation
     */
    function getTradeLiquidationPrice(IBorrowingFees.LiqPriceInput calldata _input) internal view returns (uint256) {
        uint256 closingFeesCollateral = TradingCommonUtils.getTotalTradeFeesCollateral(
            _input.collateralIndex,
            address(0), // never apply fee tiers
            _input.pairIndex,
            (_input.collateral * _input.leverage) / 1e3,
            _input.isCounterTrade
        );

        IFundingFees.TradeHoldingFees memory holdingFees;
        int256 totalRealizedPnlCollateral;

        if (!_input.beforeOpened) {
            holdingFees = _getMultiCollatDiamond().getTradePendingHoldingFeesCollateral(
                _input.trader,
                _input.index,
                _input.currentPairPrice
            );

            (, , totalRealizedPnlCollateral) = _getMultiCollatDiamond().getTradeRealizedPnlCollateral(
                _input.trader,
                _input.index
            );
        }

        uint256 spreadP = _getMultiCollatDiamond().pairSpreadP(_input.trader, _input.pairIndex);
        ITradingStorage.ContractsVersion contractsVersion = _input.beforeOpened
            ? _getMultiCollatDiamond().getCurrentContractsVersion()
            : _getMultiCollatDiamond().getTradeContractsVersion(_input.trader, _input.index);

        return
            _getTradeLiquidationPrice(
                _input.openPrice,
                _input.long,
                _input.collateral,
                _input.leverage,
                int256(closingFeesCollateral) +
                    ((holdingFees.totalFeeCollateral - totalRealizedPnlCollateral) *
                        int256(_input.partialCloseMultiplier)) /
                    1e18 +
                    _input.additionalFeeCollateral,
                _getMultiCollatDiamond().getCollateral(_input.collateralIndex).precisionDelta,
                _input.liquidationParams,
                contractsVersion,
                spreadP
            );
    }

    /**
     * @dev Check IBorrowingFeesUtils interface for documentation
     */
    function getPairOisBeforeV10Collateral(
        uint8 _collateralIndex,
        uint16 _pairIndex
    ) internal view returns (uint256 longOiCollateral, uint256 shortOiCollateral) {
        IBorrowingFees.OpenInterest storage pairOi = _getStorage().pairOisBeforeV10[_collateralIndex][_pairIndex];
        ITradingStorageUtils.Collateral memory collateralConfig = _getMultiCollatDiamond().getCollateral(
            _collateralIndex
        );
        return (
            (pairOi.long * collateralConfig.precision) / ConstantsUtils.P_10,
            (pairOi.short * collateralConfig.precision) / ConstantsUtils.P_10
        );
    }

    /**
     * @dev Check IBorrowingFeesUtils interface for documentation
     */
    function getBorrowingPairGroupIndex(
        uint8 _collateralIndex,
        uint16 _pairIndex
    ) internal view returns (uint16 groupIndex) {
        IBorrowingFees.BorrowingPairGroup[] memory pairGroups = _getStorage().pairGroups[_collateralIndex][_pairIndex];
        return pairGroups.length == 0 ? 0 : pairGroups[pairGroups.length - 1].groupIndex;
    }

    /**
     * @dev Check IBorrowingFeesUtils interface for documentation
     */
    function getPairOiBeforeV10Collateral(
        uint8 _collateralIndex,
        uint16 _pairIndex,
        bool _long
    ) internal view returns (uint256) {
        (uint256 longOiCollateral, uint256 shortOiCollateral) = getPairOisBeforeV10Collateral(
            _collateralIndex,
            _pairIndex
        );
        return _long ? longOiCollateral : shortOiCollateral;
    }

    /**
     * @dev Check IBorrowingFeesUtils interface for documentation
     */
    function withinMaxBorrowingGroupOi(
        uint8 _collateralIndex,
        uint16 _pairIndex,
        bool _long,
        uint256 _positionSizeCollateral
    ) internal view returns (bool) {
        IBorrowingFees.OpenInterest memory groupOi = _getStorage().groupOis[_collateralIndex][
            getBorrowingPairGroupIndex(_collateralIndex, _pairIndex)
        ];

        return
            (groupOi.max == 0) ||
            ((_long ? groupOi.long : groupOi.short) +
                (_positionSizeCollateral * ConstantsUtils.P_10) /
                _getMultiCollatDiamond().getCollateral(_collateralIndex).precision <=
                groupOi.max);
    }

    /**
     * @dev Check IBorrowingFeesUtils interface for documentation
     */
    function getBorrowingGroup(
        uint8 _collateralIndex,
        uint16 _groupIndex
    ) internal view returns (IBorrowingFees.BorrowingData memory) {
        return _getStorage().groups[_collateralIndex][_groupIndex];
    }

    /**
     * @dev Check IBorrowingFeesUtils interface for documentation
     */
    function getBorrowingGroupOi(
        uint8 _collateralIndex,
        uint16 _groupIndex
    ) internal view returns (IBorrowingFees.OpenInterest memory) {
        return _getStorage().groupOis[_collateralIndex][_groupIndex];
    }

    /**
     * @dev Check IBorrowingFeesUtils interface for documentation
     */
    function getBorrowingPair(
        uint8 _collateralIndex,
        uint16 _pairIndex
    ) internal view returns (IBorrowingFees.BorrowingData memory) {
        return _getStorage().pairs[_collateralIndex][_pairIndex];
    }

    /**
     * @dev Check IBorrowingFeesUtils interface for documentation
     */
    function getBorrowingPairOiBeforeV10(
        uint8 _collateralIndex,
        uint16 _pairIndex
    ) internal view returns (IBorrowingFees.OpenInterest memory) {
        return _getStorage().pairOisBeforeV10[_collateralIndex][_pairIndex];
    }

    /**
     * @dev Check IBorrowingFeesUtils interface for documentation
     */
    function getBorrowingPairGroups(
        uint8 _collateralIndex,
        uint16 _pairIndex
    ) internal view returns (IBorrowingFees.BorrowingPairGroup[] memory) {
        return _getStorage().pairGroups[_collateralIndex][_pairIndex];
    }

    /**
     * @dev Check IBorrowingFeesUtils interface for documentation
     */
    function getAllBorrowingPairs(
        uint8 _collateralIndex
    )
        internal
        view
        returns (
            IBorrowingFees.BorrowingData[] memory,
            IBorrowingFees.OpenInterest[] memory,
            IBorrowingFees.BorrowingPairGroup[][] memory
        )
    {
        IBorrowingFees.BorrowingFeesStorage storage s = _getStorage();

        uint16 len = uint16(_getMultiCollatDiamond().pairsCount());
        IBorrowingFees.BorrowingData[] memory pairs = new IBorrowingFees.BorrowingData[](len);
        IBorrowingFees.OpenInterest[] memory pairOi = new IBorrowingFees.OpenInterest[](len);
        IBorrowingFees.BorrowingPairGroup[][] memory pairGroups = new IBorrowingFees.BorrowingPairGroup[][](len);

        for (uint16 i; i < len; ++i) {
            pairs[i] = s.pairs[_collateralIndex][i];
            pairOi[i] = s.pairOisBeforeV10[_collateralIndex][i];
            pairGroups[i] = s.pairGroups[_collateralIndex][i];
        }

        return (pairs, pairOi, pairGroups);
    }

    /**
     * @dev Check IBorrowingFeesUtils interface for documentation
     */
    function getBorrowingGroups(
        uint8 _collateralIndex,
        uint16[] calldata _indices
    ) internal view returns (IBorrowingFees.BorrowingData[] memory, IBorrowingFees.OpenInterest[] memory) {
        IBorrowingFees.BorrowingFeesStorage storage s = _getStorage();

        uint256 len = _indices.length;
        IBorrowingFees.BorrowingData[] memory groups = new IBorrowingFees.BorrowingData[](len);
        IBorrowingFees.OpenInterest[] memory groupOis = new IBorrowingFees.OpenInterest[](len);

        for (uint256 i; i < len; ++i) {
            groups[i] = s.groups[_collateralIndex][_indices[i]];
            groupOis[i] = s.groupOis[_collateralIndex][_indices[i]];
        }

        return (groups, groupOis);
    }

    /**
     * @dev Check IBorrowingFeesUtils interface for documentation
     */
    function getBorrowingInitialAccFees(
        uint8 _collateralIndex,
        address _trader,
        uint32 _index
    ) internal view returns (IBorrowingFees.BorrowingInitialAccFees memory) {
        return _getStorage().initialAccFees[_collateralIndex][_trader][_index];
    }

    /**
     * @dev Check IBorrowingFeesUtils interface for documentation
     */
    function getPairMaxOi(uint8 _collateralIndex, uint16 _pairIndex) internal view returns (uint256) {
        return _getStorage().pairOisBeforeV10[_collateralIndex][_pairIndex].max;
    }

    /**
     * @dev Check IBorrowingFeesUtils interface for documentation
     */
    function getPairMaxOiCollateral(uint8 _collateralIndex, uint16 _pairIndex) internal view returns (uint256) {
        return
            (uint256(_getMultiCollatDiamond().getCollateral(_collateralIndex).precision) *
                _getStorage().pairOisBeforeV10[_collateralIndex][_pairIndex].max) / ConstantsUtils.P_10;
    }

    /**
     * @dev Check IBorrowingFeesUtils interface for documentation
     */
    function getBorrowingFeePerBlockCap() internal view returns (IBorrowingFees.BorrowingFeePerBlockCap memory) {
        return _getStorage().feePerBlockCap;
    }

    /**
     * @dev Check IBorrowingFeesUtils interface for documentation
     */
    function getBorrowingPairFeePerBlockCap(
        uint8 _collateralIndex,
        uint16 _pairIndex
    ) internal view returns (IBorrowingFees.BorrowingFeePerBlockCap memory) {
        IBorrowingFees.BorrowingFeesStorage storage s = _getStorage();
        IBorrowingFees.BorrowingFeePerBlockCap memory pairFeePerBlockCap = s.pairFeePerBlockCaps[_collateralIndex][
            _pairIndex
        ];

        // If pairFeePerBlockCap.maxP > 0, it means there's a custom cap for this pair
        return pairFeePerBlockCap.maxP > 0 ? pairFeePerBlockCap : s.feePerBlockCap;
    }

    /**
     * @dev Check IBorrowingFeesUtils interface for documentation
     */
    function getBorrowingPairFeePerBlockCaps(
        uint8 _collateralIndex,
        uint16[] calldata _indices
    ) internal view returns (IBorrowingFees.BorrowingFeePerBlockCap[] memory) {
        IBorrowingFees.BorrowingFeesStorage storage s = _getStorage();
        IBorrowingFees.BorrowingFeePerBlockCap memory defaultFeePerBlockCap = _getStorage().feePerBlockCap;

        uint256 len = _indices.length;
        IBorrowingFees.BorrowingFeePerBlockCap[] memory pairCaps = new IBorrowingFees.BorrowingFeePerBlockCap[](len);

        for (uint256 i; i < len; ++i) {
            IBorrowingFees.BorrowingFeePerBlockCap memory pairFeePerBlockCap = s.pairFeePerBlockCaps[_collateralIndex][
                _indices[i]
            ];
            pairCaps[i] = pairFeePerBlockCap.maxP > 0 ? pairFeePerBlockCap : defaultFeePerBlockCap;
        }

        return pairCaps;
    }

    /**
     * @dev Returns storage slot to use when fetching storage relevant to library
     */
    function _getSlot() internal pure returns (uint256) {
        return StorageUtils.GLOBAL_BORROWING_FEES_SLOT;
    }

    /**
     * @dev Returns storage pointer for storage struct in diamond contract, at defined slot
     */
    function _getStorage() internal pure returns (IBorrowingFees.BorrowingFeesStorage storage s) {
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
     * @dev Reverts if collateral index is not valid
     */
    modifier validCollateralIndex(uint8 _collateralIndex) {
        _validCollateralIndex(_collateralIndex);
        _;
    }

    /**
     * @dev Helper function for `validCollateralIndex` modifier.
     */
    function _validCollateralIndex(uint8 _collateralIndex) private view {
        if (!_getMultiCollatDiamond().isCollateralListed(_collateralIndex)) {
            revert IGeneralErrors.InvalidCollateralIndex();
        }
    }

    /**
     * @dev Resets a trade borrowing fee to 0 (useful when new trade opened or when partial trade executed)
     * @param _collateralIndex index of the collateral
     * @param _trader address of the trader
     * @param _pairIndex index of the pair
     * @param _index index of the trade
     * @param _long true if trade is long, false if trade is short
     * @param _currentPairPrice current pair price (1e10)
     */
    function _resetTradeBorrowingFees(
        uint8 _collateralIndex,
        address _trader,
        uint16 _pairIndex,
        uint32 _index,
        bool _long,
        uint256 _currentPairPrice
    ) internal validCollateralIndex(_collateralIndex) {
        uint256 currentBlock = ChainUtils.getBlockNumber();

        (uint64 pairAccFeeLong, uint64 pairAccFeeShort, , ) = getBorrowingPairPendingAccFees(
            _collateralIndex,
            _pairIndex,
            currentBlock,
            _currentPairPrice
        );
        (uint64 groupAccFeeLong, uint64 groupAccFeeShort, , ) = getBorrowingGroupPendingAccFees(
            _collateralIndex,
            getBorrowingPairGroupIndex(_collateralIndex, _pairIndex),
            currentBlock
        );

        IBorrowingFees.BorrowingInitialAccFees memory initialFees = IBorrowingFees.BorrowingInitialAccFees(
            _long ? pairAccFeeLong : pairAccFeeShort,
            _long ? groupAccFeeLong : groupAccFeeShort,
            ChainUtils.getUint48BlockNumber(currentBlock),
            0 // placeholder
        );

        _getStorage().initialAccFees[_collateralIndex][_trader][_index] = initialFees;

        emit IBorrowingFeesUtils.BorrowingInitialAccFeesStored(
            _collateralIndex,
            _trader,
            _pairIndex,
            _index,
            _long,
            _currentPairPrice,
            initialFees.accPairFee,
            initialFees.accGroupFee
        );
    }

    /**
     * @dev Returns pending acc borrowing fee for a pair on one side only
     * @param _collateralIndex index of the collateral
     * @param _pairIndex index of the pair
     * @param _currentBlock current block number
     * @param _long true if long side
     * @param _currentPairPrice current pair price (1e10)
     * @return accFee new pair acc borrowing fee
     */
    function _getBorrowingPairPendingAccFee(
        uint8 _collateralIndex,
        uint16 _pairIndex,
        uint256 _currentBlock,
        bool _long,
        uint256 _currentPairPrice
    ) internal view returns (uint64 accFee) {
        (uint64 accFeeLong, uint64 accFeeShort, , ) = getBorrowingPairPendingAccFees(
            _collateralIndex,
            _pairIndex,
            _currentBlock,
            _currentPairPrice
        );
        return _long ? accFeeLong : accFeeShort;
    }

    /**
     * @dev Returns pending acc borrowing fee for a borrowing group on one side only
     * @param _collateralIndex index of the collateral
     * @param _groupIndex index of the borrowing group
     * @param _currentBlock current block number
     * @param _long true if long side
     * @return accFee new group acc borrowing fee
     */
    function _getBorrowingGroupPendingAccFee(
        uint8 _collateralIndex,
        uint16 _groupIndex,
        uint256 _currentBlock,
        bool _long
    ) internal view returns (uint64 accFee) {
        (uint64 accFeeLong, uint64 accFeeShort, , ) = getBorrowingGroupPendingAccFees(
            _collateralIndex,
            _groupIndex,
            _currentBlock
        );
        return _long ? accFeeLong : accFeeShort;
    }

    /**
     * @dev Pure function that returns the new acc borrowing fees and delta between two blocks (for pairs and groups)
     * @param _input input data (last acc fees, OIs, fee per block, current block, etc.)
     * @return newAccFeeLong new acc borrowing fee on long side
     * @return newAccFeeShort new acc borrowing fee on short side
     * @return deltaLong delta with current acc borrowing fee on long side
     * @return deltaShort delta with current acc borrowing fee on short side
     */
    function _getBorrowingPendingAccFees(
        IBorrowingFees.PendingBorrowingAccFeesInput memory _input
    ) internal pure returns (uint64 newAccFeeLong, uint64 newAccFeeShort, uint64 deltaLong, uint64 deltaShort) {
        if (_input.currentBlock < _input.accLastUpdatedBlock) {
            revert IGeneralErrors.BlockOrder();
        }

        // If open interest is zero on both sides, return early with current acc fees
        if (_input.oiShort == 0 && _input.oiLong == 0) {
            return (_input.accFeeLong, _input.accFeeShort, 0, 0);
        }

        IBorrowingFees.AccFeesDeltaValues memory accFeesDeltaValues; // Avoids stack too deep
        accFeesDeltaValues.blockDistance = _input.currentBlock - _input.accLastUpdatedBlock;
        accFeesDeltaValues.moreShorts = _input.oiLong < _input.oiShort;
        accFeesDeltaValues.netOi = accFeesDeltaValues.moreShorts
            ? _input.oiShort - _input.oiLong
            : _input.oiLong - _input.oiShort;

        // Scale `_input.maxOi` to collateral precision so it can be used to calculate min/max net OI
        accFeesDeltaValues.maxOiScaled = (_input.maxOi * _input.collateralPrecision) / 1e10;
        // Calculate the min/max net OI needed to calculate the min/max delta caps
        accFeesDeltaValues.minNetOi = (accFeesDeltaValues.maxOiScaled * _input.feePerBlockCap.minP) / 1e3 / 100;
        // If maxP is >0 we can calculate maxP% of maxNetOi, otherwise use 100% of maxOi
        accFeesDeltaValues.maxNetOi = _input.feePerBlockCap.maxP > 0
            ? ((accFeesDeltaValues.maxOiScaled * _input.feePerBlockCap.maxP) / 1e3 / 100)
            : accFeesDeltaValues.maxOiScaled;

        // Cap net OI at max OI * feePerBlockCap.maxP so fee is never >`maxP`% of feePerBlock
        // In the event that maxNetOi == 0 (because `_input.maxOi` is 0), the output of this call will always be zero
        accFeesDeltaValues.cappedNetOi = accFeesDeltaValues.netOi > accFeesDeltaValues.maxNetOi
            ? accFeesDeltaValues.maxNetOi
            : accFeesDeltaValues.netOi;

        // Calculate the `minDelta`
        // Note: If `minNetOi` is 0, due to `maxOi` or `feePerBlock.minP` being 0, skip calculations and set `minDelta` to 0
        uint64 minDelta = accFeesDeltaValues.minNetOi > 0
            ? _getBorrowingPendingAccFeesDelta(
                accFeesDeltaValues.blockDistance,
                _input.feePerBlock,
                accFeesDeltaValues.minNetOi,
                _input.maxOi,
                _input.feeExponent,
                _input.collateralPrecision
            )
            : 0;

        // Calculate actual delta
        // Note: If netOi <= minNetOi, avoid unnecessary calculations and use `minDelta` as delta
        uint64 delta = accFeesDeltaValues.netOi > accFeesDeltaValues.minNetOi
            ? _getBorrowingPendingAccFeesDelta(
                accFeesDeltaValues.blockDistance,
                _input.feePerBlock,
                accFeesDeltaValues.cappedNetOi,
                _input.maxOi,
                _input.feeExponent,
                _input.collateralPrecision
            )
            : minDelta;

        // Always add minDelta to the "inactive" side. "Active" side's delta is max(minDelta, delta).
        (deltaLong, deltaShort) = accFeesDeltaValues.moreShorts ? (minDelta, delta) : (delta, minDelta);

        // If `oiLong` or `oiShort` is 0, set the respective delta to 0 so we're not incrementing acc value unnecessarily
        if (_input.oiLong == 0) deltaLong = 0;
        if (_input.oiShort == 0) deltaShort = 0;

        newAccFeeLong = _input.accFeeLong + deltaLong;
        newAccFeeShort = _input.accFeeShort + deltaShort;
    }

    /**
     * @dev Pure function that returns the delta of pending acc borrowing fees (1e10 %)
     * @param _blockDistance block distance (current block - last updated block)
     * @param _feePerBlock fee per block (1e10 %)
     * @param _netOi net open interest (collateral precision)
     * @param _maxOi max open interest (1e10)
     * @param _feeExponent fee exponent
     * @param _collateralPrecision collateral precision (10^decimals)
     */
    function _getBorrowingPendingAccFeesDelta(
        uint256 _blockDistance,
        uint32 _feePerBlock,
        uint256 _netOi,
        uint72 _maxOi,
        uint48 _feeExponent,
        uint128 _collateralPrecision
    ) internal pure returns (uint64) {
        uint256 _delta = _maxOi > 0 && _feeExponent > 0
            ? (_blockDistance * _feePerBlock * ((_netOi * 1e10) / _maxOi) ** _feeExponent) /
                (uint256(_collateralPrecision) ** _feeExponent)
            : 0; // 1e10 (%)

        if (_delta > type(uint64).max) {
            revert IGeneralErrors.Overflow();
        }

        return uint64(_delta);
    }

    /**
     * @dev Pure function that returns the liquidation price for a trade (1e10 precision)
     * @param _openPrice trade open price (1e10 precision)
     * @param _long true if long, false if short
     * @param _collateral trade collateral (collateral precision)
     * @param _leverage trade leverage (1e3 precision)
     * @param _feesCollateral closing fees + borrowing fees amount (collateral precision)
     * @param _collateralPrecisionDelta collateral precision delta (10^18/10^decimals)
     * @param _liquidationParams liquidation parameters for the trade
     * @param _contractsVersion contracts version of the trade
     * @param _pairSpreadP pair spread percentage (1e10)
     */
    function _getTradeLiquidationPrice(
        uint256 _openPrice,
        bool _long,
        uint256 _collateral,
        uint256 _leverage,
        int256 _feesCollateral,
        uint256 _collateralPrecisionDelta,
        IPairsStorage.GroupLiquidationParams memory _liquidationParams,
        ITradingStorage.ContractsVersion _contractsVersion,
        uint256 _pairSpreadP
    ) internal pure returns (uint256) {
        uint256 liqPnlThresholdP = TradingCommonUtils.getLiqPnlThresholdP(_liquidationParams, _leverage);
        int256 openPriceInt = int256(_openPrice);

        int256 collateralLiqNegativePnlInt = int256(
            (_collateral * liqPnlThresholdP * _collateralPrecisionDelta * 1e3) / 100 / ConstantsUtils.P_10
        ); // 1e18 * 1e3
        int256 feesInt = _feesCollateral * int256(_collateralPrecisionDelta * 1e3); // 1e18 * 1e3

        // 1e10
        int256 liqPriceDistance = (openPriceInt * (collateralLiqNegativePnlInt - feesInt)) / // 1e10 * 1e18 * 1e3
            int256(_collateral) /
            int256(_leverage) /
            int256(_collateralPrecisionDelta); // 1e10

        // Apply closing spread to liquidation price only for trades opened from v9.2
        if (_contractsVersion >= ITradingStorage.ContractsVersion.V9_2) {
            uint256 closingSpreadP = _pairSpreadP / 2;
            closingSpreadP = closingSpreadP > _liquidationParams.maxLiqSpreadP
                ? _liquidationParams.maxLiqSpreadP
                : closingSpreadP;
            liqPriceDistance -= (openPriceInt * int256(closingSpreadP)) / int256(ConstantsUtils.P_10) / 100;
        }

        int256 liqPrice = _long ? openPriceInt - liqPriceDistance : openPriceInt + liqPriceDistance; // 1e10

        return liqPrice > 0 ? uint256(liqPrice) : 0; // 1e10
    }

    /**
     * @dev Function to set borrowing pair params
     * @param _collateralIndex index of the collateral
     * @param _pairIndex index of the pair
     * @param _value new pair params
     * @param _currentPairPrice current pair price (1e10)
     */
    function _setBorrowingPairParams(
        uint8 _collateralIndex,
        uint16 _pairIndex,
        IBorrowingFees.BorrowingPairParams memory _value,
        uint256 _currentPairPrice
    ) internal {
        IBorrowingFees.BorrowingFeesStorage storage s = _getStorage();
        IBorrowingFees.BorrowingData storage p = s.pairs[_collateralIndex][_pairIndex];

        uint16 prevGroupIndex = getBorrowingPairGroupIndex(_collateralIndex, _pairIndex);
        uint256 currentBlock = ChainUtils.getBlockNumber();

        _setPairPendingAccFees(_collateralIndex, _pairIndex, currentBlock, _currentPairPrice);

        if (_value.groupIndex != prevGroupIndex) {
            _setGroupPendingAccFees(_collateralIndex, prevGroupIndex, currentBlock);
            _setGroupPendingAccFees(_collateralIndex, _value.groupIndex, currentBlock);

            (uint256 oiLong, uint256 oiShort) = TradingCommonUtils.getPairTotalOisCollateral(
                _collateralIndex,
                _pairIndex
            );

            // Only remove OI from old group if old group is not 0
            _updateGroupOi(_collateralIndex, prevGroupIndex, true, false, oiLong);
            _updateGroupOi(_collateralIndex, prevGroupIndex, false, false, oiShort);

            // Add OI to new group if it's not group 0 (even if old group is 0)
            // So when we assign a pair to a group, it takes into account its OI
            // And group 0 OI will always be 0 but it doesn't matter since it's not used
            _updateGroupOi(_collateralIndex, _value.groupIndex, true, true, oiLong);
            _updateGroupOi(_collateralIndex, _value.groupIndex, false, true, oiShort);

            IBorrowingFees.BorrowingData memory newGroup = s.groups[_collateralIndex][_value.groupIndex];
            IBorrowingFees.BorrowingData memory prevGroup = s.groups[_collateralIndex][prevGroupIndex];

            s.pairGroups[_collateralIndex][_pairIndex].push(
                IBorrowingFees.BorrowingPairGroup(
                    _value.groupIndex,
                    ChainUtils.getUint48BlockNumber(currentBlock),
                    newGroup.accFeeLong,
                    newGroup.accFeeShort,
                    prevGroup.accFeeLong,
                    prevGroup.accFeeShort,
                    p.accFeeLong,
                    p.accFeeShort,
                    0 // placeholder
                )
            );

            emit IBorrowingFeesUtils.BorrowingPairGroupUpdated(
                _collateralIndex,
                _pairIndex,
                prevGroupIndex,
                _value.groupIndex
            );
        }

        p.feePerBlock = _value.feePerBlock;
        p.feeExponent = _value.feeExponent;
        s.pairOisBeforeV10[_collateralIndex][_pairIndex].max = _value.maxOi;

        emit IBorrowingFeesUtils.BorrowingPairParamsUpdated(
            _collateralIndex,
            _pairIndex,
            _value.groupIndex,
            _value.feePerBlock,
            _value.feeExponent,
            _value.maxOi
        );
    }

    /**
     * @dev Function to set borrowing group params
     * @param _collateralIndex index of the collateral
     * @param _groupIndex index of the borrowing group
     * @param _value new group params
     */
    function _setBorrowingGroupParams(
        uint8 _collateralIndex,
        uint16 _groupIndex,
        IBorrowingFees.BorrowingGroupParams calldata _value
    ) internal {
        if (_groupIndex == 0) {
            revert IBorrowingFeesUtils.BorrowingZeroGroup();
        }
        if (_value.feeExponent < 1 || _value.feeExponent > 3) {
            revert IBorrowingFeesUtils.BorrowingWrongExponent();
        }

        _setGroupPendingAccFees(_collateralIndex, _groupIndex, ChainUtils.getBlockNumber());

        IBorrowingFees.BorrowingFeesStorage storage s = _getStorage();
        IBorrowingFees.BorrowingData storage group = s.groups[_collateralIndex][_groupIndex];

        group.feePerBlock = _value.feePerBlock;
        group.feeExponent = _value.feeExponent;
        s.groupOis[_collateralIndex][_groupIndex].max = _value.maxOi;

        emit IBorrowingFeesUtils.BorrowingGroupUpdated(
            _collateralIndex,
            _groupIndex,
            _value.feePerBlock,
            _value.maxOi,
            _value.feeExponent
        );
    }

    /**
     * @dev Function to update a borrowing pair/group open interest
     * @param _oiStorage open interest storage reference
     * @param _long true if long, false if short
     * @param _increase true if increase, false if decrease
     * @param _amountCollateral amount of collateral to increase/decrease (collateral precision)
     * @param _collateralPrecision collateral precision (10^decimals)
     * @return newOiLong new long open interest (1e10)
     * @return newOiShort new short open interest (1e10)
     * @return delta difference between new and current open interest (1e10)
     */
    function _updateOi(
        IBorrowingFees.OpenInterest storage _oiStorage,
        bool _long,
        bool _increase,
        uint256 _amountCollateral,
        uint128 _collateralPrecision
    ) internal returns (uint72 newOiLong, uint72 newOiShort, uint72 delta) {
        _amountCollateral = (_amountCollateral * ConstantsUtils.P_10) / _collateralPrecision; // 1e10

        if (_amountCollateral > type(uint72).max) {
            revert IGeneralErrors.Overflow();
        }

        delta = uint72(_amountCollateral);

        IBorrowingFees.OpenInterest memory oi = _oiStorage;

        // prettier-ignore
        if (_long) {
            oi.long = _increase ? oi.long + delta : delta > oi.long ? 0 : oi.long - delta;
            _oiStorage.long = oi.long;
        } else {
            oi.short = _increase ? oi.short + delta : delta > oi.short ? 0 : oi.short - delta;
            _oiStorage.short = oi.short;
        }

        return (oi.long, oi.short, delta);
    }

    /**
     * @dev Function to update a borrowing group's open interest
     * @param _collateralIndex index of the collateral
     * @param _groupIndex index of the borrowing group
     * @param _long true if long, false if short
     * @param _increase true if increase, false if decrease
     * @param _amountCollateral amount of collateral to increase/decrease (collateral precision)
     */
    function _updateGroupOi(
        uint8 _collateralIndex,
        uint16 _groupIndex,
        bool _long,
        bool _increase,
        uint256 _amountCollateral
    ) internal {
        if (_groupIndex > 0) {
            (uint72 newOiLong, uint72 newOiShort, uint72 delta) = _updateOi(
                _getStorage().groupOis[_collateralIndex][_groupIndex],
                _long,
                _increase,
                _amountCollateral,
                _getMultiCollatDiamond().getCollateral(_collateralIndex).precision
            );

            emit IBorrowingFeesUtils.BorrowingGroupOiUpdated(
                _collateralIndex,
                _groupIndex,
                _long,
                _increase,
                delta,
                newOiLong,
                newOiShort
            );
        }
    }

    /**
     * @dev Calculates the borrowing group and pair acc fees deltas for a trade between pair group at index _i and next one
     * @param _collateralIndex index of the collateral
     * @param _i index of the borrowing pair group
     * @param _pairGroups all pair's historical borrowing groups
     * @param _initialFees trade initial borrowing fees
     * @param _pairIndex index of the pair
     * @param _long true if long, false if short
     * @param _currentBlock current block number
     * @param _currentPairPrice current pair price (1e10)
     * @return deltaGroup difference between new and current group acc borrowing fee
     * @return deltaPair difference between new and current pair acc borrowing fee
     * @return beforeTradeOpen true if pair group was set before trade was opened
     */
    function _getBorrowingPairGroupAccFeesDeltas(
        uint8 _collateralIndex,
        uint256 _i,
        IBorrowingFees.BorrowingPairGroup[] memory _pairGroups,
        IBorrowingFees.BorrowingInitialAccFees memory _initialFees,
        uint16 _pairIndex,
        bool _long,
        uint256 _currentBlock,
        uint256 _currentPairPrice
    ) internal view returns (uint64 deltaGroup, uint64 deltaPair, bool beforeTradeOpen) {
        IBorrowingFees.BorrowingPairGroup memory group = _pairGroups[_i];

        beforeTradeOpen = group.block < _initialFees.block;

        if (_i == _pairGroups.length - 1) {
            // Last active group
            deltaGroup = _getBorrowingGroupPendingAccFee(_collateralIndex, group.groupIndex, _currentBlock, _long);
            deltaPair = _getBorrowingPairPendingAccFee(
                _collateralIndex,
                _pairIndex,
                _currentBlock,
                _long,
                _currentPairPrice
            );
        } else {
            // Previous groups
            IBorrowingFees.BorrowingPairGroup memory nextGroup = _pairGroups[_i + 1];

            // If it's not the first group to be before the trade was opened then fee is 0
            if (beforeTradeOpen && nextGroup.block <= _initialFees.block) {
                return (0, 0, beforeTradeOpen);
            }

            deltaGroup = _long ? nextGroup.prevGroupAccFeeLong : nextGroup.prevGroupAccFeeShort;
            deltaPair = _long ? nextGroup.pairAccFeeLong : nextGroup.pairAccFeeShort;
        }

        if (beforeTradeOpen) {
            deltaGroup -= _initialFees.accGroupFee;
            deltaPair -= _initialFees.accPairFee;
        } else {
            deltaGroup -= (_long ? group.initialAccFeeLong : group.initialAccFeeShort);
            deltaPair -= (_long ? group.pairAccFeeLong : group.pairAccFeeShort);
        }
    }

    /**
     *
     * @param _collateralIndex index of the collateral
     * @param _pairIndex index of the pair
     * @param _currentBlock current block number
     * @param _currentPairPrice current pair price (1e10)
     * @return accFeeLong new pair acc borrowing fee on long side (1e10 precision)
     * @return accFeeShort new pair acc borrowing fee on short side (1e10 precision)
     */
    function _setPairPendingAccFees(
        uint8 _collateralIndex,
        uint16 _pairIndex,
        uint256 _currentBlock,
        uint256 _currentPairPrice
    ) internal returns (uint64 accFeeLong, uint64 accFeeShort) {
        (accFeeLong, accFeeShort, , ) = getBorrowingPairPendingAccFees(
            _collateralIndex,
            _pairIndex,
            _currentBlock,
            _currentPairPrice
        );

        IBorrowingFees.BorrowingData storage pair = _getStorage().pairs[_collateralIndex][_pairIndex];

        (pair.accFeeLong, pair.accFeeShort) = (accFeeLong, accFeeShort);
        pair.accLastUpdatedBlock = ChainUtils.getUint48BlockNumber(_currentBlock);

        emit IBorrowingFeesUtils.BorrowingPairAccFeesUpdated(
            _collateralIndex,
            _pairIndex,
            _currentBlock,
            _currentPairPrice,
            pair.accFeeLong,
            pair.accFeeShort
        );
    }

    /**
     *
     * @param _collateralIndex index of the collateral
     * @param _groupIndex index of the borrowing group
     * @param _currentBlock current block number
     * @return accFeeLong new group acc borrowing fee on long side (1e10 precision)
     * @return accFeeShort new group acc borrowing fee on short side (1e10 precision)
     */
    function _setGroupPendingAccFees(
        uint8 _collateralIndex,
        uint16 _groupIndex,
        uint256 _currentBlock
    ) internal returns (uint64 accFeeLong, uint64 accFeeShort) {
        (accFeeLong, accFeeShort, , ) = getBorrowingGroupPendingAccFees(_collateralIndex, _groupIndex, _currentBlock);

        IBorrowingFees.BorrowingData storage group = _getStorage().groups[_collateralIndex][_groupIndex];

        (group.accFeeLong, group.accFeeShort) = (accFeeLong, accFeeShort);
        group.accLastUpdatedBlock = ChainUtils.getUint48BlockNumber(_currentBlock);

        emit IBorrowingFeesUtils.BorrowingGroupAccFeesUpdated(
            _collateralIndex,
            _groupIndex,
            _currentBlock,
            group.accFeeLong,
            group.accFeeShort
        );
    }

    /**
     * @dev Ensures new proposed borrowing fee per block cap fits within the allowed ranges
     * @param _value new borrowing fee per block cap
     */
    function _validateBorrowingFeePerBlockCap(IBorrowingFees.BorrowingFeePerBlockCap memory _value) internal pure {
        if (_value.minP > _value.maxP) {
            revert IGeneralErrors.WrongOrder();
        }

        if (_value.maxP > MAX_FEE_PER_BLOCK_CAP_P) {
            revert IGeneralErrors.AboveMax();
        }
    }

    /**
     * @dev Returns the borrowing pair params bit lengths array
     */
    function _getBorrowingPairParamsBitLengths() internal pure returns (uint256[] memory) {
        uint256[] memory bitLengths = new uint256[](4);
        bitLengths[0] = 16; // groupIndex
        bitLengths[1] = 32; // feePerBlock
        bitLengths[2] = 48; // feeExponent
        bitLengths[3] = 72; // maxOi

        return bitLengths;
    }

    /**
     * @dev Validates, temporarily stores, and cleans up signed market pair prices.
     */
    modifier useSignedMarketPrices(IPriceAggregator.SignedPairPrices[] calldata _signedPairPrices) {
        bool isLookback = false;
        _getMultiCollatDiamond().validateSignedPairPrices(_signedPairPrices, isLookback);
        _;
        _getMultiCollatDiamond().cleanUpSignedPairPrices();
    }

    /**
     * @dev Check IBorrowingFeesUtils.setBorrowingPairParams interface for documentation
     */
    function _setBorrowingPairParamsWithSignedPrices(
        uint8 _collateralIndex,
        uint16 _pairIndex,
        IBorrowingFees.BorrowingPairParams calldata _value
    ) internal {
        if (_value.feeExponent < 1 || _value.feeExponent > 3) revert IBorrowingFeesUtils.BorrowingWrongExponent();

        uint256[] memory values = new uint256[](4);
        values[0] = _value.groupIndex;
        values[1] = _value.feePerBlock;
        values[2] = _value.feeExponent;
        values[3] = _value.maxOi;

        uint256 newEncodedValue = PackingUtils.pack(values, _getBorrowingPairParamsBitLengths());

        // Callback expects prices to be stored
        _getMultiCollatDiamond().paramUpdateCallbackWithSignedPrices(
            IFundingFees.PendingParamUpdate(
                _collateralIndex,
                _pairIndex,
                IFundingFees.ParamUpdateType.BORROWING_PAIR,
                uint224(newEncodedValue)
            )
        );
    }
}
