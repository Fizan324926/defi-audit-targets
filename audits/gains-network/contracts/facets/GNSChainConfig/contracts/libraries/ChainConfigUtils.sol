// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../interfaces/IGeneralErrors.sol";
import "../interfaces/libraries/IChainConfigUtils.sol";

import "./StorageUtils.sol";

/**
 * @dev ChainConfig facet internal library
 */
library ChainConfigUtils {
    uint16 internal constant MIN_NATIVE_TRANSFER_GAS_LIMIT = 21_000;

    /**
     * @dev Check IChainConfig interface for documentation
     */
    function initializeChainConfig(uint16 _nativeTransferGasLimit, bool _nativeTransferEnabled) internal {
        updateNativeTransferGasLimit(_nativeTransferGasLimit);
        updateNativeTransferEnabled(_nativeTransferEnabled);
    }

    /**
     * @dev Check IChainConfigUtils interface for documentation
     */
    function updateNativeTransferGasLimit(uint16 _nativeTransferGasLimit) internal {
        if (_nativeTransferGasLimit < MIN_NATIVE_TRANSFER_GAS_LIMIT) revert IGeneralErrors.BelowMin();

        _getStorage().nativeTransferGasLimit = _nativeTransferGasLimit;

        emit IChainConfigUtils.NativeTransferGasLimitUpdated(_nativeTransferGasLimit);
    }

    /**
     * @dev Check IChainConfigUtils interface for documentation
     */
    function updateNativeTransferEnabled(bool _nativeTransferEnabled) internal {
        _getStorage().nativeTransferEnabled = _nativeTransferEnabled;

        emit IChainConfigUtils.NativeTransferEnabledUpdated(_nativeTransferEnabled);
    }

    /**
     * @dev Check IChainConfigUtils interface for documentation
     */
    function getNativeTransferGasLimit() internal view returns (uint16) {
        uint16 gasLimit = _getStorage().nativeTransferGasLimit;

        // If `nativeTransferGasLimit` is 0 (not yet initialized) then return `MIN_NATIVE_TRANSFER_GAS_LIMIT
        return gasLimit == 0 ? MIN_NATIVE_TRANSFER_GAS_LIMIT : gasLimit;
    }

    /**
     * @dev Check IChainConfigUtils interface for documentation
     */
    function getNativeTransferEnabled() internal view returns (bool) {
        return _getStorage().nativeTransferEnabled;
    }

    /**
     * @dev Check IChainConfigUtils interface for documentation
     */
    function getReentrancyLock() internal view returns (uint256) {
        return _getStorage().reentrancyLock;
    }

    /**
     * @dev Returns storage slot to use when fetching storage relevant to library
     */
    function _getSlot() internal pure returns (uint256) {
        return StorageUtils.GLOBAL_CHAIN_CONFIG_SLOT;
    }

    /**
     * @dev Returns storage pointer for storage struct in diamond contract, at defined slot
     */
    function _getStorage() internal pure returns (IChainConfig.ChainConfigStorage storage s) {
        uint256 storageSlot = _getSlot();
        assembly {
            s.slot := storageSlot
        }
    }
}
