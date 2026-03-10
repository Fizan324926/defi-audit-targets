# Kamino Finance — Security Audit Report

**Date:** 2026-03-02
**Target:** Kamino Finance (Solana DeFi protocol suite)
**Bounty:** Immunefi, max $100,000
**Programs Audited:** klend (lending), kvault (vault), scope (oracle), kfarms (farming)
**Total LOC:** ~43,700 Rust
**Ecosystem:** Solana / Anchor

---

## Executive Summary

**Result: CLEAN — 0 exploitable vulnerabilities found.**

Across 4 programs and ~43,700 lines of Rust code, 60+ vulnerability hypotheses were tested with full exploitation path verification. No findings warrant Immunefi submission. The codebase demonstrates exceptional defensive engineering with multiple layers of protection at every critical path.

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
- **scope**: Oracle aggregator supporting 40+ types (Pyth, Switchboard, Chainlink, kTokens, TWAPs, chains). CPI protection via stack height + preceding instruction checks.
- **kfarms**: Staking with warmup/cooldown periods, delegated farms for klend obligations, WAD-precision reward-per-share tracking.

---

## Hypotheses Tested (60+)

### klend — Lending Protocol (20+ hypotheses)

| # | Hypothesis | Result | Reason |
|---|-----------|--------|--------|
| 1.1 | Liquidation bonus + protocol fee > 100% → drain | Safe | Bonus capped by `diff_to_bad_debt`; fee is fraction of bonus only |
| 1.2 | Profitable self-liquidation | Safe | LTV override gated to `staging` feature only |
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

### kvault — Yield Vault (7 hypotheses)

| # | Hypothesis | Result | Reason |
|---|-----------|--------|--------|
| H1 | First-depositor inflation | Safe | INITIAL_DEPOSIT_AMOUNT=1000 seed; internal accounting |
| H2 | Share rounding exploitation | Safe | All rounding protocol-favorable (floor mint, ceil burn) |
| H3 | Fee timing sandwich | Safe | `charge_fees()` called before all share calculations |
| H4 | Deposit overflow in crank_funds | Safe | overflow-checks=true; min_deposit guard |
| H5 | Invest AUM manipulation | Safe | Post-transfer checks verify holdings never decrease |
| H6 | Withdrawal from non-allocated reserve | Safe | `is_allocated_to_reserve` check |
| H7 | Performance fee on loss | Safe | `saturating_sub` returns 0 on AUM decrease |

### kfarms — Staking (7 hypotheses)

| # | Hypothesis | Result | Reason |
|---|-----------|--------|--------|
| H8 | Flash-stake delegated farms | Safe | Restricted to trusted authority; warmup prevents flash |
| H9 | Reward precision loss accumulation | Safe | WAD-based Decimal; tally advances by integer only |
| H10 | reward_user_once bypasses limits | Design | Trusted admin op; SPL transfer fails if underfunded |
| H11 | Unstake tally underflow | Safe | `require_gt!` + `saturating_sub` |
| H12 | Early withdrawal penalty edge cases | Safe | All boundary conditions handled correctly |
| H13 | Delegated stake exceeds cap | Safe | `can_accept_deposit` check on increases |
| H14 | Permissionless harvest steal | Safe | Tokens always sent to user's own ATA |

### scope — Oracle (6 hypotheses)

| # | Hypothesis | Result | Reason |
|---|-----------|--------|--------|
| H15 | CPI protection bypass | Safe | Triple check: program ID + stack height + preceding ix |
| H16 | Price chain multiplication overflow | Safe | `checked_mul` fails safely; U128 intermediate |
| H17 | TWAP manipulation via rapid updates | Safe | 30s min interval; min samples; sub-period distribution |
| H18 | MostRecentOf divergence | Safe | All sources checked staleness + cross-validated |
| H19 | Ref price difference bypass | Safe | Batch skips failing tokens; others keep previous values |
| H20 | Scope chain staleness | Safe | Uses minimum timestamp across all chain elements |

### Cross-Program (8 vectors)

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

---

## Defensive Architecture Assessment

### 10 Key Defensive Patterns

1. **Post-transfer vault balance invariants** (klend): Every token transfer followed by check that balances moved exactly as expected
2. **PriceStatusFlags bitfield system** (klend): Operations declare required price checks; staleness/TWAP/heuristic tracked per-flag
3. **Seed deposits on reserve init** (klend): 100K dead shares prevent first-depositor inflation
4. **CPI protection via stack height** (klend + scope): Flash loans and oracle refresh banned from CPI
5. **Liquidation bonus capped by diff-to-bad-debt** (klend): Prevents bonus from creating insolvency
6. **Internal accounting** (kvault): Share prices from tracked state, not token balances
7. **Triple CPI protection** (scope): Program ID + stack height + preceding instruction validation
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

## Informational Observations

| ID | Severity | Program | Description |
|----|----------|---------|-------------|
| INFO-01 | Info | klend | Taylor 3rd-order compound interest systematically underestimates (negligible at per-slot rates) |
| INFO-02 | Info | klend | `skip_config_integrity_validation` flag allows admin to bypass config checks |
| INFO-03 | Info | klend | Flash loans can use withdraw queue reserved liquidity (atomic, no impact) |
| INFO-04 | Info | klend | RESTRICTED_PROGRAMS only blocks Jupiter; other DEXes unrestricted |
| INFO-05 | Info | klend | Protocol liquidation fee minimum of 1 token unit (disproportionate for 0-decimal tokens) |
| LOW-01 | Low | kvault | Shares minted before transfer confirmed (atomic — not exploitable) |
| LOW-02 | Low | kfarms | `reward_user_once` credits without deducting from `rewards_available` |
| LOW-03 | Low | kfarms | `reward_user_once` skips global reward refresh |
| LOW-04 | Low | kfarms | `set_stake_delegated` uses runtime check instead of Anchor `has_one` |
| LOW-05 | Low | kfarms | Pending withdrawal cooldown overwritten on re-unstake |
| LOW-06 | Low | kfarms | `slashed_amount_current` incremented but never consumed/transferred |
| LOW-07 | Low | scope | CPI protection does not restrict post-refresh instructions (by design) |
| LOW-08 | Low | scope | EMA initialized from single sample (mitigated by min-sample validation) |
| INFO-06 | Info | kvault | Performance fee allows up to 100% (design choice) |
| INFO-07 | Info | kvault | Withdrawal penalty uses max(global, vault) — admin controls floor |
| INFO-08 | Info | scope | TODO note about chain precision for high-decimal prices |
| INFO-09 | Info | scope | `check_execution_ctx` only checks preceding instructions (documented design) |

---

## Conclusion

Kamino Finance demonstrates **exceptional security engineering** across all four programs. The codebase has been through multiple professional audits (OtterSec, Offside Labs, Certora, Sec3) and the defensive patterns are thorough and well-implemented. The multi-layer oracle validation, internal accounting model, CPI protection mechanisms, and consistent protocol-favorable rounding make this one of the strongest DeFi protocol suites reviewed.

**0 Immunefi submissions warranted.**

---

## Detailed Analysis Files

- [klend Analysis](../notes/klend-analysis.md) — 20+ hypotheses, 5 informational
- [Secondary Programs Analysis](../notes/secondary-analysis.md) — 20 hypotheses across kvault/scope/kfarms
- [Cross-Program Analysis](../notes/cross-program-analysis.md) — 8 attack vectors analyzed
