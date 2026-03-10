# Reserve Protocol — Comprehensive Security Audit Report

**Date:** 2026-03-02
**Auditor:** Independent Security Researcher
**Scope:** Full protocol — Reserve Protocol (core) + Reserve Index DTF (Folio)
**Result:** **CLEAN — 0 exploitable vulnerabilities found (24+ hypotheses tested)**

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Scope & Methodology](#scope--methodology)
3. [Architecture Overview](#architecture-overview)
4. [Findings Summary](#findings-summary)
5. [Detailed Hypothesis Analysis](#detailed-hypothesis-analysis)
   - [Area 1: Trading & Recollateralization](#area-1-trading--recollateralization)
   - [Area 2: Folio Rebalancing & Trusted Filler](#area-2-folio-rebalancing--trusted-filler)
   - [Area 3: Collateral Plugins & StakingVault](#area-3-collateral-plugins--stakingvault)
   - [Area 4: Governance & Access Control](#area-4-governance--access-control)
6. [Informational Observations](#informational-observations)
7. [Architecture Assessment](#architecture-assessment)
8. [Conclusion](#conclusion)

---

## Executive Summary

The Reserve Protocol (core RToken system + Index DTF/Folio extension) was subjected to a comprehensive security audit covering all major contract systems. After testing 24+ specific attack hypotheses across trading, recollateralization, Folio rebalancing, collateral plugins, staking, governance, and fee distribution, **zero exploitable vulnerabilities were identified**.

The protocol demonstrates exceptional security engineering with defense-in-depth at every layer: global reentrancy protection, conservative fixed-point rounding universally favoring the protocol, multi-check oracle validation with graceful degradation, delayed balance tracking for flash-loan resistance, and era-based governance invalidation.

Two low/informational observations were noted (residual token approvals, first-fee-period undercharging) — neither is exploitable.

---

## Scope & Methodology

### Repositories Audited

| Repository | Path | Description |
|---|---|---|
| Reserve Protocol (core) | `protocol/` | RToken, BackingManager, StRSR, Dutch/Batch auctions, collateral plugins, governance |
| Reserve Index DTF | `reserve-index-dtf/` | Folio token, StakingVault, rebalancing auctions, fee distribution |

### Key Files Analyzed

**Core Protocol:**
- `protocol/contracts/p1/BackingManager.sol` (361 lines) — Rebalancing orchestration & revenue forwarding
- `protocol/contracts/p1/mixins/RecollateralizationLib.sol` (398 lines) — Basket range & trade pair selection
- `protocol/contracts/p1/mixins/Trading.sol` — Trade lifecycle management
- `protocol/contracts/p1/mixins/TradeLib.sol` — Trade preparation math
- `protocol/contracts/p1/Broker.sol` (330 lines) — Trade deployment & violation reporting
- `protocol/contracts/p1/RevenueTrader.sol` — Revenue distribution via auctions
- `protocol/contracts/p1/StRSR.sol` — Staked RSR with ERC20Votes, seizure mechanics
- `protocol/contracts/p1/StRSRVotes.sol` — Snapshot-based voting
- `protocol/contracts/p1/Distributor.sol` — Revenue share distribution
- `protocol/contracts/p1/Deployer.sol` — RToken factory
- `protocol/contracts/plugins/trading/DutchTrade.sol` (484 lines) — 4-phase Dutch auction
- `protocol/contracts/plugins/trading/GnosisTrade.sol` — Batch auction via Gnosis
- `protocol/contracts/plugins/governance/Governance.sol` (204 lines) — OZ Governor with flash-loan protection
- `protocol/contracts/plugins/assets/OracleLib.sol` — Chainlink oracle validation
- `protocol/contracts/plugins/assets/FiatCollateral.sol` — Base collateral with peg monitoring
- `protocol/contracts/plugins/assets/Asset.sol` — Base asset with price timeout decay
- `protocol/contracts/plugins/assets/curve/CurveStableCollateral.sol` — Curve LP pricing
- `protocol/contracts/plugins/assets/curve/CurveRecursiveCollateral.sol` — MEV-resistant Curve pricing
- `protocol/contracts/plugins/assets/curve/PoolTokens.sol` — Curve pool token helpers
- `protocol/contracts/plugins/assets/aave-v3/vendor/StaticATokenV3LM.sol` — Aave V3 wrapper
- `protocol/contracts/plugins/assets/aave-v3/AaveV3FiatCollateral.sol` — Aave V3 collateral
- `protocol/contracts/plugins/assets/compoundv3/CTokenV3Collateral.sol` — Compound V3 collateral
- `protocol/contracts/plugins/assets/compoundv3/CFiatV3Wrapper.sol` — Compound V3 wrapper
- `protocol/contracts/plugins/assets/erc20/RewardableERC20.sol` — Reward distribution base
- `protocol/contracts/plugins/assets/ERC4626FiatCollateral.sol` — Generic ERC4626 collateral
- `protocol/contracts/registry/DAOFeeRegistry.sol` — DAO fee configuration

**Index DTF (Folio):**
- `reserve-index-dtf/contracts/Folio.sol` (1162 lines) — Index DTF backed token
- `reserve-index-dtf/contracts/utils/RebalancingLib.sol` (476 lines) — Auction/bid math
- `reserve-index-dtf/contracts/utils/FolioLib.sol` (167 lines) — Fee computation
- `reserve-index-dtf/contracts/utils/MathLib.sol` (35 lines) — PRB-math wrappers
- `reserve-index-dtf/contracts/utils/Constants.sol` — Protocol constants
- `reserve-index-dtf/contracts/folio/FolioDAOFeeRegistry.sol` (155 lines) — DAO fee registry
- `reserve-index-dtf/contracts/staking/StakingVault.sol` (420 lines) — ERC4626 vault with multi-reward
- `reserve-index-dtf/contracts/staking/UnstakingManager.sol` (80 lines) — Time-locked escrow

### Methodology

1. **Architecture mapping** — Traced all major contract interactions, access control, and state flows
2. **Hypothesis-driven testing** — Formulated 24+ specific attack hypotheses across all contract systems
3. **Line-by-line code tracing** — For each hypothesis, traced exact code paths with rounding, overflow, and reentrancy analysis
4. **Mathematical proofs** — Algebraically proved safety of edge cases (fee underflow, reward handout, exponential price bounds)
5. **Cross-cutting concern analysis** — Verified reentrancy guards, oracle freshness, access control, and ERC20 edge cases across all components

---

## Architecture Overview

### Core Protocol (RToken System)

```
Governance ──► Main (hub) ──► ComponentP1 (globalNonReentrant)
                │
                ├── BackingManager ─── rebalance() ──► Broker ──► DutchTrade / GnosisTrade
                │                  └── forwardRevenue() ──► RevenueTrader ──► Distributor
                │
                ├── BasketHandler ──► CollateralPlugin[] ──► OracleLib (Chainlink)
                │
                ├── StRSR ──► seizure, staking, voting
                │
                └── RToken ──► issuance, redemption, melting
```

### Index DTF (Folio System)

```
Governance (AccessControl) ──► Folio (ERC20, sync modifier)
                                  │
                                  ├── mint() / redeem() ── permissionless, pro-rata
                                  ├── openAuction() / bid() ── Dutch auction rebalancing
                                  ├── createTrustedFill() ── CowSwap integration
                                  ├── distributeFees() ── TVL + mint fees
                                  └── StakingVault (ERC4626) ──► UnstakingManager
```

### Key Defensive Patterns

| Pattern | Implementation | Coverage |
|---|---|---|
| Global reentrancy | `ComponentP1.globalNonReentrant` via `Main._guardCounter` | All core protocol components |
| Conservative rounding | CEIL for protocol-received amounts, FLOOR for protocol-sent amounts | All fixed-point math |
| Oracle validation | 5 checks: roundId, answer>0, updatedAt, staleness, sequencer | All Chainlink reads |
| Flash-loan resistance | Snapshot voting, delayed balances, `startTime = block.timestamp + 1` | Governance, StakingVault, DutchTrade |
| Era invalidation | `era++` on RSR seizure invalidates all pending proposals and stakes | StRSR, Governance |
| Graceful degradation | Price timeout decay, IFFY→DISABLED state machine, try/catch settlements | All collateral, revenue |

---

## Findings Summary

| ID | Severity | Area | Status |
|---|---|---|---|
| INFO-01 | Informational | Folio: Residual token approval after trusted fill | Non-exploitable |
| INFO-02 | Informational | Folio: First fee period undercharges by up to ~24 hours | Non-exploitable |

**Total: 0 exploitable vulnerabilities, 2 informational observations**

---

## Detailed Hypothesis Analysis

### Area 1: Trading & Recollateralization

**Files:** DutchTrade.sol, GnosisTrade.sol, Trading.sol, TradeLib.sol, RecollateralizationLib.sol, BackingManager.sol, Broker.sol, RevenueTrader.sol
**Hypotheses tested: 8 | Exploitable: 0**

#### H1.1: DutchTrade Price Curve Manipulation — FALSE POSITIVE

The 4-phase price curve (geometric 1000x→1.5x, linear 1.5x→1x, linear best→worst, constant worst) is entirely hardcoded. `startTime = block.timestamp + 1` prevents same-block bidding. `_bidAmount` uses CEIL rounding throughout. Phase 4 constant pricing eliminates timestamp manipulation value. Per-block price drop is ~0.04% for 30-minute auctions — minimal MEV.

#### H1.2: TradeLib Rounding Bias — FALSE POSITIVE

Every rounding decision systematically favors the protocol: `prepareTradeSell` uses CEIL for minBuyAmount and FLOOR for sellAmount. `_bidAmount` uses CEIL twice (multiply + shift). `prepareTradeToCoverDeficit` uses CEIL for exactSellAmount. Numerically verified: rounding adds ~1 wei to buy requirements.

#### H1.3: nextTradePair() Manipulation — FALSE POSITIVE

Trade pair selection is purely deterministic from on-chain state. DISABLED > SOUND > IFFY priority prevents oscillating selections. Surplus assessed against `range.top`, deficit against `range.bottom` — prevents double-trading. Token donations create surplus (forwarded as revenue), not exploitable.

#### H1.4: GnosisTrade Minimum Trade Size Bypass — FALSE POSITIVE

`isEnoughToSell()` requires both UoA-based minimum and ≥2 quanta. Gnosis resizing scales both amounts proportionally with defensive rounding. `worstCasePrice` derived from oracle prices — not externally manipulable.

#### H1.5: BackingManager.rebalance() Call Ordering — FALSE POSITIVE

`assetRegistry.refresh()` runs first (current oracle data). `tradeEnd[kind] < block.timestamp` prevents same-block re-auction after settlement. Only one trade at a time (`tradesOpen == 0`). `tradingDelay` enforces configurable delay after basket switches.

#### H1.6: Revenue Distribution Edge Cases — FALSE POSITIVE

Dust retained in `forwardRevenue` is intentional (`tokensPerShare = delta / totalShares` truncation). Revenue cannot be sent to wrong recipients — Distributor destinations are governance-controlled. Failed distribution in `settleTrade()` is caught by try/catch; tokens remain for later distribution.

#### H1.7: DutchTrade bid() Token Amount Edge Cases — FALSE POSITIVE

Double-CEIL in `_bidAmount` ensures bidder always pays ≥ mathematical exact amount. `bidWithCallback()` uses balance-change verification with Solidity 0.8.x underflow protection. `settle()` uses actual balance — any excess goes to protocol.

#### H1.8: Broker.reportViolation() Spurious Disabling — FALSE POSITIVE

Only Broker-cloned trade contracts can call `reportViolation()`. Phase 1 bidding to trigger it costs 1.5x-1000x fair value (self-punishing). Dutch auction disabling limited to BackingManager-originated trades. Governance can re-enable.

---

### Area 2: Folio Rebalancing & Trusted Filler

**Files:** Folio.sol, RebalancingLib.sol, FolioLib.sol, MathLib.sol, Constants.sol, FolioDAOFeeRegistry.sol
**Hypotheses tested: 10 | Exploitable: 0**

#### H2.1: Folio mint/redeem Rounding Exploit — FALSE POSITIVE

`_toAssets()` uses `Math.Rounding.Ceil` for mint (user pays more) and `Math.Rounding.Floor` for redeem (user receives less). `totalSupply()` override includes pending fee shares, preventing dilution of existing holders. Atomic mint-redeem loses ~2 wei per token to rounding — no round-trip profit.

#### H2.2: Exponential Price Decay Overflow — FALSE POSITIVE

`k * elapsed` bounded by `ln(MAX_TOKEN_PRICE_RANGE) = ln(100) ≈ 4.6e18`, well within PRB-math SD59x18 `exp()` domain (max ~133.08e18). `startPrice / endPrice` capped at `MAX_TOKEN_PRICE_RANGE = 1e2`. No overflow possible.

#### H2.3: Trusted Filler Front-Running — FALSE POSITIVE

`sync` modifier calls `_poke()` → `_closeTrustedFill()` before all state-reading operations. `_balanceOfToken()` includes trusted filler balances for accurate NAV. `closeTrustedFill()` tracks traded amounts via balance diffs — surplus goes to protocol. Filler cannot profit by delaying close.

#### H2.4: Fee Computation Underflow — FALSE POSITIVE

Algebraically proved: `correction = ceil(feeFloor * D18 / _tvlFee) ≤ D18` always holds since `feeFloor ≤ _tvlFee` (enforced by DAO fee registry). Therefore `daoShares = feeShares * correction / D18 ≤ feeShares`, preventing underflow in `rawRecipientShares = feeShares - daoShares`.

#### H2.5: Weight/Limit Narrowing Manipulation — FALSE POSITIVE

`startRebalance()` requires `REBALANCE_MANAGER` role. Weight ranges must satisfy `newLow ≤ newHigh` and narrow toward target. Limit ranges must satisfy `spotLimit ∈ [low, high]`. `getBid()` computes sell/buy amounts from weight constraints — manipulation requires governance compromise.

#### H2.6: Auction Timing Manipulation — FALSE POSITIVE

`AUCTION_WARMUP = 30s` prevents same-block bidding after `openAuction()`. `RESTRICTED_AUCTION_BUFFER = 120s` delays unrestricted auctions. Exponential decay ensures early bids pay premium. `_closeTrustedFill()` in `sync` modifier prevents fill/auction overlap.

#### H2.7: First-Depositor Share Inflation — FALSE POSITIVE

Folio inherits OZ ERC4626 with virtual shares/assets (offset = 1). `_toAssets` with `_decimalsOffset()` prevents inflation attack. Additionally, governance must `initialize()` with initial parameters — not permissionless deployment.

#### H2.8: DAO Fee Registry Manipulation — FALSE POSITIVE

Chain-specific max fees: Mainnet/Base 50% DAO + 15bps floor, BNB 33.33% + 10bps. `setFeeRecipient` and `setTokenFeeNumerator` are `DEFAULT_ADMIN_ROLE`-gated. Fee floor enforcement ensures DAO always receives minimum share.

#### H2.9: Rebalance Proposal Griefing — FALSE POSITIVE

Only `REBALANCE_MANAGER` can call `startRebalance()`. `openAuction()` requires `AUCTION_LAUNCHER` role. `openAuctionUnrestricted()` is permissionless but has `RESTRICTED_AUCTION_BUFFER` delay. Auctions have minimum length (`MIN_AUCTION_LENGTH = 120s`).

#### H2.10: Folio ERC20 Transfer Hook Reentrancy — FALSE POSITIVE

Folio uses OZ ERC20Upgradeable — no transfer hooks. All external calls in `mint/redeem/bid` follow checks-effects-interactions. `sync` modifier ensures state consistency before operations.

---

### Area 3: Collateral Plugins & StakingVault

**Files:** All collateral plugins, StakingVault.sol, UnstakingManager.sol, StRSR.sol, RewardableERC20.sol
**Hypotheses tested: 10+ | Exploitable: 0**

#### H3.1: CurveStableCollateral Spot Balance Manipulation — FALSE POSITIVE

Spot balance usage is an acknowledged design tradeoff (TODO comment in code). Mitigated by: (1) stable swap curves are flat — enormous capital needed for measurable impact, (2) hard-default uses `get_virtual_price()` (manipulation-resistant), (3) DutchTrade Phase 1 geometric decay provides 1000x buffer, (4) CurveNG reentrancy guard via `totalSupply()` call.

#### H3.2: CompoundV3 Wrapper Rate Manipulation — FALSE POSITIVE

Comet supply index is protocol-controlled and accrues over time — not flash-manipulable. `accrueAccountRewards()` tracks index deltas correctly. `_withdraw()` truncates to 10-wei granularity (conservative). `div-by-zero` when `totalSupplyBase == 0` causes DISABLED status (safe).

#### H3.3: Aave V3 StaticAToken Rate Mismatch — FALSE POSITIVE

`rate()` reads `getReserveNormalizedIncome()` — Aave liquidity index, monotonically increasing, not flash-manipulable. StaticATokenV3LM was formally verified by BGD Labs. Reserve's `claimRewards()` addition follows CEI pattern. ERC4626 rounding favors the vault.

#### H3.4: StRSR seizeRSR() Accounting — FALSE POSITIVE

Algebraically proved: `rsrRewardsAtLastPayout = rsrRewards() - seizedRSR` cannot underflow. `_payoutRewards()` called first, ensuring stakers receive accumulated rewards before seizure. `beginEra()` correctly zeros stakeRSR/totalStakes and increments era. Total seizure case: `rewardPortion = rewards`, result is 0.

#### H3.5: RewardableERC20Wrapper Reward Theft — FALSE POSITIVE

`claimRewards()` protected by `nonReentrant`. `_beforeTokenTransfer` sets `lastRewardsPerShare[depositor]` to current value BEFORE mint — new depositors only earn from future distributions. 1e9 precision offset prevents dust attacks. Donation attack mitigated by `nonDistributed` accounting.

#### H3.6: StakingVault Flash-Donation — FALSE POSITIVE

Delayed balance tracking (one-cycle lag) prevents flash-donation reward inflation. `_calculateHandout()` rounds down safely: `(1-rewardRatio)^elapsed < 1e18` for all valid inputs (proved). Native rewards use `_currentAccountedNativeRewards()` with `delayedBalance` pattern. `_update()` override triggers `accrueRewards(from, to)` on every transfer.

#### H3.7: Oracle Staleness Exploitation — FALSE POSITIVE

OracleLib enforces 5 distinct checks: roundId > 0, answer > 0, updatedAt > 0, staleness < timeout, sequencer uplink. Graceful price decay over `priceTimeout` (not cliff) when oracle fails. IFFY status blocks issuance. Price spread widens to protect auctions.

#### H3.8: Deployer Malicious Configuration — FALSE POSITIVE

Implementation contracts are immutable (set in Deployer constructor). All component parameters bounded by their `init()` validations. Configuration transparent on-chain. No privilege escalation possible through deployment parameters.

#### H3.9: Strategic refresh() Timing — FALSE POSITIVE

DISABLED is permanent (blocks re-entry to other states). IFFY delay cannot be extended (`if (sum < _whenDefault)` check). Peg checks use Chainlink (not spot prices). `refresh()` is permissionless — anyone can call it.

#### H3.10: Non-Standard ERC20 Edge Cases — FALSE POSITIVE

CompoundV3 wrapper uses principal-change accounting (immune to fee-on-transfer). Rebasing tokens are wrapped before use. `SafeERC20` used throughout. Documentation explicitly requires compatible tokens.

---

### Area 4: Governance & Access Control

**Files:** Governance.sol, StRSRVotes.sol, Main.sol, ComponentP1.sol
**Hypotheses tested: 3 | Exploitable: 0**

#### H4.1: Governance Flash-Loan Voting — FALSE POSITIVE

`MIN_VOTING_DELAY = 86400s` (1 day minimum). Snapshot-based voting (`getPastVotes`) uses past-timestamp snapshots — immune to same-block flash loans. Era system invalidates proposals after RSR seizure events.

#### H4.2: Cross-Component Reentrancy — FALSE POSITIVE

`globalNonReentrant` modifier on all `ComponentP1` functions uses shared `_guardCounter` in `Main`. Even callback patterns (DutchTrade `bidWithCallback`) cannot reenter protocol components. Balance-change verification in callbacks provides additional safety.

#### H4.3: Access Control Escalation — FALSE POSITIVE

Role hierarchy is flat: `DEFAULT_ADMIN_ROLE` (timelock governance), `REBALANCE_MANAGER`, `AUCTION_LAUNCHER`, `BRAND_MANAGER`. No role can grant itself additional permissions. Folio uses OpenZeppelin `AccessControlUpgradeable` with standard role checks.

---

## Informational Observations

### INFO-01: Residual Token Approval After Trusted Fill Closure

**Location:** `Folio.sol` — `_closeTrustedFill()`
**Severity:** Informational (defense-in-depth improvement)

When a trusted fill is closed, token approvals granted to the filler during `createTrustedFill()` are not explicitly revoked. The filler retains a residual approval for any unspent allowance. While the filler is a governance-approved entity (reducing risk), explicitly revoking approvals after fill closure would be a defense-in-depth improvement.

**Impact:** Negligible — filler is trusted and governance-controlled.

### INFO-02: First Fee Period Undercharges by Up to ~24 Hours

**Location:** `FolioLib.sol` — `computeFeeShares()`
**Severity:** Informational (non-exploitable)

Fee computation discretizes to full days: `(block.timestamp / ONE_DAY) * ONE_DAY`. The first fee period after deployment or fee change can be up to ~24 hours shorter than expected, resulting in slightly lower fees collected. This cannot be exploited — the direction of error benefits Folio holders (lower fees), and the magnitude is bounded by one day's worth of TVL fees.

**Impact:** Negligible — at 10% annual TVL fee and $100M TVL, maximum one-time undercharge is ~$27K, which benefits token holders.

---

## Architecture Assessment

### Strengths

1. **Global reentrancy guard** — Shared `_guardCounter` in `Main` prevents all cross-contract reentrancy across core protocol components. This is superior to per-contract guards.

2. **Conservative rounding everywhere** — CEIL for amounts received, FLOOR for amounts sent, applied consistently across all fixed-point operations in both core protocol and Folio.

3. **Multi-layer oracle protection** — Five distinct Chainlink validation checks plus graceful price decay over timeout period (not cliff failure). Stale prices cause IFFY status, blocking issuance while allowing redemption.

4. **Flash-loan resistance by design** — Snapshot voting (past timestamps), delayed balance tracking in StakingVault (one-cycle lag), `startTime = block.timestamp + 1` in DutchTrade, and minimum 1-day voting delay in Governance.

5. **Deterministic auction pricing** — Both DutchTrade (4-phase hardcoded curve) and Folio auctions (exponential decay with bounded parameters) have no external inputs that can modify price evolution.

6. **Era-based invalidation** — RSR seizure events increment `era`, automatically invalidating all pending governance proposals and staking records. Clean state recovery without explicit cleanup.

7. **Defense-in-depth in Folio** — `sync` modifier calls `_poke()` → `_closeTrustedFill()` before every state read, ensuring consistent NAV. `_balanceOfToken()` includes filler balances. `totalSupply()` override includes pending fee shares.

8. **Formal verification** — StaticATokenV3LM (Aave V3 wrapper) was formally verified by BGD Labs, reducing wrapper risk.

### Design Notes (Non-Exploitable)

1. **CurveStableCollateral spot balance usage** — Acknowledged MEV risk (TODO in code). Mitigated by DutchTrade's geometric decay phase. CurveRecursiveCollateral demonstrates the MEV-resistant alternative.

2. **Dust retention** — `forwardRevenue()` retains up to `totalShares - 1` quanta per token. Intentional and documented: "We'd rather save the dust than be unfair."

3. **Trusted filler DoS** — If a governance-approved filler's `closeFiller()` reverts, the DutchTrade contract becomes stuck. Mitigated by `forceSettleTrade()` (governance escape hatch) and governance control over filler registry.

---

## Conclusion

The Reserve Protocol — encompassing both the core RToken system and the Index DTF (Folio) extension — is **exceptionally well-engineered** from a security perspective. After comprehensive analysis of 24+ attack hypotheses across all major contract systems, **zero exploitable vulnerabilities were identified**.

The protocol's security posture is characterized by:

- **Consistent defensive patterns** applied uniformly across all components (rounding, reentrancy, oracle validation)
- **Minimal attack surface** through deterministic pricing, snapshot-based voting, and delayed balance tracking
- **Graceful degradation** via IFFY→DISABLED state machine, price timeout decay, and era-based invalidation
- **Governance escape hatches** (`forceSettleTrade`, `enableBatchTrade`, `enableDutchTrade`) for recovering from unexpected states

The two informational observations (residual approval, first fee period) represent minor defense-in-depth improvements with negligible practical impact.

**Overall Rating: CLEAN — No exploitable vulnerabilities found.**
