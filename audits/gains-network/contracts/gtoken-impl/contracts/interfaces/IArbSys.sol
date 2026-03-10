// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/**
 * @dev Interface for Arbitrum special l2 functions
 */
interface IArbSys {
    function arbBlockNumber() external view returns (uint256);
}
