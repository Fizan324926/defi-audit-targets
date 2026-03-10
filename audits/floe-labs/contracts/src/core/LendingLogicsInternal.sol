// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {LendingStorageLib} from "../storage/LendingStorage.sol";
import {
    LendIntent,
    BorrowIntent,
    Market,
    Loan,
    Hook,
    Condition,
    MatchLoanParams,
    MatchContext,
    PauseStatuses
} from "../interfaces/ILendingTypes.sol";
import {IConditionValidator} from "../interfaces/IConditionValidator.sol";
import {IHookExecutor} from "../interfaces/IHookExecutor.sol";
import {IFlashloanReceiver} from "../interfaces/IFlashloanReceiver.sol";
import {ILiquidationCallback} from "../interfaces/ILiquidationCallback.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {EventsLib} from "../libraries/EventsLib.sol";
import {IntentLib} from "../libraries/IntentLib.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MathLib} from "../libraries/MathLib.sol";
import {ValidationLib} from "../libraries/ValidationLib.sol";
import {MatchValidationLib} from "../libraries/MatchValidationLib.sol";
import "../libraries/ConstantsLib.sol";

/// @title LendingLogicsInternal
/// @notice Internal implementation functions for LendingLogicsManager
/// @dev Contains all internal functions separated for cleaner code organization
abstract contract LendingLogicsInternal {
    using SafeERC20 for IERC20;
    using LendingStorageLib for LendingStorageLib.LendingStorage;

    // ============ Internal Implementation Functions ============

    /// @notice FIXED: Match loan intents with proper partial fill support
    function _matchLoanIntents(MatchLoanParams calldata params) internal returns (uint256 loanId) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();

        // Evaluate conditions
        _evaluateConditions(params.lender.conditions);
        _evaluateConditions(params.borrower.conditions);

        // Validate intents & signatures
        (bytes32 lendIntentHash, bytes32 borrowIntentHash) = _validateIntentsForMatch(params);

        // Use MatchContext struct to reduce stack depth
        MatchContext memory ctx;
        ctx.lendIntentHash = lendIntentHash;
        ctx.borrowIntentHash = borrowIntentHash;

        // Get the stored filled amount for lender intents
        if (params.isLenderOnChain) {
            ctx.previousFilledAmount = $.onChainLendIntents[lendIntentHash].filledAmount;
        } else {
            // FIX (Bug #64228): Read from storage instead of calldata for off-chain intents
            // This enables partial fill tracking for off-chain intents
            ctx.previousFilledAmount = $.offChainLendIntentFilledAmount[lendIntentHash];
        }

        // Calculate fill amount
        uint256 lenderAvailable = params.lender.amount - ctx.previousFilledAmount;
        ctx.fillAmount = MathLib.getFillAmount(
            lenderAvailable,
            params.lender.minFillAmount,
            params.borrower.borrowAmount,
            params.borrower.minFillAmount,
            params.lender.allowPartialFill,
            params.borrower.allowPartialFill
        );

        // SECURITY: Explicit zero fill check to prevent zero-principal loans
        // MathLib.getFillAmount can return 0 when intents are incompatible
        if (ctx.fillAmount == 0) {
            revert ErrorsLib.ZeroFillAmount();
        }

        if (ctx.fillAmount < params.lender.minFillAmount || ctx.fillAmount < params.borrower.minFillAmount) {
            revert ErrorsLib.FillAmountBelowMin();
        }

        // Calculate remaining after this fill
        ctx.totalFilledAfter = ctx.previousFilledAmount + ctx.fillAmount;

        // SECURITY: Explicit bounds check to prevent over-fills (defense in depth)
        // This should never trigger if MathLib is correct, but provides a hard safety boundary
        if (ctx.totalFilledAfter > params.lender.amount) {
            revert ErrorsLib.Overfill();
        }

        ctx.remainingAmount = params.lender.amount - ctx.totalFilledAfter;

        // Get market for token addresses
        Market storage market = $.markets[params.marketId];

        // Validate price deviation before any price-dependent operations
        // This reverts if price has deviated too much from last valid price
        _validatePriceDeviation(market.collateralToken, market.loanToken);

        // FIX: Use borrower's minLtvBps directly (not min of lender/borrower)
        ctx.loanLtvBps = params.borrower.minLtvBps;
        ctx.requiredCollateral = _getRequiredCollateralAmount(params.marketId, ctx.fillAmount, ctx.loanLtvBps);

        // FIX Issue #16 (FLO-310): Enforce borrower's collateral cap from signed intent
        // The borrower specifies a maximum collateral amount they're willing to provide.
        // Due to oracle price drift between signing and execution, the calculated
        // requiredCollateral could exceed this cap. This check ensures the borrower's
        // signed intent is respected.
        if (ctx.requiredCollateral > params.borrower.collateralAmount) {
            revert ErrorsLib.RequiredCollateralExceedsIntentCap();
        }

        // Execute pre-hooks
        _executeHooks(params.lender.preHooks);
        _executeHooks(params.borrower.preHooks);

        // Record the loan
        loanId = _recordLoan(
            params.lender,
            params.borrower,
            market.loanToken,
            market.collateralToken,
            market.marketFeeBps,
            params.borrower.matcherCommissionBps,
            ctx.fillAmount,
            ctx.requiredCollateral,
            ctx.lendIntentHash,
            ctx.borrowIntentHash
        );

        // Transfer assets
        _transferAssets(
            params.marketId,
            params.lender,
            params.borrower,
            market.collateralToken,
            market.loanToken,
            ctx.fillAmount,
            ctx.requiredCollateral
        );

        // ============ FIXED PARTIAL FILL LOGIC ============
        // Handle lender intent state based on fill status
        if (params.isLenderOnChain) {
            // Update filledAmount for on-chain lender intents
            $.onChainLendIntents[lendIntentHash].filledAmount = ctx.totalFilledAfter;

            // Determine if intent should be marked as used
            bool isFullyFilled = ctx.remainingAmount == 0;
            bool belowMinFill = ctx.remainingAmount < params.lender.minFillAmount;
            ctx.shouldMarkLenderUsed = isFullyFilled || belowMinFill || !params.lender.allowPartialFill;

            if (ctx.shouldMarkLenderUsed) {
                $.usedIntentHashes[lendIntentHash] = true;
                emit EventsLib.LendIntentFullyFilled(lendIntentHash);
            } else {
                // Intent still has remaining amount for future matches
                emit EventsLib.LendIntentUpdated(lendIntentHash, ctx.totalFilledAfter, ctx.remainingAmount);
            }
        } else {
            // FIX (Bug #64228): Track off-chain fills in storage and apply partial fill logic
            // This enables partial fill support for off-chain intents, preventing griefing attacks
            // where an attacker could invalidate a large intent with a minimal fill.
            $.offChainLendIntentFilledAmount[lendIntentHash] = ctx.totalFilledAfter;

            // Apply same partial fill logic as on-chain
            bool isFullyFilled = ctx.remainingAmount == 0;
            bool belowMinFill = ctx.remainingAmount < params.lender.minFillAmount;
            ctx.shouldMarkLenderUsed = isFullyFilled || belowMinFill || !params.lender.allowPartialFill;

            if (ctx.shouldMarkLenderUsed) {
                $.usedIntentHashes[lendIntentHash] = true;
                emit EventsLib.LendIntentFullyFilled(lendIntentHash);
            } else {
                // Intent still has remaining amount for future matches
                emit EventsLib.LendIntentUpdated(lendIntentHash, ctx.totalFilledAfter, ctx.remainingAmount);
            }
        }

        // Borrower intent: always mark as used (single match per borrower intent)
        $.usedIntentHashes[borrowIntentHash] = true;
        emit EventsLib.BorrowIntentFilled(borrowIntentHash);

        // Execute post-hooks
        _executeHooks(params.lender.postHooks);
        _executeHooks(params.borrower.postHooks);
    }

    function _validateIntentsForMatch(MatchLoanParams calldata params)
        internal
        view
        returns (bytes32 lendIntentHash, bytes32 borrowIntentHash)
    {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();

        // ZeroAddress checks (kept here - specific to execution path)
        if (params.lender.lender == address(0)) revert ErrorsLib.ZeroAddress();
        if (params.borrower.borrower == address(0)) revert ErrorsLib.ZeroAddress();

        // Load market for validation
        Market storage market = $.markets[params.marketId];

        // Use shared library for core compatibility checks
        // This ensures view and execution paths have identical validation
        MatchValidationLib.validateMatchCompatibility(
            params.lender,
            params.borrower,
            params.marketId,
            market,
            block.timestamp,
            $.minLtvGapBps
        );

        // Hash computation
        lendIntentHash = IntentLib.hashLender(
            params.lender,
            params.domainSeparator,
            params.lenderIntentTypehash,
            params.conditionTypehash,
            params.hookTypehash
        );
        borrowIntentHash = IntentLib.hashBorrower(
            params.borrower,
            params.domainSeparator,
            params.borrowerIntentTypehash,
            params.conditionTypehash,
            params.hookTypehash
        );

        // Check used intent hashes - with special handling for partial fills
        if (params.isLenderOnChain && params.lender.allowPartialFill) {
            // For partial-fill enabled on-chain intents, check BOTH:
            // 1. filledAmount >= amount (fully filled)
            // 2. usedIntentHashes (marked as used when remaining < minFillAmount)
            LendIntent storage storedIntent = $.onChainLendIntents[lendIntentHash];
            if (storedIntent.filledAmount >= storedIntent.amount || $.usedIntentHashes[lendIntentHash]) {
                revert ErrorsLib.IntentAlreadyUsed();
            }
        } else {
            // SECURITY FIX (Bug #64109): Prevent on-chain → off-chain replay attack
            // If an intent was registered on-chain, it MUST be matched via the on-chain path
            // to ensure the storage-tracked filledAmount is respected.
            // Only check this when the caller claims the intent is off-chain (isLenderOnChain=false).
            // When isLenderOnChain=true but allowPartialFill=false, we're in this else branch
            // but the intent legitimately exists on-chain.
            if (!params.isLenderOnChain && $.onChainLendIntents[lendIntentHash].lender != address(0)) {
                revert ErrorsLib.IntentAlreadyRegisteredOnChain();
            }
            if ($.usedIntentHashes[lendIntentHash]) {
                revert ErrorsLib.IntentAlreadyUsed();
            }
        }

        if ($.usedIntentHashes[borrowIntentHash]) {
            revert ErrorsLib.IntentAlreadyUsed();
        }

        // Verify on-chain or signature
        if (params.isLenderOnChain) {
            if ($.onChainLendIntents[lendIntentHash].lender == address(0)) {
                revert ErrorsLib.IntentNotOnChain();
            }
        } else {
            if (!IntentLib.verifySignature(lendIntentHash, params.lender.lender, params.lenderSig)) {
                revert ErrorsLib.InvalidSignature();
            }
        }

        if (params.isBorrowerOnChain) {
            if ($.onChainBorrowIntents[borrowIntentHash].borrower == address(0)) {
                revert ErrorsLib.IntentNotOnChain();
            }
        } else {
            if (!IntentLib.verifySignature(borrowIntentHash, params.borrower.borrower, params.borrowerSig)) {
                revert ErrorsLib.InvalidSignature();
            }
        }
    }

    function _evaluateConditions(Condition[] memory conditions) internal view {
        for (uint256 i = 0; i < conditions.length; ++i) {
            bool success = IConditionValidator(conditions[i].target).validateCondition(conditions[i].callData);
            if (!success) revert ErrorsLib.ConditionEvaluationFailed();
        }
    }

    function _executeHooks(Hook[] memory hooks) internal {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        if (hooks.length > 0) {
            if ($.hookExecutor == address(0)) revert ErrorsLib.HookExecutorNotSet();
            IHookExecutor($.hookExecutor).execute(hooks);
        }
    }

    function _transferAssets(
        bytes32, // marketId - unused, tokens passed directly
        LendIntent calldata lender,
        BorrowIntent calldata borrower,
        address collateralToken,
        address loanToken,
        uint256 fillAmount,
        uint256 requiredCollateralAmount
    ) internal {
        // Transfer collateral from borrower to contract
        IERC20(collateralToken).safeTransferFrom(borrower.borrower, address(this), requiredCollateralAmount);

        // Calculate matcher commission
        uint256 matcherCommission = (fillAmount * borrower.matcherCommissionBps) / BASIS_POINTS;
        uint256 netLoanAmount = fillAmount - matcherCommission;

        // Transfer net loan amount from lender to loan recipient
        address loanRecipient = borrower.onBehalfOf != address(0) ? borrower.onBehalfOf : borrower.borrower;
        IERC20(loanToken).safeTransferFrom(lender.lender, loanRecipient, netLoanAmount);

        // Transfer matcher commission to the solver
        if (matcherCommission > 0) {
            IERC20(loanToken).safeTransferFrom(lender.lender, msg.sender, matcherCommission);
        }
    }

    function _recordLoan(
        LendIntent calldata lender,
        BorrowIntent calldata borrower,
        address loanToken,
        address collateralToken,
        uint256 protocolFeeBps,
        uint256 matcherCommissionBps,
        uint256 fillAmount,
        uint256 collateralAmount,
        bytes32 lendIntentHash,
        bytes32 borrowIntentHash
    ) internal returns (uint256 loanId) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();

        loanId = ++$.loanCounter;
        bytes32 marketId = keccak256(abi.encodePacked(loanToken, collateralToken));

        $.loans[loanId] = Loan({
            marketId: marketId,
            loanId: loanId,
            lender: lender.lender,
            borrower: borrower.borrower,
            loanToken: loanToken,
            collateralToken: collateralToken,
            principal: fillAmount,
            interestRateBps: borrower.maxInterestRateBps,
            ltvBps: borrower.minLtvBps,
            liquidationLtvBps: lender.maxLtvBps,
            marketFeeBps: protocolFeeBps,
            matcherCommissionBps: matcherCommissionBps,
            startTime: block.timestamp,
            duration: MathLib.min(borrower.maxDuration, lender.maxDuration),
            collateralAmount: collateralAmount,
            repaid: false
        });

        $.userToLoanIds[borrower.borrower].push(loanId);
        $.userToLoanIds[lender.lender].push(loanId);

        Market storage market = $.markets[marketId];
        market.totalLoans++;
        market.totalPrincipalOutstanding += fillAmount;
        market.lastUpdateAt = uint128(block.timestamp);

        emit EventsLib.LogIntentsMatched(lender.lender, borrower.borrower, msg.sender, marketId, loanId);
        emit EventsLib.LogIntentsMatchedDetailed(
            lender.lender,
            borrower.borrower,
            msg.sender,
            marketId,
            loanId,
            lendIntentHash,
            borrowIntentHash
        );
    }

    function _repayLoan(uint256 loanId, uint256 repayAmount, uint256 maxTotalRepayment) internal {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        Loan storage loan = $.loans[loanId];

        if (loan.borrower != msg.sender) revert ErrorsLib.UnauthorisedCaller();
        if (loan.repaid) revert ErrorsLib.LoanRepaid();

        uint256 principal = loan.principal;
        uint256 marketFeeBps = loan.marketFeeBps;
        uint256 collateralAmount = loan.collateralAmount;
        address loanToken = loan.loanToken;
        address collateralToken = loan.collateralToken;

        if (repayAmount == 0 || repayAmount > principal) {
            revert ErrorsLib.RepayAmountOutOfBounds();
        }

        (uint256 totalInterest,) = _accruedInterest(loan);

        // Use mulDiv for full precision: (totalInterest * repayAmount) / principal
        uint256 interestToPay = Math.mulDiv(totalInterest, repayAmount, principal);
        uint256 totalToRepay = repayAmount + interestToPay;

        if (totalToRepay > maxTotalRepayment) revert ErrorsLib.MaxRepaymentExceeded();

        // Use mulDiv for fees and collateral
        uint256 protocolFee = Math.mulDiv(interestToPay, marketFeeBps, BASIS_POINTS);
        uint256 netInterest = interestToPay - protocolFee;
        uint256 lenderPayment = repayAmount + netInterest;
        uint256 collateralToReturn = Math.mulDiv(collateralAmount, repayAmount, principal);

        loan.principal -= repayAmount;
        loan.collateralAmount -= collateralToReturn;

        if (loan.principal == 0) {
            loan.repaid = true;
        }

        bytes32 marketId = loan.marketId;
        Market storage market = $.markets[marketId];
        market.totalPrincipalOutstanding -= repayAmount;
        market.lastUpdateAt = uint128(block.timestamp);

        IERC20(loanToken).safeTransferFrom(loan.borrower, loan.lender, lenderPayment);

        if (protocolFee > 0) {
            IERC20(loanToken).safeTransferFrom(loan.borrower, $.feeRecipient, protocolFee);
        }

        IERC20(collateralToken).safeTransfer(loan.borrower, collateralToReturn);

        emit EventsLib.LogLoanRepayment(loanId, totalToRepay, protocolFee, collateralToReturn);
    }

    // ============ Liquidation Shared Data ============

    /// @dev Intermediate data returned by _prepareLiquidation, consumed by transfer/event logic.
    ///      repayAmount is NOT included: it is fully consumed within _prepareLiquidation
    ///      (interest calc, underwater check, principal reduction, market stats) and its effects
    ///      are baked into the derived values here.
    struct LiquidationParams {
        address loanToken;
        address collateralToken;
        address lender;
        uint256 collateralToSeize;
        uint256 actualLiquidatorPays;
        uint256 actualLenderPayment;
        uint256 actualProtocolFee;
        bool isUnderwater;
        uint256 badDebtAmount;
        uint256 expectedLenderPayment;
    }

    // ============ Liquidation Functions ============

    function _liquidateLoan(uint256 loanId, uint256 repayAmount, uint256 maxTotalRepayment) internal {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        Loan storage loan = $.loans[loanId];

        LiquidationParams memory p = _prepareLiquidation(loanId, repayAmount, maxTotalRepayment);

        // Transfers: PULL first, then SEND (original order)
        IERC20(p.loanToken).safeTransferFrom(msg.sender, p.lender, p.actualLenderPayment);
        if (p.actualProtocolFee > 0) {
            IERC20(p.loanToken).safeTransferFrom(msg.sender, $.feeRecipient, p.actualProtocolFee);
        }
        IERC20(p.collateralToken).safeTransfer(msg.sender, p.collateralToSeize);

        _emitLiquidationEvents(loanId, loan.collateralAmount, p);
    }

    function _liquidateWithCallback(
        uint256 loanId,
        uint256 repayAmount,
        uint256 maxTotalRepayment,
        bytes calldata data
    ) internal {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        Loan storage loan = $.loans[loanId];

        LiquidationParams memory p = _prepareLiquidation(loanId, repayAmount, maxTotalRepayment);

        // Transfers: SEND collateral FIRST (optimistic transfer)
        IERC20(p.collateralToken).safeTransfer(msg.sender, p.collateralToSeize);

        // Callback: let liquidator swap collateral to loan tokens
        if (data.length > 0) {
            ILiquidationCallback(msg.sender).onLiquidationCallback(
                loanId,
                p.collateralToken,
                p.collateralToSeize,
                p.loanToken,
                p.actualLiquidatorPays,
                data
            );
        }

        // PULL payment (reverts if liquidator doesn't have enough after swap)
        IERC20(p.loanToken).safeTransferFrom(msg.sender, p.lender, p.actualLenderPayment);
        if (p.actualProtocolFee > 0) {
            IERC20(p.loanToken).safeTransferFrom(msg.sender, $.feeRecipient, p.actualProtocolFee);
        }

        _emitLiquidationEvents(loanId, loan.collateralAmount, p);
    }

    /// @dev Shared liquidation logic: pre-checks, calculations, and state mutations.
    ///      IMPORTANT: This function MUTATES storage (loan.principal, loan.collateralAmount,
    ///      loan.repaid, market.totalPrincipalOutstanding, market.lastUpdateAt).
    ///      After calling this, any `Loan storage` reference to the same loan will reflect
    ///      post-mutation values. The `lender` field in the returned struct is safe to use
    ///      because it is never mutated by liquidation state updates.
    function _prepareLiquidation(
        uint256 loanId,
        uint256 repayAmount,
        uint256 maxTotalRepayment
    ) private returns (LiquidationParams memory params) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        Loan storage loan = $.loans[loanId];

        // Pre-checks
        if (loan.repaid) revert ErrorsLib.LoanRepaid();
        if (_isHealthy(loanId)) revert ErrorsLib.HealthyLoanPosition();

        uint256 principal = loan.principal;
        params.loanToken = loan.loanToken;
        params.collateralToken = loan.collateralToken;
        params.lender = loan.lender;

        // Validate price deviation before liquidation
        _validatePriceDeviation(params.collateralToken, params.loanToken);

        (uint256 totalInterest,) = _accruedInterest(loan);
        if (repayAmount == 0 || repayAmount > principal) {
            revert ErrorsLib.RepayAmountOutOfBounds();
        }

        // Get market and price data
        bytes32 marketId = keccak256(abi.encodePacked(params.loanToken, params.collateralToken));
        Market storage market = $.markets[marketId];
        uint256 price = _getValidatedPrice($.priceOracle, params.collateralToken, params.loanToken);
        uint256 liquidationIncentiveBps = market.liquidationIncentiveBps;

        // Determine if the loan is underwater (scoped to free stack slots)
        {
            uint256 fullRepayment = principal + totalInterest;
            uint256 fullCollateralEquivalent = (fullRepayment * ORACLE_PRICE_SCALE) / price;
            uint256 fullLiquidationBonus = (fullCollateralEquivalent * liquidationIncentiveBps) / BASIS_POINTS;
            params.isUnderwater = (fullCollateralEquivalent + fullLiquidationBonus) > loan.collateralAmount;
        }

        // Use mulDiv for full precision: (totalInterest * repayAmount) / principal
        uint256 interestPortion = Math.mulDiv(totalInterest, repayAmount, principal);
        uint256 totalRepayment = repayAmount + interestPortion;

        // Calculate intended collateral seizure with bonus for this repayment
        uint256 collateralEquivalent = (totalRepayment * ORACLE_PRICE_SCALE) / price;
        uint256 liquidationBonus = Math.mulDiv(collateralEquivalent, liquidationIncentiveBps, BASIS_POINTS);
        params.collateralToSeize = collateralEquivalent + liquidationBonus;

        if (params.isUnderwater) {
            // ============ UNDERWATER LIQUIDATION ============
            // Underwater loans MUST be fully liquidated to prevent gaming
            // (liquidator taking all collateral while only repaying partial debt)
            if (repayAmount != principal) {
                revert ErrorsLib.PartialLiquidationNotAllowedWhenUnderwater();
            }

            // Liquidator gets all remaining collateral
            params.collateralToSeize = loan.collateralAmount;

            // Calculate collateral value in loan token terms
            uint256 collateralValue = (params.collateralToSeize * price) / ORACLE_PRICE_SCALE;

            // Liquidator pays: collateralValue / (1 + bonus%) to guarantee their profit
            // This ensures liquidator always makes approximately liquidationIncentiveBps profit
            params.actualLiquidatorPays = Math.mulDiv(collateralValue, BASIS_POINTS, BASIS_POINTS + liquidationIncentiveBps);

            // Protocol fee: still calculated on interest portion only (consistent with normal liquidations)
            // This ensures protocol doesn't profit from bad debt at lender's expense
            uint256 normalProtocolFee = Math.mulDiv(interestPortion, loan.marketFeeBps, BASIS_POINTS);

            // Cap protocol fee to ensure it doesn't exceed what liquidator pays
            // (safety check; in practice, protocol fee << liquidator payment)
            params.actualProtocolFee = normalProtocolFee > params.actualLiquidatorPays ? params.actualLiquidatorPays : normalProtocolFee;

            // Lender receives: what liquidator pays minus protocol fee
            params.actualLenderPayment = params.actualLiquidatorPays - params.actualProtocolFee;

            // Calculate expected payment and bad debt
            // Expected = principal + netInterest (what lender would get in normal liquidation)
            uint256 netInterest = interestPortion - params.actualProtocolFee;
            params.expectedLenderPayment = repayAmount + netInterest;
            params.badDebtAmount = params.expectedLenderPayment > params.actualLenderPayment
                ? params.expectedLenderPayment - params.actualLenderPayment
                : 0;
        } else {
            // ============ SOLVENT LIQUIDATION ============
            params.actualProtocolFee = Math.mulDiv(interestPortion, loan.marketFeeBps, BASIS_POINTS);
            uint256 netInterest = interestPortion - params.actualProtocolFee;
            params.actualLenderPayment = repayAmount + netInterest;
            params.actualLiquidatorPays = totalRepayment;
            params.badDebtAmount = 0;
            params.expectedLenderPayment = params.actualLenderPayment; // In solvent case, expected == actual
        }

        // FIX (Bug #64482): Check AFTER calculating actualLiquidatorPays
        // In underwater scenarios, actualLiquidatorPays < totalRepayment, so checking
        // totalRepayment would block valid liquidations with reasonable slippage protection
        if (params.actualLiquidatorPays > maxTotalRepayment) {
            revert ErrorsLib.MaxRepaymentExceeded();
        }

        // ============ STATE UPDATES ============
        // All mutations before any external calls (CEI compliance)
        loan.principal -= repayAmount;
        loan.collateralAmount -= params.collateralToSeize;

        if (loan.principal == 0) {
            loan.repaid = true;
        }

        market.totalPrincipalOutstanding -= repayAmount;
        market.lastUpdateAt = uint128(block.timestamp);
    }

    /// @dev Shared event emission for both liquidation paths
    function _emitLiquidationEvents(
        uint256 loanId,
        uint256 collateralRemaining,
        LiquidationParams memory p
    ) private {
        emit EventsLib.LogLoanLiquidated(
            loanId,
            p.actualLiquidatorPays,
            p.actualProtocolFee,
            p.collateralToSeize,
            collateralRemaining
        );

        if (p.isUnderwater) {
            emit EventsLib.LogBadDebtRealized(
                loanId,
                p.lender,
                msg.sender,
                p.expectedLenderPayment,
                p.actualLenderPayment,
                p.badDebtAmount,
                p.collateralToSeize
            );
        }
    }

    function _addCollateral(uint256 loanId, uint256 amount) internal {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        Loan storage loan = $.loans[loanId];

        if (loan.borrower != msg.sender) revert ErrorsLib.UnauthorisedCaller();
        if (loan.repaid) revert ErrorsLib.LoanRepaid();
        if (amount == 0) revert ErrorsLib.ZeroAmount();

        loan.collateralAmount += amount;

        IERC20(loan.collateralToken).safeTransferFrom(msg.sender, address(this), amount);

        $.markets[loan.marketId].lastUpdateAt = uint128(block.timestamp);

        emit EventsLib.LogCollateralAdded(loanId, amount);
    }

    function _withdrawCollateral(uint256 loanId, uint256 amount) internal {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        Loan storage loan = $.loans[loanId];

        // Pre-checks moved from main contract
        if (loan.borrower != msg.sender) revert ErrorsLib.UnauthorisedCaller();
        if (amount == 0) revert ErrorsLib.ZeroAmount();
        if (amount > loan.collateralAmount) revert ErrorsLib.InsufficientCollateral();

        // For active loans with outstanding principal, validate health and price before withdrawal
        if (loan.principal != 0) {
            if (loan.repaid) revert ErrorsLib.LoanRepaid();
            _validateWithdrawalHealth(loanId, amount);
            // Validate price deviation before withdrawal
            // This reverts if price has deviated too much from last valid price
            // FIX (Bug #66399): Only check when loan has outstanding debt.
            // When principal == 0 (fully repaid via solvent liquidation), the borrower
            // owns the remaining collateral unconditionally and price is irrelevant.
            _validatePriceDeviation(loan.collateralToken, loan.loanToken);
        }

        loan.collateralAmount -= amount;

        IERC20(loan.collateralToken).safeTransfer(msg.sender, amount);

        $.markets[loan.marketId].lastUpdateAt = uint128(block.timestamp);

        emit EventsLib.LogCollateralWithdrawn(loanId, amount);
    }

    function _flashLoan(address token, uint256 amount, bytes calldata data) internal {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();

        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        if (amount > balanceBefore) {
            revert ErrorsLib.InsufficientLiquidity();
        }

        uint256 fee = (amount * $.flashloanFeeBps) / BASIS_POINTS;

        IERC20(token).safeTransfer(msg.sender, amount);

        IFlashloanReceiver(msg.sender).receiveFlashLoan(token, amount, fee, data);

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount + fee);

        if (fee > 0) {
            IERC20(token).safeTransfer($.feeRecipient, fee);
        }

        // Post-balance check: catches fee-on-transfer tokens that silently reduce
        // the actual amount received, which would drain collateral held for active loans.
        if (IERC20(token).balanceOf(address(this)) < balanceBefore) {
            revert ErrorsLib.FlashLoanNotRepaidWithFee();
        }

        emit EventsLib.LogFlashLoan(msg.sender, token, amount, fee);
    }

    function _registerLendIntent(
        LendIntent calldata intent,
        bytes32 domainSeparator,
        bytes32 lenderIntentTypehash,
        bytes32 conditionTypehash,
        bytes32 hookTypehash
    ) internal {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();

        address lender = intent.lender;
        if (msg.sender != lender) revert ErrorsLib.UnauthorisedCaller();

        bytes32 lendIntentHash =
            IntentLib.hashLender(intent, domainSeparator, lenderIntentTypehash, conditionTypehash, hookTypehash);

        _validateLenderIntentRegistration(intent, lendIntentHash);
        $.registeredIntentHashes[lendIntentHash] = true;

        $.onChainLendIntents[lendIntentHash] = intent;
        emit EventsLib.LogLenderOfferPosted(lender, intent.marketId, lendIntentHash);
    }

    function _revokeLendIntentByHash(bytes32 intentHash) internal {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        LendIntent storage onChainIntent = $.onChainLendIntents[intentHash];

        if (onChainIntent.marketId == bytes32(0)) revert ErrorsLib.IntentNotOnChain();
        address lender = onChainIntent.lender;
        if (lender == address(0)) revert ErrorsLib.IntentNotOnChain();
        if (msg.sender != lender) revert ErrorsLib.UnauthorisedCaller();
        if (block.timestamp > onChainIntent.expiry) revert ErrorsLib.IntentExpired();

        // FIX: Check if already used to prevent revoking used intents
        if ($.usedIntentHashes[intentHash]) revert ErrorsLib.IntentAlreadyUsed();

        // FIX: Mark as used to prevent re-registration
        $.usedIntentHashes[intentHash] = true;

        bytes32 marketId = onChainIntent.marketId;
        delete $.onChainLendIntents[intentHash];
        emit EventsLib.LogIntentRevoked(msg.sender, marketId, intentHash, "lender");
    }

    function _registerBorrowIntent(
        BorrowIntent calldata intent,
        bytes32 domainSeparator,
        bytes32 borrowerIntentTypehash,
        bytes32 conditionTypehash,
        bytes32 hookTypehash
    ) internal {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();

        address borrower = intent.borrower;
        if (msg.sender != borrower) revert ErrorsLib.UnauthorisedCaller();

        bytes32 borrowIntentHash =
            IntentLib.hashBorrower(intent, domainSeparator, borrowerIntentTypehash, conditionTypehash, hookTypehash);

        _validateBorrowerIntentRegistration(intent, borrowIntentHash);
        $.registeredIntentHashes[borrowIntentHash] = true;

        $.onChainBorrowIntents[borrowIntentHash] = intent;
        emit EventsLib.LogBorrowerOfferPosted(borrower, intent.marketId, borrowIntentHash);
    }

    function _revokeBorrowIntentByHash(bytes32 intentHash) internal {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        BorrowIntent storage onChainIntent = $.onChainBorrowIntents[intentHash];

        if (onChainIntent.marketId == bytes32(0)) revert ErrorsLib.IntentNotOnChain();
        if (msg.sender != onChainIntent.borrower) revert ErrorsLib.UnauthorisedCaller();
        if (block.timestamp > onChainIntent.expiry) revert ErrorsLib.IntentExpired();

        // FIX: Check if already used
        if ($.usedIntentHashes[intentHash]) revert ErrorsLib.IntentAlreadyUsed();

        // FIX: Mark as used to prevent re-registration
        $.usedIntentHashes[intentHash] = true;

        bytes32 marketId = onChainIntent.marketId;
        delete $.onChainBorrowIntents[intentHash];
        emit EventsLib.LogIntentRevoked(msg.sender, marketId, intentHash, "borrower");
    }

    // ============ Internal Helper Functions ============

    function _accruedInterest(Loan storage loan) internal view returns (uint256 interest, uint256 timeElapsed) {
        if (loan.repaid) return (0, 0);
        timeElapsed = block.timestamp - loan.startTime;
        interest = (loan.principal * loan.interestRateBps * timeElapsed) / (BASIS_POINTS * 365 days);
    }

    function _getValidatedPrice(address priceOracle, address collateralToken, address loanToken)
        internal
        view
        returns (uint256 price)
    {
        price = IPriceOracle(priceOracle).getPrice(collateralToken, loanToken);
        if (price == 0) revert ErrorsLib.InvalidPrice();
    }

    /// @notice Validates price deviation for a token pair before state-changing operations
    /// @dev Calls getPriceChecked which reverts if deviation exceeds threshold
    /// @param collateralToken The collateral token address
    /// @param loanToken The loan token address
    function _validatePriceDeviation(address collateralToken, address loanToken) internal {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        // getPriceChecked validates deviation and updates last valid price
        // Reverts with PriceDeviationTooHigh if deviation exceeds threshold
        IPriceOracle($.priceOracle).getPriceChecked(collateralToken, loanToken);
    }

    /// @notice Checks if a loan is healthy (not overdue and not undercollateralized)
    /// @param loanId The loan ID to check
    /// @return True if the loan is healthy, false otherwise
    function _isHealthy(uint256 loanId) internal view returns (bool) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        Loan storage loan = $.loans[loanId];

        if (loan.repaid) return true;

        uint256 price = IPriceOracle($.priceOracle).getPrice(loan.collateralToken, loan.loanToken);
        if (price == 0) return false;

        uint256 collateralValue = (loan.collateralAmount * price) / ORACLE_PRICE_SCALE;
        if (collateralValue == 0) return false;

        // Include accrued interest in LTV calculation
        (uint256 accruedInterest,) = _accruedInterest(loan);
        uint256 totalDebt = loan.principal + accruedInterest;
        uint256 ltvBpsCurrent = (totalDebt * BASIS_POINTS) / collateralValue;

        bool isOverdue = block.timestamp > loan.startTime + loan.duration;
        bool isUndercollateralized = ltvBpsCurrent >= loan.liquidationLtvBps;

        return !isOverdue && !isUndercollateralized;
    }

    /// @notice Validates that a collateral withdrawal won't make the loan unhealthy
    /// @param loanId The loan ID
    /// @param withdrawAmount The amount to withdraw
    function _validateWithdrawalHealth(uint256 loanId, uint256 withdrawAmount) internal view {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        Loan storage loan = $.loans[loanId];

        if (block.timestamp > loan.startTime + loan.duration) {
            revert ErrorsLib.UnhealthyLoanPosition();
        }

        uint256 newCollateralAmount = loan.collateralAmount - withdrawAmount;
        uint256 price = IPriceOracle($.priceOracle).getPrice(loan.collateralToken, loan.loanToken);
        if (price == 0) revert ErrorsLib.InvalidPrice();

        uint256 newCollateralValue = (newCollateralAmount * price) / ORACLE_PRICE_SCALE;
        if (newCollateralValue == 0) revert ErrorsLib.UnhealthyLoanPosition();

        // Include accrued interest in LTV calculation
        (uint256 accruedInterest,) = _accruedInterest(loan);
        uint256 totalDebt = loan.principal + accruedInterest;
        uint256 newLtvBps = (totalDebt * BASIS_POINTS) / newCollateralValue;

        // Apply withdrawal buffer: users can only withdraw up to (liquidationLtvBps - bufferBps)
        uint256 maxAllowedLtvBps = loan.liquidationLtvBps > $.withdrawalBufferBps
            ? loan.liquidationLtvBps - $.withdrawalBufferBps
            : 0;
        bool wouldBeUndercollateralized = newLtvBps >= maxAllowedLtvBps;

        if (wouldBeUndercollateralized) {
            revert ErrorsLib.UnhealthyLoanPosition();
        }
    }

    function _getRequiredCollateralAmount(bytes32 marketId, uint256 borrowAmount, uint256 customLtvBps)
        internal
        view
        returns (uint256 requiredCollateralAmount)
    {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        Market storage market = $.markets[marketId];
        uint256 ltvToUse = customLtvBps != 0 ? customLtvBps : market.ltvBps;
        uint256 price = _getValidatedPrice($.priceOracle, market.collateralToken, market.loanToken);

        uint256 denominator = price * ltvToUse;
        uint256 numerator = borrowAmount * ORACLE_PRICE_SCALE * BASIS_POINTS;
        requiredCollateralAmount = numerator / denominator;
    }

    function _validateLenderIntentRegistration(LendIntent memory intent, bytes32 hash) internal view {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        ValidationLib.validateIntent(
            intent.amount,
            intent.expiry,
            intent.minFillAmount,
            0,
            intent.maxLtvBps,
            intent.minInterestRateBps,
            intent.validFromTimestamp,
            intent.filledAmount,
            intent.minDuration,
            intent.maxDuration,
            intent.allowPartialFill,
            hash,
            $.registeredIntentHashes,
            false,
            0,
            MAX_LTV_BPS,
            MAX_INTEREST_RATE_BPS,
            MAX_PROTOCOL_FEE_BPS
        );

        // Validate against market-specific parameters to prevent unmatchable intents
        Market storage market = $.markets[intent.marketId];
        if (market.loanToken == address(0)) revert ErrorsLib.MarketNotCreated();

        // Lender's minimum interest rate must be >= market minimum
        // Otherwise the intent can never be matched (matching requires lender.minInterestRateBps >= market.interestRateBps)
        if (intent.minInterestRateBps < market.interestRateBps) {
            revert ErrorsLib.RateOutOfBounds();
        }

        // Lender's max LTV must be >= market minimum LTV
        // Otherwise the intent can never be matched
        if (intent.maxLtvBps < market.ltvBps) {
            revert ErrorsLib.LtvOutOfBounds();
        }
    }

    function _validateBorrowerIntentRegistration(BorrowIntent memory intent, bytes32 hash) internal view {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        ValidationLib.validateIntent(
            intent.borrowAmount,
            intent.expiry,
            intent.minFillAmount,
            intent.minLtvBps,
            0,
            intent.maxInterestRateBps,
            intent.validFromTimestamp,
            0,
            intent.minDuration,
            intent.maxDuration,
            intent.allowPartialFill,
            hash,
            $.registeredIntentHashes,
            true,
            intent.matcherCommissionBps,
            MAX_LTV_BPS,
            MAX_INTEREST_RATE_BPS,
            MAX_PROTOCOL_FEE_BPS
        );

        // Validate against market-specific parameters to prevent unmatchable intents
        Market storage market = $.markets[intent.marketId];
        if (market.loanToken == address(0)) revert ErrorsLib.MarketNotCreated();

        // Borrower's maximum interest rate must be >= market minimum
        // Otherwise the intent can never be matched (matching requires borrower.maxInterestRateBps >= lender.minInterestRateBps >= market.interestRateBps)
        if (intent.maxInterestRateBps < market.interestRateBps) {
            revert ErrorsLib.RateOutOfBounds();
        }

        // Borrower's minimum LTV must be >= market minimum LTV
        // Otherwise the intent can never be matched
        if (intent.minLtvBps < market.ltvBps) {
            revert ErrorsLib.LtvOutOfBounds();
        }

        // Borrower's minLtvBps + required gap must not exceed protocol maximum
        // Otherwise no lender can ever match (they'd need maxLtvBps > MAX_LTV_BPS)
        // Example: If borrower wants 90% LTV and gap is 8%, lender needs >= 98% which exceeds 90% max
        if (intent.minLtvBps + $.minLtvGapBps > MAX_LTV_BPS) {
            revert ErrorsLib.LtvOutOfBounds();
        }
    }

    /// @notice Creates a new lending market
    /// @param loanToken The token to be lent
    /// @param collateralToken The token to be used as collateral
    /// @param interestRateBps The interest rate in basis points
    /// @param ltvBps The loan-to-value ratio in basis points
    /// @param marketFeeBps The market fee in basis points
    /// @param liquidationIncentiveBps The liquidation incentive in basis points
    /// @return marketId The unique identifier for the created market
    function _createMarket(
        address loanToken,
        address collateralToken,
        uint256 interestRateBps,
        uint256 ltvBps,
        uint256 marketFeeBps,
        uint256 liquidationIncentiveBps
    ) internal returns (bytes32 marketId) {
        if (loanToken == collateralToken) revert ErrorsLib.InvalidPrice();
        if (ltvBps == 0 || ltvBps > MAX_LTV_BPS || ltvBps > BASIS_POINTS) revert ErrorsLib.LtvOutOfBounds();
        if (interestRateBps == 0) revert ErrorsLib.InterestRateNotSet();
        if (liquidationIncentiveBps == 0 || liquidationIncentiveBps > MAX_LIQUIDATION_INCENTIVE_BPS) {
            revert ErrorsLib.IncentiveOutOfBounds();
        }
        if (marketFeeBps > MAX_PROTOCOL_FEE_BPS) revert ErrorsLib.FeeOutOfBounds();

        marketId = keccak256(abi.encodePacked(loanToken, collateralToken));

        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        if ($.markets[marketId].loanToken != address(0)) revert ErrorsLib.MarketAlreadyCreated();

        _getValidatedPrice($.priceOracle, collateralToken, loanToken);

        $.markets[marketId] = Market({
            marketId: marketId,
            loanToken: loanToken,
            collateralToken: collateralToken,
            interestRateBps: interestRateBps,
            ltvBps: ltvBps,
            liquidationIncentiveBps: liquidationIncentiveBps,
            marketFeeBps: marketFeeBps,
            totalPrincipalOutstanding: 0,
            totalLoans: 0,
            lastUpdateAt: uint128(block.timestamp),
            pauseStatuses: PauseStatuses({
                isAddCollateralPaused: false,
                isBorrowPaused: false,
                isWithdrawCollateralPaused: false,
                isRepayPaused: false,
                isLiquidatePaused: false
            })
        });

        $.marketsCreated.push(marketId);

        emit EventsLib.LogMarketCreated(marketId, loanToken, collateralToken);
    }
}
