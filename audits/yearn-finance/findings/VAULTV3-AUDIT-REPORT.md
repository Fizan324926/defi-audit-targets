# Yearn V3 VaultV3.vy Deep Security Audit Report

**Target:** `/root/defi-audit-targets/audits/yearn-finance/yearn-vaults-v3/contracts/VaultV3.vy`
**Compiler:** Vyper 0.3.7
**Version:** API 3.0.4
**Date:** 2026-03-02
**Auditor:** Independent Security Review
**Bounty:** Immunefi (up to $200K)
**Prior Audits:** yAcademy (June 2023), Statemind, ChainSecurity

---

## Executive Summary

The Yearn V3 VaultV3.vy is an exceptionally well-engineered ERC4626 vault implementation. After thorough analysis of all 8 high-priority attack vectors and every line of the 2199-line contract, **0 critical or high-severity vulnerabilities were found**. The vault exhibits multiple defensive design patterns that neutralize the most common DeFi attack vectors.

**Final Tally:** 0 Critical, 0 High, 0 Medium, 3 Low, 5 Informational

---

## Attack Vector Analysis

### 1. ERC4626 First-Depositor Inflation Attack -- NOT VULNERABLE

**Lines:** 235-236, 431-435, 460-484, 643-665

The vault uses **internal accounting** (`total_idle` + `total_debt`) instead of `balanceOf(self)` for all share price calculations:

```vyper
# Line 235-236
# Current assets held in the vault contract. Replacing balanceOf(this) to avoid price_per_share manipulation.
total_idle: uint256

# Line 431-435
def _total_assets() -> uint256:
    return self.total_idle + self.total_debt
```

**Why the classic attack fails:**
- Attacker deposits 1 wei of assets, gets 1 share.
- Attacker directly transfers 1e18 tokens to the vault contract.
- `total_idle` is unchanged. `_total_assets()` is unchanged. PPS remains 1:1.
- The donated tokens are "lost" from the attacker's perspective -- they only get swept if a REPORTING_MANAGER calls `process_report(self)` (line 1153-1156).

**Defense pattern:** Internal accounting replaces `balanceOf(this)`, completely neutralizing donation-based inflation attacks. No dead shares or virtual offset needed.

**Verdict:** SAFE. Not Immunefi-submittable.

---

### 2. Vyper 0.3.7 unsafe_add/unsafe_sub Analysis

**All 24 uses of unsafe operations analyzed:**

| Line | Operation | Context | Safe? | Reasoning |
|------|-----------|---------|-------|-----------|
| 334 | `unsafe_sub(current_allowance, amount)` | `_spend_allowance` | YES | `assert current_allowance >= amount` at line 333 |
| 340 | `unsafe_sub(sender_balance, amount)` | `_transfer` | YES | `assert sender_balance >= amount` at line 339 |
| 341 | `unsafe_add(balance_of[receiver], amount)` | `_transfer` | YES | Sum of all balances = total_supply <= uint256.max (invariant maintained by safe `+=` in `_issue_shares`) |
| 397 | `unsafe_sub(total_supply, shares)` | `_burn_shares` | YES | `balance_of[owner] -= shares` (line 396) reverts first if insufficient; total_supply >= any single balance |
| 506 | `unsafe_add(balance_of[recipient], shares)` | `_issue_shares` | YES | `total_supply += shares` (line 507) would revert on overflow first, and individual balance <= total_supply |
| 532 | `unsafe_sub(_deposit_limit, _total_assets)` | `_max_deposit` | YES | Guarded by `_total_assets >= _deposit_limit` check at line 529 |
| 777 | `unsafe_sub(requested_assets, current_total_idle)` | `_redeem` | YES | Inside `if requested_assets > current_total_idle` block (line 762) |
| 859 | `unsafe_sub(withdrawn, assets_to_withdraw)` | `_redeem` | YES | Inside `if withdrawn > assets_to_withdraw` block (line 852) |
| 863 | `unsafe_sub(assets_to_withdraw, withdrawn)` | `_redeem` | YES | Inside `elif withdrawn < assets_to_withdraw` block (line 862) |
| 867 | `unsafe_sub(assets_to_withdraw, loss)` | `_redeem` | YES | `loss = assets_to_withdraw - withdrawn` where `withdrawn >= 0`, so `loss <= assets_to_withdraw` |
| 989 | `unsafe_sub(current_debt, new_debt)` | `_update_debt` | YES | Inside `if current_debt > new_debt` block (line 987) |
| 997 | `unsafe_sub(minimum_total_idle, total_idle)` | `_update_debt` | YES | Implied by `total_idle + assets_to_withdraw < minimum_total_idle` (line 996) that `minimum_total_idle > total_idle` |
| 1034 | `unsafe_sub(assets_to_withdraw, withdrawn)` | `_update_debt` | YES | Inside `if withdrawn < assets_to_withdraw` block (line 1032) |
| 1075 | `unsafe_sub(total_idle, minimum_total_idle)` | `_update_debt` | YES | `total_idle <= minimum_total_idle` returns early at line 1072-1073, so this is only reached when `total_idle > minimum_total_idle` |
| 1166 | `unsafe_sub(total_assets, current_debt)` | `_process_report` | YES | Inside `if total_assets > current_debt` (line 1164) |
| 1169 | `unsafe_sub(current_debt, total_assets)` | `_process_report` | YES | In else branch where `total_assets <= current_debt` |
| 1230 | `unsafe_sub(ending_supply, total_supply)` | `_process_report` | YES | Inside `if ending_supply > total_supply` (line 1228) |
| 1235 | `unsafe_sub(total_supply, ending_supply)` | `_process_report` | YES | Inside `elif total_supply > ending_supply` (line 1233) |
| 1241 | `unsafe_sub(shares_to_lock, shares_to_burn)` | `_process_report` | YES | Inside `if shares_to_lock > shares_to_burn` (line 1239) |
| 1255 | `unsafe_add(current_debt, gain)` | `_process_report` | YES | `current_debt + gain = total_assets` (line 1164), bounded by real token amounts |
| 1261 | `unsafe_add(current_debt, total_refunds)` | `_process_report` | YES | Self-report path; bounded by real token amounts |
| 1266 | `unsafe_sub(current_debt, loss)` | `_process_report` | YES | `loss = current_debt - total_assets` (line 1169), so `current_debt >= loss` |
| 1272 | `unsafe_add(current_debt, total_refunds)` | `_process_report` | YES | Same as 1261 |
| 1683 | `unsafe_sub(current_debt, _amount)` | `buy_debt` | YES | `_amount` capped to `current_debt` at line 1670-1671 |

**Verdict:** ALL 24 unsafe operations are correctly guarded by preceding conditional checks. No silent overflow/underflow is possible. Not Immunefi-submittable.

---

### 3. Profit Unlocking Rate Manipulation

#### 3a. Front-running `process_report` to manipulate PPS

**Lines:** 1113-1325, 402-420

The profit locking mechanism mints shares to the vault itself, gradually "unlocked" (excluded from effective total_supply) over `profit_max_unlock_time`:

```vyper
# Line 425-427
def _total_supply() -> uint256:
    return self.total_supply - self._unlocked_shares()
```

**Front-running analysis:**
- An attacker deposits right before `process_report` is called with a profitable strategy.
- However, `process_report` locks ALL new profit by minting equivalent shares to the vault (line 1218).
- PPS does NOT change immediately -- the profit is locked and unlocks linearly.
- A sandwich attack (deposit before, withdraw after) yields zero profit because PPS does not change atomically.

**Verdict:** SAFE by design. The locking mechanism specifically prevents front-running of profit reports.

#### 3b. Weighted average period gaming (lines 1286-1302)

A REPORTING_MANAGER could rapidly call `process_report` with tiny profits to shorten the unlock period. However, this requires the REPORTING_MANAGER role (permissioned). An external attacker cannot trigger `process_report`.

#### 3c. `profit_max_unlock_time = 0` behavior (lines 1506-1517)

When set to 0, all profits are reflected immediately in PPS (no locking). Setting to 0 burns all locked shares instantly. This is documented intentional behavior controlled by the PROFIT_UNLOCK_MANAGER role.

**Verdict:** Design decision, not a vulnerability.

---

### 4. Cross-contract Reentrancy (Vault <-> Strategy)

**Lines:** 1637, 1648, 1746, 1794, 1813, 1826, 1849

All state-modifying external functions use `@nonreentrant("lock")` with the same key:
- `process_report`, `buy_debt`, `update_debt`, `deposit`, `mint`, `withdraw`, `redeem`

They all share the same lock key `"lock"`, so no two can execute simultaneously.

**ERC777 / callback token analysis:**

When the vault calls into a strategy (e.g., `IStrategy(strategy).deposit(...)` at line 1091), the strategy could theoretically call back. However, the `@nonreentrant("lock")` guard prevents re-entry into ANY vault function. Vyper 0.3.7's nonreentrant uses a storage-based lock (slot set to 1 on entry, checked at the top). Even ERC777 token callback re-entry attempts would revert.

**Transfer ordering:** In `_redeem`, the asset transfer happens AFTER `_burn_shares` and all state updates (line 905). This follows checks-effects-interactions and is also protected by `@nonreentrant`.

**Verdict:** SAFE. Single shared reentrancy guard across all mutative functions. Not Immunefi-submittable.

---

### 5. `_assess_share_of_unrealised_losses` Rounding Analysis

**Lines:** 669-694

```vyper
numerator: uint256 = assets_needed * strategy_assets
users_share_of_loss: uint256 = assets_needed - numerator / strategy_current_debt
if numerator % strategy_current_debt != 0:
    users_share_of_loss += 1
```

**Rounding direction:** Loss share always rounds UP, meaning users bear at least their fair share. This is the correct conservative direction.

**Edge case at dust amounts:** When `assets_needed = 1` and the strategy has losses, `users_share_of_loss` can be 2 (exceeds the 1 wei withdrawal amount). This leads to underflow revert at line 819: `assets_to_withdraw -= unrealised_losses_share`. See FINDING-01.

**Verdict:** Correct rounding direction. Minor dust-amount revert issue (FINDING-01).

---

### 6. `auto_allocate` Feature During Deposit

**Lines:** 664-665

```vyper
if self.auto_allocate:
    self._update_debt(self.default_queue[0], max_value(uint256), 0)
```

**Sandwich attack analysis:** `_update_debt` moves funds from `total_idle` to `total_debt`. `_total_assets()` = `total_idle + total_debt` is unchanged. PPS is unchanged. No sandwich profit possible.

**Verdict:** SAFE. Not Immunefi-submittable.

---

### 7. `_update_debt` Edge Cases

#### 7a. Strategy with `current_debt > max_debt` (from profits)

Handled at lines 1050-1055: returns early without changes if `new_debt < current_debt` after capping to `max_debt`.

#### 7b. Direct token transfers to strategy

Would show as gain on next `process_report`. Gain gets locked and distributed to all shareholders. Donator loses tokens. No exploit.

#### 7c. `minimum_total_idle` and withdrawal griefing

`minimum_total_idle` only affects `_update_debt` (debt management), not `_redeem` (user withdrawals). Users can always withdraw from idle funds regardless.

**Verdict:** SAFE. Not Immunefi-submittable.

---

### 8. Withdrawal Queue Manipulation

**Lines:** 173, 764-770, 784-888

Users can pass custom queue via the `strategies` parameter (unless `use_default_queue` is True). If all strategies are unreachable, only idle funds are available, and the vault correctly reverts if insufficient.

`set_default_queue` allows duplicate strategies (documented at line 1365-1366). Actual withdrawals handle duplicates gracefully (second pass withdraws nothing).

**Verdict:** SAFE. Not Immunefi-submittable.

---

## Findings

### FINDING-01 [FALSE POSITIVE -- PROVED UNREACHABLE]: Division by zero in `_process_report` at line 1298

**File:** `/root/defi-audit-targets/audits/yearn-finance/yearn-vaults-v3/contracts/VaultV3.vy`
**Lines:** 1296-1298

**Initial hypothesis:** `new_profit_locking_period` could truncate to 0 via integer division at line 1296, causing division by zero at line 1298.

**Mathematical proof of unreachability:**

For `new_profit_locking_period = 0` at line 1298, we need `total_locked_shares > 0` (line 1286) and the numerator at line 1296 to truncate to 0.

**Case 1: `_full_profit_unlock_date > block.timestamp` (still unlocking)**

At line 1296:
```
new_profit_locking_period = ((TLS - STL) * remaining + STL * T) / TLS
```
where `remaining >= 1` (seconds), `T = profit_max_unlock_time >= 1`, `TLS = total_locked_shares`, `STL = shares_to_lock_adjusted`.

Since `STL <= TLS` (enforced by safe subtraction at line 1293):
```
numerator = (TLS - STL) * remaining + STL * T
         >= (TLS - STL) * 1 + STL * 1    [since remaining >= 1 and T >= 1]
         = TLS
```
Therefore: `new_profit_locking_period >= TLS / TLS = 1`. **Cannot be zero.**

**Case 2: `_full_profit_unlock_date <= block.timestamp` (fully unlocked)**

When fully unlocked, `_unlocked_shares() = balance_of[self]`. The `ending_supply` calculation at line 1225 burns all previously unlocked shares. After all issuance/burning:
- `total_locked_shares = balance_of[self] = shares_to_lock_adjusted` (equal by construction)
- `new_profit_locking_period = (0 + STL * T) / STL = T`
- If `T >= 1`: `new_profit_locking_period >= 1`. **Cannot be zero.**
- If `T = 0`: `shares_to_lock = 0` (line 1217 condition fails), so `total_locked_shares = 0`, and we skip to the else branch at line 1303. **Block not entered.**

**Case 3: `_full_profit_unlock_date == 0` (no previous locking)**

Same as Case 2: `_unlocked_shares() = 0`, after accounting `total_locked_shares = shares_to_lock_adjusted`, and `new_profit_locking_period = T >= 1`.

**Conclusion:** The division by zero at line 1298 is mathematically unreachable for any valid `profit_max_unlock_time >= 1`. When `profit_max_unlock_time == 0`, the code path is skipped entirely. The weighted average formula is provably safe.

**Immunefi-submittable:** No. False positive.

---

### FINDING-02 [Low]: Dust-amount withdrawals from lossy strategies revert

**File:** `/root/defi-audit-targets/audits/yearn-finance/yearn-vaults-v3/contracts/VaultV3.vy`
**Lines:** 688-693, 819

**Description:**

In `_assess_share_of_unrealised_losses`:

```vyper
numerator: uint256 = assets_needed * strategy_assets
users_share_of_loss: uint256 = assets_needed - numerator / strategy_current_debt
if numerator % strategy_current_debt != 0:
    users_share_of_loss += 1
```

When `assets_needed = 1` and `strategy_assets < strategy_current_debt`, the calculation produces:
- `numerator = 1 * strategy_assets`
- `numerator / strategy_current_debt = 0` (integer division since `strategy_assets < strategy_current_debt`)
- `users_share_of_loss = 1 - 0 = 1`, then `+= 1` (remainder != 0) = **2**

This exceeds the 1 wei withdrawal amount. At line 819:
```vyper
assets_to_withdraw -= unrealised_losses_share  # 1 - 2 = underflow revert
```

**Impact:** Dust-amount (1-2 wei) withdrawals from lossy strategies revert. No fund loss, just a minor DOS on tiny amounts.

**Immunefi-submittable:** No. Impact is negligible.

---

### FINDING-03 [Low]: `process_report` can revert via `ending_supply` underflow with misconfigured accountant fees during loss + active unlock

**File:** `/root/defi-audit-targets/audits/yearn-finance/yearn-vaults-v3/contracts/VaultV3.vy`
**Line:** 1225

**Description:**

```vyper
ending_supply: uint256 = total_supply + shares_to_lock - shares_to_burn - self._unlocked_shares()
```

If a misconfigured accountant returns large `total_fees` during a loss report while there is an active profit unlock period, `shares_to_burn + _unlocked_shares()` can exceed `total_supply + shares_to_lock`, causing underflow revert.

**Impact:** DOS of `process_report`. Requires misconfigured accountant (governance error). Can be fixed by changing the accountant.

**Immunefi-submittable:** No. Requires admin misconfiguration.

---

### FINDING-04 [Low]: `_process_report` line 1293 lacks defensive underflow check

**File:** `/root/defi-audit-targets/audits/yearn-finance/yearn-vaults-v3/contracts/VaultV3.vy`
**Line:** 1293

```vyper
previously_locked_time = (total_locked_shares - shares_to_lock) * (_full_profit_unlock_date - block.timestamp)
```

The subtraction `total_locked_shares - shares_to_lock` uses safe Vyper arithmetic. If through some edge case `shares_to_lock > total_locked_shares`, this would revert, DOSing `process_report`. While I could not construct a concrete reachable scenario, a defensive `min(shares_to_lock, total_locked_shares)` would eliminate the risk.

**Impact:** Theoretical DOS. Could not confirm reachability.

**Immunefi-submittable:** No.

---

### FINDING-05 [Informational]: EIP-712 domain separator uses hardcoded "Yearn Vault" name

**Lines:** 2180-2189

```vyper
def domain_separator() -> bytes32:
    return keccak256(
        concat(
            DOMAIN_TYPE_HASH,
            keccak256(convert("Yearn Vault", Bytes[11])),  # Hardcoded, not self.name
            ...
        )
    )
```

All V3 vaults share the same name component in the domain separator. They are differentiated by contract address and chain ID, which is sufficient for security. But it means `permit` signatures reference "Yearn Vault" regardless of the vault's actual `name`.

**Impact:** None. Contract address uniquely identifies vaults. Cosmetic EIP-712 deviation only.

---

### FINDING-06 [Informational]: `set_default_queue` allows duplicate strategies

**Lines:** 1361-1378

Documented in NatSpec (line 1365-1366). Duplicate strategies cause inaccurate `maxWithdraw`/`maxRedeem` return values. Actual withdrawals handle duplicates gracefully. Requires QUEUE_MANAGER role.

---

### FINDING-07 [Informational]: `buy_debt` can revert with "cannot buy zero" for small amounts on heavily lossy strategies

**Lines:** 1676, 1678

```vyper
shares: uint256 = IStrategy(strategy).balanceOf(self) * _amount / current_debt
assert shares > 0, "cannot buy zero"
```

Integer division truncation can produce 0 shares for small `_amount` when the strategy has near-zero balance. Forces DEBT_PURCHASER to buy larger amounts.

---

### FINDING-08 [Informational]: `auto_allocate` with empty `default_queue` DOSes deposits

**Lines:** 664-665

`self.default_queue[0]` reverts with array index out of bounds. Documented behavior (line 1400 in NatSpec). Requires both DEBT_MANAGER to enable and QUEUE_MANAGER to empty the queue.

---

### FINDING-09 [Informational]: No check that `receiver != msg.sender` in `_transfer` allows self-transfers

**Lines:** 337-342

A user can transfer shares to themselves. The `unsafe_sub` on their balance followed by `unsafe_add` of the same amount is a no-op. This is gas waste only, with no security impact.

---

## Defensive Design Patterns (Commendable)

1. **Internal accounting** (`total_idle` + `total_debt`) instead of `balanceOf(this)` -- neutralizes ALL donation/inflation attacks (line 235).
2. **Shared reentrancy guard** (`@nonreentrant("lock")`) on all 7 mutative external functions -- prevents all reentrancy including cross-function.
3. **Profit locking mechanism** -- shares minted to vault self, gradually unlocked -- prevents front-running of profit reports.
4. **Rounding direction consistency** -- deposits round DOWN shares (fewer shares for depositor), withdrawals round UP shares (more shares burned) -- protects the vault.
5. **Loss rounding UP** -- users bear at least their proportional share of losses.
6. **Balance-based actual amount tracking** -- `pre_balance / post_balance` pattern for all strategy interactions (lines 1023-1029, 1090-1099) -- immune to strategy dishonesty about amounts.
7. **Approval reset to 0** after strategy deposits (line 1095) -- prevents lingering approvals.
8. **Two-step role manager transfer** (lines 1572-1594) -- prevents accidental role manager loss.
9. **Transfer to vault/zero address blocked** (lines 1890, 1903) -- prevents share accounting corruption.

## Conclusion

Yearn V3 VaultV3.vy is a mature, well-audited contract (3 prior audits: yAcademy, Statemind, ChainSecurity) that demonstrates strong defensive engineering. **No Immunefi-submittable vulnerabilities were found.** The initial FINDING-01 hypothesis (division by zero in profit unlocking) was mathematically proved unreachable -- the weighted average formula guarantees `new_profit_locking_period >= 1` for any valid `profit_max_unlock_time >= 1`. The vault's use of internal accounting, shared reentrancy guards, and profit locking mechanisms effectively neutralize all standard ERC4626 attack vectors.

All `unsafe_*` operations are correctly guarded by preceding conditional checks. The architecture is fundamentally sound. The codebase quality is exceptionally high.

### Hypotheses Tested But Not Confirmed

1. **ERC4626 first-depositor inflation** -- Blocked by internal accounting (total_idle + total_debt).
2. **Donation attack via direct token transfer** -- total_idle not affected by balanceOf.
3. **ERC777 reentrancy** -- Shared `@nonreentrant("lock")` guard blocks all re-entry.
4. **Profit front-running** -- Profit locking prevents instant PPS changes.
5. **Withdrawal queue manipulation** -- Custom queue is available, forced default queue option exists.
6. **Strategy dishonesty on deposit/withdraw amounts** -- pre/post balance tracking.
7. **Flash loan PPS manipulation** -- Internal accounting immune to balance manipulation.
8. **Permit replay across chains** -- domain_separator includes chain.id.
9. **Accountant fee extraction** -- Fees are bounded and go through process_report which uses @nonreentrant.
10. **unsafe_add overflow in _transfer** -- Bounded by total_supply invariant.
11. **unsafe_sub underflow in _burn_shares** -- Bounded by safe balance_of subtraction.
12. **Withdrawal from 100% loss strategy** -- Correctly handles via loss accounting and debt reduction.
13. **minimum_total_idle griefing withdrawals** -- Only affects update_debt, not _redeem.
14. **auto_allocate sandwich** -- Total assets unchanged (idle to debt), PPS unchanged.
15. **Duplicate strategy in queue** -- Handled gracefully (second pass withdraws nothing).
