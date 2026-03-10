// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Roles} from "../governance/Roles.sol";

import {LendingStorageLib} from "../storage/LendingStorage.sol";
import {Market, PauseStatuses} from "../interfaces/ILendingTypes.sol";
import {ISetters} from "../interfaces/ISetters.sol";
import {IHookExecutor} from "../interfaces/IHookExecutor.sol";
import {ILendingLogicsManager} from "../interfaces/ILendingLogicsManager.sol";

import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {EventsLib} from "../libraries/EventsLib.sol";
import "../libraries/ConstantsLib.sol";

/// @title LendingIntentMatcherSetters
/// @notice Admin setter functions for LendingIntentMatcherUpgradeable
/// @dev Inherits from AccessControlUpgradeable to use onlyRole modifier
/// @dev Implements ISetters interface
abstract contract LendingIntentMatcherSetters is AccessControlUpgradeable, ISetters {
    using LendingStorageLib for LendingStorageLib.LendingStorage;
    using Address for address;

    // ============ Setter Functions (Restricted) ============

    function setMarket(
        bytes32 marketId,
        uint256 interestRateBps,
        uint256 ltvBps,
        uint256 marketFeeBps,
        uint256 liquidationIncentiveBps
    ) external override onlyRole(Roles.PROTOCOL_ADMIN_ROLE) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        $.logicsManager.functionDelegateCall(
            abi.encodeCall(
                ILendingLogicsManager.setMarketLogic,
                (marketId, interestRateBps, ltvBps, marketFeeBps, liquidationIncentiveBps)
            )
        );
    }

    function setHookExecutor(address hookExecutor_) external override onlyRole(Roles.PROTOCOL_ADMIN_ROLE) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        if (hookExecutor_ == $.hookExecutor) revert ErrorsLib.HookExecutorAlreadySet();
        $.hookExecutor = hookExecutor_;
        emit EventsLib.LogHookExecutorUpdated(hookExecutor_);
    }

    /// @notice Updates the gas limit for the callExactCheck in the hook executor
    /// @param gasForCallExactCheck_ The new gas limit to set
    function setGasForCallExactCheck(uint32 gasForCallExactCheck_) external override onlyRole(Roles.PROTOCOL_ADMIN_ROLE) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        IHookExecutor executor = IHookExecutor($.hookExecutor);
        if (gasForCallExactCheck_ == executor.getGasForCallExactCheck()) {
            revert ErrorsLib.GasForCallExactCheckAlreadySet();
        }
        executor.setGasForCallExactCheck(gasForCallExactCheck_);
        emit EventsLib.GasForCallExactCheckSet(gasForCallExactCheck_);
    }

    function setPauseStatus(
        bytes32 marketId,
        bool isAddCollateralPaused,
        bool isBorrowPaused,
        bool isWithdrawCollateralPaused,
        bool isRepayPaused,
        bool isLiquidatePaused
    ) external override onlyRole(Roles.GUARDIAN_ROLE) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        $.logicsManager.functionDelegateCall(
            abi.encodeCall(
                ILendingLogicsManager.setPauseStatusLogic,
                (marketId, isAddCollateralPaused, isBorrowPaused, isWithdrawCollateralPaused, isRepayPaused, isLiquidatePaused)
            )
        );
    }

    function setFlashloanFeeBps(uint256 flashloanFeeBps_) external override onlyRole(Roles.PROTOCOL_ADMIN_ROLE) {
        if (flashloanFeeBps_ > MAX_PROTOCOL_FEE_BPS) revert ErrorsLib.FeeOutOfBounds();
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        if (flashloanFeeBps_ == $.flashloanFeeBps) return;
        $.flashloanFeeBps = flashloanFeeBps_;
        emit EventsLib.LogFlashloanFeeBpsUpdated(flashloanFeeBps_);
    }

    function setFeeRecipient(address feeRecipient_) external override onlyRole(Roles.PROTOCOL_ADMIN_ROLE) {
        if (feeRecipient_ == address(0)) revert ErrorsLib.ZeroAddress();
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        $.feeRecipient = feeRecipient_;
        emit EventsLib.LogFeeRecipientUpdated(feeRecipient_);
    }

    function setPriceOracle(address priceOracle_) external override onlyRole(Roles.PROTOCOL_ADMIN_ROLE) {
        if (priceOracle_ == address(0)) revert ErrorsLib.ZeroAddress();
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        $.priceOracle = priceOracle_;
        emit EventsLib.LogPriceOracleUpdated(priceOracle_);
    }

    function setLogicsManager(address logicsManager_) external override onlyRole(Roles.PROTOCOL_ADMIN_ROLE) {
        if (logicsManager_ == address(0)) revert ErrorsLib.ZeroAddress();
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        $.logicsManager = logicsManager_;
        emit EventsLib.LogLogicsManagerUpdated(logicsManager_);
    }

    /// @notice Sets the withdrawal buffer in basis points
    /// @dev Buffer is subtracted from liquidation threshold to determine max withdrawal LTV
    /// @param withdrawalBufferBps_ The new buffer in basis points (e.g., 800 = 8%)
    function setWithdrawalBufferBps(uint256 withdrawalBufferBps_) external override onlyRole(Roles.PROTOCOL_ADMIN_ROLE) {
        if (withdrawalBufferBps_ > MAX_WITHDRAWAL_BUFFER_BPS) revert ErrorsLib.WithdrawalBufferOutOfBounds();
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        uint256 oldBufferBps = $.withdrawalBufferBps;
        if (withdrawalBufferBps_ == oldBufferBps) return;
        $.withdrawalBufferBps = withdrawalBufferBps_;
        emit EventsLib.LogWithdrawalBufferBpsUpdated(oldBufferBps, withdrawalBufferBps_);
    }

    /// @notice Sets the minimum LTV gap in basis points
    /// @param minLtvGapBps_ The new gap in basis points (e.g., 800 = 8%)
    function setMinLtvGapBps(uint256 minLtvGapBps_) external override onlyRole(Roles.PROTOCOL_ADMIN_ROLE) {
        if (minLtvGapBps_ > MAX_MIN_LTV_GAP_BPS) revert ErrorsLib.MinLtvGapOutOfBounds();
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        emit EventsLib.LogMinLtvGapBpsUpdated($.minLtvGapBps, minLtvGapBps_);
        $.minLtvGapBps = minLtvGapBps_;
    }
}
