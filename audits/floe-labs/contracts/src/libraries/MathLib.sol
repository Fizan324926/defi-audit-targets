// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8;

library MathLib {
    function getFillAmount(
        uint256 lenderAvailableAmount,
        uint256 lenderMinFillAmount,
        uint256 borrowerRequestedAmount,
        uint256 borrowerMinFillAmount,
        bool lenderAllowPartialFill,
        bool borrowerAllowPartialFill
    ) internal pure returns (uint256) {
        // If minFillAmount is zero, treat as 'no partial fill wanted'
        if (lenderMinFillAmount == 0) lenderAllowPartialFill = false;
        if (borrowerMinFillAmount == 0) borrowerAllowPartialFill = false;

        // FIX (Bug #64298): When BOTH parties don't allow partial fill, require exact match
        // Previously, the borrower check (line 18) would return early without checking lender's preference
        if (!borrowerAllowPartialFill && !lenderAllowPartialFill) {
            // Both want all-or-nothing: amounts must match exactly
            if (borrowerRequestedAmount == lenderAvailableAmount) {
                return borrowerRequestedAmount;
            }
            return 0; // Incompatible - both want all-or-nothing but amounts differ
        }

        // If ONLY borrower does not allow partial fill (lender is flexible)
        // Lender must provide full borrow amount and lender's min fill must be satisfied
        if (!borrowerAllowPartialFill) {
            if (lenderAvailableAmount >= borrowerRequestedAmount && lenderMinFillAmount <= borrowerRequestedAmount) {
                return borrowerRequestedAmount;
            } else {
                return 0;
            }
        }

        // If ONLY lender does not allow partial fill (borrower is flexible)
        // Borrower must take exactly lender's full amount and borrower's min fill must be satisfied
        if (!lenderAllowPartialFill) {
            if (borrowerRequestedAmount >= lenderAvailableAmount && borrowerMinFillAmount <= lenderAvailableAmount) {
                return lenderAvailableAmount;
            } else {
                return 0;
            }
        }
        // Both allow partial fill: min(lenderAvailable, borrowerRequested), must satisfy both min fill constraints
        uint256 maxFill = min(lenderAvailableAmount, borrowerRequestedAmount);
        uint256 minFill = lenderMinFillAmount > borrowerMinFillAmount ? lenderMinFillAmount : borrowerMinFillAmount;
        if (maxFill < minFill) return 0;
        return maxFill;
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
