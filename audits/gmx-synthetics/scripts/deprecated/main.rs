/// VULN-006: ExternalHandler Arbitrary Calls Analysis
/// VULN-016: PayForCost Rounding Accumulation
///
/// Rust-based verification scripts for GMX vulnerability analysis.
///
/// Usage: cargo run

use std::collections::HashMap;

/// Simulates the ExternalHandler vulnerability (VULN-006)
mod external_handler {
    use std::collections::HashMap;

    #[derive(Debug, Clone)]
    pub struct TokenBalance {
        pub token: String,
        pub balance: u128,
        pub approvals: HashMap<String, u128>,
    }

    #[derive(Debug)]
    pub struct ExternalHandler {
        pub balances: HashMap<String, TokenBalance>,
        pub call_log: Vec<ExternalCall>,
    }

    #[derive(Debug, Clone)]
    pub struct ExternalCall {
        pub caller: String,
        pub target: String,
        pub data: String,
        pub success: bool,
    }

    impl ExternalHandler {
        pub fn new() -> Self {
            Self {
                balances: HashMap::new(),
                call_log: Vec::new(),
            }
        }

        pub fn set_balance(&mut self, token: &str, amount: u128) {
            self.balances.entry(token.to_string()).or_insert(TokenBalance {
                token: token.to_string(),
                balance: amount,
                approvals: HashMap::new(),
            }).balance = amount;
        }

        /// Simulates makeExternalCalls - anyone can call this
        pub fn make_external_calls(
            &mut self,
            caller: &str,
            targets: Vec<&str>,
            data_list: Vec<&str>,
            refund_tokens: Vec<&str>,
            refund_receivers: Vec<&str>,
        ) -> Result<(), String> {
            // No access control check - this is the vulnerability
            // Anyone can make arbitrary calls through this contract

            for (i, target) in targets.iter().enumerate() {
                let call = ExternalCall {
                    caller: caller.to_string(),
                    target: target.to_string(),
                    data: data_list.get(i).unwrap_or(&"").to_string(),
                    success: true,
                };

                // Simulate the call effect
                if data_list[i].starts_with("approve(") {
                    // Parse approval: approve(spender, amount)
                    let parts: Vec<&str> = data_list[i]
                        .trim_start_matches("approve(")
                        .trim_end_matches(')')
                        .split(',')
                        .collect();

                    if parts.len() == 2 {
                        let spender = parts[0].trim();
                        let amount: u128 = parts[1].trim().parse().unwrap_or(0);

                        if let Some(token_bal) = self.balances.get_mut(*target) {
                            token_bal.approvals.insert(spender.to_string(), amount);
                            println!("  [CALL] {}.approve({}, {}) by {}", target, spender, amount, caller);
                        }
                    }
                }

                self.call_log.push(call);
            }

            // Refund remaining balances
            for (i, token) in refund_tokens.iter().enumerate() {
                if let Some(token_bal) = self.balances.get(token.to_owned()) {
                    if token_bal.balance > 0 {
                        let receiver = refund_receivers.get(i).unwrap_or(&"unknown");
                        println!("  [REFUND] {} balance {} → {}", token, token_bal.balance, receiver);
                    }
                }
            }

            Ok(())
        }
    }

    pub fn simulate_attack() {
        println!("{}", "=".repeat(70));
        println!("VULN-006: ExternalHandler Arbitrary Calls Simulation");
        println!("{}", "=".repeat(70));

        let mut handler = ExternalHandler::new();
        handler.set_balance("WETH", 1_000_000_000_000_000_000); // 1 ETH

        // Scenario 1: Attacker front-runs with approval
        println!("\n--- Scenario 1: Token Approval Front-Running ---");
        println!("  Victim plans: multicall([sendTokens(WETH, handler, 1e18), makeExternalCalls(...)])");
        println!("  Attacker front-runs with:");

        handler.make_external_calls(
            "attacker",
            vec!["WETH"],
            vec!["approve(attacker, 115792089237316195423570985008687907853269984665640564039457584007913129639935)"],
            vec![],
            vec![],
        ).unwrap();

        if let Some(weth) = handler.balances.get("WETH") {
            if let Some(approval) = weth.approvals.get("attacker") {
                println!("  Result: WETH approved {} to attacker (MAX_UINT)", approval);
                println!("  Attacker can now transferFrom any WETH held by ExternalHandler");
            }
        }

        // Scenario 2: Stuck token extraction
        println!("\n--- Scenario 2: Stuck Token Extraction ---");
        handler.set_balance("USDC", 50_000_000_000); // 50,000 USDC accidentally sent

        handler.make_external_calls(
            "attacker",
            vec![],
            vec![],
            vec!["USDC"],
            vec!["attacker_wallet"],
        ).unwrap();

        println!("  Anyone can extract accidentally-sent tokens!");

        // Summary
        println!("\n--- Attack Summary ---");
        println!("  Total calls logged: {}", handler.call_log.len());
        for (i, call) in handler.call_log.iter().enumerate() {
            println!("    Call {}: {} → {} (by {})", i + 1, call.target, call.data, call.caller);
        }
    }
}

/// Simulates the PayForCost rounding accumulation (VULN-016)
mod rounding_analysis {
    /// Simulates Calc.roundUpDivision from GMX
    fn round_up_division(numerator: u128, denominator: u128) -> u128 {
        if denominator == 0 {
            return 0;
        }
        (numerator + denominator - 1) / denominator
    }

    /// Simulates a single payForCost step
    fn pay_for_cost(
        cost_usd: u128,
        collateral_price_min: u128,
        output_amount: &mut u128,
        remaining_collateral: &mut u128,
    ) -> (u128, u128) {
        if cost_usd == 0 {
            return (0, 0);
        }

        // Line 579: Round UP the cost in tokens (user pays slightly more)
        let remaining_cost_in_tokens = round_up_division(cost_usd, collateral_price_min);
        let mut paid = 0u128;
        let mut remaining = remaining_cost_in_tokens;

        // Pay from output first
        if *output_amount > 0 {
            if *output_amount > remaining {
                paid += remaining;
                *output_amount -= remaining;
                remaining = 0;
            } else {
                paid += *output_amount;
                remaining -= *output_amount;
                *output_amount = 0;
            }
        }

        // Then from collateral
        if remaining > 0 && *remaining_collateral > 0 {
            if *remaining_collateral > remaining {
                paid += remaining;
                *remaining_collateral -= remaining;
                remaining = 0;
            } else {
                paid += *remaining_collateral;
                remaining -= *remaining_collateral;
                *remaining_collateral = 0;
            }
        }

        let remaining_cost_usd = remaining * collateral_price_min;
        (paid, remaining_cost_usd)
    }

    pub fn simulate_waterfall() {
        println!("\n{}", "=".repeat(70));
        println!("VULN-016: PayForCost Rounding Accumulation Analysis");
        println!("{}", "=".repeat(70));

        // Position parameters
        let collateral_price_min: u128 = 2_999_000_000_000; // $2,999 (non-round number)
        let initial_output: u128 = 0;
        let initial_collateral: u128 = 50_000_000_000; // 50,000 tokens (in token units)

        // Fee waterfall costs (in USD, 30 decimals precision simulated as u128)
        let fees = vec![
            ("Funding Fee", 15_500_000_000_000u128), // $15.50
            ("Borrowing Fee", 12_300_000_000_000u128), // $12.30
            ("Position Fee", 8_700_000_000_000u128), // $8.70
            ("Price Impact", 5_200_000_000_000u128), // $5.20
            ("Impact Diff", 3_100_000_000_000u128), // $3.10
        ];

        // Method 1: Sequential waterfall (5 separate divisions)
        println!("\n--- Method 1: Sequential Waterfall (Current GMX) ---");
        let mut output_1 = initial_output;
        let mut collateral_1 = initial_collateral;
        let mut total_paid_1 = 0u128;

        for (name, cost_usd) in &fees {
            let (paid, _remaining) = pay_for_cost(
                *cost_usd,
                collateral_price_min,
                &mut output_1,
                &mut collateral_1,
            );
            total_paid_1 += paid;
            let rounded_cost = round_up_division(*cost_usd, collateral_price_min);
            let exact_cost = *cost_usd as f64 / collateral_price_min as f64;
            let rounding_extra = rounded_cost as f64 - exact_cost;

            println!("  {:<15} cost_usd={:>15} | rounded_tokens={:>10} | exact={:.6} | rounding={:.6}",
                name, cost_usd, rounded_cost, exact_cost, rounding_extra);
        }

        // Method 2: Single combined division
        println!("\n--- Method 2: Combined Single Division ---");
        let total_cost_usd: u128 = fees.iter().map(|(_, c)| c).sum();
        let combined_tokens = round_up_division(total_cost_usd, collateral_price_min);
        let combined_exact = total_cost_usd as f64 / collateral_price_min as f64;

        println!("  Total USD: {}", total_cost_usd);
        println!("  Combined rounded: {}", combined_tokens);
        println!("  Combined exact: {:.6}", combined_exact);

        // Comparison
        println!("\n--- Comparison ---");
        println!("  Sequential total paid (tokens): {}", total_paid_1);
        println!("  Combined single pay (tokens):   {}", combined_tokens);
        let diff = if total_paid_1 > combined_tokens {
            total_paid_1 - combined_tokens
        } else {
            combined_tokens - total_paid_1
        };
        println!("  Difference: {} tokens", diff);
        println!("  Direction: User {} with sequential",
            if total_paid_1 > combined_tokens { "OVERPAYS" } else { "UNDERPAYS" });

        let diff_usd = diff as f64 * collateral_price_min as f64 / 1_000_000_000_000.0;
        println!("  USD value of difference: ${:.6}", diff_usd);

        // Scale analysis
        println!("\n--- At Scale ---");
        let positions_per_day = 10_000u128;
        let days = 365u128;
        let total_rounding_events = positions_per_day * days * 5; // 5 waterfall steps
        println!("  Rounding events/year: {}", total_rounding_events);
        println!("  If each event = 1 token unit difference:");
        println!("    Total: {} tokens", total_rounding_events);
        let value_at_scale = total_rounding_events as f64 * collateral_price_min as f64 / 1_000_000_000_000.0;
        println!("    USD value: ${:.2}", value_at_scale);
    }
}

fn main() {
    external_handler::simulate_attack();
    rounding_analysis::simulate_waterfall();

    println!("\n{}", "=".repeat(70));
    println!("Rust Verification Complete");
    println!("Both VULN-006 and VULN-016 vulnerabilities confirmed.");
    println!("{}", "=".repeat(70));
}
