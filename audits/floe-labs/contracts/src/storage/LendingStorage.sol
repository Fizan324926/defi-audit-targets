// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {LendIntent, BorrowIntent, Market, Loan} from "../interfaces/ILendingTypes.sol";

/// @title LendingStorage
/// @notice ERC-7201 namespaced storage for the Floe Modular Lending protocol
/// @dev Implements ERC-7201 storage layout for safe upgrades
///      Namespace ID: floe.storage.LendingStorage
library LendingStorageLib {
    /// @dev Storage slot for LendingStorage namespace
    /// @dev Computed via: keccak256(abi.encode(uint256(keccak256("floe.storage.LendingStorage")) - 1)) & ~bytes32(uint256(0xff))
    /// @dev Verified by: script/ComputeSlots.s.sol
    bytes32 internal constant LENDING_STORAGE_SLOT =
        0xe8764bbf0e6271e91784e9c270c3677040190f13325dc23c4114eba2201a4d00;

    /// @custom:storage-location erc7201:floe.storage.LendingStorage
    struct LendingStorage {
        // ============ Markets ============
        /// @notice Maps market IDs to market metadata
        mapping(bytes32 marketId => Market) markets;
        /// @notice List of all market IDs created
        bytes32[] marketsCreated;

        // ============ Intents ============
        /// @notice Tracks lender intents posted on-chain
        mapping(bytes32 intentHash => LendIntent) onChainLendIntents;
        /// @notice Tracks borrower intents posted on-chain
        mapping(bytes32 intentHash => BorrowIntent) onChainBorrowIntents;
        /// @notice Records whether a specific intent hash has been registered on-chain
        mapping(bytes32 intentHash => bool) registeredIntentHashes;
        /// @notice Records whether a specific intent hash has been used in a loan match
        mapping(bytes32 intentHash => bool) usedIntentHashes;

        // ============ Loans ============
        /// @notice Maps loan IDs to active or repaid loan data
        mapping(uint256 loanId => Loan) loans;
        /// @notice Maps users to their loan IDs
        mapping(address user => uint256[]) userToLoanIds;
        /// @notice Global counter for assigning unique loan IDs
        uint256 loanCounter;

        // ============ Protocol Config ============
        /// @notice Address that receives protocol fees
        address feeRecipient;
        /// @notice Address of the price oracle used for valuations
        address priceOracle;
        /// @notice Address of the contract that executes hooks
        address hookExecutor;
        /// @notice Address of the lending logics manager contract for delegation
        address logicsManager;
        /// @notice Flashloan fee in basis points (bps)
        uint256 flashloanFeeBps;
        /// @notice Buffer from liquidation threshold for collateral withdrawals (bps)
        uint256 withdrawalBufferBps;
        /// @notice Minimum gap required between borrower's initial LTV and lender's liquidation threshold (bps)
        uint256 minLtvGapBps;

        // ============ Domain Separator Cache ============
        /// @notice Cached domain separator for post-fork scenarios
        bytes32 cachedDomainSeparator;
        /// @notice Cached chain ID for post-fork scenarios
        uint256 cachedChainId;

        // ============ Extension Slots (Bug Fixes) ============
        /// @notice Tracks filled amount for off-chain lend intents (Bug #64228 fix)
        /// @dev Added post-deployment - uses first gap slot to maintain storage compatibility
        mapping(bytes32 intentHash => uint256) offChainLendIntentFilledAmount;

        // ============ Reserved for Future Upgrades ============
        /// @dev Storage gap for future upgrades (48 slots reserved, reduced by 1 for offChainLendIntentFilledAmount)
        uint256[48] __gap;
    }

    /// @notice Returns the storage pointer to the LendingStorage struct
    /// @return $ Storage pointer to LendingStorage
    function _getLendingStorage() internal pure returns (LendingStorage storage $) {
        assembly {
            $.slot := LENDING_STORAGE_SLOT
        }
    }
}
