// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../interfaces/libraries/IFeeTiersUtils.sol";
import "../interfaces/IGeneralErrors.sol";

import "../interfaces/types/IFeeTiers.sol";

import "./StorageUtils.sol";

/**
 * @custom:version 8
 * @dev GNSFeeTiers facet internal library
 *
 * This is a library to apply fee tiers to trading fees based on a trailing point system.
 */
library FeeTiersUtils {
    uint256 private constant MAX_FEE_TIERS = 8;
    uint32 private constant TRAILING_PERIOD_DAYS = 30;
    uint32 private constant FEE_MULTIPLIER_SCALE = 1e3;
    uint224 private constant POINTS_THRESHOLD_SCALE = 1e18;
    uint256 private constant GROUP_VOLUME_MULTIPLIER_SCALE = 1e3;

    /**
     * @dev Check IFeeTiersUtils interface for documentation
     */
    function initializeFeeTiers(
        uint256[] calldata _groupIndices,
        uint256[] calldata _groupVolumeMultipliers,
        uint256[] calldata _feeTiersIndices,
        IFeeTiers.FeeTier[] calldata _feeTiers
    ) internal {
        setGroupVolumeMultipliers(_groupIndices, _groupVolumeMultipliers);
        setFeeTiers(_feeTiersIndices, _feeTiers);
    }

    /**
     * @dev Check IFeeTiersUtils interface for documentation
     */
    function setGroupVolumeMultipliers(uint256[] calldata _groupIndices, uint256[] calldata _groupVolumeMultipliers)
        internal
    {
        if (_groupIndices.length != _groupVolumeMultipliers.length) {
            revert IGeneralErrors.WrongLength();
        }

        mapping(uint256 => uint256) storage groupVolumeMultipliers = _getStorage().groupVolumeMultipliers;

        for (uint256 i; i < _groupIndices.length; ++i) {
            groupVolumeMultipliers[_groupIndices[i]] = _groupVolumeMultipliers[i];
        }

        emit IFeeTiersUtils.GroupVolumeMultipliersUpdated(_groupIndices, _groupVolumeMultipliers);
    }

    /**
     * @dev Check IFeeTiersUtils interface for documentation
     */
    function setFeeTiers(uint256[] calldata _feeTiersIndices, IFeeTiers.FeeTier[] calldata _feeTiers) internal {
        if (_feeTiersIndices.length != _feeTiers.length) {
            revert IGeneralErrors.WrongLength();
        }

        IFeeTiers.FeeTier[8] storage feeTiersStorage = _getStorage().feeTiers;

        // First do all updates
        for (uint256 i; i < _feeTiersIndices.length; ++i) {
            feeTiersStorage[_feeTiersIndices[i]] = _feeTiers[i];
        }

        // Then check updates are valid
        for (uint256 i; i < _feeTiersIndices.length; ++i) {
            _checkFeeTierUpdateValid(_feeTiersIndices[i], _feeTiers[i], feeTiersStorage);
        }

        emit IFeeTiersUtils.FeeTiersUpdated(_feeTiersIndices, _feeTiers);
    }

    /**
     * @dev Check IFeeTiersUtils interface for documentation
     */
    function updateTraderPoints(address _trader, uint256 _volumeUsd, uint256 _groupIndex) internal {
        IFeeTiers.FeeTiersStorage storage s = _getStorage();

        // Scale amount by group multiplier
        uint224 points = uint224((_volumeUsd * s.groupVolumeMultipliers[_groupIndex]) / GROUP_VOLUME_MULTIPLIER_SCALE);

        mapping(uint32 => IFeeTiers.TraderDailyInfo) storage traderDailyInfo = s.traderDailyInfos[_trader];
        uint32 currentDay = _getCurrentDay();
        IFeeTiers.TraderDailyInfo storage traderCurrentDayInfo = traderDailyInfo[currentDay];

        // Increase points for current day
        if (points > 0) {
            traderCurrentDayInfo.points += points;
            emit IFeeTiersUtils.TraderDailyPointsIncreased(_trader, currentDay, points);
        }

        IFeeTiers.TraderInfo storage traderInfo = s.traderInfos[_trader];

        // Return early if first update ever for trader since trailing points would be 0 anyway
        if (traderInfo.lastDayUpdated == 0) {
            traderInfo.lastDayUpdated = currentDay;
            emit IFeeTiersUtils.TraderInfoFirstUpdate(_trader, currentDay);

            return;
        }

        // Update trailing points & re-calculate cached fee tier.
        // Only run if at least 1 day elapsed since last update
        if (currentDay > traderInfo.lastDayUpdated) {
            // Trailing points = sum of all daily points accumulated for last TRAILING_PERIOD_DAYS.
            // It determines which fee tier to apply (pointsThreshold)
            uint224 curTrailingPoints;

            // Calculate trailing points if less than or exactly TRAILING_PERIOD_DAYS have elapsed since update.
            // Otherwise, trailing points is 0 anyway.
            uint32 earliestActiveDay = currentDay - TRAILING_PERIOD_DAYS;

            if (traderInfo.lastDayUpdated >= earliestActiveDay) {
                // Load current trailing points and add last day updated points since they are now finalized
                curTrailingPoints = traderInfo.trailingPoints + traderDailyInfo[traderInfo.lastDayUpdated].points;

                // Expire outdated trailing points
                uint32 earliestOutdatedDay = traderInfo.lastDayUpdated - TRAILING_PERIOD_DAYS;
                uint32 lastOutdatedDay = earliestActiveDay - 1;

                uint224 expiredTrailingPoints;
                for (uint32 i = earliestOutdatedDay; i <= lastOutdatedDay; ++i) {
                    expiredTrailingPoints += traderDailyInfo[i].points;
                }

                curTrailingPoints -= expiredTrailingPoints;

                emit IFeeTiersUtils.TraderTrailingPointsExpired(
                    _trader, earliestOutdatedDay, lastOutdatedDay, expiredTrailingPoints
                );
            }

            // Store last updated day and new trailing points
            traderInfo.lastDayUpdated = currentDay;
            traderInfo.trailingPoints = curTrailingPoints;

            emit IFeeTiersUtils.TraderInfoUpdated(_trader, traderInfo);

            // Re-calculate current fee tier for trader
            uint32 newFeeMultiplier = FEE_MULTIPLIER_SCALE; // use 1 by default (if no fee tier corresponds)

            for (uint256 i = getFeeTiersCount(); i > 0; --i) {
                IFeeTiers.FeeTier memory feeTier = s.feeTiers[i - 1];

                if (curTrailingPoints >= uint224(feeTier.pointsThreshold) * POINTS_THRESHOLD_SCALE) {
                    newFeeMultiplier = feeTier.feeMultiplier;
                    break;
                }
            }

            // Update trader cached fee multiplier
            traderCurrentDayInfo.feeMultiplierCache = newFeeMultiplier;
            emit IFeeTiersUtils.TraderFeeMultiplierCached(_trader, currentDay, newFeeMultiplier);
        }
    }

    /**
     * @dev Check IFeeTiersUtils interface for documentation
     */
    function calculateFeeAmount(address _trader, uint256 _normalFeeAmountCollateral) internal view returns (uint256) {
        uint32 feeMultiplier = _getStorage().traderDailyInfos[_trader][_getCurrentDay()].feeMultiplierCache;
        return feeMultiplier == 0
            ? _normalFeeAmountCollateral
            : (uint256(feeMultiplier) * _normalFeeAmountCollateral) / uint256(FEE_MULTIPLIER_SCALE);
    }

    /**
     * @dev Check IFeeTiersUtils interface for documentation
     */
    function getFeeTiersCount() internal view returns (uint256) {
        IFeeTiers.FeeTier[8] storage _feeTiers = _getStorage().feeTiers;

        for (uint256 i = MAX_FEE_TIERS; i > 0; --i) {
            if (_feeTiers[i - 1].feeMultiplier > 0) {
                return i;
            }
        }

        return 0;
    }

    /**
     * @dev Check IFeeTiersUtils interface for documentation
     */
    function getFeeTier(uint256 _feeTierIndex) internal view returns (IFeeTiers.FeeTier memory) {
        return _getStorage().feeTiers[_feeTierIndex];
    }

    /**
     * @dev Check IFeeTiersUtils interface for documentation
     */
    function getGroupVolumeMultiplier(uint256 _groupIndex) internal view returns (uint256) {
        return _getStorage().groupVolumeMultipliers[_groupIndex];
    }

    /**
     * @dev Check IFeeTiersUtils interface for documentation
     */
    function getFeeTiersTraderInfo(address _trader) internal view returns (IFeeTiers.TraderInfo memory) {
        return _getStorage().traderInfos[_trader];
    }

    /**
     * @dev Check IFeeTiersUtils interface for documentation
     */
    function getFeeTiersTraderDailyInfo(address _trader, uint32 _day)
        internal
        view
        returns (IFeeTiers.TraderDailyInfo memory)
    {
        return _getStorage().traderDailyInfos[_trader][_day];
    }

    /**
     * @dev Returns storage slot to use when fetching storage relevant to library
     */
    function _getSlot() internal pure returns (uint256) {
        return StorageUtils.GLOBAL_FEE_TIERS_SLOT;
    }

    /**
     * @dev Returns storage pointer for storage struct in diamond contract, at defined slot
     */
    function _getStorage() internal pure returns (IFeeTiers.FeeTiersStorage storage s) {
        uint256 storageSlot = _getSlot();
        assembly {
            s.slot := storageSlot
        }
    }

    /**
     * @dev Checks validity of a single fee tier update (feeMultiplier: descending, pointsThreshold: ascending, no gap)
     * @param _index index of the fee tier that was updated
     * @param _feeTier fee tier new value
     * @param _feeTiers all fee tiers
     */
    function _checkFeeTierUpdateValid(
        uint256 _index,
        IFeeTiers.FeeTier calldata _feeTier,
        IFeeTiers.FeeTier[8] storage _feeTiers
    ) internal view {
        bool isDisabled = _feeTier.feeMultiplier == 0 && _feeTier.pointsThreshold == 0;

        // Either both feeMultiplier and pointsThreshold are 0 or none
        // And make sure feeMultiplier < 1 otherwise useless
        if (
            !isDisabled
                && (
                    _feeTier.feeMultiplier >= FEE_MULTIPLIER_SCALE || _feeTier.feeMultiplier == 0
                        || _feeTier.pointsThreshold == 0
                )
        ) {
            revert IFeeTiersUtils.WrongFeeTier();
        }

        bool hasNextValue = _index < MAX_FEE_TIERS - 1;

        // If disabled, only need to check the next fee tier is disabled as well to create no gaps in active tiers
        if (isDisabled) {
            if (hasNextValue && _feeTiers[_index + 1].feeMultiplier > 0) {
                revert IGeneralErrors.WrongOrder();
            }
        } else {
            // Check next value order
            if (hasNextValue) {
                IFeeTiers.FeeTier memory feeTier = _feeTiers[_index + 1];
                if (
                    feeTier.feeMultiplier != 0
                        && (
                            feeTier.feeMultiplier >= _feeTier.feeMultiplier
                                || feeTier.pointsThreshold <= _feeTier.pointsThreshold
                        )
                ) {
                    revert IGeneralErrors.WrongOrder();
                }
            }

            // Check previous value order
            if (_index > 0) {
                IFeeTiers.FeeTier memory feeTier = _feeTiers[_index - 1];
                if (
                    feeTier.feeMultiplier <= _feeTier.feeMultiplier
                        || feeTier.pointsThreshold >= _feeTier.pointsThreshold
                ) {
                    revert IGeneralErrors.WrongOrder();
                }
            }
        }
    }

    /**
     * @dev Get current day (index of mapping traderDailyInfo)
     */
    function _getCurrentDay() internal view returns (uint32) {
        return uint32(block.timestamp / 1 days);
    }
}
