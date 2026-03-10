// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {LendingStorageLib} from "../storage/LendingStorage.sol";
import {LendIntent, BorrowIntent, Market, Loan} from "../interfaces/ILendingTypes.sol";
import {IGetters} from "../interfaces/IGetters.sol";
import {IStorage} from "../interfaces/IStorage.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import "../libraries/ConstantsLib.sol";

/// @title LendingIntentMatcherGetters
/// @notice Simple getter functions for LendingIntentMatcherUpgradeable
/// @dev Only contains functions that directly access storage without internal helpers
/// @dev Implements IGetters and IStorage interfaces
abstract contract LendingIntentMatcherGetters is IGetters, IStorage {
    using LendingStorageLib for LendingStorageLib.LendingStorage;

    // ============ Getter Functions (IGetters) ============

    function getMarket(bytes32 marketId) public view override returns (Market memory) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        return $.markets[marketId];
    }

    function getMarketId(address loanToken, address collateralToken) public pure override returns (bytes32) {
        return keccak256(abi.encodePacked(loanToken, collateralToken));
    }

    function getLoan(uint256 loanId) public view override returns (Loan memory) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        return $.loans[loanId];
    }

    function getLoanPrincipal(uint256 loanId) external view override returns (uint256) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        return $.loans[loanId].principal;
    }

    function getOnChainLendIntent(bytes32 hash) external view override returns (LendIntent memory) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        return $.onChainLendIntents[hash];
    }

    function getOnChainBorrowIntent(bytes32 hash) external view override returns (BorrowIntent memory) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        return $.onChainBorrowIntents[hash];
    }

    function getOffChainLendIntentFilledAmount(bytes32 hash) external view override returns (uint256) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        return $.offChainLendIntentFilledAmount[hash];
    }

    function getAccruedInterest(uint256 loanId) external view override returns (uint256 interest, uint256 timeElapsed) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        Loan memory loan = $.loans[loanId];
        if (loan.repaid) return (0, 0);
        timeElapsed = block.timestamp - loan.startTime;
        interest = (loan.principal * loan.interestRateBps * timeElapsed) / (BASIS_POINTS * 365 days);
    }

    function getCurrentLtvBps(uint256 loanId) external view override returns (uint256) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        Loan memory loan = $.loans[loanId];
        uint256 price = IPriceOracle($.priceOracle).getPrice(loan.collateralToken, loan.loanToken);

        uint256 collateralValue;
        unchecked {
            collateralValue = (loan.collateralAmount * price) / ORACLE_PRICE_SCALE;
        }
        if (collateralValue == 0) return 0;

        // Include accrued interest in LTV calculation
        uint256 accruedInterest = 0;
        if (!loan.repaid) {
            uint256 timeElapsed = block.timestamp - loan.startTime;
            accruedInterest = (loan.principal * loan.interestRateBps * timeElapsed) / (BASIS_POINTS * 365 days);
        }
        uint256 totalDebt = loan.principal + accruedInterest;
        return (totalDebt * BASIS_POINTS) / collateralValue;
    }

    function getLoanIdsByUser(address user) external view override returns (uint256[] memory) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        return $.userToLoanIds[user];
    }

    function getRequiredCollateralAmount(bytes32 marketId, uint256 borrowAmount, uint256 customLtvBps)
        public
        view
        override
        returns (uint256)
    {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        Market storage market = $.markets[marketId];
        if (market.loanToken == address(0) || market.collateralToken == address(0)) {
            revert ErrorsLib.MarketNotCreated();
        }

        uint256 ltvToUse = customLtvBps != 0 ? customLtvBps : market.ltvBps;
        uint256 price = IPriceOracle($.priceOracle).getPrice(market.collateralToken, market.loanToken);
        if (price == 0) revert ErrorsLib.InvalidPrice();

        uint256 denominator = price * ltvToUse;
        uint256 numerator = borrowAmount * ORACLE_PRICE_SCALE;
        numerator = numerator * BASIS_POINTS;
        return numerator / denominator;
    }

    function getPrice(address collateralToken, address loanToken) external view override returns (uint256) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        return IPriceOracle($.priceOracle).getPrice(collateralToken, loanToken);
    }

    function getFlashloanFeeBps() external view override returns (uint256) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        return $.flashloanFeeBps;
    }

    // ============ Storage Functions (IStorage) ============

    /// @notice Checks if a lender intent is stored on-chain.
    /// @param hash Keccak256 hash of the lender intent.
    /// @return True if intent exists, false otherwise.
    function isLendIntentOnChain(bytes32 hash) external view override returns (bool) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        return $.onChainLendIntents[hash].lender != address(0);
    }

    /// @notice Checks if a borrower intent is stored on-chain.
    /// @param hash Keccak256 hash of the borrower intent.
    /// @return True if intent exists, false otherwise.
    function isBorrowIntentOnChain(bytes32 hash) external view override returns (bool) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        return $.onChainBorrowIntents[hash].borrower != address(0);
    }

    /// @notice Checks if an intent has been used (matched into a loan).
    /// @param hash Keccak256 hash of the intent (lend or borrow).
    /// @return True if the intent has been used, false otherwise.
    function isIntentUsed(bytes32 hash) external view override returns (bool) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        return $.usedIntentHashes[hash];
    }

    /// @notice Checks if an intent hash was ever registered on-chain.
    /// @dev This differs from isLendIntentOnChain/isBorrowIntentOnChain - those check
    ///      if intent DATA exists, this checks if the hash was registered (stays true after revocation).
    /// @param hash Keccak256 hash of the intent (lend or borrow).
    /// @return True if the intent was registered, false otherwise.
    function isIntentRegistered(bytes32 hash) external view override returns (bool) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        return $.registeredIntentHashes[hash];
    }

    // ============ Additional Getters ============

    function getFeeRecipient() external view returns (address) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        return $.feeRecipient;
    }

    function getPriceOracle() external view returns (address) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        return $.priceOracle;
    }

    function getHookExecutor() external view returns (address) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        return $.hookExecutor;
    }

    function getLogicsManager() external view returns (address) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        return $.logicsManager;
    }

    function getWithdrawalBufferBps() external view returns (uint256) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        return $.withdrawalBufferBps;
    }

    function getMinLtvGapBps() external view override returns (uint256) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        return $.minLtvGapBps;
    }

    // NOTE: Underwater/Bad Debt View Functions (isLoanUnderwater, getEstimatedBadDebt, getLiquidationQuote)
    // are available via the separate LendingViews contract to reduce main contract size
}
