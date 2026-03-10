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
| [Sky (MakerDAO)](https://immunefi.com/bug-bounty/sky/) | $10,000,000 | Solidity | 1 High, 2 Medium | [`audits/sky/`](audits/sky/README.md) | Complete |
| [GMX V2 Synthetics](https://immunefi.com/bug-bounty/gmx/) | $5,000,000 | Solidity | 2 High | [`audits/gmx-synthetics/`](audits/gmx-synthetics/README.md) | Complete |
| [Optimism](https://immunefi.com/bug-bounty/optimism/) | $2,000,042 | Solidity + Go | 1 Medium | [`audits/optimism/`](audits/optimism/README.md) | Complete |
| [Olympus DAO](https://immunefi.com/bug-bounty/olympus/) | $3,333,333 | Solidity | 1 Medium-High, 5 Medium | [`audits/olympus-dao/`](audits/olympus-dao/bophades/findings/AUDIT-REPORT.md) | Complete |
| [Orca Whirlpool](https://immunefi.com/bug-bounty/orca/) | $500,000 | Rust / Solana | 1 Medium (borderline) | [`audits/orca-whirlpool/`](audits/orca-whirlpool/README.md) | Complete |

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

**Total: 3 High, 1 Medium-High, 9 Medium across 5 protocols**

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
