// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

/// @title IStorage
/// @notice Interface for storage-related view functions used by modules.
interface IStorage {
    /// @notice Checks if a lender intent is stored on-chain.
    /// @param hash Keccak256 hash of the lender intent.
    /// @return True if intent exists, false otherwise.
    function isLendIntentOnChain(bytes32 hash) external view returns (bool);

    /// @notice Checks if a borrower intent is stored on-chain.
    /// @param hash Keccak256 hash of the borrower intent.
    /// @return True if intent exists, false otherwise.
    function isBorrowIntentOnChain(bytes32 hash) external view returns (bool);

    /// @notice Checks if an intent has been used (matched into a loan).
    /// @param hash Keccak256 hash of the intent (lend or borrow).
    /// @return True if the intent has been used, false otherwise.
    function isIntentUsed(bytes32 hash) external view returns (bool);

    /// @notice Checks if an intent hash was ever registered on-chain.
    /// @dev This differs from isLendIntentOnChain/isBorrowIntentOnChain - those check
    ///      if intent DATA exists, this checks if the hash was registered (stays true after revocation).
    /// @param hash Keccak256 hash of the intent (lend or borrow).
    /// @return True if the intent was registered, false otherwise.
    function isIntentRegistered(bytes32 hash) external view returns (bool);
}
