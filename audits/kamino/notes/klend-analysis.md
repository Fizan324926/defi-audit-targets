# Kamino klend Security Audit Analysis

## Codebase Overview

- **Program:** Kamino Lending (klend)
- **Program IDs:** `KLend2g3cP87fffoy8q1mQqGKjrxjC8boSyAYavgmjD` (mainnet), `SLendK7ySfcEzyaFqy93gDnD3RtrpXJcnRwb6zFHJSh` (staging)
- **Architecture:** Anchor-based Solana program with AccountLoader (zero-copy) for Reserve, Obligation, LendingMarket
- **Math Library:** Fixed-point U68F60 (128-bit unsigned fixed-point with 60 fractional bits) as `Fraction`, plus U256-based `BigFraction` for cumulative borrow rates
- **Auditors (per security.txt):** OtterSec, Offside Labs, Certora, Sec3
- **Key Source Files:**
  - `/root/defi-audit-targets/audits/kamino/klend/programs/klend/src/lib.rs` -- instruction entrypoints
  - `/root/defi-audit-targets/audits/kamino/klend/programs/klend/src/state/reserve.rs` -- Reserve state, collateral exchange rate, fee calculation, compound interest
  - `/root/defi-audit-targets/audits/kamino/klend/programs/klend/src/state/obligation.rs` -- Obligation state, borrow/deposit tracking
  - `/root/defi-audit-targets/audits/kamino/klend/programs/klend/src/state/liquidation_operations.rs` -- Liquidation bonus calculation, liquidation eligibility checks
  - `/root/defi-audit-targets/audits/kamino/klend/programs/klend/src/lending_market/lending_operations.rs` -- Core business logic for all operations
  - `/root/defi-audit-targets/audits/kamino/klend/programs/klend/src/lending_market/flash_ixs.rs` -- Flash loan borrow/repay validation
  - `/root/defi-audit-targets/audits/kamino/klend/programs/klend/src/lending_market/lending_checks.rs` -- Pre/post-transfer invariant checks
  - `/root/defi-audit-targets/audits/kamino/klend/programs/klend/src/utils/fraction.rs` -- Fixed-point math types

---

## Attack Surface Analysis

### 1. Liquidation Logic

**Hypothesis 1.1: Liquidation bonus + protocol fee can exceed 100%, causing drain**

Analysis: The liquidation bonus is calculated in `calculate_liquidation_bonus()` (liquidation_operations.rs:401). Key defensive mechanism:

```rust
// Line 460-462
let diff_to_bad_debt = bad_debt_ltv - user_no_bf_ltv; // bad_debt_ltv = Fraction::ONE
min(collared_bonus, diff_to_bad_debt)
```

The bonus is **always** capped at `1 - user_no_bf_ltv` (i.e., the gap to insolvency). When `user_no_bf_ltv >= 0.99`, it enters a special bad-debt path that similarly caps via `max(liquidation_bonus_bad_debt, diff_to_bad_debt)`.

The protocol liquidation fee (`calculate_protocol_liquidation_fee`, line 946) takes a percentage of the **bonus portion only**, not the total amount:
```rust
let bonus = amount_liquidated - (amount_liquidated / bonus_multiplier);
let protocol_fee = bonus * protocol_fee_rate;
```

Even at 100% protocol_liquidation_fee_pct, the protocol fee cannot exceed the bonus. The bonus itself is bounded by `diff_to_bad_debt`. Total withdrawals (amount + bonus) are further capped by collateral value in `calculate_liquidation_amounts()`.

**Verdict: NOT EXPLOITABLE.** The diff_to_bad_debt cap is a strong invariant. The protocol fee is a fraction of the bonus, not of the principal.

**Hypothesis 1.2: Profitable self-liquidation**

The `max_allowed_ltv_override_percent` parameter allows self-liquidation:
```rust
// handler_liquidate.rs:113-121
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

**Verdict: NOT EXPLOITABLE.** The LTV override is gated to the `staging` feature flag only. On mainnet (`not(feature = "staging")`), self-liquidation with LTV override is impossible.

**Hypothesis 1.3: Liquidation priority enforcement bypass**

The protocol enforces that liquidations must target the highest borrow factor debt and lowest liquidation LTV collateral:
```rust
// liquidation_operations.rs:229-245
if params.liquidation_reason == LiquidationReason::LtvExceeded && !is_debt_reserve_highest_borrow_factor {
    return err!(LendingError::LiquidationBorrowFactorPriority);
}
```

The `is_debt_reserve_highest_borrow_factor` check uses `>=` comparison against `obligation.highest_borrow_factor_pct`, and `is_collateral_reserve_lowest_liquidation_ltv` uses `<=` against `obligation.lowest_reserve_deposit_liquidation_ltv`. These cached values are set during `refresh_obligation`.

**Verdict: SAFE.** The cached values are set during refresh which must be in the same slot (staleness check).

---

### 2. Flash Loan Verification

**Hypothesis 2.1: Flash repay amount manipulation**

The `flash_repay_checks` in `flash_ixs.rs` validates:
1. No CPI calls (stack height check)
2. `borrow_instruction_index < current_index`
3. Referenced instruction at index is a `FlashBorrowReserveLiquidity` discriminator
4. Reserve account matches (index 3 in accounts)
5. `liquidity_amount == borrow_liquidity_amount`

The `flash_borrow_checks` performs forward-looking validation:
1. Scans all subsequent instructions for a matching repay
2. Ensures single borrow/repay pair
3. Validates all accounts match between borrow and repay
4. Validates amounts match

**Hypothesis 2.2: Flash loan repayment amount is only the principal (no fee)**

Looking at `flash_repay_reserve_liquidity` in lending_operations.rs:1765:
```rust
let flash_loan_amount = liquidity_amount;
let (protocol_fee, referrer_fee) = reserve.config.fees.calculate_flash_loan_fees(...)?;
reserve.liquidity.repay(flash_loan_amount, flash_loan_amount_f)?;
// ...
let flash_loan_amount_with_referral_fee = flash_loan_amount + referrer_fee;
Ok((flash_loan_amount_with_referral_fee, protocol_fee))
```

The handler then transfers `flash_loan_amount_with_referral_fee` to the supply vault and `protocol_fee` to the fee vault. The total paid by the user is `liquidity_amount + referrer_fee + protocol_fee`, which includes fees on top of the borrowed amount.

**Verdict: SAFE.** The flash loan fee mechanism correctly charges fees on top of the principal. The amount validation (`liquidity_amount` match) ensures the full principal is returned, and fees are charged additionally.

**Hypothesis 2.3: Flash loan can be used for price manipulation within same tx**

The protocol uses TWAP divergence checks (checks.rs:126) and price staleness checks. Flash loans only affect token balances within the lending protocol's vaults -- they don't directly affect oracle prices. The reserve is refreshed during flash_borrow (`lending_operations::refresh_reserve`), and prices come from external oracles (Pyth, Switchboard, Scope).

**Verdict: NOT EXPLOITABLE.** Oracle prices are external and not affected by vault balance changes.

---

### 3. Interest Rate Accrual

**Hypothesis 3.1: Precision loss in compound interest approximation**

The `approximate_compounded_interest` function (reserve.rs:1810) uses a 3rd-order Taylor expansion:
```rust
Fraction::ONE + first_term + second_term + third_term
```
Where:
- `first_term = base * exp`
- `second_term = (base^2 * exp * (exp-1)) / 2`
- `third_term = (base^3 * exp * (exp-1) * (exp-2)) / 6`

This approximation underestimates true compound interest. For small rates and short periods, this is negligible. For very large `elapsed_slots` (e.g., if `accrue_interest` is not called for weeks), the underestimation grows.

However, the per-slot rate is extremely small (annual rate / 63,072,000 slots_per_year), so `base` is on the order of 1e-8. Even for 1 million slots (~5.8 days), the error is negligible.

**Hypothesis 3.2: Can `accrue_interest` be skipped to gain advantage?**

Interest accrual happens in `refresh_reserve` which is called before most operations. The staleness check ensures reserves are refreshed in the current slot:
```rust
if reserve.last_update.is_stale(clock.slot, PriceStatusFlags::NONE)? {
    return err!(LendingError::ReserveStale);
}
```

**Verdict: SAFE.** Cannot skip interest accrual for any operation that requires a fresh reserve.

**Hypothesis 3.3: Compound interest accumulation in obligation vs reserve mismatch**

The obligation tracks `cumulative_borrow_rate_bsf` per liquidity position and multiplies borrowed amounts by the ratio of new/old rates during `accrue_interest` (obligation.rs:694-723). This uses U256 arithmetic for precision:
```rust
let borrowed_amount_sf_u256 = U256::from(self.borrowed_amount_sf)
    * new_cumulative_borrow_rate_bsf / former_cumulative_borrow_rate_bsf;
```

This is a standard cumulative rate index approach. The division truncates toward zero, meaning the borrower's debt is slightly underestimated. This is protocol-favorable in that it rounds down debt (against the lender), but the effect is sub-atomic unit.

**Verdict: SAFE.** Standard index-based interest accrual. Truncation is toward zero on borrower's debt, marginal impact.

---

### 4. Oracle Price Manipulation

**Hypothesis 4.1: Spot prices used without TWAP validation**

The price validation in `checks.rs` shows that TWAP checking is configurable per token:
```rust
if token_info.is_twap_enabled() {
    // check TWAP exists, age, and divergence
} else {
    // Mark TWAP checks as passed
    price_status.set(PriceStatusFlags::TWAP_CHECKED, true);
    price_status.set(PriceStatusFlags::TWAP_AGE_CHECKED, true);
}
```

If TWAP is not enabled for a token, the spot price is used without divergence checking. This is a configuration decision, not a bug. The `PriceStatusFlags` system allows operations to require different levels of price validation:
- `PriceStatusFlags::NONE` -- for deposits, redemptions (no price check needed)
- `PriceStatusFlags::ALL_CHECKS` -- for borrows, liquidations (all checks required)

**Hypothesis 4.2: Price staleness during liquidation**

Liquidation requires `assert_obligation_liquidatable` which calls `check_obligation_fully_refreshed_and_not_null`. Both the obligation and reserves must be refreshed in the current slot. The obligation's `last_update` inherits the intersection of all reserve price statuses during refresh.

**Verdict: SAFE.** The price status flag system is well-designed. Operations requiring accurate prices demand ALL_CHECKS, which includes TWAP validation when configured.

---

### 5. Share Calculation (cToken/Collateral Exchange Rate)

**Hypothesis 5.1: First-depositor inflation attack**

The protocol has explicit first-depositor protection via `seed_deposit_on_init_reserve`:
```rust
// handler_seed_deposit_on_init_reserve.rs:31-32
reserve.liquidity.total_available_amount = market.min_initial_deposit_amount;
reserve.collateral.mint_total_supply = market.min_initial_deposit_amount;
```

The `min_initial_deposit_amount` defaults to 100,000 (`DEFAULT_MIN_DEPOSIT_AMOUNT`). This creates a 1:1 exchange rate with a minimum seed deposit. The cTokens from this seed deposit are not minted to any user -- they are "dead shares" that permanently exist in the protocol's accounting.

Additionally, deposits cannot proceed until the seed deposit is made:
```rust
// From update_reserve_config checking ReserveHasNotReceivedInitialDeposit
```

**Verdict: SAFE.** The seed deposit mechanism (dead shares) effectively prevents the first-depositor inflation attack. With 100,000 minimum seed, donation attacks become economically infeasible.

**Hypothesis 5.2: Rounding direction consistency**

Examining collateral exchange rate operations:
- `liquidity_to_collateral`: `to_floor()` -- depositor gets fewer cTokens (rounds down for depositor)
- `collateral_to_liquidity`: `to_floor()` -- redeemer gets fewer liquidity tokens (rounds down for redeemer)
- `collateral_to_liquidity_ceil`: used in `compute_depositable_amount_and_minted_collateral` to calculate the exact liquidity needed for a given collateral amount

The deposit flow:
1. `collateral_amount = liquidity_to_collateral(liquidity_amount)` -- floor
2. `liquidity_amount_to_deposit = collateral_to_liquidity_ceil(collateral_amount)` -- ceil
3. Asserts `liquidity_amount >= liquidity_amount_to_deposit`

This means the protocol always rounds in its own favor: depositors provide slightly more liquidity than the cTokens represent. Redeemers receive slightly less.

**Verdict: SAFE.** Rounding is consistently protocol-favorable.

---

### 6. Obligation Health Calculation

**Hypothesis 6.1: Stale obligation values used during critical operations**

All critical operations (borrow, withdraw, liquidate) check:
```rust
if obligation.last_update.is_stale(slot, required_price_status)? {
    return err!(LendingError::ObligationStale);
}
```

The obligation is refreshed via `refresh_obligation` which recalculates all market values, allowed_borrow_value, unhealthy_borrow_value from current reserve prices and exchange rates.

**Hypothesis 6.2: Elevation group LTV manipulation**

When switching elevation groups (`request_elevation_group`), the protocol:
1. Resets all elevation group debt trackers
2. Refreshes borrows and deposits under the new group's parameters
3. Validates `allowed_borrow_value >= borrow_factor_adjusted_debt_value`
4. Checks LTV not worsened if marked for deleveraging

**Verdict: SAFE.** The full refresh during elevation group changes prevents manipulation.

---

### 7. Deposit/Withdraw/Borrow/Repay

**Hypothesis 7.1: CPI reentrancy on borrow**

The handlers use the `is_forbidden_cpi_call` check:
```rust
if get_stack_height() > TRANSACTION_LEVEL_STACK_HEIGHT {
    return Ok(true); // forbidden
}
```

Flash loans explicitly check for CPI:
```rust
if instruction_loader.is_flash_forbidden_cpi_call()? {
    return err!(LendingError::FlashBorrowCpi);
}
```

Regular operations (borrow, deposit, etc.) go through `check_refresh_ixs` macro which also verifies via sysvar introspection.

Additionally, there's a CPI whitelist mechanism for approved integrators (Squads, FlexLend, etc.) with configurable depth levels.

**Verdict: SAFE.** CPI is either blocked or whitelisted with controlled depth.

**Hypothesis 7.2: Token amount rounding on repay benefits borrower**

In `calculate_repay`:
```rust
let settle_amount = if amount_to_repay == u64::MAX {
    borrowed_amount
} else {
    min(Fraction::from(amount_to_repay), borrowed_amount)
};
let repay_amount = settle_amount.to_ceil();
```

`settle_amount` is the fractional debt reduction, `repay_amount` is the actual tokens transferred. `to_ceil()` means the borrower pays at least as much as the debt reduction -- protocol-favorable rounding.

**Verdict: SAFE.** Repay amount is ceiled, preventing borrowers from underpaying.

---

### 8. Reserve Configuration -- Admin Parameter Attacks

**Hypothesis 8.1: Admin can set malicious parameters to drain funds**

The `update_reserve_config` instruction requires `lending_market_owner` or `proposer_authority` as signer. It can modify:
- LTV/liquidation threshold
- Borrow/deposit limits
- Fee rates
- Borrow rate curve
- Elevation groups

There is a `validate_reserve_config_integrity` function (referenced but not fully traced) and a `skip_config_integrity_validation` parameter.

The lending market can be set as `immutable`:
```rust
pub fn is_immutable(&self) -> bool { self.immutable != false as u8 }
```

When immutable, updates are blocked with `OperationNotPermittedMarketImmutable`.

**Verdict: LOW RISK.** Admin is trusted. The immutable flag provides a safety mechanism. The `skip_config_integrity_validation` parameter is concerning but requires admin authority.

---

### 9. Account Validation

**Hypothesis 9.1: Reserve account spoofing**

All critical accounts use Anchor constraints:
- `has_one = lending_market` -- reserves must belong to the correct market
- `address = reserve.load()?.liquidity.supply_vault` -- vault addresses verified
- `seeds = [LENDING_MARKET_AUTH, lending_market.key().as_ref()], bump` -- PDA authority
- `address = reserve.load()?.liquidity.mint_pubkey` -- mint verified

**Hypothesis 9.2: Obligation spoofing**

Obligations are linked to lending markets via `has_one = lending_market`. Owner checks are performed in handlers via `obligation.owner == signer.key()`.

**Verdict: SAFE.** Standard Anchor account validation patterns are used consistently.

---

### 10. Referrer Fee Handling

**Hypothesis 10.1: Referrer fee gaming**

The referrer fee is deducted from the origination fee, not charged additionally:
```rust
let protocol_fee = origination_fee - referral_fee;
```

The referrer state is validated via PDA:
```rust
let referrer_token_state_valid_pda = Pubkey::create_program_address(
    &[BASE_SEED_REFERRER_TOKEN_STATE, referrer.as_ref(), reserve.as_ref(), &[bump]],
    program_id,
)?;
```

The `validate_referrer_token_state` function checks mint, referrer, and PDA derivation.

**Verdict: SAFE.** Referrer fees are bounded by the origination fee and validated via PDA seeds.

---

### 11. Post-Transfer Vault Balance Checks

**Hypothesis 11.1: Vault balance drift from token extensions**

The `post_transfer_vault_balance_liquidity_reserve_checks` function validates:
```rust
// Pre-transfer diff == Post-transfer diff
pre_transfer_reserve_diff == post_transfer_reserve_diff
// Expected vault balance matches actual
expected_reserve_vault_balance == final_reserve_vault_balance
```

This catches any unexpected token balance changes from transfer hooks or fee-on-transfer tokens.

**Verdict: SAFE.** The invariant check system is robust against token extension manipulation.

---

### 12. Withdrawal Cap Operations

**Hypothesis 12.1: Withdrawal cap bypass via time manipulation**

Withdrawal caps use `last_interval_start_timestamp` and reset periodically. On Solana, timestamps come from the Clock sysvar which is consensus-driven and cannot be easily manipulated.

**Verdict: SAFE.** Timestamp source is reliable.

---

### 13. Flash Loan + Liquidation Combo Attack

**Hypothesis 13.1: Flash borrow to manipulate oracle, then liquidate**

Flash loans cannot be used via CPI (checked). Oracle prices are external (Pyth/Switchboard/Scope) and not affected by on-chain token movements. The flash loan amounts are from the lending reserve vault, not from DEX pools that feed into oracle prices.

**Verdict: NOT EXPLOITABLE.** Oracle prices are independent of vault balances.

---

### 14. Socialize Loss Mechanism

**Hypothesis 14.1: Premature loss socialization**

```rust
if !obligation.is_active_deposits_empty() {
    return Err(LendingError::CannotSocializeObligationWithCollateral.into());
}
```

Loss can only be socialized when the obligation has no remaining collateral (fully liquidated). Both reserve and obligation must be freshly refreshed. The forgiven debt reduces `borrowed_amount_sf` in the reserve, diluting all depositors proportionally.

**Verdict: SAFE.** Guards prevent premature socialization.

---

### 15. Withdraw Queue / Ticketed Withdrawals

**Hypothesis 15.1: Queue manipulation**

The withdraw queue tracks `queued_collateral_amount` and uses sequential ticket numbers. The `freely_available_liquidity_amount()` subtracts queued collateral's liquidity value from available amount, preventing double-spending of reserved liquidity.

Borrows use `freely_available_liquidity_amount()` which respects the queue, while flash loans use `borrow(liquidity_amount_f, true)` -- the `true` parameter means `use_withdraw_queue=true`, allowing flash loans to use queued liquidity (since they must be repaid within the same transaction).

**Verdict: SAFE.** The queue mechanism properly reserves liquidity for pending withdrawals.

---

## Summary of Findings

### Confirmed Vulnerabilities: 0

### Notable Observations (Informational):

1. **INFO-01: Taylor expansion interest approximation underestimates compound interest.**
   - File: `/root/defi-audit-targets/audits/kamino/klend/programs/klend/src/state/reserve.rs:1810`
   - The 3rd-order approximation always underestimates true compound interest. For very high rates and long periods without refresh, this creates a small but systematic loss for depositors.
   - Impact: Negligible in practice due to per-slot rate being extremely small (~1e-8).
   - Severity: Informational

2. **INFO-02: `skip_config_integrity_validation` flag allows bypassing configuration checks.**
   - File: `/root/defi-audit-targets/audits/kamino/klend/programs/klend/src/lib.rs:70`
   - The admin can bypass validation when updating reserve configs.
   - Impact: Requires trusted admin. Risk if admin key is compromised.
   - Severity: Informational

3. **INFO-03: Flash loans can use liquidity reserved for the withdraw queue.**
   - File: `/root/defi-audit-targets/audits/kamino/klend/programs/klend/src/lending_market/lending_operations.rs:1759`
   - `reserve.borrow(liquidity_amount_f, true)` uses `use_withdraw_queue=true`, accessing all available liquidity including amounts queued for withdrawal.
   - Impact: Queued withdrawals may temporarily fail during flash loan execution, but flash loans are atomic within a single transaction so the liquidity is restored before any withdrawal can execute.
   - Severity: Informational

4. **INFO-04: RESTRICTED_PROGRAMS list only contains Jupiter (jupr81Y).**
   - File: `/root/defi-audit-targets/audits/kamino/klend/programs/klend/src/utils/consts.rs:240`
   - Only Jupiter is in the restricted programs list. This prevents Jupiter swaps within flash loan transactions, but other DEX programs are not restricted.
   - Severity: Informational

5. **INFO-05: Protocol liquidation fee minimum is 1 token unit.**
   - File: `/root/defi-audit-targets/audits/kamino/klend/programs/klend/src/state/liquidation_operations.rs:970`
   - `max(protocol_fee, 1)` ensures at least 1 unit is taken as protocol fee even for tiny liquidations.
   - For high-decimal tokens this is negligible. For zero-decimal tokens, this could disproportionately reduce liquidator profit.
   - Severity: Informational

---

## Defensive Architecture Assessment

The klend codebase demonstrates strong defensive engineering:

1. **Post-transfer vault balance invariants**: Every token transfer is followed by a check that vault balances moved exactly as expected, preventing re-entrancy and fee-on-transfer issues.

2. **Price status flags**: A bitfield-based system tracks which price checks have passed, and operations declare which checks they require. This prevents using stale or unvalidated prices.

3. **Staleness checks**: Both reserves and obligations must be refreshed in the current slot before any value-affecting operation.

4. **Fixed-point math with U256 overflow protection**: The `BigFraction` type uses U256 for intermediate calculations, and the `panicking_shl` function explicitly checks for overflow.

5. **Seed deposit on reserve init**: Dead shares prevent the first-depositor inflation attack.

6. **CPI protection**: Stack height checks prevent unauthorized cross-program invocations, with a whitelist for approved integrators.

7. **LTV invariant checks**: Post-operation invariants verify that borrows don't exceed unhealthy thresholds and withdrawals don't make positions liquidatable.

8. **Liquidation bonus capped by diff_to_bad_debt**: Prevents liquidation bonus from creating bad debt.

9. **Withdrawal caps**: Rate-limited withdrawals and borrows prevent sudden drain attacks.

10. **Emergency mode**: Global circuit breaker that can halt all operations.

---

## Conclusion

The Kamino klend lending protocol is **well-engineered with no exploitable vulnerabilities found**. The codebase has been through multiple professional audits (OtterSec, Offside Labs, Certora, Sec3) and shows strong defensive patterns throughout. The fixed-point math is carefully implemented with appropriate precision levels, rounding is consistently protocol-favorable, and post-operation invariant checks catch a wide range of potential issues.

Tested Hypotheses: 20+
Confirmed Exploitable: 0
Informational: 5
