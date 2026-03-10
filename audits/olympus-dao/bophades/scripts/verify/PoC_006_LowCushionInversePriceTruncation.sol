// SPDX-License-Identifier: Unlicense
pragma solidity >=0.8.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Demonstrates ERC4626 rounding gap in _regenerate approval logic
/// @dev This PoC corresponds to Finding 006 (Clearinghouse keeper reward accounting)
/// @dev but the original numbering is preserved for consistency
contract PoC_006_RoundingGap is Test {

    // Simplified ERC4626 math
    uint256 totalAssets = 100_000_000e18 + 1;
    uint256 totalSupply = 100_000_000e18;

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return shares * totalAssets / totalSupply;
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return (assets * totalSupply + totalAssets - 1) / totalAssets;
    }

    function test_roundingGapAccumulation() public {
        uint256 approvalShares = 10_000_000e18;
        uint256 desiredCapacity = 10_000_000e18;

        uint256 approvalAssets = previewRedeem(approvalShares);
        console2.log("Approval in assets:", approvalAssets);
        console2.log("Desired capacity:", desiredCapacity);

        if (approvalAssets < desiredCapacity) {
            uint256 deficit = desiredCapacity - approvalAssets;
            uint256 sharesToAdd = previewWithdraw(deficit);
            uint256 newApproval = approvalShares + sharesToAdd;
            uint256 newAssets = previewRedeem(newApproval);
            console2.log("New approval assets:", newAssets);
            console2.log("Overshoot:", newAssets > desiredCapacity ? newAssets - desiredCapacity : 0);
        }
    }
}
