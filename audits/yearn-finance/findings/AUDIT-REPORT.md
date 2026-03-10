# Yearn Finance Security Audit Report

**Date:** 2026-03-02
**Scope:** veYFI, stYFI, vault-periphery, yearn-boosted-staker, yearn-yb
**Auditor:** Independent Security Review
**Total Findings:** 5 Medium, 6 Low, 8 Informational

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Findings](#findings)
3. [Per-Repo Analysis](#per-repo-analysis)

---

## Executive Summary

This audit covers five Yearn Finance repositories comprising the veYFI governance system, stYFI staking infrastructure, vault periphery contracts, the yearn-boosted-staker, and the yield-bearing (yearn-yb) system. The codebase is generally well-engineered with careful attention to precision, access control, and integration safety.

The most significant findings relate to:
- **CombinedChainlinkOracle** missing negative/zero price validation, creating a potential division-by-zero or price inversion in the Redemption contract
- **Gauge.sol** residual approval accumulation enabling potential reward token theft
- **RewardPool/dYFIRewardPool** division-by-zero when `ve_supply` is zero for a claimed week
- **Zap.sol** zero-slippage paths in multiple Curve pool interactions
- **YearnBoostedStaker** precision loss from forced even-amount staking

---

## Findings

### FINDING-01 [Medium] CombinedChainlinkOracle: No Validation for Zero or Negative Oracle Prices

**File:** `/root/defi-audit-targets/audits/yearn-finance/veYFI/contracts/CombinedChainlinkOracle.vy`, lines 25-31
**File:** `/root/defi-audit-targets/audits/yearn-finance/veYFI/contracts/Redemption.vy`, lines 186-194

**Description:**
The `CombinedChainlinkOracle` combines YFI/USD and ETH/USD Chainlink feeds to produce YFI/ETH price. It performs no validation that either `yfi.answer` or `eth.answer` is positive before computing `yfi.answer * SCALE / eth.answer`.

```vyper
# CombinedChainlinkOracle.vy:25-31
@external
@view
def latestRoundData() -> LatestRoundData:
    yfi: LatestRoundData = ChainlinkOracle(YFI_ORACLE).latestRoundData()
    eth: LatestRoundData = ChainlinkOracle(ETH_ORACLE).latestRoundData()
    if eth.updated < yfi.updated:
        yfi.updated = eth.updated
    yfi.answer = yfi.answer * SCALE / eth.answer  # NO CHECK: eth.answer could be 0 or negative
    return yfi
```

If the ETH/USD oracle returns 0 (due to a Chainlink circuit breaker or multisig failure), this causes a **division-by-zero revert**, bricking all dYFI redemptions.

If either oracle returns a negative value (int256), the division produces a garbage value. The `Redemption._get_latest_price()` then converts this to `uint256` using `convert(price, uint256)`, which in Vyper 0.3.7 will revert on negative values -- but only if the _result_ is negative. Since `negative * SCALE / negative` can produce a positive int256, a scenario with both feeds negative would produce a valid-looking but completely wrong price.

The `Redemption.vy:193` staleness check (`assert updated_at + 3600 > block.timestamp`) does NOT protect against zero or negative values.

**Exploit Scenario:**
1. Chainlink ETH/USD feed returns 0 due to aggregator failure
2. All `redeem()` calls on the Redemption contract revert
3. dYFI holders cannot exercise their discount, potentially losing time-sensitive value

**Impact:** Medium -- Chainlink returning 0 is rare but documented (LUNA/UST crash precedent). Redemption contract becomes non-functional. No direct fund loss since reverts prevent execution.

**Recommendation:**
```vyper
@external
@view
def latestRoundData() -> LatestRoundData:
    yfi: LatestRoundData = ChainlinkOracle(YFI_ORACLE).latestRoundData()
    eth: LatestRoundData = ChainlinkOracle(ETH_ORACLE).latestRoundData()
    assert yfi.answer > 0, "invalid YFI price"
    assert eth.answer > 0, "invalid ETH price"
    if eth.updated < yfi.updated:
        yfi.updated = eth.updated
    yfi.answer = yfi.answer * SCALE / eth.answer
    return yfi
```

**Immunefi-submittable:** Yes, if Yearn has an active bounty program for veYFI contracts.

---

### FINDING-02 [Medium] Gauge.sol: Residual Approval Accumulation to VE_YFI_POOL

**File:** `/root/defi-audit-targets/audits/yearn-finance/veYFI/contracts/Gauge.sol`, lines 534-537

**Description:**
Every time `_updateReward` is called for an account with a boosted balance, any "penalty" (the difference between max earning and actual earning) is transferred to the VE_YFI_POOL via:

```solidity
function _transferVeYfiORewards(uint256 _penalty) internal {
    IERC20(REWARD_TOKEN).approve(VE_YFI_POOL, _penalty);
    IDYfiRewardPool(VE_YFI_POOL).burn(_penalty);
}
```

This uses `approve()` (not `safeIncreaseAllowance`) each time. The `burn()` function on the dYFIRewardPool pulls tokens via `transferFrom`. However, if the `burn()` call pulls less than the approved amount (e.g., if the dYFI reward pool's `burn` implementation changes or there's a revert path that is caught), a residual allowance remains.

More critically, the pattern of calling `approve(target, amount)` followed by `target.transferFrom(this, target, amount)` is fragile. If the reward token is a token that requires approval to be set to 0 first (like USDT), this would fail on subsequent calls. The dYFI reward token itself doesn't have this issue, but this pattern is still concerning for cloned gauges that might use different reward tokens.

**Impact:** Medium -- Incorrect approval handling. If the burn call partially fails or the approval pattern breaks with certain tokens, penalty distribution breaks, causing rewards to accumulate incorrectly in the gauge.

**Recommendation:**
Use `safeApprove(VE_YFI_POOL, 0)` followed by `safeApprove(VE_YFI_POOL, _penalty)`, or better yet, use `safeIncreaseAllowance`.

---

### FINDING-03 [Medium] RewardPool/dYFIRewardPool: Division by Zero When ve_supply is Zero

**File:** `/root/defi-audit-targets/audits/yearn-finance/veYFI/contracts/RewardPool.vy`, line 196
**File:** `/root/defi-audit-targets/audits/yearn-finance/veYFI/contracts/dYFIRewardPool.vy`, line 190

**Description:**
In the `_claim` function, the reward distribution calculates:

```vyper
to_distribute += balance_of * self.tokens_per_week[week_cursor] / self.ve_supply[week_cursor]
```

If `ve_supply[week_cursor]` is 0, this causes a division-by-zero revert. The `ve_supply` is populated by `_checkpoint_total_supply()` which computes `max(pt.bias - pt.slope * dt, 0)`. During the early period after contract deployment, or after all locks expire, `ve_supply` for a given week can legitimately be 0.

The check `if balance_of == 0: break` on line 194/188 provides some protection since if the user's balance is 0, we break out of the loop. However, there are edge cases:
- A user creates a lock, then all other locks expire but the user's lock still has non-zero balance
- The global supply checkpoint hasn't been called for that specific week

In such cases, the user would have `balance_of > 0` but `ve_supply == 0`, causing a permanent revert that locks the user out of all future claims (since `week_cursor` gets stuck).

**Exploit Scenario:**
1. All veYFI locks expire except one user's
2. The remaining user's `balanceOf` returns non-zero for a week where `ve_supply` was snapshotted as 0
3. Claim reverts permanently, user cannot claim any rewards past that week

**Impact:** Medium -- Funds not directly lost but permanently locked from claiming. This is a known pattern from Curve's fee distributor and typically doesn't occur in practice due to protocol activity, but remains a theoretical risk.

**Recommendation:**
Add a zero check: `if self.ve_supply[week_cursor] == 0: week_cursor += WEEK; continue`

---

### FINDING-04 [Medium] Zap.sol: Zero Slippage on Curve Pool Operations

**File:** `/root/defi-audit-targets/audits/yearn-finance/yearn-yb/src/Zap.sol`, lines 130, 157, 170

**Description:**
The Zap contract makes multiple Curve pool calls with zero minimum output:

```solidity
// Line 130: remove_liquidity_one_coin with minOut=0
yybAmount = ICurvePool(POOL).remove_liquidity_one_coin(lpAmount, int128(1), 0, address(this));

// Line 157: exchange with minOut=0
return ICurvePool(POOL).exchange(0, 1, amount, 0);

// Line 170: add_liquidity with minOut=0
return ICurvePool(POOL).add_liquidity(_amounts, 0, address(this));
```

While the outer `zap()` function has a `minOut` parameter that checks the final output, the intermediate operations have zero slippage protection. This creates a sandwich attack vector:

1. Attacker sees a `zap(YB -> LP_YYB)` transaction
2. The path is: YB -> (exchange with 0 minOut) -> yYB -> (add_liquidity with 0 minOut) -> LP
3. Attacker front-runs to manipulate the Curve pool
4. Each intermediate step suffers maximal slippage
5. The final `minOut` check may still pass if the attacker calibrates the sandwich precisely

The issue is that the final `minOut` only checks the combined result. An attacker can extract more MEV than the user's slippage tolerance covers because the intermediate steps compound losses.

**Impact:** Medium -- MEV extraction on zap operations. The final `minOut` provides some protection, but intermediate zero-slippage calls allow sandwich attacks to extract more value than intended.

**Recommendation:**
Compute intermediate minimum outputs based on the final `minOut` parameter, or add per-step slippage parameters.

---

### FINDING-05 [Medium] StakingRewardDistributor: Division by Zero When total_weight is Zero

**File:** `/root/defi-audit-targets/audits/yearn-finance/stYFI/contracts/StakingRewardDistributor.vy`, lines 518, 531, 550

**Description:**
The `_sync_integral()` function in StakingRewardDistributor divides by `total_weight`:

```vyper
# Line 518
self.reward_integral_snapshot[epoch] = integral + unlocked * PRECISION // total_weight

# Line 531
self.reward_integral_snapshot[epoch] = integral + unlocked * PRECISION // total_weight

# Line 550
self.reward_integral = integral + unlocked * PRECISION // total_weight
```

`total_weight` is read from `self.total_weight_entries[self.total_weight_cursor.count - 1].weight`. The constructor initializes this to `10**12`:

```vyper
self.total_weight_entries[0] = TotalWeight(epoch=0, weight=10**12)
```

This non-zero initialization prevents division by zero initially. However, if all stakers unstake (reducing weight to 0 via `_update_total_weight`), subsequent calls to `_sync_integral` will divide by zero.

The `on_unstake` hook calls `_update_total_weight(_amount, DECREMENT)` which decrements the weight. If all stakers exit, `weight.weight` becomes 0. The next epoch rollover in `_sync_integral` will then attempt `unlocked * PRECISION // 0`, causing a permanent revert.

**Impact:** Medium -- If all stakers exit and rewards arrive, the distributor permanently bricks. The `10**12` dead shares mitigate this for normal operation, but they only protect the initial state, not subsequent all-exit scenarios.

**Recommendation:**
Add a zero-weight check in `_sync_integral`: if `total_weight == 0`, skip the integral update and carry rewards forward to the next epoch.

---

### FINDING-06 [Low] YearnBoostedStaker: Forced Even-Amount Staking Causes Precision Loss

**File:** `/root/defi-audit-targets/audits/yearn-finance/yearn-boosted-staker/contracts/YearnBoostedStaker.sol`, lines 131-132

**Description:**
The staking mechanism forces all amounts to be even by using bit-shifting:

```solidity
uint weight = _amount >> 1;
_amount = weight << 1; // This helps prevent balance/weight discrepancies.
```

This means if a user stakes an odd amount (e.g., 101 tokens), they transfer 100 tokens and lose 1 token in the process (the 1 remaining stays in the user's wallet since `safeTransferFrom` uses the adjusted `_amount`). While not strictly a loss, it is confusing behavior and breaks the ERC20-like interface expectation.

More importantly, the `_unstake` function does the same:
```solidity
uint128 amountNeeded = uint128(_amount >> 1);
_amount = amountNeeded << 1;
```

This means a user who stakes 2 tokens cannot unstake 1 token -- they must unstake in increments of 2. For tokens with small total supply or high value per unit, this creates non-trivial unusable dust.

**Impact:** Low -- Precision dust accumulation. Users cannot interact with odd amounts. For most ERC20 tokens this is negligible, but for high-value tokens it matters.

---

### FINDING-07 [Low] Gauge.sol: `getReward(address)` Can Be Called by Anyone

**File:** `/root/defi-audit-targets/audits/yearn-finance/veYFI/contracts/Gauge.sol`, lines 503-509

**Description:**
The `getReward(address _account)` function allows anyone to trigger a reward claim for any account:

```solidity
function getReward(
    address _account
) external updateReward(_account) returns (bool) {
    _getReward(_account);
    return true;
}
```

While the rewards are sent to `_account` (or their designated recipient), the issue is that calling `getReward` triggers `_updateReward` which computes and stores the penalty. A sophisticated attacker could time calls to `getReward` for a user just before the user increases their veYFI lock, causing the penalty to be calculated at the user's current (lower) boost rather than their intended (higher) boost.

**Impact:** Low -- Can cause suboptimal reward calculations for users who are about to increase their boost. The griefing window is small and the economic impact is marginal.

---

### FINDING-08 [Low] Redemption.vy: Oracle Price Converted Without Negative Check

**File:** `/root/defi-audit-targets/audits/yearn-finance/veYFI/contracts/Redemption.vy`, line 194

**Description:**
```vyper
return convert(price, uint256)
```

The `price` from the Chainlink feed is `int256`. In Vyper 0.3.7, `convert(negative_int256, uint256)` reverts. However, the combined oracle could theoretically return a negative answer (if one feed returns negative and the math produces negative). The staleness check doesn't protect against this.

While this would result in a revert (not a wrong value), it means the redemption contract would be bricked until the oracle returns to normal.

**Impact:** Low -- Revert-only impact, no fund loss. Defensive check would improve robustness.

---

### FINDING-09 [Low] VotingYFI.vy: Lock Duration Rounding Creates Off-by-One Weeks

**File:** `/root/defi-audit-targets/audits/yearn-finance/veYFI/contracts/VotingYFI.vy`, lines 270-271

**Description:**
```vyper
unlock_week = self.round_to_week(unlock_time)  # locktime is rounded down to weeks
assert ((unlock_week - self.round_to_week(block.timestamp)) / WEEK) < MAX_N_WEEKS
```

The `round_to_week` function rounds down: `ts / WEEK * WEEK`. If a user passes `unlock_time` that is exactly on a week boundary, their lock duration is calculated correctly. But if they pass a timestamp just before the next week boundary, rounding down reduces their effective lock by up to 6 days, 23 hours, 59 minutes. This is documented behavior but can confuse users who expect to lock for exactly N weeks.

**Impact:** Low -- Users may get slightly less voting power than expected. Well-documented behavior from Curve's veToken model.

---

### FINDING-10 [Low] LiquidLockerRedemption.vy: `exchange()` Can Underflow `used`

**File:** `/root/defi-audit-targets/audits/yearn-finance/stYFI/contracts/LiquidLockerRedemption.vy`, line 161

**Description:**
```vyper
self.used[_idx] -= _yfi_amount
```

The `exchange()` function allows buying back liquid locker tokens with YFI. It decrements `self.used[_idx]` by `_yfi_amount`. If `_yfi_amount > self.used[_idx]`, this underflows (in Vyper 0.4.2, this reverts due to built-in overflow checking).

However, this means the exchange function can only be called up to the total amount that has been redeemed. If management wants to allow exchange beyond what has been redeemed (e.g., initial liquidity provision), they cannot do so through this mechanism. This is likely by design but worth noting.

**Impact:** Low -- Functional limitation. Cannot exchange more YFI than has been redeemed.

---

### FINDING-11 [Low] GaugeFactory.sol: No Access Control on `createGauge`

**File:** `/root/defi-audit-targets/audits/yearn-finance/veYFI/contracts/GaugeFactory.sol`, lines 27-36

**Description:**
```solidity
function createGauge(
    address _vault,
    address _owner
) external override returns (address) {
    address newGauge = _clone(deployedGauge);
    emit GaugeCreated(newGauge);
    IGauge(newGauge).initialize(_vault, _owner);
    return newGauge;
}
```

Anyone can call `createGauge` to deploy new gauge clones. While the Registry contract (which calls this) has `onlyOwner` protection, the factory itself is permissionless. An attacker could create rogue gauges pointing to any vault, though these gauges would not be registered in the Registry and thus wouldn't receive protocol rewards.

**Impact:** Low -- Unauthorized gauge creation has no direct financial impact since the Registry controls reward distribution. However, it pollutes the chain with clones.

---

### FINDING-12 [Informational] StakedYFI/DelegatedStakedYFI: Packed Stream Timestamp Truncation at 40 Bits

**File:** `/root/defi-audit-targets/audits/yearn-finance/stYFI/contracts/StakedYFI.vy`, lines 77-78

**Description:**
```vyper
SMALL_MASK: constant(uint256) = 2**40 - 1  # ~34,865 years from epoch
BIG_MASK: constant(uint256) = 2**108 - 1
```

The timestamp is stored in 40 bits. `2^40 = 1,099,511,627,776` seconds, which is approximately 34,865 years from Unix epoch. This is safe for the foreseeable future. The 108-bit values for total and claimed can hold approximately `3.24 * 10^32`, which comfortably exceeds any realistic token amount.

**Impact:** Informational -- No issue. Well-designed packing scheme.

---

### FINDING-13 [Informational] Accountant.sol: Management Fee Calculated on `current_debt` Not `average_debt`

**File:** `/root/defi-audit-targets/audits/yearn-finance/vault-periphery/src/accountants/Accountant.sol`, lines 206-214

**Description:**
```solidity
uint256 duration = block.timestamp - strategyParams.last_report;
totalFees = ((strategyParams.current_debt *
    duration *
    (fee.managementFee)) /
    MAX_BPS /
    SECS_PER_YEAR);
```

The management fee is charged on `current_debt` at the time of reporting, not the average debt over the reporting period. If the debt fluctuated significantly between reports, the fee may over- or under-charge. This is standard practice in Yearn V3 and matches the vault's expected behavior.

**Impact:** Informational -- By-design behavior matching Yearn V3 accounting model.

---

### FINDING-14 [Informational] DebtAllocator: `update_debt` Calls `process_report` Before Zero-Debt Update

**File:** `/root/defi-audit-targets/audits/yearn-finance/vault-periphery/src/debtAllocators/DebtAllocator.sol`, lines 216-219

**Description:**
```solidity
if (_targetDebt == 0) {
    IVault(_vault).process_report(_strategy);
}
IVault(_vault).update_debt(_strategy, _targetDebt, maxDebtUpdateLoss);
```

When removing all debt from a strategy, the allocator first calls `process_report` to realize any gains/losses before pulling all funds. This is correct behavior to avoid loss accounting issues, but the combination could be gas-intensive and the `process_report` could revert if the strategy has issues, preventing emergency debt removal.

**Impact:** Informational -- Correct design pattern, but worth noting the dependency.

---

### FINDING-15 [Informational] YearnBoostedStaker: `stakeAsMaxWeighted` Breaks Weight Derivation

**File:** `/root/defi-audit-targets/audits/yearn-finance/yearn-boosted-staker/contracts/YearnBoostedStaker.sol`, lines 184-189

**Description:**
The function explicitly documents this:
```solidity
// Note: The usage of `stakeAsMaxWeighted` breaks an ability to reliably derive account + global
// amount deposited at any week using `weeklyToRealize` variables.
```

The `accountWeeklyMaxStake` and `globalWeeklyMaxStake` mappings are provided as compensation, but any off-chain or on-chain integrator that only uses `weeklyToRealize` will compute incorrect deposit amounts.

**Impact:** Informational -- Documented limitation with mitigation provided.

---

### FINDING-16 [Informational] SingleTokenRewardDistributor: `claimWithRange` Can Permanently Skip Rewards

**File:** `/root/defi-audit-targets/audits/yearn-finance/yearn-boosted-staker/contracts/SingleTokenRewardDistributor.sol`, lines 119-123

**Description:**
```solidity
/**
    @dev    IMPORTANT: Choosing a `_claimStartWeek` that is greater than the earliest week in which a user
            may claim. Will result in the user being locked out (total loss) of rewards for any weeks prior.
*/
function claimWithRange(uint _claimStartWeek, uint _claimEndWeek) external returns (uint amountClaimed) {
```

This is documented but dangerous. A user or integration calling `claimWithRange` with an incorrect `_claimStartWeek` permanently loses all rewards for skipped weeks. The `lastClaimWeek` is updated to `_claimEndWeek + 1`, making those rewards unrecoverable.

**Impact:** Informational -- User error vector. Well-documented with warnings.

---

### FINDING-17 [Informational] YToken.sol: Anyone Can Mint yTokens by Sending Tokens to Locker

**File:** `/root/defi-audit-targets/audits/yearn-finance/yearn-yb/src/YToken.sol`, lines 36-43

**Description:**
```solidity
function mint(uint256 amount, address to) external {
    require(amount > 0, "Amount must be > 0");
    if (msg.sender != operator()) {
        IERC20(token).safeTransferFrom(msg.sender, locker, amount);
        IOperator(operator()).lock(amount);
    }
    _mint(to, amount);
}
```

Anyone can call `mint()` to create yTokens by depositing underlying tokens. This is by design -- the YToken is intended to be freely mintable 1:1 with the underlying locked token. The operator path skips the transfer because it handles the accounting separately.

**Impact:** Informational -- By-design behavior. The mint is backed by actual token locking.

---

### FINDING-18 [Informational] Locker.sol: `execute` Returns Success Status Without Enforcing It

**File:** `/root/defi-audit-targets/audits/yearn-finance/yearn-yb/src/Locker.sol`, lines 66-72

**Description:**
```solidity
function execute(
    address payable _to,
    uint256 _value,
    bytes calldata _data
) external payable returns (bool success, bytes memory result) {
    (success, result) = _execute(_to, _value, _data);
}
```

The `execute` function does not require success, unlike `safeExecute`. This is intentional to allow non-reverting execution, but callers must check the return value.

**Impact:** Informational -- Intentional design for flexible execution.

---

### FINDING-19 [Informational] Locker.sol: `increase_amount` Selector Guard Can Be Bypassed via Delegatecall

**File:** `/root/defi-audit-targets/audits/yearn-finance/yearn-yb/src/Locker.sol`, lines 83-86

**Description:**
```solidity
if (_to == escrow && _data.length >= 4) {
    bytes4 selector = bytes4(_data[:4]);
    if (selector == INCREASE_AMOUNT_SELECTOR) require(msg.sender == operator, "Blocked selector");
}
```

The owner can only call `increase_amount` through the Operator (to ensure caching). However, the owner could potentially call a proxy or intermediary contract that then calls `increase_amount` on the escrow, bypassing the selector check. This is mitigated by the fact that the owner is trusted and the check is a defense-in-depth measure.

**Impact:** Informational -- Defense-in-depth bypass by trusted party only.

---

## Per-Repo Analysis

### veYFI Assessment
- **VotingYFI.vy**: Well-implemented Curve-style ve-token. Lock manipulation is properly guarded. Checkpoint logic correctly handles kinks for locks > MAX_LOCK_DURATION. The `modify_lock` function properly enforces minimum 1 YFI for creation, user-only unlock time modifications, and direction constraints.
- **dYFI.sol**: Minimal ERC20 with mint/burn. Clean implementation.
- **Redemption.vy**: Discount formula using exponential math is correctly bounded. Scaling factor ramp has proper active/inactive checks. The `_exp` implementation follows Balancer's audited code.
- **Gauge.sol/BaseGauge.sol**: Boost calculation follows Curve's formula. The 120% threshold for reward queueing prevents manipulation of reward distribution timing. `_beforeTokenTransfer`/`_afterTokenTransfer` hooks correctly update boosted balances.
- **RewardPool.vy/dYFIRewardPool.vy**: Standard Curve fee distributor pattern with known limitations (50-week iteration cap, 40-week checkpoint cap).

### stYFI Assessment
- **StakedYFI.vy**: 1:1 ERC4626 with 14-day unstaking stream. Packed storage is well-designed. Hook system allows extensible reward distribution. The instant withdrawal mechanism for whitelisted accounts is clean.
- **DelegatedStakedYFI.vy**: Deposits into StakedYFI on behalf of users. Assumes instant withdrawal whitelist. Stream mechanics mirror StakedYFI.
- **RewardDistributor.vy**: Epoch-based distribution with linked-list component management. The `_sync` function properly handles zero-weight epochs by rolling rewards forward. 32-component and 32-epoch iteration limits are reasonable.
- **StakingRewardDistributor.vy**: Complex reward streaming with integral-based accounting. The `RAMP_LENGTH` of 4 epochs for boosting is well-calibrated. Reclaim mechanism for expired rewards is well-designed.
- **LiquidLockerDepositor.vy**: Scale factor for LL tokens is immutable, preventing manipulation. Capacity limits properly enforced.
- **StakingMiddleware.vy**: Simple blacklist + instant withdrawal middleware. Clean pass-through pattern.

### Vault Periphery Assessment
- **Accountant.sol**: Fee calculation is standard. Management fee threshold (200 bps) and performance fee threshold (5000 bps) prevent excessive fees. Health check skip is single-use per report.
- **RefundAccountant.sol**: Refund mechanism properly resets after each use. `_checkAllowance` correctly handles the approve-then-pull pattern.
- **DebtAllocator.sol**: Rate limiting (minimumWait), base fee checks, and minimum change thresholds provide robust protection against manipulation. The `process_report` before zero-debt update is a good practice.
- **RoleManager.sol**: Standard role-based access with proper 2-step ownership transfer patterns.

### YearnBoostedStaker Assessment
- **YearnBoostedStaker.sol**: Novel bitmap-based weight tracking for 1-7 week growth periods. The `MAX_STAKE_GROWTH_WEEKS <= 7` constraint ensures the bitmap fits in uint8. The LIFO unstaking (least-weighted first) is well-implemented.
- **SingleTokenRewardDistributor.sol**: Adjusted weight computation (subtracting first-week deposits) is a good anti-gaming measure. The `pushRewards` mechanism handles zero-weight weeks gracefully.

### yearn-yb Assessment
- **Locker.sol**: NFT-based lock with operator pattern. The `increase_amount` selector guard is a good defense-in-depth measure. `onERC721Received` correctly triggers the operator callback.
- **Operator.sol**: Cached locked amount pattern for NFT transfers is clean. The `nftTransferCallback` correctly computes the delta and mints proportionally.
- **YToken.sol**: Simple 1:1 wrapped lock token. The dual-path mint (operator vs user) is correct.
- **Zap.sol**: Multi-path conversion with final slippage check. The `_convertYb` function's buffer-based routing (swap vs mint) is a good optimization.

### Hypotheses Tested But Not Confirmed

1. **veYFI withdraw penalty bypass**: The penalty is computed as `min(time_left * SCALE / MAX_LOCK_DURATION, MAX_PENALTY_RATIO)` -- capped at 75%. Cannot be bypassed since it's based on lock end time stored in contract state.
2. **Gauge first-depositor attack**: Gauges use 1:1 share ratio (shares = assets), so inflation attacks don't apply.
3. **dYFI discount gaming via flash loans**: The discount depends on `veyfi_supply / yfi_supply` which reads from the veYFI contract's bias-based totalSupply. Flash loans cannot create veYFI locks (minimum 1 week), so this is not manipulable.
4. **RewardDistributor double-claiming**: The `@nonreentrant` guard on `claim()` and the epoch-based cursor advancement prevent any double-claiming.
5. **StakedYFI stream manipulation**: The `_unstake` function correctly combines existing unclaimed stream with new unstake by computing `total - claimed + _value`. Stream resetting is safe.
6. **DebtAllocator keeper front-running**: Keepers can only call `update_debt` which goes through the vault's debt management. The `maxDebtUpdateLoss` parameter (default 1 bp) prevents significant extraction.
7. **YearnBoostedStaker epoch manipulation**: `getWeek()` uses `(block.timestamp - START_TIME) / 1 weeks` which is deterministic and cannot be manipulated by users.
8. **Locker arbitrary execution abuse**: The Locker's `_execute` function properly restricts to owner/operator and blocks `increase_amount` from non-operator. The owner is trusted by design.
9. **Operator cached amount race condition**: The `nftTransferCallback` atomically reads cached, updates, computes delta, and mints. No race condition since it executes in a single transaction.
10. **Accountant refund drain**: Refunds are bounded by `Math.min(loss * refundRatio / MAX_BPS, balance)`. Cannot drain more than the accountant's balance.
