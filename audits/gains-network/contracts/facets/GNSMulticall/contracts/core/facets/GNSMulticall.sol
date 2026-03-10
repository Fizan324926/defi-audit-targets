// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../../interfaces/IMulticall.sol";
import "../../interfaces/IGeneralErrors.sol";

/**
 * @dev Facet #12: Multicall
 */
contract GNSMulticall is IMulticall {
    /// @inheritdoc IMulticall
    /// @dev NEVER make this function `payable`! delegatecall forwards msg.value to all calls regardless of it being spent or not
    function multicall(bytes[] calldata data) external returns (bytes[] memory results) {
        if (data.length > 20) {
            revert IGeneralErrors.AboveMax();
        }

        results = new bytes[](data.length);

        for (uint256 i; i < data.length; ++i) {
            (bool success, bytes memory result) = address(this).delegatecall(data[i]);

            if (!success) {
                assembly {
                    returndatacopy(0x00, 0x00, returndatasize())
                    revert(0x00, returndatasize())
                }
            }

            results[i] = result;
        }
    }
}
