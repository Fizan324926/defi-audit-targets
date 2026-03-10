// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {LendIntent, BorrowIntent, MatchLoanParams} from "./ILendingTypes.sol";

/// @title ILendingLogicsManager
/// @notice Interface for the LendingLogicsManager contract that handles delegated logic
interface ILendingLogicsManager {
    /// @notice Implements the match loan intents logic
    function matchLoanIntentsLogic(MatchLoanParams calldata params) external returns (uint256 loanId);

    /// @notice Implements the repay loan logic
    function repayLoanLogic(uint256 loanId, uint256 repayAmount, uint256 maxTotalRepayment) external;

    /// @notice Implements the liquidate loan logic
    function liquidateLoanLogic(uint256 loanId, uint256 repayAmount, uint256 maxTotalRepayment) external;

    /// @notice Implements the liquidate loan with callback logic
    function liquidateWithCallbackLogic(
        uint256 loanId,
        uint256 repayAmount,
        uint256 maxTotalRepayment,
        bytes calldata data
    ) external;

    /// @notice Implements the add collateral logic
    function addCollateralLogic(uint256 loanId, uint256 amount) external;

    /// @notice Implements the withdraw collateral logic
    function withdrawCollateralLogic(uint256 loanId, uint256 amount) external;

    /// @notice Implements the register lend intent logic
    function registerLendIntentLogic(
        LendIntent calldata intent,
        bytes32 domainSeparator,
        bytes32 lenderIntentTypehash,
        bytes32 conditionTypehash,
        bytes32 hookTypehash
    ) external;

    /// @notice Implements the revoke lend intent logic
    function revokeLendIntentByHashLogic(bytes32 intentHash) external;

    /// @notice Implements the register borrow intent logic
    function registerBorrowIntentLogic(
        BorrowIntent calldata intent,
        bytes32 domainSeparator,
        bytes32 borrowerIntentTypehash,
        bytes32 conditionTypehash,
        bytes32 hookTypehash
    ) external;

    /// @notice Implements the revoke borrow intent logic
    function revokeBorrowIntentByHashLogic(bytes32 intentHash) external;

    /// @notice Implements the flash loan logic
    function flashLoanLogic(address token, uint256 amount, bytes calldata data) external;

    /// @notice Implements the create market logic
    function createMarketLogic(
        address loanToken,
        address collateralToken,
        uint256 interestRateBps,
        uint256 ltvBps,
        uint256 marketFeeBps,
        uint256 liquidationIncentiveBps
    ) external returns (bytes32 marketId);

    // ============ Setter Logic Functions ============

    /// @notice Implements the set market logic
    function setMarketLogic(
        bytes32 marketId,
        uint256 interestRateBps,
        uint256 ltvBps,
        uint256 marketFeeBps,
        uint256 liquidationIncentiveBps
    ) external;

    /// @notice Implements the set pause status logic
    function setPauseStatusLogic(
        bytes32 marketId,
        bool isAddCollateralPaused,
        bool isBorrowPaused,
        bool isWithdrawCollateralPaused,
        bool isRepayPaused,
        bool isLiquidatePaused
    ) external;
}
