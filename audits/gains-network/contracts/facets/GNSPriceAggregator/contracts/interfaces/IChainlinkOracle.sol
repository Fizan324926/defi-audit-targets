// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/**
 * @dev Interface for chainlink oracles
 */
interface IChainlinkOracle {
    function getAuthorizationStatus(address) external view returns (bool);

    function owner() external view returns (address);
}
