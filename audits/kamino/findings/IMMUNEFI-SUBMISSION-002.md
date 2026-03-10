# Permissionless Crank Operator Can Exploit Missing Multiplier Validation in ChainlinkX v10 Oracle to Corrupt xStocks Prices on KLend

## Bug Description

The `update_price_v10` function in Scope's Chainlink oracle handler (`chainlink.rs:408-504`) takes a `current_multiplier` value straight from the Chainlink Data Streams v10 report and multiplies it into the oracle price with no bounds checking at all, no confidence interval validation, and no cross reference against the DON signed `tokenized_price` field that sits right there in the same report. The `refresh_chainlink_price` instruction is fully permissionless, anyone can call it with any valid DON signed report, and it is missing the `check_execution_ctx()` anti CPI guard that `refresh_price_list` has. So you can sandwich it in a single atomic transaction.

During a corporate action like a stock split, both pre split and post split DON signed reports are valid at the same time. A crank operator who also holds KLend positions can pick and choose which report to submit and when, taking advantage of the fact that `update_price_v10` does zero validation on the multiplier. Every other oracle adapter in Scope validates its prices. This one does not. On top of that, Scope ignores the report's `expires_at` field (so you can feed it stale reports) and `valid_from_timestamp` (so you can feed it premature reports), which opens up a real replay window.

Three entries (#262, #266, #282) have zero secondary protection. No `ref_price`, no confidence check, nothing between the raw multiplier and KLend's collateral engine. When you combine that with the `activation_date_time = 0` bypass that kills all suspension logic, you get a clear path from permissionless crank submission to **protocol insolvency**.

**Estimated funds at risk**: around $5 to $20M in xStocks collateral on KLend (isolated market). This is well above the $50,000 minimum for Critical severity under Kamino's program rules. Using the 10% of funds at risk formula: $500K to $2M (capped at $1.5M, floored at $150K).

---

## Vulnerability Details

### Target Asset

- **Program**: Kamino's Price Oracle Aggregator (Scope)
- **Repository**: https://github.com/Kamino-Finance/scope
- **Onchain address**: `HFn8GnPADiny6XqUoWE8uRPPxb29ikn4yTuPa9MF2fWJ`
- **File**: `programs/scope/src/oracles/chainlink.rs`
- **Function**: `update_price_v10` (lines 408-504)
- **Version**: v0.32.0, commit `b2c689e`
- **Also affected**: `handler_refresh_chainlink_price.rs` (the permissionless instruction handler)

### Root Cause

Lines 480 through 487. The function grabs the raw price and the `current_multiplier` from the Chainlink report, multiplies them, and stores the result. Nothing else happens. No validation whatsoever:

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
// no cross reference against tokenized_price either
```

There are five validations missing here and each one matters:

**1) No multiplier bounds check.** The `chainlink_bigint_value_parse` function (line 568) does reject negative values and 192 bit overflows, but it happily accepts zero. If `current_multiplier = 0`, you get `price * 0 = $0`. There is also no upper bound at all.

**2) No confidence interval check.** The v3 handler in the same file (line 267) calls `check_confidence_interval_decimal(price_dec, spread, confidence_factor)` to reject sketchy prices. The v10 handler just... does not do this. It is the only oracle adapter in Scope that skips this.

**3) No `tokenized_price` cross reference.** Every single v10 report has a DON signed `tokenized_price` field described as the "24/7 tokenized equity price". Scope never looks at it. If it did, it would immediately catch zero multiplier and extreme multiplier situations.

**4) No `expires_at` enforcement.** Scope completely ignores when the report expires. As long as the `observations_timestamp` is higher than the last stored value, the report goes through. A report that expired hours ago is fine.

**5) No `valid_from_timestamp` enforcement.** Scope does not check whether a report is supposed to be valid yet. You can submit a report before its valid from time.

That TODO comment at line 483 is telling. The developer wrote `// TODO(liviuc): once Chainlink has added the total_return_price, use that`. The field already exists in `ReportDataV10` under the name `tokenized_price`. The TODO was never finished.

---

## Attack Vector 1: Permissionless Crank with Selective Report Submission During Stock Split

### The crank is fully permissionless

Look at the `RefreshChainlinkPrice` account struct (`handler_refresh_chainlink_price.rs:23-54`). It has one signer:

```rust
pub struct RefreshChainlinkPrice<'info> {
    pub user: Signer<'info>,  // any keypair
```

That `user` field just gets forwarded to the Chainlink verifier CPI call. Scope itself does not check who is calling. No `has_one = admin`, no seeds constraint, no `Configuration` account loaded. Compare that with `ResumeChainlinkXPrice` (`handler_resume_chainlinkx_price.rs:15-19`) which requires `pub admin: Signer<'info>` with a `has_one = admin` constraint. The difference is intentional but the implications were not fully thought through.

On top of that, `refresh_chainlink_price` does not call `check_execution_ctx()`. The standard `refresh_price_list` handler does have this guard (at `handler_refresh_prices.rs:38`), and it exists to stop exactly the kind of CPI sandwiching that this opens up.

### The timestamp ordering is weak

The timestamp check at `chainlink.rs:164-183` only requires:

```rust
if observations_ts <= last_observations_ts {
    return Err(ScopeError::BadTimestamp);
}
```

So any report with `observations_timestamp > last_stored_timestamp` gets accepted. It does not force you to submit the most recent report. It does not check `expires_at`. It does not check `valid_from_timestamp`. A crank operator can hold onto multiple valid reports and pick the one that benefits them most.

### Attack scenario: Apple 2 for 1 stock split

**Setup: Attacker gets positioned before the split**

1. Apple announces a 2 for 1 stock split. Chainlink starts putting `activation_date_time` and `new_multiplier = 2e18` in v10 reports.
2. Attacker deposits AAPLx as collateral on KLend. Borrows max USDC against it. Today's live oracle price is $263.17 per AAPLx (verified on chain, entry #258, March 5 2026).

**Phase 1: Blackout kicks in (T minus 24h to T)**

3. When someone cranks a report with `activation_date_time > 0`, the code at line 450 triggers suspension: `suspended = true`. Oracle freezes at $263.17.

**Phase 2: Admin resumes**

4. After the split goes through, Kamino admin calls `resume_chainlinkx_price`. This sets `suspended = false` and resets `observations_timestamp` to `clock.unix_timestamp` (`handler_resume_chainlinkx_price.rs:74-78`). This reset is what makes the replay possible because now stale reports with timestamps after the reset will pass the ordering check.

**Phase 3: Attacker replays a stale pre split report**

5. The attacker has been saving DON signed reports. They have one from before the split with:
   - `observations_timestamp = T_resume + 1s` (passes the ordering check)
   - `price = $263.17 * WAD` (the pre split price)
   - `current_multiplier = 1e18` (the pre split multiplier)
   - `activation_date_time = 0` (no pending action, so it **skips all suspension logic**)

6. Attacker calls `refresh_chainlink_price` with this stale report:
   - Chainlink verifier accepts it because DON signatures are valid and reports do not expire on chain
   - `validate_observations_timestamp`: T_resume+1 > T_resume, passes
   - `suspended = false`, passes
   - `activation_date_time = 0`, so the suspension check at line 444 is completely skipped
   - `price_dec = 263.17e18`, `current_multiplier_dec = 1e18`
   - `multiplied_price = $263.17`

7. **The oracle shows $263.17 per unit, but the AAPLx token has been rebased 2:1.** Users now hold 2x the units, each worth $131.58. The oracle still prices every unit at $263.17. That is a 2x overvaluation.

8. Attacker borrows more USDC against the inflated collateral value. This can be done atomically through CPI because there is no `check_execution_ctx` guard on this handler.

9. Eventually someone submits the correct post split report. Oracle corrects. Attacker's position is now undercollateralized. Protocol takes the bad debt.

**Numbers for this scenario:**
- Attacker collateral (real): 200 units at $131.58 = $26,316
- Attacker collateral (oracle): 200 units at $263.17 = $52,634
- Max borrow at 35% LTV based on oracle: $18,422
- Max borrow at 35% LTV based on real value: $9,211
- **Bad debt created: $9,211 (that is 100% of what the legitimate borrow should have been)**

Scale that to the whole xStocks market ($5 to $20M TVL): **$1.75M to $7M in potential bad debt.**

### The zero multiplier scenario

If the DON signs a report with `current_multiplier = 0` during the transition (initialization state, race condition, data feed glitch, whatever):

1. Someone cranks that report
2. `$263.17 * 0 = $0` gets stored as oracle price
3. Every AAPLx collateralized position is instantly liquidatable at $0 valuation
4. Liquidation bots drain everything

---

## Attack Vector 2: `activation_date_time = 0` Bypass Kills the Suspension

The entire suspension mechanism lives behind one gate at `chainlink.rs:444`:

```rust
if chainlink_report.activation_date_time > 0 {
    // ... entire blackout logic (lines 444-471) ...
}
```

When `activation_date_time = 0`, which is just the normal steady state value when no corporate action is happening, that entire block gets skipped. So:

1. Any report with `activation_date_time = 0` bypasses suspension completely
2. Even if `new_multiplier` is wildly different from `current_multiplier`, nothing catches it
3. Even if the multiplier is literally zero, it falls through to `price * 0 = $0`
4. The 24 hour constant `V10_TIME_PERIOD_BEFORE_ACTIVATION_TO_SUSPEND_S` never gets evaluated

The `new_multiplier` field is only used in log messages (`chainlink.rs:429-437`, `452-460`). It is never compared against `current_multiplier` for any kind of sanity check. PoC test G demonstrates this directly.

---

## Attack Vector 3: Missing `tokenized_price` Cross Reference

Every v10 report has 13 fields. Scope reads 8 and ignores 5. The biggest miss is `tokenized_price`, which is a separate DON signed value that represents the 24/7 tokenized equity price.

From the Chainlink Rust SDK (`ReportDataV10` struct, `data-streams-sdk/rust/crates/report/src/report/v10.rs`):
```rust
pub tokenized_price: BigInt,    // "24/7 tokenized equity price"
```

If Scope compared `price * current_multiplier` against `tokenized_price` with say a 5% tolerance:
- Zero multiplier: computed = $0, tokenized_price = $263.17. Obviously wrong, reject it.
- 1000x multiplier: computed = $263,170, tokenized_price = $263.17. Obviously wrong, reject it.
- Stale pre split report after a split: the computed value would diverge from the live tokenized_price. Reject.

I grepped the entire Scope codebase for `tokenized_price`. Zero matches. Not in the handler, not in any test, not anywhere. PoC test E confirms this.

### v10 is the only adapter without any validation

| Adapter | Confidence Check | Location |
|---|---|---|
| Chainlink v3 | `check_confidence_interval_decimal()` | chainlink.rs:267 |
| Pyth | `check_confidence_interval()` | pyth.rs:110 |
| Pyth Pull | `validate_valid_price` + confidence | pyth_pull.rs:50 |
| Pyth Lazer | `check_confidence_interval()` | pyth_lazer.rs:156 |
| Switchboard | `check_confidence_interval()` | switchboard_on_demand.rs:78 |
| Most Recent Of | `check_confidence_interval_decimal_bps()` | most_recent_of.rs:112 |
| **ChainlinkX v10** | **Nothing** | **chainlink.rs:480-487** |

Every single adapter has some kind of price validation. Except v10.

---

## Attack Vector 4: No CPI Protection Makes It Atomic

`refresh_chainlink_price` does not call `check_execution_ctx()`. The normal `refresh_price_list` handler does call it at `handler_refresh_prices.rs:38`. This means the Chainlink oracle update can be invoked through CPI inside a single atomic transaction:

```
Attacker's program (single transaction):
  1. CPI -> refresh_chainlink_price(stale_report)  // inflate oracle
  2. CPI -> klend::borrow(max_usdc)                 // borrow against inflated value
  3. (optional) CPI -> refresh_chainlink_price(correct_report) // fix oracle
  4. Attacker walks away with the USDC
```

The `check_execution_ctx()` guard was built specifically to stop this pattern. It is just not wired up on the Chainlink path.

---

## Impact

### Impact Classification

**Selected in scope impact: Protocol insolvency (Critical)**

Here is how the attack chain works:

1. Inflated oracle price (from stale report replay or manipulated multiplier) causes KLend to accept overvalued xStocks collateral
2. Attacker borrows against the inflated value (can be done atomically since there is no CPI guard)
3. Oracle corrects when someone submits the right report
4. Attacker's position is now underwater
5. KLend's xStocks isolated market eats the bad debt. That is protocol insolvency for that market.

The zero multiplier vector also enables direct theft of user funds through mass liquidation at $0 valuation, but protocol insolvency is the primary impact.

### Funds at Risk

| Metric | Value | Source |
|---|---|---|
| Kamino KLend total TVL | ~$2.0B | DeFiLlama, March 2026 |
| xStocks market on KLend (Dec 2025) | $3.9M | Kamino 2025 Year in Review |
| xStocks market on KLend (est. March 2026) | **$5 to $20M** | Based on 271.9% 90 day growth rate |
| xStocks ecosystem on Solana | ~$196M | CoinGecko, Jan 2026 |
| Max LTV for xStocks on KLend | 35% | Kamino risk parameters |

The xStocks market on KLend is an isolated lending market. It is ring fenced from the main $2B pool. The amount at risk is specifically what is deposited in the xStocks isolated market.

**At $5M TVL:**
- Funds at risk = $5M
- At 35% LTV: roughly $1.75M in borrows that could go bad
- This is well above the $50,000 minimum for Critical

**At $10M TVL:**
- Funds at risk = $10M
- At 35% LTV: roughly $3.5M in potential bad debt

### The 3 completely unprotected entries

Entries #262, #266, and #282 have `ref_price = 0xFFFF` (verified on chain March 5 2026 by decoding the OracleMappings account at `4zh6bmb77qX2CL7t5AJYCqa6YqFafbz3QJNeFvZjLowg`). When `ref_price` is `0xFFFF`, the `check_ref_price_difference` call at `handler_refresh_chainlink_price.rs:222-231` is skipped entirely. For these three entries, there is literally nothing standing between the raw report data and KLend reading that price.

The other 10 entries point `ref_price` to Pyth feeds with a 5% tolerance (`MAX_REF_RATIO_TOLERANCE_BPS = 500` at `price_impl.rs:10`). That would catch extreme values like $0 or 1000x, but not manipulation within the 5% band.

### Historical Precedents

| Incident | Date | Loss | Root Cause | Relevance |
|---|---|---|---|---|
| **Moonwell** | Feb 15, 2026 | **$1.78M** | Used cbETH/ETH ratio without multiplying by ETH/USD. Missing multiplication step in Chainlink oracle. | Structurally the same class of bug. $1.78M bad debt in minutes. |
| **Loopscale** (Solana) | Apr 26, 2025 | **$5.8M** | Manipulated RateX PT oracle to inflate tokenized asset collateral | Same pattern: inflated oracle, overborrow, bad debt |
| **KiloEx** | Apr 14, 2025 | **$7M** | Oracle access control missing, attacker set arbitrary prices | Permissionless oracle manipulation |

The Moonwell one is especially relevant. It happened on Chainlink infrastructure, involved a missing multiplication step, and created $1.78M in bad debt in minutes. The post mortem is at https://forum.moonwell.fi/t/mip-x43-cbeth-oracle-incident-summary/2068. Same class of vulnerability that we are looking at here.

### Chainlink themselves say this is dangerous

From the Chainlink Data Streams Best Practices documentation (docs.chain.link/data-streams/concepts/best-practices):

They specifically warn that corporate actions can produce abrupt price moves and that computing price times currentMultiplier when the underlying price has not yet adjusted can produce large errors. They tell integrators to pause markets before the activationDateTime and keep them paused until post activation checks pass.

Scope does have a suspension mechanism for this. The problem is that it only runs when `activation_date_time > 0`. When `activation_date_time` is 0, which is the normal value when no corporate action is pending, everything is bypassed.

---

## Proof of Concept

### Compliance Note

**No mainnet or testnet testing was performed.** The PoC is a standalone Rust project that replicates the exact math from `update_price_v10` using the same crates Scope uses on chain (`decimal-wad v0.1`, `num-bigint v0.4`). Everything runs locally. No deployed contracts, oracles, or third party systems are touched. The on chain evidence section only references publicly readable account data and no transactions were submitted.

### How to run

```bash
cd PoC/
cargo test -- --nocapture
```

### Dependencies

- Rust 1.75+
- `decimal-wad v0.1` (same crate Scope uses on chain, resolves to 0.1.9)
- `num-bigint v0.4` (same crate Scope uses)

No network, no RPC, no external APIs needed.

### Test Matrix

10 tests, each one showing a different angle of the vulnerability with print output explaining every step and showing dollar amounts:

| Test | What it shows | Impact |
|------|--------------|--------|
| **PoC A: Zero Multiplier** | `current_multiplier = 0` goes straight through the v10 math. $150 stock becomes $0 in the oracle. | Mass liquidation of all xStocks positions |
| **PoC B: Extreme Multiplier** | `current_multiplier = 1000*WAD` produces a $150,000 oracle price. Not rejected. | Borrow against 1000x inflated collateral, protocol insolvency |
| **PoC C: v3 vs v10** | Same unreliable price (66.7% spread): v3 REJECTS it via confidence check, v10 ACCEPTS it. | v10 is the only adapter without confidence validation |
| **PoC D: Bounds Check** | Shows a simple `0 < mult <= 10*WAD` check correctly catches bad values while allowing legitimate splits (1x, 2x, 4x, 10x). | Simple fix catches all attack vectors |
| **PoC E: tokenized_price** | The ignored `tokenized_price` field would catch zero mult ($0 vs $150) and extreme mult ($150K vs $150) while passing normal operation. | Ignored DON signed field would prevent all attacks |
| **PoC F: Stock Split Replay** | Full end to end attack. Pre split report with activation=0 submitted after admin resume. Oracle says $150 per unit but token rebased to $75 per unit. 2x overvaluation. Bad debt calculated. | Complete attack: $10,500 bad debt per $30,000 position |
| **PoC G: Suspension Bypass** | `activation_date_time=0` bypasses all suspension logic even with 10x multiplier divergence or zero multiplier. | Suspension mechanism is dead code in normal state |
| **PoC H: Stale Reports** | Expired report (expired 2h ago) accepted. Premature report (valid from is in the future) accepted. Post resume stale replay works. | Stale report replay attack is real |
| **Supplementary** | `chainlink_bigint_value_parse(BigInt(0))` returns `Decimal(0)`. Confirms the parse function accepts zero. | Root cause: no zero check in parse |
| **Integration** | Full attack sequence using real mainnet AAPLx price ($263.17), dollar amounts, LTV math, unprotected entries. | $1.75M to $7M potential bad debt |

### Test Results (all 10 pass)

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

### End to end attack flow

```
Step 1: Attacker subscribes to Chainlink Data Streams, archives DON signed reports
Step 2: Attacker opens KLend position (deposits AAPLx, borrows USDC at $263.17 valuation)
Step 3: Stock split announced, Chainlink begins embedding activation_date_time
Step 4: Blackout triggers: oracle suspended for 24h
Step 5: Admin resumes oracle, observations_timestamp reset to clock.unix_timestamp
Step 6: Attacker submits archived pre split report:
   -> observations_timestamp > resume_timestamp (passes ordering)
   -> activation_date_time = 0 (bypasses suspension, Attack Vector 2)
   -> expires_at not checked (stale report accepted, Attack Vector 3)
   -> no check_execution_ctx (can sandwich via CPI, Attack Vector 4)
   -> Old multiplier applied, oracle price 2x inflated
Step 7: Attacker borrows additional USDC against inflated collateral (atomic via CPI)
Step 8: Correct report eventually submitted, price corrects
Step 9: Attacker position undercollateralized, KLend eats the bad debt = PROTOCOL INSOLVENCY
```

### On chain Evidence (read only, no transactions submitted)

All data below was read directly from Solana mainnet on March 5 2026 by decoding the OraclePrices account (`3t4JZcueEzTbVP6kLxXrL3VpWx45jDer4eqysweBchNH`) and OracleMappings account (`4zh6bmb77qX2CL7t5AJYCqa6YqFafbz3QJNeFvZjLowg`). All entries were fresh (updated within seconds of the read). Oracle type for all 13 entries is `37` (ChainlinkX). No transactions were submitted.

| Entry | Token | Live Price | ref_price | Protected? |
|-------|-------|-----------|-----------|------------|
| #258 | AAPLx | $263.17 | #26 (Pyth AAPL/USD) | Yes (5%) |
| #260 | HOODx | $82.25 | #94 (Pyth HOOD/USD) | Yes (5%) |
| **#262** | **Unknown** | **$105.28** | **0xFFFF (None)** | **NO** |
| #264 | GOOGLx | $303.54 | #34 (Pyth GOOGL/USD) | Yes (5%) |
| **#266** | **Unknown** | **$668.41** | **0xFFFF (None)** | **NO** |
| #268 | NVDAx | $183.08 | #42 (Pyth NVDA/USD) | Yes (5%) |
| #270 | MSTRx | $146.37 | #72 (Pyth MSTR/USD) | Yes (5%) |
| #272 | TSLAx | $406.06 | #56 (Pyth TSLA/USD) | Yes (5%) |
| #274 | AMZNx | $216.94 | #50 (Pyth AMZN/USD) | Yes (5%) |
| #276 | COINx | $208.74 | #64 (Pyth COIN/USD) | Yes (5%) |
| #278 | Unknown | $687.34 | #284 (Pyth ref) | Yes (5%) |
| #280 | QQQx | $611.49 | #90 (Pyth QQQ/USD) | Yes (5%) |
| **#282** | **Unknown** | **$406.13** | **0xFFFF (None)** | **NO** |

Key accounts (all verified live on Solana mainnet March 5 2026):

| Account | Address | Verification |
|---------|---------|-------------|
| Scope Program | `HFn8GnPADiny6XqUoWE8uRPPxb29ikn4yTuPa9MF2fWJ` | Executable, matches `program_id.rs` in source |
| OracleMappings | `4zh6bmb77qX2CL7t5AJYCqa6YqFafbz3QJNeFvZjLowg` | 29704 bytes, owned by Scope program |
| OraclePrices | `3t4JZcueEzTbVP6kLxXrL3VpWx45jDer4eqysweBchNH` | 28712 bytes, oracle_mappings field points to account above |
| Chainlink Verifier | `Gt9S41PtjR58CbG9JhJ3J6vxesqrNAswbWYbLNTMZA3c` | Executable, matches `VERIFIER_PROGRAM_ID` in chainlink.rs |

All 13 feed IDs start with `0x000a`, which confirms they use the v10 report schema.

---

## Recommendation

### 1. Add multiplier bounds check (this is the most important one)

After line 482 in `chainlink.rs`, reject zero and extreme multipliers:

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

### 2. Cross validate against `tokenized_price`

This field is right there in every report. Just compare it:

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

### 3. Validate `expires_at` and `valid_from_timestamp`

Stop accepting stale and premature reports:

```rust
if chainlink_report.valid_from_timestamp as i64 > clock.unix_timestamp {
    return Err(ScopeError::BadTimestamp.into());
}
if chainlink_report.expires_at > 0
    && (chainlink_report.expires_at as i64) < clock.unix_timestamp {
    return Err(ScopeError::BadTimestamp.into());
}
```

### 4. Add confidence interval validation

Bring v10 in line with every other adapter. The v3 handler at line 267 already shows exactly how to do `check_confidence_interval_decimal`.

### 5. Add `check_execution_ctx()` to `refresh_chainlink_price`

```rust
// In refresh_chainlink_price handler, before processing:
check_execution_ctx(&ctx)?;
```

### 6. Validate `new_multiplier` divergence when `activation_date_time = 0`

If `new_multiplier` is very different from `current_multiplier` but `activation_date_time` is 0, something is off. Reject the report.

### 7. Set `ref_price` for entries #262, #266, #282

These three entries currently have no backup check at all. Point their `ref_price` to the Pyth feed for the same underlying stock.

---

## References

**Scope source code (in scope asset):**
- `programs/scope/src/oracles/chainlink.rs:408-504` — `update_price_v10` (the vulnerable function)
- `programs/scope/src/oracles/chainlink.rs:267` — `update_price_v3` confidence check (for comparison)
- `programs/scope/src/oracles/chainlink.rs:444` — `activation_date_time` suspension gate
- `programs/scope/src/oracles/chainlink.rs:568` — `chainlink_bigint_value_parse` (accepts zero)
- `programs/scope/src/handlers/handler_refresh_chainlink_price.rs:23-27` — permissionless crank
- `programs/scope/src/handlers/handler_refresh_chainlink_price.rs:222-231` — ref_price check
- `programs/scope/src/handlers/handler_resume_chainlinkx_price.rs:15-19` — admin only resume
- `programs/scope/src/handlers/handler_resume_chainlinkx_price.rs:74-78` — timestamp reset on resume
- `programs/scope/src/utils/price_impl.rs:10` — `MAX_REF_RATIO_TOLERANCE_BPS = 500`
- `programs/scope/src/utils/math.rs:225` — `check_confidence_interval_decimal`

**Downstream:**
- `klend/programs/klend/src/utils/prices/scope.rs` — KLend reading Scope oracle prices

**External:**
- Chainlink Data Streams Best Practices — https://docs.chain.link/data-streams/concepts/best-practices
- Chainlink data-streams-sdk ReportDataV10 — https://github.com/smartcontractkit/data-streams-sdk
- Moonwell MIP-X43 Post Mortem — https://forum.moonwell.fi/t/mip-x43-cbeth-oracle-incident-summary/2068
- Scope repository — https://github.com/Kamino-Finance/scope
- Kamino Immunefi program — https://immunefi.com/bug-bounty/kamino/
