// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../abstract/GNSAddressStore.sol";

import "../../interfaces/libraries/IFeeTiersUtils.sol";

import "../../libraries/FeeTiersUtils.sol";
import "../../libraries/PairsStorageUtils.sol";

/**
 * @custom:version 8c
 * @dev Facet #3: Fee tiers
 */
contract GNSFeeTiers is GNSAddressStore, IFeeTiersUtils {
    // Initialization

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IFeeTiersUtils
    function initializeFeeTiers(
        uint256[] calldata _groupIndices,
        uint256[] calldata _groupVolumeMultipliers,
        uint256[] calldata _feeTiersIndices,
        IFeeTiersUtils.FeeTier[] calldata _feeTiers
    ) external reinitializer(4) {
        FeeTiersUtils.initializeFeeTiers(_groupIndices, _groupVolumeMultipliers, _feeTiersIndices, _feeTiers);
    }

    // Management Setters

    /// @inheritdoc IFeeTiersUtils
    function setGroupVolumeMultipliers(uint256[] calldata _groupIndices, uint256[] calldata _groupVolumeMultipliers)
        external
        onlyRole(Role.GOV)
    {
        FeeTiersUtils.setGroupVolumeMultipliers(_groupIndices, _groupVolumeMultipliers);
    }

    /// @inheritdoc IFeeTiersUtils
    function setFeeTiers(uint256[] calldata _feeTiersIndices, IFeeTiersUtils.FeeTier[] calldata _feeTiers)
        external
        onlyRole(Role.GOV)
    {
        FeeTiersUtils.setFeeTiers(_feeTiersIndices, _feeTiers);
    }

    // Interactions

    /// @inheritdoc IFeeTiersUtils
    function updateTraderPoints(address _trader, uint256 _volumeUsd, uint256 _pairIndex) external virtual onlySelf {
        FeeTiersUtils.updateTraderPoints(_trader, _volumeUsd, PairsStorageUtils.pairFeeIndex(_pairIndex));
    }

    // Getters

    /// @inheritdoc IFeeTiersUtils
    function calculateFeeAmount(address _trader, uint256 _normalFeeAmountCollateral) external view returns (uint256) {
        return FeeTiersUtils.calculateFeeAmount(_trader, _normalFeeAmountCollateral);
    }

    /// @inheritdoc IFeeTiersUtils
    function getFeeTiersCount() external view returns (uint256) {
        return FeeTiersUtils.getFeeTiersCount();
    }

    /// @inheritdoc IFeeTiersUtils
    function getFeeTier(uint256 _feeTierIndex) external view returns (IFeeTiersUtils.FeeTier memory) {
        return FeeTiersUtils.getFeeTier(_feeTierIndex);
    }

    /// @inheritdoc IFeeTiersUtils
    function getGroupVolumeMultiplier(uint256 _groupIndex) external view returns (uint256) {
        return FeeTiersUtils.getGroupVolumeMultiplier(_groupIndex);
    }

    /// @inheritdoc IFeeTiersUtils
    function getFeeTiersTraderInfo(address _trader) external view returns (IFeeTiersUtils.TraderInfo memory) {
        return FeeTiersUtils.getFeeTiersTraderInfo(_trader);
    }

    /// @inheritdoc IFeeTiersUtils
    function getFeeTiersTraderDailyInfo(address _trader, uint32 _day)
        external
        view
        returns (IFeeTiersUtils.TraderDailyInfo memory)
    {
        return FeeTiersUtils.getFeeTiersTraderDailyInfo(_trader, _day);
    }
}
