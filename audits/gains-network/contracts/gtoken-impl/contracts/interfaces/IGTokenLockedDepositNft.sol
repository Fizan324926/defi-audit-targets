// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import "./IGTokenLockedDepositNftDesign.sol";

/**
 * @dev Interface for GTokenLockedDepositNft contract
 */
interface IGTokenLockedDepositNft is IERC721 {
    function mint(address to, uint256 tokenId) external;

    function burn(uint256 tokenId) external;

    event DesignUpdated(IGTokenLockedDepositNftDesign newValue);
    event DesignDecimalsUpdated(uint8 newValue);
}
