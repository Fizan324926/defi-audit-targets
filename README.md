# defi-audit-targets

Research repository for identifying and prioritizing Immunefi bug bounty programs best suited for code-audit-style vulnerability research, and publishing findings from active audits.

---

## Reference Guides

| Guide | Purpose |
|-------|---------|
| [`AUDIT-AI-RULES.md`](AUDIT-AI-RULES.md) | **AI audit methodology** — full process: scope determination, codebase exploration, multi-angle analysis, exploit development, reporting, repo organization, and complete vulnerability catalog |
| [`IMMUNEFI-REPORT-GUIDE.md`](IMMUNEFI-REPORT-GUIDE.md) | Report format, PoC requirements, severity classification, submission rules, and negotiation guide |

---

## Active Audits

| Program | Bounty | Language | Audit Folder | Status |
|---------|--------|----------|--------------|--------|
| [Sky (MakerDAO)](https://immunefi.com/bug-bounty/sky/) | $10,000,000 | Solidity / EVM | [`audits/sky/`](audits/sky/README.md) | In Progress |
| [Orca Whirlpool](https://immunefi.com/bug-bounty/orca/) | $500,000 | Rust / Solana | [`audits/orca-whirlpool/`](audits/orca-whirlpool/README.md) | In Progress |
| [GMX V2 Synthetics](https://immunefi.com/bug-bounty/gmx/) | $5,000,000 | Solidity / EVM | [`audits/gmx-synthetics/`](audits/gmx-synthetics/README.md) | Complete |

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
