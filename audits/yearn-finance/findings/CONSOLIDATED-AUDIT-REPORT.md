# Yearn Finance - Consolidated Security Audit Report

**Date:** 2026-03-02
**Auditor:** Independent Security Review
**Bounty Program:** Immunefi (max $200K)
**Total LOC Audited:** ~60,911 across 8 repositories

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Scope](#scope)
3. [Findings Summary](#findings-summary)
4. [Immunefi-Submittable Findings](#immunefi-submittable-findings)
5. [Additional Findings](#additional-findings)
6. [Per-Repo Assessments](#per-repo-assessments)
7. [Hypotheses Tested (Not Confirmed)](#hypotheses-tested-not-confirmed)
8. [False Positives Eliminated](#false-positives-eliminated)

---

## Executive Summary

This comprehensive audit covers the full Yearn Finance ecosystem across 8 repositories: the V3 Vault core (VaultV3.vy), TokenizedStrategy, veYFI governance, stYFI staking, vault periphery, yearn-boosted-staker, and yearn-yb. Over 60 hypotheses were tested across approximately 60,911 lines of code.

**Overall Assessment:** The Yearn Finance codebase is well-engineered across all repositories. The core vault infrastructure (VaultV3.vy and TokenizedStrategy.sol) is exceptionally robust with **zero exploitable vulnerabilities** found. The V3 vault's use of internal accounting (`total_idle + total_debt`) rather than `balanceOf(this)` completely neutralizes the entire class of donation/inflation attacks. All 24 unsafe operations in VaultV3.vy were mathematically proven safe.

Vulnerabilities were found in the surrounding ecosystem contracts -- veYFI governance, stYFI staking, and yearn-yb -- primarily around missing input validation, division-by-zero edge cases, and zero-slippage MEV exposure.

**Final Tally:** 0 Critical, 0 High, 5 Medium, 6 Low, 13 Informational

| Severity | Count | Immunefi Submissions |
|----------|-------|---------------------|
| Critical | 0 | - |
| High | 0 | - |
| Medium | 5 | 5 (IMMUNEFI-001 through 005) |
| Low | 6 | - |
| Informational | 13 | - |

---

## Scope

### Repositories Audited

| Repository | Language | LOC (approx) | Key Contracts |
|-----------|----------|--------------|---------------|
| yearn-vaults-v3 | Vyper 0.3.7 | ~2,200 | VaultV3.vy |
| tokenized-strategy | Solidity >=0.8.18 | ~2,050 | TokenizedStrategy.sol |
| veYFI | Solidity/Vyper | ~3,500 | VotingYFI.vy, Gauge.sol, Redemption.vy, CombinedChainlinkOracle.vy, RewardPool.vy, dYFIRewardPool.vy |
| stYFI | Vyper 0.4.2 | ~4,800 | StakedYFI.vy, DelegatedStakedYFI.vy, StakingRewardDistributor.vy, RewardDistributor.vy, LiquidLockerDepositor.vy, LiquidLockerRedemption.vy |
| vault-periphery (tokenized-strategy-periphery) | Solidity | ~8,500 | Accountant.sol, DebtAllocator.sol, Auction.sol, RoleManager.sol |
| vault-periphery (vault-periphery) | Solidity | ~3,200 | Splitter.vy, RewardClaimer |
| yearn-boosted-staker | Solidity | ~1,800 | YearnBoostedStaker.sol, SingleTokenRewardDistributor.sol |
| yearn-yb | Solidity | ~1,200 | Locker.sol, Operator.sol, YToken.sol, Zap.sol |

### Compiler Versions
- **Vyper 0.3.7** (VaultV3.vy): NOT affected by the Curve reentrancy bug (CVE-2023-37902 affects 0.2.15-0.3.0). ecrecover undefined data bug has negligible risk. See `VYPER-0.3.7-COMPILER-BUGS.md`.
- **Vyper 0.4.2** (stYFI contracts): Latest stable, no known relevant vulnerabilities.
- **Solidity >=0.8.18/0.8.20**: Built-in overflow checks, no known compiler issues.

---

## Findings Summary

### Medium Findings (5)

| ID | Finding | Repo | File | Immunefi |
|----|---------|------|------|----------|
| M-01 | CombinedChainlinkOracle: No validation for zero/negative oracle prices | veYFI | CombinedChainlinkOracle.vy:30 | IMMUNEFI-001 |
| M-02 | Gauge.sol: Residual approval accumulation to VE_YFI_POOL | veYFI | Gauge.sol:534-537 | IMMUNEFI-002 |
| M-03 | RewardPool/dYFIRewardPool: Division by zero when ve_supply is zero | veYFI | RewardPool.vy:196 | IMMUNEFI-003 |
| M-04 | Zap.sol: Zero slippage on intermediate Curve pool operations | yearn-yb | Zap.sol:130,157,170 | IMMUNEFI-004 |
| M-05 | StakingRewardDistributor: Division by zero when total_weight is zero | stYFI | StakingRewardDistributor.vy:518,531,550 | IMMUNEFI-005 |

### Low Findings (6)

| ID | Finding | Repo | File |
|----|---------|------|------|
| L-01 | YearnBoostedStaker: Forced even-amount staking causes precision loss | yearn-boosted-staker | YearnBoostedStaker.sol:131-132 |
| L-02 | Gauge.sol: `getReward(address)` callable by anyone, enabling boost-timing griefing | veYFI | Gauge.sol:503-509 |
| L-03 | Redemption.vy: Oracle price converted without negative check | veYFI | Redemption.vy:194 |
| L-04 | VotingYFI.vy: Lock duration rounding creates off-by-one weeks | veYFI | VotingYFI.vy:270-271 |
| L-05 | VaultV3.vy: Dust-amount withdrawals from lossy strategies revert | yearn-vaults-v3 | VaultV3.vy:688-693 |
| L-06 | VaultV3.vy: `ending_supply` underflow with misconfigured accountant | yearn-vaults-v3 | VaultV3.vy:1225 |

### Informational Findings (13)

| ID | Finding | Repo |
|----|---------|------|
| I-01 | StakedYFI/DelegatedStakedYFI: Packed stream timestamp truncation at 40 bits (safe) | stYFI |
| I-02 | Accountant.sol: Management fee calculated on current_debt not average_debt | vault-periphery |
| I-03 | DebtAllocator: `update_debt` calls `process_report` before zero-debt update | vault-periphery |
| I-04 | YearnBoostedStaker: `stakeAsMaxWeighted` breaks weight derivation (documented) | yearn-boosted-staker |
| I-05 | SingleTokenRewardDistributor: `claimWithRange` can permanently skip rewards | yearn-boosted-staker |
| I-06 | YToken.sol: Anyone can mint yTokens by sending tokens to locker (by design) | yearn-yb |
| I-07 | Locker.sol: `execute` returns success status without enforcing it | yearn-yb |
| I-08 | Locker.sol: `increase_amount` selector guard bypassable by owner via proxy | yearn-yb |
| I-09 | GaugeFactory.sol: No access control on `createGauge` | veYFI |
| I-10 | VaultV3.vy: EIP-712 domain separator uses hardcoded "Yearn Vault" name | yearn-vaults-v3 |
| I-11 | VaultV3.vy: `set_default_queue` allows duplicate strategies (documented) | yearn-vaults-v3 |
| I-12 | VaultV3.vy: `buy_debt` reverts with "cannot buy zero" for small amounts | yearn-vaults-v3 |
| I-13 | VaultV3.vy: `auto_allocate` with empty `default_queue` DOSes deposits | yearn-vaults-v3 |

---

## Immunefi-Submittable Findings

### FINDING M-01 [Medium]: CombinedChainlinkOracle Missing Zero/Negative Price Validation

**File:** `veYFI/contracts/CombinedChainlinkOracle.vy`, line 30
**Consumer:** `veYFI/contracts/Redemption.vy`, lines 186-194
**Submission:** `IMMUNEFI-SUBMISSION-001.md`

The `CombinedChainlinkOracle` combines YFI/USD and ETH/USD Chainlink feeds to derive YFI/ETH price. It performs no validation that either oracle answer is positive or non-zero before computing `yfi.answer * SCALE / eth.answer`.

```vyper
yfi.answer = yfi.answer * SCALE / eth.answer  # NO CHECK: eth.answer could be 0 or negative
```

**Impact:** If ETH/USD returns 0 (Chainlink circuit breaker event), all dYFI redemptions permanently revert. If both feeds return negative, `negative / negative = positive` produces a valid-looking but wrong price.

**Recommendation:** Add `assert yfi.answer > 0` and `assert eth.answer > 0` before the division.

---

### FINDING M-02 [Medium]: Gauge.sol Residual Approval Accumulation

**File:** `veYFI/contracts/Gauge.sol`, lines 534-537
**Submission:** `IMMUNEFI-SUBMISSION-002.md`

```solidity
function _transferVeYfiORewards(uint256 _penalty) internal {
    IERC20(REWARD_TOKEN).approve(VE_YFI_POOL, _penalty);
    IDYfiRewardPool(VE_YFI_POOL).burn(_penalty);
}
```

Uses `approve()` instead of `safeIncreaseAllowance`. If `burn()` consumes fewer tokens than approved (partial failure path), residual allowance remains exploitable. The pattern also breaks for USDT-like tokens that require approval reset to 0.

**Recommendation:** Use `approve(0)` then `approve(amount)`, or `safeIncreaseAllowance`.

---

### FINDING M-03 [Medium]: RewardPool/dYFIRewardPool Division by Zero

**File:** `veYFI/contracts/RewardPool.vy`, line 196; `dYFIRewardPool.vy`, line 190
**Submission:** `IMMUNEFI-SUBMISSION-003.md`

```vyper
to_distribute += balance_of * self.tokens_per_week[week_cursor] / self.ve_supply[week_cursor]
```

When all veYFI locks expire, `ve_supply[week_cursor]` becomes 0 while a user may still have non-zero `balance_of`. This causes permanent revert, locking the user out of all future claims.

**Recommendation:** Add `if self.ve_supply[week_cursor] > 0:` guard before the division.

---

### FINDING M-04 [Medium]: Zap.sol Zero Slippage on Intermediate Curve Operations

**File:** `yearn-yb/src/Zap.sol`, lines 130, 157, 170
**Submission:** `IMMUNEFI-SUBMISSION-004.md`

All intermediate Curve pool operations use `minOut = 0`:
```solidity
ICurvePool(POOL).exchange(0, 1, amount, 0);           // line 157
ICurvePool(POOL).add_liquidity(_amounts, 0, address(this)); // line 170
ICurvePool(POOL).remove_liquidity_one_coin(lpAmount, int128(1), 0, address(this)); // line 130
```

While the outer `zap()` has a `minOut` parameter, intermediate zero-slippage operations create compound sandwich attack vectors. MEV bots can extract value at each step, and the compound effect of two sandwiched operations can exceed the user's slippage tolerance.

**Recommendation:** Use `get_dy` / `calc_token_amount` to compute intermediate minimums at ~99% tolerance per step.

---

### FINDING M-05 [Medium]: StakingRewardDistributor Division by Zero

**File:** `stYFI/contracts/StakingRewardDistributor.vy`, lines 518, 531, 550
**Submission:** `IMMUNEFI-SUBMISSION-005.md`

Three division points by `total_weight` in `_sync_integral()`. The constructor initializes dead shares of `10^12`, which provides protection under normal operation. However, if accounting allows weight to reach exactly 0 after all stakers exit, the distributor is permanently bricked.

**Mitigation Factor:** Dead shares of `10^12` provide strong protection. Requires accounting edge case.

**Recommendation:** Add `if total_weight > 0:` guard at all three division points.

---

## Additional Findings

### L-01: YearnBoostedStaker Forced Even-Amount Staking

**File:** `yearn-boosted-staker/contracts/YearnBoostedStaker.sol`, lines 131-132

```solidity
uint weight = _amount >> 1;
_amount = weight << 1;
```

Forces all amounts to even numbers via bit-shifting. Users staking odd amounts lose 1 wei of precision. Unstaking also requires even increments.

---

### L-02: Gauge.sol `getReward(address)` Callable by Anyone

**File:** `veYFI/contracts/Gauge.sol`, lines 503-509

Anyone can trigger reward claims for any account, which also updates `_boostedBalances`. An attacker can time calls to force penalty calculation at a user's current (lower) boost before the user increases their veYFI lock.

---

### L-03: Redemption.vy Oracle Price Negative Check

**File:** `veYFI/contracts/Redemption.vy`, line 194

`convert(price, uint256)` in Vyper 0.3.7 reverts on negative int256 values. If the combined oracle returns negative, redemptions are bricked until recovery.

---

### L-04: VotingYFI.vy Lock Duration Rounding

**File:** `veYFI/contracts/VotingYFI.vy`, lines 270-271

`round_to_week(unlock_time)` rounds down, potentially reducing effective lock by up to 6 days, 23 hours. Known Curve ve-token behavior.

---

### L-05: VaultV3.vy Dust-Amount Withdrawal Revert

**File:** `yearn-vaults-v3/contracts/VaultV3.vy`, lines 688-693

`_assess_share_of_unrealised_losses` rounds loss UP, producing `users_share_of_loss = 2` for `assets_needed = 1`, causing underflow at line 819.

---

### L-06: VaultV3.vy Ending Supply Underflow

**File:** `yearn-vaults-v3/contracts/VaultV3.vy`, line 1225

Misconfigured accountant returning large `total_fees` during loss report with active profit unlock can cause `ending_supply` underflow, DOSing `process_report`.

---

## Per-Repo Assessments

### yearn-vaults-v3 (VaultV3.vy) -- CLEAN

**Findings:** 0 Critical, 0 High, 0 Medium, 2 Low, 4 Informational

The V3 vault is exceptionally well-engineered. Key defensive patterns:
- **Internal accounting** (`total_idle + total_debt`) neutralizes all donation/inflation attacks
- **Shared `@nonreentrant("lock")`** on all 7 mutative functions prevents cross-function reentrancy
- **Profit locking** prevents front-running of profit reports
- **Pre/post balance tracking** for strategy interactions (immune to dishonest strategies)
- **Correct rounding** throughout (deposits DOWN, withdrawals UP, losses UP)
- All 24 `unsafe_*` operations mathematically proven safe

### tokenized-strategy (TokenizedStrategy.sol) -- CLEAN

**Findings:** 0 Critical, 0 High, 0 Medium, 0 Low

TokenizedStrategy uses manual `S.totalAssets` tracking (prevents first-depositor attacks), custom storage slots for delegatecall safety, and well-structured profit locking. Zero exploitable vulnerabilities.

### veYFI -- 3 Medium, 3 Low, 1 Informational

Well-implemented Curve-style governance system. VotingYFI.vy handles checkpoints and kinks correctly. Gauge boost follows Curve's formula with kick() as corrective mechanism. The dYFI discount formula uses audited Balancer exponential math. Issues found primarily in oracle validation and edge-case division-by-zero scenarios inherited from the Curve FeeDistributor pattern.

### stYFI -- 1 Medium

Solid staking infrastructure. StakedYFI.vy's 14-day withdrawal stream is well-designed with packed storage. Hook system provides extensible reward distribution. The StakingRewardDistributor's integral-based accounting is complex but correct under normal operation. The 4-epoch ramp for boosting is well-calibrated.

### vault-periphery -- CLEAN (effectively)

Accountant.sol, DebtAllocator.sol, and Auction.sol are well-structured. Fee bounds prevent excessive extraction. Rate limiting and minimum change thresholds in DebtAllocator protect against manipulation. Auction.sol's `nonReentrant` guards on both `kick()` and `_take()` prevent callback reentrancy.

### yearn-boosted-staker -- 1 Low, 2 Informational

Novel bitmap-based weight tracking. The MAX_STAKE_GROWTH_WEEKS <= 7 constraint ensures bitmap fits in uint8. LIFO unstaking is well-implemented. The `claimWithRange` permanent skip is documented.

### yearn-yb -- 1 Medium

Locker/Operator/YToken system is clean. NFT-based lock with cache-based delta tracking works correctly. The Zap contract's zero-slippage intermediates are the only significant issue.

---

## Hypotheses Tested (Not Confirmed)

Over 60 hypotheses were systematically tested. Key ones:

1. **ERC4626 first-depositor inflation (VaultV3)** -- Blocked by internal accounting
2. **ERC4626 first-depositor inflation (TokenizedStrategy)** -- Blocked by manual totalAssets tracking
3. **Profit front-running (VaultV3)** -- Blocked by profit locking mechanism
4. **Cross-contract reentrancy (VaultV3)** -- Blocked by shared `@nonreentrant("lock")`
5. **VaultV3 `_process_report` div-by-zero** -- Mathematically proved unreachable (see VAULTV3-AUDIT-REPORT.md)
6. **unsafe_add/sub overflow (VaultV3)** -- All 24 instances proven safe with algebraic bounds
7. **veYFI withdraw penalty bypass** -- Penalty capped at 75%, based on stored lock end time
8. **dYFI discount gaming via flash loans** -- Flash loans cannot create veYFI locks (min 1 week)
9. **StakedYFI stream manipulation** -- `_unstake` correctly combines existing + new stream
10. **Gauge first-depositor attack** -- 1:1 share ratio eliminates inflation
11. **YToken unbacked minting** -- Cache-based delta tracking verified correct
12. **Operator cached amount race condition** -- Atomic single-transaction execution verified
13. **RewardDistributor double-claiming** -- `@nonreentrant` + epoch cursor prevent this
14. **DebtAllocator keeper front-running** -- `maxDebtUpdateLoss` (1bp default) limits extraction
15. **YearnBoostedStaker epoch manipulation** -- Deterministic `(block.timestamp - START_TIME) / 1 weeks`
16. **Accountant refund drain** -- Bounded by `min(loss * refundRatio / MAX_BPS, balance)`
17. **Auction callback reentrancy** -- `kick()` has `nonReentrant`, making reentry impossible
18. **StakingRewardDistributor stale total_weight** -- Weight constant during catch-up period
19. **Vyper 0.3.7 compiler reentrancy bug** -- NOT affected (bug was in 0.2.15-0.3.0)
20. **ERC777 reentrancy via token callbacks** -- Shared nonreentrant guard blocks all re-entry

---

## False Positives Eliminated

| # | Hypothesis | Why It's False |
|---|-----------|----------------|
| 1 | VaultV3 `_process_report` div-by-zero at line 1298 | Proved `new_profit_locking_period >= 1` for all valid `profit_max_unlock_time >= 1` |
| 2 | Auction reentrancy via callback into `kick()` | `kick()` has `nonReentrant` guard (line 570); cannot reenter from `_take()` callback |
| 3 | YToken unbacked minting via cache race condition | `lock()` and `nftTransferCallback()` both call `_updateCachedLockedAmount()`; sequential execution guarantees correctness |
| 4 | StakingRewardDistributor stale total_weight during catch-up | Weight only changes via interactions that call `_sync_integral` first; latest value IS correct during catch-up |
| 5 | VaultV3 first-depositor inflation attack | Internal accounting (`total_idle + total_debt`) unaffected by direct token transfers |
| 6 | TokenizedStrategy first-depositor attack | Manual `S.totalAssets` tracking unaffected by donations |
| 7 | Gauge stale cached boost as new vulnerability | Known Curve gauge design pattern; `kick()` is intentional corrective mechanism |

---

## Detailed Sub-Reports

- **VaultV3 Deep Analysis:** `VAULTV3-AUDIT-REPORT.md`
- **Vyper 0.3.7 Compiler Analysis:** `VYPER-0.3.7-COMPILER-BUGS.md`
- **Immunefi Submissions:** `IMMUNEFI-SUBMISSION-001.md` through `005.md`
- **PoC Files:** `scripts/verify/PoC_001_*.sol` through `PoC_005_*.sol`

---

## Conclusion

The Yearn Finance V3 ecosystem demonstrates strong defensive engineering at its core. The VaultV3.vy and TokenizedStrategy.sol are among the most well-defended DeFi contracts reviewed, with internal accounting, shared reentrancy guards, profit locking, and correct rounding eliminating entire classes of attacks.

The surrounding ecosystem (veYFI, stYFI, yearn-yb) contains medium-severity issues primarily around:
1. Missing oracle input validation (zero/negative prices)
2. Division-by-zero edge cases inherited from the Curve FeeDistributor design
3. Zero-slippage MEV exposure in the Zap contract
4. Approval pattern fragility in the Gauge

All 5 Medium findings have Immunefi submissions with working Foundry PoCs.
