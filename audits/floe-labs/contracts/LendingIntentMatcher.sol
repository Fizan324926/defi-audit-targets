// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Roles} from "../governance/Roles.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {LendingStorageLib} from "../storage/LendingStorage.sol";
import {
    LendIntent,
    BorrowIntent,
    Market,
    Loan,
    PauseStatuses,
    MatchLoanParams,
    MatchContext
} from "../interfaces/ILendingTypes.sol";
import {ILendingIntentMatcher} from "../interfaces/ILendingIntentMatcher.sol";
import {ILendingLogicsManager} from "../interfaces/ILendingLogicsManager.sol";
import {IGetters} from "../interfaces/IGetters.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {IHookExecutor} from "../interfaces/IHookExecutor.sol";

import {LendingIntentMatcherGetters} from "./LendingIntentMatcherGetters.sol";
import {LendingIntentMatcherSetters} from "./LendingIntentMatcherSetters.sol";
import {LendingIntentMatcherInternal} from "./LendingIntentMatcherInternal.sol";

import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {EventsLib} from "../libraries/EventsLib.sol";
import {ChainIdLib} from "../libraries/ChainIdLib.sol";
import {IntentLib} from "../libraries/IntentLib.sol";
import "../libraries/ConstantsLib.sol";

/// @title LendingIntentMatcherUpgradeable
/// @notice UUPS upgradeable intent-based lending system that matches lenders and borrowers peer-to-peer
/// @dev Implements ERC-7201 namespaced storage for safe upgrades
contract LendingIntentMatcherUpgradeable is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    LendingIntentMatcherInternal,
    LendingIntentMatcherGetters,
    LendingIntentMatcherSetters,
    ILendingIntentMatcher
{
    using Address for address;
    using SafeERC20 for IERC20;
    using LendingStorageLib for LendingStorageLib.LendingStorage;

    // ============ Immutables ============
    /// @notice Immutable chain ID set at deployment
    uint256 private immutable _immutableChainId;
    /// @notice Immutable domain separator set at deployment
    bytes32 private immutable _immutableDomainSeparator;

    // ============ Modifiers ============
    modifier onlyWhenAddCollateralNotPaused(bytes32 marketId) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        if ($.markets[marketId].pauseStatuses.isAddCollateralPaused) revert ErrorsLib.AddCollateralPaused();
        _;
    }

    modifier onlyWhenWithdrawCollateralNotPaused(bytes32 marketId) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        if ($.markets[marketId].pauseStatuses.isWithdrawCollateralPaused) revert ErrorsLib.WithdrawCollateralPaused();
        _;
    }

    modifier onlyWhenBorrowNotPaused(bytes32 marketId) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        if ($.markets[marketId].pauseStatuses.isBorrowPaused) revert ErrorsLib.BorrowPaused();
        _;
    }

    modifier onlyWhenRepayNotPaused(bytes32 marketId) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        if ($.markets[marketId].pauseStatuses.isRepayPaused) revert ErrorsLib.RepayPaused();
        _;
    }

    modifier onlyWhenLiquidateNotPaused(bytes32 marketId) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        if ($.markets[marketId].pauseStatuses.isLiquidatePaused) revert ErrorsLib.LiquidationPaused();
        _;
    }

    modifier onlyNonZeroAddress(address account) {
        if (account == address(0)) revert ErrorsLib.ZeroAddress();
        _;
    }

    modifier onlyWhenMarketCreated(bytes32 marketId) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        Market storage market = $.markets[marketId];
        if (market.loanToken == address(0) || market.collateralToken == address(0)) {
            revert ErrorsLib.MarketNotCreated();
        }
        _;
    }

    /// @notice Reverts if oracle circuit breaker is active
    modifier onlyWhenCircuitBreakerNotActive() {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        if (IPriceOracle($.priceOracle).isCircuitBreakerActive()) {
            revert ErrorsLib.CircuitBreakerActive(
                IPriceOracle($.priceOracle).getCircuitBreakerReason()
            );
        }
        _;
    }

    // ============ Constructor ============
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // Initialize immutable domain separator
        uint256 chainId = ChainIdLib.getChainId();
        _immutableChainId = chainId;
        _immutableDomainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(PROTOCOL_NAME)),
                keccak256(bytes(PROTOCOL_VERSION)),
                chainId,
                address(this)
            )
        );
        _disableInitializers();
    }

    // ============ Initializer ============
    /// @notice Initializes the upgradeable contract
    /// @param admin_ The default admin address (can grant/revoke roles)
    /// @param protocolAdmin_ The protocol admin address (manages config)
    /// @param guardian_ The guardian address (can pause)
    /// @param upgrader_ The upgrader address (should be TimelockController)
    /// @param feeRecipient_ The fee recipient address
    /// @param priceOracle_ The price oracle address
    /// @param hookExecutor_ The hook executor address
    /// @param logicsManager_ The logics manager address
    function initialize(
        address admin_,
        address protocolAdmin_,
        address guardian_,
        address upgrader_,
        address feeRecipient_,
        address priceOracle_,
        address hookExecutor_,
        address logicsManager_
    ) external initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        // Grant roles
        _grantRole(Roles.DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(Roles.PROTOCOL_ADMIN_ROLE, protocolAdmin_);
        _grantRole(Roles.GUARDIAN_ROLE, guardian_);
        _grantRole(Roles.UPGRADER_ROLE, upgrader_);

        if (priceOracle_ == address(0)) revert ErrorsLib.ZeroAddress();
        if (feeRecipient_ == address(0)) revert ErrorsLib.ZeroAddress();
        // hookExecutor and logicsManager can be set later via setters

        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        $.priceOracle = priceOracle_;
        $.feeRecipient = feeRecipient_;
        $.logicsManager = logicsManager_;
        $.hookExecutor = hookExecutor_;
        $.flashloanFeeBps = DEFAULT_FLASHLOAN_FEE_BPS;
        $.withdrawalBufferBps = DEFAULT_WITHDRAWAL_BUFFER_BPS;
        $.minLtvGapBps = DEFAULT_MIN_LTV_GAP_BPS;

        // Cache domain separator with proxy's address (address(this) in initialize is the proxy)
        // This ensures signatures remain valid across implementation upgrades
        uint256 chainId = ChainIdLib.getChainId();
        $.cachedChainId = chainId;
        $.cachedDomainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(PROTOCOL_NAME)),
                keccak256(bytes(PROTOCOL_VERSION)),
                chainId,
                address(this) // This is the proxy address in initialize context
            )
        );
    }

    // ============ Upgrade Authorization ============
    /// @notice Authorizes an upgrade to a new implementation
    /// @param newImplementation The address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(Roles.UPGRADER_ROLE) {}

    // ============ Domain Separator ============
    /// @notice Returns the EIP-712 domain separator
    /// @dev Prioritizes the cached domain separator (set during initialize with proxy address)
    ///      to ensure signatures remain valid across implementation upgrades
    /// @return The domain separator bytes32
    function domainSeparator() public view override(ILendingIntentMatcher, LendingIntentMatcherInternal, IGetters) returns (bytes32) {
        uint256 currentChainId = ChainIdLib.getChainId();
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();

        // First check cached domain separator (set during initialize with proxy address)
        // This ensures signatures remain valid across implementation upgrades
        if (currentChainId == $.cachedChainId && $.cachedDomainSeparator != bytes32(0)) {
            return $.cachedDomainSeparator;
        }

        // Fallback to immutable (for pre-initialized or direct implementation calls)
        if (currentChainId == _immutableChainId) {
            return _immutableDomainSeparator;
        }

        // Compute on-the-fly for chain forks
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes(PROTOCOL_NAME)),
                keccak256(bytes(PROTOCOL_VERSION)),
                currentChainId,
                address(this)
            )
        );
    }

    // ============ View Functions (ILendingIntentMatcher) ============

    /// @notice Checks if a loan is healthy
    function isHealthy(uint256 loanId) public view override returns (bool) {
        return _isHealthy(loanId);
    }

    // NOTE: canMatchLoanIntents moved to LendingViewsUpgradeable to reduce contract size
    // NOTE: validateIntents moved to LendingViewsUpgradeable to reduce contract size
    // Users should call LendingViews for pre-flight checks
    // Or simply attempt the match - it will revert with a descriptive error if invalid

    /// @notice Hashes a lender intent
    function hashLenderIntent(LendIntent calldata lenderIntent) external view override returns (bytes32) {
        return IntentLib.hashLender(
            lenderIntent, domainSeparator(), LENDER_INTENT_TYPEHASH, CONDITION_TYPEHASH, HOOK_TYPEHASH
        );
    }

    /// @notice Hashes a borrower intent
    function hashBorrowerIntent(BorrowIntent calldata borrowerIntent) external view override returns (bytes32) {
        return IntentLib.hashBorrower(
            borrowerIntent, domainSeparator(), BORROWER_INTENT_TYPEHASH, CONDITION_TYPEHASH, HOOK_TYPEHASH
        );
    }

    // ============ Market Functions ============
    /// @notice Creates a new lending market
    function createMarket(
        address loanToken,
        address collateralToken,
        uint256 interestRateBps,
        uint256 ltvBps,
        uint256 marketFeeBps,
        uint256 liquidationIncentiveBps
    ) external onlyRole(Roles.PROTOCOL_ADMIN_ROLE) returns (bytes32 marketId) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        bytes memory returnData = $.logicsManager.functionDelegateCall(
            abi.encodeCall(
                ILendingLogicsManager.createMarketLogic,
                (loanToken, collateralToken, interestRateBps, ltvBps, marketFeeBps, liquidationIncentiveBps)
            )
        );
        return abi.decode(returnData, (bytes32));
    }

    // ============ Intent Matching ============
    /// @notice Matches a lender's intent with a borrower's intent, creating a loan
    function matchLoanIntents(
        LendIntent calldata lender,
        bytes calldata lenderSig,
        BorrowIntent calldata borrower,
        bytes calldata borrowerSig,
        bytes32 marketId,
        bool isLenderOnChain,
        bool isBorrowerOnChain
    ) external nonReentrant onlyWhenCircuitBreakerNotActive onlyWhenBorrowNotPaused(marketId) returns (uint256 loanId) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();

        MatchLoanParams memory params = MatchLoanParams({
            lender: lender,
            lenderSig: lenderSig,
            borrower: borrower,
            borrowerSig: borrowerSig,
            marketId: marketId,
            isLenderOnChain: isLenderOnChain,
            isBorrowerOnChain: isBorrowerOnChain,
            domainSeparator: domainSeparator(),
            lenderIntentTypehash: LENDER_INTENT_TYPEHASH,
            borrowerIntentTypehash: BORROWER_INTENT_TYPEHASH,
            conditionTypehash: CONDITION_TYPEHASH,
            hookTypehash: HOOK_TYPEHASH
        });

        bytes memory returnData = $.logicsManager.functionDelegateCall(
            abi.encodeCall(ILendingLogicsManager.matchLoanIntentsLogic, (params))
        );
        return abi.decode(returnData, (uint256));
    }

    // ============ Intent Registration ============
    /// @notice Registers a lender's intent on-chain
    function registerLendIntent(LendIntent calldata intent) external nonReentrant onlyWhenCircuitBreakerNotActive onlyWhenBorrowNotPaused(intent.marketId) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        $.logicsManager.functionDelegateCall(
            abi.encodeCall(
                ILendingLogicsManager.registerLendIntentLogic,
                (intent, domainSeparator(), LENDER_INTENT_TYPEHASH, CONDITION_TYPEHASH, HOOK_TYPEHASH)
            )
        );
    }

    /// @notice Revokes an on-chain lender intent
    function revokeLendIntentByHash(bytes32 intentHash) external nonReentrant onlyWhenCircuitBreakerNotActive {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        $.logicsManager.functionDelegateCall(
            abi.encodeCall(ILendingLogicsManager.revokeLendIntentByHashLogic, (intentHash))
        );
    }

    /// @notice Registers a borrower's intent on-chain
    function registerBorrowIntent(BorrowIntent calldata intent) external nonReentrant onlyWhenCircuitBreakerNotActive onlyWhenBorrowNotPaused(intent.marketId) {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        $.logicsManager.functionDelegateCall(
            abi.encodeCall(
                ILendingLogicsManager.registerBorrowIntentLogic,
                (intent, domainSeparator(), BORROWER_INTENT_TYPEHASH, CONDITION_TYPEHASH, HOOK_TYPEHASH)
            )
        );
    }

    /// @notice Revokes an on-chain borrower intent
    function revokeBorrowIntentByHash(bytes32 intentHash) external nonReentrant onlyWhenCircuitBreakerNotActive {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        $.logicsManager.functionDelegateCall(
            abi.encodeCall(ILendingLogicsManager.revokeBorrowIntentByHashLogic, (intentHash))
        );
    }

    // ============ Loan Operations ============
    /// @notice Repays part or all of a loan
    function repayLoan(uint256 loanId, uint256 repayAmount, uint256 maxTotalRepayment)
        external
        nonReentrant
        onlyWhenCircuitBreakerNotActive
        onlyWhenRepayNotPaused(LendingStorageLib._getLendingStorage().loans[loanId].marketId)
    {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        $.logicsManager.functionDelegateCall(
            abi.encodeCall(ILendingLogicsManager.repayLoanLogic, (loanId, repayAmount, maxTotalRepayment))
        );
    }

    /// @notice Liquidates an unhealthy loan
    function liquidateLoan(uint256 loanId, uint256 repayAmount, uint256 maxTotalRepayment)
        external
        nonReentrant
        onlyWhenCircuitBreakerNotActive
        onlyWhenLiquidateNotPaused(LendingStorageLib._getLendingStorage().loans[loanId].marketId)
    {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        // All validation (repaid check, health check) moved to LogicsManager
        $.logicsManager.functionDelegateCall(
            abi.encodeCall(ILendingLogicsManager.liquidateLoanLogic, (loanId, repayAmount, maxTotalRepayment))
        );
    }

    /// @notice Liquidates an unhealthy loan with a callback for zero-capital liquidation
    /// @dev Sends collateral to msg.sender first, invokes callback, then pulls loan token payment.
    ///      If data is empty, no callback is invoked (behaves like a send-first liquidateLoan).
    /// @param loanId The loan to liquidate
    /// @param repayAmount Principal amount to repay
    /// @param maxTotalRepayment Maximum total the liquidator is willing to pay (slippage protection)
    /// @param data Arbitrary data passed to onLiquidationCallback. Empty = no callback.
    function liquidateWithCallback(
        uint256 loanId,
        uint256 repayAmount,
        uint256 maxTotalRepayment,
        bytes calldata data
    )
        external
        nonReentrant
        onlyWhenCircuitBreakerNotActive
        onlyWhenLiquidateNotPaused(LendingStorageLib._getLendingStorage().loans[loanId].marketId)
    {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        $.logicsManager.functionDelegateCall(
            abi.encodeCall(
                ILendingLogicsManager.liquidateWithCallbackLogic,
                (loanId, repayAmount, maxTotalRepayment, data)
            )
        );
    }

    /// @notice Adds collateral to an active loan
    function addCollateral(uint256 loanId, uint256 amount)
        external
        nonReentrant
        onlyWhenCircuitBreakerNotActive
        onlyWhenAddCollateralNotPaused(LendingStorageLib._getLendingStorage().loans[loanId].marketId)
    {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        $.logicsManager.functionDelegateCall(
            abi.encodeCall(ILendingLogicsManager.addCollateralLogic, (loanId, amount))
        );
    }

    /// @notice Withdraws collateral from an active loan
    function withdrawCollateral(uint256 loanId, uint256 amount)
        external
        nonReentrant
        onlyWhenCircuitBreakerNotActive
        onlyWhenWithdrawCollateralNotPaused(LendingStorageLib._getLendingStorage().loans[loanId].marketId)
    {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        // All validation (borrower check, amount checks, health check) moved to LogicsManager
        $.logicsManager.functionDelegateCall(
            abi.encodeCall(ILendingLogicsManager.withdrawCollateralLogic, (loanId, amount))
        );
    }

    // ============ Flash Loans ============
    /// @notice Executes a flash loan
    function flashLoan(address token, uint256 amount, bytes calldata data) external nonReentrant onlyWhenCircuitBreakerNotActive {
        LendingStorageLib.LendingStorage storage $ = LendingStorageLib._getLendingStorage();
        $.logicsManager.functionDelegateCall(
            abi.encodeCall(ILendingLogicsManager.flashLoanLogic, (token, amount, data))
        );
    }

}
