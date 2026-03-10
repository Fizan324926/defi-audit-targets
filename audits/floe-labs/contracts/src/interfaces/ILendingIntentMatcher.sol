// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {LendIntent, BorrowIntent, Market, Loan} from "./ILendingTypes.sol";
import {IGetters} from "./IGetters.sol";
import {ISetters} from "./ISetters.sol";
import {IStorage} from "./IStorage.sol";

/// @title ILendingIntentMatcher
/// @notice Interface for the LendingIntentMatcher contract
/// @dev Inherits from IGetters, ISetters, and IStorage for complete interface coverage
interface ILendingIntentMatcher is IGetters, ISetters, IStorage {
    // ============ Market Functions ============
    function createMarket(
        address loanToken,
        address collateralToken,
        uint256 interestRateBps,
        uint256 ltvBps,
        uint256 marketFeeBps,
        uint256 liquidationIncentiveBps
    ) external returns (bytes32 marketId);

    // ============ Intent Matching ============
    function matchLoanIntents(
        LendIntent calldata lender,
        bytes calldata lenderSig,
        BorrowIntent calldata borrower,
        bytes calldata borrowerSig,
        bytes32 marketId,
        bool isLenderOnChain,
        bool isBorrowerOnChain
    ) external returns (uint256 loanId);

    // ============ Intent Registration ============
    function registerLendIntent(LendIntent calldata intent) external;
    function revokeLendIntentByHash(bytes32 intentHash) external;
    function registerBorrowIntent(BorrowIntent calldata intent) external;
    function revokeBorrowIntentByHash(bytes32 intentHash) external;

    // ============ Loan Operations ============
    function repayLoan(uint256 loanId, uint256 repayAmount, uint256 maxTotalRepayment) external;
    function liquidateLoan(uint256 loanId, uint256 repayAmount, uint256 maxTotalRepayment) external;
    function liquidateWithCallback(
        uint256 loanId,
        uint256 repayAmount,
        uint256 maxTotalRepayment,
        bytes calldata data
    ) external;
    function addCollateral(uint256 loanId, uint256 amount) external;
    function withdrawCollateral(uint256 loanId, uint256 amount) external;

    // ============ Flash Loans ============
    function flashLoan(address token, uint256 amount, bytes calldata data) external;

    // ============ View Functions ============
    function isHealthy(uint256 loanId) external view returns (bool);
    // NOTE: canMatchLoanIntents moved to LendingViewsUpgradeable to reduce main contract size
    // NOTE: validateIntents moved to LendingViewsUpgradeable to reduce main contract size
    function hashLenderIntent(LendIntent calldata lenderIntent) external view returns (bytes32);
    function hashBorrowerIntent(BorrowIntent calldata borrowerIntent) external view returns (bytes32);
    function domainSeparator() external view returns (bytes32);
}
