# Kamino Scope / KLend / KFarms: External Data Field Audit

Date: 2026-03-02
Focus: Missing validation, unused security-relevant fields, TODO comments, adapter asymmetry.

---

## TASK 1: Scope Oracle External Data Analysis

### 1.1 Chainlink Report Struct Field Analysis

Source: `scope/programs/scope/src/oracles/chainlink.rs`
Dependency: `chainlink-data-streams-report` v1.0.3 (git commit fb56ce042fc7)

#### ReportDataV3 (9 fields) -- Used by OracleType::Chainlink

| # | Field | Type | Used? | Validated? | Notes |
|---|-------|------|-------|------------|-------|
| 1 | `feed_id` | FeedID | YES | YES | Checked against mapping pubkey via `validate_report_feed_id()` |
| 2 | `valid_from_timestamp` | u32 | **NO** | **NO** | **IGNORED** -- earliest applicable timestamp |
| 3 | `observations_timestamp` | u32 | YES | YES | Checked > last observation, clamped to current time |
| 4 | `native_fee` | BigInt | **NO** | **NO** | **IGNORED** -- fee field, acceptable to ignore |
| 5 | `link_fee` | BigInt | **NO** | **NO** | **IGNORED** -- fee field, acceptable to ignore |
| 6 | `expires_at` | u32 | **NO** | **NO** | **IGNORED -- SECURITY RELEVANT** -- last verifiable timestamp |
| 7 | `benchmark_price` | BigInt | YES | YES | Parsed via `chainlink_bigint_value_parse()`, negative check, 192-bit bounds |
| 8 | `bid` | BigInt | YES | YES | Used in confidence interval: spread = ask - bid |
| 9 | `ask` | BigInt | YES | YES | Used in confidence interval: spread = ask - bid |

**V3 Validation:** feed_id, observations_timestamp monotonicity, negative price, 192-bit overflow, confidence interval (bid/ask spread)
**V3 Missing:** `expires_at` not checked, `valid_from_timestamp` not checked

#### ReportDataV7 (7 fields) -- Used by OracleType::ChainlinkExchangeRate

| # | Field | Type | Used? | Validated? | Notes |
|---|-------|------|-------|------------|-------|
| 1 | `feed_id` | FeedID | YES | YES | Checked against mapping |
| 2 | `valid_from_timestamp` | u32 | **NO** | **NO** | **IGNORED** |
| 3 | `observations_timestamp` | u32 | YES | YES | Monotonicity + clamping |
| 4 | `native_fee` | BigInt | **NO** | **NO** | Fee field, acceptable |
| 5 | `link_fee` | BigInt | **NO** | **NO** | Fee field, acceptable |
| 6 | `expires_at` | u32 | **NO** | **NO** | **IGNORED -- SECURITY RELEVANT** |
| 7 | `exchange_rate` | BigInt | YES | YES | Parsed, negative check, 192-bit bounds |

**V7 Validation:** feed_id, observations_timestamp, negative/overflow checks
**V7 Missing:** `expires_at` not checked, `valid_from_timestamp` not checked, **NO confidence interval check** (no bid/ask)

#### ReportDataV8 (9 fields) -- Used by OracleType::ChainlinkRWA

| # | Field | Type | Used? | Validated? | Notes |
|---|-------|------|-------|------------|-------|
| 1 | `feed_id` | FeedID | YES | YES | Checked against mapping |
| 2 | `valid_from_timestamp` | u32 | **NO** | **NO** | **IGNORED** |
| 3 | `observations_timestamp` | u32 | YES | YES | Monotonicity + clamping |
| 4 | `native_fee` | BigInt | **NO** | **NO** | Fee field, acceptable |
| 5 | `link_fee` | BigInt | **NO** | **NO** | Fee field, acceptable |
| 6 | `expires_at` | u32 | **NO** | **NO** | **IGNORED -- SECURITY RELEVANT** |
| 7 | `last_update_timestamp` | u64 | YES | YES | Used for staleness check in `validate_report_based_on_market_status()` |
| 8 | `mid_price` | BigInt | YES | YES | Parsed, negative check, 192-bit bounds |
| 9 | `market_status` | u32 | YES | YES | Validated as enum, checked against MarketStatusBehavior config |

**V8 Validation:** feed_id, observations_timestamp, market_status + staleness, negative/overflow
**V8 Missing:** `expires_at` not checked, `valid_from_timestamp` not checked, **NO confidence interval check**

#### ReportDataV9 (10 fields) -- Used by OracleType::ChainlinkNAV

| # | Field | Type | Used? | Validated? | Notes |
|---|-------|------|-------|------------|-------|
| 1 | `feed_id` | FeedID | YES | YES | Checked against mapping |
| 2 | `valid_from_timestamp` | u32 | **NO** | **NO** | **IGNORED** |
| 3 | `observations_timestamp` | u32 | YES | YES | Monotonicity + clamping |
| 4 | `native_fee` | BigInt | **NO** | **NO** | Fee field, acceptable |
| 5 | `link_fee` | BigInt | **NO** | **NO** | Fee field, acceptable |
| 6 | `expires_at` | u32 | **NO** | **NO** | **IGNORED -- SECURITY RELEVANT** |
| 7 | `nav_per_share` | BigInt | YES | YES | Parsed, negative check, 192-bit bounds |
| 8 | `nav_date` | u64 | YES | YES | Checked for staleness (7 day max) |
| 9 | `aum` | BigInt | **NO** | **NO** | **IGNORED** -- Assets Under Management |
| 10 | `ripcord` | u32 | YES | YES | Checked -- feed paused = reject |

**V9 Validation:** feed_id, observations_timestamp, nav_date staleness (7d), ripcord pause flag, negative/overflow
**V9 Missing:** `expires_at` not checked, `valid_from_timestamp` not checked, `aum` ignored (low risk), **NO confidence interval check**

#### ReportDataV10 (13 fields) -- Used by OracleType::ChainlinkX (xStocks)

| # | Field | Type | Used? | Validated? | Notes |
|---|-------|------|-------|------------|-------|
| 1 | `feed_id` | FeedID | YES | YES | Checked against mapping |
| 2 | `valid_from_timestamp` | u32 | **NO** | **NO** | **IGNORED** |
| 3 | `observations_timestamp` | u32 | YES | YES | Monotonicity + clamping |
| 4 | `native_fee` | BigInt | **NO** | **NO** | Fee field, acceptable |
| 5 | `link_fee` | BigInt | **NO** | **NO** | Fee field, acceptable |
| 6 | `expires_at` | u32 | **NO** | **NO** | **IGNORED -- SECURITY RELEVANT** |
| 7 | `last_update_timestamp` | u64 | YES | YES | Staleness check in market_status validation |
| 8 | `price` | BigInt | YES | YES | Parsed, negative check, 192-bit bounds |
| 9 | `market_status` | u32 | YES | YES | Validated via MarketStatusBehavior |
| 10 | `current_multiplier` | BigInt | YES | **PARTIAL** | Used in multiplication: `price * current_multiplier`. **No zero check. No bounds check.** |
| 11 | `new_multiplier` | BigInt | **NO** | **NO** | **IGNORED** -- only logged in warn messages |
| 12 | `activation_date_time` | u32 | YES | YES | Blackout period logic: suspends price refresh 24h before activation |
| 13 | `tokenized_price` | BigInt | **NO** | **NO** | **IGNORED** -- see TODO comment below |

**V10 Validation:** feed_id, observations_timestamp, market_status + staleness, activation blackout, negative/overflow on price and multiplier individually
**V10 Missing:**
- `expires_at` not checked
- `valid_from_timestamp` not checked
- `current_multiplier` has **NO zero check** -- if zero, `price * 0 = 0` which becomes the stored price
- `current_multiplier` has **NO upper-bound check** -- an extremely large multiplier would produce an overflow (mitigated by `try_mul` returning `MathOverflow`)
- `tokenized_price` completely ignored
- `new_multiplier` completely ignored (only logged)
- **NO confidence interval check** (unlike v3 which has bid/ask spread check)

**TODO Comment (line 483):**
```rust
// TODO(liviuc): once Chainlink has added the `total_return_price`, use that
```
This confirms `tokenized_price` is a placeholder field not yet used. The current approach multiplies `price * current_multiplier` manually.

### 1.2 CRITICAL FINDING: V10 `current_multiplier` Zero-Value Risk

**Location:** `chainlink.rs:480-487`
```rust
let price_dec = chainlink_bigint_value_parse(&chainlink_report.price)?;
let current_multiplier_dec =
    chainlink_bigint_value_parse(&chainlink_report.current_multiplier)?;
let multiplied_price: Price = price_dec
    .try_mul(current_multiplier_dec)
    .map_err(|_| ScopeError::MathOverflow)?
    .into();
```

If `current_multiplier` is `0` (which is the BigInt zero, passing the "not negative" check in `chainlink_bigint_value_parse`), the result is `price * 0 = 0`. This zero price WOULD be caught by the zero-price guard in `get_non_zero_price()` at line 468:
```rust
if price.price.value == 0 && price_type != OracleType::FixedPrice {
    return err!(ScopeError::PriceNotValid);
}
```

**HOWEVER**, Chainlink prices are NOT refreshed through `get_non_zero_price()`. They go through `refresh_chainlink_price()` which calls `chainlink::update_price_v10()` directly and stores the result without any zero-price guard. The zero-price guard in `mod.rs:468` only applies to the non-Chainlink refresh path.

**Assessment:** If Chainlink were to deliver a report with `current_multiplier = 0`, the zero price would be stored in `oracle_prices`. klend does NOT have a zero-price guard for scope-sourced prices (only Pyth and Switchboard have explicit zero checks). This would cause cascading issues in lending operations.

**Mitigating factors:**
- The Chainlink verifier program validates the signed report, so only legitimate DON-signed data passes
- In practice, `current_multiplier` for xStocks is set by the protocol and should never be zero
- A value of 0 would represent a corporate action (stock split) where shares become worthless, which is theoretically possible but should trigger the blackout mechanism first

**Severity: Low-Medium** (requires Chainlink DON to produce a valid zero-multiplier report)

### 1.3 `expires_at` Field -- Systematically Ignored

The `expires_at` field is present in ALL five report versions (V3, V7, V8, V9, V10) and represents "the latest timestamp at which the report can be verified on-chain." It is **never checked** in any version.

**Impact analysis:** This field's validation is performed by the Chainlink verifier program (`VERIFIER_PROGRAM_ID`) during the `invoke()` call in `handler_refresh_chainlink_price.rs:79-87`. The verifier CPI validates signatures, expiration, and configuration PDA. So this is defense-in-depth that is already covered by the verifier.

**Assessment:** Informational. The Chainlink verifier handles expiration. Scope trusts the verifier's judgment.

### 1.4 `valid_from_timestamp` -- Systematically Ignored

Present in all five versions, never checked. This represents the earliest timestamp at which the report is valid.

**Impact analysis:** Similar to `expires_at`, the Chainlink verifier program handles this. Additionally, the `observations_timestamp` monotonicity check provides temporal ordering protection.

**Assessment:** Informational.

### 1.5 Confidence Interval Asymmetry Across Chainlink Versions

| Version | Confidence Check | Fields Available |
|---------|-----------------|------------------|
| V3 (Chainlink) | YES -- bid/ask spread | bid, ask |
| V7 (ExchangeRate) | **NO** | Only exchange_rate |
| V8 (RWA) | **NO** | Only mid_price |
| V9 (NAV) | **NO** | Only nav_per_share |
| V10 (xStocks) | **NO** | Only price + multiplier |

Only V3 has a confidence interval check (using `check_confidence_interval_decimal` on the bid/ask spread). V7-V10 have no spread/confidence mechanism. This is acceptable since those report types don't include bid/ask data.

### 1.6 TODO Comments in Oracle Adapters

1. **`chainlink.rs:483`**: `TODO(liviuc): once Chainlink has added the 'total_return_price', use that` -- Indicates `tokenized_price` field will eventually replace the manual `price * current_multiplier` calculation
2. **`mod.rs:498-500`**: `TODO, should validate ownership of the ktoken account` -- kToken, KTokenToTokenA, KTokenToTokenB mapping validation does `Ok(())` without verifying account ownership
3. **`jupiter_lp.rs:47`**: `TODO: find a way to get the last update time` -- JLP uses current clock slot/timestamp rather than actual pool update time
4. **`pyth_pull.rs:62`**: `todo: Discuss how we should handle the time jump that can happen when there is an outage?` -- Same comment in `pyth_pull_ema.rs:55`

---

### 1.7 Comprehensive Oracle Adapter Validation Comparison

| Adapter | External Source | Staleness Check | Confidence Check | Negative Check | Zero Check | Owner Check |
|---------|----------------|-----------------|-------------------|----------------|------------|-------------|
| **Chainlink V3** | Signed report CPI | observations_ts monotonicity | YES (bid/ask spread) | YES (BigInt sign) | NO (at adapter) | Verifier CPI |
| **Chainlink V7** | Signed report CPI | observations_ts monotonicity | **NO** | YES (BigInt sign) | NO (at adapter) | Verifier CPI |
| **Chainlink V8** | Signed report CPI | observations_ts + market hours | **NO** | YES (BigInt sign) | NO (at adapter) | Verifier CPI |
| **Chainlink V9** | Signed report CPI | observations_ts + nav_date (7d) | **NO** | YES (BigInt sign) | NO (at adapter) | Verifier CPI |
| **Chainlink V10** | Signed report CPI | observations_ts + market hours | **NO** | YES (BigInt sign) | NO (at adapter) | Verifier CPI |
| **Pyth (legacy)** | On-chain account | Slot-based (10min) | YES (conf/price ratio) | Implicit (u64) | Implicit (Trading status) | Pyth program |
| **Pyth Pull** | PriceUpdateV2 account | Caller-configured | YES (conf/price ratio) | Implicit (u64 cast) | Via caller | Pyth Receiver SDK |
| **Pyth Pull EMA** | PriceUpdateV2 account | Caller-configured | YES (conf/price ratio) | Implicit (u64 cast) | Via caller | Pyth Receiver SDK |
| **Pyth Lazer** | Signed payload CPI | timestamp_us monotonicity | YES (bid/ask spread) | YES (u64 conversion) | Via caller | Lazer verifier |
| **Switchboard OD** | PullFeedAccountData | Slot-based estimation | YES (std_dev/price) | YES (mantissa sign) | Via caller | Switchboard program |
| **RedStone** | PriceData account | timestamp monotonicity | **NO** | YES (u64 overflow) | Via caller | RedStone program owner |
| **SPL Stake** | StakePool account | Epoch-based (1h grace) | **NO** | **NO** | **NO** (rate could be 0) | N/A |
| **MSOL Stake** | Marinade State | **NO explicit staleness** | **NO** | **NO** | **NO** | N/A |
| **Jito Restaking** | Vault account | **NO explicit staleness** | **NO** | **NO** | Returns Price::default if supply=0 | N/A |
| **Jupiter LP** | Pool + Mint | **NO** (uses current clock) | **NO** | **NO** | Division by 0 possible if supply=0 | JLP PDA check |
| **Orca Whirlpool** | Whirlpool account | **NO** (uses current clock) | **NO** | **NO** | **NO** | Deserialization |
| **Raydium V3** | PoolState account | **NO** (uses current clock) | **NO** | **NO** | **NO** | Deserialization |
| **Meteora DLMM** | LbPair account | **NO** (uses current clock) | **NO** | **NO** | **NO** | Deserialization |
| **Adrena LP** | Pool account | Timestamp clamped to now | **NO** | **NO** | **NO** | Owner check (adrena::ID) |
| **Flashtrade LP** | Pool account | Timestamp clamped to now | **NO** | **NO** | **NO** | Owner check (flashtrade::ID) |
| **KToken** | Strategy + Scope prices | Via component prices | Via component prices | Via component prices | If shares=0 returns 0 | Account PK checks |
| **Securitize** | VaultState + RedStone | Via RedStone | **NO** | YES (rate=0 check) | Rate=0 returns error | Hardcoded PK checks |
| **Fixed Price** | Admin config | N/A | N/A | N/A | **Allowed to be 0** | N/A |
| **TWAP** | Internal (scope prices) | Sample count validation | N/A | N/A | Via source | N/A |
| **MostRecentOf** | Internal (scope prices) | `sources_max_age_s` | Divergence check (bps) | N/A | Via source | N/A |
| **CappedFloored** | Internal (scope prices) | Via source | N/A | N/A | Via source | N/A |
| **DiscountToMaturity** | Admin config + clock | N/A | N/A | N/A | Non-zero by construction | N/A |

**Key observation:** The global zero-price guard at `mod.rs:468` catches zero prices from ALL adapters that go through `get_non_zero_price()`. But Chainlink adapters bypass this path entirely -- they go through `handler_refresh_chainlink_price.rs` which has NO zero-price guard. Similarly, PythLazer goes through its own handler.

### 1.8 KToken Price Calculation

**Location:** `scope/programs/scope/src/oracles/ktokens.rs`

**Inputs:**
1. `WhirlpoolStrategy` account (zero-copy) -- contains token mints, decimals, pool, position, scope_prices address
2. `GlobalConfig` account -- contains `token_infos` address
3. `CollateralInfos` account -- maps collateral tokens to scope price chain IDs
4. Pool account (Orca Whirlpool or Raydium PoolState)
5. Position account (Orca/Raydium position)
6. Scope prices account (cross-referenced from strategy)

**Calculation:**
1. Loads scope prices for token_a and token_b via their configured collateral chains
2. Derives a **sqrt price from scope oracle prices** (NOT from pool state -- avoiding manipulation)
3. Computes holdings using this oracle-derived sqrt price
4. Excludes reward tokens from holdings (manipulation resistance)
5. `price = total_holdings_value / shares_issued`

**Critical design:** The pool's on-chain sqrt_price is NOT used for pricing. Instead, the oracle-derived sqrt_price is used. This is a defense against pool price manipulation (flash loans, sandwich attacks).

**Zero-share edge case:** If `shares_issued == 0`, returns `Price { value: 0, exp: 1 }` which is caught by the zero-price guard at mod.rs:468.

---

## TASK 2: KLend External Data Analysis

### 2.1 How KLend Consumes Scope Prices

**Location:** `klend/programs/klend/src/utils/prices/scope.rs`

KLend reads scope prices via a "conversion chain" -- an array of up to 4 scope price IDs. The prices are multiplied together to form the final USD price.

```
price_chain = [scope_id_1, scope_id_2, scope_id_3, scope_id_4]
final_price = scope_prices[id_1] * scope_prices[id_2] * ... (up to 4)
```

The oldest timestamp among all chain entries is used as the price timestamp.

**Account validation:** Checks discriminator byte match against `ScopePrices::discriminator()` and that account key is not `NULL_PUBKEY`. Uses `bytemuck::from_bytes` for zero-copy deserialization.

### 2.2 Zero-Price Guard Gap in KLend for Scope Prices

**Finding:** KLend has explicit zero-price guards for:
- **Pyth:** `if price == 0 { return err!(LendingError::PriceIsZero); }` (pyth.rs:76)
- **Switchboard:** `if price_switchboard_desc.mantissa() <= 0 { return err!(LendingError::PriceIsZero); }` (switchboard.rs:60-62)

**But Scope has NO zero-price guard in the KLend price path.** The `get_base_price()` function (scope.rs:150) directly returns whatever is in `scope_prices.prices[token_id]` without checking if `price.value == 0`.

**Impact:** If scope somehow stores a zero price (which the global guard at mod.rs:468 prevents for most adapters BUT NOT for Chainlink path), klend would consume it and use it for collateral/borrow calculations.

**However**, note that:
1. The heuristic check in `checks.rs:143-168` can catch abnormally low prices if configured
2. The TWAP divergence check would likely catch a sudden drop to zero
3. The `block_price_usage` flag can administratively block a price

**Assessment:** The zero-price gap in klend's scope path is defense-in-depth that's missing, but the primary defense is at the scope level. Low severity because scope's own guard covers most paths, and klend's heuristic/twap checks provide secondary protection.

### 2.3 KLend External Data Blobs

KLend does NOT accept raw external data blobs in its instructions. All price data comes from:
1. Pyth PriceUpdateV2 accounts (deserialized from on-chain account)
2. Switchboard PullFeedAccountData accounts (zero-copy deserialized)
3. Scope OraclePrices accounts (zero-copy deserialized)

All three sources are pre-validated on-chain accounts, not arbitrary user-submitted data.

### 2.4 KLend Price Validation Pipeline

```
get_price() -> get_most_recent_price_and_twap() -> get_validated_price()

Validation checks:
1. Price loaded successfully (PRICE_LOADED flag)
2. Price age vs max_age_price_seconds (PRICE_AGE_CHECKED flag)
3. TWAP loaded and age checked (TWAP_AGE_CHECKED flag)
4. Price vs TWAP divergence within tolerance (TWAP_CHECKED flag)
5. Heuristic bounds (lower/upper) (HEURISTIC_CHECKED flag)
6. Price usage not blocked (PRICE_USAGE_ALLOWED flag)
```

The result is a `PriceStatusFlags` bitmask. The caller (lending operations) checks which flags are set to determine if the price is usable for specific operations (borrowing, liquidation, etc.).

---

## TASK 3: KFarms External Data Analysis

### 3.1 KFarms External Data Blobs

KFarms does NOT accept raw external data blobs. It consumes scope prices via `load_scope_price()` in `utils/scope.rs`:

```rust
pub fn load_scope_price(
    scope_prices_account: &Option<AccountLoader<'_, scope::OraclePrices>>,
    farm_state: &FarmState,
) -> Result<Option<DatedPrice>> {
```

**Validation in this function:**
1. If `scope_oracle_price_id == u64::MAX`, returns `None` (oracle disabled)
2. Validates scope account key is not `Pubkey::default()` and not `crate::ID`
3. Validates scope account key matches `farm_state.scope_prices`
4. Directly indexes `scope_prices.prices[farm_state.scope_oracle_price_id]`

**No zero-price check at this level.** No staleness check at this level.

### 3.2 KFarms Scope Price Usage for Deposit Caps

**Location:** `state.rs:181-223`, `farm_operations.rs:891-914`

**Deposit cap check (state.rs):**
```rust
let final_amount = unadjusted_total * price_value / price_ten_pow;
Ok(self.deposit_cap_amount == 0 || final_amount <= self.deposit_cap_amount)
```

If `price.price.value == 0`, then `final_amount = 0`, which means `0 <= deposit_cap_amount` is always true, effectively **bypassing the deposit cap**. However, this requires scope to store a zero price.

**Reward issuance adjustment (farm_operations.rs):**
```rust
let oracle_adjusted_amt = decimal_adjusted_amt * px / factor;
```

If `price.price.value == 0`, then `oracle_adjusted_amt = 0`, meaning zero rewards are issued. This is a denial-of-reward scenario, not an exploit.

**Staleness check:** KFarms checks `ts - price.unix_timestamp > farm_state.scope_oracle_max_age` which is a proper staleness guard.

**Assessment:** KFarms has appropriate staleness checks. The zero-price scenario would bypass deposit caps but requires a scope-level failure. Low severity.

---

## Summary of Findings

### Findings Ranked by Severity

#### 1. [Low-Medium] V10 `current_multiplier` Not Bounds-Checked

**File:** `scope/programs/scope/src/oracles/chainlink.rs:480-487`

The `current_multiplier` field from ChainlinkX (v10) reports is used in price calculation (`price * current_multiplier`) without checking for zero or abnormal values.

- **If zero:** Produces a $0 price that gets stored (no zero guard on Chainlink refresh path)
- **If extremely large:** `try_mul` returns `MathOverflow` error, so overflow is caught
- **Mitigating:** Chainlink DON would need to sign a report with multiplier=0

#### 2. [Low] Chainlink Refresh Path Bypasses Zero-Price Guard

**File:** `scope/programs/scope/src/handlers/handler_refresh_chainlink_price.rs`

All five Chainlink oracle types bypass the `get_non_zero_price()` guard. A zero-priced Chainlink report would be stored without rejection.

The `get_non_zero_price()` guard at `mod.rs:468` only covers the `refresh_price_list` path (non-Chainlink oracles).

#### 3. [Informational] `expires_at` and `valid_from_timestamp` Ignored Across All Chainlink Versions

All five Chainlink report versions contain `expires_at` and `valid_from_timestamp` fields that are never checked by scope. This is mitigated by the Chainlink verifier CPI handling expiration validation.

#### 4. [Informational] Confidence Interval Only on V3

Only Chainlink V3 (standard crypto feeds) has a confidence interval check via bid/ask spread. V7-V10 do not have equivalent checks since their report formats don't include bid/ask data.

#### 5. [Informational] KLend Missing Zero-Price Guard for Scope Path

KLend explicitly rejects zero prices from Pyth and Switchboard but has no equivalent check for scope-sourced prices. Scope's own guards mitigate this for most oracle types, but the Chainlink refresh path gap (finding #2) creates a theoretical end-to-end zero-price path.

#### 6. [Informational] KToken Mapping Validation is a No-Op

`mod.rs:498-500` -- KToken, KTokenToTokenA, KTokenToTokenB all return `Ok(())` during mapping validation, with TODO comments acknowledging the ownership verification gap. The account checks happen at price-read time instead.

#### 7. [Informational] V10 `tokenized_price` and `new_multiplier` Ignored

`tokenized_price` and `new_multiplier` are unused. The TODO comment at line 483 confirms `tokenized_price` is planned for future use. `new_multiplier` is only logged in warning messages during blackout periods.

#### 8. [Informational] DEX Pool Prices (Orca, Raydium, Meteora) Have No Staleness Check

These adapters set `last_updated_slot = clock.slot` and `unix_timestamp = clock.unix_timestamp`, meaning the price always appears fresh regardless of when the pool was last traded. This is a known design tradeoff -- consumers must apply their own staleness logic based on pool-specific factors.

---

## Chain-of-Trust Analysis

```
Chainlink DON -> Signs Report -> Verifier CPI (validates sig/expiry) ->
  Scope (validates feed_id, monotonicity, market_status) ->
    Stored in oracle_prices ->
      klend reads (validates age, twap divergence, heuristics) ->
        Used in lending operations

Pyth -> On-chain account -> Scope (validates status, staleness, confidence) ->
  Stored in oracle_prices ->
    klend reads (validates age, twap divergence, heuristics)

Switchboard -> PullFeedAccountData -> Scope (validates confidence) ->
  Stored in oracle_prices
```

The multi-layer validation approach is solid. The only structural gap is the Chainlink refresh path bypassing scope's zero-price guard, which is a narrow edge case requiring a malformed but validly-signed Chainlink report.
