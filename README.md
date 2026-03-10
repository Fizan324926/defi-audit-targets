# defi-audit-targets

Research repository for identifying and prioritizing Immunefi bug bounty programs best suited for code-audit-style vulnerability research, and publishing findings from active audits.

---

## Reference Guides

| Guide | Purpose |
|-------|---------|
| [`AUDIT-AI-RULES.md`](AUDIT-AI-RULES.md) | **AI audit methodology** — full process: scope determination, codebase exploration, multi-angle analysis, exploit development, reporting, repo organization, and complete vulnerability catalog |
| [`IMMUNEFI-REPORT-GUIDE.md`](IMMUNEFI-REPORT-GUIDE.md) | Report format, PoC requirements, severity classification, submission rules, and negotiation guide |

---

## All Audits

| Program | Max Bounty | Language | Findings | Audit Folder | Status |
|---------|-----------|----------|----------|--------------|--------|
| [LayerZero](https://immunefi.com/bug-bounty/layerzero/) | $15,000,000 | Solidity + Rust | 0 (clean audit) | [`audits/layerzero/`](audits/layerzero/AUDIT-REPORT.md) | Complete |
| [Sky (MakerDAO)](https://immunefi.com/bug-bounty/sky/) | $10,000,000 | Solidity | 1 High, 2 Medium | [`audits/sky/`](audits/sky/README.md) | Complete |
| [GMX V2 Synthetics](https://immunefi.com/bug-bounty/gmx/) | $5,000,000 | Solidity | 2 High | [`audits/gmx-synthetics/`](audits/gmx-synthetics/README.md) | Complete |
| [Optimism](https://immunefi.com/bug-bounty/optimism/) | $2,000,042 | Solidity + Go | 1 Medium | [`audits/optimism/`](audits/optimism/README.md) | Complete |
| [Olympus DAO](https://immunefi.com/bug-bounty/olympus/) | $3,333,333 | Solidity | 1 Medium-High, 5 Medium | [`audits/olympus-dao/`](audits/olympus-dao/bophades/findings/AUDIT-REPORT.md) | Complete |
| [Orca Whirlpool](https://immunefi.com/bug-bounty/orca/) | $500,000 | Rust / Solana | 1 Medium (borderline) | [`audits/orca-whirlpool/`](audits/orca-whirlpool/README.md) | Complete |
| [Beanstalk](https://immunefi.com/bug-bounty/beanstalk/) | $1,100,000 | Solidity | 1 Medium-High | [`audits/beanstalk/`](audits/beanstalk/findings/AUDIT-REPORT.md) | Complete |
| [Gearbox V3](https://immunefi.com/bug-bounty/gearbox/) | $200,000 | Solidity | 0 (clean audit) | [`audits/gearbox/`](audits/gearbox/AUDIT-REPORT.md) | Complete |
| [Reserve Protocol](https://immunefi.com/bug-bounty/reserve/) | $500,000 | Solidity | 0 (clean audit) | [`audits/reserve-protocol/`](audits/reserve-protocol/findings/AUDIT-REPORT.md) | Complete |
| [Gains Network](https://immunefi.com/bug-bounty/gains-network/) | $200,000 | Solidity | 0 (clean audit) | [`audits/gains-network/`](audits/gains-network/findings/AUDIT-REPORT.md) | Complete |
| [Kamino Finance](https://immunefi.com/bug-bounty/kamino/) | $100,000 | Rust / Solana | 1 High, 2 Low-Medium, 2 Low | [`audits/kamino/`](audits/kamino/findings/AUDIT-REPORT.md) | Complete |

---

## All Confirmed Findings (Quick Reference)

| # | Program | ID | Severity | Title | Report |
|---|---------|-----|----------|-------|--------|
| 1 | Sky | 001 | **HIGH** | `setRewardsDuration` mid-period truncation destroys staker yield | [Report](audits/sky/findings/001-staking-rewards-duration-yield-loss.md) |
| 2 | Sky | 002 | **MEDIUM** | `kick()` reverts when `farm==address(0)` + `burn<WAD` | [Report](audits/sky/findings/002-splitter-farm-zero-dos.md) |
| 3 | Sky | 003 | **MEDIUM** | `setRewardsDuration(0)` bricks reward distribution | [Report](audits/sky/findings/003-staking-rewards-zero-duration.md) |
| 4 | GMX | VULN-003 | **HIGH** | Relay fee swap hardcodes `minOutputAmount=0` (zero slippage) | [Report](audits/gmx-synthetics/exploits/VULN-003-relay-fee-swap-zero-slippage.md) |
| 5 | GMX | VULN-011 | **HIGH** | Missing sequential nonce — keeper reorders/skips relay txns | [Report](audits/gmx-synthetics/exploits/VULN-011-missing-relay-nonce-validation.md) |
| 6 | Optimism | M-01 | **MEDIUM** | `SuperFaultDisputeGame.closeGame()` blocks credit claims during pause | [Report](audits/optimism/findings/IMMUNEFI-SUBMISSION-M01.md) |
| 7 | Orca | H-02 | **MEDIUM** | Protocol fee counter wrapping overflow — silent revenue loss | [Report](audits/orca-whirlpool/findings/H-02-protocol-fee-wrapping-overflow.md) |
| 8 | Olympus | 011 | **MED-HIGH** | CCIP Bridge missing ERC20 rescue — OHM permanently stuck | [Report](audits/olympus-dao/bophades/findings/IMMUNEFI-SUBMISSION-011.md) |
| 9 | Olympus | 012 | **MEDIUM** | LZ Bridge incomplete shutdown — `bridgeActive` doesn't block mints | [Report](audits/olympus-dao/bophades/findings/IMMUNEFI-SUBMISSION-012.md) |
| 10 | Olympus | 005 | **MEDIUM** | Clearinghouse `rebalance()` fund-time accumulation | [Report](audits/olympus-dao/bophades/findings/IMMUNEFI-SUBMISSION-005.md) |
| 11 | Olympus | 008 | **MEDIUM** | Stale price oracle wall swap arbitrage (24h window) | [Report](audits/olympus-dao/bophades/findings/IMMUNEFI-SUBMISSION-008.md) |
| 12 | Olympus | 010 | **MEDIUM** | Heart beat front-running via predictable price updates | [Report](audits/olympus-dao/bophades/findings/IMMUNEFI-SUBMISSION-010.md) |
| 13 | Olympus | 001 | **MEDIUM** | YieldRepo hardcoded `backingPerToken` ($11.33) | [Report](audits/olympus-dao/bophades/findings/IMMUNEFI-SUBMISSION-001.md) |
| 14 | Beanstalk | 001 | **MED-HIGH** | SOP/Flood zero-slippage swap + manipulable spot deltaB | [Report](audits/beanstalk/findings/IMMUNEFI-SUBMISSION-001.md) |

| 15 | Kamino | 002 | **HIGH** | Permissionless crank exploits missing multiplier validation to corrupt xStocks prices | [Report](audits/kamino/findings/IMMUNEFI-SUBMISSION-002.md) |
| 16 | Kamino | 001 | **LOW-MED** | ChainlinkX v10 ignores `tokenized_price` — manual `price * multiplier` may diverge | [Report](audits/kamino/findings/IMMUNEFI-SUBMISSION-001.md) |

**Total: 4 High, 2 Medium-High, 9 Medium, 1 Low-Medium across 11 protocols** (LayerZero + Gearbox V3 + Reserve Protocol + Gains Network: clean audits — 0 findings)

---

## Audits

### Orca Whirlpool — [`audits/orca-whirlpool/`](audits/orca-whirlpool/README.md)

Concentrated liquidity AMM on Solana (Uniswap V3-style). Covers the adaptive fee system, Pinocchio hot-path rewrite, lock position feature, extension segment storage, and Token-2022 integrations.

**Findings:**

| ID | Severity | Description |
|----|----------|-------------|
| [H-01](audits/orca-whirlpool/findings/H-01-adaptive-fee-u32-underflow.md) | Low | Unsafe u32 subtraction in adaptive fee range calc — invariant maintained |
| [H-02](audits/orca-whirlpool/findings/H-02-protocol-fee-wrapping-overflow.md) | Medium | `wrapping_add` on protocol fee counter — silent revenue loss |
| [M-01](audits/orca-whirlpool/findings/M-01-migrate-production-panic.md) | Medium | Production `panic!` in migrate instruction — untyped error |
| [M-02](audits/orca-whirlpool/findings/M-02-extension-segment-expect-dos.md) | Medium | `.expect()` on Borsh deserialize — permanent pool DoS risk |

**Exploit writeups:**
- [H-02 exploit](audits/orca-whirlpool/findings/exploits/H-02-exploit.md)
- [M-01 exploit](audits/orca-whirlpool/findings/exploits/M-01-exploit.md)
- [M-02 exploit](audits/orca-whirlpool/findings/exploits/M-02-exploit.md)

**Verification scripts:** `audits/orca-whirlpool/scripts/verify/`

---

### Sky Protocol — [`audits/sky/`](audits/sky/README.md)

One of the largest DeFi protocols ($8B+ TVL). CDP stablecoin (DAI/USDS), savings vaults, lockstake governance staking, surplus buyback engine, cross-chain bridges.

**Findings:**

| ID | Severity | Contract | Description |
|----|----------|----------|-------------|
| [001](audits/sky/findings/001-staking-rewards-duration-yield-loss.md) | High | StakingRewards.sol | `setRewardsDuration` mid-period integer truncation destroys staker yield |
| [002](audits/sky/findings/002-splitter-farm-zero-dos.md) | Medium | Splitter.sol | `kick()` reverts when `farm==address(0)` + `burn<WAD`, DoSing SBE |
| [003](audits/sky/findings/003-staking-rewards-zero-duration.md) | Medium | StakingRewards.sol | `setRewardsDuration(0)` permanently bricks reward distribution |
| [004](audits/sky/findings/004-lockstake-lock-no-auth.md) | Medium | LockstakeEngine.sol | `lock()` uses `_getUrn` instead of `_getAuthedUrn` — unauthorized urn manipulation |

---

### Optimism — [`audits/optimism/`](audits/optimism/README.md)

L2 rollup with fault proof system. 162 Solidity files + Go op-node code covering bridges, dispute games, Cannon MIPS64 VM, and superchain interop. Two full audit passes: 120+ vectors investigated.

**Confirmed Findings (1 of 120+):**

| ID | Severity | Contract | Description |
|----|----------|----------|-------------|
| [M-01](audits/optimism/findings/IMMUNEFI-SUBMISSION-M01.md) | Medium | SuperFaultDisputeGame.sol | `closeGame()` pause check before early return blocks `claimCredit()` during system pause |

**Immunefi submission:** [`IMMUNEFI-SUBMISSION-M01.md`](audits/optimism/findings/IMMUNEFI-SUBMISSION-M01.md) (copy-paste ready)
**PoC:** [`PoC_M01_CloseGameOrdering.sol`](audits/optimism/scripts/verify/PoC_M01_CloseGameOrdering.sol) (Foundry test)
**Full audit report:** [`AUDIT-REPORT.md`](audits/optimism/findings/AUDIT-REPORT.md)

---

### Olympus DAO (Bophades) — [`audits/olympus-dao/`](audits/olympus-dao/bophades/findings/AUDIT-REPORT.md)

Kernel-Module-Policy architecture DeFi protocol. OHM token with Range Bound Stability, MonoCooler lending, cross-chain bridges (LayerZero + Chainlink CCIP), yield repurchase, emission management. 50+ contracts, 15,000+ LOC.

**Findings (13 total — 6 Immunefi-submittable):**

| ID | Severity | Contract | Description |
|----|----------|----------|-------------|
| [011](audits/olympus-dao/bophades/findings/IMMUNEFI-SUBMISSION-011.md) | Medium-High | CCIPCrossChainBridge | `withdraw()` only rescues ETH — OHM permanently stuck after failed messages |
| [012](audits/olympus-dao/bophades/findings/IMMUNEFI-SUBMISSION-012.md) | Medium | CrossChainBridge | `bridgeActive` not checked on receive — incomplete emergency shutdown |
| [005](audits/olympus-dao/bophades/findings/IMMUNEFI-SUBMISSION-005.md) | Medium | Clearinghouse | `rebalance()` fund-time accumulation — borrow 54M+ in one block |
| [008](audits/olympus-dao/bophades/findings/IMMUNEFI-SUBMISSION-008.md) | Medium | Operator | Stale price oracle enables wall swap arbitrage within 24h window |
| [010](audits/olympus-dao/bophades/findings/IMMUNEFI-SUBMISSION-010.md) | Medium | Heart/PRICE | Predictable MA updates enable heart beat front-running |
| [001](audits/olympus-dao/bophades/findings/IMMUNEFI-SUBMISSION-001.md) | Medium | YieldRepurchaseFacility | Hardcoded `backingPerToken` ($11.33) diverges from actual backing |

**Additional low-severity findings:** EmissionManager precision loss, Kernel migration stale state, DLGTE OZ internals, Clearinghouse keeper reward accounting, Operator regenerate desync, fullCapacity over-estimation, ConvertibleDepositAuctioneer tick decay.

**Notable safe areas:** MonoCooler (0 findings — exceptionally well-engineered), CoolerLtvOracle, SafeCast, FullMath.

**Full audit report:** [`AUDIT-REPORT.md`](audits/olympus-dao/bophades/findings/AUDIT-REPORT.md)
**Immunefi submissions:** `audits/olympus-dao/bophades/findings/IMMUNEFI-SUBMISSION-001.md` through `013.md`
**PoC files:** `audits/olympus-dao/bophades/scripts/verify/`

---

### Beanstalk Protocol — [`audits/beanstalk/`](audits/beanstalk/findings/AUDIT-REPORT.md)

Credit-based stablecoin protocol on Arbitrum. EIP-2535 Diamond proxy with 37+ facets, Basin DEX (Wells, Pumps), Pipeline, and Tractor automation. 226 Beanstalk + 120 Basin Solidity files covering Silo (deposits/stalk/seeds), Field (pods/soil), Barn (fertilizer), Convert, Season/Sunrise, Flood/SOP, Gauge, and cross-cutting systems.

**Findings (1 confirmed — 60+ hypotheses tested):**

| ID | Severity | Contract | Description |
|----|----------|----------|-------------|
| [001](audits/beanstalk/findings/IMMUNEFI-SUBMISSION-001.md) | Medium-High | LibFlood.sol | SOP/Flood zero-slippage swap + manipulable spot deltaB |

**Basin observations (2):** Pump silent update failure (Medium), Stable2 Newton oscillation (Low).

**Notable safe areas:** Tractor EIP-712 (bounds checking verified), Farm multicall (dual reentrancy guard), Convert capacity (TWAP-protected), BDV calculation (EMA-protected), Diamond admin, Germination system.

**Key false positive eliminated:** `calculateSopPerWell` division by zero — mathematically proved unreachable (shaveToLevel bounded by guard condition).

**Full audit report:** [`AUDIT-REPORT.md`](audits/beanstalk/findings/AUDIT-REPORT.md)
**Season/Sun sub-report:** [`SEASON-SUN-AUDIT-REPORT.md`](audits/beanstalk/findings/SEASON-SUN-AUDIT-REPORT.md)
**Immunefi submission:** [`IMMUNEFI-SUBMISSION-001.md`](audits/beanstalk/findings/IMMUNEFI-SUBMISSION-001.md)
**PoC:** [`PoC_001_SopFloodZeroSlippage.sol`](audits/beanstalk/scripts/verify/PoC_001_SopFloodZeroSlippage.sol)

---

### GMX V2 Synthetics — [`audits/gmx-synthetics/`](audits/gmx-synthetics/README.md)

Decentralized perpetual exchange on Arbitrum/Avalanche ($265-400M TVL, ~$270M daily volume). Covers the Gelato relay system ("GMX Express") for gasless transactions, LayerZero cross-chain bridging, oracle price validation, and position management.

**Both vulnerabilities confirmed LIVE on Arbitrum mainnet** — 230,062+ relay transactions processed since November 2025, ~2,212 txns/day.

**Confirmed Findings (2 of 20 initial — 18 eliminated as false positives):**

| ID | Severity | Description | Estimated Annual Impact |
|----|----------|-------------|------------------------|
| [VULN-003](audits/gmx-synthetics/exploits/VULN-003-relay-fee-swap-zero-slippage.md) | High | `minOutputAmount: 0` hardcoded in relay fee swap — unprotected slippage | $74K-$297K (volatility) |
| [VULN-011](audits/gmx-synthetics/exploits/VULN-011-missing-relay-nonce-validation.md) | High | Random (not sequential) relay nonce — keeper can reorder/skip transactions | $26M+ risk exposure |

**Exploit writeups (with verification script output and on-chain data):**
- [VULN-003 exploit](audits/gmx-synthetics/exploits/VULN-003-relay-fee-swap-zero-slippage.md) — loss tables from price volatility, MEV sandwich model, on-chain deployment proof
- [VULN-011 exploit](audits/gmx-synthetics/exploits/VULN-011-missing-relay-nonce-validation.md) — reordering/skipping demo, cancellation impossibility, real-world damage scenarios

**Verification scripts:** `audits/gmx-synthetics/scripts/`

**False positive analysis:** `audits/gmx-synthetics/exploits/false-positives/` (18 findings with detailed elimination rationale)

### Gearbox Protocol V3 — [`audits/gearbox/`](audits/gearbox/AUDIT-REPORT.md)

Generalized leverage protocol for DeFi. 552 Solidity files across 5 repos: core-v3 (credit accounts, pools, oracles), integrations-v3 (19 protocol adapters), oracles-v3 (LP/composite/updatable price feeds), governance (Governor + timelock), periphery-v3 (zappers, routers, liquidators).

**Result: Clean audit — 0 exploitable vulnerabilities found across ~59 hypotheses.**

The codebase demonstrates exceptional defense-in-depth: accounting-based ERC4626 (immune to donation attacks), same-block debt change protection, dual reentrancy guards, epoch-locked GEAR staking for governance, bounded LP price feeds, safe pricing with reserve feeds, and granular bot permissions.

**Low/Informational observations only:**

| Area | Severity | Description |
|------|----------|-------------|
| PythPriceFeed | Low | Negative price passes confidence check (caught by consumer-level validation) |
| CurveTWAPPriceFeed | Informational | Division-by-zero if Curve pool oracle returns 0 (practically impossible) |

**Full audit report:** [`AUDIT-REPORT.md`](audits/gearbox/AUDIT-REPORT.md)

---

### LayerZero Protocol — [`audits/layerzero/`](audits/layerzero/AUDIT-REPORT.md)

Cross-chain messaging protocol with $15M max Immunefi bounty. V1 (EVM) + V2 (EVM + Solana) covering EndpointV2, DVN verification, OFT token bridges, Executor delivery, and 50+ chain deployments. 60+ Solidity contracts + 20+ Solana Rust programs, ~15,000+ LOC.

**Result: Clean audit — 0 exploitable vulnerabilities found across 107+ hypotheses.**

The protocol demonstrates exceptionally mature defense-in-depth: multi-DVN verification model (required + optional threshold), DVN address binding via msg.sender, lazy inbound nonces with payload hash verification, two-phase compose (store-then-execute), immutable endpoint/token references, role-based ACL with denylist priority, and lossless OFT decimal conversion.

**Low/Informational observations only:**

| Area | Severity | Description |
|------|----------|-------------|
| PriceFeed `_estimateFeeByEid()` | Low | Double-computation for L2 eids (mitigated by explicit config) |
| OFTCore `_toSD()` | Low | Silent uint64 truncation (already fixed in devtools version) |

**Full audit report:** [`AUDIT-REPORT.md`](audits/layerzero/AUDIT-REPORT.md)
**Sub-reports:** [`DVN/Executor/Worker`](audits/layerzero/findings/AUDIT-REPORT-DVN-EXECUTOR-WORKER-2026-03-02.md) | [`OFT/OApp`](audits/layerzero/findings/AUDIT-REPORT-OFT-OAPP-2026-03-02.md)
**False positive documentation:** `audits/layerzero/notes/false-positives/` (7 detailed writeups)

### Kamino Finance — [`audits/kamino/`](audits/kamino/findings/AUDIT-REPORT.md)

Solana DeFi protocol suite: lending (klend), yield vaults (kvault), oracle aggregation (scope), and farming/staking (kfarms). 4 Anchor programs, ~43,700 LOC Rust. Covers reserves, obligations, elevation groups, flash loans, withdrawal queues, ERC4626-like vaults, 40+ oracle types with TWAP/chain pricing, and delegated farming with warmup/cooldown. Two audit passes: 80+ hypotheses, per-instruction access control matrix, cross-adapter comparison, external data field tracing, exploit pattern matching.

**Result: 1 High, 2 Low-Medium, 2 Low, 8+ Informational findings. 2 Immunefi submissions.**

The klend, kvault, and kfarms programs demonstrate exceptional defense-in-depth. The Scope oracle program has critical gaps in the ChainlinkX (v10) adapter — missing multiplier validation, missing CPI protection, and ignored cross-reference fields create a compound vulnerability exploitable during corporate action windows.

**Findings:**

| ID | Severity | Program | Description |
|----|----------|---------|-------------|
| [002](audits/kamino/findings/IMMUNEFI-SUBMISSION-002.md) | **High** | scope | Permissionless crank exploits missing multiplier validation in v10 to corrupt xStocks prices — 3 entries with zero protection, `activation_date_time=0` bypass, $5-20M TVL at risk |
| [001](audits/kamino/findings/IMMUNEFI-SUBMISSION-001.md) | Low-Medium | scope | ChainlinkX v10 ignores `tokenized_price` field — manual `price * current_multiplier` may diverge from Chainlink's pre-computed "24/7 tokenized equity price" |
| FINDING-02 | Low-Medium | scope | Missing `check_execution_ctx` CPI protection on `refresh_chainlink_price` (asymmetric with `refresh_price_list`) |
| FINDING-03 | Low | scope | Missing `check_execution_ctx` CPI protection on `refresh_pyth_lazer_price` |
| FINDING-04 | Low | scope | Chainlink refresh path bypasses zero-price guard — v10 `current_multiplier = 0` would store zero price |

**Full audit report:** [`AUDIT-REPORT.md`](audits/kamino/findings/AUDIT-REPORT.md)
**Immunefi submissions:** [`IMMUNEFI-SUBMISSION-001.md`](audits/kamino/findings/IMMUNEFI-SUBMISSION-001.md), [`IMMUNEFI-SUBMISSION-002.md`](audits/kamino/findings/IMMUNEFI-SUBMISSION-002.md)
**Analysis files:** [`klend`](audits/kamino/notes/klend-analysis.md) | [`kvault/scope/kfarms`](audits/kamino/notes/secondary-analysis.md) | [`Cross-program`](audits/kamino/notes/cross-program-analysis.md) | [`Re-audit notes`](audits/kamino/notes/reaudit-instruction-matrix.md)

---

### Reserve Protocol — [`audits/reserve-protocol/`](audits/reserve-protocol/findings/AUDIT-REPORT.md)

Two-repo protocol: core RToken system (BackingManager, StRSR, Dutch/Batch auctions, 15+ collateral plugins, governance) + Index DTF/Folio extension (index token, StakingVault, rebalancing auctions, trusted filler/CowSwap integration, fee distribution). 1000+ Solidity files across `protocol/` and `reserve-index-dtf/`.

**Result: Clean audit — 0 exploitable vulnerabilities found across 24+ hypotheses.**

The protocol demonstrates exceptional defense-in-depth: global reentrancy guard (shared `_guardCounter` in Main), conservative fixed-point rounding universally favoring the protocol (CEIL received, FLOOR sent), 5-check Chainlink oracle validation with graceful price decay, flash-loan resistance by design (snapshot voting, delayed balance tracking, `startTime = block.timestamp + 1`), era-based governance invalidation, and Folio's `sync` modifier ensuring consistent NAV.

**Informational observations only:**

| Area | Severity | Description |
|------|----------|-------------|
| Folio trusted fill | Informational | Residual token approval after trusted fill closure (defense-in-depth improvement) |
| FolioLib fees | Informational | First fee period undercharges by up to ~24 hours (non-exploitable) |

**Full audit report:** [`AUDIT-REPORT.md`](audits/reserve-protocol/findings/AUDIT-REPORT.md)

---

### Gains Network (gTrade) — [`audits/gains-network/`](audits/gains-network/findings/AUDIT-REPORT.md)

Leveraged perpetual trading platform on Arbitrum + Polygon. EIP-2535 Diamond proxy (GNSMultiCollatDiamond) with 15 facets, GToken ERC4626 vaults (gDAI, gUSDC, gETH) as trade counterparty, velocity-based funding fees, depth-band price impact, multi-reward staking, LayerZero bridge, and Chainlink oracle PnL feed. 12,000+ LOC across core trading, fee, and peripheral systems.

**Result: Clean audit — 0 exploitable vulnerabilities found across 50+ hypotheses.**

The protocol demonstrates strong defense-in-depth: global diamond reentrancy guard, Solidity 0.8.23 overflow protection, SafeERC20 universally, OpenZeppelin Math.mulDiv for rounding control, bounded PnL (-100% floor), anti-trade-splitting price impact (mathematically sound), protection close factor blocking same-block profits, epoch-based vault withdrawals, outlier-filtered median oracle, and consistent multi-collateral precision handling.

**Low/Informational observations only:**

| Area | Severity | Description |
|------|----------|-------------|
| PriceAggregatorUtils | Low | Chainlink `latestRoundData()` missing staleness/negative price check (defense-in-depth) |
| FundingFeesUtils | Low | Sign-change + cap interaction undercharges ~50% for one sub-period (rare edge case) |
| ERC20BridgeRateLimiter | Low | `executePendingClaim` zero-mint advances claim timestamp (griefing, no fund loss) |
| GNSStaking | Low | `debtToken` advanced on zero-amount harvest (sub-penny precision loss) |

**Full audit report:** [`AUDIT-REPORT.md`](audits/gains-network/findings/AUDIT-REPORT.md)

---

## Target Research

| File | Description |
|------|-------------|
| [`scraper.py`](scraper.py) | Fetches all Immunefi programs into a structured text file |
| [`all_programs.txt`](all_programs.txt) | Full data dump: 257 programs with rewards, assets, impacts, scope, and resource links |
| [`ANALYSIS.md`](ANALYSIS.md) | Prioritization analysis — Tier 1/2/3 programs, scoring methodology, vulnerability class focus |

```bash
# Re-scrape all programs
python3 scraper.py
```

Requirements: Python 3.8+, standard library only.

## Focus

- Smart contract programs only (code review, not web/app testing)
- Scoring: max bounty, response time, payment history, Primacy of Impact, in-scope impact count
- Vulnerability classes: arithmetic overflow, access control, oracle manipulation, reentrancy, cross-contract state
