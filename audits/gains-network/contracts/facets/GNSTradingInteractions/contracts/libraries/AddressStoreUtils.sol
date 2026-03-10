// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../interfaces/types/IAddressStore.sol";

import "./StorageUtils.sol";

/**
 *
 * @dev GNSAddressStore facet internal library
 */
library AddressStoreUtils {
    /**
     * @dev Returns storage slot to use when fetching addresses
     */
    function _getSlot() internal pure returns (uint256) {
        return StorageUtils.GLOBAL_ADDRESSES_SLOT;
    }

    /**
     * @dev Returns storage pointer for Addresses struct in global diamond contract, at defined slot
     */
    function getAddresses() internal pure returns (IAddressStore.Addresses storage s) {
        uint256 storageSlot = _getSlot();
        assembly {
            s.slot := storageSlot
        }
    }
}
