// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {LendIntent, BorrowIntent, Hook, Condition} from "../interfaces/ILendingTypes.sol";
import {ChainIdLib} from "./ChainIdLib.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title IntentLib
/// @notice Library for hashing and verifying intents according to EIP-712
library IntentLib {
    /// @notice Hashes a lender intent according to EIP-712 domain separation.
    /// @param i The lender intent struct.
    /// @param DOMAIN_SEPARATOR The EIP-712 domain separator.
    /// @param LENDER_INTENT_TYPEHASH The typehash for lender intents.
    /// @param CONDITION_TYPEHASH The typehash for conditions.
    /// @param HOOK_TYPEHASH The typehash for hooks.
    /// @return The keccak256 hash of the lender intent.
    function hashLender(
        LendIntent memory i,
        bytes32 DOMAIN_SEPARATOR,
        bytes32 LENDER_INTENT_TYPEHASH,
        bytes32 CONDITION_TYPEHASH,
        bytes32 HOOK_TYPEHASH
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(
                    abi.encode(
                        LENDER_INTENT_TYPEHASH,
                        i.lender,
                        i.onBehalfOf,
                        i.amount,
                        i.minFillAmount,
                        i.filledAmount,
                        i.minInterestRateBps,
                        i.maxLtvBps,
                        i.minDuration,
                        i.maxDuration,
                        i.allowPartialFill,
                        i.validFromTimestamp,
                        i.expiry,
                        i.marketId,
                        i.salt,
                        ChainIdLib.getChainId(),
                        hashConditionArray(i.conditions, CONDITION_TYPEHASH),
                        hashHooks(i.preHooks, HOOK_TYPEHASH),
                        hashHooks(i.postHooks, HOOK_TYPEHASH)
                    )
                )
            )
        );
    }

    /// @notice Hashes a borrower intent according to EIP-712 domain separation.
    /// @param i The borrower intent struct.
    /// @param DOMAIN_SEPARATOR The EIP-712 domain separator.
    /// @param BORROWER_INTENT_TYPEHASH The typehash for borrower intents.
    /// @param CONDITION_TYPEHASH The typehash for conditions.
    /// @param HOOK_TYPEHASH The typehash for hooks.
    /// @return The keccak256 hash of the borrower intent.
    function hashBorrower(
        BorrowIntent memory i,
        bytes32 DOMAIN_SEPARATOR,
        bytes32 BORROWER_INTENT_TYPEHASH,
        bytes32 CONDITION_TYPEHASH,
        bytes32 HOOK_TYPEHASH
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(
                    abi.encode(
                        BORROWER_INTENT_TYPEHASH,
                        i.borrower,
                        i.onBehalfOf,
                        i.borrowAmount,
                        i.collateralAmount,
                        i.minFillAmount,
                        i.maxInterestRateBps,
                        i.minLtvBps,
                        i.minDuration,
                        i.maxDuration,
                        i.allowPartialFill,
                        i.validFromTimestamp,
                        i.matcherCommissionBps,
                        i.expiry,
                        i.marketId,
                        i.salt,
                        ChainIdLib.getChainId(),
                        hashConditionArray(i.conditions, CONDITION_TYPEHASH),
                        hashHooks(i.preHooks, HOOK_TYPEHASH),
                        hashHooks(i.postHooks, HOOK_TYPEHASH)
                    )
                )
            )
        );
    }

    /// @notice Hashes an array of hooks.
    /// @param hooks The array of hooks.
    /// @param HOOK_TYPEHASH The typehash for hooks.
    /// @return The keccak256 hash of the hooks array.
    function hashHooks(Hook[] memory hooks, bytes32 HOOK_TYPEHASH) internal pure returns (bytes32) {
        bytes32[] memory hookHashes = new bytes32[](hooks.length);
        for (uint256 i = 0; i < hooks.length; i++) {
            hookHashes[i] = keccak256(
                abi.encode(
                    HOOK_TYPEHASH,
                    hooks[i].target,
                    hooks[i].callData,
                    hooks[i].gasLimit,
                    hooks[i].expiry,
                    hooks[i].allowFailure,
                    hooks[i].applyToAllPartialFills
                )
            );
        }
        return keccak256(abi.encodePacked(hookHashes));
    }

    /// @notice Hashes an array of conditions.
    /// @param conditions The array of conditions.
    /// @param CONDITION_TYPEHASH The typehash for conditions.
    /// @return The keccak256 hash of the conditions array.
    function hashConditionArray(Condition[] memory conditions, bytes32 CONDITION_TYPEHASH)
        internal
        pure
        returns (bytes32)
    {
        bytes32[] memory conditionHashes = new bytes32[](conditions.length);
        for (uint256 i = 0; i < conditions.length; i++) {
            conditionHashes[i] = hashCondition(conditions[i], CONDITION_TYPEHASH);
        }
        return keccak256(abi.encodePacked(conditionHashes));
    }

    /// @notice Hashes a single condition.
    /// @param condition The condition to hash.
    /// @param CONDITION_TYPEHASH The typehash for conditions.
    /// @return The keccak256 hash of the condition.
    function hashCondition(Condition memory condition, bytes32 CONDITION_TYPEHASH) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                CONDITION_TYPEHASH,
                condition.target,
                keccak256(condition.callData),
                condition.applyToAllPartialFills
            )
        );
    }

    /// @notice Verifies a signature, supporting both EOAs and ERC-1271 contracts.
    /// @dev Attempts ECDSA recovery first, then falls back to ERC-1271 validation.
    /// @param digest The hashed message that was signed.
    /// @param signer The address expected to have signed the message.
    /// @param sig The signature bytes.
    /// @return True if the signature is valid, false otherwise.
    function verifySignature(bytes32 digest, address signer, bytes memory sig) internal view returns (bool) {
        // First, try ECDSA signature recovery (works for EOAs and EIP-7702 accounts)
        if (sig.length == 65) {
            address recovered = ECDSA.recover(digest, sig);
            if (recovered == signer) {
                return true;
            }
        }

        // If ECDSA fails, try ERC-1271 smart contract validation
        if (signer.code.length > 0) {
            bytes4 magicValue = IERC1271.isValidSignature.selector;
            (bool success, bytes memory result) = signer.staticcall(
                abi.encodeWithSelector(IERC1271.isValidSignature.selector, digest, sig)
            );
            if (!success || result.length != 32) {
                return false;
            }
            bytes32 resultBytes32 = bytes32(result);
            return resultBytes32 == bytes32(magicValue);
        }

        return false;
    }
}
