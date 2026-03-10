// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8;

interface IConditionValidator {
    /// @notice Validates a condition for a given intent.
    /// @return success True if the condition is met, false otherwise.
    function validateCondition(bytes calldata data) external view returns (bool);
}
