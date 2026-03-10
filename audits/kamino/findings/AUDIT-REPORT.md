# Kamino Finance — Security Audit Report

**Date:** 2026-03-02
**Target:** Kamino Finance (Solana DeFi protocol suite)
**Bounty:** Immunefi, max $100,000
**Programs Audited:** klend (lending), kvault (vault), scope (oracle), kfarms (farming)
**Total LOC:** ~43,700 Rust
**Ecosystem:** Solana / Anchor

---

## Executive Summary

**Result: 2 Low-Medium, 2 Low, 8 Informational findings. 1 Immunefi submission.**

Across 4 programs and ~43,700 lines of Rust code, 80+ vulnerability hypotheses were tested across two audit passes. The initial audit (60+ hypotheses) found 0 exploitable vulnerabilities. A re-audit using per-instruction access control matrices, cross-adapter comparison tables, external data field tracing, and exploit pattern matching uncovered oracle-layer issues in the Scope program — specifically in the ChainlinkX (v10) oracle adapter and the `refresh_chainlink_price` handler.

The klend, kvault, and kfarms programs remain exceptionally well-defended with no exploitable findings.

---

## Scope

### In-Scope Repositories

| Repository | Program ID | LOC | Description |
|-----------|-----------|-----|-------------|
| [klend](https://github.com/Kamino-Finance/klend) | `KLend2g3cP87fffoy8q1mQqGKjrxjC8boSyAYavgmjD` | ~23,000 | Lending/borrowing protocol |
| [kvault](https://github.com/Kamino-Finance/kvault) | kvault program | ~5,300 | ERC4626-like yield vault |
| [scope](https://github.com/Kamino-Finance/scope) | scope program | ~6,200 | Oracle aggregator |
| [kfarms](https://github.com/Kamino-Finance/kfarms) | `FarmsPZpWu9i7Kky8tPN37rs2TpmMrAZrC7S7vJa91Hr` | ~9,200 | Staking/farming rewards |

### Previous Audits
- OtterSec, Offside Labs, Certora, Sec3 (per security.txt in klend)

---

## Architecture Overview

```
scope (oracle) ──> klend (lending) <──> kfarms (farming)
                       ↑
                   kvault (vault) ──CPI──> klend reserves
```

- **klend**: Anchor-based lending with reserves, obligations, elevation groups, flash loans, withdrawal queues, and delegated farming. Uses U68F60 fixed-point (`Fraction`) and U256 (`BigFraction`) for precision.
- **kvault**: Deposits user tokens into klend reserves for yield. Internal accounting (not balance-derived) prevents donation attacks.
- **scope**: Oracle aggregator supporting 40+ types (Pyth, Switchboard, Chainlink v3/v7/v8/v9/v10, kTokens, TWAPs, chains). CPI protection via stack height + preceding instruction checks on `refresh_price_list`.
- **kfarms**: Staking with warmup/cooldown periods, delegated farms for klend obligations, WAD-precision reward-per-share tracking.

---

## Findings

### FINDING-01 [Low-Medium]: ChainlinkX v10 Ignores `tokenized_price` Field

**Program:** scope
**File:** `programs/scope/src/oracles/chainlink.rs:480-487`
**Immunefi Submission:** [IMMUNEFI-SUBMISSION-001.md](IMMUNEFI-SUBMISSION-001.md)

**Description:** The `update_price_v10` function manually computes `price * current_multiplier` to derive the xStocks price. However, the `ReportDataV10` struct from the `chainlink-data-streams-report` dependency (v1.0.3, commit `fb56ce042fc7`) includes a `tokenized_price: BigInt` field documented as the "24/7 tokenized equity price" — a pre-computed price that accounts for multipliers and corporate actions.

The code ignores `tokenized_price` and has a TODO at line 483: `// TODO(liviuc): once Chainlink has added the 'total_return_price', use that`. The field already exists as `tokenized_price` but the developer appears to have expected it under a different name (`total_return_price`).

**Evidence:** The Chainlink SDK test data (`data-streams-sdk/rust/crates/report/src/report/v10.rs:167`) sets `tokenized_price = MOCK_PRICE * 2` independently from `price * current_multiplier`, confirming these values can diverge. The field documentation describes it as the "24/7 tokenized equity price" — the continuously-available price for tokenized equities that may differ from the raw `price * current_multiplier` computation.

**Impact:**
- During off-market hours, `tokenized_price` may reflect continued 24/7 trading while `price` is stale (last close)
- During corporate action transitions, the manual multiplication may diverge from Chainlink's natively-computed total return price
- Precision loss from manual BigInt multiplication vs. Chainlink's pre-computed value
- For klend lending: incorrect collateral valuation for xStocks-denominated positions, potentially enabling under-collateralized borrowing or triggering unfair liquidations

**Mitigating Factors:**
- Market status validation restricts updates during closed hours (configurable per-asset)
- Suspension/blackout mechanism freezes prices 24h before corporate actions
- `ref_price` cross-check (when configured) provides secondary price sanity bounds
- Chainlink reports are cryptographically signed — attacker cannot forge values

**Recommendation:** Replace manual `price * current_multiplier` with `tokenized_price`:
```rust
// BEFORE (current):
let price_dec = chainlink_bigint_value_parse(&chainlink_report.price)?;
let current_multiplier_dec = chainlink_bigint_value_parse(&chainlink_report.current_multiplier)?;
let multiplied_price: Price = price_dec.try_mul(current_multiplier_dec)
    .map_err(|_| ScopeError::MathOverflow)?.into();

// AFTER (recommended):
let tokenized_price: Price = chainlink_bigint_value_parse(&chainlink_report.tokenized_price)?
    .into();
```

---

### FINDING-02 [Low-Medium]: Missing CPI Protection on `refresh_chainlink_price`

**Program:** scope
**File:** `programs/scope/src/handlers/handler_refresh_chainlink_price.rs`

**Description:** The `refresh_chainlink_price` instruction lacks the `check_execution_ctx()` CPI protection that `refresh_price_list` enforces. This creates an asymmetry in the security model:

| | `refresh_price_list` | `refresh_chainlink_price` |
|---|---|---|
| CPI blocked? | YES (stack height + program ID) | **NO** |
| Preceding ix whitelist? | YES (ComputeBudget only) | **NO** |
| `instruction_sysvar` required? | YES | **NO** |
| Signer requirement | None (permissionless) | `user: Signer` (any) |

Without CPI protection, `refresh_chainlink_price` can be:
1. Called via CPI from any program (PDA as signer)
2. Composed in transactions with arbitrary preceding/following instructions
3. Used in atomic transaction sequences: `[setup] → [refresh_chainlink_price] → [exploit]`

**Impact:** An attacker monitoring Chainlink data streams could atomically compose a transaction that applies a price update and immediately acts on it in klend (borrow, liquidate, withdraw), before anyone else can react to the new price. The `refresh_price_list` CPI protection specifically prevents this pattern for standard oracle sources.

**Mitigating Factors:**
- Chainlink reports are cryptographically verified — attacker cannot forge prices
- Reports must have strictly increasing `observations_timestamp`
- klend has its own staleness and TWAP divergence checks
- The practical exploitation window requires finding a scenario where timing a legitimate report is profitable

**Recommendation:** Add `check_execution_ctx()` to `refresh_chainlink_price`, matching the protection on `refresh_price_list`. Add `instruction_sysvar_account_info` to the accounts struct.

---

### FINDING-03 [Low]: Missing CPI Protection on `refresh_pyth_lazer_price`

**Program:** scope
**File:** `programs/scope/src/handlers/handler_refresh_pyth_lazer_price.rs`

**Description:** Same CPI protection gap as FINDING-02. The `refresh_pyth_lazer_price` handler does not call `check_execution_ctx()`.

**Mitigating Factors:** Partially mitigated by the Pyth Lazer verification CPI which inherently uses the `instructions_sysvar` for ed25519 signature verification. The Pyth treasury is also charged per verification, adding cost to spam.

**Recommendation:** Add `check_execution_ctx()` for consistency with `refresh_price_list`.

---

### FINDING-04 [Low]: Chainlink Refresh Path Bypasses Zero-Price Guard

**Program:** scope
**Files:** `handlers/handler_refresh_chainlink_price.rs`, `oracles/mod.rs:468`, `oracles/chainlink.rs:480-487`

**Description:** The `refresh_price_list` path calls `get_non_zero_price()` which rejects `price.value == 0` for all non-FixedPrice oracle types. The `refresh_chainlink_price` path has **no equivalent zero-price guard**. If any Chainlink report version produces a zero price (e.g., v10 with `current_multiplier = 0`), it would be stored in `oracle_prices` without rejection.

The `chainlink_bigint_value_parse()` function only rejects negative BigInt values and values exceeding 192 bits. A zero BigInt passes validation and produces `Price { value: 0, exp: 18 }`.

**End-to-end zero-price path:**
1. Chainlink DON signs v10 report with `current_multiplier = 0`
2. `refresh_chainlink_price` stores zero price in Scope oracle (no zero guard)
3. klend reads Scope price via `get_base_price()` (no zero guard for Scope path — klend only checks zero for Pyth/Switchboard)
4. Collateral valued at $0 → all positions become instantly liquidatable

**Mitigating Factors:**
- Requires Chainlink DON to sign a report with anomalous data (extremely unlikely)
- Entries with `ref_price` configured would catch zero prices via tolerance check
- klend TWAP divergence and heuristic bounds provide secondary protection
- `overflow-checks = true` across all programs

**Recommendation:** Add `if multiplied_price.value == 0 { return Err(ScopeError::PriceNotValid); }` after the multiplication in `update_price_v10`. Consider adding the same guard to all Chainlink update functions.

---

## Informational Observations

| ID | Severity | Program | Description |
|----|----------|---------|-------------|
| INFO-01 | Info | klend | Taylor 3rd-order compound interest systematically underestimates (negligible at per-slot rates) |
| INFO-02 | Info | klend | `skip_config_integrity_validation` flag allows admin to bypass config checks |
| INFO-03 | Info | klend | Flash loans can use withdraw queue reserved liquidity (atomic, no impact) |
| INFO-04 | Info | klend | RESTRICTED_PROGRAMS only blocks Jupiter; other DEXes unrestricted |
| INFO-05 | Info | klend | Protocol liquidation fee minimum of 1 token unit (disproportionate for 0-decimal tokens) |
| INFO-06 | Info | kvault | Performance fee allows up to 100% (design choice) |
| INFO-07 | Info | kvault | Withdrawal penalty uses max(global, vault) — admin controls floor |
| INFO-08 | Info | scope | `expires_at` and `valid_from_timestamp` ignored across all 5 Chainlink report versions (Chainlink verifier CPI handles expiration) |
| INFO-09 | Info | scope | Confidence interval check only on v3 (v7-v10 report formats lack bid/ask data) |
| INFO-10 | Info | scope | `tokenized_price` and `new_multiplier` fields in v10 reports ignored (see FINDING-01) |
| INFO-11 | Info | scope | scope_chain `get_price_from_chain` uses U128 (TODO: "not working with latest prices that have a lot of decimals"). Fails safely via `checked_mul`. klend reimplements with U256 + adaptive exponent reduction. |
| INFO-12 | Info | scope | KToken oracle mapping validation returns `Ok(())` without ownership checks (3 TODOs). Admin-only operation. |
| INFO-13 | Info | scope | Jupiter LP staleness undetectable — uses `clock.slot`/`clock.unix_timestamp` as update time (TODO: "find a way to get the last update time") |
| INFO-14 | Info | scope | Pyth Pull outage handling undecided (TODO: "Discuss how we should handle the time jump that can happen when there is an outage") |
| INFO-15 | Info | scope | DEX pool oracles (Orca, Raydium, Meteora) use spot pool prices. CPI-protected by `refresh_price_list`'s `check_execution_ctx`, preventing intra-transaction manipulation. |
| INFO-16 | Info | scope | Scope program has **zero test coverage** — no `#[test]`, no `#[cfg(test)]`, no integration tests |
| INFO-17 | Info | scope | v10 blackout/suspension state machine has zero test coverage |
| LOW-01 | Low | kvault | Shares minted before transfer confirmed (atomic — not exploitable) |
| LOW-02 | Low | kfarms | `reward_user_once` credits without deducting from `rewards_available` |
| LOW-03 | Low | kfarms | `reward_user_once` skips global reward refresh |
| LOW-04 | Low | kfarms | `set_stake_delegated` uses runtime check instead of Anchor `has_one` |
| LOW-05 | Low | kfarms | Pending withdrawal cooldown overwritten on re-unstake |
| LOW-06 | Low | kfarms | `slashed_amount_current` incremented but never consumed/transferred |
| LOW-07 | Low | scope | CPI protection does not restrict post-refresh instructions (by design) |
| LOW-08 | Low | scope | EMA initialized from single sample (mitigated by min-sample validation) |
| LOW-09 | Low | scope | klend has no zero-price guard for Scope-sourced prices (only Pyth/Switchboard have explicit zero checks) |
| LOW-10 | Low | kfarms | `unimplemented!()` in `update_reward_config` catch-all (unreachable by current call graph, but panics instead of returning error) |

---

## Hypotheses Tested (80+)

### Initial Audit — klend (20+ hypotheses)

| # | Hypothesis | Result | Reason |
|---|-----------|--------|--------|
| 1.1 | Liquidation bonus + protocol fee > 100% → drain | Safe | Bonus capped by `diff_to_bad_debt`; fee is fraction of bonus only |
| 1.2 | Profitable self-liquidation | Safe | LTV override gated to `staging` feature only (compile-time) |
| 1.3 | Liquidation priority enforcement bypass | Safe | Cached values set during same-slot refresh |
| 2.1 | Flash repay amount manipulation | Safe | Bidirectional instruction validation (borrow↔repay) |
| 2.2 | Flash loan fee evasion | Safe | Fee charged on top of principal; amount validation exact |
| 2.3 | Flash loan → oracle manipulation | Safe | Oracle prices external, not affected by vault balances |
| 3.1 | Taylor compound interest precision loss | Info | Per-slot rate ~1e-8 makes 3rd-order error negligible |
| 3.2 | Skip interest accrual | Safe | Staleness check enforces same-slot refresh |
| 3.3 | Obligation vs reserve rate mismatch | Safe | Standard U256 cumulative index; truncation sub-atomic |
| 4.1 | Spot prices without TWAP validation | Safe | Configurable per token; ops requiring accurate prices demand ALL_CHECKS |
| 4.2 | Price staleness during liquidation | Safe | Both reserve + obligation must be current-slot fresh |
| 5.1 | First-depositor inflation attack | Safe | Seed deposit (100K dead shares) on reserve init |
| 5.2 | Rounding direction inconsistency | Safe | Consistently protocol-favorable (floor for minting, ceil for burning) |
| 6.1 | Stale obligation values in critical ops | Safe | Same-slot staleness enforcement |
| 6.2 | Elevation group LTV manipulation | Safe | Full refresh on group change with health validation |
| 7.1 | CPI reentrancy | Safe | Stack height checks + CPI whitelist with depth control |
| 7.2 | Repay rounding benefits borrower | Safe | `to_ceil()` on repay amount; protocol-favorable |
| 8.1 | Admin sets malicious config | Trusted | Admin-only; `immutable` flag available |
| 9.1 | Reserve/obligation account spoofing | Safe | Anchor constraints: `has_one`, PDA seeds, discriminators |
| 10.1 | Referrer fee gaming | Safe | Deducted from origination fee; PDA-validated |
| 11.1 | Post-transfer vault balance drift | Safe | Invariant checks catch fee-on-transfer/hook issues |
| 12.1 | Withdrawal cap time bypass | Safe | Clock sysvar is consensus-driven |
| 13.1 | Flash borrow → manipulate → liquidate | Safe | Oracle independent of vault; CPI banned |
| 14.1 | Premature loss socialization | Safe | Requires zero collateral + fresh state |
| 15.1 | Withdraw queue manipulation | Safe | `freely_available_liquidity_amount()` respects queue |

### Initial Audit — kvault (7 hypotheses)

| # | Hypothesis | Result | Reason |
|---|-----------|--------|--------|
| H1 | First-depositor inflation | Safe | INITIAL_DEPOSIT_AMOUNT=1000 seed; internal accounting |
| H2 | Share rounding exploitation | Safe | All rounding protocol-favorable (floor mint, ceil burn) |
| H3 | Fee timing sandwich | Safe | `charge_fees()` called before all share calculations |
| H4 | Deposit overflow in crank_funds | Safe | overflow-checks=true; min_deposit guard |
| H5 | Invest AUM manipulation | Safe | Post-transfer checks verify holdings never decrease |
| H6 | Withdrawal from non-allocated reserve | Safe | `is_allocated_to_reserve` check |
| H7 | Performance fee on loss | Safe | `saturating_sub` returns 0 on AUM decrease |

### Initial Audit — kfarms (7 hypotheses)

| # | Hypothesis | Result | Reason |
|---|-----------|--------|--------|
| H8 | Flash-stake delegated farms | Safe | Restricted to trusted authority; warmup prevents flash |
| H9 | Reward precision loss accumulation | Safe | WAD-based Decimal; tally advances by integer only |
| H10 | reward_user_once bypasses limits | Design | Trusted admin op; SPL transfer fails if underfunded |
| H11 | Unstake tally underflow | Safe | `require_gt!` + `saturating_sub` |
| H12 | Early withdrawal penalty edge cases | Safe | All boundary conditions handled correctly |
| H13 | Delegated stake exceeds cap | Safe | `can_accept_deposit` check on increases |
| H14 | Permissionless harvest steal | Safe | Tokens always sent to user's own ATA |

### Initial Audit — scope (6 hypotheses)

| # | Hypothesis | Result | Reason |
|---|-----------|--------|--------|
| H15 | CPI protection bypass | Safe | Triple check: program ID + stack height + preceding ix |
| H16 | Price chain multiplication overflow | Safe | `checked_mul` fails safely; klend uses U256 reimplementation |
| H17 | TWAP manipulation via rapid updates | Safe | 30s min interval; min samples; sub-period distribution |
| H18 | MostRecentOf divergence | Safe | All sources checked staleness + cross-validated |
| H19 | Ref price difference bypass | Safe | Batch skips failing tokens; others keep previous values |
| H20 | Scope chain staleness | Safe | Uses minimum timestamp across all chain elements |

### Initial Audit — Cross-Program (8 vectors)

| # | Vector | Result | Reason |
|---|--------|--------|--------|
| X1 | Scope manipulation → klend exploit | Safe | CPI ban + TWAP divergence + multi-oracle fallback |
| X2 | Flash loan → kvault share manipulation | Safe | Exchange rate unaffected by flash borrow |
| X3 | Flash borrow → kfarms stake | Safe | Warmup periods prevent flash-stake reward extraction |
| X4 | kvault shares as klend collateral (circular) | Safe | No scope oracle type exists for kvault shares |
| X5 | kfarms reward token arbitrage | N/A | Independent accounting systems |
| X6 | Cross-program admin compromise | Trusted | Per-program admin separation limits blast radius |
| X7 | kvault skip_price_updates pattern | Safe | kvault needs exchange rates, not oracle prices |
| X8 | First-depositor on kvault via donation | Safe | Internal accounting; not balance-derived |

### Re-Audit — Per-Instruction Access Control Matrix (11 instructions)

| # | Instruction | CPI Protected? | Admin? | Finding |
|---|------------|---------------|--------|---------|
| 1 | `initialize` | No | No (seeds prevent re-init) | Safe |
| 2 | `refresh_price_list` | **YES** | No | Safe — baseline protection |
| 3 | `refresh_chainlink_price` | **NO** | No | **FINDING-02** |
| 4 | `refresh_pyth_lazer_price` | **NO** | No | **FINDING-03** |
| 5 | `update_mapping_and_metadata` | N/A | YES | Safe |
| 6 | `reset_twap` | YES | YES | Safe |
| 7 | `set_admin_cached` | YES | YES | Safe |
| 8 | `approve_admin_cached` | YES | YES | Safe |
| 9 | `create_mint_map` | N/A | YES | Safe |
| 10 | `close_mint_map` | N/A | YES | Safe |
| 11 | `resume_chainlinkx_price` | YES | YES | Safe |

### Re-Audit — External Data Field Tracing (5 Chainlink versions, 48 fields)

| Version | Total Fields | Used | Validated | Ignored (Security-Relevant) |
|---------|-------------|------|-----------|----------------------------|
| V3 | 9 | 7 | 7 | `expires_at`, `valid_from_timestamp` |
| V7 | 7 | 4 | 4 | `expires_at`, `valid_from_timestamp` |
| V8 | 9 | 6 | 6 | `expires_at`, `valid_from_timestamp` |
| V9 | 10 | 7 | 7 | `expires_at`, `valid_from_timestamp`, `aum` |
| V10 | 13 | 8 | 7 | `expires_at`, `valid_from_timestamp`, **`tokenized_price`**, `new_multiplier` |

### Re-Audit — Exploit Pattern Matching (12 patterns, 18 checks)

| # | Pattern | Rating |
|---|---------|--------|
| 1A | Spot oracle for DEX pools | Safe (CPI-protected by `refresh_price_list`) |
| 1B | kToken oracle manipulation | Safe (oracle-derived sqrt_price, not pool) |
| 1C | Chainlink v10 multiplier | **FINDING-01** (tokenized_price ignored) |
| 1D | Adapter confidence asymmetry | Info (report format limitation) |
| 2A | Missing health check (socialize_loss) | Safe (admin-only, empty collateral required) |
| 2B | Missing health check (borrow/withdraw) | Safe (all operations check health) |
| 6A | Self-liquidation discount | Safe (staging feature gate, compile-time) |
| 9A | kvault donation attack | Safe (internal accounting) |
| 9B | kvault invest exchange rate | Safe (pre/post AUM checks + CPI protection) |
| 10A | kvault→klend CPI state consistency | Safe (Solana single-threaded) |
| 10B | kfarms delegated farm timing | Safe (farm refresh after obligation change) |
| 10C | Circular dependency Scope→klend→kvault | Safe (unidirectional data flow) |
| 11C | Permissionless Chainlink refresh | **FINDING-02** |
| 11D | Permissionless Pyth Lazer refresh | **FINDING-03** |
| 12A | Corporate action `activation_date_time=0` | Safe (correctly skips suspension) |
| 12B | Pre/post split report coexistence | Safe (suspension + timestamp gate) |

### Re-Audit — Cross-Adapter Validation Comparison (26 adapters)

Built full validation comparison across all 26 oracle adapters. Key asymmetries identified:

| Check | Adapters WITH | Adapters WITHOUT |
|-------|--------------|-----------------|
| Confidence interval | Pyth, PythPull, PythPullEMA, SwitchboardOD, Chainlink v3, PythLazer | All others (v7-v10, DEX, staking, etc.) |
| Zero-price guard | `refresh_price_list` path only | Chainlink path, Pyth Lazer path |
| CPI protection | `refresh_price_list` | `refresh_chainlink_price`, `refresh_pyth_lazer_price` |
| Staleness check | Pyth, SwitchboardOD, Chainlink v8/v9/v10 | Orca, Raydium, Meteora, JupiterLP, MSolStake, JitoRestaking |

---

## Defensive Architecture Assessment

### 10 Key Defensive Patterns

1. **Post-transfer vault balance invariants** (klend): Every token transfer followed by check that balances moved exactly as expected
2. **PriceStatusFlags bitfield system** (klend): Operations declare required price checks; staleness/TWAP/heuristic tracked per-flag
3. **Seed deposits on reserve init** (klend): 100K dead shares prevent first-depositor inflation
4. **CPI protection via stack height** (klend + scope): Flash loans and oracle refresh banned from CPI (scope: `refresh_price_list` only)
5. **Liquidation bonus capped by diff-to-bad-debt** (klend): Prevents bonus from creating insolvency
6. **Internal accounting** (kvault): Share prices from tracked state, not token balances
7. **Triple CPI protection** (scope `refresh_price_list`): Program ID + stack height + preceding instruction validation
8. **TWAP minimum sample requirements** (scope): Prevents single-update manipulation
9. **WAD-precision reward tracking** (kfarms): Integer-advance tally preserves sub-precision rewards
10. **Warmup/cooldown periods** (kfarms): Prevent flash-loan-based reward extraction

### Rounding Direction Summary

| Operation | Direction | Favors |
|-----------|-----------|--------|
| klend: liquidity → collateral | Floor | Protocol (fewer cTokens) |
| klend: collateral → liquidity | Floor | Protocol (less liquidity) |
| klend: repay amount | Ceil | Protocol (borrower pays more) |
| kvault: share minting | Floor | Protocol (fewer shares) |
| kvault: share burning | Ceil | Protocol (more shares burned) |
| kvault: deposit amount from shares | Ceil | Protocol (user pays more) |
| kvault: withdrawal entitlement | Floor | Protocol (user gets less) |

---

## Conclusion

Kamino Finance demonstrates **strong security engineering** across all four programs. The klend, kvault, and kfarms programs are exceptionally well-defended. The Scope oracle program has defense-in-depth gaps in the ChainlinkX (v10) adapter — specifically the ignored `tokenized_price` field and the missing CPI protection on the Chainlink refresh handler. These findings are mitigated by the cryptographic verification of Chainlink reports and klend's multi-layer price validation, but represent areas for improvement.

**1 Immunefi submission warranted (FINDING-01).**

---

## Detailed Analysis Files

- [klend Analysis](../notes/klend-analysis.md) — 20+ hypotheses, 5 informational
- [Secondary Programs Analysis](../notes/secondary-analysis.md) — 20 hypotheses across kvault/scope/kfarms
- [Cross-Program Analysis](../notes/cross-program-analysis.md) — 8 attack vectors analyzed
- [Re-Audit: Instruction Matrix](../notes/reaudit-instruction-matrix.md) — 11-instruction access control matrix
- [Re-Audit: External Data Fields](../notes/reaudit-external-data.md) — 48-field analysis across 5 Chainlink versions
- [Re-Audit: Pattern Matching](../notes/reaudit-pattern-matching.md) — 12 exploit patterns, 18 checks
- [Re-Audit: TODO/Coverage](../notes/reaudit-todos-coverage.md) — 13 TODO items, test coverage analysis
