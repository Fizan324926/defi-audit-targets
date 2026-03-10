// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../abstract/GNSAddressStore.sol";

import "../../interfaces/libraries/IChainConfigUtils.sol";

import "../../libraries/ChainConfigUtils.sol";

/**
 * @dev Facet #13: ChainConfig (Handles global and chain-specific configuration)
 */
contract GNSChainConfig is GNSAddressStore, IChainConfigUtils {
    // Initialization

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IChainConfigUtils
    function initializeChainConfig(
        uint16 _nativeTransferGasLimit,
        bool _nativeTransferEnabled
    ) external reinitializer(18) {
        ChainConfigUtils.initializeChainConfig(_nativeTransferGasLimit, _nativeTransferEnabled);
    }

    // Management Setters

    /// @inheritdoc IChainConfigUtils
    function updateNativeTransferGasLimit(uint16 _nativeTransferGasLimit) external onlyRole(Role.GOV_EMERGENCY) {
        ChainConfigUtils.updateNativeTransferGasLimit(_nativeTransferGasLimit);
    }

    /// @inheritdoc IChainConfigUtils
    function updateNativeTransferEnabled(bool _nativeTransferEnabled) external onlyRole(Role.GOV_EMERGENCY) {
        ChainConfigUtils.updateNativeTransferEnabled(_nativeTransferEnabled);
    }

    // Getters

    /// @inheritdoc IChainConfigUtils
    function getNativeTransferGasLimit() external view returns (uint16) {
        return ChainConfigUtils.getNativeTransferGasLimit();
    }

    /// @inheritdoc IChainConfigUtils
    function getNativeTransferEnabled() external view returns (bool) {
        return ChainConfigUtils.getNativeTransferEnabled();
    }

    /// @inheritdoc IChainConfigUtils
    function getReentrancyLock() external view returns (uint256) {
        return ChainConfigUtils.getReentrancyLock();
    }
}
