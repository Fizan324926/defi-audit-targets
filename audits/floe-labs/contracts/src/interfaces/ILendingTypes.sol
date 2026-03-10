// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

/// @dev A user-specified hook to be executed before or after an intent.
/// @param target The address of the contract to call for the hook.
/// @param callData The calldata to be sent to the target contract for the hook execution.
/// @param gasLimit The maximum gas allowed for the hook execution.
/// @param expiry The timestamp after which the hook is no longer valid.
/// @param allowFailure Whether to allow the transaction to continue if the hook fails.
/// @param applyToAllPartialFills Whether to apply this hook to all partial fills.
struct Hook {
    address target;
    bytes callData;
    uint256 gasLimit;
    uint256 expiry;
    bool allowFailure;
    bool applyToAllPartialFills;
}

/// @dev A condition that must be met for an intent to be executed.
/// @param target The address of the contract to call for the condition check.
/// @param callData The calldata to be sent to the target contract for the condition check.
/// @param applyToAllPartialFills Whether to apply this condition to all partial fills.
struct Condition {
    address target;
    bytes callData;
    bool applyToAllPartialFills;
}

/// @dev A user-specified intent to lend funds in a market.
/// @param lender The address of the lender.
/// @param onBehalfOf The address on whose behalf the lending is performed.
/// @param amount The total amount the lender is willing to lend.
/// @param minFillAmount The minimum amount that must be filled.
/// @param filledAmount The amount already filled by borrowers (for partial fills).
/// @param minInterestRateBps The minimum acceptable interest rate (in basis points).
/// @param maxLtvBps The maximum acceptable LTV for liquidation (in basis points).
/// @param minDuration The minimum acceptable loan duration in seconds.
/// @param maxDuration The maximum acceptable loan duration in seconds.
/// @param allowPartialFill Whether the intent can be partially filled.
/// @param validFromTimestamp The timestamp from which the intent becomes valid.
/// @param expiry The timestamp after which the intent is no longer valid.
/// @param marketId The identifier of the market this intent applies to.
/// @param salt A unique value to ensure intent uniqueness and prevent replay.
/// @param conditions Array of conditions that must be met.
/// @param preHooks Array of hooks to be executed before the intent is matched.
/// @param postHooks Array of hooks to be executed after the intent is matched.
struct LendIntent {
    address lender;
    address onBehalfOf;
    uint256 amount;
    uint256 minFillAmount;
    uint256 filledAmount;
    uint256 minInterestRateBps;
    uint256 maxLtvBps;
    uint256 minDuration;
    uint256 maxDuration;
    bool allowPartialFill;
    uint256 validFromTimestamp;
    uint256 expiry;
    bytes32 marketId;
    bytes32 salt;
    Condition[] conditions;
    Hook[] preHooks;
    Hook[] postHooks;
}

/// @dev A user-specified intent to borrow funds in a market.
/// @param borrower The address of the borrower.
/// @param onBehalfOf The address on whose behalf the borrowing is performed.
/// @param borrowAmount The amount the borrower wishes to borrow.
/// @param collateralAmount The amount of collateral to be locked.
/// @param minFillAmount The minimum amount that must be filled.
/// @param maxInterestRateBps The maximum acceptable interest rate (in basis points).
/// @param minLtvBps The minimum LTV ratio for the actual loan (in basis points).
/// @param minDuration The minimum acceptable loan duration in seconds.
/// @param maxDuration The maximum acceptable loan duration in seconds.
/// @param allowPartialFill Whether the intent can be partially filled.
/// @param validFromTimestamp The timestamp from which the intent becomes valid.
/// @param matcherCommissionBps The commission paid to the matcher.
/// @param expiry The timestamp after which the intent is no longer valid.
/// @param marketId The identifier of the market this intent applies to.
/// @param salt A unique value to ensure intent uniqueness and prevent replay.
/// @param conditions Array of conditions that must be met.
/// @param preHooks Array of hooks to be executed before the intent is matched.
/// @param postHooks Array of hooks to be executed after the intent is matched.
struct BorrowIntent {
    address borrower;
    address onBehalfOf;
    uint256 borrowAmount;
    uint256 collateralAmount;
    uint256 minFillAmount;
    uint256 maxInterestRateBps;
    uint256 minLtvBps;
    uint256 minDuration;
    uint256 maxDuration;
    bool allowPartialFill;
    uint256 validFromTimestamp;
    uint256 matcherCommissionBps;
    uint256 expiry;
    bytes32 marketId;
    bytes32 salt;
    Condition[] conditions;
    Hook[] preHooks;
    Hook[] postHooks;
}

/// @dev Pause statuses for various market actions.
/// @param isAddCollateralPaused Whether adding collateral is paused.
/// @param isBorrowPaused Whether borrowing is paused.
/// @param isWithdrawCollateralPaused Whether withdrawing collateral is paused.
/// @param isRepayPaused Whether loan repayment is paused.
/// @param isLiquidatePaused Whether loan liquidation is paused.
struct PauseStatuses {
    bool isAddCollateralPaused;
    bool isBorrowPaused;
    bool isWithdrawCollateralPaused;
    bool isRepayPaused;
    bool isLiquidatePaused;
}

/// @dev A unique market.
/// @param marketId The unique identifier for the market.
/// @param loanToken The address of the token to be lent.
/// @param collateralToken The address of the token used as collateral.
/// @param interestRateBps Minimum interest rate in basis points.
/// @param ltvBps Minimum loan-to-value ratio in basis points.
/// @param liquidationIncentiveBps Liquidation incentive in basis points.
/// @param marketFeeBps Market fee in basis points.
/// @param totalPrincipalOutstanding Total principal of active loans.
/// @param totalLoans Total number of loans created in this market.
/// @param lastUpdateAt Timestamp of the last update to the market.
/// @param pauseStatuses Pause statuses for various market actions.
struct Market {
    bytes32 marketId;
    address loanToken;
    address collateralToken;
    uint256 interestRateBps;
    uint256 ltvBps;
    uint256 liquidationIncentiveBps;
    uint256 marketFeeBps;
    uint256 totalPrincipalOutstanding;
    uint256 totalLoans;
    uint128 lastUpdateAt;
    PauseStatuses pauseStatuses;
}

/// @dev A unique loan position.
/// @param marketId The identifier of the market.
/// @param loanId The unique identifier for this loan.
/// @param lender The address of the lender.
/// @param borrower The address of the borrower.
/// @param loanToken The address of the token lent.
/// @param collateralToken The address of the token used as collateral.
/// @param principal The principal amount of the loan.
/// @param interestRateBps The interest rate in basis points.
/// @param ltvBps The loan-to-value ratio in basis points at origination.
/// @param liquidationLtvBps The liquidation threshold LTV in basis points.
/// @param marketFeeBps The market fee in basis points.
/// @param matcherCommissionBps The matcher commission in basis points.
/// @param startTime The timestamp when the loan was originated.
/// @param duration The duration of the loan in seconds.
/// @param collateralAmount The amount of collateral locked.
/// @param repaid Whether the loan has been fully repaid.
struct Loan {
    bytes32 marketId;
    uint256 loanId;
    address lender;
    address borrower;
    address loanToken;
    address collateralToken;
    uint256 principal;
    uint256 interestRateBps;
    uint256 ltvBps;
    uint256 liquidationLtvBps;
    uint256 marketFeeBps;
    uint256 matcherCommissionBps;
    uint256 startTime;
    uint256 duration;
    uint256 collateralAmount;
    bool repaid;
}

/// @dev Parameters for matching loan intents
struct MatchLoanParams {
    LendIntent lender;
    bytes lenderSig;
    BorrowIntent borrower;
    bytes borrowerSig;
    bytes32 marketId;
    bool isLenderOnChain;
    bool isBorrowerOnChain;
    bytes32 domainSeparator;
    bytes32 lenderIntentTypehash;
    bytes32 borrowerIntentTypehash;
    bytes32 conditionTypehash;
    bytes32 hookTypehash;
}

/// @dev Context struct for matching operations to reduce stack depth
struct MatchContext {
    bytes32 lendIntentHash;
    bytes32 borrowIntentHash;
    uint256 fillAmount;
    uint256 requiredCollateral;
    uint256 loanLtvBps;
    uint256 previousFilledAmount;
    uint256 totalFilledAfter;
    uint256 remainingAmount;
    bool shouldMarkLenderUsed;
}

/// @dev Quote for a potential liquidation, used by off-chain systems (bot, web app)
/// @param loanId The ID of the loan being quoted
/// @param isUnderwater True if collateral value < debt + liquidation bonus
/// @param requiresFullLiquidation True if underwater (partial liquidation not allowed)
/// @param repayAmount Principal amount being repaid
/// @param interestAmount Interest portion of the repayment
/// @param totalLiquidatorPays Total amount liquidator must pay (may differ from repay+interest if underwater)
/// @param collateralToReceive Amount of collateral tokens liquidator receives
/// @param collateralValueReceived Value of collateral in loan token terms
/// @param lenderReceives Amount lender receives (may be less than owed if underwater)
/// @param protocolFeeAmount Protocol fee deducted
/// @param liquidatorProfit Guaranteed profit for liquidator in loan token terms
/// @param liquidatorProfitBps Profit as basis points of liquidator payment
/// @param badDebtAmount Bad debt amount (0 if solvent, positive if underwater)
struct LiquidationQuote {
    uint256 loanId;
    bool isUnderwater;
    bool requiresFullLiquidation;
    uint256 repayAmount;
    uint256 interestAmount;
    uint256 totalLiquidatorPays;
    uint256 collateralToReceive;
    uint256 collateralValueReceived;
    uint256 lenderReceives;
    uint256 protocolFeeAmount;
    uint256 liquidatorProfit;
    uint256 liquidatorProfitBps;
    uint256 badDebtAmount;
}
