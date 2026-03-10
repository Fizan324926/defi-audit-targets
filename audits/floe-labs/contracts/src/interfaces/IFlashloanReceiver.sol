// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8;

/// @title IFlashloanReceiver
/// @notice Interface for contracts that want to handle flashloans
interface IFlashloanReceiver {
    /**
     * @notice Called after your contract has received the flashloaned amount
     * @param token The address of the token being flashloaned
     * @param amount The amount of tokens received
     * @param fee The fee to be paid for the flashloan
     * @param data Arbitrary data passed from the flashloan initiator
     */
    function receiveFlashLoan(address token, uint256 amount, uint256 fee, bytes calldata data) external;
}
