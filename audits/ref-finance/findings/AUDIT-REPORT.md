# Ref Finance Security Audit Report

**Protocol:** Ref Finance (NEAR Protocol DEX)
**Scope:** ref-contracts/ref-exchange (~14,027 LOC Rust) + boost-farm (~4,597 LOC Rust)
**Date:** 2026-03-03
**Bounty:** Immunefi, max $250K (Critical)
**Deployed:** v2.ref-finance.near (exchange), boostfarm.ref-labs.near (farming)

---

## Executive Summary

Comprehensive security audit of Ref Finance's two in-scope repositories covering ~18,600 lines of Rust smart contract code across 38 source files. The audit tested 80+ vulnerability hypotheses using multiple methodologies: line-by-line code review, cross-contract state analysis, arithmetic verification, oracle manipulation modeling, and first-depositor attack simulation.

**Result: 2 Medium, 3 Low, 8 Informational findings. 1 Immunefi submission (M-01).**

The core DEX mechanics (constant-product AMM, StableSwap invariant, Newton's method convergence) are correctly implemented with proper rounding directions and U256/U384 precision. The internal accounting pattern (tracking balances via state variables, never reading `ft_balance_of`) provides strong defense against donation/inflation attacks. The async callback patterns mostly follow correct optimistic/pessimistic update models, with one notable exception in the burrow liquidation flow.

---

## Findings Summary

| ID | Severity | Title | Component |
|----|----------|-------|-----------|
| M-01 | Medium | Burrow liquidation creates permanent phantom farming shadows | ref-exchange/shadow_actions.rs |
| M-02 | Medium | Boost-farm reward tokens permanently lost on withdraw+unregister race | boost-farm/actions_of_farmer_reward.rs |
| L-01 | Low | Rate modules accept zero oracle values causing temporary pool DoS | ref-exchange/rated_swap/*_rate.rs |
| L-02 | Low | f64 floating-point precision loss in boost ratio calculations | boost-farm/booster.rs, farmer_seed.rs |
| L-03 | Low | Degen price oracle `decimals` subtraction can underflow | ref-exchange/degen_swap/price_oracle.rs |
| I-01 | Informational | `callback_on_burrow_liquidation` is a log-only no-op | ref-exchange/shadow_actions.rs:289 |
| I-02 | Informational | Pyth `publish_time` truncated from i64 to u32 | ref-exchange/oracle.rs:79 |
| I-03 | Informational | `skip_degen_price_sync` allows bounded oracle staleness | ref-exchange/lib.rs:756 |
| I-04 | Informational | LP fee calculation uses unchecked subtraction | ref-exchange/stable_swap/math.rs:239 |
| I-05 | Informational | Pool ID u64-to-u32 truncation in volume tracking | ref-exchange/swap_volume.rs:52 |
| I-06 | Informational | TWAP sync is permissionless and gas-bounded | ref-exchange/unit_lpt_cumulative_infos.rs:182 |
| I-07 | Informational | Per-seed slash rate has no upper bound validation | boost-farm/management.rs:101 |
| I-08 | Informational | `swap_out_recipient` failure refund goes to recipient, not sender | ref-exchange/token_receiver.rs:144 |

---

## Detailed Findings

### M-01: Burrow Liquidation Creates Permanent Phantom Farming Shadows [Medium]

**File:** `ref-exchange/src/shadow_actions.rs` lines 171-238, 288-297

**Description:**
When `on_burrow_liquidation` is called and the liquidated user has LP shares shadow-staked in BOTH burrow and farming, the function:
1. Immediately decrements `shadow_in_burrow` (line 181)
2. If free shares are insufficient, immediately decrements `shadow_in_farm` (line 193)
3. Removes liquidity from pool and sends tokens to liquidator (lines 202-216)
4. Sends cross-contract call to farming contract to remove shadow seeds (line 219)
5. The callback `callback_on_burrow_liquidation` (lines 289-297) **only logs success/failure**

If step 4 fails (farming contract paused, insufficient gas, etc.), the state is permanently inconsistent:
- **ref-exchange**: `shadow_in_farm` already decremented, LP shares already burned
- **boost-farm**: `shadow_amount` unchanged, farming rewards continue accruing on phantom seeds

This violates the pattern used in the normal `shadow_action` flow, which correctly uses optimistic rollback in `callback_on_shadow`.

**Impact:**
- The liquidated user's phantom farming shadows earn real rewards, diluting all other farmers
- No recovery mechanism exists: no admin function in either contract can fix the inconsistency
- The farming contract's `total_seed_power` is permanently inflated

**Trigger conditions:**
- User with shares shadow-staked in both burrow and farming
- Liquidation event occurs
- Farming contract's `on_remove_shadow` call fails (contract paused, gas exhaustion)

**Recommendation:**
Add rollback logic to `callback_on_burrow_liquidation` when the farming shadow removal fails. At minimum, store the failed amounts in a recovery map that an admin can process.

---

### M-02: Boost-Farm Reward Tokens Permanently Lost on Withdraw+Unregister Race [Medium]

**File:** `boost-farm/src/actions_of_farmer_reward.rs` lines 19-52, 78-98

**Description:**
When a farmer calls `withdraw_reward`:
1. Line 30: `farmer.sub_reward(&token_id, amount)` deducts rewards from the farmer's map
2. Line 31: `self.internal_set_farmer(&farmer_id, farmer)` persists the farmer with rewards already deducted
3. Lines 33-48: Schedules `ft_transfer` promise with callback

Between steps 2 and the callback resolution (which occurs in a subsequent block), the farmer's `rewards` map is empty. A separate transaction calling `storage_unregister` in this window will:
- Check `farmer.rewards.is_empty()` -- passes (rewards already deducted)
- Remove the farmer from storage

When the callback fires and `ft_transfer` fails:
```rust
if let Some(mut farmer) = self.internal_get_farmer(&farmer_id) {
    farmer.add_rewards(...);
} else {
    Event::RewardLostfound { ... }.emit();  // Only logs, no recovery
}
```

The farmer no longer exists, so rewards are permanently lost. Unlike `seeds_lostfound`, there is no `rewards_lostfound` map or owner recovery function.

**Impact:** Permanent loss of reward tokens (self-harm, not theft). Tokens remain in the contract but are unrecoverable.

**Recommendation:** Add a `rewards_lostfound` map mirroring the existing `seeds_lostfound` pattern, or prevent unregistration while withdrawal promises are pending.

---

### L-01: Rate Modules Accept Zero Oracle Values Causing Temporary Pool DoS [Low]

**Files:** `ref-exchange/src/rated_swap/stnear_rate.rs:42`, `linear_rate.rs:42`, `nearx_rate.rs:42`

**Description:**
The `set()` function in stnear_rate, linear_rate, and nearx_rate stores oracle-returned values without zero validation:
```rust
fn set(&mut self, cross_call_result: &Vec<u8>) -> u128 {
    if let Ok(U128(price)) = from_slice::<U128>(cross_call_result) {
        self.stored_rates = price;  // No check: price > 0
        ...
    }
}
```

If an oracle returns `U128(0)`, the rate is stored as 0. Downstream, `div_rate()` in `rated_swap/math.rs:131` divides by this rate, causing a panic. All swap, add_liquidity, and remove_liquidity_by_tokens operations on that pool fail until the rate is refreshed.

**Mitigating factors:**
- `remove_liquidity_by_shares` does NOT use rates -- users CAN escape
- Rate updates are permissionless -- anyone can call `update_token_rate()` to fix
- Requires oracle malfunction (not attacker-controlled)
- The SFRAX Pyth path correctly validates `price.0 > 0`

**Recommendation:** Add `assert!(price > 0)` after deserialization in each `set()` function.

---

### L-02: f64 Floating-Point Precision Loss in Boost Ratio Calculations [Low]

**Files:** `boost-farm/src/booster.rs:76-78`, `boost-farm/src/farmer_seed.rs:50`

**Description:**
Boost ratios use f64 logarithm: `booster_amount.log(log_base)`. Seed power is computed as `(base_power as f64) * ratio) as u128`. For values > 2^53 (~9e15), the `as f64` conversion loses precision. With 24-decimal tokens, even 9 tokens triggers this.

Additionally, if `log_base` is configured to 1.0, `log(1.0)` produces NaN/Infinity, which silently converts to 0 when cast to u128 on WASM.

**Impact:** Inaccurate reward distribution proportional to balance magnitude. Not directly exploitable for theft, but creates unfairness.

**Recommendation:** Use fixed-point arithmetic (BigDecimal) instead of f64 for boost calculations.

---

### L-03: Degen Price Oracle Decimals Subtraction Can Underflow [Low]

**File:** `ref-exchange/src/degen_swap/price_oracle.rs` lines 65, 111

**Description:**
```rust
let fraction_digits = 10u128.pow((token_price.decimals - self.decimals) as u32);
```
If `token_price.decimals < self.decimals`, the u8 subtraction wraps to a large value. The subsequent `10u128.pow()` would overflow and panic, preventing all price updates for that token.

**Impact:** DoS on price refresh for misconfigured tokens. Swaps continue on stale prices until `expire_ts` passes.

**Recommendation:** Add explicit `assert!(token_price.decimals >= self.decimals)` with a descriptive error.

---

### I-01 through I-08: Informational Findings

**I-01: `callback_on_burrow_liquidation` is log-only** (shadow_actions.rs:289) -- Root cause of M-01. The callback should include state rollback or recovery logic.

**I-02: Pyth `publish_time` truncated to u32** (oracle.rs:79) -- `self.publish_time as u32` silently drops high bits of the i64 timestamp. Safe until 2106, but the addition `publish_time as u32 + valid_duration_sec` could overflow u32 for large duration values.

**I-03: `skip_degen_price_sync` user-controllable** (lib.rs:756) -- Allows users to skip post-swap oracle refresh. Pre-swap validation still runs, so impact is bounded by `expire_ts` staleness window.

**I-04: LP fee calculation unchecked subtraction** (stable_swap/math.rs:239, 351) -- `diff_shares - mint_shares` and `burn_shares - diff_shares` use unchecked subtraction. Due to `as_u128()` truncation, these could theoretically underflow. Practically safe for reasonable pool parameters.

**I-05: Pool ID u64-to-u32 truncation** (swap_volume.rs:52) -- Volume tracking uses `pool_id as u32` as map key. Pools 0 and 4,294,967,296 would collide. Unreachable in practice.

**I-06: TWAP sync permissionless** (unit_lpt_cumulative_infos.rs:182) -- `sync_pool_twap_record` can be called by anyone to record current pool state. Manipulation resistance depends on `record_interval_sec` being sufficiently large.

**I-07: Per-seed slash rate unbounded** (boost-farm/management.rs:101) -- `modify_seed_slash_rate` has no upper bound check (unlike `modify_default_slash_rate` which checks < BP_DENOM). Operator could set 100% slash rate.

**I-08: `swap_out_recipient` failure refund misdirection** (token_receiver.rs:144) -- When `swap_out_recipient` is used and the outgoing transfer fails, the callback's `internal_handle_fail_in_withdraw_callback` refunds to the recipient, not the original sender. The sender's tokens end up in the recipient's lostfound or the owner's central lostfound.

---

## Hypotheses Tested and Rejected (Clean Areas)

The following attack vectors were thoroughly investigated and found to be properly defended:

| # | Hypothesis | Why Safe |
|---|-----------|----------|
| 1 | First-depositor inflation (SimplePool) | Internal accounting prevents donation; INIT_SHARES_SUPPLY proportional dilution |
| 2 | First-depositor inflation (StableSwap) | Shares = D(amounts), proportional to deposit; MIN_RESERVE enforced |
| 3 | LP share rounding exploitation | `amounts[i]-1` rounds DOWN shares; `+1` rounds UP tokens taken; always favors pool |
| 4 | Admin fee share inflation | Fee shares proportional to invariant increase; no sequencing advantage |
| 5 | Donation attack via direct transfer | Internal accounting never reads `ft_balance_of`; `retrieve_unmanaged_token` is owner-only |
| 6 | Degen oracle price manipulation | NEAR async model prevents atomic price-manipulation-then-swap |
| 7 | Token theft via `swap_out_recipient` | User spends own tokens; virtual account isolation |
| 8 | HotZap token accounting manipulation | `TokenCache.sub()` strict overdraft check |
| 9 | Action chain 0-output propagation | `amount_in > 0` assertion at pool level; transaction reverts atomically |
| 10 | `total_seed_power` desync exploitation | Update-on-claim pattern correct: old power for old period, delta adjustment |
| 11 | Shadow record underflow via MFT transfer | `free_shares` check prevents transfer of shadow-locked shares |
| 12 | Reentrancy | NEAR single-threaded execution model; callbacks are `#[private]` |
| 13 | StableSwap Newton's method non-convergence | 256 iterations sufficient; convergence in ~10 for reasonable params |
| 14 | Cross-contract callback manipulation | `#[private]` macros; debit-first credit-on-callback pattern |
| 15 | Storage exhaustion attacks | Users pay own storage via NEAR deposits; `internal_check_storage` enforced |

---

## Key Defensive Patterns

1. **Internal accounting** (`self.amounts[]` / `self.c_amounts[]`) -- never reads token balances
2. **U256/U384 precision** for all critical math -- prevents intermediate overflow
3. **Conservative rounding** -- DOWN for user receives, UP for user pays
4. **Debit-first, credit-on-callback** -- standard NEAR async safety pattern
5. **Virtual account isolation** -- ephemeral `@` account for instant swaps
6. **Shadow share tracking** -- `free_shares = total - max(farm, burrow)` prevents double-counting
7. **Frozen token checks** on all swap/liquidity/withdraw paths
8. **Running state checks** on all user-facing mutations
9. **`assert_one_yocto()`** on all admin/sensitive operations
10. **`assert_degens_valid()`** before every degen swap
