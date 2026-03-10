# Optimism Security Audit

**Target**: [Optimism Immunefi Bug Bounty](https://immunefi.com/bug-bounty/optimism/)
**Max Bounty**: $2,000,042
**Rules**: Primacy of Impact (Smart Contracts/Blockchain)
**Date**: March 2026

## Scope

162 Solidity files in the Optimism monorepo, covering:
- **Bridge/Portal**: OptimismPortal2, L1StandardBridge, L1CrossDomainMessenger, ETHLockbox
- **Fault Proofs**: FaultDisputeGame, SuperFaultDisputeGame, DisputeGameFactory, AnchorStateRegistry, DelayedWETH
- **Cannon/MIPS64**: MIPS64 VM, PreimageOracle, instruction/syscall libraries
- **L2 Contracts**: CrossDomainMessenger, StandardBridge, CrossL2Inbox, SuperchainTokenBridge, GasPriceOracle, SystemConfig

Source: https://github.com/ethereum-optimism/optimism

## Findings Summary

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| M-01 | MEDIUM | SuperFaultDisputeGame.closeGame() blocks credit claims during pause after bond distribution decided | CONFIRMED |

120+ potential issues investigated across 2 audit passes, 1 confirmed. All others eliminated as false positives.

## Verification

```bash
python3 scripts/verify/verify_M01_closeGame_ordering.py
```

## Structure

```
findings/                          - Finding reports
findings/exploits/                 - Exploit writeups
findings/AUDIT-REPORT.md           - Full audit report
scripts/verify/                    - Verification scripts
source/                            - Optimism monorepo (cloned)
```
