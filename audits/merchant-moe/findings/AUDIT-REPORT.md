# Merchant Moe (LFJ) Security Audit Report

## Protocol Overview

**Protocol:** Merchant Moe (by LFJ / Trader Joe team)
**Network:** Mantle
**Bounty:** Immunefi, max $100K Critical / $10K High (USDC)
**Scope:** 4 repositories — moe-core, joe-v2, lb-rewarder, autopools
**Total LOC:** ~21,268 Solidity across 119 files
**Audit Date:** March 2026
**Prior Audits:** Paladin (March 2024), Bailsec (November 2024)
**Known Issues:** Broken EIP712 in MoeERC20 (DOMAIN_SEPARATOR set in constructor, not in clones)

## Architecture Summary

Merchant Moe is the cornerstone DEX for Mantle Network, featuring a dual-AMM architecture:

### moe-core (Classic AMM + Governance)
- **MoePair** — UniV2 fork with non-standard `_sendFee()` (extracts actual tokens instead of minting LP)
- **MoeRouter** — Standard UniV2 router with fee-on-transfer token support
- **MoeFactory** — Pair factory using ImmutableClone deterministic deployment
- **MasterChef** — Core farming contract, sole MOE minter with static pool shares + VeMoe-weighted pools
- **VeMoe** — Vote-escrowed MOE with alpha-weighted pool voting (`weight = min(votes, votes^alpha)`)
- **MoeStaking** — Simple staking proxy calling VeMoe + StableMoe sequentially
- **StableMoe** — Protocol fee distribution to stakers via balance-derived rewards
- **Moe** — ERC20 with minter-controlled supply cap (1B max)
- **JoeStaking** — JOE token staking with single rewarder slot
- **BaseRewarder** — Abstract base using RewarderV2 (128-bit precision)
- **MasterChefRewarder/VeMoeRewarder/JoeStakingRewarder** — Specialized rewarder implementations
- **RewarderFactory** — Creates rewarders via ImmutableClone (VeMoeRewarder is permissionless)
- **Libraries:** Rewarder V1 (64-bit), RewarderV2 (128-bit), Amounts, Math, Constants

### joe-v2 (Liquidity Book — Concentrated Liquidity)
- **LBPair** — Core trading engine with discrete price bins, 128.128 binary fixed-point pricing
- **LBFactory** — Pair registry with presets, hooks management, and LB_HOOKS_MANAGER_ROLE
- **LBRouter** — Multi-hop routing across V2.1, V2.0, and V1 AMMs
- **LBToken** — ERC1155-like without safe transfer callbacks (intentional, prevents reentrancy)
- **LBBaseHooks** — Template for custom LP hooks (10 flag-based hook points)
- **Libraries:** PackedUint128Math, Uint256x256Math, SafeCast, PriceHelper, BinHelper, OracleHelper, FeeHelper, TreeMath (3-level O(log64) bin traversal), BitMath

### lb-rewarder (Hooks-Based Reward Distribution)
- **LBHooksBaseRewarder** — Core hooks-based reward distribution across LB bins
- **LBHooksBaseSimpleRewarder** — Linear time-based emission
- **LBHooksBaseParentRewarder** — Parent-extra rewarder chaining
- **LBHooksExtraRewarder** — Secondary reward token via parent delegation
- **LBHooksMCRewarder** — MasterChef integration via ERC20 wrapper (1-token deposit)
- **LBHooksSimpleRewarder** — Simple + parent combined
- **LBHooksManager** — Factory for deploying and linking rewarders to LB pairs

### autopools (Automated Vault Management)
- **BaseVault** — Core vault with withdrawal queue, dead-share (1e6) first-depositor protection
- **Strategy** — LB liquidity management with AUM fees (capped 25%), 1inch swap integration
- **SimpleVault** — Ratio-based deposits with cross-product share calculation
- **OracleVault** — Chainlink price-driven deposits with 24h staleness check
- **CustomOracleVault** — Flexible oracle decimals support
- **VaultFactory** — Vault/strategy deployment with atomic initialization

## Audit Methodology

### Approach
- Phase 1: Scope determination and repository cloning
- Phase 2: Deep manual code review of all 119 source files
- Phase 3-5: Multi-angle vulnerability analysis via 3 parallel deep-analysis passes
- Phase 6: Cross-cutting review and false-positive elimination

### Hypotheses Tested: 53

**moe-core (16 hypotheses):**
1. MoePair._sendFee() non-standard token extraction — state consistency
2. _sendFee() manipulation for excess extraction
3. Local _totalSupply phantom increment — kLast consistency
4. MasterChef _modify() oldTotalSupply usage after amounts.update()
5. emergencyWithdraw() skipping extraRewarder.onModify() — accounting desync
6. Static pool shares div-by-zero in _getWeights()
7. VeMoe maxVeMoe cap using oldBalance instead of newBalance
8. powWad overflow in _calculateWeight() for large poolVotes
9. Unchecked block deltaVeMoe subtraction — int256 underflow
10. StableMoe reward loss when totalSupply becomes 0
11. StableMoe reserve underflow from direct token donation
12. First staker flash deposit to extract accumulated StableMoe rewards
13. BaseRewarder._update() — rewards > reserve causing DoS
14. BaseRewarder._setRewardParameters() — _balanceOfThis underflow
15. Cross-contract reentrancy via MoeStaking -> VeMoe -> StableMoe
16. Rewarder V1 (64-bit) vs V2 (128-bit) precision significance

**joe-v2 Liquidity Book (17 hypotheses):**
1. LBPair swap bin traversal — gas exhaustion via TreeMath
2. Flash loan fee bypass or oracle manipulation
3. Oracle TWAP manipulation at sample boundaries
4. PackedUint128Math — cross-half overflow corruption
5. Uint256x256Math — 512-bit multiplication edge cases
6. LBPair.mint() composition fee front-running
7. LBPair.burn() rounding favoring withdrawer
8. PriceHelper extreme bin ID precision loss
9. BinHelper getAmountOutOfBin rounding exploitation
10. LBFactory hooks — malicious hooks stealing funds
11. LBToken no safeTransfer callbacks
12. LBRouter multi-hop intermediate validation
13. Dynamic fee manipulation to zero
14. TreeMath 3-level bitmap boundary correctness
15. Hooks reentrancy (after-hooks outside guard)
16. FeeHelper dynamic fee computation overflow
17. Partial fills creating stuck states in _getAmountsIn/_getAmountsOut

**autopools + lb-rewarder (20 hypotheses):**
1. BaseVault first-depositor inflation attack
2. Withdrawal queue blocking / front-running
3. Strategy AUM fee cap circumvention via rapid rebalances
4. Strategy 1inch swap — operator stealing funds
5. OracleVault Chainlink 24h staleness sufficiency
6. SimpleVault cross-product overflow in unchecked block
7. BaseVault share price manipulation via donation
8. Strategy withdrawal queue rounding error accumulation
9. VaultFactory deployment initialization front-running
10. BaseVault emergency withdrawal accounting
11. LBHooksBaseRewarder reward precision across bins
12. LBHooksBaseRewarder _onHooksSet validation
13. LBHooksMCRewarder MasterChef integration — ERC20 wrapper isolation
14. LBHooksExtraRewarder chaining — independent exploitation
15. LBHooksManager TOCTOU race in createLBHooksMCRewarder
16. LBHooksBaseRewarder deltaAmounts handling for burns
17. Strategy operator trust model — maximum extractable value
18. BaseVault reentrancy during withdrawal processing
19. OracleVault price manipulation via Chainlink deviation
20. LBHooksBaseRewarder reward distribution to empty bins

## Findings Summary

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 0 |
| Informational | 7 |

**Result: 0 exploitable vulnerabilities found across 53 hypotheses.**

## Informational Findings

### INFO-01: MoeStaking Lacks Reentrancy Guard

**File:** `moe-core/src/MoeStaking.sol`

MoeStaking does not have a reentrancy guard despite calling two external contracts sequentially (`_veMoe.onModify()` then `_sMoe.onModify()`). The current code is safe because:
1. VeMoe.onModify() makes no external calls (library-internal only)
2. StableMoe updates all state BEFORE token transfers (effects-before-interactions)

However, if StableMoe distributes native tokens (address(0) reward), the user receives a callback that could re-enter MoeStaking. This is currently safe because all state updates precede the callback, but it relies on correct ordering being maintained in future modifications.

**Risk:** None currently. Fragile against future changes.

### INFO-02: Rewarder V1 Uses 64-bit Precision (MasterChef/VeMoe/StableMoe)

**File:** `moe-core/src/libraries/Rewarder.sol`

The V1 Rewarder uses `ACC_PRECISION_BITS = 64` while the V2 Rewarder (used by BaseRewarder) uses `NEW_ACC_PRECISION_BITS = 128`. The V1 precision is adequate for current parameters (max ~54 wei precision loss per update across all users), but the codebase itself acknowledges V2 should be preferred (Rewarder.sol comments).

**Risk:** Negligible precision loss. No exploitable impact.

### INFO-03: MoePair._sendFee() Architecture Diverges from UniV2

**File:** `moe-core/src/dex/MoePair.sol`, lines 100-135

MoePair extracts actual tokens from reserves as protocol fees instead of minting LP tokens to `feeTo`. While mathematically equivalent to the standard UniV2 approach (proven via formula analysis), the token-extraction design means actual tokens leave the pair contract during mint/burn operations. This could surprise integrators who assume standard UniV2 behavior.

**Risk:** Integration awareness. No exploitable impact.

### INFO-04: LBToken Omits ERC1155 Safe Transfer Callbacks

**File:** `joe-v2/src/LBToken.sol`

Explicitly documented design choice: "it doesn't do any call to the receiver contract to prevent reentrancy." Contracts that depend on `onERC1155Received` callbacks for accounting will not receive them. This is mitigated by the hooks system in LB v2.1.

**Risk:** Integration awareness. Documented design decision.

### INFO-05: LBPair After-Hooks Execute Outside Reentrancy Guard

**File:** `joe-v2/src/LBPair.sol`

The `afterSwap`, `afterMint`, and `afterBurn` hooks are called AFTER `_nonReentrantAfter()`, meaning hooks can re-enter the pair. This is safe because all state changes (reserves, parameters, oracle, bins, token transfers) are finalized before the guard is released. The hooks operate on consistent, finalized state.

**Risk:** Hook developers must be aware their callbacks are not protected by the pair's reentrancy guard. The pair itself is safe.

### INFO-06: Autopools Operator Has Unrestricted 1inch Swap Control

**File:** `autopools/src/Strategy.sol`, lines 284-308

The operator can call `swap()` with arbitrary 1inch executor and data. While `dstReceiver = address(this)` is enforced and `minReturnAmount > 0` is checked, the operator can set `minReturnAmount = 1` effectively allowing maximum slippage. This is by design — the operator is a trusted role appointed by the factory owner.

**Risk:** Trust model. Operator must be trusted. Not a bug.

### INFO-07: VeMoe Cap Uses oldBalance (Conservative Delay)

**File:** `moe-core/src/VeMoe.sol`, line 646

When a user stakes additional MOE, the veMoe cap is calculated using `oldBalance` (pre-stake), not `newBalance`. This means the benefit of increasing stake is delayed by one interaction. The design is conservative (user gets less, not more) and cannot be exploited for excess veMoe.

**Risk:** User experience. Not exploitable.

## Key Defensive Patterns Observed

### moe-core
- **Rewarder accDebtPerShare pattern:** Both V1 (64-bit) and V2 (128-bit) correctly implement floor-rounding that prevents underflow in `getDebt(acc, balance) - debt[account]`
- **Emergency escape hatches:** `emergencyWithdraw` (MasterChef), `emergencyUnsetBribes` (VeMoe) bypass external contracts
- **Balance-derived rewards (StableMoe):** `totalRewards = balanceOf - reserve` with proper `totalSupply == 0` guard
- **Supply cap with return value propagation:** `Moe.mint()` returns actual minted amount; MasterChef uses this for reward distribution
- **Conservative VeMoe bounds:** Alpha constrained to (0, 1e18], powWad within safe domain, weight capped at poolVotes
- **Bribe ordering:** `_bribesTotalVotes` updated BEFORE `bribe.onModify()` (line 619), old value passed as `oldTotalSupply` — correct for debt-per-share calculation

### joe-v2 Liquidity Book
- **PackedUint128Math dual overflow check:** `z < x || uint128(z) < uint128(x)` catches both upper and lower 128-bit overflow
- **Consistent rounding discipline:** `RoundDown` for outputs (user gets less), `RoundUp` for inputs/fees (user pays more)
- **Fee bounds at initialization:** `_setStaticFeeParameters` validates worst-case total fee < 10% using max volatility accumulator
- **TreeMath boundary correctness:** 3-level bitmap correctly handles bin 0 (returns type(uint24).max for "not found") and bin 16777215
- **Once-per-block oracle:** `block.timestamp > lastUpdatedAt` check prevents same-block manipulation; TWAP time-weighting dilutes brief spikes
- **Flash loan per-component check:** `balancesAfter.lt(reservesBefore.add(totalFees))` checks BOTH token X AND token Y independently
- **CEI pattern with after-hooks:** All state finalized before reentrancy guard release; after-hooks see consistent state

### lb-rewarder
- **X64/X128 fixed-point precision:** High-precision reward accumulation across bins with negligible per-update rounding loss
- **Hooks architecture integration:** All LB operations (swap/mint/burn/transfer) trigger reward state updates via before-hooks
- **MCRewarder ERC20 isolation:** Single token minted and locked in MasterChef; no external actor can mint
- **Extra rewarder chaining:** Parent authorization + `_isLinked()` double-check prevents independent exploitation
- **Balance-based MOE accounting (MCRewarder):** `balance - _totalUnclaimedRewards` ensures no permanent reward loss even during zero-liquidity periods

### autopools
- **Dead shares (1e6):** Permanent shares minted to vault on first deposit prevent inflation attacks
- **ReentrancyGuard on all public functions:** Combined with state-before-transfer pattern
- **AUM fee bounds:** Capped at 25% annual, 1 day max per rebalance, same-block = 0 fee
- **Atomic initialization:** VaultFactory creates and initializes in single transaction (no front-running window)
- **Withdrawal queue isolation:** `_totalAmountX`/`_totalAmountY` accounting prevents emergency withdrawal from double-counting queued amounts
- **uint128 input bounds (SimpleVault):** Prevents overflow in unchecked cross-product calculations

## Conclusion

The Merchant Moe protocol demonstrates strong security engineering across all four repositories. The codebase shows mature patterns including:

- Dual-precision rewarder system (V1 for legacy, V2 for new contracts) with correct accDebtPerShare mechanics
- Comprehensive hooks architecture in LB v2.1 with proper reentrancy considerations
- Dead-share protection in autopools preventing first-depositor inflation
- Balance-derived reward distribution in StableMoe with proper zero-supply guards
- Emergency escape hatches that bypass external contract calls

The non-standard `_sendFee()` in MoePair, while architecturally different from UniV2, is mathematically proven equivalent and correctly maintains the K invariant. The 53 hypotheses tested across all critical code paths revealed no exploitable vulnerabilities.

This audit joins the growing set of clean audits for well-established, battle-tested DeFi protocols built by experienced teams (LFJ/Trader Joe).
