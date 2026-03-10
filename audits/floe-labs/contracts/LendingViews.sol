// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Roles} from "../governance/Roles.sol";

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Market, Loan, LiquidationQuote, LendIntent, BorrowIntent} from "../interfaces/ILendingTypes.sol";
import {IGetters} from "../interfaces/IGetters.sol";
import {IStorage} from "../interfaces/IStorage.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {IntentLib} from "../libraries/IntentLib.sol";
import {MatchValidationLib} from "../libraries/MatchValidationLib.sol";
import {ValidationLib} from "../libraries/ValidationLib.sol";
import {MathLib} from "../libraries/MathLib.sol";
import "../libraries/ConstantsLib.sol";

/// @title LendingViewsUpgradeable
/// @notice UUPS upgradeable contract for complex view functions
/// @dev Separated from main contract to reduce bytecode size while maintaining stable address
/// @dev Reads data via external calls to LendingIntentMatcher contract
/// @dev Used by web apps, auto-matchers, and liquidation bots for underwater detection
contract LendingViewsUpgradeable is Initializable, UUPSUpgradeable, AccessControlUpgradeable {
    // ============ ERC-7201 Storage ============
    /// @custom:storage-location erc7201:floe.storage.LendingViews
    struct LendingViewsStorage {
        /// @dev The address of the LendingIntentMatcher contract to read data from
        IGetters lendingMatcher;
        /// @dev Reserved for future upgrades (50 slots standard)
        uint256[50] __gap;
    }

    /// @dev Computed via: keccak256(abi.encode(uint256(keccak256("floe.storage.LendingViews")) - 1)) & ~bytes32(uint256(0xff))
    /// @dev Verified by: script/utils/ComputeSlots.s.sol
    bytes32 private constant LENDING_VIEWS_STORAGE_SLOT =
        0x8453380d7aefbec9ebad96486273a4a6b2e38df01b67853e129ce6f67d6abe00;

    function _getLendingViewsStorage() private pure returns (LendingViewsStorage storage $) {
        assembly {
            $.slot := LENDING_VIEWS_STORAGE_SLOT
        }
    }

    // ============ Constructor ============
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============
    /// @notice Initializes the upgradeable lending views contract
    /// @param admin_ The default admin address (can grant/revoke roles)
    /// @param protocolAdmin_ The protocol admin address (can update lendingMatcher)
    /// @param upgrader_ The upgrader address (should be TimelockController)
    /// @param lendingMatcher_ The address of the LendingIntentMatcher contract
    function initialize(
        address admin_,
        address protocolAdmin_,
        address upgrader_,
        address lendingMatcher_
    ) external initializer {
        if (lendingMatcher_ == address(0)) revert ErrorsLib.ZeroAddress();

        __AccessControl_init();
        __UUPSUpgradeable_init();

        // Grant roles
        _grantRole(Roles.DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(Roles.PROTOCOL_ADMIN_ROLE, protocolAdmin_);
        _grantRole(Roles.UPGRADER_ROLE, upgrader_);

        LendingViewsStorage storage $ = _getLendingViewsStorage();
        $.lendingMatcher = IGetters(lendingMatcher_);
    }

    // ============ Upgrade Authorization ============
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(Roles.UPGRADER_ROLE) {}

    // ============ Admin Functions ============
    /// @notice Updates the lending matcher address (for disaster recovery)
    /// @param newLendingMatcher The new LendingIntentMatcher address
    function setLendingMatcher(address newLendingMatcher) external onlyRole(Roles.PROTOCOL_ADMIN_ROLE) {
        if (newLendingMatcher == address(0)) revert ErrorsLib.ZeroAddress();
        LendingViewsStorage storage $ = _getLendingViewsStorage();
        $.lendingMatcher = IGetters(newLendingMatcher);
    }

    // ============ Getters ============
    /// @notice Returns the lending matcher address this contract reads from
    function getLendingMatcher() external view returns (address) {
        LendingViewsStorage storage $ = _getLendingViewsStorage();
        return address($.lendingMatcher);
    }

    // ============ View Functions ============

    /// @notice Determines if two intents can be matched
    /// @dev Moved from LendingIntentMatcher to reduce contract size
    /// @param lender The lender intent
    /// @param borrower The borrower intent
    /// @param marketId The market ID
    /// @return True if the intents can be matched
    function canMatchLoanIntents(LendIntent calldata lender, BorrowIntent calldata borrower, bytes32 marketId)
        external
        view
        returns (bool)
    {
        LendingViewsStorage storage $ = _getLendingViewsStorage();
        IGetters matcher = $.lendingMatcher;

        Market memory market = matcher.getMarket(marketId);
        uint256 minLtvGapBps = matcher.getMinLtvGapBps();

        // Use shared library for core compatibility checks
        if (!MatchValidationLib.canMatch(lender, borrower, marketId, market, block.timestamp, minLtvGapBps)) {
            return false;
        }

        // Per-intent field validation (parity with on-chain registration checks)
        ValidationLib.validateIntentFields(
            lender.amount, lender.expiry, lender.minFillAmount, 0, lender.maxLtvBps,
            lender.minInterestRateBps, lender.validFromTimestamp, lender.filledAmount,
            lender.minDuration, lender.maxDuration, lender.allowPartialFill,
            false, 0, MAX_LTV_BPS, MAX_INTEREST_RATE_BPS, MAX_PROTOCOL_FEE_BPS
        );
        ValidationLib.validateIntentFields(
            borrower.borrowAmount, borrower.expiry, borrower.minFillAmount, borrower.minLtvBps, 0,
            borrower.maxInterestRateBps, borrower.validFromTimestamp, 0,
            borrower.minDuration, borrower.maxDuration, borrower.allowPartialFill,
            true, borrower.matcherCommissionBps, MAX_LTV_BPS, MAX_INTEREST_RATE_BPS, MAX_PROTOCOL_FEE_BPS
        );

        // Price validation
        uint256 price = matcher.getPrice(market.collateralToken, market.loanToken);
        if (price == 0) return false;

        // Fill amount calculation
        uint256 lenderAvailable = lender.amount - lender.filledAmount;
        uint256 fillAmount = MathLib.getFillAmount(
            lenderAvailable,
            lender.minFillAmount,
            borrower.borrowAmount,
            borrower.minFillAmount,
            lender.allowPartialFill,
            borrower.allowPartialFill
        );
        if (fillAmount == 0) return false;

        // Collateral sufficiency check
        uint256 requiredCollateral = matcher.getRequiredCollateralAmount(marketId, fillAmount, borrower.minLtvBps);
        if (borrower.collateralAmount < requiredCollateral) return false;

        return true;
    }

    /// @notice Validates intents and returns their hashes
    /// @dev Moved from LendingIntentMatcherUpgradeable to reduce main contract size.
    /// Replicates the same validation: expiry, used/on-chain checks, signature verification, compatibility.
    /// @param lender The lender intent
    /// @param lenderSig The lender's signature (ignored if isLenderOnChain)
    /// @param borrower The borrower intent
    /// @param borrowerSig The borrower's signature (ignored if isBorrowerOnChain)
    /// @param marketId The market ID
    /// @param isLenderOnChain Whether the lender intent is registered on-chain
    /// @param isBorrowerOnChain Whether the borrower intent is registered on-chain
    /// @return lendIntentHash The EIP-712 hash of the lender intent
    /// @return borrowIntentHash The EIP-712 hash of the borrower intent
    function validateIntents(
        LendIntent calldata lender,
        bytes calldata lenderSig,
        BorrowIntent calldata borrower,
        bytes calldata borrowerSig,
        bytes32 marketId,
        bool isLenderOnChain,
        bool isBorrowerOnChain
    ) external view returns (bytes32 lendIntentHash, bytes32 borrowIntentHash) {
        if (lender.lender == address(0)) revert ErrorsLib.ZeroAddress();
        if (borrower.borrower == address(0)) revert ErrorsLib.ZeroAddress();

        LendingViewsStorage storage $ = _getLendingViewsStorage();
        IGetters matcher = $.lendingMatcher;
        IStorage storageIface = IStorage(address(matcher));

        // 1. Expiry
        uint256 nowTs = block.timestamp;
        if (nowTs > lender.expiry || nowTs > borrower.expiry) {
            revert ErrorsLib.IntentExpired();
        }

        // 2. Hash intents
        bytes32 domSep = matcher.domainSeparator();
        lendIntentHash = IntentLib.hashLender(
            lender, domSep, LENDER_INTENT_TYPEHASH, CONDITION_TYPEHASH, HOOK_TYPEHASH
        );
        borrowIntentHash = IntentLib.hashBorrower(
            borrower, domSep, BORROWER_INTENT_TYPEHASH, CONDITION_TYPEHASH, HOOK_TYPEHASH
        );

        // 2b. Per-intent field validation (parity with on-chain registration checks)
        ValidationLib.validateIntentFields(
            lender.amount, lender.expiry, lender.minFillAmount, 0, lender.maxLtvBps,
            lender.minInterestRateBps, lender.validFromTimestamp, lender.filledAmount,
            lender.minDuration, lender.maxDuration, lender.allowPartialFill,
            false, 0, MAX_LTV_BPS, MAX_INTEREST_RATE_BPS, MAX_PROTOCOL_FEE_BPS
        );
        ValidationLib.validateIntentFields(
            borrower.borrowAmount, borrower.expiry, borrower.minFillAmount, borrower.minLtvBps, 0,
            borrower.maxInterestRateBps, borrower.validFromTimestamp, 0,
            borrower.minDuration, borrower.maxDuration, borrower.allowPartialFill,
            true, borrower.matcherCommissionBps, MAX_LTV_BPS, MAX_INTEREST_RATE_BPS, MAX_PROTOCOL_FEE_BPS
        );

        // 3. Check used intent hashes and resolve storage-based filledAmount
        // The execution path reads filledAmount from storage (not calldata) to prevent
        // stale values. We mirror that here for each case.
        uint256 lenderStorageFilledAmount;
        if (isLenderOnChain && lender.allowPartialFill) {
            // On-chain partial fill: read stored intent for current filledAmount.
            // Check fully filled OR marked as used (remaining < minFillAmount after a previous match).
            LendIntent memory storedIntent = matcher.getOnChainLendIntent(lendIntentHash);
            lenderStorageFilledAmount = storedIntent.filledAmount;
            if (storedIntent.filledAmount >= storedIntent.amount || storageIface.isIntentUsed(lendIntentHash)) {
                revert ErrorsLib.IntentAlreadyUsed();
            }
        } else {
            // Off-chain partial fill: read from dedicated storage mapping
            if (!isLenderOnChain && lender.allowPartialFill) {
                lenderStorageFilledAmount = matcher.getOffChainLendIntentFilledAmount(lendIntentHash);
            }
            // lenderStorageFilledAmount remains 0 for non-partial fills (consumed in one match)

            // Prevent on-chain to off-chain replay attack (Bug #64109 parity).
            // An intent registered on-chain must be matched via the on-chain path
            // to ensure storage-tracked filledAmount is respected.
            if (!isLenderOnChain && storageIface.isLendIntentOnChain(lendIntentHash)) {
                revert ErrorsLib.IntentAlreadyRegisteredOnChain();
            }
            if (storageIface.isIntentUsed(lendIntentHash)) {
                revert ErrorsLib.IntentAlreadyUsed();
            }
        }

        if (storageIface.isIntentUsed(borrowIntentHash)) {
            revert ErrorsLib.IntentAlreadyUsed();
        }

        // 4. Verify on-chain status or signatures
        if (isLenderOnChain) {
            if (!storageIface.isLendIntentOnChain(lendIntentHash)) revert ErrorsLib.IntentNotOnChain();
        } else {
            if (!IntentLib.verifySignature(lendIntentHash, lender.lender, lenderSig)) {
                revert ErrorsLib.InvalidSignature();
            }
        }

        if (isBorrowerOnChain) {
            if (!storageIface.isBorrowIntentOnChain(borrowIntentHash)) revert ErrorsLib.IntentNotOnChain();
        } else {
            if (!IntentLib.verifySignature(borrowIntentHash, borrower.borrower, borrowerSig)) {
                revert ErrorsLib.InvalidSignature();
            }
        }

        // 5. Compatibility check (reverts if incompatible)
        Market memory market = matcher.getMarket(marketId);
        uint256 minLtvGapBps = matcher.getMinLtvGapBps();
        MatchValidationLib.validateMatchCompatibility(lender, borrower, marketId, market, nowTs, minLtvGapBps);

        // 6. Price and collateral sufficiency
        uint256 price = matcher.getPrice(market.collateralToken, market.loanToken);
        if (price == 0) revert ErrorsLib.InvalidPrice();

        uint256 lenderAvailable = lender.amount - lenderStorageFilledAmount;
        uint256 fillAmount = MathLib.getFillAmount(
            lenderAvailable,
            lender.minFillAmount,
            borrower.borrowAmount,
            borrower.minFillAmount,
            lender.allowPartialFill,
            borrower.allowPartialFill
        );
        if (fillAmount == 0) revert ErrorsLib.IncompatibleIntents();

        uint256 requiredCollateral = matcher.getRequiredCollateralAmount(marketId, fillAmount, borrower.minLtvBps);
        if (borrower.collateralAmount < requiredCollateral) revert ErrorsLib.IncompatibleIntents();
    }

    /// @notice Check if a loan is currently underwater
    /// @dev A loan is underwater when collateral value < debt + liquidation bonus
    /// @param loanId The ID of the loan to check
    /// @return True if the loan is underwater, false otherwise
    function isLoanUnderwater(uint256 loanId) external view returns (bool) {
        LendingViewsStorage storage $ = _getLendingViewsStorage();
        IGetters matcher = $.lendingMatcher;

        Loan memory loan = matcher.getLoan(loanId);
        if (loan.repaid || loan.principal == 0) return false;

        uint256 price = matcher.getPrice(loan.collateralToken, loan.loanToken);
        if (price == 0) return false;

        bytes32 marketId = matcher.getMarketId(loan.loanToken, loan.collateralToken);
        Market memory market = matcher.getMarket(marketId);

        (uint256 totalInterest,) = matcher.getAccruedInterest(loanId);
        uint256 fullRepayment = loan.principal + totalInterest;

        uint256 collateralEquivalent = (fullRepayment * ORACLE_PRICE_SCALE) / price;
        uint256 liquidationBonus = Math.mulDiv(collateralEquivalent, market.liquidationIncentiveBps, BASIS_POINTS);

        return (collateralEquivalent + liquidationBonus) > loan.collateralAmount;
    }

    /// @notice Estimate bad debt if loan were liquidated now
    /// @dev Returns 0 if loan is not underwater or already repaid
    /// @param loanId The ID of the loan to check
    /// @return badDebtAmount The estimated bad debt amount in loan token units
    /// @return isUnderwater_ True if the loan is underwater
    function getEstimatedBadDebt(uint256 loanId) external view returns (uint256 badDebtAmount, bool isUnderwater_) {
        LendingViewsStorage storage $ = _getLendingViewsStorage();
        IGetters matcher = $.lendingMatcher;

        Loan memory loan = matcher.getLoan(loanId);
        if (loan.repaid || loan.principal == 0) return (0, false);

        uint256 price = matcher.getPrice(loan.collateralToken, loan.loanToken);
        if (price == 0) return (0, false);

        bytes32 marketId = matcher.getMarketId(loan.loanToken, loan.collateralToken);
        Market memory market = matcher.getMarket(marketId);

        (uint256 totalInterest,) = matcher.getAccruedInterest(loanId);
        uint256 fullRepayment = loan.principal + totalInterest;

        uint256 collateralEquivalent = (fullRepayment * ORACLE_PRICE_SCALE) / price;
        uint256 liquidationBonus = Math.mulDiv(collateralEquivalent, market.liquidationIncentiveBps, BASIS_POINTS);

        if ((collateralEquivalent + liquidationBonus) <= loan.collateralAmount) return (0, false);

        uint256 collateralValue = (loan.collateralAmount * price) / ORACLE_PRICE_SCALE;
        uint256 liquidatorPays = Math.mulDiv(collateralValue, BASIS_POINTS, BASIS_POINTS + market.liquidationIncentiveBps);

        uint256 protocolFee = Math.mulDiv(totalInterest, loan.marketFeeBps, BASIS_POINTS);
        uint256 actualProtocolFee = protocolFee > liquidatorPays ? liquidatorPays : protocolFee;

        uint256 lenderReceives = liquidatorPays - actualProtocolFee;
        uint256 netInterest = totalInterest - actualProtocolFee;
        uint256 expectedLenderPayment = loan.principal + netInterest;

        badDebtAmount = expectedLenderPayment > lenderReceives ? expectedLenderPayment - lenderReceives : 0;
        isUnderwater_ = true;
    }

    /// @notice Get a comprehensive quote for liquidating a loan
    /// @dev Returns all details needed for liquidation decision-making
    /// @param loanId The ID of the loan to liquidate
    /// @param repayAmount The amount of principal to repay (ignored for underwater loans)
    /// @return quote The liquidation quote with all relevant details
    function getLiquidationQuote(uint256 loanId, uint256 repayAmount) external view returns (LiquidationQuote memory quote) {
        LendingViewsStorage storage $ = _getLendingViewsStorage();
        IGetters matcher = $.lendingMatcher;

        Loan memory loan = matcher.getLoan(loanId);

        quote.loanId = loanId;
        if (loan.repaid || loan.principal == 0) revert ErrorsLib.LoanRepaid();
        if (repayAmount == 0 || repayAmount > loan.principal) return quote;

        uint256 price = matcher.getPrice(loan.collateralToken, loan.loanToken);
        if (price == 0) return quote;

        bytes32 marketId = matcher.getMarketId(loan.loanToken, loan.collateralToken);
        Market memory market = matcher.getMarket(marketId);

        (uint256 totalInterest,) = matcher.getAccruedInterest(loanId);
        uint256 fullRepayment = loan.principal + totalInterest;

        uint256 fullCollateralEquivalent = (fullRepayment * ORACLE_PRICE_SCALE) / price;
        uint256 fullLiquidationBonus = Math.mulDiv(fullCollateralEquivalent, market.liquidationIncentiveBps, BASIS_POINTS);

        quote.isUnderwater = (fullCollateralEquivalent + fullLiquidationBonus) > loan.collateralAmount;
        quote.requiresFullLiquidation = quote.isUnderwater;

        uint256 actualRepayAmount = quote.isUnderwater ? loan.principal : repayAmount;
        // Use mulDiv for full precision: (totalInterest * repayAmount) / principal
        uint256 interestPortion = quote.isUnderwater
            ? totalInterest
            : Math.mulDiv(totalInterest, repayAmount, loan.principal);

        quote.repayAmount = actualRepayAmount;
        quote.interestAmount = interestPortion;

        if (quote.isUnderwater) {
            quote.collateralToReceive = loan.collateralAmount;
            quote.collateralValueReceived = (loan.collateralAmount * price) / ORACLE_PRICE_SCALE;
            quote.totalLiquidatorPays = Math.mulDiv(quote.collateralValueReceived, BASIS_POINTS, BASIS_POINTS + market.liquidationIncentiveBps);

            uint256 normalProtocolFee = Math.mulDiv(interestPortion, loan.marketFeeBps, BASIS_POINTS);
            quote.protocolFeeAmount = normalProtocolFee > quote.totalLiquidatorPays ? quote.totalLiquidatorPays : normalProtocolFee;
            quote.lenderReceives = quote.totalLiquidatorPays - quote.protocolFeeAmount;

            uint256 netInterest = interestPortion - quote.protocolFeeAmount;
            uint256 expectedLenderPayment = actualRepayAmount + netInterest;
            quote.badDebtAmount = expectedLenderPayment > quote.lenderReceives ? expectedLenderPayment - quote.lenderReceives : 0;

            quote.liquidatorProfit = quote.collateralValueReceived - quote.totalLiquidatorPays;
            quote.liquidatorProfitBps = quote.totalLiquidatorPays > 0 ? (quote.liquidatorProfit * BASIS_POINTS) / quote.totalLiquidatorPays : 0;
        } else {
            uint256 totalRepayment = actualRepayAmount + interestPortion;
            uint256 collateralEquivalent = (totalRepayment * ORACLE_PRICE_SCALE) / price;
            uint256 liquidationBonus = Math.mulDiv(collateralEquivalent, market.liquidationIncentiveBps, BASIS_POINTS);

            quote.collateralToReceive = collateralEquivalent + liquidationBonus;
            quote.collateralValueReceived = (quote.collateralToReceive * price) / ORACLE_PRICE_SCALE;
            quote.totalLiquidatorPays = totalRepayment;
            quote.protocolFeeAmount = Math.mulDiv(interestPortion, loan.marketFeeBps, BASIS_POINTS);
            quote.lenderReceives = actualRepayAmount + interestPortion - quote.protocolFeeAmount;
            quote.badDebtAmount = 0;
            quote.liquidatorProfit = quote.collateralValueReceived - quote.totalLiquidatorPays;
            quote.liquidatorProfitBps = quote.totalLiquidatorPays > 0 ? (quote.liquidatorProfit * BASIS_POINTS) / quote.totalLiquidatorPays : 0;
        }
    }
}
