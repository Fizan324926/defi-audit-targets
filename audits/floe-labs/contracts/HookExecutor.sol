// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Roles} from "../governance/Roles.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {Hook} from "../interfaces/ILendingTypes.sol";
import {IHookExecutor} from "../interfaces/IHookExecutor.sol";
import {CallWithExactGas} from "../libraries/CallWithExactGas.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {EventsLib} from "../libraries/EventsLib.sol";

/// @title HookExecutorUpgradeable
/// @notice UUPS upgradeable hook executor for intent-based lending
/// @dev Implements ERC-7201 namespaced storage
/// @dev Executes user-specified hooks in an isolated context to prevent privileged execution
contract HookExecutorUpgradeable is Initializable, UUPSUpgradeable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, IHookExecutor {
    using CallWithExactGas for bytes;

    // ============ ERC-7201 Storage ============
    /// @custom:storage-location erc7201:floe.storage.HookExecutor
    struct HookExecutorStorage {
        /// @dev The address of the LendingIntentMatcher contract
        address lendingIntentMatcher;
        /// @notice Gas amount reserved for the exact EXTCODESIZE call
        uint32 gasForCallExactCheck;
        /// @dev Reserved for future upgrades (50 slots standard)
        uint256[50] __gap;
    }

    /// @dev Computed via: keccak256(abi.encode(uint256(keccak256("floe.storage.HookExecutor")) - 1)) & ~bytes32(uint256(0xff))
    /// @dev Verified by: script/ComputeSlots.s.sol
    bytes32 private constant HOOK_EXECUTOR_STORAGE_SLOT =
        0xcdcb582c3c88ec404152083243da4c514ebd757171385e4695903e4100e5cf00;

    function _getHookExecutorStorage() private pure returns (HookExecutorStorage storage $) {
        assembly {
            $.slot := HOOK_EXECUTOR_STORAGE_SLOT
        }
    }

    // ============ Constructor ============
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============
    /// @notice Initializes the upgradeable hook executor
    /// @param admin_ The default admin address (can grant/revoke roles)
    /// @param protocolAdmin_ The protocol admin address (manages protocol config)
    /// @param upgrader_ The upgrader address (should be TimelockController)
    /// @param lendingIntentMatcher_ The address of the LendingIntentMatcher contract
    function initialize(
        address admin_,
        address protocolAdmin_,
        address upgrader_,
        address lendingIntentMatcher_
    ) external initializer {
        if (lendingIntentMatcher_ == address(0)) revert ErrorsLib.ZeroAddress();

        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        // Grant roles
        _grantRole(Roles.DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(Roles.PROTOCOL_ADMIN_ROLE, protocolAdmin_);
        _grantRole(Roles.UPGRADER_ROLE, upgrader_);

        HookExecutorStorage storage $ = _getHookExecutorStorage();
        $.lendingIntentMatcher = lendingIntentMatcher_;
        $.gasForCallExactCheck = 5_000;

        emit EventsLib.LendingIntentMatcherUpdated(address(0), lendingIntentMatcher_);
    }

    // ============ Upgrade Authorization ============
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(Roles.UPGRADER_ROLE) {}

    // ============ Modifiers ============
    /// @dev Modifier that ensures that the `msg.sender` is the LendingIntentMatcher contract
    modifier onlyLendingIntentMatcher() {
        HookExecutorStorage storage $ = _getHookExecutorStorage();
        if (msg.sender != $.lendingIntentMatcher) {
            revert ErrorsLib.NotLendingIntentMatcher();
        }
        _;
    }

    // ============ Core Functions ============
    /// @dev Executes the user specified hooks. Called only by the LendingIntentMatcher contract.
    /// Each hook is executed with the specified gas limit, and failure does not revert the entire transaction.
    /// Each hook is only executed before the specified expiry timestamp.
    /// @param hooks The hooks to execute.
    function execute(Hook[] calldata hooks) external nonReentrant onlyLendingIntentMatcher {
        HookExecutorStorage storage $ = _getHookExecutorStorage();
        uint32 gasCheck = $.gasForCallExactCheck;

        unchecked {
            for (uint256 i = 0; i < hooks.length; ++i) {
                Hook calldata hook = hooks[i];

                // Skip expired hooks
                if (block.timestamp > hook.expiry) {
                    continue;
                }

                (bool success, bool sufficientGas) =
                    hook.callData._callWithExactGasEvenIfTargetIsNoContract(hook.target, hook.gasLimit, gasCheck);

                if (!sufficientGas) {
                    // Insufficient gas to execute the hook
                    emit EventsLib.HookExecutionInsufficientGas(hook.target, hook.gasLimit);
                    if (!hook.allowFailure) {
                        // Revert if insufficient gas and failure is not allowed
                        revert ErrorsLib.HookExecutionInsufficientGas(hook.target, hook.gasLimit);
                    }
                } else if (!success) {
                    // Hook execution failed (sufficient gas was available)
                    emit EventsLib.HookExecutionFailed(hook.target, success);
                    if (!hook.allowFailure) {
                        // Revert if the call fails and failure is not allowed
                        revert ErrorsLib.HookExecutionFailed(hook.target);
                    }
                } else {
                    // Hook executed successfully
                    emit EventsLib.HookExecuted(hook.target, success);
                }
            }
        }
    }

    // ============ Admin Functions ============
    /// @notice Updates the gas reserved for the exact EXTCODESIZE call and related checks
    /// @dev Only callable by the LendingIntentMatcher contract
    /// @param gasForCallExactCheck_ The new gas amount to reserve for the exact call check
    function setGasForCallExactCheck(uint32 gasForCallExactCheck_) external onlyLendingIntentMatcher {
        HookExecutorStorage storage $ = _getHookExecutorStorage();
        $.gasForCallExactCheck = gasForCallExactCheck_;
        emit EventsLib.GasForCallExactCheckSet(gasForCallExactCheck_);
    }

    /// @notice Updates the LendingIntentMatcher address
    /// @dev Only callable by PROTOCOL_ADMIN_ROLE
    /// @param newMatcher The new LendingIntentMatcher address
    function setLendingIntentMatcher(address newMatcher) external onlyRole(Roles.PROTOCOL_ADMIN_ROLE) {
        if (newMatcher == address(0)) revert ErrorsLib.ZeroAddress();
        HookExecutorStorage storage $ = _getHookExecutorStorage();
        address oldMatcher = $.lendingIntentMatcher;
        $.lendingIntentMatcher = newMatcher;
        emit EventsLib.LendingIntentMatcherUpdated(oldMatcher, newMatcher);
    }

    // ============ View Functions ============
    /// @notice Returns the LendingIntentMatcher address
    function getLendingIntentMatcher() external view returns (address) {
        HookExecutorStorage storage $ = _getHookExecutorStorage();
        return $.lendingIntentMatcher;
    }

    /// @notice Returns the gas for call exact check
    function getGasForCallExactCheck() external view returns (uint32) {
        HookExecutorStorage storage $ = _getHookExecutorStorage();
        return $.gasForCallExactCheck;
    }
}
