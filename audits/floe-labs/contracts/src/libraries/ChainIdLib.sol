// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8;

/// @title Function for getting the current chain ID
library ChainIdLib {
    /// @dev Gets the current chain ID
    /// @return chainId The current chain ID
    function getChainId() internal view returns (uint256 chainId) {
        chainId = block.chainid;
    }
}
