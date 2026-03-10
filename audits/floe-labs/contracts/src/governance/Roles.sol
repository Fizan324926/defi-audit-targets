// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

/// @title Roles
/// @notice Role constants for AccessControl-based governance
/// @dev Used across all upgradeable contracts for consistent role management
library Roles {
    /// @notice Default admin - can grant/revoke all roles
    /// @dev This is AccessControl's built-in admin role (bytes32(0))
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    /// @notice Protocol admin - manages protocol configuration
    /// @dev Markets, fees, managers, hook executor
    bytes32 internal constant PROTOCOL_ADMIN_ROLE = keccak256("PROTOCOL_ADMIN_ROLE");

    /// @notice Oracle admin - manages price oracle configuration
    /// @dev Price sources, staleness, fallbacks
    bytes32 internal constant ORACLE_ADMIN_ROLE = keccak256("ORACLE_ADMIN_ROLE");

    /// @notice Upgrader - can execute upgrades
    /// @dev Should be held by TimelockController, NOT by EOA or multisig directly
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Guardian - emergency pause and cancel operations
    /// @dev Can be multisig or dedicated hot key for fast response
    bytes32 internal constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
}
