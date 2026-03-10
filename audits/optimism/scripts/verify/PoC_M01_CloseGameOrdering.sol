// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "forge-std/Test.sol";

/// @title PoC: SuperFaultDisputeGame.closeGame() Ordering Bug
/// @notice Demonstrates that SuperFaultDisputeGame blocks claimCredit() during
///         system pause even after bond distribution mode is decided, while
///         FaultDisputeGame correctly allows it.
contract CloseGameOrderingPoC is Test {

    enum BondDistributionMode { UNDECIDED, NORMAL, REFUND }

    bool public systemPaused;
    BondDistributionMode public bondDistributionMode_super;
    BondDistributionMode public bondDistributionMode_fault;
    mapping(address => uint256) public credits;

    error GamePaused();
    error NoCreditToClaim();

    function setPaused(bool _paused) external {
        systemPaused = _paused;
    }

    function setBondMode(bool isSuper, BondDistributionMode mode) external {
        if (isSuper) {
            bondDistributionMode_super = mode;
        } else {
            bondDistributionMode_fault = mode;
        }
    }

    function setCredit(address recipient, uint256 amount) external {
        credits[recipient] = amount;
    }

    /// @notice SuperFaultDisputeGame.closeGame() — BUG: pause check BEFORE early return
    /// @dev Mirrors SuperFaultDisputeGame.sol lines 1007-1025
    function closeGame_Super() public {
        // Line 1013: Pause check FIRST (should be second)
        if (systemPaused) {
            revert GamePaused();
        }
        // Line 1018: Early return SECOND (never reached during pause)
        if (bondDistributionMode_super == BondDistributionMode.REFUND
            || bondDistributionMode_super == BondDistributionMode.NORMAL)
        {
            return;
        }
    }

    /// @notice FaultDisputeGame.closeGame() — CORRECT: early return BEFORE pause check
    /// @dev Mirrors FaultDisputeGame.sol lines 1026-1045
    function closeGame_Fault() public {
        // Line 1027: Early return FIRST (correct)
        if (bondDistributionMode_fault == BondDistributionMode.REFUND
            || bondDistributionMode_fault == BondDistributionMode.NORMAL)
        {
            return;
        }
        // Line 1043: Pause check SECOND (only reached if UNDECIDED)
        if (systemPaused) {
            revert GamePaused();
        }
    }

    /// @notice Simulated claimCredit for SuperFaultDisputeGame
    function claimCredit_Super(address recipient) external {
        closeGame_Super(); // Reverts during pause even if mode decided!
        uint256 credit = credits[recipient];
        if (credit == 0) revert NoCreditToClaim();
        credits[recipient] = 0;
    }

    /// @notice Simulated claimCredit for FaultDisputeGame
    function claimCredit_Fault(address recipient) external {
        closeGame_Fault(); // Does NOT revert during pause if mode decided
        uint256 credit = credits[recipient];
        if (credit == 0) revert NoCreditToClaim();
        credits[recipient] = 0;
    }

    // =========================================================================
    // Tests
    // =========================================================================

    /// @notice FaultDisputeGame: claimCredit succeeds during pause (CORRECT)
    function test_FaultDisputeGame_ClaimCreditDuringPause_Succeeds() external {
        // Setup: game resolved, bond distribution decided, user has credit
        this.setBondMode(false, BondDistributionMode.NORMAL);
        this.setCredit(address(0xBEEF), 1 ether);

        // Pause the system (simulating Guardian calling SuperchainConfig.pause())
        this.setPaused(true);

        // FaultDisputeGame: claimCredit succeeds during pause
        this.claimCredit_Fault(address(0xBEEF));

        // Credit claimed successfully
        assertEq(credits[address(0xBEEF)], 0, "Credit should be claimed");
    }

    /// @notice SuperFaultDisputeGame: claimCredit REVERTS during pause (BUG)
    function test_SuperFaultDisputeGame_ClaimCreditDuringPause_Reverts() external {
        // Setup: IDENTICAL to above
        this.setBondMode(true, BondDistributionMode.NORMAL);
        this.setCredit(address(0xCAFE), 1 ether);

        // Pause the system
        this.setPaused(true);

        // SuperFaultDisputeGame: claimCredit REVERTS during pause
        vm.expectRevert(GamePaused.selector);
        this.claimCredit_Super(address(0xCAFE));

        // Credit was NOT claimed — funds are frozen!
        assertEq(credits[address(0xCAFE)], 1 ether, "Credit should still be locked");
    }

    /// @notice Both games work identically when NOT paused
    function test_BothGames_ClaimCredit_WhenNotPaused_Succeeds() external {
        // Setup for both
        this.setBondMode(true, BondDistributionMode.NORMAL);
        this.setBondMode(false, BondDistributionMode.NORMAL);
        this.setCredit(address(0xBEEF), 1 ether);
        this.setCredit(address(0xCAFE), 1 ether);

        // System NOT paused
        this.setPaused(false);

        // Both succeed
        this.claimCredit_Fault(address(0xBEEF));
        this.claimCredit_Super(address(0xCAFE));

        assertEq(credits[address(0xBEEF)], 0);
        assertEq(credits[address(0xCAFE)], 0);
    }

    /// @notice REFUND mode also affected
    function test_SuperFaultDisputeGame_RefundMode_AlsoBlocked() external {
        this.setBondMode(true, BondDistributionMode.REFUND);
        this.setCredit(address(0xDEAD), 2 ether);
        this.setPaused(true);

        vm.expectRevert(GamePaused.selector);
        this.claimCredit_Super(address(0xDEAD));

        assertEq(credits[address(0xDEAD)], 2 ether, "Refund credit should still be locked");
    }
}
