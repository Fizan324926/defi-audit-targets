# Permissionless Crank Operator Can Exploit Missing Multiplier Validation in ChainlinkX v10 Oracle to Corrupt xStocks Prices on KLend

## Brief

The `update_price_v10` function in Scope's Chainlink oracle handler (`chainlink.rs:408-504`) takes a `current_multiplier` value from the Chainlink Data Streams v10 report and directly multiplies it into the oracle price with **zero bounds checking**. The `refresh_chainlink_price` instruction is fully permissionless — any keypair can submit any valid DON-signed report. During a corporate action (stock split), both pre-split and post-split DON-signed reports coexist as valid. A crank operator who also holds KLend positions can **selectively choose which report to submit and when**, exploiting the fact that `update_price_v10` performs zero validation on the multiplier field — unlike every other oracle adapter in Scope.

Three entries (#262, #266, #282) have absolutely no secondary protection — no `ref_price`, no confidence check, nothing between the raw multiplier and KLend's collateral engine. Combined with the fact that Scope ignores the report's `expires_at` timestamp (allowing stale report consumption) and that the entire suspension mechanism is bypassed when `activation_date_time = 0`, this creates a concrete path from permissionless crank submission to protocol insolvency.

**TVL at risk**: ~$5-20M in xStocks collateral on KLend (isolated market), with the broader xStocks ecosystem at ~$228M total market cap on Solana.

---

## Vulnerability Details

### Where

- **File**: `programs/scope/src/oracles/chainlink.rs`
- **Function**: `update_price_v10` (lines 408-504)
- **Repo**: https://github.com/Kamino-Finance/scope (v0.32.0, commit `b2c689e`)
- **Also affected**: `handler_refresh_chainlink_price.rs` (permissionless instruction handler)

### What's happening

At lines 480-487, the function takes the raw price and the `current_multiplier` from the Chainlink report, multiplies them together, and stores the result. No checks on the multiplier at all:

```rust
// chainlink.rs lines 480-487
let price_dec = chainlink_bigint_value_parse(&chainlink_report.price)?;
let current_multiplier_dec =
    chainlink_bigint_value_parse(&chainlink_report.current_multiplier)?;
// TODO(liviuc): once Chainlink has added the `total_return_price`, use that
let multiplied_price: Price = price_dec
    .try_mul(current_multiplier_dec)   // <-- no bounds check on multiplier
    .map_err(|_| ScopeError::MathOverflow)?
    .into();
// no check_confidence_interval_decimal() call either
```

Two things are missing here:

**1) No multiplier bounds check.** The `chainlink_bigint_value_parse` function (line 568) does reject negative values and values that don't fit in 192 bits, but it happily accepts zero. So `current_multiplier = 0` is a valid input that produces `price * 0 = $0`. There's also no upper bound, so a multiplier of 1000x just goes through.

**2) No confidence interval check.** The v3 handler (same file, line 267) calls `check_confidence_interval_decimal(price_dec, spread, confidence_factor)` to reject prices with abnormally wide bid-ask spreads. The v10 handler simply doesn't have this. At all.

The developer's own TODO at line 483 (`// TODO(liviuc): once Chainlink has added the total_return_price, use that`) shows this code was written as a temporary implementation and never got the validation it needs.

---

## Attack Vector 1: Permissionless Crank Selective Report Submission

### The crank is fully permissionless

The `RefreshChainlinkPrice` account struct (`handler_refresh_chainlink_price.rs:23-54`) has a single signer constraint:

```rust
// handler_refresh_chainlink_price.rs:25-26
pub struct RefreshChainlinkPrice<'info> {
    /// The account that signs the transaction.
    pub user: Signer<'info>,
```

That `user` field is only forwarded to the Chainlink verifier CPI (`handler_refresh_chainlink_price.rs:65-76`) — Scope performs no access control. There is no `has_one = admin`, no seeds constraint, and no `Configuration` account loaded. Compare this with `ResumeChainlinkXPrice` (`handler_resume_chainlinkx_price.rs:15-19`), which requires `pub admin: Signer<'info>` and a `has_one = admin` constraint.

The instruction signature (`lib.rs:55-65`):

```rust
pub fn refresh_chainlink_price<'info>(
    ctx: Context<'_, '_, '_, 'info, RefreshChainlinkPrice<'info>>,
    token: u16,
    serialized_chainlink_report: Vec<u8>,  // <-- caller chooses this
) -> Result<()> {
```

**Any keypair can call `refresh_chainlink_price` with any valid DON-signed report blob.** The caller controls which report to submit.

Additionally, unlike the standard `refresh_price_list` instruction which has the `check_execution_ctx` anti-sandwich guard, `refresh_chainlink_price` has **no such guard** — it can be executed via CPI and can be sandwiched.

### The only ordering enforcement is weak

The timestamp check (`chainlink.rs:164-183`) only requires:

```rust
if observations_ts <= last_observations_ts {
    warn!("An outdated report was provided");
    return Err(ScopeError::BadTimestamp);
}
```

This means any report with `observations_timestamp > last_stored_timestamp` is accepted. It does not enforce that the report is the *most recent* available. A crank can hold multiple valid reports and submit them selectively.

### Attack scenario during a stock split

**Setup — Attacker positions before the split:**

1. Apple announces a 2-for-1 stock split. Chainlink begins embedding `activation_date_time` and `new_multiplier = 2e18` in v10 reports.
2. Attacker deposits AAPLx as collateral on KLend. Borrows maximum USDC against it at oracle price $150 x 1.0 = $150.

**Phase 1 — Blackout (T-24h to T+0):**

3. When the first report with `activation_date_time > 0` arrives and someone cranks it, `update_price_v10` (line 450) triggers the suspension: `suspended = true`. Oracle is frozen at $150.
4. KLend positions remain priced at $150 throughout the blackout.

**Phase 2 — Admin resumes:**

5. After the split activates, Kamino admin calls `resume_chainlinkx_price`. This sets `suspended = false` and resets `observations_timestamp` to `clock.unix_timestamp` (`handler_resume_chainlinkx_price.rs:74-78`).
6. The correct post-split price should be $75 x 2.0 = $150.00 (stock price halved, multiplier doubled).

**Phase 3 — Attacker selectively submits a stale pre-split report:**

7. The attacker has been archiving valid DON-signed reports. They hold report R_stale with `observations_timestamp = T_resume + 1s`, `price = $150 WAD`, `current_multiplier = 1e18` (the pre-split multiplier).
8. Attacker calls `refresh_chainlink_price` with R_stale. Chainlink verifier accepts it (DON signatures valid). `update_price_v10` runs:
   - `validate_observations_timestamp`: T_resume+1 > T_resume -> passes
   - `suspended = false` -> passes
   - `activation_date_time = 0` in R_stale -> suspension check at line 444 is **skipped entirely**
   - `price_dec = 150e18`, `current_multiplier_dec = 1e18`
   - `multiplied_price = $150`
9. **The oracle now shows $150, but the real post-split value of the AAPLx token (which has been rebased 2:1) is only $75.** The AAPLx token has twice as many units, each worth half as much — but the oracle still prices them at $150.
10. Attacker borrows additional USDC against the inflated collateral value.
11. When the correct report is eventually submitted, the oracle corrects to $75 x 2 = $150 per original unit, but the attacker's rebased position is now undercollateralized. Protocol absorbs the bad debt.

**Alternatively — Zero multiplier during transition:**

If during the transition window the DON briefly signs a report with `current_multiplier = 0` (initialization state, race condition, or data feed glitch):

1. Crank submits the zero-multiplier report
2. `$150 * 0 = $0` stored as oracle price
3. All AAPLx-collateralized positions become instantly liquidatable
4. Liquidation bots drain everything at $0 collateral valuation

---

## Attack Vector 2: `activation_date_time = 0` Suspension Bypass

The entire suspension mechanism is gated by a single line at `chainlink.rs:444`:

```rust
if chainlink_report.activation_date_time > 0 {
    // ... entire blackout logic (lines 444-471) ...
}
```

When `activation_date_time = 0` — which is the **normal steady-state value** when no corporate action is pending — the entire block is skipped unconditionally. This means:

1. A report that carries `activation_date_time = 0` bypasses all suspension logic
2. Even if `new_multiplier` wildly differs from `current_multiplier` in that report, no alarm is raised
3. Even if the multiplier is zero, the code falls straight through to `price * 0 = $0`
4. The `V10_TIME_PERIOD_BEFORE_ACTIVATION_TO_SUSPEND_S` constant (24 hours) is never evaluated

The `new_multiplier` field is only used in log messages (`chainlink.rs:429-437`, `452-460`) — it is never compared to `current_multiplier` for validation. A report with `current_multiplier = 0` and `activation_date_time = 0` will produce a $0 oracle price with zero protection triggered.

The constant is defined at line 35:
```rust
const V10_TIME_PERIOD_BEFORE_ACTIVATION_TO_SUSPEND_S: i64 = 24 * 60 * 60; // 24 hours
```

This constant is referenced **only** inside the guarded block. When `activation_date_time = 0`, it's dead code.

---

## Attack Vector 3: Ignored `tokenized_price` Cross-Reference

The `ReportDataV10` struct has 13 fields. Scope only uses 8. The most important ignored field is `tokenized_price` — a separate DON-signed price representing the 24/7 tokenized equity value. This field is available in every single v10 report, but Scope never reads it.

If Scope compared `price * current_multiplier` against `tokenized_price`, it would catch:
- Zero multiplier: result = $0, tokenized_price = $150 -> obvious anomaly, reject
- 1000x multiplier: result = $150,000, tokenized_price = $150 -> obvious anomaly, reject
- Even moderate errors that slip past the 5% ref_price tolerance

A grep across the entire Scope codebase confirms `tokenized_price` appears nowhere. Not in the handler, not in any test, not in any config. It's completely unused.

Other ignored fields that matter:
- `valid_from_timestamp` — could prevent consuming reports before they're valid
- `expires_at` — could prevent consuming expired/stale reports (critical for the crank replay attack above)
- `new_multiplier` — only logged, never validated against `current_multiplier`

### This is the only adapter without validation

| Adapter | Validation | Where |
|---|---|---|
| Chainlink v3 | `check_confidence_interval_decimal(price, spread, factor)` | chainlink.rs:267 |
| Pyth | `check_confidence_interval(price, exp, conf, ...)` | pyth.rs:110 |
| Pyth Pull | `validate_valid_price` with confidence check | pyth_pull.rs:50 |
| Pyth Lazer | `check_confidence_interval(...)` | pyth_lazer.rs:156 |
| Switchboard | `check_confidence_interval(...)` | switchboard_on_demand.rs:78 |
| Most Recent Of | `check_confidence_interval_decimal_bps(...)` | most_recent_of.rs:112 |
| **ChainlinkX v10** | **nothing** | **chainlink.rs:480-487** |

### Zero test coverage

There are no tests for `update_price_v10` anywhere in the Scope codebase. Searched for `#[test]`, `#[cfg(test)]`, and any test files mentioning chainlink or v10. Nothing. The entire v10 code path — multiplier handling, suspension logic, market status checks — has never been unit tested.

---

## Impact

### Immunefi Classification

Under the Immunefi Vulnerability Severity Classification System v2.2 for Smart Contracts:

- **Protocol insolvency** (Critical — inflated multiplier allows borrowing against fake collateral value; when price corrects, KLend is left with undercollateralized debt)
- **Direct theft of user funds** (Critical — zero multiplier enables liquidation bots to drain collateral positions at $0 valuation)

**Severity: High** — The permissionless crank provides a concrete external attack vector during corporate action windows. The attacker does not need to forge DON signatures; they only need to selectively submit valid reports that benefit their position.

### TVL at risk

Based on publicly available data:

| Metric | Value | Source |
|---|---|---|
| Kamino KLend total TVL | ~$2.0B | DeFiLlama, March 2026 |
| xStocks market on KLend (Dec 2025 snapshot) | $3.9M | Kamino 2025 Year-in-Review |
| xStocks market on KLend (estimated March 2026) | **$5-20M** | Based on 271.9% 90-day growth rate |
| xStocks ecosystem total (Solana) | ~$196M | CoinGecko/xStocks data, Jan 2026 |
| xStocks ecosystem total (all chains) | ~$228M | CoinGecko BackedFi category |

The xStocks market on KLend is an **isolated lending market** — exposure is ring-fenced from the $2B main pool. The at-risk amount is specifically what is deposited into the xStocks isolated market.

Individual token breakdown (Dec 2025 snapshot): TSLAx ($1.1M), NVDAx ($0.9M), SPYx ($0.8M), others smaller.

Max LTV ratio for xStocks: 35% (conservative setting by Kamino, indicating risk awareness).

### The 3 completely unprotected entries

Entries #262, #266, and #282 have `ref_price = 0xFFFF`, meaning `check_ref_price_difference` at `handler_refresh_chainlink_price.rs:222-231` is skipped entirely. For these entries:

- Zero multiplier -> price stored as $0, no check catches it
- 1000x multiplier -> inflated price stored, no check catches it
- There is literally zero defense between the raw report data and KLend reading that price

The other 10 entries have `ref_price` pointing to Pyth feeds with a default 5% tolerance (`MAX_REF_RATIO_TOLERANCE_BPS = 500` at `price_impl.rs:10`). That would catch extreme values like $0 or 1000x, but not moderate manipulation within 5%.

### Historical precedents: This class of bug causes real losses

| Incident | Date | Loss | Root Cause |
|---|---|---|---|
| **Moonwell** (Chainlink OEV wrapper) | Feb 15, 2026 | **$1.8M** bad debt | Used raw cbETH/ETH rate instead of multiplying by ETH/USD — structurally identical to using `price` without `current_multiplier` |
| **Morpho PAXG/USDC** | Oct 13, 2024 | **$230K** | `SCALE_FACTOR` misconfigured — PAXG overvalued by 10^12. Attacker supplied $350, borrowed $230K |
| **Ribbon Finance / Aevo** | Dec 12, 2025 | **$2.7M** | Oracle precision upgrade didn't account for legacy decimal assets — post-upgrade window with mismatched scaling |
| **Loopscale** (Solana) | Apr 26, 2025 | **$5.8M** | Manipulated RateX PT oracle price to inflate tokenized asset collateral — same pattern as this vulnerability |
| **KiloEx** | Apr 14, 2025 | **$7M** | Oracle access control missing — attacker set ETH/USD to $100 then $10,000 |

**Total losses from this class: >$17M in the last 18 months.** The Moonwell incident (Feb 2026) is particularly relevant — it involved Chainlink infrastructure and a missing multiplication step, exactly the pattern in this report.

### Chainlink's own documentation confirms the risk window

From Chainlink Data Streams Best Practices:

> "If activation occurs while the underlying market is closed, prices may still show the pre-event last trade. **Do not compute the Theoretical Price during this pre-adjustment window.** Monitor marketStatus and keep the protocol paused until the first post-event trade prints and the Theoretical Price is continuous."

From xStocks official documentation:

> "Trading venues and protocols are advised to **pause interactions with the affected token for a brief window around each activation timestamp** to prevent unexpected settlement behavior."

The corporate action transition window is not hypothetical. It is formally documented by Chainlink as a condition requiring protocol-level pausing. Scope's suspension mechanism (the `activation_date_time` check) is the intended implementation of this — but it is bypassed when `activation_date_time = 0`.

---

## Risk Breakdown

| Factor | Assessment |
|--------|------------|
| **Difficulty of Exploitation** | Moderate. Requires a valid DON-signed report with anomalous multiplier OR selective submission of pre/post-split reports during the transition window. The crank is permissionless — no special access needed. |
| **Attacker Profile** | Any entity running a Chainlink Data Streams subscription. Can archive reports and submit selectively. Combined with a KLend position, this is a profitable attack. |
| **Affected Assets** | 13 live ChainlinkX v10 entries on Solana mainnet |
| **Funds at Risk** | $5-20M in xStocks on KLend (isolated market); $228M xStocks ecosystem on Solana |
| **Attack Surface** | 3 entries with zero protection, 10 entries with 5% tolerance |
| **Attacker Control** | Cannot forge DON signatures, but CAN choose which valid report to submit and when. The permissionless crank + lack of `expires_at` enforcement enables selective/stale report submission. |
| **Likelihood** | High during corporate actions. Stock splits are routine events for equity tokens (NVIDIA 10:1 June 2024, Tesla 3:1 Aug 2022, Apple 4:1 Aug 2020). The `current_multiplier` field WILL change during these events. |
| **Immunefi Severity** | Smart Contracts — High (permissionless crank enables selective oracle manipulation during corporate actions, leading to protocol insolvency or mass liquidation) |

---

## Proof of Concept

The PoC is a standalone Rust binary that replicates the exact arithmetic from `update_price_v10` using the same crates Scope uses (`decimal-wad v0.1.7`, `num-bigint v0.4`). It's runnable, not pseudocode.

### How to run

```bash
cd PoC/
cargo test -- --nocapture
```

### What it proves

| Test | What it does | Result |
|------|-------------|--------|
| PoC A | Passes `current_multiplier = BigInt(0)` through the v10 math. Result: $150 stock becomes $0. | PASS |
| PoC B | Passes `current_multiplier = 1000 * WAD` through the v10 math. Result: $150 stock becomes $150,000. No rejection. | PASS |
| PoC C | Runs the same unreliable price (66.7% spread) through v3 and v10. v3 rejects it via `check_confidence_interval_decimal`. v10 accepts it without any check. | PASS |
| PoC D | Validates that a simple bounds check (`0 < mult <= 10 * WAD`) correctly catches bad values while allowing legitimate multipliers (1x normal, 2x stock split, 10x max). | PASS |
| PoC E | Shows that `tokenized_price` (a DON-signed field in every v10 report) would catch both zero and extreme multipliers if Scope checked it. Scope never reads this field. | PASS |
| Supplementary | Confirms `chainlink_bigint_value_parse` at line 568 accepts `BigInt(0)` as valid input, producing `Decimal(0)`. | PASS |

All 6 tests pass. The math is identical to what Scope does on-chain.

### End-to-end attack flow

```
1. Attacker subscribes to Chainlink Data Streams, archives DON-signed reports
2. Attacker opens KLend position (deposits AAPLx, borrows USDC at $150 valuation)
3. Stock split announced — Chainlink begins embedding activation_date_time
4. Blackout triggers: oracle suspended for 24h
5. Admin resumes oracle — observations_timestamp reset to now
6. Attacker submits archived pre-split report (obs_ts > resume_ts, activation_date_time = 0)
   -> Suspension check SKIPPED (activation_date_time = 0)
   -> Old multiplier applied -> oracle price inflated relative to rebased token
7. Attacker borrows additional USDC against inflated collateral
8. Correct report eventually submitted -> price corrects
9. Attacker's position is now undercollateralized -> KLend absorbs bad debt
```

### On-chain verification

There's also a Node.js script that reads the live mainnet state directly:

```bash
npm install
node onchain-verification/verify_chainlinkx_mainnet.mjs
```

This queries the actual Solana RPC, decodes the OracleMappings and OraclePrices accounts, and shows all 13 v10 entries with their prices, feed IDs, and ref_price configuration.

---

## On-Chain Evidence

Verified against Solana mainnet on 2026-02-28. All entries were updated within minutes of the check.

| Entry | Token | Price | ref_price Target | Protected? |
|-------|-------|-------|-----------------|------------|
| #258 | AAPLx | $264.70 | #26 (Pyth AAPL/USD) | Yes (5%) |
| #260 | HOODx | $75.84 | #94 (Pyth HOOD/USD) | Yes (5%) |
| **#262** | **Unknown** | **$83.48** | **None** | **No** |
| #264 | GOOGLx | $311.97 | #34 (Pyth GOOGL/USD) | Yes (5%) |
| **#266** | **Unknown** | **$648.79** | **None** | **No** |
| #268 | NVDAx | $177.39 | #42 (Pyth NVDA/USD) | Yes (5%) |
| #270 | MSTRx | $129.74 | #72 (Pyth MSTR/USD) | Yes (5%) |
| #272 | TSLAx | $402.42 | #56 (Pyth TSLA/USD) | Yes (5%) |
| #274 | AMZNx | $210.01 | #50 (Pyth AMZN/USD) | Yes (5%) |
| #276 | COINx | $176.00 | #64 (Pyth COIN/USD) | Yes (5%) |
| #278 | Unknown | $688.11 | #284 (Pyth ref) | Yes (5%) |
| #280 | QQQx | $608.08 | #90 (Pyth QQQ/USD) | Yes (5%) |
| **#282** | **Unknown** | **$394.14** | **None** | **No** |

Key accounts:

| Account | Address |
|---------|---------|
| Scope Program | `HFn8GnPADiny6XqUoWE8uRPPxb29ikn4yTuPa9MF2fWJ` |
| OracleMappings | `4zh6bmb77qX2CL7t5AJYCqa6YqFafbz3QJNeFvZjLowg` |
| Chainlink Verifier | `Gt9S41PtjR58CbG9JhJ3J6vxesqrNAswbWYbLNTMZA3c` |

All feed IDs start with `0x000a`, confirming they use the v10 report schema.

---

## Recommendation

### 1. Add multiplier bounds check (most important)

After line 482 in `chainlink.rs`, reject zero and extreme multipliers:

```rust
let current_multiplier_dec =
    chainlink_bigint_value_parse(&chainlink_report.current_multiplier)?;

// Reject zero or extreme multipliers
let max_multiplier = Decimal::from(10u64); // 10x covers stock splits up to 10:1
if current_multiplier_dec == Decimal::from(0u64) {
    return Err(ScopeError::PriceNotValid.into());
}
if current_multiplier_dec > max_multiplier {
    return Err(ScopeError::PriceNotValid.into());
}
```

### 2. Validate `expires_at` and `valid_from_timestamp`

Reject stale or premature reports to prevent the crank replay attack:

```rust
if chainlink_report.valid_from_timestamp > clock.unix_timestamp as u64 {
    return Err(ScopeError::BadTimestamp.into()); // report not yet valid
}
if chainlink_report.expires_at > 0 && chainlink_report.expires_at < clock.unix_timestamp as u64 {
    return Err(ScopeError::BadTimestamp.into()); // report expired
}
```

### 3. Cross-validate against `tokenized_price`

The `tokenized_price` field is already in every v10 report, already DON-signed, and already available. After computing `price * current_multiplier`, compare it against `tokenized_price` with a reasonable tolerance. This is the fix the developer's TODO was waiting for — it just needs to be wired up.

### 4. Add confidence interval validation

Bring v10 in line with every other adapter by adding a `check_confidence_interval_decimal` call. The v3 handler at line 267 shows the exact pattern.

### 5. Validate `new_multiplier` divergence

If `new_multiplier` diverges significantly from `current_multiplier` but `activation_date_time = 0`, this signals an inconsistent report that should be rejected rather than processed.

### 6. Set `ref_price` for entries #262, #266, #282

These 3 entries currently have no post-update sanity check at all. Pointing their `ref_price` to a Pyth feed for the same underlying stock would add a second layer of defense.

---

## References

- `programs/scope/src/oracles/chainlink.rs:408-504` — `update_price_v10` (vulnerable function)
- `programs/scope/src/oracles/chainlink.rs:267` — `update_price_v3` confidence check (for comparison)
- `programs/scope/src/oracles/chainlink.rs:444` — `activation_date_time` suspension gate (bypassed when 0)
- `programs/scope/src/oracles/chainlink.rs:568` — `chainlink_bigint_value_parse` (accepts zero)
- `programs/scope/src/handlers/handler_refresh_chainlink_price.rs:23-27` — permissionless crank (no admin check)
- `programs/scope/src/handlers/handler_refresh_chainlink_price.rs:222-231` — ref_price check
- `programs/scope/src/handlers/handler_resume_chainlinkx_price.rs:15-19` — admin-only resume (contrast with permissionless refresh)
- `programs/scope/src/handlers/handler_resume_chainlinkx_price.rs:74-78` — timestamp reset on resume
- `programs/scope/src/utils/price_impl.rs:10` — `MAX_REF_RATIO_TOLERANCE_BPS = 500`
- `programs/scope/src/utils/math.rs:225` — `check_confidence_interval_decimal`
- `klend/programs/klend/src/utils/prices/scope.rs` — KLend reading Scope oracle prices
- Scope repository: https://github.com/Kamino-Finance/scope
- Chainlink verifier on mainnet: `Gt9S41PtjR58CbG9JhJ3J6vxesqrNAswbWYbLNTMZA3c`
