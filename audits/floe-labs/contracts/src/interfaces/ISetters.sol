// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

/// @title ISetters
/// @notice Interface for setter functions that update protocol and market configuration.
interface ISetters {
    /// @notice Sets market parameters for a given marketId.
    /// @param marketId The identifier of the market.
    /// @param interestRateBps The interest rate in basis points.
    /// @param ltvBps The loan-to-value ratio in basis points.
    /// @param marketFeeBps The market fee in basis points.
    /// @param liquidationIncentiveBps The liquidation incentive in basis points.
    function setMarket(
        bytes32 marketId,
        uint256 interestRateBps,
        uint256 ltvBps,
        uint256 marketFeeBps,
        uint256 liquidationIncentiveBps
    ) external;

    /// @notice Sets the address of the hook executor contract.
    /// @param hookExecutor_ The address of the hook executor.
    function setHookExecutor(address hookExecutor_) external;

    /// @notice Sets the gas limit for call exact check operations.
    /// @param gasForCallExactCheck_ The gas amount to set.
    function setGasForCallExactCheck(uint32 gasForCallExactCheck_) external;

    /// @notice Sets the pause status for various actions in a market.
    /// @param marketId The identifier of the market.
    /// @param isAddCollateralPaused Pause status for adding collateral.
    /// @param isBorrowPaused Pause status for borrowing.
    /// @param isWithdrawCollateralPaused Pause status for withdrawing collateral.
    /// @param isRepayPaused Pause status for repaying.
    /// @param isLiquidatePaused Pause status for liquidations.
    function setPauseStatus(
        bytes32 marketId,
        bool isAddCollateralPaused,
        bool isBorrowPaused,
        bool isWithdrawCollateralPaused,
        bool isRepayPaused,
        bool isLiquidatePaused
    ) external;

    /// @notice Sets the flashloan fee in basis points.
    /// @param flashloanFeeBps_ The flashloan fee in basis points.
    function setFlashloanFeeBps(uint256 flashloanFeeBps_) external;

    /// @notice Sets the address that receives protocol fees.
    /// @param feeRecipient_ The address of the fee recipient.
    function setFeeRecipient(address feeRecipient_) external;

    /// @notice Sets the address of the price oracle contract.
    /// @param priceOracle_ The address of the price oracle.
    function setPriceOracle(address priceOracle_) external;

    /// @notice Sets the address of the lending logics manager contract.
    /// @param logicsManager_ The address of the lending logics manager.
    function setLogicsManager(address logicsManager_) external;

    /// @notice Sets the withdrawal buffer in basis points.
    /// @dev Buffer is subtracted from liquidation threshold to determine max withdrawal LTV.
    /// @param withdrawalBufferBps_ The new buffer in basis points (e.g., 800 = 8%).
    function setWithdrawalBufferBps(uint256 withdrawalBufferBps_) external;

    /// @notice Sets the minimum LTV gap in basis points.
    /// @dev Gap is required between borrower's initial LTV and lender's liquidation threshold.
    /// @param minLtvGapBps_ The new gap in basis points (e.g., 800 = 8%).
    function setMinLtvGapBps(uint256 minLtvGapBps_) external;
}
