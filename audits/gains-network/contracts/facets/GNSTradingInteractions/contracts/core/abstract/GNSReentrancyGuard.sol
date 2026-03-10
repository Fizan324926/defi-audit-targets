// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../../libraries/ChainConfigUtils.sol";

/**
 * @dev Reentrancy guard contract for the diamond. Uses `ChainConfigStorage.reentrancyLock` state var as the locking slot.
 *
 * Based on https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.5/contracts/security/ReentrancyGuard.sol
 */
abstract contract GNSReentrancyGuard {
    error ReentrancyGuardReentrantCall();

    uint256 private constant UNLOCKED = 0;
    uint256 private constant LOCKED = 1;

    /**
     * @dev Prevents the diamond from calling other `nonReentrant` functions, directly or indirectly.
     */
    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    /**
     * @dev `nonReentrant` modifier helper. Ensures reentrancy guard is UNLOCKED and then updates it to LOCKED.
     *
     * Reverts with {ReentrancyGuardReentrantCall()} if guard is LOCKED.
     */
    function _nonReentrantBefore() internal {
        // If state is currently LOCKED, revert with `ReentrancyGuardReentrantCall()`
        if (_reentrancyGuardLocked()) {
            revert ReentrancyGuardReentrantCall();
        }

        // Set state to LOCKED
        _setReentrancyGuard(LOCKED);
    }

    /**
     * @dev `nonReentrant` modifier helper. Sets reentrancy guard to UNLOCKED.
     */
    function _nonReentrantAfter() internal {
        _setReentrancyGuard(UNLOCKED);
    }

    /**
     * @dev Updated the value of the reentrancy guard slot
     * @param _value the new reentrancy guard value
     */
    function _setReentrancyGuard(uint256 _value) private {
        uint256 storageSlot = ChainConfigUtils._getSlot();
        assembly {
            sstore(storageSlot, _value)
        }
    }

    /**
     * @dev Returns whether reentrancy guard is set to LOCKED
     */
    function _reentrancyGuardLocked() internal view returns (bool isLocked) {
        uint256 storageSlot = ChainConfigUtils._getSlot();
        assembly {
            isLocked := eq(sload(storageSlot), LOCKED)
        }
    }
}
