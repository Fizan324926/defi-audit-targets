// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

/// @title ILiquidationCallback
/// @notice Interface for contracts that handle liquidation callbacks
/// @dev Implement this to perform zero-capital liquidations via liquidateWithCallback
interface ILiquidationCallback {
    /// @notice Called after collateral has been transferred to msg.sender but before
    ///         loan token payment is pulled. Use this to swap collateral to loan tokens.
    /// @param loanId The ID of the loan being liquidated
    /// @param collateralToken The address of the collateral token received
    /// @param collateralAmount The amount of collateral tokens received
    /// @param loanToken The address of the loan token that must be repaid
    /// @param repaymentRequired The total amount of loan tokens that will be pulled after this callback
    /// @param data Arbitrary data passed through from the liquidateWithCallback caller
    function onLiquidationCallback(
        uint256 loanId,
        address collateralToken,
        uint256 collateralAmount,
        address loanToken,
        uint256 repaymentRequired,
        bytes calldata data
    ) external;
}
