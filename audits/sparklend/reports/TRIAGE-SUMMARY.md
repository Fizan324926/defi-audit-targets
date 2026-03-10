# Spark (SparkLend) Audit Triage Summary

**Date**: 2026-03-01
**Program**: Spark / SparkLend (Immunefi, $5M max, Primacy of Impact)
**In-Scope Impacts**: Direct theft of funds, Permanent freezing, Protocol insolvency, Theft of unclaimed yield
**Out-of-Scope**: Centralization risks, privileged address attacks, third-party oracle issues (but oracle manipulation IS in scope), governance attacks

---

## Audit Coverage

6 parallel agents performed line-by-line review of ALL in-scope source repos (~145 Solidity files):

| Group | Subsystem | Files |
|-------|-----------|-------|
| 1 | ALM Controller Core (MainnetController, ForeignController, RateLimits, OTCBuffer, WEETHModule) | 9 files |
| 2 | ALM Proxy + Integration Libraries (Curve, UniV4, CCTP, LayerZero, PSM, ERC4626, Aave, WEETH) | 14 files |
| 3 | PSM3 (Peg Stability Module 3) | 3 files + 26 test files |
| 4 | Spark Vault V2 (ERC4626 vault) | 2 files + 8 test files |
| 5 | SSR Oracle Cross-Chain (forwarders, adapters, auth oracle) | 12 files |
| 6 | Aave V3 Spark Diffs + Governance/Executor | 17 files |

---

## Raw Findings (Pre-Triage)

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 9 |
| Low | ~34 |
| Informational | ~40 |

---

## Deep-Dive Verification Results

### 1. SSR Oracle No Staleness Protection (G5-M1)
**VERDICT: NOT EXPLOITABLE (working as designed)**
- Extrapolation is intentionally documented in README
- Forwarders are permissionless — anyone can trigger updates
- SSR changes are small, public, and predictable (governance votes)
- Even extreme 5%→0% SSR change over 1hr delay = ~$342 mispricing on $100M TVL
- No staleness checks by design — continuous compounding from stored (ssr, chi, rho)

### 2. Chainlink Adapter Returns block.timestamp as updatedAt (G5-M2)
**VERDICT: NOT EXPLOITABLE within Spark**
- SparkLend's AaveOracle only checks `price > 0`, never checks `updatedAt`
- No impact on internal Spark systems
- Could theoretically affect hypothetical third-party integrations (out of scope)

### 3. SavingsDaiOracle Stale chi (G6-M1)
**VERDICT: NOT EXPLOITABLE (impractical)**
- drip() called extremely frequently (every sDAI deposit/withdrawal + keeper bots)
- 1hr staleness at 11.25% DSR = 0.00128% underpricing ($12.85 per $1M)
- Maximum impact: $768 at 1hr on 60M sDAI supply cap
- Third-party oracle issue (MakerDAO Pot design, not Spark bug)

### 4. OTC Claim Unbounded Sweep (G1-M2)
**VERDICT: NOT A VULNERABILITY (by design)**
- otcClaim only moves tokens inward (OTCBuffer → ALMProxy), never outward
- Relayer cannot redirect to attacker-controlled address
- No rate limit needed on inbound leg — value returns to system
- Test suite explicitly validates this behavior
- Privileged role exclusion applies

---

## All Medium Findings — Triage Disposition

| ID | Finding | Disposition | Reason |
|----|---------|-------------|--------|
| G1-M1 | Non-constant role identifiers in MainnetController | OUT | Style/gas issue, not security |
| G1-M2 | OTC claim unbounded sweep | **ELIMINATED** | By design, inbound only, privileged role |
| G2-M1 | doDelegateCall allows storage overwrite from CONTROLLER | OUT | Requires compromised governance contract |
| G3-M1 | PSM3 donation-based DoS before seed deposit | OUT | Known issue (test exists), operationally mitigated |
| G3-M2 | PSM3 classic inflation attack | OUT | Known issue (team wrote InflationAttack.t.sol) |
| G5-M1 | SSR Oracle no staleness protection | **ELIMINATED** | Working as designed, permissionless updates |
| G5-M2 | Chainlink adapter lies about freshness | **ELIMINATED** | No impact on Spark (updatedAt never checked) |
| G6-M1 | SavingsDaiOracle stale chi | **ELIMINATED** | Third-party oracle issue, negligible impact |
| G6-M2 | Executor DEFAULT_ADMIN_ROLE | OUT | Deployment hygiene, centralization risk |

---

## Cross-Contract & Economic Attack Verification

All 10 cross-system attack vectors investigated:

| Vector | Feasibility | Verdict |
|--------|------------|---------|
| Cross-chain SSR rate arbitrage | 4/10 | ~$342 profit on $100M/1hr delay — not viable |
| ALM-PSM3 front-running | 2/10 | Negligible |
| Flash loan + PSM3 | 2/10 | Zero (oracle-based, not AMM) |
| Cross-venue rate manipulation | 3/10 | Negligible |
| Governance relay front-running | 3/10 | Negligible |
| Cross-chain accounting mismatch | 5/10 | Liveness only, no fund loss |
| Rate limit circumvention multi-chain | 1/10 | Not viable (per-chain limits) |
| SparkVault + PSM3 extraction | 3/10 | Not viable |
| Donation + oracle timing | 3/10 | Negative (loss for attacker) |
| MEV on ALM rebalancing | 6/10 | MEV leakage, not a bug |

---

## Conclusion

**No findings survived verification that meet the Spark program's in-scope impact threshold.**

The Spark codebase demonstrates exceptional security engineering:

1. **PSM3**: Oracle-based pricing (not AMM) eliminates flash loan/sandwich attack surfaces. Thorough invariant and fuzz testing including explicit attack scenario tests (DoSAttack.t.sol, InflationAttack.t.sol).

2. **ALM Controller**: Defense-in-depth with layered security: permissioned roles (RELAYER/FREEZER/ADMIN), per-venue rate limits, reentrancy guards, and threat model documentation assuming full relayer compromise.

3. **SparkVault V2**: Chi-based rate accumulator model (not balance-based) eliminates donation and first-depositor attacks entirely. Continuous compounding via `_rpow` is immune to flash loan manipulation.

4. **SSR Oracle**: Intentional extrapolation design with permissionless forwarders. SSR bounds enforcement, monotonicity checks, and bridge sender validation.

5. **Aave V3 fork**: Minimal, conservative modifications (only two: SC-342 stale-params fix and SC-343 flash-loan-into-borrow deprecation). Upstream security inherits fully.

### Recommendation

No findings are recommended for Immunefi submission. The codebase has clearly been through extensive auditing (referenced at devs.spark.fi/security/security-and-audits) and the custom Spark additions (ALM, PSM3, Vaults V2, SSR Oracle) are well-designed with defense-in-depth throughout.
