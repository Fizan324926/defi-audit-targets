// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../interfaces/IGNSMultiCollatDiamond.sol";

import "./StorageUtils.sol";
import "./ConstantsUtils.sol";

/**
 * @dev GNSPairsStorage facet internal library
 */
library PairsStorageUtils {
    uint256 private constant MIN_LEVERAGE = 1.1e3; // 1.1x (1e3 precision)
    uint256 private constant MAX_LEVERAGE = 1000e3; // 1000x (1e3 precision)
    uint256 private constant MIN_COUNTER_TRADE_FEE_RATE_MULTIPLIER = 0.2e3; // 80% discount

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function initializeGroupLiquidationParams(
        IPairsStorage.GroupLiquidationParams[] memory _groupLiquidationParams
    ) internal {
        IPairsStorage.PairsStorage storage s = _getStorage();
        if (_groupLiquidationParams.length != s.groupsCount) revert IGeneralErrors.WrongLength();

        for (uint256 i = 0; i < _groupLiquidationParams.length; ++i) {
            setGroupLiquidationParams(i, _groupLiquidationParams[i]);
        }
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function initializeNewFees(IPairsStorage.GlobalTradeFeeParams memory _tradeFeeParams) internal {
        setGlobalTradeFeeParams(_tradeFeeParams);
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function initializeReferralFeeChange() internal {
        IPairsStorage.GlobalTradeFeeParams memory globalFeeParams = _getStorage().globalTradeFeeParams;

        uint24 increment = globalFeeParams.referralFeeP / 2;
        globalFeeParams.govFeeP += increment;
        globalFeeParams.gnsOtcFeeP += increment;

        _validateGlobalTradeFeeParams(globalFeeParams);

        _getStorage().globalTradeFeeParams = globalFeeParams;

        emit IPairsStorageUtils.GlobalTradeFeeParamsUpdated(globalFeeParams);
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function addPairs(IPairsStorage.Pair[] calldata _pairs) internal {
        for (uint256 i = 0; i < _pairs.length; ++i) {
            _addPair(_pairs[i]);
        }
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function updatePairs(uint256[] calldata _pairIndices, IPairsStorage.Pair[] calldata _pairs) internal {
        if (_pairIndices.length != _pairs.length) revert IGeneralErrors.WrongLength();

        for (uint256 i = 0; i < _pairs.length; ++i) {
            _updatePair(_pairIndices[i], _pairs[i]);
        }
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function addGroups(IPairsStorage.Group[] calldata _groups) internal {
        for (uint256 i = 0; i < _groups.length; ++i) {
            _addGroup(_groups[i]);
        }
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function updateGroups(uint256[] calldata _ids, IPairsStorage.Group[] calldata _groups) internal {
        if (_ids.length != _groups.length) revert IGeneralErrors.WrongLength();

        for (uint256 i = 0; i < _groups.length; ++i) {
            _updateGroup(_ids[i], _groups[i]);
        }
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function addFees(IPairsStorage.FeeGroup[] memory _fees) internal {
        for (uint256 i = 0; i < _fees.length; ++i) {
            _addFee(_fees[i]);
        }
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function updateFees(uint256[] calldata _ids, IPairsStorage.FeeGroup[] memory _fees) internal {
        if (_ids.length != _fees.length) revert IGeneralErrors.WrongLength();

        for (uint256 i = 0; i < _fees.length; ++i) {
            _updateFee(_ids[i], _fees[i]);
        }
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function setPairCustomMaxLeverages(uint256[] calldata _indices, uint256[] calldata _values) internal {
        if (_indices.length != _values.length) revert IGeneralErrors.WrongLength();

        IPairsStorage.PairsStorage storage s = _getStorage();

        for (uint256 i; i < _indices.length; ++i) {
            s.pairCustomMaxLeverage[_indices[i]] = _values[i];

            emit IPairsStorageUtils.PairCustomMaxLeverageUpdated(_indices[i], _values[i]);
        }
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function setGroupLiquidationParams(
        uint256 _groupIndex,
        IPairsStorage.GroupLiquidationParams memory _params
    ) internal groupListed(_groupIndex) {
        IPairsStorage.PairsStorage storage s = _getStorage();

        if (
            _params.maxLiqSpreadP == 0 ||
            _params.startLiqThresholdP == 0 ||
            _params.endLiqThresholdP == 0 ||
            _params.startLeverage == 0 ||
            _params.endLeverage == 0
        ) revert IGeneralErrors.ZeroValue();

        if (_params.maxLiqSpreadP > ConstantsUtils.MAX_LIQ_SPREAD_P) revert IPairsStorageUtils.MaxLiqSpreadPTooHigh();

        if (_params.startLiqThresholdP < _params.endLiqThresholdP) revert IPairsStorageUtils.WrongLiqParamsThresholds();
        if (_params.startLiqThresholdP > ConstantsUtils.LEGACY_LIQ_THRESHOLD_P)
            revert IPairsStorageUtils.StartLiqThresholdTooHigh();
        if (_params.endLiqThresholdP < ConstantsUtils.MIN_LIQ_THRESHOLD_P)
            revert IPairsStorageUtils.EndLiqThresholdTooLow();

        if (_params.startLeverage > _params.endLeverage) revert IPairsStorageUtils.WrongLiqParamsLeverages();
        if (_params.startLeverage < groups(_groupIndex).minLeverage) revert IPairsStorageUtils.StartLeverageTooLow();
        if (_params.endLeverage > groups(_groupIndex).maxLeverage) revert IPairsStorageUtils.EndLeverageTooHigh();

        s.groupLiquidationParams[_groupIndex] = _params;

        emit IPairsStorageUtils.GroupLiquidationParamsUpdated(_groupIndex, _params);
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function setGlobalTradeFeeParams(IPairsStorage.GlobalTradeFeeParams memory _feeParams) internal {
        _validateGlobalTradeFeeParams(_feeParams);

        _getStorage().globalTradeFeeParams = _feeParams;

        emit IPairsStorageUtils.GlobalTradeFeeParamsUpdated(_feeParams);
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function setPairCounterTradeMaxLeverages(uint16[] calldata _indices, uint24[] calldata _values) internal {
        if (_indices.length != _values.length) revert IGeneralErrors.WrongLength();

        IPairsStorage.PairsStorage storage s = _getStorage();

        for (uint256 i; i < _indices.length; ++i) {
            s.pairCounterTradeSettings[_indices[i]].maxLeverage = _values[i];

            emit IPairsStorageUtils.CounterTradeMaxLeverageUpdated(_indices[i], _values[i]);
        }
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function setPairCounterTradeFeeRateMultipliers(uint16[] calldata _indices, uint16[] calldata _values) internal {
        if (_indices.length != _values.length) revert IGeneralErrors.WrongLength();

        IPairsStorage.PairsStorage storage s = _getStorage();

        for (uint256 i; i < _indices.length; ++i) {
            if (_values[i] > 1e3) revert IGeneralErrors.AboveMax();
            if (_values[i] < MIN_COUNTER_TRADE_FEE_RATE_MULTIPLIER) revert IGeneralErrors.BelowMin();

            s.pairCounterTradeSettings[_indices[i]].feeRateMultiplier = _values[i];

            emit IPairsStorageUtils.CounterTradeFeeRateMultiplierUpdated(_indices[i], _values[i]);
        }
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function setPairGlobalTradeFeeParamsOverrides(
        uint8[] calldata _collateralIndices,
        uint16[] calldata _pairIndices,
        IPairsStorage.GlobalTradeFeeParams[] calldata _feeParams
    ) internal {
        if (_collateralIndices.length != _pairIndices.length || _collateralIndices.length != _feeParams.length)
            revert IGeneralErrors.WrongLength();

        IPairsStorage.PairsStorage storage s = _getStorage();

        for (uint256 i; i < _pairIndices.length; ++i) {
            uint8 collateralIndex = _collateralIndices[i];
            uint16 pairIndex = _pairIndices[i];
            IPairsStorage.GlobalTradeFeeParams memory pairFeeParams = _feeParams[i];

            // Override placeholder to 0
            pairFeeParams.__placeholder = 0;

            // Validate pairFeeParams if at least one value is > 0, otherwise it's considered as unsetting the override
            if (
                pairFeeParams.referralFeeP > 0 ||
                pairFeeParams.govFeeP > 0 ||
                pairFeeParams.triggerOrderFeeP > 0 ||
                pairFeeParams.gnsOtcFeeP > 0 ||
                pairFeeParams.gTokenFeeP > 0 ||
                pairFeeParams.gTokenOcFeeP > 0
            ) _validateGlobalTradeFeeParams(pairFeeParams);

            s.pairTradeFeeParamOverrides[collateralIndex][pairIndex] = pairFeeParams;

            emit IPairsStorageUtils.PairGlobalTradeFeeParamsOverridesUpdated(collateralIndex, pairIndex, pairFeeParams);
        }
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function setPairFlags(
        uint8[] calldata _collateralIndices,
        uint16[] calldata _pairIndices,
        IPairsStorage.PairFlags[] calldata _pairFlags
    ) internal {
        if (_collateralIndices.length != _pairIndices.length || _collateralIndices.length != _pairFlags.length)
            revert IGeneralErrors.WrongLength();

        IPairsStorage.PairsStorage storage s = _getStorage();

        for (uint256 i; i < _pairIndices.length; ++i) {
            uint8 collateralIndex = _collateralIndices[i];
            uint16 pairIndex = _pairIndices[i];
            IPairsStorage.PairFlags memory pairFlags = _pairFlags[i];

            if (pairFlags.__placeholder != 0) revert IGeneralErrors.ZeroValue();

            s.pairFlags[collateralIndex][pairIndex] = pairFlags;

            emit IPairsStorageUtils.PairFlagsUpdated(collateralIndex, pairIndex, pairFlags);
        }
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function pairJob(uint256 _pairIndex) internal view returns (string memory, string memory) {
        IPairsStorage.PairsStorage storage s = _getStorage();

        IPairsStorage.Pair storage p = s.pairs[_pairIndex];
        if (!s.isPairListed[p.from][p.to]) revert IPairsStorageUtils.PairNotListed();

        return (p.from, p.to);
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function isPairListed(string calldata _from, string calldata _to) internal view returns (bool) {
        return _getStorage().isPairListed[_from][_to];
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function isPairIndexListed(uint256 _pairIndex) internal view returns (bool) {
        return _pairIndex < _getStorage().pairsCount;
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function pairs(uint256 _index) internal view returns (IPairsStorage.Pair storage) {
        return _getStorage().pairs[_index];
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function pairsCount() internal view returns (uint256) {
        return _getStorage().pairsCount;
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function pairSpreadP(address _trader, uint256 _pairIndex) internal view returns (uint256) {
        return
            uint256(_getMultiCollatDiamond().getUserPriceImpact(_trader, _pairIndex).fixedSpreadP) *
            1e7 +
            pairs(_pairIndex).spreadP;
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function pairSpreadPArray(
        address[] calldata _trader,
        uint256[] calldata _pairIndex
    ) internal view returns (uint256[] memory) {
        uint256[] memory spreadP = new uint256[](_pairIndex.length);

        for (uint256 i; i < spreadP.length; ++i) {
            spreadP[i] = pairSpreadP(_trader[i], _pairIndex[i]);
        }

        return spreadP;
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function pairMinLeverage(uint256 _pairIndex) internal view returns (uint256) {
        return groups(pairs(_pairIndex).groupIndex).minLeverage;
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function pairTotalPositionSizeFeeP(uint256 _pairIndex) internal view returns (uint256) {
        return fees(pairs(_pairIndex).feeIndex).totalPositionSizeFeeP;
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function pairTotalLiqCollateralFeeP(uint256 _pairIndex) internal view returns (uint256) {
        return fees(pairs(_pairIndex).feeIndex).totalLiqCollateralFeeP;
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function pairOraclePositionSizeFeeP(uint256 _pairIndex) internal view returns (uint256) {
        return fees(pairs(_pairIndex).feeIndex).oraclePositionSizeFeeP;
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function pairMinPositionSizeUsd(uint256 _pairIndex) internal view returns (uint256) {
        return (uint256(fees(pairs(_pairIndex).feeIndex).minPositionSizeUsd) * 1e18) / 1e3;
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function getGlobalTradeFeeParams() internal view returns (IPairsStorage.GlobalTradeFeeParams memory) {
        return _getStorage().globalTradeFeeParams;
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function pairMinFeeUsd(uint256 _pairIndex) internal view returns (uint256) {
        return (pairMinPositionSizeUsd(_pairIndex) * pairTotalPositionSizeFeeP(_pairIndex)) / ConstantsUtils.P_10 / 100;
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function pairFeeIndex(uint256 _pairIndex) internal view returns (uint256) {
        return _getStorage().pairs[_pairIndex].feeIndex;
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function groups(uint256 _index) internal view returns (IPairsStorage.Group storage) {
        return _getStorage().groups[_index];
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function groupsCount() internal view returns (uint256) {
        return _getStorage().groupsCount;
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function fees(uint256 _index) internal view returns (IPairsStorage.FeeGroup memory) {
        return _getStorage().feeGroups[_index];
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function feesCount() internal view returns (uint256) {
        return _getStorage().feesCount;
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function pairMaxLeverage(uint256 _pairIndex) internal view returns (uint256) {
        IPairsStorage.PairsStorage storage s = _getStorage();

        uint256 maxLeverage = s.pairCustomMaxLeverage[_pairIndex];
        return maxLeverage > 0 ? maxLeverage : s.groups[s.pairs[_pairIndex].groupIndex].maxLeverage;
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function pairCustomMaxLeverage(uint256 _pairIndex) internal view returns (uint256) {
        return _getStorage().pairCustomMaxLeverage[_pairIndex];
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function getAllPairsRestrictedMaxLeverage() internal view returns (uint256[] memory) {
        uint256[] memory lev = new uint256[](pairsCount());

        for (uint256 i; i < lev.length; ++i) {
            lev[i] = pairCustomMaxLeverage(i);
        }

        return lev;
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function getGroupLiquidationParams(
        uint256 _groupIndex
    ) internal view returns (IPairsStorage.GroupLiquidationParams memory) {
        return _getStorage().groupLiquidationParams[_groupIndex];
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function getPairLiquidationParams(
        uint256 _pairIndex
    ) internal view returns (IPairsStorage.GroupLiquidationParams memory) {
        return _getStorage().groupLiquidationParams[pairs(_pairIndex).groupIndex];
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function getPairCounterTradeMaxLeverage(uint16 _pairIndex) internal view returns (uint24) {
        return _getStorage().pairCounterTradeSettings[_pairIndex].maxLeverage;
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function getPairCounterTradeMaxLeverages(uint16[] calldata _pairIndex) internal view returns (uint24[] memory) {
        uint24[] memory levThresholds = new uint24[](_pairIndex.length);

        for (uint256 i; i < _pairIndex.length; ++i) {
            levThresholds[i] = getPairCounterTradeMaxLeverage(_pairIndex[i]);
        }

        return levThresholds;
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function getPairCounterTradeFeeRateMultiplier(uint16 _pairIndex) internal view returns (uint16) {
        uint16 feeRateMultiplier = _getStorage().pairCounterTradeSettings[_pairIndex].feeRateMultiplier;
        return feeRateMultiplier > 0 ? feeRateMultiplier : 1e3;
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function getPairCounterTradeFeeRateMultipliers(
        uint16[] calldata _pairIndex
    ) internal view returns (uint16[] memory) {
        uint16[] memory feeRateMultipliers = new uint16[](_pairIndex.length);

        for (uint256 i; i < _pairIndex.length; ++i) {
            feeRateMultipliers[i] = getPairCounterTradeFeeRateMultiplier(_pairIndex[i]);
        }

        return feeRateMultipliers;
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function getEffectiveTotalPositionSizeFeeP(
        uint16 _pairIndex,
        bool _isCounterTrade
    ) internal view returns (uint256) {
        uint256 feeP = uint256(pairTotalPositionSizeFeeP(_pairIndex));

        return _isCounterTrade ? (feeP * getPairCounterTradeFeeRateMultiplier(_pairIndex)) / 1e3 : feeP;
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function getPairGlobalTradeFeeParamsOverride(
        uint8 _collateralIndex,
        uint16 _pairIndex
    ) internal view returns (IPairsStorage.GlobalTradeFeeParams memory) {
        return _getStorage().pairTradeFeeParamOverrides[_collateralIndex][_pairIndex];
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function getPairGlobalTradeFeeParamsOverrideArray(
        uint8 _collateralIndex,
        uint16[] calldata _pairIndices
    ) internal view returns (IPairsStorage.GlobalTradeFeeParams[] memory) {
        IPairsStorage.PairsStorage storage s = _getStorage();
        IPairsStorage.GlobalTradeFeeParams[] memory feeParamsOverrides = new IPairsStorage.GlobalTradeFeeParams[](
            _pairIndices.length
        );

        for (uint256 i; i < _pairIndices.length; ++i) {
            feeParamsOverrides[i] = s.pairTradeFeeParamOverrides[_collateralIndex][_pairIndices[i]];
        }

        return feeParamsOverrides;
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function getPairFlags(
        uint8 _collateralIndex,
        uint16 _pairIndex
    ) internal view returns (IPairsStorage.PairFlags memory) {
        return _getStorage().pairFlags[_collateralIndex][_pairIndex];
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function getPairFlagsArray(
        uint8 _collateralIndex,
        uint16[] calldata _pairIndices
    ) internal view returns (IPairsStorage.PairFlags[] memory) {
        IPairsStorage.PairFlags[] memory pairFlags = new IPairsStorage.PairFlags[](_pairIndices.length);

        for (uint256 i; i < _pairIndices.length; ++i) {
            pairFlags[i] = getPairFlags(_collateralIndex, _pairIndices[i]);
        }

        return pairFlags;
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function getTradeFeeParams(
        uint8 _collateralIndex,
        uint16 _pairIndex
    ) internal view returns (IPairsStorage.GlobalTradeFeeParams memory) {
        IPairsStorage.PairsStorage storage s = _getStorage();
        IPairsStorage.GlobalTradeFeeParams memory pairTradeFeeOverrides = s.pairTradeFeeParamOverrides[
            _collateralIndex
        ][_pairIndex];

        // If at least one feeP value is > 0, then override is active
        // Note: We could simplify the check by checking only govFeeP since certain values are enforced to be > 0, but for future
        // updates it's preferable to keep the full check
        if (
            pairTradeFeeOverrides.govFeeP > 0 ||
            pairTradeFeeOverrides.referralFeeP > 0 ||
            pairTradeFeeOverrides.gnsOtcFeeP > 0 ||
            pairTradeFeeOverrides.gTokenFeeP > 0 ||
            pairTradeFeeOverrides.gTokenOcFeeP > 0 ||
            pairTradeFeeOverrides.triggerOrderFeeP > 0
        ) return pairTradeFeeOverrides;

        return s.globalTradeFeeParams;
    }

    /**
     * @dev Check IPairsStorageUtils interface for documentation
     */
    function getTradeFeeParamsArray(
        uint8 _collateralIndex,
        uint16[] calldata _pairIndices
    ) internal view returns (IPairsStorage.GlobalTradeFeeParams[] memory) {
        IPairsStorage.GlobalTradeFeeParams[] memory feeParams = new IPairsStorage.GlobalTradeFeeParams[](
            _pairIndices.length
        );

        for (uint256 i; i < _pairIndices.length; ++i) {
            feeParams[i] = getTradeFeeParams(_collateralIndex, _pairIndices[i]);
        }

        return feeParams;
    }

    /**
     * @dev Returns storage slot to use when fetching storage relevant to library
     */
    function _getSlot() internal pure returns (uint256) {
        return StorageUtils.GLOBAL_PAIRS_STORAGE_SLOT;
    }

    /**
     * @dev Returns storage pointer for storage struct in diamond contract, at defined slot
     */
    function _getStorage() internal pure returns (IPairsStorage.PairsStorage storage s) {
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
     * Reverts if group is not listed
     * @param _groupIndex group index to check
     */
    modifier groupListed(uint256 _groupIndex) {
        if (_getStorage().groups[_groupIndex].minLeverage == 0) revert IPairsStorageUtils.GroupNotListed();
        _;
    }

    /**
     * Reverts if fee is not listed
     * @param _feeIndex fee index to check
     */
    modifier feeListed(uint256 _feeIndex) {
        if (_getStorage().feeGroups[_feeIndex].totalPositionSizeFeeP == 0) revert IPairsStorageUtils.FeeNotListed();
        _;
    }

    /**
     * Reverts if group is not valid
     * @param _group group to check
     */
    modifier groupOk(IPairsStorage.Group calldata _group) {
        if (
            _group.minLeverage < MIN_LEVERAGE ||
            _group.maxLeverage > MAX_LEVERAGE ||
            _group.minLeverage >= _group.maxLeverage
        ) revert IPairsStorageUtils.WrongLeverages();
        _;
    }

    /**
     * @dev Reverts if fee is not valid
     * @param _fee fee to check
     */
    modifier feeOk(IPairsStorage.FeeGroup memory _fee) {
        if (
            _fee.totalPositionSizeFeeP == 0 ||
            _fee.totalLiqCollateralFeeP == 0 ||
            _fee.oraclePositionSizeFeeP > _fee.totalPositionSizeFeeP ||
            _fee.minPositionSizeUsd == 0 ||
            _fee.__placeholder != 0
        ) revert IPairsStorageUtils.WrongFees();
        _;
    }

    /**
     * @dev Adds a new trading pair
     * @param _pair pair to add
     */
    function _addPair(
        IPairsStorage.Pair calldata _pair
    ) internal groupListed(_pair.groupIndex) feeListed(_pair.feeIndex) {
        IPairsStorage.PairsStorage storage s = _getStorage();
        if (s.isPairListed[_pair.from][_pair.to]) revert IPairsStorageUtils.PairAlreadyListed();

        s.pairs[s.pairsCount] = _pair;
        s.isPairListed[_pair.from][_pair.to] = true;

        emit IPairsStorageUtils.PairAdded(s.pairsCount++, _pair.from, _pair.to);
    }

    /**
     * @dev Updates an existing trading pair
     * @param _pairIndex index of pair to update
     * @param _pair new pair value
     */
    function _updatePair(
        uint256 _pairIndex,
        IPairsStorage.Pair calldata _pair
    ) internal groupListed(_pair.groupIndex) feeListed(_pair.feeIndex) {
        IPairsStorage.PairsStorage storage s = _getStorage();

        IPairsStorage.Pair storage p = s.pairs[_pairIndex];
        if (!s.isPairListed[p.from][p.to]) revert IPairsStorageUtils.PairNotListed();

        p.feed = _pair.feed;
        p.spreadP = _pair.spreadP;
        p.groupIndex = _pair.groupIndex;
        p.feeIndex = _pair.feeIndex;

        emit IPairsStorageUtils.PairUpdated(_pairIndex);
    }

    /**
     * @dev Adds a new pair group
     * @param _group group to add
     */
    function _addGroup(IPairsStorage.Group calldata _group) internal groupOk(_group) {
        IPairsStorage.PairsStorage storage s = _getStorage();
        s.groups[s.groupsCount] = _group;

        emit IPairsStorageUtils.GroupAdded(s.groupsCount++, _group.name);
    }

    /**
     * @dev Updates an existing pair group
     * @param _id index of group to update
     * @param _group new group value
     */
    function _updateGroup(uint256 _id, IPairsStorage.Group calldata _group) internal groupListed(_id) groupOk(_group) {
        _getStorage().groups[_id] = _group;

        emit IPairsStorageUtils.GroupUpdated(_id);
    }

    /**
     * @dev Adds a new pair fee group
     * @param _fee fee to add
     */
    function _addFee(IPairsStorage.FeeGroup memory _fee) internal feeOk(_fee) {
        IPairsStorage.PairsStorage storage s = _getStorage();
        s.feeGroups[s.feesCount] = _fee;

        emit IPairsStorageUtils.FeeAdded(s.feesCount++, _fee);
    }

    /**
     * @dev Updates an existing pair fee group
     * @param _id index of fee to update
     * @param _fee new fee value
     */
    function _updateFee(uint256 _id, IPairsStorage.FeeGroup memory _fee) internal feeListed(_id) feeOk(_fee) {
        _getStorage().feeGroups[_id] = _fee;

        emit IPairsStorageUtils.FeeUpdated(_id, _fee);
    }

    function _validateGlobalTradeFeeParams(IPairsStorage.GlobalTradeFeeParams memory _feeParams) internal pure {
        if (
            _feeParams.referralFeeP == 0 ||
            _feeParams.govFeeP == 0 ||
            _feeParams.gnsOtcFeeP == 0 ||
            _feeParams.gTokenFeeP == 0 ||
            _feeParams.__placeholder != 0
        ) revert IGeneralErrors.ZeroValue(); // only trigger fee and gTokenOcFeeP are allowed to be 0%

        if (
            _feeParams.govFeeP +
                _feeParams.triggerOrderFeeP +
                _feeParams.gnsOtcFeeP +
                _feeParams.gTokenFeeP +
                _feeParams.gTokenOcFeeP !=
            100 * 1e3
        ) revert IGeneralErrors.WrongParams(); // referral fee is charged first so not included in 100% check

        if (_feeParams.referralFeeP > ConstantsUtils.MAX_REFERRAL_FEE_P) revert IGeneralErrors.AboveMax();
    }
}
