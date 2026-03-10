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
| [004](findings/004-lockstake-lock-no-auth.md) | **Medium** | LockstakeEngine.sol | `lock()` uses `_getUrn()` instead of `_getAuthedUrn()` — unauthorized urn state manipulation | Ready to submit |

---

## False Positives

| ID | Contract | Claim | Reason Rejected |
|----|----------|-------|-----------------|
| [FP-001](findings/false-positives/FP-001-lockstake-reentrancy.md) | LockstakeEngine | CRITICAL reentrancy via malicious VoteDelegate | Factory only deploys standard VoteDelegate code |
| [FP-002](findings/false-positives/FP-002-litepsm-cut-underflow.md) | DssLitePsm | Underflow in cut() | Invariant maintained by design |
| [FP-003](findings/false-positives/FP-003-bridge-inflight-bypass.md) | L2TokenGateway / L2TokenBridge | HIGH: in-flight messages bypass isOpen | Inherent L1/L2 messaging constraint, not a bug |
| [FP-004](findings/false-positives/FP-004-l1gateway-no-token-validation.md) | L1TokenGateway | HIGH: no l1Token registry validation | L2 validates token before encoding; onlyCounterpartGateway prevents forgery |
| [FP-005](findings/false-positives/FP-005-d3m-exit-divzero.md) | D3M4626TypePool | HIGH: exit() division by zero | Not reachable — vat.slip prevents calling with zero Art |
| [FP-006](findings/false-positives/FP-006-d3m-flash-manipulation.md) | D3MAaveTypeBufferPlan | HIGH: flash loan inflates getTargetAssets | Admitted known design in code comments |
| [FP-007](findings/false-positives/FP-007-gemjoin9-frontrun.md) | GemJoin9 | MEDIUM: front-running join() | Self-documented known design; atomic proxy usage required |

---

## Out of Scope / Known Issues Verified (Full Re-Audit, 27 repos)

**Round 1:** Exit fee bypass on liquidations (known), MEV/sandwich on SBE (known),
canonical Synthetix bugs (excluded), large auction amounts (known),
emergency spell schedule() no auth (by design), LitePsm cut() underflow (invariant holds),
LockstakeEngine reentrancy via VoteDelegate (factory only deploys standard code).

**Round 2 (comprehensive coverage):**
- Bridge in-flight message bypass — inherent Arbitrum/Optimism design constraint (FP-003)
- L1TokenGateway token validation — L2 validates before message encoding (FP-004)
- D3M4626TypePool exit div/0 — unreachable via vat.slip protection (FP-005)
- D3MAaveTypeBufferPlan flash manipulation — documented known design (FP-006)
- GemJoin9 frontrun — self-documented, atomic proxy usage required (FP-007)
- DssAutoLine exec() underflow — wards trusted trigger required
- End.cash() bag reuse — long-standing MakerDAO End design choice
- VoteDelegate.lock() CEI — not exploitable with standard ERC-20 tokens
- FlapperUniV2 stale pip DoS — oracle delay is intentional safety feature
- LockstakeMigrator line=0 reset — intentional ward-controlled migration design
- Swapper minOut=0 — wards trusted (authorized callers only)
- DepositorUniV3 era=0 bypass — wards trusted (automation role)
- DssVest rate cap truncation — less than 1 full token total overshoot
- LockstakeEngine.wipe() no auth — net positive for victim (debt repaid), not harmful

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

### Finding 004 — Medium: LockstakeEngine.lock() Missing Authorization Check

**File:** `lockstake/src/LockstakeEngine.sol:291-309`

`lock()` uses `_getUrn(owner, index)` instead of `_getAuthedUrn(owner, index)`. Every other state-modifying function (`free`, `draw`, `selectVoteDelegate`, `selectFarm`, `wipe`, `getReward`) requires the caller to be authorized for the urn. Anyone can call `lock(victimOwner, victimIndex, wad)` to force SKY into a victim's urn: the attacker's SKY is forwarded to the victim's selected VoteDelegate (inflating that delegate's governance weight without consent), ink is added to the victim's urn, and lssky is minted and staked into the victim's farm. The attacker permanently loses their SKY but achieves unauthorized governance state manipulation. There is no `urnAuctions[urn] == 0` guard either, meaning this can be called during active auctions.
