# Sky Protocol (formerly MakerDAO) — Security Audit

**Program:** Sky on Immunefi
**Bounty URL:** https://immunefi.com/bug-bounty/sky/
**Max Bounty:** $10,000,000
**Primacy:** Primacy of Rules
**KYC Required:** No
**PoC Required:** Yes
**Audit Date:** 2026-03-01

---

## Protocol Overview

Sky (formerly MakerDAO) is one of the oldest DeFi protocols, operating the DAI/USDS CDP stablecoin system. Key components:

- **Core DSS**: Vat (accounting), Cat (liquidation), Jug (stability fee), Vow (surplus/deficit buffer)
- **LitePSM**: Lightweight Peg Stability Module for USDC-backed DAI
- **Lockstake Engine**: SKY governance token staking with CDP collateral
- **SUsds / sDai**: Savings Rate vaults (ERC-4626)
- **Endgame Toolkit**: StakingRewards, VestedRewardsDistribution for SKY farming
- **DSS Flappers (SBE)**: Surplus Buyback Engine — Splitter, FlapperUniV2, Kicker
- **Bridges**: Optimism and Arbitrum token bridges for USDS/SKY
- **D3M**: Direct Deposit Module for auto-allocating DAI to external protocols
- **Vote Delegate**: Governance vote proxying factory
- **DSS Vest**: Token vesting for contributors

---

## Codebase

**Source:** `/root/audits/sky-protocol/`
**Files analyzed:** 567 Solidity files across 27 repositories

Key repositories cloned:
- dss, lockstake, usds, sky, sdai, endgame-toolkit
- dss-flappers, vote-delegate, dss-lite-psm
- dss-allocator, op-token-bridge, arbitrum-token-bridge
- dss-direct-deposit, dss-flash, dss-cdp-manager
- dss-auto-line, dss-vest, median, osm, sp-beam
- dss-gem-joins, dss-emergency-spells, etc.

---

## Findings Summary

| ID | Severity | Contract | Title | Status |
|----|----------|----------|-------|--------|
| [001](findings/001-staking-rewards-duration-yield-loss.md) | **High** | StakingRewards.sol | `setRewardsDuration` mid-period integer truncation destroys staker yield | Ready to submit |
| [002](findings/002-splitter-farm-zero-dos.md) | **Medium** | Splitter.sol | `kick()` permanently reverts when `farm==address(0)` and `burn<WAD` | Ready to submit |
| [003](findings/003-staking-rewards-zero-duration.md) | **Medium** | StakingRewards.sol | `setRewardsDuration(0)` permanently bricks reward distribution | Ready to submit |

---

## False Positives

| ID | Contract | Claim | Reason Rejected |
|----|----------|-------|-----------------|
| [FP-001](findings/false-positives/FP-001-lockstake-reentrancy.md) | LockstakeEngine | CRITICAL reentrancy via malicious VoteDelegate | Factory only deploys standard VoteDelegate code |
| [FP-002](findings/false-positives/FP-002-litepsm-cut-underflow.md) | DssLitePsm | Underflow in cut() | Invariant maintained; requires trusted-role attack |

---

## Out of Scope / Known Issues Verified

- **Exit fee bypass on liquidations** — explicitly stated as known in Sky's program rules
- **Large auction amounts delaying selectVoteDelegate** — known per program rules
- **Sandwich/MEV attacks on SBE** — explicitly known per dss-flappers rules
- **Any issue in original Synthetix StakingRewards** — explicitly excluded
- **Emergency spell schedule() no auth** — intended design for pre-authorized spells
- **L1TokenBridge no whitelist on finalize** — L2 provides validation; requires compromised bridge to exploit
- **GemJoin8 GUSD lock on upgrade** — external dependency, temporary, LOW
- **Reentrancy guards on LockstakeEngine** — VoteDelegateLike.lock() is standard code with no reentrant callback
- **DssLitePsm.cut() underflow** — invariant maintained through normal operations

---

## Key Scope Notes

- **Primacy of Rules**: Only listed impact categories are in scope
- **Wards trusted**: "It is assumed that wards in all contracts are fully trusted"
- **Canonical Synthetix exclusion**: Any bug also in the original Synthetix StakingRewards is excluded
- **MEV/sandwich**: Known and out of scope for dss-flappers
- **Oracle frequency**: Out of scope
- **Temporary fund freeze (<150 blocks)**: Downgraded to Medium

---

## Reward Tiers

| Level | Range |
|-------|-------|
| Critical | $150K – $10M (10% of affected funds) |
| High | $5K – $100K |
| Medium | $5K |
| Low | $1K |

---

## Findings Detail

### Finding 001 — High: StakingRewards.setRewardsDuration Arithmetic Bug

**File:** `endgame-toolkit/src/synthetix/StakingRewards.sol:172-182`

Sky explicitly modified the canonical Synthetix `setRewardsDuration` to support mid-period duration changes. The implementation uses integer division `leftover / _rewardsDuration` which truncates when the new duration greatly exceeds the remaining undistributed tokens. This can reduce `rewardRate` by orders of magnitude or to zero, permanently destroying pending staker yield.

The canonical Synthetix unconditionally reverts mid-period. This bug is entirely new code introduced by Sky.

**Key code:**
```solidity
uint256 leftover = (periodFinish_ - block.timestamp) * rewardRate;
rewardRate = leftover / _rewardsDuration;  // truncates silently
```

### Finding 002 — Medium: Splitter farm==address(0) DoS

**File:** `dss-flappers/src/Splitter.sol:112-116`

When `burn < WAD` and `farm == address(0)`, `kick()` attempts `usdsJoin.exit(address(0), pay)` which USDS reverts with "Usds/invalid-address". Since `Kicker.flap()` is permissionless, anyone can trigger this DoS once the misconfiguration exists. No guard prevents setting `burn < WAD` without setting `farm`.

### Finding 003 — Medium: StakingRewards.setRewardsDuration(0)

**File:** `endgame-toolkit/src/synthetix/StakingRewards.sol:172-182`

No guard against `_rewardsDuration = 0`. After a period completes, calling `setRewardsDuration(0)` stores zero. All subsequent `notifyRewardAmount` calls panic with division by zero, permanently bricking `VestedRewardsDistribution.distribute()`.
