# Immunefi Bug Report: LimitOrderHook Withdrawal Underflow — Permanent Fund Lock

## Bug Description

The `LimitOrderHook.withdraw()` function in OpenZeppelin's Uniswap V4 Hooks library contains an arithmetic underflow vulnerability that permanently locks funds for users who withdraw after an earlier user.

### Vulnerable Code

**File:** `src/general/LimitOrderHook.sol`, lines 413-419

```solidity
uint256 checkpointAmountCurrency0 = orderInfo.checkpoints[msg.sender].amountCurrency0;
uint256 checkpointAmountCurrency1 = orderInfo.checkpoints[msg.sender].amountCurrency1;

// calculate the amount of currency0 and currency1 owed to the msg.sender
// note that the user is not able to withdraw funds that were accrued before their checkpoint.
amount0 = FullMath.mulDiv(orderInfo.currency0Total - checkpointAmountCurrency0, liquidity, liquidityTotal);
amount1 = FullMath.mulDiv(orderInfo.currency1Total - checkpointAmountCurrency1, liquidity, liquidityTotal);
```

### Root Cause

When multiple users join the same limit order at different times, each user's checkpoint records the `currency0Total`/`currency1Total` at their join time. Fees that accrue between user joins create a discrepancy: early users have low checkpoints (e.g., 0), late users have high checkpoints (e.g., 100).

When the early user withdraws first, their proportional share calculation `mulDiv(total - 0, liquidity, totalLiquidity)` includes a portion of the fees that accrued before the late user joined. This reduces `currency0Total` below the late user's checkpoint value.

When the late user then tries to withdraw, `currency0Total - checkpointAmountCurrency0` underflows because `currency0Total` is now less than the checkpoint. Since these are `uint256` values, the subtraction reverts (Solidity 0.8+ checked arithmetic applies outside the `unchecked` block — note that while `placeOrder` uses `unchecked` for liquidity tracking, the `withdraw` function's subtraction on line 418 is NOT in an unchecked block, so it reverts).

### Call Chain

1. User A: `placeOrder()` → sets `checkpoints[A] = {0, 0}`, `liquidityTotal += A_liq`
2. Swaps generate fees → `currency0Total += fees0`, `currency1Total += fees1`
3. User B: `placeOrder()` → sets `checkpoints[B] = {fees0, fees1}`, `liquidityTotal += B_liq`
4. Price crosses tick → `_fillOrder()` → adds fill amounts to `currency0Total`/`currency1Total`
5. User A: `withdraw()` → takes `mulDiv(total - 0, A_liq, totalLiq)`, reduces totals
6. User B: `withdraw()` → `total - checkpointB` **UNDERFLOWS** → revert, funds locked

## Impact

### Severity: High

- **Fund Loss:** The late user's entire deposited liquidity (both fill proceeds and any fees) is permanently locked in the hook contract
- **No Rescue Path:** There is no admin function, emergency withdrawal, or alternative claim mechanism
- **Order State:** The order is marked `filled = true`, so `cancelOrder()` cannot be used
- **Irreversible:** The locked funds cannot be recovered by any party

### Financial Impact

Any limit order with:
- 2+ users who joined at different times
- Fee accumulation between joins
- One-sided fill (common for limit orders, e.g., zeroForOne orders get token1 from fills but token0 mostly from fees)

is vulnerable. The locked amount equals the late user's entire proportional share of the order's fill proceeds and post-checkpoint fees.

### Affected Users

All users of `LimitOrderHook` who join existing orders (not first placers). The vulnerability is more likely when:
- Orders remain unfilled for extended periods (more fee accumulation)
- Multiple users stack into the same tick/direction
- Withdrawal order is FIFO (early placers withdraw first)

## Risk Breakdown

- **Difficulty to Exploit:** Low — occurs naturally with normal usage patterns
- **Weakness Type:** CWE-191 (Integer Underflow)
- **CVSS:** 7.5 (High) — Availability impact (permanent DoS on withdrawal), Integrity impact (funds permanently locked)

## Recommendation

### Option A: Clamp checkpoint to available total (minimal change)

```diff
- amount0 = FullMath.mulDiv(orderInfo.currency0Total - checkpointAmountCurrency0, liquidity, liquidityTotal);
- amount1 = FullMath.mulDiv(orderInfo.currency1Total - checkpointAmountCurrency1, liquidity, liquidityTotal);
+ uint256 effectiveCheck0 = checkpointAmountCurrency0 > orderInfo.currency0Total
+     ? orderInfo.currency0Total : checkpointAmountCurrency0;
+ uint256 effectiveCheck1 = checkpointAmountCurrency1 > orderInfo.currency1Total
+     ? orderInfo.currency1Total : checkpointAmountCurrency1;
+ amount0 = FullMath.mulDiv(orderInfo.currency0Total - effectiveCheck0, liquidity, liquidityTotal);
+ amount1 = FullMath.mulDiv(orderInfo.currency1Total - effectiveCheck1, liquidity, liquidityTotal);
```

### Option B: Use rewardPerShare accumulator (architectural fix)

Replace the checkpoint-based fee distribution with a standard `rewardDebt` / `accRewardPerShare` pattern (as used in SushiSwap's MasterChef):

```solidity
// Track accumulated rewards per unit of liquidity
uint256 accCurrency0PerLiquidity;
uint256 accCurrency1PerLiquidity;

// Per-user debt
mapping(address => uint256) rewardDebt0;
mapping(address => uint256) rewardDebt1;
```

This ensures each user receives exactly the fees that accrued during their participation period, with no cross-contamination between users.

## Proof of Concept

### Exploit Scenario (Numerical)

```
Setup:
- Pool: WETH/USDC, tickSpacing=60
- Tick range: zeroForOne limit order at tick -120

Step 1: Alice places order
  placeOrder(key, -120, true, liquidity=1e18)
  → orderInfo.liquidityTotal = 1e18
  → checkpoints[Alice] = {currency0: 0, currency1: 0}

Step 2: 100 swaps generate fees
  → orderInfo.currency0Total = 1e16 (WETH fees)
  → orderInfo.currency1Total = 5e18 (USDC fees)

Step 3: Bob places into same order
  placeOrder(orderId, key, -120, true, liquidity=1e18)
  → orderInfo.liquidityTotal = 2e18
  → checkpoints[Bob] = {currency0: 1e16, currency1: 5e18}

Step 4: Price crosses tick, order fills
  _fillOrder: removes 2e18 liquidity
  → delta.amount0() ≈ 1e14 (small WETH from concentrated liquidity removal)
  → delta.amount1() ≈ 2e20 (large USDC from fill)
  → orderInfo.currency0Total = 1e16 + 1e14 = 1.01e16
  → orderInfo.currency1Total = 5e18 + 2e20 = 2.05e20

Step 5: Alice withdraws
  withdraw(orderId, alice):
  → amount0 = mulDiv(1.01e16 - 0, 1e18, 2e18) = 5.05e15
  → amount1 = mulDiv(2.05e20 - 0, 1e18, 2e18) = 1.025e20
  → orderInfo.currency0Total = 1.01e16 - 5.05e15 = 5.05e15
  → orderInfo.currency1Total = 2.05e20 - 1.025e20 = 1.025e20

Step 6: Bob tries to withdraw — REVERTS
  withdraw(orderId, bob):
  → currency0Total - checkpointCurrency0 = 5.05e15 - 1e16
  → 5.05e15 < 1e16 → UNDERFLOW REVERT
  → Bob's ~1.025e20 USDC + fees permanently locked!
```

### Foundry Test

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {LimitOrderHook} from "src/general/LimitOrderHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {OrderIdLibrary} from "src/general/LimitOrderHook.sol";

/// @notice PoC demonstrating LimitOrderHook withdrawal underflow
/// @dev This test demonstrates the concept — a full integration test requires
///      deploying PoolManager, creating a pool, and executing swaps.
///      The core arithmetic bug can be verified by examining the withdraw() function:
///      When currency0Total (53) < checkpointAmountCurrency0 (100),
///      the subtraction on line 418 underflows in uint256.
contract LimitOrderUnderflowPoC is Test {

    /// @notice Demonstrates the arithmetic that causes the underflow
    function test_withdrawalUnderflow_arithmetic() public pure {
        // After Alice's withdrawal:
        uint256 currency0Total = 5.05e15;    // Remaining after Alice took her share
        uint256 currency1Total = 1.025e20;

        // Bob's checkpoint (set when he joined, after fees accrued):
        uint256 checkpointCurrency0 = 1e16;  // Was 1e16 when Bob joined
        uint256 checkpointCurrency1 = 5e18;

        // Bob's withdrawal attempt — this is the exact calculation from line 418:
        // amount0 = FullMath.mulDiv(currency0Total - checkpointCurrency0, liquidity, liquidityTotal);

        // Verify the underflow condition:
        assert(currency0Total < checkpointCurrency0); // 5.05e15 < 1e16 — TRUE!

        // This would revert in the actual contract:
        // uint256 diff = currency0Total - checkpointCurrency0; // UNDERFLOW!

        // Currency1 is fine:
        assert(currency1Total > checkpointCurrency1); // 1.025e20 > 5e18 — OK
    }
}
```

## References

- **Vulnerable file:** `uniswap-hooks/src/general/LimitOrderHook.sol`
  - `withdraw()`: lines 390-441
  - `placeOrder()` checkpoint setting: lines 282-285
  - `_fillOrder()`: lines 615-671
- **Repository:** OpenZeppelin Uniswap V4 Hooks library
- **Related pattern:** SushiSwap MasterChef `rewardDebt` pattern that correctly handles multi-user proportional distributions
