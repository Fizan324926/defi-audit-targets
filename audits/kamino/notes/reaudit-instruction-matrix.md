# Scope Oracle Program -- Per-Instruction Access Control Matrix (Re-Audit)

**Date:** 2026-03-02
**Scope:** `/root/defi-audit-targets/audits/kamino/scope/programs/scope/src/`
**Focus:** Instruction-level access control, CPI protection, data validation asymmetries

---

## 1. Complete Instruction Matrix

| # | Instruction | Signer Required | Admin Check? | `check_context`? | `check_execution_ctx`? (CPI protection) | `instruction_sysvar` Account? | Caller-Controlled Data | Validation on Data | Missing Checks vs Peers |
|---|---|---|---|---|---|---|---|---|---|
| 1 | `initialize` | `admin: Signer` | No (anyone can init new feed) | No | No | No | `feed_name: String` | `#[account(init, seeds)]` prevents re-init | N/A -- one-time init |
| 2 | `refresh_price_list` | **None** (no Signer) | No | No | **YES** -- calls `check_execution_ctx()` | **YES** -- `instruction_sysvar_account_info` | `tokens: Vec<u16>`, remaining_accounts (oracle data) | Token bounds, oracle mapping match, per-oracle validation, ref_price check, zero-price reject | Baseline -- most protected |
| 3 | `refresh_chainlink_price` | `user: Signer` (any signer) | **No** | No | **NO** -- NO `check_execution_ctx()` | **NO** -- no `instruction_sysvar` | `token: u16`, `serialized_chainlink_report: Vec<u8>` | CL verifier CPI validates report signature, feed_id check, timestamp monotonicity, market status, ref_price check | **MISSING `check_execution_ctx`** -- see Finding #1 |
| 4 | `refresh_pyth_lazer_price` | `user: Signer` (any signer, `mut`) | No | No | **NO** -- NO `check_execution_ctx()` | **YES** -- `instructions_sysvar` (used by Pyth Lazer CPI verify) | `tokens: Vec<u16>`, `serialized_pyth_message: Vec<u8>`, `ed25519_instruction_index: u16` | Pyth Lazer CPI verify, feed_id, exponent, confidence interval, ref_price check | Same gap as Chainlink but Pyth Lazer has ed25519 sysvar check inherently |
| 5 | `update_mapping_and_metadata` | `admin: Signer` | **YES** -- `has_one = admin` via Configuration PDA | No | No | No | `feed_name`, `updates: Vec<UpdateOracleMappingAndMetadataEntriesWithId>` + remaining_accounts | Bounds checks, `validate_oracle_cfg()`, single-mapping-update-per-entry guard | Properly admin-gated |
| 6 | `reset_twap` | `admin: Signer` | **YES** -- `has_one = admin` via Configuration PDA | **YES** | No | **YES** -- `instruction_sysvar_account_info` | `token: u64`, `feed_name` | `check_context` (no extra accounts) | Properly protected |
| 7 | `set_admin_cached` | `admin: Signer` | **YES** -- `has_one = admin` via Configuration PDA | **YES** | No | No | `new_admin: Pubkey`, `feed_name` | `check_context` (no extra accounts) | Properly protected |
| 8 | `approve_admin_cached` | `admin_cached: Signer` | **YES** -- `has_one = admin_cached` via Configuration PDA | **YES** | No | No | `feed_name` | `check_context` (no extra accounts) | Properly protected, 2-step admin transfer |
| 9 | `create_mint_map` | `admin: Signer` (mut, payer) | **YES** -- `has_one = admin` via Configuration | No | No | No | `seed_pk`, `seed_id`, `bump`, `scope_chains` + remaining mints | Mint deserialization check, length match | Properly admin-gated |
| 10 | `close_mint_map` | `admin: Signer` (mut, receives lamports) | **YES** -- `has_one = admin` via Configuration | No | No | No | None | `constraint = mappings.oracle_prices == configuration.load()?.oracle_prices` | Properly admin-gated |
| 11 | `resume_chainlinkx_price` | `admin: Signer` | **YES** -- `has_one = admin` via Configuration PDA | **YES** | No | No | `token: u16`, `feed_name` | `check_context`, ChainlinkX type check, suspended state check | Properly admin-gated |

---

## 2. Critical Comparison: `refresh_price_list` vs `refresh_chainlink_price`

### 2a. CPI Protection (`check_execution_ctx`)

**`refresh_price_list`** has a robust CPI protection mechanism:

```rust
// handler_refresh_prices.rs:38
check_execution_ctx(&ctx.accounts.instruction_sysvar_account_info)?;
```

This function (lines 176-201) performs THREE checks:
1. The current instruction's program_id matches the Scope program (not CPI'd into).
2. The stack height is `TRANSACTION_LEVEL_STACK_HEIGHT` (not called from another program).
3. ALL preceding instructions in the transaction must be `ComputeBudget` instructions.

**`refresh_chainlink_price`** has **NONE of these protections**. There is:
- No `instruction_sysvar_account_info` in its accounts struct.
- No call to `check_execution_ctx`.
- No stack height check.
- No preceding instruction whitelist.

**`refresh_pyth_lazer_price`** also lacks `check_execution_ctx`, BUT it has the `instructions_sysvar` account present (used by the Pyth Lazer CPI verify instruction). The ed25519 signature verification provides an indirect form of data integrity -- a malicious CPI caller cannot forge the Pyth signature. However, transaction composition attacks are still theoretically possible.

### 2b. What This Missing Check Enables

Without `check_execution_ctx`, `refresh_chainlink_price` can be:
1. **Called via CPI** from any program -- the `user: Signer` just needs to be a PDA of the calling program.
2. **Preceded by arbitrary instructions** -- an attacker could compose a transaction with instructions that manipulate state before the Chainlink price update, then act on the new price in the same transaction.

However, **the practical exploitability is limited** because:
- The Chainlink verifier CPI validates the report cryptographic signature (CL DON consensus).
- The report data itself comes from Chainlink's DON, not from the caller.
- The `serialized_chainlink_report` is verified by the external Chainlink verifier program.
- An attacker cannot forge a report -- they can only choose WHICH valid report to submit and WHEN.

**Residual risk:** Transaction composition attacks where an attacker:
1. Observes a new Chainlink report in the mempool.
2. Sandwiches it: [setup manipulation] -> [refresh_chainlink_price] -> [exploit updated price].
3. Because there's no `check_execution_ctx`, the refresh can be part of a complex transaction with arbitrary other instructions.

For `refresh_price_list`, this same attack is impossible because `check_execution_ctx` ensures only `ComputeBudget` instructions precede the refresh.

**Severity: Low-Medium** -- The CPI protection gap is real but exploitation requires a specific scenario where same-transaction price update + action is profitable, and the Chainlink verifier provides cryptographic integrity of the price data itself.

---

## 3. Deep Dive: `update_price_v10` (ChainlinkX) -- Lines 408-504

### 3a. `current_multiplier` Validation

```rust
// chainlink.rs:480-487
let price_dec = chainlink_bigint_value_parse(&chainlink_report.price)?;
let current_multiplier_dec =
    chainlink_bigint_value_parse(&chainlink_report.current_multiplier)?;
let multiplied_price: Price = price_dec
    .try_mul(current_multiplier_dec)
    .map_err(|_| ScopeError::MathOverflow)?
    .into();
```

**Can `current_multiplier` be 0?**

Yes -- `chainlink_bigint_value_parse` only rejects:
- Negative BigInt values (Sign::Minus).
- Values exceeding 192 bits.

A zero BigInt (Sign::NoSign, empty bytes or `[0]`) passes validation and produces `Decimal(U192::from(0))`.

If `current_multiplier == 0`:
- `price_dec.try_mul(Decimal(0))` = `Decimal(0)` = `Price { value: 0, exp: 18 }`.
- This zero price is written to `oracle_prices.prices[token_idx]`.
- **There is NO zero-price check in the chainlink update path.**

Compare with `refresh_price_list` which calls `get_non_zero_price()` (mod.rs:468):
```rust
if price.price.value == 0 && price_type != OracleType::FixedPrice {
    return err!(ScopeError::PriceNotValid);
}
```

**The Chainlink path (`refresh_chainlink_price` handler) does NOT have this zero-price guard.**

However, the practical risk is mitigated: `current_multiplier` comes from the Chainlink DON consensus report which is cryptographically signed. If the DON signs a report with `current_multiplier = 0`, this is a Chainlink infrastructure failure, not something an attacker can craft.

But: if such a malformed report were signed (even by accident), the Scope oracle would accept a zero price, which could cause catastrophic liquidations or unlimited borrowing in downstream protocols like KLend.

**The ref_price check (lines 222-231) partially mitigates this**: if a ref_price is configured, a zero price would fail the tolerance check. But entries WITHOUT ref_price have no protection against zero prices from ChainlinkX.

**Severity: Low** -- Depends on Chainlink DON never producing a zero multiplier, which is outside Scope's control but extremely unlikely in practice.

### 3b. Can `current_multiplier` be Extremely Large?

`chainlink_bigint_value_parse` allows values up to 192 bits (U192 max = 2^192 - 1). With 18 decimal places, this represents approximately 6.2 * 10^39.

`try_mul` could overflow: `Decimal.try_mul(Decimal)` returns `Err` on overflow, which maps to `ScopeError::MathOverflow`. So an extremely large multiplier that causes overflow would reject the price update -- this is handled correctly.

But a large-but-not-overflowing multiplier could produce an artificially high price. Again, this would require a compromised Chainlink DON report.

### 3c. Confidence Interval Check -- v3 vs v10

**v3 (`update_price_v3`) HAS a confidence interval check:**
```rust
// chainlink.rs:265-273
let confidence_factor: u32 =
    AnchorDeserialize::try_from_slice(&mapping_generic_data[..4]).unwrap();
check_confidence_interval_decimal(price_dec, spread, confidence_factor).map_err(|e| { ... })?;
```

This uses `bid` and `ask` from the V3 report to compute spread and checks `price > spread * confidence_factor`.

**v10 (`update_price_v10`) has NO confidence interval check.**

The V10 report does not contain `bid`/`ask` fields. It has `price`, `current_multiplier`, `new_multiplier`, `tokenized_price`. So there is no spread data to check against.

**This is an inherent limitation of the V10 report schema**, not a code bug. The V10 report represents xStocks which use `price * current_multiplier` as the final price, and spread/confidence is not part of this report type.

### 3d. Other v10-Specific Validation

v10 has ADDITIONAL validations not in v3:
- **Suspension mechanism** (lines 427-440): If `existing_price_data.suspended == true`, rejects ALL updates until admin resumes.
- **Blackout period** (lines 444-471): If `activation_date_time > 0` and current time is within 24h of activation, suspends the price.
- **Market status** (lines 473-478): Validates market status via `validate_report_based_on_market_status()`.

---

## 4. Comparison: `resume_chainlinkx_price` vs `refresh_chainlink_price`

| Dimension | `resume_chainlinkx_price` | `refresh_chainlink_price` |
|---|---|---|
| **Signer** | `admin: Signer` | `user: Signer` (any) |
| **Admin check** | `has_one = admin` via Configuration PDA | **None** |
| **`check_context`** | **YES** -- rejects extra accounts | **No** |
| **CPI protection** | Inherits from admin-only access | **None** |
| **Configuration PDA** | Required (`seeds = [CONFIG, feed_name]`) | **Not used** |
| **tokens_metadata** | Required and loaded | **Not used** |
| **Effect** | Only unsets `suspended` flag, updates `observations_timestamp` | Writes new price to oracle |

This asymmetry is **by design**: `resume_chainlinkx_price` is an admin operation that manually overrides the suspension state after a corporate action (stock split, dividend). It must be admin-only. `refresh_chainlink_price` is permissionless price refresh -- any cranker can submit verified Chainlink reports.

---

## 5. Which Entries Have `ref_price` Protection and Which Don't?

The ref_price mechanism (handler_refresh_chainlink_price.rs:222-231):
```rust
match price_update_result {
    PriceUpdateResult::Updated if oracle_mappings.ref_price[token_idx] != u16::MAX => {
        // check ref price tolerance
    }
    _ => {} // NO CHECK if ref_price == u16::MAX (disabled)
}
```

Entries where `ref_price[token_idx] == u16::MAX` (the default) have **no ref_price cross-check**. This is configurable per-entry by the admin via `update_mapping_and_metadata` -> `MappingRefPrice`.

For ChainlinkX entries specifically, if ref_price is NOT configured:
- The only protection against a bad price is the Chainlink verifier signature.
- A zero-multiplier report or a price far from reality would be accepted.

For entries WITH ref_price:
- The new price must be within `ref_price_tolerance_bps` (or default 500 bps / 5%) of the reference price.
- This provides a sanity check even if the Chainlink report is technically valid but anomalous.

---

## 6. External Data Blob Validation Summary

Three instructions accept external data blobs:

| Instruction | Blob Field | Validation |
|---|---|---|
| `refresh_chainlink_price` | `serialized_chainlink_report: Vec<u8>` | CPI to Chainlink verifier program (cryptographic verification); return data decoded and validated per report version |
| `refresh_pyth_lazer_price` | `serialized_pyth_message: Vec<u8>` | CPI to Pyth Lazer verifier program; ed25519 signature verified via sysvar; payload validated (channel, feed count, feed_id, exponent, confidence) |
| `update_mapping_and_metadata` | `updates: Vec<UpdateOracleMappingAndMetadataEntriesWithId>` (admin-only) | Admin-gated; each update type individually validated; `validate_oracle_cfg()` called for mapping changes |

The Chainlink and Pyth Lazer blobs both use external verifier programs for cryptographic validation. The key difference is that `refresh_pyth_lazer_price` also has the instructions sysvar available for its Pyth verification CPI, while `refresh_chainlink_price` does not use the instructions sysvar at all.

---

## 7. Findings Summary

### Finding #1: Missing `check_execution_ctx` on `refresh_chainlink_price`

**Severity:** Low-Medium

**Description:** The `refresh_chainlink_price` instruction does not call `check_execution_ctx()` and does not require the `instruction_sysvar_account_info` account. This is asymmetric with `refresh_price_list`, which enforces:
1. The instruction is not called via CPI.
2. The stack height is at transaction level.
3. All preceding instructions are ComputeBudget only.

**Impact:** Allows `refresh_chainlink_price` to be:
- Called via CPI from any program.
- Composed in transactions with arbitrary preceding/following instructions.
- Used in sandwich/atomic-composition attacks where the price update is combined with state-manipulating instructions.

**Mitigating factors:**
- The Chainlink report is cryptographically verified -- the attacker cannot forge price data.
- The attacker can only choose timing and transaction composition.
- `ref_price` checks (when configured) provide additional price sanity bounds.

**Location:**
- `handler_refresh_chainlink_price.rs` -- missing call at top of `refresh_chainlink_price()`
- Compare with `handler_refresh_prices.rs:38` -- `check_execution_ctx()`

### Finding #2: No Zero-Price Guard in Chainlink Update Path

**Severity:** Low (Informational)

**Description:** The `refresh_price_list` path calls `get_non_zero_price()` which rejects `price.value == 0` for all non-FixedPrice oracle types. The `refresh_chainlink_price` path has no equivalent zero-price guard. If any Chainlink report version produces a zero price (e.g., v10 with `current_multiplier = 0`), it would be written to the oracle.

**Impact:** A zero price in the oracle could cause:
- Zero-value collateral assessments (free liquidations) in downstream lending (KLend).
- Unlimited borrowing against assets priced at zero.

**Mitigating factors:**
- Requires a Chainlink DON to sign a report with anomalous data.
- Entries with `ref_price` configured would catch zero prices.
- `chainlink_bigint_value_parse` rejects negative values but not zero.

**Location:**
- `handler_refresh_chainlink_price.rs:106-219` -- no zero-price check after price computation
- `chainlink.rs:480-487` (`update_price_v10`) -- `try_mul` with zero produces zero
- Compare with `oracles/mod.rs:468` -- zero-price guard in `get_non_zero_price()`

### Finding #3: No `check_execution_ctx` on `refresh_pyth_lazer_price`

**Severity:** Low

**Description:** Same pattern as Finding #1 but for the Pyth Lazer path. The `refresh_pyth_lazer_price` instruction does not call `check_execution_ctx()`. However, the practical risk is lower because:
- The Pyth Lazer verification CPI inherently uses the `instructions_sysvar` for ed25519 signature verification.
- The Pyth Lazer treasury is charged a fee per verification, adding cost to spam.

**Location:**
- `handler_refresh_pyth_lazer_price.rs` -- missing `check_execution_ctx()` call

### Finding #4: ChainlinkX v10 Has No Confidence Interval Check (Unlike v3)

**Severity:** Informational

**Description:** `update_price_v3` performs a configurable confidence interval check using bid/ask spread. `update_price_v10` has no equivalent because the V10 report schema does not include bid/ask fields. This means ChainlinkX prices have no spread-based sanity check.

**Mitigating factors:**
- This is a limitation of the V10 report format, not a code oversight.
- The `ref_price` mechanism provides an alternative price sanity check when configured.
- Market status validation and suspension mechanism provide additional safety.

**Location:**
- `chainlink.rs:265-273` (v3 confidence check)
- `chainlink.rs:480-487` (v10 -- no confidence check)

---

## 8. Validation Depth Per Chainlink Report Version

| Report Version | Oracle Type | Feed ID Check | Timestamp Monotonicity | Confidence Check | Market Status Check | Staleness Check | Zero-Price Check | Suspension | Multiplier |
|---|---|---|---|---|---|---|---|---|---|
| v3 | `Chainlink` | YES | YES | **YES** (bid/ask spread) | NO | NO | NO | NO | NO |
| v7 | `ChainlinkExchangeRate` | YES | YES | NO | NO | NO | NO | NO | NO |
| v8 | `ChainlinkRWA` | YES | YES | NO | YES (market hours) | YES (60s) | NO | NO | NO |
| v9 | `ChainlinkNAV` | YES | YES | NO | NO | YES (7 days NAV) | NO | NO (ripcord flag) | NO |
| v10 | `ChainlinkX` | YES | YES | NO | YES (market hours) | YES (60s, via market status) | NO | YES (24h blackout) | YES (`price * current_multiplier`) |

---

## 9. Key Takeaway

The previous audit likely generalized the CPI protection from `refresh_price_list` to cover `refresh_chainlink_price`. This is incorrect -- they have fundamentally different protection models:

- **`refresh_price_list`**: CPI-protected (anti-sandwich), permissionless, reads on-chain oracle accounts.
- **`refresh_chainlink_price`**: NOT CPI-protected, permissionless, processes caller-provided data blob (verified by external CL program).
- **`refresh_pyth_lazer_price`**: NOT CPI-protected, permissionless, processes caller-provided data blob (verified by external Pyth program).

The asymmetry exists because Chainlink and Pyth Lazer use a push model (caller provides signed report) while standard oracles use a pull model (read existing on-chain data). The `check_execution_ctx` was designed for the pull model to prevent sandwich attacks. Whether it's needed for the push model depends on whether same-transaction price-update-then-exploit scenarios are profitable -- which is protocol-dependent (e.g., in KLend lending markets).
