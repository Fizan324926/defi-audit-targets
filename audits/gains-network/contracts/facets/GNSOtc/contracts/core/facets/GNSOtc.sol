// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../abstract/GNSAddressStore.sol";

import "../../interfaces/libraries/IOtcUtils.sol";

import "../../libraries/OtcUtils.sol";

/**
 * @dev Facet #11: OTC (Handles buy backs and distribution)
 */
contract GNSOtc is GNSAddressStore, IOtcUtils {
    // Initialization

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IOtcUtils
    function initializeOtc(IOtcUtils.OtcConfig memory _config) external reinitializer(12) {
        OtcUtils.initializeOtc(_config);
    }

    // Management Setters

    /// @inheritdoc IOtcUtils
    function updateOtcConfig(IOtcUtils.OtcConfig memory _config) external onlyRole(Role.GOV) {
        OtcUtils.updateOtcConfig(_config);
    }

    // Interactions

    /// @inheritdoc IOtcUtils
    function addOtcCollateralBalance(uint8 _collateralIndex, uint256 _collateralAmount) external virtual onlySelf {
        OtcUtils.addOtcCollateralBalance(_collateralIndex, _collateralAmount);
    }

    /// @inheritdoc IOtcUtils
    function sellGnsForCollateral(uint8 _collateralIndex, uint256 _collateralAmount) external {
        OtcUtils.sellGnsForCollateral(_collateralIndex, _collateralAmount);
    }

    // Getters

    /// @inheritdoc IOtcUtils
    function getOtcConfig() external view returns (IOtcUtils.OtcConfig memory) {
        return OtcUtils.getOtcConfig();
    }

    /// @inheritdoc IOtcUtils
    function getOtcBalance(uint8 _collateralIndex) external view returns (uint256) {
        return OtcUtils.getOtcBalance(_collateralIndex);
    }

    /// @inheritdoc IOtcUtils
    function getOtcRate(uint8 _collateralIndex) external view returns (uint256) {
        return OtcUtils.getOtcRate(_collateralIndex);
    }
}
