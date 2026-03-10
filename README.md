# defi-audit-targets

Research repository for identifying and prioritizing Immunefi bug bounty programs best suited for code-audit-style vulnerability research, and publishing findings from active audits.

---

## Active Audits

| Program | Bounty | Language | Audit Folder | Status |
|---------|--------|----------|--------------|--------|
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

### GMX V2 Synthetics — [`audits/gmx-synthetics/`](audits/gmx-synthetics/README.md)

Decentralized perpetual exchange on Arbitrum/Avalanche ($700M+ TVL). Covers the Gelato relay system for gasless transactions, LayerZero cross-chain bridging, oracle price validation, and position management.

**Confirmed Findings (2 of 20 initial — 18 eliminated as false positives):**

| ID | Severity | Description |
|----|----------|-------------|
| [VULN-003](audits/gmx-synthetics/exploits/VULN-003-relay-fee-swap-zero-slippage.md) | High | `minOutputAmount: 0` hardcoded in relay fee swap — MEV sandwich extraction |
| [VULN-011](audits/gmx-synthetics/exploits/VULN-011-missing-relay-nonce-validation.md) | High | Random (not sequential) relay nonce — keeper can reorder/skip transactions |

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
