// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {LendIntent, BorrowIntent, Market} from "../interfaces/ILendingTypes.sol";
import {ErrorsLib} from "./ErrorsLib.sol";
import {MathLib} from "./MathLib.sol";
import {MAX_LTV_BPS, MAX_INTEREST_RATE_BPS} from "./ConstantsLib.sol";

/// @title MatchValidationLib
/// @notice Shared validation logic for intent matching compatibility
/// @dev Single source of truth for both view and execution paths
library MatchValidationLib {
    /// @notice Validates intent compatibility and reverts on failure
    /// @dev Used by execution path (_validateIntentsForMatch)
    /// @param lender The lender intent
    /// @param borrower The borrower intent
    /// @param marketId The market ID from execution params
    /// @param market The market data (must be loaded by caller)
    /// @param currentTimestamp Current block.timestamp
    function validateMatchCompatibility(
        LendIntent calldata lender,
        BorrowIntent calldata borrower,
        bytes32 marketId,
        Market memory market,
        uint256 currentTimestamp,
        uint256 minLtvGapBps
    ) internal pure {
        // 1. MarketId validation - CRITICAL: prevents wrong token transfers
        if (lender.marketId != marketId) revert ErrorsLib.MarketIdMismatch();
        if (borrower.marketId != marketId) revert ErrorsLib.MarketIdMismatch();

        // 2. Market exists
        if (market.loanToken == address(0)) revert ErrorsLib.MarketNotCreated();
        if (market.collateralToken == address(0)) revert ErrorsLib.MarketNotCreated();

        // 3. Pause status
        if (market.pauseStatuses.isBorrowPaused) revert ErrorsLib.BorrowPaused();
        if (market.pauseStatuses.isAddCollateralPaused) revert ErrorsLib.AddCollateralPaused();

        // 4. Expiry
        if (currentTimestamp > lender.expiry) revert ErrorsLib.IntentExpired();
        if (currentTimestamp > borrower.expiry) revert ErrorsLib.IntentExpired();

        // 5. validFromTimestamp
        if (currentTimestamp < lender.validFromTimestamp) revert ErrorsLib.IntentNotYetValid();
        if (currentTimestamp < borrower.validFromTimestamp) revert ErrorsLib.IntentNotYetValid();

        // 6. Duration range overlap
        {
            uint256 overlapMin = borrower.minDuration > lender.minDuration
                ? borrower.minDuration
                : lender.minDuration;
            uint256 overlapMax = MathLib.min(borrower.maxDuration, lender.maxDuration);
            if (overlapMin > overlapMax) revert ErrorsLib.DurationMismatch();
        }

        // 7. Interest rate compatibility
        if (borrower.maxInterestRateBps < lender.minInterestRateBps) {
            revert ErrorsLib.InterestRateMismatch();
        }
        if (lender.minInterestRateBps < market.interestRateBps) {
            revert ErrorsLib.InterestRateOutOfBounds();
        }

        // FIX (Bug #64321): Enforce MAX_INTEREST_RATE_BPS for off-chain intents
        if (lender.minInterestRateBps > MAX_INTEREST_RATE_BPS) {
            revert ErrorsLib.RateOutOfBounds();
        }
        if (borrower.maxInterestRateBps > MAX_INTEREST_RATE_BPS) {
            revert ErrorsLib.RateOutOfBounds();
        }

        // 8. LTV bounds validation (matches legacy Internal.sol:179-181)
        // Borrower's minimum LTV must be at least the market minimum
        if (borrower.minLtvBps < market.ltvBps) revert ErrorsLib.LtvOutOfBounds();
        // Lender's maximum LTV must be at least the market minimum
        if (lender.maxLtvBps < market.ltvBps) revert ErrorsLib.LtvOutOfBounds();

        // FIX (Bug #64321): Enforce MAX_LTV_BPS for off-chain intents
        // This ensures off-chain intents respect the same protocol limits as on-chain registration
        if (lender.maxLtvBps > MAX_LTV_BPS) revert ErrorsLib.LtvOutOfBounds();
        if (borrower.minLtvBps > MAX_LTV_BPS) revert ErrorsLib.LtvOutOfBounds();

        // Borrower's minimum + required gap must not exceed lender's maximum
        // This ensures sufficient buffer between initial LTV and liquidation threshold
        if (borrower.minLtvBps + minLtvGapBps > lender.maxLtvBps) revert ErrorsLib.LtvMismatch();

        // 9. Lender available amount
        if (lender.amount <= lender.filledAmount) revert ErrorsLib.IntentAlreadyUsed();
        uint256 lenderAvailable = lender.amount - lender.filledAmount;
        if (lenderAvailable < borrower.minFillAmount) revert ErrorsLib.FillAmountBelowMin();
    }

    /// @notice Checks intent compatibility and returns false on failure
    /// @dev Used by view path (_canMatchLoanIntents)
    /// @param lender The lender intent
    /// @param borrower The borrower intent
    /// @param marketId The market ID
    /// @param market The market data
    /// @param currentTimestamp Current block.timestamp
    /// @return True if intents are compatible, false otherwise
    function canMatch(
        LendIntent calldata lender,
        BorrowIntent calldata borrower,
        bytes32 marketId,
        Market memory market,
        uint256 currentTimestamp,
        uint256 minLtvGapBps
    ) internal pure returns (bool) {
        // 1. MarketId validation
        if (lender.marketId != marketId) return false;
        if (borrower.marketId != marketId) return false;

        // 2. Market exists
        if (market.loanToken == address(0)) return false;
        if (market.collateralToken == address(0)) return false;

        // 3. Pause status
        if (market.pauseStatuses.isBorrowPaused) return false;
        if (market.pauseStatuses.isAddCollateralPaused) return false;

        // 4. Expiry
        if (currentTimestamp > lender.expiry) return false;
        if (currentTimestamp > borrower.expiry) return false;

        // 5. validFromTimestamp
        if (currentTimestamp < lender.validFromTimestamp) return false;
        if (currentTimestamp < borrower.validFromTimestamp) return false;

        // 6. Duration range overlap
        {
            uint256 overlapMin = borrower.minDuration > lender.minDuration
                ? borrower.minDuration
                : lender.minDuration;
            uint256 overlapMax = MathLib.min(borrower.maxDuration, lender.maxDuration);
            if (overlapMin > overlapMax) return false;
        }

        // 7. Interest rate compatibility
        if (borrower.maxInterestRateBps < lender.minInterestRateBps) return false;
        if (lender.minInterestRateBps < market.interestRateBps) return false;

        // FIX (Bug #64321): Enforce MAX_INTEREST_RATE_BPS for off-chain intents
        if (lender.minInterestRateBps > MAX_INTEREST_RATE_BPS) return false;
        if (borrower.maxInterestRateBps > MAX_INTEREST_RATE_BPS) return false;

        // 8. LTV bounds validation (matches legacy Internal.sol:179-181)
        if (borrower.minLtvBps < market.ltvBps) return false;
        if (lender.maxLtvBps < market.ltvBps) return false;

        // FIX (Bug #64321): Enforce MAX_LTV_BPS for off-chain intents
        if (lender.maxLtvBps > MAX_LTV_BPS) return false;
        if (borrower.minLtvBps > MAX_LTV_BPS) return false;

        // Borrower's minimum + required gap must not exceed lender's maximum
        if (borrower.minLtvBps + minLtvGapBps > lender.maxLtvBps) return false;

        // 9. Lender available amount
        if (lender.amount <= lender.filledAmount) return false;
        uint256 lenderAvailable = lender.amount - lender.filledAmount;
        if (lenderAvailable < borrower.minFillAmount) return false;

        return true;
    }
}
