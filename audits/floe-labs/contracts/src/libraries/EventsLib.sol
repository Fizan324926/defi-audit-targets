// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

/// @title EventsLib
/// @notice Library containing all event definitions for the protocol
library EventsLib {
    // ============ Market Events ============
    event LogMarketCreated(bytes32 indexed marketId, address indexed loanToken, address indexed collateralToken);
    event LogMarketConfigurationUpdated(bytes32 indexed marketId);
    event LogMarketPauseStatusUpdated(bytes32 indexed marketId);

    // ============ Intent Events ============
    event LogLenderOfferPosted(address indexed lender, bytes32 indexed marketId, bytes32 offerHash);
    event LogBorrowerOfferPosted(address indexed borrower, bytes32 indexed marketId, bytes32 offerHash);
    event LogIntentRevoked(address indexed user, bytes32 indexed marketId, bytes32 indexed offerHash, string role);
    event LogIntentsMatched(
        address indexed lender, address indexed borrower, address indexed matcher, bytes32 marketId, uint256 loanId
    );
    /// @notice Detailed event emitted when loan intents are matched, including intent hashes for full traceability
    /// @dev Emitted in addition to LogIntentsMatched for backward compatibility
    event LogIntentsMatchedDetailed(
        address indexed lender,
        address indexed borrower,
        address indexed matcher,
        bytes32 marketId,
        uint256 loanId,
        bytes32 lendIntentHash,
        bytes32 borrowIntentHash
    );

    // ============ Partial Fill Events ============
    event LendIntentFullyFilled(bytes32 indexed intentHash);
    event LendIntentUpdated(bytes32 indexed lendIntentHash, uint256 newFilledAmount, uint256 remainingAmount);
    event BorrowIntentFilled(bytes32 indexed borrowIntentHash);

    // ============ Loan Events ============
    event LogLoanRepayment(uint256 indexed loanId, uint256 totalRepaid, uint256 protocolFee, uint256 collateralReturned);
    event LogLoanLiquidated(
        uint256 indexed loanId,
        uint256 totalRepaid,
        uint256 protocolFee,
        uint256 collateralSeized,
        uint256 collateralRemaining
    );

    /// @notice Emitted when a loan is liquidated with bad debt (underwater position)
    /// @dev This event is emitted IN ADDITION to LogLoanLiquidated for underwater liquidations
    /// @param loanId The ID of the liquidated loan
    /// @param lender The lender who absorbed the bad debt
    /// @param liquidator The address that executed the liquidation
    /// @param totalOwed Total amount owed to lender (principal + interest - protocol fee)
    /// @param lenderReceived Amount lender actually received
    /// @param badDebtAmount The shortfall absorbed by lender (totalOwed - lenderReceived)
    /// @param collateralSeized Total collateral seized by liquidator
    event LogBadDebtRealized(
        uint256 indexed loanId,
        address indexed lender,
        address indexed liquidator,
        uint256 totalOwed,
        uint256 lenderReceived,
        uint256 badDebtAmount,
        uint256 collateralSeized
    );

    // ============ Collateral Events ============
    event LogCollateralAdded(uint256 indexed loanId, uint256 collateralAmount);
    event LogCollateralWithdrawn(uint256 indexed loanId, uint256 collateralAmount);

    // ============ Flash Loan Events ============
    event LogFlashLoan(address indexed receiver, address indexed token, uint256 amount, uint256 fee);
    event LogFlashloanFeeBpsUpdated(uint256 flashloanFeeBps);

    // ============ Withdrawal Buffer Events ============
    event LogWithdrawalBufferBpsUpdated(uint256 oldBufferBps, uint256 newBufferBps);

    // ============ LTV Gap Events ============
    event LogMinLtvGapBpsUpdated(uint256 oldGapBps, uint256 newGapBps);

    // ============ Protocol Config Events ============
    event LogFeeRecipientUpdated(address indexed feeRecipient);
    event LogPriceOracleUpdated(address indexed priceOracle);
    event LogHookExecutorUpdated(address indexed hookExecutor);
    event LogLogicsManagerUpdated(address indexed logicsManager);
    event GasForCallExactCheckSet(uint32 gasForCallExactCheck);

    // ============ Oracle Events ============
    event LogStalenessTimeoutUpdated(uint256 oldTimeout, uint256 newTimeout);
    event LogAssetPriceSourceUpdated(address indexed asset, address indexed source);
    event LogFallbackOracleUpdated(address indexed fallbackOracle);
    event LogEthUsdPriceFeedUpdated(address indexed ethUsdPriceFeed);
    event LogBaseCurrencySet(address indexed baseCurrency, uint256 baseCurrencyUnit);
    event LogMaxDeviationBpsUpdated(uint256 oldMaxDeviationBps, uint256 newMaxDeviationBps);
    event LogPriceUpdated(address indexed asset, uint256 oldPrice, uint256 newPrice);

    // ============ L2 Sequencer Events ============
    event LogSequencerUptimeFeedUpdated(address indexed oldFeed, address indexed newFeed);
    event LogSequencerGracePeriodUpdated(uint256 oldGracePeriod, uint256 newGracePeriod);

    // ============ Circuit Breaker Events ============
    /// @notice Emitted when circuit breaker is activated
    /// @param reason The reason code (1-6)
    /// @param activatedAt Timestamp of activation
    event CircuitBreakerActivated(uint8 indexed reason, uint256 activatedAt);
    /// @notice Emitted when circuit breaker is reset
    /// @param previousReason The reason that was active
    /// @param resetBy Address that reset (guardian)
    event CircuitBreakerReset(uint8 indexed previousReason, address indexed resetBy);

    // ============ Fallback Oracle Events ============
    event LogPriceFeedIdSet(address indexed asset, bytes32 priceFeedId);
    event LogEthUsdPriceFeedIdSet(bytes32 priceFeedId);
    event LogMaxPriceAgeUpdated(uint256 oldMaxPriceAge, uint256 newMaxPriceAge);
    event LogMaxConfidenceUpdated(uint256 oldMaxConfidence, uint256 newMaxConfidence);

    // ============ Hook Executor Events ============
    event HookExecuted(address indexed target, bool success);
    event HookExecutionFailed(address indexed target, bool success);
    event HookExecutionInsufficientGas(address indexed target, uint256 gasLimit);
    event LendingIntentMatcherUpdated(address indexed oldMatcher, address indexed newMatcher);

    // ============ Upgrade Events ============
    event Initialized(uint8 version);
    event Upgraded(address indexed implementation);

    // ============ Access Control Events (Inherited from OpenZeppelin) ============
    // The following events are NOT defined here but are inherited from OpenZeppelin's
    // AccessControlUpgradeable contract. They are listed here for documentation purposes.
    //
    // From @openzeppelin/contracts-upgradeable/access/IAccessControl.sol:
    //   event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    //   event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);
    //   event RoleAdminChanged(bytes32 indexed role, bytes32 indexed previousAdminRole, bytes32 indexed newAdminRole);
    //
    // These events are automatically emitted by contracts inheriting AccessControlUpgradeable:
    //   - LendingIntentMatcherUpgradeable
    //   - PriceOracleUpgradeable
    //   - HookExecutorUpgradeable
    //   - FallbackPriceOracleUpgradeable
    //
    // Role constants are defined in src/governance/Roles.sol:
    //   - DEFAULT_ADMIN_ROLE (0x00)
    //   - PROTOCOL_ADMIN_ROLE
    //   - ORACLE_ADMIN_ROLE
    //   - UPGRADER_ROLE
    //   - GUARDIAN_ROLE
}
