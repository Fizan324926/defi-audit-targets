// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../interfaces/IWETH9.sol";
import "../interfaces/IERC20.sol";

/**
 * @dev Library to handle transfers of tokens, including native tokens.
 */
library TokenTransferUtils {
    using SafeERC20 for IERC20;

    /**
     * @dev Unwraps and transfers `_amount` of native tokens to a recipient, `_to`.
     *
     * IMPORTANT:
     * If the recipient does not accept the native transfer then the tokens are re-wrapped and transferred as ERC20.
     * Always ensure CEI pattern is followed or reentrancy guards are in place before performing native transfers.
     *
     * @param _token the wrapped native token address
     * @param _to the recipient
     * @param _amount the amount of tokens to transfer
     * @param _gasLimit how much gas to forward.
     */
    function unwrapAndTransferNative(address _token, address _to, uint256 _amount, uint256 _gasLimit) internal {
        // 1. Unwrap `_amount` of `_token`
        IWETH9(_token).withdraw(_amount);

        // 2. Attempt to transfer native tokens
        // Uses low-level call and loads no return data into memory to prevent `returnbomb` attacks
        // See https://gist.github.com/pcaversaccio/3b487a24922c839df22f925babd3c809 for an example
        bool success;
        assembly {
            // call(gas, address, value, argsOffset, argsSize, retOffset, retSize)
            success := call(_gasLimit, _to, _amount, 0, 0, 0, 0)
        }

        // 3. If the native transfer was successful, return
        if (success) return;

        // 4. Otherwise re-wrap `_amount` of `_token`
        IWETH9(_token).deposit{value: _amount}();

        // 5. Send with an ERC20 transfer
        transfer(_token, _to, _amount);
    }

    /**
     * @dev Transfers `_amount` of `_token` to a recipient, `to`
     * @param _token the token address
     * @param _to the recipient
     * @param _amount amount of tokens to transfer
     */
    function transfer(address _token, address _to, uint256 _amount) internal {
        IERC20(_token).safeTransfer(_to, _amount);
    }

    /**
     * @dev Transfers `_amount` of `_token` from a sender, `_from`, to a recipient, `to`.
     * @param _token the token address
     * @param _from the sender
     * @param _to the recipient
     * @param _amount amount of tokens to transfer
     */
    function transferFrom(address _token, address _from, address _to, uint256 _amount) internal {
        IERC20(_token).safeTransferFrom(_from, _to, _amount);
    }
}
