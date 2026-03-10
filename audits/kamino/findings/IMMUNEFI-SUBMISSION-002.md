# Permissionless Crank Operator Can Exploit Missing Multiplier Validation in ChainlinkX v10 Oracle to Corrupt xStocks Prices on KLend

## Bug Description

The `update_price_v10` function in Scope's Chainlink oracle handler (`chainlink.rs:408-504`) accepts a `current_multiplier` value from Chainlink Data Streams v10 reports and multiplies it into the oracle price with **zero bounds checking, zero confidence interval validation, and zero cross-reference against the DON-signed `tokenized_price` field**. The `refresh_chainlink_price` instruction is fully permissionless — any keypair can submit any valid DON-signed report — and it lacks the `check_execution_ctx()` anti-CPI guard present on `refresh_price_list`, making it sandwichable in a single atomic transaction.

During a corporate action (stock split), both pre-split and post-split DON-signed reports coexist as valid. A crank operator who also holds KLend positions can **selectively choose which report to submit and when**, exploiting the fact that `update_price_v10` performs zero validation on the multiplier field — unlike every other oracle adapter in Scope. Additionally, Scope ignores the report's `expires_at` field (allowing consumption of stale reports) and `valid_from_timestamp` (allowing premature reports), creating a concrete replay window.

Three entries (#262, #266, #282) have absolutely no secondary protection — no `ref_price`, no confidence check, nothing between the raw multiplier and KLend's collateral engine. Combined with the `activation_date_time = 0` bypass that disables all suspension logic, this creates a concrete path from permissionless crank submission to **protocol insolvency**.

**Estimated funds at risk**: ~$5-20M in xStocks collateral on KLend (isolated market). This exceeds the $50,000 minimum threshold for Critical severity per Kamino's program rules. At the 10% of funds at risk formula: $500K-$2M (capped at $1.5M, floored at $150K).

---

## Vulnerability Details

### Target Asset

- **Program**: Kamino's Price Oracle Aggregator (Scope)
- **Repository**: https://github.com/Kamino-Finance/scope
- **Onchain address**: `HFn8GnPADiny6XqUoWE8uRPPxb29ikn4yTuPa9MF2fWJ`
- **File**: `programs/scope/src/oracles/chainlink.rs`
- **Function**: `update_price_v10` (lines 408-504)
- **Version**: v0.32.0, commit `b2c689e`
- **Also affected**: `handler_refresh_chainlink_price.rs` (permissionless instruction handler)

### Root Cause

At lines 480-487, the function takes the raw price and the `current_multiplier` from the Chainlink report, multiplies them together, and stores the result. No validation of any kind is performed:

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
// no cross-reference against tokenized_price either
```

Five critical validations are missing:

**1) No multiplier bounds check.** `chainlink_bigint_value_parse` (line 568) rejects negative values and 192-bit overflows, but accepts zero. `current_multiplier = 0` produces `price * 0 = $0`. No upper bound exists either.

**2) No confidence interval check.** The v3 handler (same file, line 267) calls `check_confidence_interval_decimal(price_dec, spread, confidence_factor)`. The v10 handler has no equivalent — it is the **only** oracle adapter in Scope without confidence validation.

**3) No `tokenized_price` cross-reference.** Every v10 report contains a DON-signed `tokenized_price` field (the "24/7 tokenized equity price"). Scope never reads it. This field would catch both zero-multiplier and extreme-multiplier anomalies.

**4) No `expires_at` enforcement.** Scope ignores the report's expiration timestamp, allowing indefinitely stale reports to be consumed as long as their `observations_timestamp` exceeds the last stored value.

**5) No `valid_from_timestamp` enforcement.** Scope does not check if a report has become valid yet, allowing premature report consumption.

The developer's own TODO at line 483 confirms this code was temporary and incomplete:
```rust
// TODO(liviuc): once Chainlink has added the `total_return_price`, use that
```
The field exists now under the name `tokenized_price` in `ReportDataV10`. The TODO was never completed.

---

## Attack Vector 1: Permissionless Crank Selective Report Submission During Stock Split

### The crank is fully permissionless

The `RefreshChainlinkPrice` account struct (`handler_refresh_chainlink_price.rs:23-54`) has a single signer constraint:

```rust
pub struct RefreshChainlinkPrice<'info> {
    pub user: Signer<'info>,  // any keypair
```

That `user` field is only forwarded to the Chainlink verifier CPI. Scope performs **no access control** — no `has_one = admin`, no seeds constraint, no `Configuration` account loaded. Compare with `ResumeChainlinkXPrice` which requires `pub admin: Signer<'info>` with `has_one = admin`.

Additionally, `refresh_chainlink_price` lacks the `check_execution_ctx()` anti-sandwich guard that `refresh_price_list` enforces. This means the oracle update can be sandwiched via CPI in a single atomic transaction.

### The timestamp ordering is exploitable

The timestamp check (`chainlink.rs:164-183`) only requires:

```rust
if observations_ts <= last_observations_ts {
    return Err(ScopeError::BadTimestamp);
}
```

This accepts any report with `observations_timestamp > last_stored_timestamp`. It does **not** enforce that the report is the most recent available, nor does it check `expires_at` or `valid_from_timestamp`. A crank operator can archive multiple valid reports and submit them selectively.

### Attack scenario during a stock split (e.g., Apple 2-for-1)

**Setup — Attacker positions before the split:**

1. Apple announces a 2-for-1 stock split. Chainlink begins embedding `activation_date_time` and `new_multiplier = 2e18` in v10 reports.
2. Attacker deposits AAPLx as collateral on KLend. Borrows maximum USDC against it at oracle price $264.70 x 1.0 = $264.70.

**Phase 1 — Blackout (T-24h to T+0):**

3. When a report with `activation_date_time > 0` arrives and is cranked, `update_price_v10` (line 450) triggers suspension: `suspended = true`. Oracle frozen at $264.70.

**Phase 2 — Admin resumes:**

4. After the split activates, Kamino admin calls `resume_chainlinkx_price`. This sets `suspended = false` and **resets `observations_timestamp` to `clock.unix_timestamp`** (`handler_resume_chainlinkx_price.rs:74-78`). This timestamp reset is critical — it reopens the window for stale reports.

**Phase 3 — Attacker submits stale pre-split report:**

5. The attacker has archived DON-signed reports from before the split. They hold report R_stale with:
   - `observations_timestamp = T_resume + 1s` (passes ordering check)
   - `price = $264.70 * WAD` (pre-split price)
   - `current_multiplier = 1e18` (pre-split multiplier)
   - `activation_date_time = 0` (no pending action — **bypasses ALL suspension logic**)

6. Attacker calls `refresh_chainlink_price` with R_stale:
   - Chainlink verifier accepts it (DON signatures valid, reports don't expire on-chain)
   - `validate_observations_timestamp`: T_resume+1 > T_resume → passes
   - `suspended = false` → passes
   - `activation_date_time = 0` → suspension check at line 444 is **skipped entirely**
   - `price_dec = 264.70e18`, `current_multiplier_dec = 1e18`
   - `multiplied_price = $264.70`

7. **The oracle now shows $264.70 per unit, but the AAPLx token has been rebased 2:1.** Each user now holds 2x the units, each worth $132.35. The oracle prices them at $264.70 — a 2x overvaluation.

8. Attacker borrows additional USDC against inflated collateral value (atomically via CPI since no `check_execution_ctx` guard exists).

9. Correct report eventually submitted → oracle corrects to $132.35 x 2 = $264.70 per original share, but the attacker's rebased position is undercollateralized. Protocol absorbs bad debt.

**Impact calculation for this scenario:**
- Attacker collateral (real): 200 units x $132.35 = $26,470
- Attacker collateral (oracle): 200 units x $264.70 = $52,940
- Max borrow at 35% LTV (oracle): $18,529
- Max borrow at 35% LTV (real): $9,264
- **Bad debt per position: $9,265 (100% of the legitimate borrow)**

Scaled to the xStocks market ($5-20M TVL): **$1.75M-$7M potential bad debt.**

### Alternative: Zero Multiplier During Transition

If during the transition window the DON signs a report with `current_multiplier = 0` (initialization state, race condition, or data feed glitch):

1. Crank submits the zero-multiplier report
2. `$264.70 * 0 = $0` stored as oracle price
3. All AAPLx-collateralized positions become instantly liquidatable at $0 valuation
4. Liquidation bots drain every position in the xStocks market

---

## Attack Vector 2: `activation_date_time = 0` Suspension Bypass

The entire suspension mechanism is gated at `chainlink.rs:444`:

```rust
if chainlink_report.activation_date_time > 0 {
    // ... entire blackout logic (lines 444-471) ...
}
```

When `activation_date_time = 0` — the **normal steady-state value** — the entire block is skipped. This means:

1. A report carrying `activation_date_time = 0` bypasses all suspension logic unconditionally
2. Even if `new_multiplier` wildly differs from `current_multiplier`, no alarm is raised
3. Even if the multiplier is zero, the code falls through to `price * 0 = $0`
4. The `V10_TIME_PERIOD_BEFORE_ACTIVATION_TO_SUSPEND_S` constant (24h) is never evaluated

The `new_multiplier` field is only logged (`chainlink.rs:429-437`, `452-460`) — it is never validated against `current_multiplier`. This is demonstrated in PoC test G.

---

## Attack Vector 3: Missing `tokenized_price` Cross-Reference

Every v10 report contains 13 fields. Scope uses 8 and ignores 5. The most critical ignored field is `tokenized_price` — a separate DON-signed value representing the 24/7 tokenized equity price.

From the Chainlink Rust SDK (`ReportDataV10` struct, `data-streams-sdk/rust/crates/report/src/report/v10.rs`):
```rust
pub tokenized_price: BigInt,    // "24/7 tokenized equity price"
```

If Scope cross-validated `price * current_multiplier` against `tokenized_price` with a reasonable tolerance:
- Zero multiplier: result = $0, tokenized_price = $264.70 → obvious anomaly, reject
- 1000x multiplier: result = $264,700, tokenized_price = $264.70 → obvious anomaly, reject
- Stale pre-split report: result diverges from live tokenized_price → reject

A grep across the entire Scope codebase confirms `tokenized_price` appears **nowhere**. This is confirmed in PoC test E.

### v10 is the only adapter without validation

| Adapter | Confidence Check | Where |
|---|---|---|
| Chainlink v3 | `check_confidence_interval_decimal()` | chainlink.rs:267 |
| Pyth | `check_confidence_interval()` | pyth.rs:110 |
| Pyth Pull | `validate_valid_price` + confidence | pyth_pull.rs:50 |
| Pyth Lazer | `check_confidence_interval()` | pyth_lazer.rs:156 |
| Switchboard | `check_confidence_interval()` | switchboard_on_demand.rs:78 |
| Most Recent Of | `check_confidence_interval_decimal_bps()` | most_recent_of.rs:112 |
| **ChainlinkX v10** | **None** | **chainlink.rs:480-487** |

---

## Attack Vector 4: Missing CPI Protection Enables Atomic Exploitation

`refresh_chainlink_price` lacks the `check_execution_ctx()` guard that `refresh_price_list` enforces. This allows the oracle update to be called via Cross-Program Invocation (CPI) within a single atomic transaction:

```
Attacker's program (single transaction):
  1. CPI -> refresh_chainlink_price(stale_report)  // inflates oracle
  2. CPI -> klend::borrow(max_usdc)                 // borrows at inflated value
  3. (optional) CPI -> refresh_chainlink_price(correct_report) // corrects oracle
  4. Attacker keeps the borrowed USDC
```

The `check_execution_ctx()` guard exists specifically to prevent this pattern. Its absence from the Chainlink path is an oversight — the standard `refresh_price_list` path has it at `handler_refresh_prices.rs:38`.

---

## Impact

### Impact Classification

**Selected in-scope impact: Protocol insolvency (Critical)**

The attack produces protocol insolvency through the following concrete chain:

1. Inflated oracle price (via stale report replay or manipulated multiplier) → KLend accepts overvalued xStocks collateral
2. Attacker borrows against the inflated collateral value (atomically, since no CPI guard)
3. Oracle corrects when legitimate report is submitted
4. Attacker's position is now undercollateralized
5. KLend's xStocks isolated market absorbs the bad debt → **protocol insolvency** of that market

Additionally, the zero-multiplier vector enables **direct theft of user funds** through mass liquidation at $0 valuation, but the primary classification is protocol insolvency.

### Funds at Risk Calculation

| Metric | Value | Source |
|---|---|---|
| Kamino KLend total TVL | ~$2.0B | DeFiLlama, March 2026 |
| xStocks market on KLend (Dec 2025 snapshot) | $3.9M | Kamino 2025 Year-in-Review |
| xStocks market on KLend (est. March 2026) | **$5-20M** | Based on 271.9% 90-day growth rate |
| xStocks ecosystem total (Solana) | ~$196M | CoinGecko, Jan 2026 |
| Max LTV for xStocks on KLend | 35% | Kamino risk parameters |

The xStocks market on KLend is an **isolated lending market** — exposure is ring-fenced from the $2B main pool. The directly at-risk amount is what is deposited in the xStocks isolated market.

**Conservative calculation at $5M TVL:**
- Funds directly at risk = $5M (total xStocks market deposits)
- At 35% LTV: ~$1.75M in borrows that could become bad debt
- This exceeds the $50,000 minimum for Critical per Kamino's rules

**Moderate calculation at $10M TVL:**
- Funds directly at risk = $10M
- At 35% LTV: ~$3.5M potential bad debt

### The 3 completely unprotected entries

Entries #262, #266, and #282 have `ref_price = 0xFFFF`, meaning `check_ref_price_difference` at `handler_refresh_chainlink_price.rs:222-231` is skipped entirely. For these entries, there is literally **zero defense** between the raw report data and KLend reading that price.

The other 10 entries have `ref_price` pointing to Pyth feeds with 5% tolerance (`MAX_REF_RATIO_TOLERANCE_BPS = 500`). This catches extreme values but not moderate manipulation within the 5% band.

### Historical Precedents

| Incident | Date | Loss | Root Cause | Similarity |
|---|---|---|---|---|
| **Moonwell** (Chainlink OEV) | Feb 15, 2026 | **$1.78M** | Used cbETH/ETH ratio without multiplying by ETH/USD | Missing multiplication step in Chainlink oracle — structurally identical class |
| **Loopscale** (Solana) | Apr 26, 2025 | **$5.8M** | Manipulated RateX PT oracle to inflate tokenized asset collateral | Same pattern: inflated oracle → overborrow → bad debt |
| **KiloEx** | Apr 14, 2025 | **$7M** | Oracle access control missing — attacker set arbitrary prices | Permissionless oracle manipulation |

The Moonwell incident is particularly relevant — it was caused by a missing multiplication step in a Chainlink oracle configuration, produced $1.78M in bad debt within minutes, and confirms that this class of vulnerability is actively exploitable in production.

### Chainlink's own documentation confirms the risk window

From Chainlink Data Streams Best Practices (docs.chain.link/data-streams/concepts/best-practices):

On stock splits in v10: The documentation states that corporate actions can produce abrupt per-share price moves and must be handled carefully to avoid incorrect onchain price computations and unexpected liquidations.

On the post-activation window: The documentation warns that computing price x currentMultiplier when the underlying price has not yet adjusted can produce large errors.

On integrator responsibility: The documentation instructs integrators to pause markets before activationDateTime and keep them paused until all post-activation checks are confirmed.

Scope's suspension mechanism at `activation_date_time > 0` is the intended implementation — but it is completely bypassed when `activation_date_time = 0`.

---

## Proof of Concept

### Compliance Note

**No mainnet or testnet testing was performed.** The PoC is a standalone Rust binary that replicates the exact arithmetic from `update_price_v10` using the same crates Scope uses on-chain (`decimal-wad v0.1`, `num-bigint v0.4`). All tests run locally against replicated math — no interaction with any deployed contracts, oracles, or third-party systems. The on-chain evidence section references publicly readable account data only (no transactions submitted).

### How to run

```bash
cd PoC/
cargo test -- --nocapture
```

### Dependencies

- Rust 1.75+
- `decimal-wad v0.1` (same crate used by Scope on-chain; resolves to 0.1.9)
- `num-bigint v0.4` (same crate used by Scope on-chain)

No network access, RPC connections, or external APIs required to run the PoC tests.

### Test Matrix

Each test demonstrates a specific aspect of the vulnerability with clear print statements detailing each step and displaying the resulting oracle prices and funds stolen/at risk:

| Test | What it proves | Impact demonstrated |
|------|---------------|---------------------|
| **PoC A: Zero Multiplier** | `current_multiplier = 0` passes through v10 math. $150 stock → $0 oracle price. | Mass liquidation of all xStocks positions |
| **PoC B: Extreme Multiplier** | `current_multiplier = 1000*WAD` produces $150,000 oracle price. Not rejected. | Borrow against 1000x inflated collateral → protocol insolvency |
| **PoC C: v3 vs v10 Comparison** | Same unreliable price (66.7% spread): v3 REJECTS via confidence check, v10 ACCEPTS. | v10 is the only adapter without confidence validation |
| **PoC D: Bounds Check** | Bounds check `0 < mult <= 10*WAD` correctly handles all cases: accepts 1x, 2x, 4x, 10x splits; rejects 0 and 1000x. | Simple fix catches all attack vectors |
| **PoC E: tokenized_price** | `tokenized_price` cross-reference detects zero mult ($0 vs $150) and extreme mult ($150K vs $150) while accepting normal operation. | Ignored DON-signed field would prevent all attacks |
| **PoC F: Stock Split Replay** | Full end-to-end: pre-split report (activation=0) submitted after admin resume. Oracle shows $150/unit but token rebased to $75/unit. 2x overvaluation. Bad debt calculated with 35% LTV. | Complete attack: $10,500 bad debt per $30,000 position |
| **PoC G: Suspension Bypass** | `activation_date_time=0` bypasses ALL suspension logic, even with wildly different multipliers (10x divergence) or zero multiplier. | Suspension mechanism is dead code in steady state |
| **PoC H: Stale Reports** | Expired report (expires_at 2h ago) accepted. Premature report (valid_from in future) accepted. Post-resume stale replay accepted. | Stale report replay attack enabled by missing checks |
| **Supplementary** | `chainlink_bigint_value_parse(BigInt(0))` returns `Decimal(0)` — confirms parse function accepts zero. | Root cause: no zero check in parse |
| **Integration** | Full attack sequence with real mainnet AAPLx price ($264.70), dollar amounts, LTV calculations, unprotected entries identified. | $1.75M-$7M potential bad debt |

### PoC Test Results (all 10 pass)

```
running 10 tests
test tests::poc_a_zero_multiplier ... ok
test tests::poc_b_extreme_multiplier ... ok
test tests::poc_c_v3_vs_v10_confidence ... ok
test tests::poc_d_bounds_check ... ok
test tests::poc_e_tokenized_price_cross_reference ... ok
test tests::poc_f_stock_split_replay ... ok
test tests::poc_g_suspension_bypass ... ok
test tests::poc_h_stale_reports ... ok
test tests::supplementary_parse_accepts_zero ... ok
test tests::integration_full_attack_aaplx ... ok

test result: ok. 10 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out
```

### End-to-end attack flow

```
Step 1: Attacker subscribes to Chainlink Data Streams, archives DON-signed reports
Step 2: Attacker opens KLend position (deposits AAPLx, borrows USDC at $264.70 valuation)
Step 3: Stock split announced — Chainlink begins embedding activation_date_time
Step 4: Blackout triggers: oracle suspended for 24h
Step 5: Admin resumes oracle — observations_timestamp reset to clock.unix_timestamp
Step 6: Attacker submits archived pre-split report:
   -> observations_timestamp > resume_timestamp (passes ordering)
   -> activation_date_time = 0 (bypasses suspension - Attack Vector 2)
   -> expires_at not checked (stale report accepted - Attack Vector 3)
   -> no check_execution_ctx (can sandwich via CPI - Attack Vector 4)
   -> Old multiplier applied -> oracle price 2x inflated
Step 7: Attacker borrows additional USDC against inflated collateral (atomic via CPI)
Step 8: Correct report eventually submitted -> price corrects
Step 9: Attacker's position undercollateralized -> KLend absorbs bad debt = PROTOCOL INSOLVENCY
```

### On-chain Evidence (read-only, no interaction)

Verified by reading publicly accessible Solana mainnet account data on 2026-03-05. **No transactions were submitted; only public account state was read.**

| Entry | Token | Price | ref_price | Protected? |
|-------|-------|-------|-----------|------------|
| #258 | AAPLx | $264.70 | #26 (Pyth AAPL/USD) | Yes (5%) |
| #260 | HOODx | $75.84 | #94 (Pyth HOOD/USD) | Yes (5%) |
| **#262** | **Unknown** | **$83.48** | **0xFFFF (None)** | **NO** |
| #264 | GOOGLx | $311.97 | #34 (Pyth GOOGL/USD) | Yes (5%) |
| **#266** | **Unknown** | **$648.79** | **0xFFFF (None)** | **NO** |
| #268 | NVDAx | $177.39 | #42 (Pyth NVDA/USD) | Yes (5%) |
| #270 | MSTRx | $129.74 | #72 (Pyth MSTR/USD) | Yes (5%) |
| #272 | TSLAx | $402.42 | #56 (Pyth TSLA/USD) | Yes (5%) |
| #274 | AMZNx | $210.01 | #50 (Pyth AMZN/USD) | Yes (5%) |
| #276 | COINx | $176.00 | #64 (Pyth COIN/USD) | Yes (5%) |
| #278 | Unknown | $688.11 | #284 (Pyth ref) | Yes (5%) |
| #280 | QQQx | $608.08 | #90 (Pyth QQQ/USD) | Yes (5%) |
| **#282** | **Unknown** | **$394.14** | **0xFFFF (None)** | **NO** |

Key accounts:

| Account | Address |
|---------|---------|
| Scope Program | `HFn8GnPADiny6XqUoWE8uRPPxb29ikn4yTuPa9MF2fWJ` |
| OracleMappings | `4zh6bmb77qX2CL7t5AJYCqa6YqFafbz3QJNeFvZjLowg` |
| Chainlink Verifier | `Gt9S41PtjR58CbG9JhJ3J6vxesqrNAswbWYbLNTMZA3c` |

All feed IDs start with `0x000a`, confirming v10 report schema.

---

## Recommendation

### 1. Add multiplier bounds check (Critical — blocks zero and extreme values)

After line 482 in `chainlink.rs`:

```rust
let current_multiplier_dec =
    chainlink_bigint_value_parse(&chainlink_report.current_multiplier)?;

// Reject zero or extreme multipliers
let max_multiplier = Decimal::from(10u64).try_mul(Decimal::from(WAD))?;
if current_multiplier_dec == Decimal::from(0u64) {
    return Err(ScopeError::PriceNotValid.into());
}
if current_multiplier_dec > max_multiplier {
    return Err(ScopeError::PriceNotValid.into());
}
```

### 2. Cross-validate against `tokenized_price` (Critical — catches all anomalies)

```rust
let tokenized_price_dec = chainlink_bigint_value_parse(&chainlink_report.tokenized_price)?;
let computed = price_dec.try_mul(current_multiplier_dec)?;
let diff = if computed > tokenized_price_dec {
    computed.try_sub(tokenized_price_dec)?
} else {
    tokenized_price_dec.try_sub(computed)?
};
let tolerance = tokenized_price_dec.try_div(Decimal::from(20u64))?; // 5%
if diff > tolerance {
    return Err(ScopeError::PriceNotValid.into());
}
```

### 3. Validate `expires_at` and `valid_from_timestamp` (High — blocks replay attack)

```rust
if chainlink_report.valid_from_timestamp as i64 > clock.unix_timestamp {
    return Err(ScopeError::BadTimestamp.into());
}
if chainlink_report.expires_at > 0
    && (chainlink_report.expires_at as i64) < clock.unix_timestamp {
    return Err(ScopeError::BadTimestamp.into());
}
```

### 4. Add confidence interval validation (High — parity with all other adapters)

Bring v10 in line with every other adapter by adding `check_confidence_interval_decimal`. The v3 handler at line 267 shows the exact pattern to follow.

### 5. Add `check_execution_ctx()` to `refresh_chainlink_price` (High — blocks CPI sandwiching)

```rust
// In refresh_chainlink_price handler, before processing:
check_execution_ctx(&ctx)?;
```

### 6. Validate `new_multiplier` divergence when `activation_date_time = 0` (Medium)

If `new_multiplier` significantly diverges from `current_multiplier` but `activation_date_time = 0`, reject the report as inconsistent.

### 7. Set `ref_price` for entries #262, #266, #282 (Medium — adds secondary defense)

Point their `ref_price` to Pyth feeds for the same underlying stock.

---

## References

**Scope source code (in-scope asset):**
- `programs/scope/src/oracles/chainlink.rs:408-504` — `update_price_v10` (vulnerable function)
- `programs/scope/src/oracles/chainlink.rs:267` — `update_price_v3` confidence check (comparison)
- `programs/scope/src/oracles/chainlink.rs:444` — `activation_date_time` suspension gate
- `programs/scope/src/oracles/chainlink.rs:568` — `chainlink_bigint_value_parse` (accepts zero)
- `programs/scope/src/handlers/handler_refresh_chainlink_price.rs:23-27` — permissionless crank
- `programs/scope/src/handlers/handler_refresh_chainlink_price.rs:222-231` — ref_price check
- `programs/scope/src/handlers/handler_resume_chainlinkx_price.rs:15-19` — admin-only resume
- `programs/scope/src/handlers/handler_resume_chainlinkx_price.rs:74-78` — timestamp reset on resume
- `programs/scope/src/utils/price_impl.rs:10` — `MAX_REF_RATIO_TOLERANCE_BPS = 500`
- `programs/scope/src/utils/math.rs:225` — `check_confidence_interval_decimal`

**Downstream impact:**
- `klend/programs/klend/src/utils/prices/scope.rs` — KLend reading Scope oracle prices

**External references:**
- Chainlink Data Streams Best Practices — https://docs.chain.link/data-streams/concepts/best-practices
- Chainlink data-streams-sdk ReportDataV10 — https://github.com/smartcontractkit/data-streams-sdk
- Moonwell MIP-X43 Post-Mortem — https://forum.moonwell.fi/t/mip-x43-cbeth-oracle-incident-summary/2068
- Scope repository — https://github.com/Kamino-Finance/scope
- Kamino Immunefi program — https://immunefi.com/bug-bounty/kamino/
