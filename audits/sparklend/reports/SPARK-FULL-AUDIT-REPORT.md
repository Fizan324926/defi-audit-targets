# Spark (SparkLend) — Full Security Audit Report

**Date**: 2026-03-01
**Program**: Spark / SparkLend (Immunefi Bug Bounty)
**Program URL**: https://immunefi.com/bug-bounty/sparklend/
**Max Bounty**: USD $5,000,000
**Primacy**: Primacy of Impact
**KYC Required**: No
**PoC Required**: Yes (Critical + High)
**Result**: No submittable findings

---

## Table of Contents

1. [Program Scope](#1-program-scope)
2. [Audit Methodology](#2-audit-methodology)
3. [Codebase Overview](#3-codebase-overview)
4. [Phase 1: First-Pass Audit (6 Agents)](#4-phase-1-first-pass-audit)
5. [Phase 2: Deep-Dive Verification (4 Agents)](#5-phase-2-deep-dive-verification)
6. [Phase 3: Rare Edge-Case Audit (5 Agents)](#6-phase-3-rare-edge-case-audit)
7. [All Findings Catalog](#7-all-findings-catalog)
8. [Triage Disposition Table](#8-triage-disposition-table)
9. [Security Architecture Assessment](#9-security-architecture-assessment)
10. [Why No Submittable Findings](#10-why-no-submittable-findings)
11. [Recommendations for Future Audits](#11-recommendations-for-future-audits)

---

## 1. Program Scope

### In-Scope Impacts

**Smart Contract — Critical ($50K-$5M, 10% of affected funds):**
- Direct theft of user funds (at-rest or in-motion), other than unclaimed yield
- Permanent freezing of funds
- Protocol insolvency

**Smart Contract — High ($10K-$100K):**
- Theft of unclaimed yield
- Permanent freezing of unclaimed yield
- Temporary freezing of funds

### Out-of-Scope

- Attacks requiring access to privileged addresses without additional privilege modifications
- Incorrect data supplied by third-party oracles (but oracle manipulation IS in scope)
- Basic economic and governance attacks (e.g., 51% attack)
- Lack of liquidity, Sybil attacks, centralization risks
- Impacts on test files and configuration files

### In-Scope Assets

150+ deployed smart contracts across 7 chains:
- **Ethereum**: SparkLend (Pool, tokens, logic libs), ALM Controller, SSR Oracle forwarders, Spark Vaults V2, Governance (SparkProxy), Rewards, Treasury
- **Gnosis**: SparkLend deployment, SSR Oracle
- **Arbitrum**: PSM3, ALM Controller/Proxy, SSR/DSR Oracle, Executor
- **Optimism**: PSM3, ALM Controller/Proxy, SSR/DSR Oracle, Executor
- **Base**: PSM3, ALM Controller/Proxy, SSR/DSR Oracle, Executor
- **Unichain**: PSM3, ALM Controller/Proxy, SSR Oracle, Executor
- **Avalanche**: Spark Vault V2, ALM Controller/Proxy, Executor, Rewards

### Source Repositories Audited

| Repository | Files Analyzed | Focus |
|------------|---------------|-------|
| marsfoundation/spark-alm-controller | 23 Solidity files | ALMProxy, MainnetController, ForeignController, RateLimits, 9 integration libraries |
| marsfoundation/xchain-ssr-oracle | 12 Solidity files | SSRAuthOracle, SSRMainnetOracle, SSROracleBase, forwarders, adapters |
| marsfoundation/spark-psm | 3 Solidity files + 26 test files | PSM3 (Peg Stability Module) |
| sparkdotfi/spark-vaults-v2 | 2 Solidity files + 8 test files | SparkVault ERC4626 implementation |
| marsfoundation/aave-v3-core | 102 Solidity files | Pool, PoolConfigurator, all Logic libs, tokens, oracles |
| marsfoundation/sparklend | 2 Solidity files | SavingsDaiOracle, DaiInterestRateStrategy |
| marsfoundation/spark-gov-relay | 2 Solidity files | Executor governance relay |

**Total: ~146 Solidity source files analyzed**

---

## 2. Audit Methodology

### Approach: Three-Phase Multi-Agent Comprehensive Audit

**Phase 1 — Full Codebase Exploration (6 parallel agents)**
Line-by-line review of every in-scope source file, organized by subsystem. Each agent checked the standard vulnerability catalog: access control, reentrancy, arithmetic, input validation, state consistency, cross-contract interactions, and fund extraction paths.

**Phase 2 — Deep-Dive Verification (4 targeted agents)**
Top Medium findings from Phase 1 subjected to independent verification. Each agent traced full call chains, analyzed mathematical constraints, and assessed real-world exploitability against program scope.

**Phase 3 — Rare Edge-Case Audit (5 creative agents)**
Out-of-the-box audit targeting vulnerabilities that conventional pattern matching misses:
- Proxy initialization attacks (uninitialized implementations, selfdestruct)
- Token-specific quirks (USDT approve, fee-on-transfer, 6-vs-18 decimal precision)
- Compiler-specific bugs for exact Solidity versions used
- Assembly code correctness (inline `_rpow`)
- Rate limit state machine mathematical edge cases
- Emergency freeze mechanism bypasses
- Cross-chain governance timing attacks

### Vulnerability Angles Checked

| Category | Specific Checks |
|----------|----------------|
| Access Control | Role-based permissions, privilege escalation, unauthorized state changes |
| Reentrancy | Cross-function, cross-contract, callback-based (ERC777, hooks) |
| Arithmetic | Overflow/underflow, precision loss, rounding direction, unchecked blocks |
| Oracle Manipulation | Stale data, replay, rate manipulation, cross-chain inconsistency |
| Flash Loan Attacks | Share manipulation, rate manipulation, sandwich attacks |
| Proxy/Upgrade | Uninitialized implementations, storage collisions, selfdestruct |
| Cross-Chain | Message spoofing, replay, ordering, accounting mismatches |
| Token Quirks | Non-standard ERC20 (USDT), fee-on-transfer, blacklisting, decimals |
| State Machine | Rate limit bypass, freeze bypass, governance timing, race conditions |
| Economic | Arbitrage, MEV extraction, donation attacks, inflation attacks |
| Compiler | Solidity version-specific bugs, optimizer bugs, ABI encoding |
| EIP Compliance | ERC4626 rounding directions, ERC20 permit replay, encodePacked collisions |

---

## 3. Codebase Overview

### Architecture

```
Ethereum L1
├── SparkLend (Aave V3 Fork)
│   ├── Pool.sol — Core lending pool
│   ├── Logic Libraries — Borrow, Supply, Liquidation, FlashLoan, Bridge, EMode, Pool, Reserve
│   ├── Tokens — AToken, VariableDebtToken, StableDebtToken
│   ├── Oracle — AaveOracle, SavingsDaiOracle
│   └── Config — ACLManager, PoolAddressesProvider, PoolConfigurator
├── ALM Controller (Mainnet)
│   ├── MainnetController.sol — Rate-limited operations (Aave, Curve, PSM, OTC, etc.)
│   ├── ALMProxy.sol — Fund custodian (doCall/doDelegateCall)
│   ├── RateLimits.sol — Per-venue rate limiting state machine
│   └── Libraries — AaveLib, CurveLib, PSMLib, CCTPLib, LayerZeroLib, UniswapV4Lib, etc.
├── SSR Oracle Forwarders — Send SSR data from L1 to each L2
├── Spark Vaults V2 — ERC4626 vault (chi-based rate accumulator)
├── Governance — SparkProxy, FreezerMom, Spells (Freeze, Pause)
└── Tokens — SPK, stSPK

L2 Chains (Arbitrum, Optimism, Base, Unichain, Avalanche)
├── PSM3 — Multi-asset Peg Stability Module (USDC/USDS/sUSDS)
├── ALM Controller (Foreign)
│   ├── ForeignController.sol — Rate-limited L2 operations
│   ├── ALMProxyFreezable.sol — Freezable fund custodian
│   └── Libraries (same as mainnet)
├── SSR Oracle — SSRAuthOracle + adapters (Balancer, Chainlink)
├── Spark Vaults V2 — ERC4626 vault (Avalanche)
└── Governance — Executor.sol (cross-chain governance relay)
```

### Key Design Patterns

1. **Role-Based Access Control**: All sensitive operations require specific roles (RELAYER, FREEZER, CONTROLLER, ADMIN)
2. **Rate Limiting**: Per-venue, per-chain rate limits with slope-based recharge — the primary defense against compromised relayers
3. **Oracle-Based Pricing**: PSM3 uses oracle prices (not AMM curves), eliminating flash loan/sandwich attack surfaces
4. **Chi-Based Rate Accumulator**: SparkVault V2 computes totalAssets from `totalSupply * chi / RAY` (not balance-based), eliminating donation attacks
5. **Threat Model**: ALM Controller explicitly assumes full relayer compromise — system designed to limit damage via rate limits

### Compiler Versions

| Repository | Pragma | Compiled With |
|------------|--------|--------------|
| spark-psm | ^0.8.13 | 0.8.20 |
| spark-alm-controller | ^0.8.21 | 0.8.25 |
| spark-vaults-v2 | ^0.8.25 | 0.8.29 |
| xchain-ssr-oracle | ^0.8.0 | 0.8.25 |
| aave-v3-core | 0.8.10 | 0.8.10 |

---

## 4. Phase 1: First-Pass Audit

### Agent G1: ALM Controller Core

**Files**: MainnetController.sol (1225 lines), ForeignController.sol (561 lines), RateLimits.sol (136 lines), RateLimitHelpers.sol (22 lines), OTCBuffer.sol (39 lines), WEETHModule.sol (49 lines), interfaces (3 files)

**Findings**:
| ID | Severity | Finding |
|----|----------|---------|
| G1-M1 | Medium | Non-constant role/limit identifiers in MainnetController (mutable storage vs constant) |
| G1-M2 | Medium | OTC claim accumulator has no upper bound — relayer can sweep OTCBuffer tokens |
| G1-L1 | Low | Precision loss in OTC for >18 decimal tokens |
| G1-L2 | Low | WEETHModule uses address(this).balance instead of delta calculation |
| G1-L3 | Low | PSM fill loop gas concerns with large arrays |
| G1-L4 | Low | Curve swap rate limit approximation |
| G1-L5 | Low | Potential overflow in getCurrentRateLimit intermediate calculation |
| G1-L6 | Low | UniswapV4 _decreaseLiquidity underflow with fee-on-transfer |
| G1-L7 | Low | OTC rechargeRate18 could be set too high |
| G1-I1-I8 | Info | 8 design observations and style notes |

**Security strengths noted**: ALMProxy only accepts CONTROLLER role, controllers only accept RELAYER/FREEZER/ADMIN, rate limits atomically enforced, nonReentrant on all external state-modifying functions.

---

### Agent G2: ALM Proxy + Integration Libraries

**Files**: ALMProxy.sol, ALMProxyFreezable.sol, 9 library files (AaveLib, ApproveLib, CCTPLib, CurveLib, ERC4626Lib, LayerZeroLib, PSMLib, UniswapV4Lib, WEETHLib), 3 interface files

**Findings**:
| ID | Severity | Finding |
|----|----------|---------|
| G2-M1 | Medium | doDelegateCall allows arbitrary storage manipulation from CONTROLLER |
| G2-L1 | Low | PSMLib potential infinite loop edge case |
| G2-L2 | Low | Permit2 approval timing window |
| G2-L3 | Low | CurveLib rate accounting imprecision |
| G2-L4 | Low | LayerZero minAmountLD trust assumption |
| G2-L5 | Low | UniswapV4 decreasePosition ownership check skip |
| G2-L6 | Low | CCTP bridge message ordering assumption |
| G2-I1-I8 | Info | 8 design observations |

**Security strengths noted**: Libraries interact through proxy.doCall() (not direct delegatecall), slippage protections on all swaps, forceApprove pattern for non-standard tokens.

---

### Agent G3: PSM3 (Peg Stability Module)

**Files**: PSM3.sol (428 lines), IPSM3.sol (326 lines), IRateProviderLike.sol (6 lines), 26 test files (including DoSAttack.t.sol, InflationAttack.t.sol, invariant tests, fuzz tests)

**Findings**:
| ID | Severity | Finding |
|----|----------|---------|
| G3-M1 | Medium | Donation-based DoS — permanent fund lockout via pre-first-deposit donation |
| G3-M2 | Medium | Classic ERC4626 inflation attack before seed deposit |
| G3-L1 | Low | Rounding dust accumulation (by design, favors protocol) |
| G3-L2 | Low | No runtime rate provider validation (trust assumption) |
| G3-L3 | Low | Sequential division precision loss (~$0.000002/operation) |
| G3-L4 | Low | No reentrancy guard (safe with supported tokens) |
| G3-L5 | Low | No recovery mechanism for blacklisted tokens |
| G3-I1-I5 | Info | 5 design observations |

**Security strengths noted**: All rounding consistently favors protocol/LPs (verified by invariant testing), immutable core configuration, correct checks-effects-interactions, most thoroughly tested PSM reviewed — explicit attack scenario tests.

---

### Agent G4: Spark Vault V2

**Files**: SparkVault.sol (561 lines), ISparkVault.sol (170 lines), 8 test files (~1800 lines including fuzz and invariant tests)

**Findings**:
| ID | Severity | Finding |
|----|----------|---------|
| G4-L1 | Low | TAKER_ROLE can cause denial of withdrawals (by design) |
| G4-L2 | Low | previewRedeem/previewWithdraw revert with insufficient liquidity (ERC4626 deviation) |
| G4-L3 | Low | VSR bounds not enforced on initialization |
| G4-L4 | Low | _rpow precision loss (~25 wei/year at max VSR) |
| G4-L5 | Low | take() does not call drip() first |
| G4-L6 | Low | No event emitted on VSR bounds change |
| G4-I1-I6 | Info | 6 design observations |

**Security strengths noted**: Chi-based rate accumulator eliminates ALL balance-manipulation attacks. Share price immune to donation/flash loan. `_disableInitializers()` in constructor. All rounding directions verified correct per ERC4626 spec.

---

### Agent G5: SSR Oracle Cross-Chain

**Files**: SSRAuthOracle.sol, SSRMainnetOracle.sol, SSROracleBase.sol, 2 adapters, 4 forwarders, 3 interfaces, SavingsDaiOracle.sol

**Findings**:
| ID | Severity | Finding |
|----|----------|---------|
| G5-M1 | Medium | No staleness protection — unbounded rate extrapolation |
| G5-M2 | Medium | Chainlink adapter returns block.timestamp as updatedAt (misleading freshness) |
| G5-L1 | Low | SSRMainnetOracle.refresh() uses unsafe truncation (inconsistent with forwarder) |
| G5-L2 | Low | First setSUSDSData() call bypasses all monotonicity checks |
| G5-L3 | Low | SavingsDaiOracle does not drip before reading chi |
| G5-L4 | Low | Overflow analysis — intermediate calculations safe for practical ranges |
| G5-L5 | Low | Bridge sender validation relies on L1 receiver being correctly set |
| G5-I1-I8 | Info | 8 design observations including positive security patterns |

**Security strengths noted**: Monotonicity enforcement (chi/rho never decrease), SSR bounds (lower + optional upper), bridge receiver validates L1 sender, permissionless forwarders allow anyone to update.

---

### Agent G6: Aave V3 Spark Diffs + Governance

**Files**: Pool.sol, LiquidationLogic.sol, BorrowLogic.sol, FlashLoanLogic.sol, SupplyLogic.sol, ValidationLogic.sol, AToken.sol, VariableDebtToken.sol, StableDebtToken.sol, DefaultReserveInterestRateStrategy.sol, EModeLogic.sol, BridgeLogic.sol, GenericLogic.sol, ReserveLogic.sol, AaveOracle.sol, SavingsDaiOracle.sol, Executor.sol

**Spark-specific modifications identified**:
1. **SC-342**: Fixed stale-parameter vulnerability in flash-loan-into-borrow (re-reads pool state from storage)
2. **SC-343**: Complete removal of flash-loan-into-borrow feature (replaced with revert)
3. Added `getReservesCount()` view function
4. Added `pool` field to `FlashloanParams` struct

**Findings**:
| ID | Severity | Finding |
|----|----------|---------|
| G6-M1 | Medium | SavingsDaiOracle stale chi value (reads Pot.chi() without dripping) |
| G6-M2 | Medium | Executor executeDelegateCall accessible to DEFAULT_ADMIN_ROLE |
| G6-L1 | Low | Executor updateDelay has no minimum (can be set to 0) |
| G6-L2 | Low | StableDebtToken mint/burn still possible in Spark fork |
| G6-L3 | Low | No validation that oracle returns fresh data in AaveOracle |
| G6-L4 | Low | Pool revision number not incremented for SC-342 patch |
| G6-L5 | Low | L2Pool calldataLogic delegation could theoretically be abused |
| G6-I1-I5 | Info | 5 design observations |

**Security strengths noted**: Minimal, conservative fork — only 2 substantive changes from upstream Aave v3. Full battle-tested security inherits from Aave. Proper reentrancy guards, access control, and mathematical library usage throughout.

---

## 5. Phase 2: Deep-Dive Verification

### Verification V1: SSR Oracle Staleness (G5-M1)

**VERDICT: NOT EXPLOITABLE — Working as Designed**

- Extrapolation is intentionally documented in README: "you can extrapolate an exact exchange rate to any point in the future for as long as the ssr value does not get updated on mainnet"
- Forwarders are **permissionless** — anyone can trigger an oracle update by calling `refresh()`
- SSR changes are small, public, and predictable (MakerDAO governance votes over multiple days)
- Even extreme 5%→0% SSR change over 1-hour bridge delay creates only ~$342 mispricing on $100M TVL
- SSR can never go below RAY (1e27) — enforced at line 39 of SSRAuthOracle
- No staleness checks exist anywhere in the consumption path — this is by design, not an oversight

---

### Verification V2: OTC Claim Unbounded Sweep (G1-M2)

**VERDICT: NOT A VULNERABILITY — By Design**

- `otcClaim` only moves tokens **inward** (OTCBuffer → ALMProxy), never outward
- Destination is hardcoded to `address(proxy)` — relayer cannot redirect to attacker address
- Relayer has no function to send tokens TO the OTCBuffer — tokens only enter via external exchange deposits
- `claimed18` accumulator intentionally has no cap — serves only as accounting for `isOtcSwapReady()`
- Rate limits protect the **outbound** leg (otcSend), not the inbound leg — architecturally correct
- Test at line 525 of OTCSwaps.t.sol explicitly validates claiming 10M when sent18=0
- Even under full relayer compromise, no value leaves the system
- Program excludes "attacks requiring access to privileged addresses"

---

### Verification V3: SavingsDaiOracle Stale Chi (G6-M1)

**VERDICT: NOT EXPLOITABLE — Impractical Impact**

- drip() is called extremely frequently: every sDAI deposit/withdrawal triggers it, plus keeper bots
- At 11.25% DSR, 1-hour staleness = 0.00128% underpricing ($12.85 per $1M)
- Maximum impact: $768 at 1-hour staleness on 60M sDAI supply cap
- Attacker cannot prevent permissionless drip() calls
- Positions affected would have health factors between 1.0000 and 1.0003 — unrealistically narrow band
- Most likely classified as "third-party oracle issue" (MakerDAO Pot design, not Spark bug)
- Spark's newer SSR Oracle already uses improved extrapolation approach for sUSDS

---

### Verification V4: Cross-Contract Economic Attacks (10 vectors)

**VERDICT: NO VIABLE ATTACK VECTORS**

| # | Attack Vector | Feasibility | Max Profit | Why Blocked |
|---|---------------|-------------|------------|-------------|
| 1 | Cross-chain SSR rate arbitrage | 4/10 | ~$342 on $100M/1hr | Permissionless forwarders, tiny rate differentials |
| 2 | ALM-PSM3 front-running | 2/10 | Negligible | PSM3 is oracle-based, not AMM |
| 3 | Flash loan + PSM3 | 2/10 | $0 | Oracle pricing eliminates flash loan surface |
| 4 | Cross-venue rate manipulation | 3/10 | Negligible | Per-venue rate limits isolate venues |
| 5 | Governance relay front-running | 3/10 | Negligible | Rate limits bound max extractable value |
| 6 | Cross-chain accounting mismatch | 5/10 | N/A | Liveness issue only, no fund loss |
| 7 | Rate limit circumvention multi-chain | 1/10 | N/A | Per-chain independent rate limits |
| 8 | SparkVault + PSM3 extraction | 3/10 | N/A | Different systems with no direct interaction |
| 9 | Donation + oracle timing | 3/10 | Negative | Attacker loses money (rounding against them) |
| 10 | MEV on ALM rebalancing | 6/10 | ~$10K/swap | MEV leakage, not a protocol bug |

---

## 6. Phase 3: Rare Edge-Case Audit

### Edge-Case E1: Proxy Initialization Attacks

**VERDICT: NOT EXPLOITABLE**

- **Aave V3 implementations** (Pool, AToken, VariableDebtToken, StableDebtToken, PoolConfigurator): Use `VersionedInitializable` — CAN be initialized by anyone on the implementation, BUT no `selfdestruct` or `delegatecall` exposed to external callers. Implementation storage is completely isolated from proxy storage.
- **SparkVault.sol**: Calls `_disableInitializers()` in constructor (line 84) — permanently blocks initialization on implementation. Attack impossible.
- **WEETHModule.sol**: Calls `_disableInitializers()` in constructor (line 49). Attack impossible.
- **OTCBuffer.sol**: Calls `_disableInitializers()` in constructor (line 39). Attack impossible.
- **ALMProxy.sol**: Uses constructor-based initialization with AccessControl, not proxy pattern. No initialization vulnerability.
- **Executor.sol**: Constructor-based initialization. No proxy pattern.
- **PoolConfigurator** edge case: `initialize()` accepts arbitrary `IPoolAddressesProvider` without immutable check, but implementation storage is never read by any proxy. Dead end.

---

### Edge-Case E2: Token Quirks and Precision

**VERDICT: NO EXPLOITABLE ISSUES**

- **USDT approve()**: PSM3 never calls `approve()` — only `safeTransfer`/`safeTransferFrom`. ApproveLib correctly implements forceApprove pattern. ForeignController._approve() also uses forceApprove.
- **6-vs-18 decimal precision loss**: Rounding ALWAYS goes against the user in every path (deposits round DOWN shares, withdrawals round UP shares-to-burn). Max error per operation ~$0.000002. Dust accumulates in pool, benefiting LPs.
- **Fee-on-transfer**: PSM3 trusts transfer amounts (no balance before/after check), BUT token addresses are immutable and USDC/USDS/sUSDS don't have transfer fees. Would be critical with fee-on-transfer tokens, but deployment constraints prevent this.
- **USDC blacklisting**: No recovery mechanism — known centralized dependency risk. The `pocket` pattern provides partial mitigation (USDC held externally). Likely out of scope as centralization risk.
- **sUSDS rate edge cases**: At extreme rates, intermediate calculations overflow and revert naturally. Rate provider is immutable and trusted.
- **Zero/max amounts**: All entry points reject zero amounts with explicit `require` checks. Max amounts overflow in intermediate calculations and revert safely.

---

### Edge-Case E3: Compiler Bugs and Assembly

**VERDICT: NO EXPLOITABLE ISSUES**

- **Compiler versions**: Checked all known bugs for 0.8.10, 0.8.20, 0.8.25, 0.8.29. Most relevant: TransientStorageClearingHelperCollision (HIGH, affects 0.8.28-0.8.33 in SparkVault's 0.8.29) — requires `viaIR: true` + transient storage + persistent storage deletion. None of these conditions met.
- **_rpow assembly** (SparkVault + SSROracleBase): Identical implementation, copied from MakerDAO's battle-tested sDAI. All 5 overflow checks verified. Edge cases correct (`x=0,n=0` → RAY; `x=0,n>0` → 0; `x>0,n=0` → RAY). No memory corruption risk.
- **ERC4626 compliance**: All rounding directions correct per spec. One deviation: `previewRedeem`/`previewWithdraw` revert with "insufficient-liquidity" when vault assets are lent out via `take()`. EIP-4626 says preview functions "MUST NOT revert due to vault specific limits" — could break composability but no fund loss.
- **ERC20 permit**: DOMAIN_SEPARATOR computed dynamically with `block.chainid` and `address(this)`. Cross-chain/fork/cross-contract replay all prevented.
- **abi.encodePacked**: All production uses involve only fixed-length types. No collision vectors.
- **Unchecked blocks**: All 15+ unchecked blocks verified safe — each guarded by prior `require` or proven invariant.

---

### Edge-Case E4: Rate Limit Math Edge Cases

**VERDICT: NO EXPLOITABLE ISSUES**

| Edge Case | Result |
|-----------|--------|
| Recharge overflow | Solidity 0.8 checked arithmetic → reverts (DoS), never wraps |
| Reset on reconfiguration | 3-param `setRateLimitData` resets to maxAmount by design; 5-param preserves state |
| Key collision | `abi.encode` (not `encodePacked`) used throughout — computationally infeasible |
| Decrease below zero | `require(amountToDecrease <= currentRateLimit)` at line 100 prevents underflow |
| L2 timestamp manipulation | Standard L2 sequencer trust assumption, not Spark-specific |
| Atomic multi-limit bypass | `nonReentrant` + sequential checks within single function prevent manipulation |
| Zero slope | Works as "one-shot" limit (0 recharge). Correct behavior. |
| Zero maxAmount | Both trigger functions revert with "RateLimits/zero-maxAmount" |
| View vs trigger discrepancy | `triggerRateLimitDecrease` calls `getCurrentRateLimit()` internally — identical |
| Unlimited key bypass | Uninitialized keys have maxAmount=0 → blocks operations (reverts) |

---

### Edge-Case E5: Freeze Bypass and Governance Timing

**VERDICT: NO EXPLOITABLE ISSUES**

- **Freeze mechanism**: Role revocation (not boolean flag). `removeController()` revokes CONTROLLER role, `removeRelayer()` revokes RELAYER role. Two-tier defense-in-depth.
- **Freeze bypass**: No race condition at smart contract level. Mempool race is bounded by rate limits.
- **Rate limit accumulation during freeze**: Rate limits silently recharge to maxAmount during freeze. Operational risk if governance forgets to reset after security incident — but not an attacker-exploitable vulnerability.
- **Executor timelock**: `updateDelay` has no minimum (can be set to 0), but setting it requires passing through current timelock. `_execute()` requires `timelock <= block.timestamp` and `block.timestamp <= timelock + gracePeriod`.
- **Executor replay**: Prevented by `executed = true` flag set before execution (checks-effects-interactions).
- **L1→L2 front-running**: 10-30+ minute bridge transit window exists but old rate limits bound max extractable value.
- **Frozen proxy fund movement**: Comprehensive — all three call functions (doCall, doCallWithValue, doDelegateCall) require CONTROLLER role.

---

## 7. All Findings Catalog

### Summary Counts

| Severity | Phase 1 | Phase 2 Verified | Phase 3 Edge | Total |
|----------|---------|-------------------|--------------|-------|
| Critical | 0 | 0 | 0 | **0** |
| High | 0 | 0 | 0 | **0** |
| Medium | 9 | 0 (all eliminated) | 0 | **9** |
| Low | ~34 | — | ~5 | **~39** |
| Info | ~40 | — | ~10 | **~50** |
| **Submittable** | — | — | — | **0** |

### All Medium Findings Detail

| ID | Finding | Subsystem | Disposition |
|----|---------|-----------|-------------|
| G1-M1 | Non-constant role/limit identifiers in MainnetController | ALM Controller | OUT — Gas/style issue, not security impact |
| G1-M2 | OTC claim accumulator has no upper bound | ALM Controller | ELIMINATED — By design, inbound only, privileged role |
| G2-M1 | doDelegateCall allows arbitrary storage manipulation from CONTROLLER | ALM Proxy | OUT — Requires compromised governance-deployed contract |
| G3-M1 | Donation-based DoS before seed deposit | PSM3 | OUT — Known issue (team wrote DoSAttack.t.sol), operationally mitigated |
| G3-M2 | Classic ERC4626 inflation attack before seed deposit | PSM3 | OUT — Known issue (team wrote InflationAttack.t.sol), operationally mitigated |
| G5-M1 | SSR Oracle no staleness protection — unbounded extrapolation | SSR Oracle | ELIMINATED — Intentional design, permissionless updates, documented |
| G5-M2 | Chainlink adapter returns block.timestamp as updatedAt | SSR Oracle | ELIMINATED — No impact on Spark (updatedAt never checked internally) |
| G6-M1 | SavingsDaiOracle reads stale chi without dripping | Aave V3 | ELIMINATED — Third-party oracle issue, negligible impact ($768 max) |
| G6-M2 | Executor executeDelegateCall accessible to DEFAULT_ADMIN_ROLE | Governance | OUT — Deployment hygiene / centralization risk (excluded) |

---

## 8. Triage Disposition Table

| Disposition | Count | Criteria |
|-------------|-------|----------|
| **ELIMINATED (verified false/non-exploitable)** | 4 | Deep-dive proved not exploitable or working as designed |
| **OUT (not in scope)** | 5 | Centralization risk, known issue, privileged access, third-party oracle |
| **SUBMITTABLE** | 0 | None met in-scope impact threshold |

---

## 9. Security Architecture Assessment

### Positive Security Patterns

1. **Defense-in-Depth**: Every subsystem has multiple independent security layers
2. **Rate Limiting as Primary Defense**: The ALM Controller assumes full relayer compromise — rate limits bound maximum damage regardless of attacker capability
3. **Oracle-Based Pricing (PSM3)**: Eliminates the entire flash loan / sandwich / MEV attack class that plagues AMM-based systems
4. **Chi-Based Rate Accumulator (SparkVault V2)**: Eliminates the entire donation / first-depositor / share inflation attack class
5. **Immutable Configurations**: Token addresses, rate providers in PSM3 are immutable — reduces governance attack surface
6. **Comprehensive Testing**: PSM3 has explicit attack scenario tests (DoSAttack.t.sol, InflationAttack.t.sol), SparkVault has invariant and fuzz tests
7. **Minimal Fork Modifications**: Only 2 substantive changes to Aave V3 — inherits full battle-tested security
8. **Permissionless Oracle Updates**: SSR forwarders are permissionless — prevents oracle staleness
9. **Threat Model Documentation**: ALM Controller has explicit THREAT_MODEL.md assuming worst-case compromise scenarios
10. **Consistent Rounding**: All rounding consistently favors the protocol across all subsystems

### Attack Surface Ranking (by residual risk)

1. **ALM Controller rate limit configuration** — Misconfigured rate limits could allow excessive extraction (operational risk)
2. **PSM3 deployment process** — Missing seed deposit would enable donation-based DoS (operational risk)
3. **Cross-chain governance latency** — 10-30 minute bridge transit creates a front-running window (bounded by rate limits)
4. **USDC centralized dependency** — Circle blacklisting could freeze PSM3 USDC holdings (centralization risk, out of scope)

---

## 10. Why No Submittable Findings

### The Honest Assessment

After 15 agents analyzing ~146 Solidity files across three increasingly creative audit phases, we found zero findings meeting Immunefi's in-scope impact threshold. Here's why:

1. **Professional security audits already completed**: The team references completed audits at devs.spark.fi/security/security-and-audits. Cantina and ChainSecurity have reviewed the code.

2. **Defensive architecture neutralizes common attack classes**:
   - PSM3's oracle-based pricing eliminates flash loan attacks
   - SparkVault's chi model eliminates donation/inflation attacks
   - Rate limits cap all relayer operations regardless of compromise

3. **Known issues are acknowledged and mitigated**: The team explicitly wrote test cases for the PSM3 donation attack and inflation attack — they know about them and mitigate operationally.

4. **Minimal custom code surface**: The Aave V3 fork is nearly identical to upstream (2 patches). The custom Spark additions (ALM, PSM3, Vaults V2, SSR Oracle) are each relatively focused contracts with clear security boundaries.

5. **The scope explicitly excludes the most likely finding types**: Centralization risks, privileged access attacks, third-party oracle issues, and governance attacks are all out of scope — these are the categories where residual risk remains.

---

## 11. Recommendations for Future Audits

If revisiting Spark in the future, focus on:

1. **On-chain deployed configuration**: Check actual rate limit values, role assignments, and proxy admin settings via RPC calls — configuration mistakes are harder to find from source code alone
2. **New code additions**: Monitor the marsfoundation GitHub for new contracts or significant changes
3. **Web application**: The Spark web app bounty ($5K-$50K) at app.spark.fi is a different attack surface entirely
4. **Cross-chain operational gaps**: Monitor for situations where oracle forwarders stop being called or bridge messages fail
5. **Token listing events**: When new tokens are added to SparkLend or PSM3, the integration assumptions may not hold

---

## Appendix: Agent Reports

All detailed agent reports are archived at:

```
/root/immunefi/audits/sparklend/agent-reports/
├── group1-alm-controller-core.md      (Phase 1)
├── group2-alm-proxy-libs.md           (Phase 1)
├── group3-psm3.md                     (Phase 1)
├── group4-spark-vault-v2.md           (Phase 1)
├── group5-ssr-oracle.md               (Phase 1)
├── group6-aave-v3-spark-diffs.md      (Phase 1)
├── deepdive-ssr-staleness.md          (Phase 2)
├── deepdive-otc-claim.md              (Phase 2)
├── deepdive-sdai-oracle.md            (Phase 2)
├── deepdive-cross-contract.md         (Phase 2)
├── rare-proxy-init.md                 (Phase 3)
├── rare-token-precision.md            (Phase 3)
├── rare-compiler-assembly.md          (Phase 3)
├── rare-ratelimit-math.md             (Phase 3)
└── rare-freeze-governance.md          (Phase 3)
```

---

*Report generated 2026-03-01. 15 total audit agents, ~146 Solidity files, 3 audit phases, 0 submittable findings.*
