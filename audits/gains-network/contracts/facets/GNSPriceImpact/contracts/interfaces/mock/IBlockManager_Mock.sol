// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/**
 * @dev Interface for BlockManager_Mock contract (test helper)
 */
interface IBlockManager_Mock {
    function getBlockNumber() external view returns (uint256);
}
