// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./IGToken.sol";

/**
 * @dev Interface for GTokenLockedDepositNftDesign contract
 */
interface IGTokenLockedDepositNftDesign {
    function buildTokenURI(
        uint256 tokenId,
        IGToken.LockedDeposit memory lockedDeposit,
        string memory gTokenSymbol,
        string memory assetSymbol,
        uint8 numberInputDecimals,
        uint8 numberOutputDecimals
    ) external pure returns (string memory);
}
