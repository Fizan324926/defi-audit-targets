// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Market, Loan, LendIntent, BorrowIntent} from "./ILendingTypes.sol";

/// @title IGetters
/// @notice Interface for getter functions that provide protocol, market, loan, and intent data.
interface IGetters {
    /// @notice Returns the market ID for a given loan and collateral token.
    /// @param loanToken The address of the loan token.
    /// @param collateralToken The address of the collateral token.
    /// @return The market ID as a bytes32 hash.
    function getMarketId(address loanToken, address collateralToken) external pure returns (bytes32);

    /// @notice Retrieves the Market struct associated with a given marketId.
    /// @param marketId The unique identifier of the market to retrieve.
    /// @return The Market struct corresponding to the provided marketId.
    function getMarket(bytes32 marketId) external view returns (Market memory);

    /// @notice Retrieves the current flashloan fee in basis points.
    /// @return The flashloan fee in basis points.
    function getFlashloanFeeBps() external view returns (uint256);

    /// @notice Retrieves the Loan struct associated with a given loanId.
    /// @param loanId The unique identifier of the loan to retrieve.
    /// @return The Loan struct corresponding to the provided loanId.
    function getLoan(uint256 loanId) external view returns (Loan memory);

    /// @notice Retrieves the principal amount of a given loan.
    /// @param loanId The unique identifier of the loan.
    /// @return The principal amount of the loan.
    function getLoanPrincipal(uint256 loanId) external view returns (uint256);

    /// @notice Retrieves the on-chain lend intent associated with a given hash.
    /// @param hash The hash of the lend intent.
    /// @return The LendIntent struct corresponding to the provided hash.
    function getOnChainLendIntent(bytes32 hash) external view returns (LendIntent memory);

    /// @notice Retrieves the on-chain borrow intent associated with a given hash.
    /// @param hash The hash of the borrow intent.
    /// @return The BorrowIntent struct corresponding to the provided hash.
    function getOnChainBorrowIntent(bytes32 hash) external view returns (BorrowIntent memory);

    /// @notice Retrieves the filled amount for an off-chain lend intent.
    /// @param hash The hash of the lend intent.
    /// @return The amount that has been filled for this off-chain intent.
    function getOffChainLendIntentFilledAmount(bytes32 hash) external view returns (uint256);

    /// @notice Retrieves the accrued interest and time elapsed for a given loan.
    /// @param loanId The unique identifier of the loan.
    /// @return interest The accrued interest amount.
    /// @return timeElapsed The time elapsed since the last interest calculation.
    function getAccruedInterest(uint256 loanId) external view returns (uint256 interest, uint256 timeElapsed);

    /// @notice Retrieves the current loan-to-value ratio in basis points for a given loan.
    /// @param loanId The unique identifier of the loan.
    /// @return The current LTV in basis points.
    function getCurrentLtvBps(uint256 loanId) external view returns (uint256);

    /// @notice Retrieves all loan IDs associated with a given user.
    /// @param user The address of the user.
    /// @return An array of loan IDs belonging to the user.
    function getLoanIdsByUser(address user) external view returns (uint256[] memory);

    /// @notice Calculates the required collateral amount for a given market, borrow amount, and custom LTV.
    /// @param marketId The unique identifier of the market.
    /// @param borrowAmount The amount to borrow.
    /// @param customLtvBps The custom loan-to-value ratio in basis points.
    /// @return requiredCollateralAmount The required collateral amount.
    function getRequiredCollateralAmount(bytes32 marketId, uint256 borrowAmount, uint256 customLtvBps)
        external
        view
        returns (uint256 requiredCollateralAmount);

    /// @notice Returns the price of the collateralToken in terms of the loanToken from the PriceOracle.
    /// @param collateralToken The address of the collateral token.
    /// @param loanToken The address of the loan token.
    /// @return price The price from the oracle.
    function getPrice(address collateralToken, address loanToken) external view returns (uint256 price);

    /// @notice Returns the EIP-712 domain separator for signature verification.
    /// @return The domain separator as bytes32.
    function domainSeparator() external view returns (bytes32);

    /// @notice Returns the minimum LTV gap in basis points required between borrower's initial LTV and liquidation LTV.
    /// @return The minimum LTV gap in basis points.
    function getMinLtvGapBps() external view returns (uint256);

    // NOTE: Underwater/Bad Debt View Functions (isLoanUnderwater, getEstimatedBadDebt, getLiquidationQuote)
    // are available on LendingLogicsManager contract directly to reduce main contract size
}
