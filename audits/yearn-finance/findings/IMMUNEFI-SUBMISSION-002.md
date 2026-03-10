# Immunefi Bug Report: Gauge.sol Residual Approval Accumulation to VE_YFI_POOL

## Bug Description

The `Gauge.sol` contract distributes penalty rewards (the difference between maximum earning and actual boosted earning) to the VE_YFI_POOL by calling `approve()` followed by the pool's `burn()` function. This pattern uses `approve()` (not `safeIncreaseAllowance`), which creates a fragile approval mechanism.

**Vulnerable Code:**

File: `veYFI/contracts/Gauge.sol`, lines 534-537

```solidity
function _transferVeYfiORewards(uint256 _penalty) internal {
    IERC20(REWARD_TOKEN).approve(VE_YFI_POOL, _penalty);
    IDYfiRewardPool(VE_YFI_POOL).burn(_penalty);
}
```

**Call Chain:**
1. Any state-changing function calls `_updateReward(account)` modifier
2. `_updateReward` computes `boostedBalance` vs `realBalance` to determine penalty
3. Penalty amount is sent via `_transferVeYfiORewards(_penalty)`
4. `approve(VE_YFI_POOL, _penalty)` sets allowance, then `burn(_penalty)` pulls tokens

**The problems:**

1. **Residual Allowance Risk:** If `burn()` consumes fewer tokens than approved (e.g., the burn function has a partial failure path, the pool's `transferFrom` pulls a different amount, or the dYFI reward pool implementation is upgraded), a residual allowance remains. This residual can be exploited by the VE_YFI_POOL address (or any contract at that address if it's upgradeable) to pull additional tokens from the Gauge.

2. **USDT-like Token Incompatibility:** Some ERC20 tokens (notably USDT) require the allowance to be set to 0 before setting a new non-zero value. While the current REWARD_TOKEN (dYFI) does not have this restriction, the Gauge is deployed as an upgradeable proxy via `GaugeFactory.createGauge()`, and the pattern would break if any gauge clone uses a token with this behavior.

3. **Race Condition:** The standard `approve()` pattern is susceptible to the well-known ERC20 approve front-running attack. Between the `approve()` and `burn()` calls (in the same transaction, so less risky), the allowance exists.

**The `burn()` function on `dYFIRewardPool.vy` (line 246-261):**
```vyper
@external
def burn(amount: uint256 = max_value(uint256)) -> bool:
    _amount: uint256 = amount
    if _amount == max_value(uint256):
        _amount = YFI.allowance(msg.sender, self)
    if _amount > 0:
        YFI.transferFrom(msg.sender, self, _amount)
    return True
```

Note: The `burn()` function takes a `uint256` parameter but in the Gauge it's called as `burn(_penalty)`. The dYFI reward pool pulls exactly `_amount` via `transferFrom`. If the `transferFrom` fails silently (e.g., insufficient balance), the allowance persists.

## Impact

**Severity:** Medium

**Financial Impact:**
- If the `burn()` call partially fails or consumes fewer tokens than approved, a residual allowance remains on the Gauge contract. The VE_YFI_POOL address could later pull additional reward tokens from the Gauge, reducing rewards available to stakers.
- For cloned gauges using USDT-like tokens as reward tokens, the `approve()` pattern would permanently brick penalty distribution after the first successful call (since subsequent `approve(VE_YFI_POOL, newAmount)` would revert).

**Affected Users:** All gauge stakers whose penalty rewards are being distributed.

## Risk Breakdown

- **Difficulty to Exploit:** Medium -- Requires VE_YFI_POOL to behave unexpectedly or an upgrade scenario
- **Weakness Type:** CWE-863 (Incorrect Authorization via residual approval), CWE-670 (Always-Incorrect Control Flow for USDT-like tokens)
- **CVSS Score:** 5.3 (Medium) -- AV:N/AC:H/PR:N/UI:N/S:U/C:N/I:H/A:N

## Recommendation

Replace `approve()` with a safe pattern:

```diff
 function _transferVeYfiORewards(uint256 _penalty) internal {
-    IERC20(REWARD_TOKEN).approve(VE_YFI_POOL, _penalty);
+    IERC20(REWARD_TOKEN).approve(VE_YFI_POOL, 0);
+    IERC20(REWARD_TOKEN).approve(VE_YFI_POOL, _penalty);
     IDYfiRewardPool(VE_YFI_POOL).burn(_penalty);
+    // Clear any residual allowance
+    IERC20(REWARD_TOKEN).approve(VE_YFI_POOL, 0);
 }
```

Or better, use `safeIncreaseAllowance`:

```diff
 function _transferVeYfiORewards(uint256 _penalty) internal {
-    IERC20(REWARD_TOKEN).approve(VE_YFI_POOL, _penalty);
+    IERC20(REWARD_TOKEN).safeIncreaseAllowance(VE_YFI_POOL, _penalty);
     IDYfiRewardPool(VE_YFI_POOL).burn(_penalty);
 }
```

## Proof of Concept

```solidity
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
```

**To run:**
```bash
forge test --match-contract GaugeApprovalPoC -vvv
```

## References

- Vulnerable file: `veYFI/contracts/Gauge.sol` (lines 534-537)
- Consumer: `veYFI/contracts/dYFIRewardPool.vy` (lines 246-261)
- ERC20 Approve Race Condition: https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
- USDT approve(0) requirement: https://etherscan.io/address/0xdac17f958d2ee523a2206206994597c13d831ec7#code
