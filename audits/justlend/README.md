# JustLend DAO Security Audit

## Overview

Security audit of [JustLend DAO](https://justlend.org/), a Compound V2 fork on TRON blockchain, for the [Immunefi bug bounty program](https://immunefi.com/bug-bounty/justlenddao/).

## Scope

- **Repository:** https://github.com/justlend/justlend-protocol
- **Blockchain:** TRON (TVM, Solidity ^0.5.12)
- **Contracts:** 52 Solidity files, ~15,447 LOC
- **Bounty:** Max $50K Critical, $20K High, $10K Medium

## Findings Summary

| ID | Severity | Title |
|----|----------|-------|
| 01 | Medium | WJST.getPriorVotes lacks checkpoint mechanism — governance manipulation via post-proposal vote buying |
| 02 | Low | CErc20.doTransferOut silently skips USDT return value check |
| 03 | Low | GovernorBravo unsafe uint96 downcast for vote counts |
| 04 | Low | WJST.transferFrom missing SafeMath on balance addition |
| 05 | Low | CEther.doTransferIn excess TRX refund may fail for contract callers |
| 06 | Info | Deployed Comptroller contains features absent from GitHub |
| 07 | Info | CTokenERC777 is misleadingly named dead code |
| 08 | Info | COMP distribution flywheel absent |
| 09 | Info | WJST owner can arbitrarily change governor contract |
| 10 | Info | GovernorAlpha uses hardcoded chain ID = 1 |

## Key Architecture Differences from Compound V2

1. **WJST governance token** — Vote-and-lock mechanism instead of checkpoint-based delegation
2. **CEther** — Explicit amount parameter, excess TRX refund
3. **reserveAdmin** — Separated from protocol admin for reserve management
4. **CErc20** — Hardcoded USDT address with return value skip
5. **Block timing** — 3-second TRON blocks (blocksPerYear = 10,512,000)

## Files

- `findings/AUDIT-REPORT.md` — Full audit report with all findings
- `findings/IMMUNEFI-SUBMISSION-001.md` — Immunefi submission for WJST governance
- `findings/DEPLOYED-VS-GITHUB-ANALYSIS.md` — Deployed contract vs GitHub source comparison
- `scripts/verify/PoC_001_WJSTGovernanceManipulation.sol` — Proof of concept
