# Kamino Re-Audit: TODO/FIXME/HACK/TEMP Comments + Test Coverage Analysis

Date: 2026-03-02

---

## EXECUTIVE SUMMARY

**Total TODO/incomplete code items found: 13**
- Security-Critical: 4
- Security-Adjacent: 5
- Informational: 4

**Test Coverage Assessment:**
- **Scope program: ZERO unit tests in the entire program. ZERO integration tests for Chainlink oracles.**
- klend: No Rust unit tests found (only TypeScript integration test file, no oracle-related tests)
- kfarms: No Rust unit tests found (only TypeScript integration test file)
- kvault: No Rust unit tests found

**HIGH PRIORITY BUG CANDIDATES (TODO + Zero Tests + Security Implications):**
1. Scope: KToken oracle mapping validation completely skipped (3 TODOs)
2. Scope: scope_chain `get_price_from_chain` known broken for high-decimal prices
3. Scope: Chainlink v10 `price * current_multiplier` is a temporary workaround
4. Scope: Jupiter LP price has no staleness check (uses current slot as update time)
5. Scope: Pyth Pull outage handling undecided (2 TODOs)

---

## TASK 1: ALL TODO/FIXME/HACK/TEMP COMMENTS

### SCOPE PROGRAM (`audits/kamino/scope/programs/scope/src/`)

#### FINDING S-1: KToken Oracle Validation Completely Skipped [SECURITY-CRITICAL]

**File:** `/root/defi-audit-targets/audits/kamino/scope/programs/scope/src/oracles/mod.rs`
**Lines:** 498-500

```rust
OracleType::KToken => Ok(()), // TODO, should validate ownership of the ktoken account
OracleType::KTokenToTokenA => Ok(()), // TODO, should validate ownership of the ktoken account
OracleType::KTokenToTokenB => Ok(()), // TODO, should validate ownership of the ktoken account
```

**Context:** The `validate_oracle_cfg()` function is called when updating oracle mappings (admin operation via `handler_update_mapping_and_metadata.rs:198`). For KToken oracle types, NO validation is performed on the price account -- the function immediately returns `Ok(())`.

**Security Impact:** An admin (or compromised admin key) could map a KToken oracle to an arbitrary account that is not actually a valid KToken. When prices are later refreshed, the `ktokens::get_price()` function would attempt to deserialize an arbitrary account as a KToken strategy, potentially yielding a manipulated price. The lack of ownership validation means the system relies entirely on the admin not making mistakes or being compromised. Compare to other oracle types like `PythPull`, `SwitchboardOnDemand`, `JupiterLpFetch`, `OrcaWhirlpool`, `RaydiumAmmV3`, `MeteoraDlmm` -- all perform account validation.

**Test Coverage:** ZERO -- no tests anywhere in the codebase test `validate_oracle_cfg` for KToken types.

**Rating: SECURITY-CRITICAL** -- Missing input validation on oracle configuration for 3 oracle types. The KToken oracle types are actively used (staleness configured at 120,000 and 100,000 slots respectively).

---

#### FINDING S-2: scope_chain `get_price_from_chain` Known Broken for High-Decimal Prices [SECURITY-CRITICAL]

**File:** `/root/defi-audit-targets/audits/kamino/scope/programs/scope/src/utils/scope_chain.rs`
**Line:** 241

```rust
// TODO not working with latest prices that have a lot of decimals. Backport yvault version here.
pub fn get_price_from_chain(
    prices: &OraclePrices,
    chain: &[u16; MAX_CHAIN_LENGTH],
) -> Result<DatedPrice, ScopeChainError> {
```

**Context:** This function computes chained prices (e.g., mSOL/SOL * SOL/USDH * USDH/USD) by multiplying price values using `U128` (128-bit integer). With up to 4 prices in a chain, each potentially having 18 decimals (Chainlink format) or high-value exponents, the intermediate product can overflow 128 bits. The TODO explicitly acknowledges this is broken for "latest prices that have a lot of decimals" and says to "backport yvault version" (which presumably uses wider arithmetic).

**Security Impact:** If the intermediate multiplication overflows U128, the function returns `MathOverflow` error, which propagates as `ScopeError::MathOverflow`. This would cause price refresh to fail for any KToken or chained price that involves high-decimal-count underlying prices. A stale price would persist, potentially enabling liquidation avoidance or bad-debt accumulation in klend.

**Test Coverage:** ZERO -- no tests at all for `get_price_from_chain`.

**Rating: SECURITY-CRITICAL** -- Acknowledged broken code in price computation path, zero tests, direct impact on lending liquidation prices.

---

#### FINDING S-3: Chainlink v10 Manual Price * Multiplier Calculation (Temporary Workaround) [SECURITY-CRITICAL]

**File:** `/root/defi-audit-targets/audits/kamino/scope/programs/scope/src/oracles/chainlink.rs`
**Lines:** 480-487

```rust
let price_dec = chainlink_bigint_value_parse(&chainlink_report.price)?;
let current_multiplier_dec =
    chainlink_bigint_value_parse(&chainlink_report.current_multiplier)?;
// TODO(liviuc): once Chainlink has added the `total_return_price`, use that
let multiplied_price: Price = price_dec
    .try_mul(current_multiplier_dec)
    .map_err(|_| ScopeError::MathOverflow)?
    .into();
```

**Context:** The `update_price_v10` function handles ChainlinkX (xStocks) oracle pricing. Rather than using Chainlink's `total_return_price` field (which accounts for corporate actions like stock splits and dividends), the code manually multiplies `price * current_multiplier` using `Decimal` (192-bit) arithmetic.

**Security Impact:**
1. **Precision loss:** Manual multiplication of two 18-decimal BigInt values can lose precision compared to Chainlink's natively-computed `total_return_price`. The `try_mul` on `Decimal` (U192) could produce different results than Chainlink's internal computation.
2. **Corporate action timing:** During a stock split or dividend, the `current_multiplier` changes. The manual multiplication may not correctly handle the transition period, especially since the blackout suspension logic (lines 442-470) relies on `activation_date_time` which is the timestamp when the multiplier becomes active.
3. **Overflow risk:** Two 18-decimal values multiplied together could exceed U192, causing MathOverflow and stale prices.

**Test Coverage:** ZERO -- no tests for `update_price_v10` anywhere in the codebase. No tests for the multiplier calculation. No tests for the blackout/suspension logic.

**Rating: SECURITY-CRITICAL** -- Temporary workaround for core price computation in xStocks oracle, zero tests, direct impact on DeFi prices.

---

#### FINDING S-4: Jupiter LP Price Uses Current Slot as Update Time (No Staleness Detection) [SECURITY-ADJACENT]

**File:** `/root/defi-audit-targets/audits/kamino/scope/programs/scope/src/oracles/jupiter_lp.rs`
**Lines:** 47-51

```rust
let dated_price = DatedPrice {
    price: price_dec.into(),
    // TODO: find a way to get the last update time
    last_updated_slot: clock.slot,
    unix_timestamp: u64::try_from(clock.unix_timestamp).unwrap(),
    ..Default::default()
};
```

**Context:** When computing the Jupiter LP token price, the function uses `clock.slot` as the `last_updated_slot` and `clock.unix_timestamp` as the `unix_timestamp`. This means the price ALWAYS appears fresh, regardless of when the underlying Jupiter pool's `aum_usd` was last updated.

**Security Impact:** Downstream consumers (klend) that check price staleness will never detect a stale Jupiter LP price. If Jupiter's `aum_usd` value becomes outdated (e.g., due to Jupiter program downtime or manipulation), klend would continue to use it as if it were current. This breaks the staleness protection that is carefully implemented for all other oracle types (Pyth, Chainlink, Switchboard, etc.).

**Test Coverage:** ZERO

**Rating: SECURITY-ADJACENT** -- Breaks staleness detection for Jupiter LP oracle type.

---

#### FINDING S-5: Pyth Pull Oracle Outage Handling Undecided [SECURITY-ADJACENT]

**File:** `/root/defi-audit-targets/audits/kamino/scope/programs/scope/src/oracles/pyth_pull.rs`
**Line:** 61

```rust
// todo: Discuss how we should handle the time jump that can happen when there is an outage?
let last_updated_slot = estimate_slot_update_from_ts(clock, unix_timestamp);
```

**File:** `/root/defi-audit-targets/audits/kamino/scope/programs/scope/src/oracles/pyth_pull_ema.rs`
**Line:** 54

```rust
// todo: Discuss how we should handle the time jump that can happen when there is an outage?
let last_updated_slot = estimate_slot_update_from_ts(clock, unix_timestamp);
```

**Context:** After a Pyth outage, the `publish_time` may jump forward significantly. The `estimate_slot_update_from_ts` function estimates the slot based on the time difference, but after an outage, this estimate could be wildly inaccurate. The `clamp_timestamp_to_now` function (called just before) prevents future timestamps, but doesn't handle the case where a very old price suddenly gets accepted.

**Security Impact:** After a Pyth outage, the first price update may have a `publish_time` that is current but the price itself reflects pre-outage conditions. The slot estimate would appear fresh, bypassing staleness checks. In volatile markets, this could lead to incorrect liquidation decisions.

**Test Coverage:** ZERO

**Rating: SECURITY-ADJACENT** -- Undecided handling of oracle outages in two critical oracle types (PythPull and PythPullEMA).

---

#### FINDING S-6: Chainlink v10 Blackout/Suspension Logic (Untested) [SECURITY-ADJACENT]

**File:** `/root/defi-audit-targets/audits/kamino/scope/programs/scope/src/oracles/chainlink.rs`
**Lines:** 426-470

```rust
// Check if this price was suspended
if existing_price_data.suspended {
    // ... reject update
    return Err(ScopeError::PriceNotValid);
}

// Check if the price report contains an activation time, and if we've entered the
// blackout period, suspend the price refresh
if chainlink_report.activation_date_time > 0 {
    let activation_time_i64 = i64::from(chainlink_report.activation_date_time);
    let activation_time_lower_bound = activation_time_i64
        .checked_sub(V10_TIME_PERIOD_BEFORE_ACTIVATION_TO_SUSPEND_S)
        .ok_or(ScopeError::BadTimestamp)?;

    if clock.unix_timestamp >= activation_time_lower_bound {
        // Suspend the price refresh
        // ...
        return Ok(PriceUpdateResult::SuspendExistingPrice);
    }
}
```

**Context:** The v10 (ChainlinkX / xStocks) suspension mechanism freezes price updates 24 hours before a corporate action's `activation_date_time`. Once suspended, the price can only be resumed by an admin calling `resume_chainlinkx_price`. This is a complex state machine with multiple edge cases.

**Potential Issues (untested):**
1. After suspension, the `observations_timestamp` is set to `last_observations_ts` (the PREVIOUS report's timestamp). After resume, it's set to `clock.unix_timestamp`. Any report with `observations_timestamp <= clock.unix_timestamp` at resume time will be rejected. This means ALL reports accumulated during suspension are permanently lost.
2. The blackout check uses `clock.unix_timestamp >= activation_time_lower_bound` but `activation_date_time` comes from the Chainlink report itself. If a malicious/buggy report provides activation_date_time = 0, the `if chainlink_report.activation_date_time > 0` guard prevents suspension, but this means corporate actions with activation_date_time = 0 skip suspension entirely.
3. Race condition: if `activation_date_time` changes between reports (e.g., corporate action rescheduled), the suspension state could become inconsistent.

**Test Coverage:** ZERO -- no tests for suspension, blackout, resume, or any state transitions.

**Rating: SECURITY-ADJACENT** -- Complex untested state machine for xStocks price management.

---

#### FINDING S-7: handler_refresh_prices Temporary Mut Load Pattern [INFORMATIONAL]

**File:** `/root/defi-audit-targets/audits/kamino/scope/programs/scope/src/handlers/handler_refresh_prices.rs`
**Line:** 126

```rust
// Only temporary load as mut to allow prices to be computed based on a scope chain
// from the price feed that is currently updated
let mut oracle_prices = ctx.accounts.oracle_prices.load_mut()?;
```

**Context:** This comment explains a design choice -- the oracle_prices account is loaded mutably inside the refresh loop iteration so that scope chain prices can reference the just-updated prices. This is not an incomplete implementation but a deliberate pattern.

**Rating: INFORMATIONAL** -- Design comment, not an incomplete implementation.

---

### KVAULT PROGRAM (`audits/kamino/kvault/programs/kvault/src/`)

#### FINDING V-1: Pending Fees Not Split by Type [INFORMATIONAL]

**File:** `/root/defi-audit-targets/audits/kamino/kvault/programs/kvault/src/state.rs`
**Line:** 124

```rust
// todo: should we split this into pending_mgmt_fee and pending_perf_fee?
pub pending_fees_sf: u128,
```

**Context:** The vault combines management and performance fees into a single `pending_fees_sf` field. Splitting them would improve accounting granularity but the current single-field approach is functionally correct -- fees are computed separately (`cumulative_mgmt_fees_sf` and `cumulative_perf_fees_sf` exist as separate trackers at lines 140-141) and only the pending amount to be minted is combined.

**Rating: INFORMATIONAL** -- Accounting granularity improvement, no security impact.

---

#### FINDING V-2: Reserve Allocation Lookup Not Sophisticated [INFORMATIONAL]

**File:** `/root/defi-audit-targets/audits/kamino/kvault/programs/kvault/src/state.rs`
**Line:** 297

```rust
pub fn is_allocated_to_reserve(&self, reserve: Pubkey) -> bool {
    // TODO: make this more sophisticated
    self.vault_allocation_strategy
        .iter()
        .any(|r| r.reserve == reserve)
}
```

**Context:** Simple linear scan over the allocation strategy array. The TODO suggests adding more sophisticated logic (possibly checking allocation weights, active status, etc.) but the current implementation correctly answers whether a reserve is in the allocation list.

**Rating: INFORMATIONAL** -- Performance/logic improvement opportunity, no security impact.

---

### KFARMS PROGRAM (`audits/kamino/kfarms/programs/kfarms/src/`)

#### FINDING F-1: unimplemented!() in update_reward_config [SECURITY-ADJACENT]

**File:** `/root/defi-audit-targets/audits/kamino/kfarms/programs/kfarms/src/farm_operations.rs`
**Line:** 375

```rust
_ => unimplemented!(),
```

**Context:** The `update_reward_config` function has a catch-all `unimplemented!()` for unhandled `FarmConfigOption` variants. Analysis of the call site at `update_farm_config` (line 157-162) shows that only reward-specific options (`UpdateRewardRps`, `UpdateRewardMinClaimDuration`, `RewardType`, `RpsDecimals`, `UpdateRewardScheduleCurvePoints`) are routed to `update_reward_config`. All other variants are handled in the outer function.

**Security Impact:** LOW -- the catch-all should be unreachable by design. However, `unimplemented!()` will panic the program (abort the transaction) rather than returning a clean error. If a future code change adds a new FarmConfigOption and incorrectly routes it to `update_reward_config`, it would cause a panic rather than a graceful error.

**Test Coverage:** ZERO (no Rust tests in kfarms)

**Rating: SECURITY-ADJACENT** -- Should be `return err!(FarmError::InvalidConfigOption)` or similar instead of panic.

---

### KLEND PROGRAM (`audits/kamino/klend/programs/klend/src/`)

#### FINDING K-1: No TODO/FIXME/HACK Comments Found

The klend program has no TODO, FIXME, HACK, or TEMP comments in its source code. This is the cleanest codebase of the four repos.

---

## TASK 2: TEST COVERAGE ANALYSIS

### Scope Program -- CRITICAL TEST GAPS

| Component | Test Files | Unit Tests | Integration Tests |
|-----------|-----------|------------|-------------------|
| `update_price_v10` (ChainlinkX) | **NONE** | **0** | **0** |
| `update_price_v3` (Chainlink) | **NONE** | **0** | **0** |
| `update_price_v8` (ChainlinkRWA) | **NONE** | **0** | **0** |
| `update_price_v9` (ChainlinkNAV) | **NONE** | **0** | **0** |
| `update_price_v7` (ChainlinkExchangeRate) | **NONE** | **0** | **0** |
| `refresh_chainlink_price` handler | **NONE** | **0** | **0** |
| `resume_chainlinkx_price` handler | **NONE** | **0** | **0** |
| `validate_oracle_cfg` (KToken branch) | **NONE** | **0** | **0** |
| `get_price_from_chain` (scope chain) | **NONE** | **0** | **0** |
| Blackout/suspension logic | **NONE** | **0** | **0** |
| Market status validation | **NONE** | **0** | **0** |
| `chainlink_bigint_value_parse` | **NONE** | **0** | **0** |
| `validate_observations_timestamp` | **NONE** | **0** | **0** |
| Pyth Pull oracle | **NONE** | **0** | **0** |
| Pyth Pull EMA oracle | **NONE** | **0** | **0** |
| Jupiter LP oracle | **NONE** | **0** | **0** |

**The entire Scope program has ZERO `#[test]` or `#[cfg(test)]` annotations.** There are no Rust test files, no integration test directories, and no TypeScript test files. The only test-adjacent code in the repo is in external interface stubs (`switchbord-itf`, `adrena-perp-itf`).

### Specific Test Gap: Chainlink v10 (`update_price_v10`)
- No tests for normal price update path
- No tests for suspension on blackout entry
- No tests for rejection when already suspended
- No tests for `activation_date_time = 0` bypass
- No tests for price * multiplier overflow
- No tests for negative BigInt handling
- No tests for observations timestamp ordering

### Specific Test Gap: `refresh_chainlink_price` handler
- No tests for CPI to Chainlink verifier
- No tests for return data validation
- No tests for oracle type routing
- No tests for TWAP update on price change
- No tests for ref price tolerance check
- No tests for suspended price skipping TWAP

### Other Repos Test Coverage

| Repo | Test Directory | Test Type | Oracle Tests |
|------|---------------|-----------|--------------|
| klend | `tests/klend.ts` | TypeScript integration | No oracle/chainlink tests |
| kfarms | `tests/kfarms.ts` | TypeScript integration | No oracle tests |
| kvault | None found | None | N/A |

---

## TASK 3: RECENT GIT CHANGES

### Git Log Analysis

Each repo has only a single commit (initial snapshot):

| Repo | Commit | Message |
|------|--------|---------|
| scope | `2897dd5` | Update 3t4j feed with new oracles (#41) |
| klend | `4fb7a09` | Prepare release 1.14.0 (#52) |
| kfarms | `2a63e5a` | Update README (#21) |
| kvault | `10a8d08` | release 2.0.1 (#6) |

Since these are single-commit snapshots, we cannot determine which files were most recently changed. However, the Scope commit message "Update 3t4j feed with new oracles (#41)" suggests oracle configuration changes were the most recent activity, which aligns with the highest-risk area (Chainlink oracle code with zero tests).

---

## PRIORITIZED BUG CANDIDATES

### PRIORITY 1: HIGHEST RISK (TODO + Zero Tests + Direct Security Impact)

#### P1-A: scope_chain `get_price_from_chain` U128 Overflow [POTENTIAL MEDIUM-HIGH]

- **TODO says:** "not working with latest prices that have a lot of decimals"
- **Test coverage:** ZERO
- **Impact:** Prices for KToken and chained assets could fail to compute, causing stale prices in klend. If prices are stale, liquidations may not trigger, leading to bad debt.
- **Exploit scenario:** If a KToken's underlying prices have high decimal counts (e.g., Chainlink's 18-decimal prices), multiplying 4 prices with 18 decimals each = 72 decimal digits, which exceeds U128's ~38 decimal digit capacity.
- **Action:** Verify what decimal counts are used in production scope chain configurations. Check if any chain uses prices with exponents > 9.

#### P1-B: Chainlink v10 Ignores `tokenized_price` Field [CONFIRMED MEDIUM-HIGH]

- **TODO says:** "once Chainlink has added the `total_return_price`, use that"
- **Test coverage:** ZERO
- **CONFIRMED BUG:** ReportDataV10 contains `tokenized_price: BigInt` (documented as "24/7 tokenized equity price"), the Chainlink-computed price with multiplier applied. Scope ignores it, manually computing `price * current_multiplier` instead.
- **Impact:** Incorrect xStocks pricing. Manual multiplication may diverge from Chainlink's native computation during corporate actions (splits, dividends). Precision differences in U192 multiplication vs Chainlink's internal computation.
- **CRITICAL FINDING:** Verified that `ReportDataV10` from the `chainlink-data-streams-report` crate (v1.0.3, git source: smartcontractkit/data-streams-sdk) contains a `tokenized_price: BigInt` field that is **completely ignored** by the Scope program. This field may be Chainlink's pre-computed total return price (accounting for multiplier). The TODO says to use `total_return_price` but the field is actually called `tokenized_price`. The code manually computes `price * current_multiplier` instead.
- **Full ReportDataV10 fields:** feed_id, valid_from_timestamp, observations_timestamp, native_fee, link_fee, expires_at, last_update_timestamp, price, market_status, current_multiplier, new_multiplier, activation_date_time, tokenized_price
- **VERIFIED:** `tokenized_price` is documented by Chainlink as the **"24/7 tokenized equity price"** -- a continuously-available price that includes the multiplier effect. In test code, it equals `MOCK_PRICE * 2`, confirming it is the pre-computed price with multiplier applied. The Scope program SHOULD be using `tokenized_price` instead of manually computing `price * current_multiplier`. This is a CONFIRMED deviation from Chainlink's intended usage.
- **Severity upgrade:** This is no longer just a TODO -- it is a confirmed bug where a Chainlink-provided pre-computed field is available but ignored in favor of a manual calculation that may diverge.

#### P1-C: KToken Oracle Validation Bypass [POTENTIAL MEDIUM]

- **TODO says:** "should validate ownership of the ktoken account"
- **Test coverage:** ZERO
- **Impact:** Admin can map any account as a KToken oracle without validation. If admin key is compromised, attacker can point KToken oracle to a crafted account.
- **Mitigating factor:** This is an admin-only operation (requires `configuration.admin` signer). Impact limited to admin compromise scenarios.
- **Action:** Check if `ktokens::get_price()` has its own account validation that compensates for the missing mapping validation.

### PRIORITY 2: MEDIUM RISK (TODO + Zero Tests + Indirect Security Impact)

#### P2-A: Jupiter LP Staleness Bypass [POTENTIAL LOW-MEDIUM]

- **TODO says:** "find a way to get the last update time"
- **Impact:** Jupiter LP prices always appear fresh, bypassing klend's staleness protection.
- **Action:** Check if klend has additional staleness checks beyond the scope-reported timestamp.

#### P2-B: Pyth Outage Handling [POTENTIAL LOW]

- **TODO says:** "Discuss how we should handle the time jump that can happen when there is an outage"
- **Impact:** First post-outage price update may have stale data but appear fresh.
- **Mitigating factor:** The `clamp_timestamp_to_now` function prevents future timestamps, and the `validate_valid_price` confidence check may catch large price deviations.

### PRIORITY 3: LOW RISK

#### P3-A: kfarms `unimplemented!()` [LOW]
- Unreachable by current call graph, but panic is worse than error return.

#### P3-B: kvault pending_fees split [INFORMATIONAL]
- Accounting granularity, no security impact.

#### P3-C: kvault reserve allocation sophistication [INFORMATIONAL]
- Functionality correct, performance/logic improvement opportunity.

---

## RECOMMENDATIONS

1. **IMMEDIATE:** Investigate P1-A (scope_chain overflow) -- check production chain configurations for high-decimal prices. If any chain uses 3+ prices with 18 decimals, the bug is live.

2. **IMMEDIATE:** P1-B (Chainlink v10 multiplier) is CONFIRMED -- the `tokenized_price` field exists in `ReportDataV10` (documented as "24/7 tokenized equity price") but is completely ignored. The fix is to use `chainlink_report.tokenized_price` directly. Need to verify whether `tokenized_price` exactly equals `price * current_multiplier` or includes additional adjustments (if it does, the divergence is a live bug).

3. **HIGH:** Audit the KToken oracle validation gap (P1-C) by tracing what validation `ktokens::get_price()` performs on its own.

4. **HIGH:** Check Jupiter LP on-chain behavior -- does the `aum_usd` field have its own freshness indicator that could be checked?

5. **MEDIUM:** The entire Scope program lacks any test coverage. Any code change to the oracle logic should be considered high-risk until tests are added.
