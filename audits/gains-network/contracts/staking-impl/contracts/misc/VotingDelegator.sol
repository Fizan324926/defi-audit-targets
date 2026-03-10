// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/**
 *
 * @dev Abstract contract that handles delegating governance votes of an asset when possible.
 * Compatible with any token that extends OpenZeppelin ERC20Votes/ERC20VotesUpgradeable or implements `delegate(address)`
 */
abstract contract VotingDelegator {
    event Delegated(address indexed asset, address indexed delegatee, bool success);

    /**
     * @dev Calls `delegate(address)` on `_asset`. Does not revert if function is not supported by `_asset`.
     *
     * Emits {Delegated} with `_asset`, `_delegatee` and `success` flag
     */
    function _tryDelegate(address _asset, address _delegatee) internal {
        (bool success, ) = _asset.call(abi.encodeWithSignature("delegate(address)", _delegatee));
        emit Delegated(_asset, _delegatee, success);
    }
}
