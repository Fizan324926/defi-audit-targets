// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Hook} from "./ILendingTypes.sol";

/// @notice Interface for executing an array of hooks.
interface IHookExecutor {
    /// @notice Executes the provided hooks.
    /// @param hooks The array of Hook structs to execute.
    function execute(Hook[] calldata hooks) external;

    /// @notice Sets the gas limit for exact call checks.
    /// @param gasForCallExactCheck_ The new gas limit value.
    function setGasForCallExactCheck(uint32 gasForCallExactCheck_) external;

    /// @notice Returns the current gas limit for exact call checks.
    /// @return The gas limit value.
    function getGasForCallExactCheck() external view returns (uint32);
}
