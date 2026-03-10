// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

/// @title ErrorsLib
/// @notice Library containing all custom error definitions for the protocol
library ErrorsLib {
    // ============ Intent Errors ============
    error IntentExpired();
    error IntentAlreadyUsed();
    error IntentNotOnChain();
    /// @notice Thrown when off-chain path is used for an intent that exists on-chain
    error IntentAlreadyRegisteredOnChain();
    error IncompatibleIntents();
    /// @notice Thrown when intent marketId doesn't match execution marketId
    error MarketIdMismatch();
    error InvalidSignature();
    error FilledAmountOutOfBounds();
    error FilledAmountExceedsLenderAmount();
    error FillAmountBelowMin();
    error MinFillAmountOutOfBounds();
    error ValidFromAfterExpiry();
    error ValidFromInPast();
    error IntentNotYetValid();
    error DurationMismatch();
    error MinDurationExceedsMax();
    error InterestRateMismatch();
    error LtvMismatch();
    error Overfill();
    error ZeroFillAmount();
    /// @notice Thrown when calculated collateral exceeds borrower's intent cap
    error RequiredCollateralExceedsIntentCap();

    // ============ Market Errors ============
    error MarketAlreadyCreated();
    error MarketNotCreated();

    // ============ Loan Errors ============
    error LoanRepaid();
    error RepayAmountOutOfBounds();
    error MaxRepaymentExceeded();
    error HealthyLoanPosition();
    error UnhealthyLoanPosition();
    error InsufficientCollateral();

    /// @notice Thrown when attempting partial liquidation on an underwater loan
    /// @dev Underwater loans (where collateral < debt + liquidation bonus) must be fully liquidated
    /// to prevent gaming where liquidator takes all collateral while only repaying partial debt
    error PartialLiquidationNotAllowedWhenUnderwater();

    // ============ Oracle Errors ============
    error InvalidPrice();
    error InvalidPriceScale();
    error StalePriceData();
    error PriceDeviationTooHigh(address asset, uint256 currentPrice, uint256 lastPrice, uint256 deviationBps);

    // ============ L2 Sequencer Errors ============
    /// @notice Thrown when the L2 sequencer is currently down
    error SequencerDown();
    /// @notice Thrown when the L2 sequencer recently came back up and is still in grace period
    /// @param timeRemaining Seconds remaining until grace period ends
    error SequencerGracePeriodNotOver(uint256 timeRemaining);

    // ============ Access Control Errors ============
    error UnauthorisedCaller();
    error ZeroAddress();

    // ============ Parameter Validation Errors ============
    error ArrayLengthMismatch();
    error ZeroAmount();
    error LtvOutOfBounds();
    error InterestRateNotSet();
    error InterestRateOutOfBounds();
    error RateOutOfBounds();
    error FeeOutOfBounds();
    error IncentiveOutOfBounds();
    error WithdrawalBufferOutOfBounds();
    error MinLtvGapOutOfBounds();

    // ============ Protocol Errors ============
    error HookExecutorNotSet();
    error HookExecutorAlreadySet();
    error GasForCallExactCheckAlreadySet();
    error ConditionEvaluationFailed();
    error InsufficientLiquidity();
    error FlashLoanNotRepaidWithFee();

    // ============ Hook Executor Errors ============
    error NotLendingIntentMatcher();
    error HookExecutionFailed(address target);
    error HookExecutionInsufficientGas(address target, uint256 gasLimit);

    // ============ Pause Errors ============
    error LiquidationPaused();
    error AddCollateralPaused();
    error RepayPaused();
    error BorrowPaused();
    error WithdrawCollateralPaused();

    // ============ Circuit Breaker Errors ============
    /// @notice Thrown when operation attempted while circuit breaker is active
    /// @param reason The reason code (1=SequencerDown, 2=SequencerGracePeriod, 3=BothFeedsFailed, 4=DeviationExceeded, 5=EthUsdFeedFailed, 6=GuardianTriggered)
    error CircuitBreakerActive(uint8 reason);
    /// @notice Thrown when trying to reset circuit breaker that isn't active
    error CircuitBreakerNotActive();
    /// @notice Thrown when both Chainlink and fallback oracle fail for an asset
    /// @param asset The asset address that failed
    error BothOraclesFailed(address asset);

    // ============ Upgrade Errors ============
    error AlreadyInitialized();
    error NotInitialized();
}
