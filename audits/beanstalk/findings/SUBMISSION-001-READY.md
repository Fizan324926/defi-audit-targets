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

- [x] Fork tests run against live deployed contracts on Arbitrum (not mock math)
- [x] Bean/WETH Well pinned to block 440420446 for reproducibility
- [x] Bean/wstETH Well tested at latest block ($6.8M TVL)
- [x] All 7 tests pass: sunrise permissionless, spot manipulation, sandwich extraction, extreme manipulation, atomic contract exploit, wstETH 1% SOP, wstETH 5% SOP
- [x] Shows concrete extraction: 23-24% across both Wells
- [x] Shows dollar amounts: $101 on small pool, $8,137-$38,533 on large pool
- [x] Includes AtomicFloodExploit contract proving no mempool needed
- [x] References exact file:line in LibFlood.sol and LibDeltaB.sol
- [x] Explicitly addresses the frontrunning exclusion (this is NOT front running)
- [x] Includes concrete fix recommendations with diffs
- [x] Gist has README + foundry.toml + FloodSandwich.t.sol + BeanWstEthSandwich.t.sol
- [x] Addresses Flood rarity: designed mechanism, expected to trigger during economic recovery
