// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {ErrorsLib} from "./ErrorsLib.sol";

/// @title ValidationLib
/// @notice Library for validating intent parameters
library ValidationLib {
    /// @notice Validates intent field parameters without storage mapping check.
    /// @dev Used by LendingViewsUpgradeable where storage mappings are not accessible.
    /// The storage-based hash deduplication is handled separately via storageIface.isIntentUsed().
    function validateIntentFields(
        uint256 amount,
        uint256 expiry,
        uint256 minFillAmount,
        uint256 minLtvBps,
        uint256 maxLtvBps,
        uint256 interestRateBps,
        uint256 validFromTimestamp,
        uint256 filledAmount,
        uint256 minDuration,
        uint256 maxDuration,
        bool allowPartialFill,
        bool isBorrower,
        uint256 matcherCommissionBps,
        uint256 maxLtv,
        uint256 maxInterestRate,
        uint256 maxProtocolFee
    ) internal view {
        // Expiry checks
        if (block.timestamp > expiry) revert ErrorsLib.IntentExpired();

        // Amount > 0
        if (amount == 0) revert ErrorsLib.ZeroAmount();

        // LTV checks
        if (minLtvBps > 0 && maxLtvBps > 0) {
            if (minLtvBps > maxLtvBps) revert ErrorsLib.LtvOutOfBounds();
        }
        if ((minLtvBps > 0 && minLtvBps > maxLtv) || (maxLtvBps > 0 && maxLtvBps > maxLtv)) {
            revert ErrorsLib.LtvOutOfBounds();
        }

        // Interest rate checks
        if (interestRateBps == 0 || interestRateBps > maxInterestRate) {
            revert ErrorsLib.RateOutOfBounds();
        }

        // Min fill amount checks
        if (allowPartialFill && minFillAmount > amount) {
            revert ErrorsLib.MinFillAmountOutOfBounds();
        }

        // Valid-from timestamp checks
        if (validFromTimestamp > expiry) revert ErrorsLib.ValidFromAfterExpiry();

        // Filled amount checks (relevant for lenders)
        if (filledAmount >= amount) revert ErrorsLib.FilledAmountOutOfBounds();

        // Duration range validation
        if (minDuration == 0) revert ErrorsLib.ZeroAmount();
        if (maxDuration == 0) revert ErrorsLib.ZeroAmount();
        if (minDuration > maxDuration) revert ErrorsLib.MinDurationExceedsMax();

        // Borrower-specific commission checks
        if (isBorrower && matcherCommissionBps > maxProtocolFee) {
            revert ErrorsLib.FeeOutOfBounds();
        }
    }

    /// @notice Validates intent parameters for both registration and matching flows.
    /// @dev Includes storage mapping check for hash deduplication (used by on-chain registration path).
    function validateIntent(
        uint256 amount,
        uint256 expiry,
        uint256 minFillAmount,
        uint256 minLtvBps,
        uint256 maxLtvBps,
        uint256 interestRateBps,
        uint256 validFromTimestamp,
        uint256 filledAmount,
        uint256 minDuration,
        uint256 maxDuration,
        bool allowPartialFill,
        bytes32 hash,
        mapping(bytes32 => bool) storage intentHashes,
        bool isBorrower,
        uint256 matcherCommissionBps,
        uint256 maxLtv,
        uint256 maxInterestRate,
        uint256 maxProtocolFee
    ) internal view {
        // Expiry checks
        if (block.timestamp > expiry) revert ErrorsLib.IntentExpired();

        // Amount > 0
        if (amount == 0) revert ErrorsLib.ZeroAmount();

        // LTV checks
        if (minLtvBps > 0 && maxLtvBps > 0) {
            if (minLtvBps > maxLtvBps) revert ErrorsLib.LtvOutOfBounds();
        }
        if ((minLtvBps > 0 && minLtvBps > maxLtv) || (maxLtvBps > 0 && maxLtvBps > maxLtv)) {
            revert ErrorsLib.LtvOutOfBounds();
        }

        // Interest rate checks
        if (interestRateBps == 0 || interestRateBps > maxInterestRate) {
            revert ErrorsLib.RateOutOfBounds();
        }

        // Min fill amount checks
        if (allowPartialFill && minFillAmount > amount) {
            revert ErrorsLib.MinFillAmountOutOfBounds();
        }

        // Valid-from timestamp checks
        if (validFromTimestamp > expiry) revert ErrorsLib.ValidFromAfterExpiry();

        // Intent hash deduplication check
        if (intentHashes[hash]) revert ErrorsLib.IntentAlreadyUsed();

        // Filled amount checks (relevant for lenders)
        if (filledAmount >= amount) revert ErrorsLib.FilledAmountOutOfBounds();

        // Duration range validation
        if (minDuration == 0) revert ErrorsLib.ZeroAmount();
        if (maxDuration == 0) revert ErrorsLib.ZeroAmount();
        if (minDuration > maxDuration) revert ErrorsLib.MinDurationExceedsMax();

        // Borrower-specific commission checks
        if (isBorrower && matcherCommissionBps > maxProtocolFee) {
            revert ErrorsLib.FeeOutOfBounds();
        }
    }
}
