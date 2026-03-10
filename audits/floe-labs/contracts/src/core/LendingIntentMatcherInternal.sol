// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {LendingStorageLib} from "../storage/LendingStorage.sol";
import {Loan} from "../interfaces/ILendingTypes.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import "../libraries/ConstantsLib.sol";

/// @title LendingIntentMatcherInternal
/// @notice Internal implementation functions for LendingIntentMatcherUpgradeable
/// @dev Contains all internal functions separated for cleaner code organization
/// @dev This abstract contract has NO storage of its own - all storage access goes through ERC-7201 namespaced storage
abstract contract LendingIntentMatcherInternal {
    using LendingStorageLib for LendingStorageLib.LendingStorage;

    /// @notice Returns the EIP-712 domain separator
    /// @dev Must be implemented by the inheriting contract
    function domainSeparator() public view virtual returns (bytes32);

    // ============ Internal Functions ============

    function _isHealthy(uint256 loanId) internal view returns (bool) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        Loan memory loan = $.loans[loanId];

        if (loan.repaid) return true;

        uint256 price = IPriceOracle($.priceOracle).getPrice(loan.collateralToken, loan.loanToken);
        if (price == 0) return false;

        uint256 collateralValue = (loan.collateralAmount * price) / ORACLE_PRICE_SCALE;
        if (collateralValue == 0) return false;

        // Include accrued interest in LTV calculation (inline for memory param)
        (uint256 accruedInterest,) = _accruedInterest(loan);
        uint256 totalDebt = loan.principal + accruedInterest;
        uint256 ltvBpsCurrent = (totalDebt * BASIS_POINTS) / collateralValue;

        bool isOverdue = block.timestamp > loan.startTime + loan.duration;
        bool isUndercollateralized = ltvBpsCurrent >= loan.liquidationLtvBps;

        return !isOverdue && !isUndercollateralized;
    }

    function _accruedInterest(Loan memory loan) internal view returns (uint256 interest, uint256 timeElapsed) {
        if (loan.repaid) return (0, 0);
        timeElapsed = block.timestamp - loan.startTime;
        interest = (loan.principal * loan.interestRateBps * timeElapsed) / (BASIS_POINTS * 365 days);
    }
}
