# Submission Ready: BSK-001

## Immunefi Form Fields

**Title**: SOP/Flood swap has no slippage protection and uses manipulable spot reserves

**Target**: https://github.com/BeanstalkFarms/Beanstalk

**Smart Contract**: `0xD1A0060ba708BC4BCD3DA6C37EFa8deDF015FB70` (Beanstalk Diamond, Arbitrum)

**Impact**: Theft of unclaimed yield

**Severity**: High

**PoC Gist**: https://gist.github.com/Fizan324926/191d48c77caa5d293ba18302154a577e

**Description Field**: Paste content of IMMUNEFI-SUBMISSION-001.md

**PoC Field**: Paste content of SUBMISSION-001-POC.md

## Pre-submission checklist

- [x] Fork test runs against live deployed contracts on Arbitrum (not mock math)
- [x] Pinned to block 440420446 for reproducibility
- [x] All 5 tests pass: sunrise permissionless, spot manipulation, sandwich extraction, extreme manipulation, atomic contract exploit
- [x] Shows concrete extraction: 23% with 15% front-run, 68% with 80% dump
- [x] Shows dollar amounts at current ETH price (~$2,036)
- [x] Includes AtomicFloodExploit contract proving no mempool needed
- [x] References exact file:line in LibFlood.sol and LibDeltaB.sol
- [x] Explicitly addresses the frontrunning exclusion (this is NOT front-running)
- [x] Includes concrete fix recommendations with diffs
- [x] Gist has README + foundry.toml + FloodSandwich.t.sol
