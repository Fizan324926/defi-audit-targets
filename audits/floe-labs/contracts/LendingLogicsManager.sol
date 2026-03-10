// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {LendingLogicsInternal} from "./LendingLogicsInternal.sol";
import {ILendingLogicsManager} from "../interfaces/ILendingLogicsManager.sol";
import {LendIntent, BorrowIntent, MatchLoanParams, Market, PauseStatuses} from "../interfaces/ILendingTypes.sol";
import {LendingStorageLib} from "../storage/LendingStorage.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {EventsLib} from "../libraries/EventsLib.sol";
import "../libraries/ConstantsLib.sol";

/// @title LendingLogicsManager
/// @notice Contract containing the core logic functions delegated from LendingIntentMatcher
/// @dev Operates on the caller's storage via delegatecall (NOT a UUPS proxy)
/// @dev "Upgraded" by deploying a new version and calling setLogicsManager() on the matcher
/// @dev Includes FIXED partial fill logic
contract LendingLogicsManager is ILendingLogicsManager, LendingLogicsInternal {
    // ============ Delegate Call Protection ============
    /// @dev Address of the implementation contract (set at deployment)
    address private immutable __self = address(this);

    /// @dev Error thrown when function is called directly instead of via delegatecall
    error OnlyProxy();

    /// @dev Ensures function is only callable via delegatecall from a proxy
    modifier onlyProxy() {
        if (address(this) == __self) revert OnlyProxy();
        _;
    }

    // ============ Core Logic Functions ============
    /// @notice Implements the match loan intents logic with FIXED partial fill support
    function matchLoanIntentsLogic(MatchLoanParams calldata params) external onlyProxy returns (uint256 loanId) {
        return _matchLoanIntents(params);
    }

    /// @notice Implements the repay loan logic
    function repayLoanLogic(uint256 loanId, uint256 repayAmount, uint256 maxTotalRepayment) external onlyProxy {
        _repayLoan(loanId, repayAmount, maxTotalRepayment);
    }

    /// @notice Implements the liquidate loan logic
    function liquidateLoanLogic(uint256 loanId, uint256 repayAmount, uint256 maxTotalRepayment) external onlyProxy {
        _liquidateLoan(loanId, repayAmount, maxTotalRepayment);
    }

    /// @notice Implements the liquidate loan with callback logic
    function liquidateWithCallbackLogic(
        uint256 loanId,
        uint256 repayAmount,
        uint256 maxTotalRepayment,
        bytes calldata data
    ) external onlyProxy {
        _liquidateWithCallback(loanId, repayAmount, maxTotalRepayment, data);
    }

    /// @notice Implements the add collateral logic
    function addCollateralLogic(uint256 loanId, uint256 amount) external onlyProxy {
        _addCollateral(loanId, amount);
    }

    /// @notice Implements the withdraw collateral logic
    function withdrawCollateralLogic(uint256 loanId, uint256 amount) external onlyProxy {
        _withdrawCollateral(loanId, amount);
    }

    /// @notice Implements the register lend intent logic
    function registerLendIntentLogic(
        LendIntent calldata intent,
        bytes32 domainSeparator,
        bytes32 lenderIntentTypehash,
        bytes32 conditionTypehash,
        bytes32 hookTypehash
    ) external onlyProxy {
        _registerLendIntent(intent, domainSeparator, lenderIntentTypehash, conditionTypehash, hookTypehash);
    }

    /// @notice Implements the revoke lend intent logic
    function revokeLendIntentByHashLogic(bytes32 intentHash) external onlyProxy {
        _revokeLendIntentByHash(intentHash);
    }

    /// @notice Implements the register borrow intent logic
    function registerBorrowIntentLogic(
        BorrowIntent calldata intent,
        bytes32 domainSeparator,
        bytes32 borrowerIntentTypehash,
        bytes32 conditionTypehash,
        bytes32 hookTypehash
    ) external onlyProxy {
        _registerBorrowIntent(intent, domainSeparator, borrowerIntentTypehash, conditionTypehash, hookTypehash);
    }

    /// @notice Implements the revoke borrow intent logic
    function revokeBorrowIntentByHashLogic(bytes32 intentHash) external onlyProxy {
        _revokeBorrowIntentByHash(intentHash);
    }

    /// @notice Implements the flash loan logic
    function flashLoanLogic(address token, uint256 amount, bytes calldata data) external onlyProxy {
        _flashLoan(token, amount, data);
    }

    /// @notice Implements the create market logic
    function createMarketLogic(
        address loanToken,
        address collateralToken,
        uint256 interestRateBps,
        uint256 ltvBps,
        uint256 marketFeeBps,
        uint256 liquidationIncentiveBps
    ) external onlyProxy returns (bytes32 marketId) {
        return _createMarket(loanToken, collateralToken, interestRateBps, ltvBps, marketFeeBps, liquidationIncentiveBps);
    }

    // ============ Setter Logic Functions ============

    /// @notice Implements the set market logic
    function setMarketLogic(
        bytes32 marketId,
        uint256 interestRateBps,
        uint256 ltvBps,
        uint256 marketFeeBps,
        uint256 liquidationIncentiveBps
    ) external onlyProxy {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        Market storage market = $.markets[marketId];

        if (market.loanToken == address(0) || market.collateralToken == address(0)) {
            revert ErrorsLib.MarketNotCreated();
        }

        if (ltvBps == 0 || ltvBps > MAX_LTV_BPS || ltvBps > BASIS_POINTS) revert ErrorsLib.LtvOutOfBounds();
        if (interestRateBps == 0) revert ErrorsLib.InterestRateNotSet();
        if (interestRateBps > MAX_INTEREST_RATE_BPS) revert ErrorsLib.InterestRateOutOfBounds();
        if (liquidationIncentiveBps == 0 || liquidationIncentiveBps > MAX_LIQUIDATION_INCENTIVE_BPS) {
            revert ErrorsLib.IncentiveOutOfBounds();
        }
        if (marketFeeBps > MAX_PROTOCOL_FEE_BPS) revert ErrorsLib.FeeOutOfBounds();

        market.ltvBps = ltvBps;
        market.interestRateBps = interestRateBps;
        market.liquidationIncentiveBps = liquidationIncentiveBps;
        market.marketFeeBps = marketFeeBps;
        market.lastUpdateAt = uint128(block.timestamp);

        emit EventsLib.LogMarketConfigurationUpdated(marketId);
    }

    /// @notice Implements the set pause status logic
    function setPauseStatusLogic(
        bytes32 marketId,
        bool isAddCollateralPaused,
        bool isBorrowPaused,
        bool isWithdrawCollateralPaused,
        bool isRepayPaused,
        bool isLiquidatePaused
    ) external onlyProxy {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        Market storage market = $.markets[marketId];
        market.pauseStatuses = PauseStatuses({
            isAddCollateralPaused: isAddCollateralPaused,
            isBorrowPaused: isBorrowPaused,
            isWithdrawCollateralPaused: isWithdrawCollateralPaused,
            isRepayPaused: isRepayPaused,
            isLiquidatePaused: isLiquidatePaused
        });
        market.lastUpdateAt = uint128(block.timestamp);
        emit EventsLib.LogMarketPauseStatusUpdated(marketId);
    }

    // NOTE: View functions (isLoanUnderwater, getEstimatedBadDebt, getLiquidationQuote)
    // are available via the separate LendingViews contract
}
