# Kamino Re-Audit: Exploit Pattern Matching

Date: 2026-03-02

---

## Pattern 1 -- Oracle Inconsistency

### 1A. Spot/Manipulable Price Usage in Scope Oracles

**Finding: OrcaWhirlpool, RaydiumAmmV3, and MeteoraDlmm oracles use SPOT pool prices**

- **File:** `/root/defi-audit-targets/audits/kamino/scope/programs/scope/src/oracles/orca_whirlpool.rs` lines 57-59
- **File:** `/root/defi-audit-targets/audits/kamino/scope/programs/scope/src/oracles/raydium_ammv3.rs` lines 15-17
- **File:** `/root/defi-audit-targets/audits/kamino/scope/programs/scope/src/oracles/meteora_dlmm.rs` lines 60-61
- **Function:** `get_price()` in each file

**Analysis:**
- `orca_whirlpool.rs` reads `pool_data.sqrt_price` directly from the Whirlpool state -- this is the **spot pool price**, trivially manipulable via a swap in the same transaction.
- `raydium_ammv3.rs` reads `pool_data.sqrt_price_x64` from the Raydium pool -- also spot price.
- `meteora_dlmm.rs` uses `lb_pair_state.active_id` and `lb_pair_state.bin_step` -- also spot state.

**Defense Check:**
These oracle types (`OrcaWhirlpoolAtoB`, `OrcaWhirlpoolBtoA`, `RaydiumAmmV3AtoB`, `RaydiumAmmV3BtoA`, `MeteoraDlmmAtoB`, `MeteoraDlmmBtoA`) are likely used as reference/informational prices rather than for direct valuation in lending. The `ref_price` mechanism in Scope provides a secondary cross-check, and klend's price staleness mechanism adds another layer. The comments in the OracleType enum also note these are "spot" prices.

**Key question:** Are these oracle types ever configured as the PRIMARY oracle for a klend reserve? If so, a sandwich attack could manipulate the price within a transaction to unfairly liquidate or over-borrow.

However, `refresh_price_list` in `handler_refresh_prices.rs` has a **critical CPI protection** (lines 176-201): it checks `get_stack_height() > TRANSACTION_LEVEL_STACK_HEIGHT` and rejects CPI calls, AND it checks that all preceding instructions are compute budget instructions. This means an attacker cannot sandwich a price refresh within an atomic transaction that also manipulates the pool.

**Rating: Needs More Analysis** -- The CPI protection prevents atomic sandwich of the refresh, but a searcher could still sandwich across two transactions (refresh + exploit) within the same block. The risk depends entirely on whether these spot oracles are used as primary price sources for klend reserves or only as TWAP sources / reference prices.

---

### 1B. kToken Oracle -- Correct Use of Oracle-Derived Prices

**File:** `/root/defi-audit-targets/audits/kamino/scope/programs/scope/src/oracles/ktokens.rs` lines 260-281
**Function:** `holdings()`

**Analysis:**
The kToken oracle is **well-designed** against manipulation:
- Line 262: `pool_sqrt_price = price_utils::sqrt_price_from_scope_prices(price_a, price_b, ...)` -- it derives sqrt_price from Scope oracle prices, NOT from the pool's on-chain sqrt_price.
- Comment on line 42: "When calculating invested amounts, a sqrt price derived from scope price_a and price_b is used to determine the 'correct' ratio of underlying assets, the sqrt price of the pool cannot be considered reliable"
- Line 40: "Reward tokens are excluded from the calculation as they are generally lower value/mcap and can be manipulated"
- The pool account is still loaded (for position liquidity), but its `sqrt_price` is only used in debug mode (lines 283-296).

**Rating: Not Exploitable** -- The kToken oracle correctly avoids pool spot price manipulation by deriving the sqrt_price from external Scope oracle prices.

---

### 1C. Chainlink v10 `current_multiplier` Validation

**File:** `/root/defi-audit-targets/audits/kamino/scope/programs/scope/src/oracles/chainlink.rs` lines 408-504
**Function:** `update_price_v10()`

**Analysis:**
- Line 481-487: `current_multiplier` is parsed via `chainlink_bigint_value_parse()` (which checks for negative values and overflow) and then multiplied into the final price via `price_dec.try_mul(current_multiplier_dec)`.
- The only validation on `current_multiplier` is that it's a non-negative BigInt that fits in 192 bits (line 568-582 in `chainlink_bigint_value_parse`).
- There is NO validation that `current_multiplier` is within a reasonable range (e.g., between 0.5x and 2x). If Chainlink sends a report with an erroneous multiplier (e.g., 0 or 1000), it would be applied directly.
- The `validate_mapping_v8_v10` function (line 530-551) only validates the `MarketStatusBehavior` generic data, not the multiplier.

**However:** The multiplier comes from a Chainlink-verified report (the `invoke` call verifies the report signature at line 79-87 of `handler_refresh_chainlink_price.rs`). Chainlink's DON would need to be compromised to send a bad multiplier. The `ref_price` cross-check mechanism (lines 222-231 in the handler) provides additional protection if configured.

**Attack path:** If `current_multiplier` could be zero (BigInt `0`), the final price would be 0. But the `get_non_zero_price` function in `mod.rs` line 468 rejects zero prices: `if price.price.value == 0 && price_type != OracleType::FixedPrice`.

Wait -- Chainlink types DON'T go through `get_non_zero_price`. They're updated via `handler_refresh_chainlink_price.rs` directly. So a zero-multiplier report WOULD set the price to 0. But the `validate_observations_timestamp` check ensures reports must be newer than the last one, so an attacker can't replay old reports.

The real protection: the multiplier is part of the Chainlink DON-signed report. If the DON signs a zero multiplier, that's a Chainlink-level failure, not a Scope-level vulnerability.

**Rating: Not Exploitable** -- The multiplier is cryptographically verified by the Chainlink DON. Scope correctly applies it but cannot independently validate the economic reasonableness of a DON-signed value.

---

### 1D. Missing Validation in Oracle Adapters

**Analysis of validation consistency across adapters:**
- **Pyth/PythPull/PythPullEMA:** Confidence interval check (ORACLE_CONFIDENCE_FACTOR), staleness check, positive price check, exponent validation.
- **SwitchboardOnDemand:** Confidence interval check (via std_dev), staleness check via slot.
- **Chainlink v3:** Confidence interval check (bid/ask spread), observations_timestamp monotonicity, feed_id match.
- **Chainlink v8 (RWA):** Market status validation, observations_timestamp, feed_id match. **No confidence/spread check** (unlike v3).
- **Chainlink v7 (ExchangeRate):** Only feed_id and observations_timestamp. **No confidence check, no market status check.**
- **Chainlink v9 (NAV):** ripcord flag check, nav_date staleness, feed_id, observations_timestamp. **No confidence check.**
- **Chainlink v10 (xStocks):** Market status, suspension logic, feed_id, observations_timestamp. **No confidence check.**

**Finding: Inconsistent confidence/spread validation across Chainlink oracle versions.**

Chainlink v3 has a `confidence_factor` check via bid/ask spread. Chainlink v7, v8, v9, v10 do NOT have equivalent spread validation. This is likely intentional since v7-v10 serve different data types (exchange rates, NAV, RWA prices, xStocks) where bid/ask spread may not apply.

**Rating: Not Exploitable** -- The different validation levels reflect the different data characteristics of each oracle type.

---

## Pattern 2 -- Missing Health Check

### 2A. `socialize_loss` -- Admin-Only, Requires Full Liquidation First

**File:** `/root/defi-audit-targets/audits/kamino/klend/programs/klend/src/lending_market/lending_operations.rs` lines 1810-1890
**File:** `/root/defi-audit-targets/audits/kamino/klend/programs/klend/src/handlers/handler_socialize_loss.rs` lines 87-89

**Analysis:**
- `socialize_loss` is gated by `lending_market_owner` (line 89 of handler) -- admin only.
- Line 1843: `if !obligation.is_active_deposits_empty() { return Err(CannotSocializeObligationWithCollateral) }` -- requires ALL collateral to have been liquidated first.
- Line 1821-1830: Reserve must be fresh.
- Line 1832-1841: Obligation must be fresh.
- No health check needed because deposits are already empty (fully liquidated).

**Rating: Not Exploitable** -- Admin-only, pre-conditions prevent abuse.

### 2B. All Borrow/Withdraw Operations Have Health Checks

**Borrow (`borrow_obligation_liquidity`):** Line 238: `check_obligation_fully_refreshed_and_not_null`. Line 367: `post_borrow_obligation_invariants` -- verifies the obligation remains within limits.

**Withdraw (`withdraw_obligation_collateral`):** Line 555-563: `max_withdraw_value` computation ensures withdrawal doesn't violate LTV.

**Flash Borrow/Repay:** CPI-protected (lines 28-31 of flash_ixs.rs), must have matching repay in same transaction. No obligation involvement -- just reserve-level accounting.

**Rating: Not Exploitable** -- All user-facing operations that change obligation health have proper health checks.

---

## Pattern 6 -- Self-Liquidation Discount

### 6A. `max_allowed_ltv_override` -- Staging-Only Check

**File:** `/root/defi-audit-targets/audits/kamino/klend/programs/klend/src/handlers/handler_liquidate_obligation_and_redeem_reserve_collateral.rs` lines 112-122

**Analysis:**
```rust
let max_allowed_ltv_override_pct_opt =
    if accounts.liquidator.key() == obligation.owner && max_allowed_ltv_override_percent > 0 {
        if cfg!(feature = "staging") {
            Some(max_allowed_ltv_override_percent)
        } else {
            msg!("Warning! Attempting to set an ltv override outside the staging program");
            None
        }
    } else {
        None
    };
```

- `cfg!(feature = "staging")` is a **compile-time check**, not a runtime check. On mainnet builds, the `staging` feature is not enabled, so `max_allowed_ltv_override_pct_opt` will ALWAYS be `None` for self-liquidation attempts on production.
- The `else` branch (non-staging) explicitly sets it to `None` and logs a warning.

**Attack Path Analysis:**
Without the LTV override, can a user self-liquidate profitably?
1. The user's obligation must be unhealthy (LTV > liquidation threshold) per `check_liquidate_obligation` in `liquidation_operations.rs` line 272.
2. Making a position unhealthy requires either price movement or depositing into a position that's already borderline.
3. On mainnet, `max_allowed_ltv_override_pct_opt` is always `None`, so the actual `max_allowed_ltv` comes from `obligation.unhealthy_loan_to_value()`.
4. A user could atomically: (a) borrow to the max LTV, (b) then immediately try to liquidate. But the obligation must be refreshed, and borrowing doesn't push past the max LTV (it's bounded by `remaining_borrow_value`).

The self-liquidation scenario requires the position to ALREADY be unhealthy, which means the user would have lost value. The liquidation bonus would partially offset this loss but wouldn't create profit from a healthy position.

**Rating: Not Exploitable** -- The `cfg!(feature = "staging")` is a compile-time gate that correctly prevents the override on mainnet. Self-liquidation of an already unhealthy position does extract a bonus, but the user has already suffered the underlying loss.

---

## Pattern 9 -- Donation Attack on kvault

### 9A. kvault Share Price -- Internal State vs Token Account Balances

**File:** `/root/defi-audit-targets/audits/kamino/kvault/programs/kvault/src/operations/vault_operations.rs`

**Analysis:**
- `vault.token_available` (line 762) is an **internal accounting variable**, not derived from token account balance.
- `deposit_into_vault` (line 766) and `withdraw_from_vault` (line 770) modify `vault.token_available` directly.
- `amounts_invested` (line 669) reads `allocation_state.ctoken_allocation` (internal state) and computes liquidity via `reserve.collateral_exchange_rate()`.
- `holdings` (line 731) = `available (internal) + invested (internal * exchange_rate)`.
- `get_shares_to_mint` (line 650-667): `shares = shares_issued * user_amount / holdings_aum_ceil` -- uses internal state.

**Key question:** Can someone directly transfer tokens to the `token_vault` SPL account to inflate the share price?

Looking at the deposit handler (lines 72-82 in `handler_deposit.rs`):
- Line 96-102: Post-checks verify `token_to_deposit + crank_funds_to_deposit <= max_amount`.
- Line 109-113: `user_intial_ata_balance - token_to_deposit - crank_funds_to_deposit == user_ata_balance_after` -- verifies exact user balance change.

The vault's share price depends on `vault.token_available` (internal counter) + invested amounts (internal ctoken_allocation * exchange_rate). **Directly donating tokens to the token_vault SPL account would NOT affect the share price** because the vault reads `vault.token_available` (internal state), not the token account balance.

**However:** The `invest` function at line 54 of `handler_invest.rs` reads the actual `token_vault` balance for pre/post checks:
```rust
let token_vault_before = amount(&ctx.accounts.token_vault.to_account_info())?;
```
But this is only used for the `post_transfer_invest_checks` verification, not for share price computation.

**Rating: Not Exploitable** -- kvault correctly uses internal state (`vault.token_available`, `vault.ctoken_allocation`) for all share price calculations. Direct token donations to the SPL token account are ignored in accounting.

### 9B. Invest Function -- klend Exchange Rate Influence

**File:** `/root/defi-audit-targets/audits/kamino/kvault/programs/kvault/src/operations/vault_operations.rs` lines 436-568

**Analysis:**
The `invest` function reads `reserve.collateral_exchange_rate()` to convert between liquidity and collateral amounts. The exchange rate comes from the klend reserve's internal state:
- `reserve.liquidity.total_supply()` and `reserve.collateral.mint_total_supply`
- This rate could theoretically be influenced by depositing/withdrawing large amounts from the klend reserve.

**Attack Path:**
1. Flash borrow a large amount of the underlying token.
2. Deposit into the klend reserve to inflate the exchange rate (more liquidity, same collateral supply).
3. Call `invest` on the kvault -- the inflated exchange rate would make the vault's invested amounts appear larger.
4. Withdraw from kvault at the inflated price.
5. Flash repay.

**Defense Checks:**
- `invest` is a **permissionless crank** function. The payer is `pub payer: Signer<'info>` (line 194), not the vault owner.
- Before invest, ALL reserves are refreshed via `klend_operations::cpi_refresh_reserves` (line 44).
- After invest, `post_transfer_invest_checks` verifies `final_holdings_total >= initial_holdings_total` (line 199-203) and `aum_after_transfers >= aum_before_transfers` (line 209-213).
- The invest function computes holdings BEFORE and AFTER, so any manipulation would need to persist across both reads.
- Flash loans on klend have CPI protection -- you can't flash borrow and then call invest in the same CPI chain.

**The key protection is:** klend flash borrows/repays check for CPI (`is_flash_forbidden_cpi_call`) and the kvault invest calls klend via CPI. So a flash loan -> invest attack would need to be done in separate top-level instructions within the same transaction. But the flash borrow/repay matching check (flash_ixs.rs lines 109-143) requires the repay to be a later instruction, and the invest would be between borrow and repay. The klend `deposit_reserve_liquidity` call inside invest would FAIL because the flash-borrowed liquidity hasn't been repaid yet (reserve accounting would be off).

Actually, looking more carefully: the attacker doesn't need to flash borrow from the SAME reserve. They could flash borrow from reserve A, deposit into reserve B (the one kvault invests in), inflate the exchange rate, then call invest. But the `post_transfer_invest_checks` at lines 199-213 verify that `final_holdings_total >= initial_holdings_total`, which would catch any attempt to extract value.

**Rating: Not Exploitable** -- Multiple defense layers: CPI protection on flash borrows, pre/post holding checks, and reserve refresh requirements prevent exchange rate manipulation attacks.

---

## Pattern 10 -- Cross-Protocol Interaction Shadow

### 10A. kvault -> klend CPI: State Change Between Read and Write

**File:** `/root/defi-audit-targets/audits/kamino/kvault/programs/kvault/src/handlers/handler_invest.rs`

**Analysis:**
The invest handler:
1. Refreshes all reserves (line 44).
2. Reads holdings/AUM (lines 73, 77).
3. Performs deposit/redeem CPI to klend (lines 128-143).
4. Refreshes all reserves again (line 146).
5. Reads holdings/AUM again (lines 154-156).
6. Verifies AUM didn't decrease (post_transfer_invest_checks).

**Between step 2 and step 3:** No external state can change because we're in a single instruction execution. Solana's execution model is single-threaded per instruction -- no concurrent state modifications.

**Between steps 3 and 4:** The klend CPI changes the reserve state (exchange rate, liquidity amounts). Step 4 refreshes to capture these changes. Step 5 reads the updated state.

**Key insight:** Solana's transaction model ensures atomicity within a single instruction. The kvault handler is a single instruction, so no interleaving is possible. The re-read after CPI correctly captures the updated state.

**Rating: Not Exploitable** -- Solana's single-threaded execution model prevents TOCTOU within a single instruction.

### 10B. kfarms Delegated Farms -- klend State Change Exploitation

**File:** `/root/defi-audit-targets/audits/kamino/kfarms/programs/kfarms/src/handlers/handler_set_stake_delegated.rs`

**Analysis:**
- `set_stake_delegated` requires `delegate_authority` or `second_delegated_authority` to sign (line 17-19).
- klend is the delegate authority for its farms.
- klend calls `set_stake_delegated` via CPI when obligations change.
- The stake amount is set to the obligation's deposited or borrowed amount.

**Attack path:** Could an attacker manipulate their obligation state between klend's farm refresh and the actual lending operation?

No -- klend's `refresh_farms!` macro is called AFTER the lending operation completes. The farm state is updated to reflect the final obligation state. There's no window where the farm state is stale relative to the obligation.

**Rating: Not Exploitable** -- Farm updates happen after obligation state changes, maintaining consistency.

### 10C. Circular Dependency: Scope -> klend -> kvault

**Analysis:**
- Scope prices feed into klend (via `refresh_reserve` which reads Scope oracle).
- klend exchange rates feed into kvault (via `collateral_exchange_rate()`).
- Scope's kToken oracle reads kvault strategy data (but kvault is a different product from kTokens -- kTokens are Kamino liquidity vaults for CLMM positions, while kvault is a lending vault).

**Can a circular dependency be exploited?**
- Scope reads external oracle data (Pyth, Chainlink, pool prices).
- klend reads Scope prices for reserve valuation.
- kvault reads klend exchange rates for investment valuation.
- Scope's kToken oracle reads Scope prices (for token A/B) and strategy state (for holdings).

The chain is: External oracle -> Scope -> klend -> kvault. There's no feedback loop where kvault influences Scope prices that then influence klend that then influences kvault. The kToken oracle is for Kamino CLMM vaults, not kvault.

**Rating: Not Exploitable** -- No circular dependency exists. The data flow is one-directional.

---

## Pattern 11 -- Permissionless Crank

### 11A. Scope Instruction Permission Analysis

| Instruction | Permissioned? | Caller Controls |
|---|---|---|
| `refresh_price_list` | Permissionless (any signer) | Token indices to refresh, oracle accounts |
| `refresh_chainlink_price` | Permissionless (any signer) | Token index, serialized report |
| `refresh_pyth_lazer_price` | Permissionless (any signer) | Token indices, serialized message |
| `reset_twap` | Admin only | Token index |
| `resume_chainlinkx_price` | Admin only | Token index |
| `update_mapping_and_metadata` | Admin only | All mapping config |
| `initialize` | Admin only | Initial config |
| `set_admin_cached` | Admin only | New admin |
| `approve_admin_cached` | Cached admin only | N/A |

### 11B. `refresh_price_list` -- CPI Protection Analysis

**File:** `/root/defi-audit-targets/audits/kamino/scope/programs/scope/src/handlers/handler_refresh_prices.rs` lines 176-201

**Defense:** `check_execution_ctx` performs two critical checks:
1. `crate::ID != current_ix.program_id` -> ensures it's not called via CPI from another program.
2. `get_stack_height() > TRANSACTION_LEVEL_STACK_HEIGHT` -> ensures stack height is at the transaction level.
3. All preceding instructions must be `ComputeBudget` instructions.

This means `refresh_price_list` **cannot** be sandwiched with other instructions in the same transaction (except compute budget). An attacker cannot atomically: manipulate pool -> refresh price -> exploit.

**However:** An attacker CAN submit a transaction with: [ComputeBudget, refresh_price_list] in one transaction, then in a separate transaction in the same block: [exploit_instruction]. If the attacker is a validator or has MEV capabilities, they could order these transactions.

### 11C. `refresh_chainlink_price` -- NO CPI Protection

**File:** `/root/defi-audit-targets/audits/kamino/scope/programs/scope/src/handlers/handler_refresh_chainlink_price.rs`

**Critical Finding:** `refresh_chainlink_price` does NOT call `check_execution_ctx()`. It only requires `pub user: Signer<'info>` (line 26).

**Analysis:**
- The report must be verified by the Chainlink verifier program (lines 79-87). The caller cannot forge a report.
- The caller can choose WHICH token index to update (line 58: `token: u16`).
- The caller provides the serialized report (`serialized_chainlink_report: Vec<u8>`).
- The report must be newer than the last one (line 174: `observations_ts <= last_observations_ts` rejects stale reports).

**Can this be called via CPI?** Yes -- there's no `check_execution_ctx` call. A malicious program could:
1. CPI into Scope's `refresh_chainlink_price` with a valid but stale report.
2. In the same CPI chain, exploit the temporarily outdated price.

**Wait** -- the `validate_observations_timestamp` check (line 174) requires the new report's timestamp to be STRICTLY greater than the stored one. So an attacker can only submit a NEWER report, not replay an old one. This means:
- The attacker can push a legitimate newer price update.
- If the newer price is less favorable, the attacker front-runs by updating the price before their exploit.
- But the price must be a valid Chainlink-signed report.

**The real risk:** A Chainlink price update could be applied in the same atomic transaction as a klend operation, because there's no CPI prevention. But the Chainlink report is cryptographically signed, so the attacker can't forge a price. They can only TIME when a valid report is applied.

**Rating: Needs More Analysis** -- The lack of CPI protection on `refresh_chainlink_price` means it can be composed atomically with other operations. However, since the report must be Chainlink-signed and newer than the last, the practical attack surface is limited to strategic timing of legitimate price updates. This is a design choice (Chainlink reports are inherently trusted), but it's inconsistent with `refresh_price_list`'s CPI protection.

### 11D. `refresh_pyth_lazer_price` -- NO CPI Protection

**File:** `/root/defi-audit-targets/audits/kamino/scope/programs/scope/src/handlers/handler_refresh_pyth_lazer_price.rs`

Same pattern as Chainlink -- no `check_execution_ctx`. The Pyth Lazer message must be verified by the Pyth Lazer program (line 64-75). Same risk profile as 11C.

**Rating: Needs More Analysis** -- Same assessment as 11C.

---

## Pattern 12 -- Corporate Action Window (Chainlink v10)

### 12A. `activation_date_time = 0` Behavior

**File:** `/root/defi-audit-targets/audits/kamino/scope/programs/scope/src/oracles/chainlink.rs` lines 442-471

**Analysis:**
```rust
if chainlink_report.activation_date_time > 0 {
    let activation_time_i64 = i64::from(chainlink_report.activation_date_time);
    let activation_time_lower_bound = activation_time_i64
        .checked_sub(V10_TIME_PERIOD_BEFORE_ACTIVATION_TO_SUSPEND_S)
        .ok_or(ScopeError::BadTimestamp)?;

    if clock.unix_timestamp >= activation_time_lower_bound {
        // Suspend the price
        ...
        return Ok(PriceUpdateResult::SuspendExistingPrice);
    }
}
```

When `activation_date_time = 0`:
- The condition `chainlink_report.activation_date_time > 0` evaluates to `false`.
- The entire suspension block is **skipped**.
- The price update proceeds normally (lines 473-503).
- This is the correct behavior: `activation_date_time = 0` means no upcoming corporate action.

**Rating: Not Exploitable** -- `activation_date_time = 0` correctly indicates "no corporate action" and skips the suspension logic.

### 12B. Pre-Split and Post-Split Report Coexistence

**File:** `/root/defi-audit-targets/audits/kamino/scope/programs/scope/src/oracles/chainlink.rs` lines 408-504

**Analysis of the transition period:**
1. **Before blackout (24h before activation):** Normal reports with `current_multiplier = pre_split_multiplier` are accepted. `activation_date_time > 0` but `clock.unix_timestamp < activation_time_lower_bound`.

2. **During blackout (24h before activation until admin resume):**
   - First report entering the blackout: Sets `suspended = true` in `generic_data` (line 463-468), returns `SuspendExistingPrice`.
   - Subsequent reports while suspended: Rejected at line 427-439 (`existing_price_data.suspended` is true).
   - The price is FROZEN at the last valid pre-blackout price.

3. **After admin resume (`resume_chainlinkx_price`):**
   - Admin sets `suspended = false` (line 71 of `handler_resume_chainlinkx_price.rs`).
   - Sets `observations_timestamp` to current time (line 75-78), so only NEW reports are accepted.
   - New reports will have `current_multiplier = post_split_multiplier`.

**Can pre-split and post-split reports coexist?**
- `validate_observations_timestamp` (line 174) requires `observations_ts > last_observations_ts`.
- After resume, `observations_timestamp` is set to the current clock time.
- Only reports with a NEWER timestamp than the resume time will be accepted.
- If a post-split report was generated before the resume (but after the activation), it would have `observations_ts > last_observations_ts` (which was set to current time at resume). Whether this is true depends on the exact timing.

**Edge case:** If the admin resumes very quickly after the activation (e.g., activation happens at T, admin resumes at T+1s), and there are reports from between T and T+1s that use the NEW multiplier, those reports would be accepted because their `observations_ts` is between the activation time and the resume time... but wait, during suspension ALL reports are rejected (line 427-439). So no reports from during the suspension are accepted. After resume, `observations_timestamp` is set to `Clock::get()?.unix_timestamp`, and only reports newer than that are accepted. So post-split reports generated before the resume time would be rejected.

**Rating: Not Exploitable** -- The suspension mechanism cleanly prevents any report processing during the transition. After admin resume, the timestamp gate ensures only genuinely new reports are accepted.

---

## Summary of Findings

| # | Pattern | Finding | Rating |
|---|---|---|---|
| 1A | Oracle Inconsistency | Orca/Raydium/Meteora oracles use spot prices | Needs More Analysis |
| 1B | Oracle Inconsistency | kToken oracle uses oracle-derived prices | Not Exploitable |
| 1C | Oracle Inconsistency | Chainlink v10 multiplier validation | Not Exploitable |
| 1D | Oracle Inconsistency | Inconsistent confidence checks across CL versions | Not Exploitable |
| 2A | Missing Health Check | socialize_loss admin-only, requires empty deposits | Not Exploitable |
| 2B | Missing Health Check | All borrow/withdraw have health checks | Not Exploitable |
| 6A | Self-Liquidation | LTV override is staging-only (compile-time gate) | Not Exploitable |
| 9A | Donation Attack | kvault uses internal state, not token balances | Not Exploitable |
| 9B | Donation Attack | invest function exchange rate manipulation | Not Exploitable |
| 10A | Cross-Protocol | kvault->klend CPI state consistency | Not Exploitable |
| 10B | Cross-Protocol | kfarms delegated farms timing | Not Exploitable |
| 10C | Cross-Protocol | Circular dependency Scope->klend->kvault | Not Exploitable |
| 11A | Permissionless Crank | refresh_price_list has strong CPI protection | Not Exploitable |
| 11B | Permissionless Crank | refresh_price_list CPI + preceding-ix checks | Not Exploitable |
| 11C | Permissionless Crank | **refresh_chainlink_price has NO CPI protection** | Needs More Analysis |
| 11D | Permissionless Crank | **refresh_pyth_lazer_price has NO CPI protection** | Needs More Analysis |
| 12A | Corporate Action | activation_date_time=0 correctly skips suspension | Not Exploitable |
| 12B | Corporate Action | Pre/post split report coexistence prevented | Not Exploitable |

---

## Items Requiring Further Investigation

### HIGH PRIORITY: Spot Price Oracle Usage (1A)
Need to determine if `OrcaWhirlpoolAtoB/BtoA`, `RaydiumAmmV3AtoB/BtoA`, or `MeteoraDlmmAtoB/BtoA` oracle types are configured as primary price sources for any klend reserve on mainnet. If they are, the price can be manipulated across transactions within the same block (the CPI protection prevents intra-transaction manipulation but not cross-transaction within a block).

### MEDIUM PRIORITY: Missing CPI Protection on Chainlink/PythLazer Handlers (11C, 11D)
The `refresh_chainlink_price` and `refresh_pyth_lazer_price` handlers lack the `check_execution_ctx` CPI protection that `refresh_price_list` has. While the reports are cryptographically signed (preventing forgery), the lack of CPI protection allows these price updates to be composed atomically with other on-chain operations via CPI. This is an inconsistency in the security model.

The practical impact is limited because:
1. Reports are signed by the oracle DON.
2. Reports must be newer than the last stored one.
3. klend has its own staleness and price status checks.

But the inconsistency deserves attention -- if the design intent is to prevent atomic composition of price updates with exploits, it should be applied uniformly.

---

## Defensive Patterns Observed

1. **Internal accounting isolation (kvault):** Share prices derived from internal counters, not token account balances.
2. **Oracle-derived sqrt_price (kToken):** Uses Scope prices instead of manipulable pool sqrt_price.
3. **CPI protection (refresh_price_list):** Stack height + program ID + preceding-ix checks.
4. **Compile-time feature gates (klend staging):** `cfg!(feature = "staging")` prevents test-only features on mainnet.
5. **Post-transfer invariant checks (kvault invest):** AUM must not decrease after invest operations.
6. **Monotonic timestamp enforcement (Chainlink):** Reports must have strictly increasing timestamps.
7. **Admin-gated suspension resume (ChainlinkX):** Corporate action handling requires admin intervention.
8. **Reference price cross-checks (Scope):** `ref_price` and `ref_price_tolerance_bps` provide secondary validation.
