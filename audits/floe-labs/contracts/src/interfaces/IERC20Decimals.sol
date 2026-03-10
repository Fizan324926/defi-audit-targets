// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8;

/// @title IERC20Decimals
/// @notice Minimal interface for ERC20 tokens that provides access to the decimals() function
interface IERC20Decimals {
    /// @notice Returns the number of decimals used by the token
    /// @return decimals The token precision
    function decimals() external view returns (uint8);
}

