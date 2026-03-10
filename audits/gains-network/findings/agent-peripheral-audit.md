# Gains Network (gTrade) Peripheral Contracts -- Security Audit

**Auditor:** Senior Smart Contract Security Auditor
**Date:** 2026-03-02
**Scope:** GNSStaking, ERC20Bridge, OTC, GTokenOpenPnlFeed, TradingStorageUtils, GToken

---

## Executive Summary

Audit of the Gains Network peripheral contracts: staking, bridge, OTC module, open-PnL oracle feed, trading storage, and the GToken vault. The codebase is generally well-written, with appropriate use of SafeERC20, explicit precision handling, and reasonable access controls. However, several findings across varying severity levels were identified.

**Findings Summary:**
| Severity | Count |
|----------|-------|
| MEDIUM   | 3     |
| LOW      | 4     |
| INFORMATIONAL | 3 |

---

## FINDING-001: OTC GNS Distribution Rounding Loss Allows Permanent Token Leakage

**Severity:** MEDIUM

**File:** `/root/defi-audit-targets/audits/gains-network/contracts/facets/GNSOtc/contracts/libraries/OtcUtils.sol`
**Lines:** 186-194

**Description:**

The `_calculateGnsDistribution` function computes the GNS distribution for treasury, staking, and burn using integer division independently for each share:

```solidity
function _calculateGnsDistribution(
    uint256 _gnsAmount
) internal view returns (uint256 treasuryAmountGns, uint256 stakingAmountGns, uint256 burnAmountGns) {
    IOtc.OtcConfig storage config = _getStorage().otcConfig;

    treasuryAmountGns = (_gnsAmount * config.treasuryShareP) / 100 / ConstantsUtils.P_10;
    stakingAmountGns = (_gnsAmount * config.stakingShareP) / 100 / ConstantsUtils.P_10;
    burnAmountGns = (_gnsAmount * config.burnShareP) / 100 / ConstantsUtils.P_10;
}
```

The shares are validated to sum to `100 * P_10` (line 37). However, because each division truncates independently, the sum `treasuryAmountGns + stakingAmountGns + burnAmountGns` can be up to 2 wei less than `_gnsAmount` per OTC execution. These "dust" tokens remain stuck in the diamond contract forever.

More importantly, the caller transfers `gnsAmount` GNS tokens into the protocol (line 76), but only `treasuryAmountGns + stakingAmountGns + burnAmountGns` are distributed. The remainder accumulates in the contract with no sweep mechanism.

**Example:**
- `_gnsAmount` = 1000000000000000001 (1 GNS + 1 wei)
- `treasuryShareP` = 33.33% = 3_333_000_000
- `stakingShareP` = 33.33% = 3_333_000_000
- `burnShareP` = 33.34% = 3_334_000_000 (sum = 100 * P_10)
- `treasuryAmountGns` = (1000000000000000001 * 3333000000) / 100 / 1e10 = 333300000000000000
- `stakingAmountGns` = 333300000000000000
- `burnAmountGns` = 333400000000000000
- Sum = 999_999_999_999_999_999_999 / 1e15... wait, let me recalculate carefully:
  - treasury = 1000000000000000001 * 3333000000 / 100 / 10000000000 = 333300000000000000 (0.3333 GNS)
  - staking = same = 333300000000000000
  - burn = 1000000000000000001 * 3334000000 / 100 / 10000000000 = 333400000000000000
  - Total distributed = 999_999_999_999_999_999 ... we lost ~1 wei

Over thousands of OTC trades, this accumulated dust becomes non-trivial.

**Impact:** Low financial impact per trade (dust amounts), but persistent leakage over time with no recovery mechanism. The diamond contract's GNS balance grows monotonically with trapped dust.

**Recommendation:**
Compute the third share as a remainder rather than dividing independently:

```solidity
treasuryAmountGns = (_gnsAmount * config.treasuryShareP) / 100 / ConstantsUtils.P_10;
stakingAmountGns = (_gnsAmount * config.stakingShareP) / 100 / ConstantsUtils.P_10;
burnAmountGns = _gnsAmount - treasuryAmountGns - stakingAmountGns;
```

---

## FINDING-002: Bridge `executePendingClaim` Can Return Zero Tokens Without Clearing The Claim

**Severity:** MEDIUM

**File:** `/root/defi-audit-targets/audits/gains-network/contracts/bridge/contracts/abstract/ERC20BridgeRateLimiter.sol`
**Lines:** 85-115

**Description:**

The `executePendingClaim` function attempts to mint tokens for a user whose bridge was throttled. However, if the epoch limit has already been completely consumed (`currentEpochCount >= epochLimit`), the `claimAmount` computed on line 94-97 will be zero:

```solidity
uint claimAmount = Math.min(
    pendingClaim.amount,
    epochLimit - Math.min(epochLimit, currentEpochCount)  // = 0 when currentEpochCount >= epochLimit
);
```

When `claimAmount == 0`:
1. `pendingClaim.amount -= 0` (no change to amount)
2. `pendingClaim.amount > 0` is true, so `claimTimestamp` is pushed forward by another `epochDuration` (line 102)
3. `token.mint(receiver, 0)` is called (mints nothing)
4. `PendingClaimExecuted` event emits with amount=0

**Attack vector:** An attacker (or any caller) can repeatedly call `executePendingClaim` for a victim once `claimTimestamp` is met, but in an epoch where the limit is already exhausted. Each call pushes the victim's `claimTimestamp` forward by another full `epochDuration`, effectively indefinitely delaying their claim.

This is possible because:
- `executePendingClaim` is callable by **anyone** (not just the receiver)
- There is no check that `claimAmount > 0`
- Each call resets the delay

**Impact:** An attacker can grief a user by repeatedly calling `executePendingClaim` at the end of each epoch (when the epoch limit is consumed). Each call adds `epochDuration` (30 min to 1 week) of delay. At a cost of gas only, an attacker can delay a bridge claim indefinitely.

**Recommendation:**
Add a check that `claimAmount > 0` before updating state:

```solidity
require(claimAmount > 0, "EPOCH_LIMIT_REACHED");
```

Or alternatively, only update `claimTimestamp` when `claimAmount < pendingClaim.amount` and `claimAmount > 0`.

---

## FINDING-003: GNSStaking Reward Precision Loss Truncates Low-Decimal Token Rewards For Small Stakers

**Severity:** MEDIUM

**File:** `/root/defi-audit-targets/audits/gains-network/contracts/staking-impl/contracts/core/GNSStaking.sol`
**Lines:** 159-165, 262-274, 463-472

**Description:**

The staking contract uses a `precisionDelta` to scale between token decimals and 1e18 internal accounting. The `_pendingTokens` function divides by `precisionDelta`:

```solidity
function _pendingTokens(
    uint128 _currDebtToken,
    uint128 _lastDebtToken,
    uint128 _precisionDelta
) private pure returns (uint128) {
    return (_currDebtToken - _lastDebtToken) / _precisionDelta;
}
```

For a 6-decimal token like USDC, `precisionDelta = 1e12`. This means any pending rewards smaller than `1e12` in internal 1e18 units (i.e., less than 0.000001 USDC = 1 micro-USDC) are truncated to zero and effectively lost.

The issue manifests when `distributeReward` is called:

```solidity
rewardState.accRewardPerGns += uint128((_amountToken * rewardState.precisionDelta * 1e18) / gnsBalance);
```

If `gnsBalance` is large and `_amountToken` is modest, the increment to `accRewardPerGns` is small. When a staker with a relatively small position calls `harvestToken`, their `_currDebtToken - _lastDebtToken` may be less than `precisionDelta`, resulting in zero reward payout, while the internal debt is updated.

Concretely: if `gnsBalance = 10,000,000e18` (10M GNS) and 100 USDC is distributed, `accRewardPerGns` increases by `(100e6 * 1e12 * 1e18) / 10,000,000e18 = 10,000,000,000` (1e10). A user with 1 GNS staked gets `_currDebtToken` increment of `1e18 * 1e10 / 1e18 = 1e10`, and `_pendingTokens = 1e10 / 1e12 = 0`. They get nothing.

Importantly, `_harvestToken` still updates their `debtToken` to the new value (line 269), meaning these lost rewards cannot be recovered later -- they are permanently forfeited.

**Impact:** Small stakers lose reward tokens on every harvest. The lost tokens remain in the contract without any recovery mechanism. For 6-decimal tokens at realistic staking quantities, any staker with less than ~100 GNS staked (out of 10M total) will lose a fraction of their USDC rewards each distribution cycle.

**Recommendation:**
Track accumulated "dust" per user per token, and only update debtToken by the amount actually paid out:

```solidity
uint128 rawPending = _currDebtToken - _lastDebtToken;
pendingTokens = rawPending / _precisionDelta;
// Only update debt by the actually-claimed amount (scaled back up)
userInfo.debtToken = _lastDebtToken + (pendingTokens * _precisionDelta);
```

This preserves the remainder for the next harvest.

---

## FINDING-004: GTokenOpenPnlFeed `forceNewEpoch` Uses Stale PnL When Oracle Responses Are Incomplete

**Severity:** LOW

**File:** `/root/defi-audit-targets/audits/gains-network/contracts/pnlfeed/contracts/v6.3/GTokenOpenPnlFeed.sol`
**Lines:** 332-359

**Description:**

In `startNewEpoch`:

```solidity
int newEpochOpenPnl = nextEpochValues.length >= requestsCount ?
    average(nextEpochValues) : int(currentEpochPositiveOpenPnl);
```

When `forceNewEpoch` is called (which is permissionless after the timeout), if `nextEpochValues.length < requestsCount`, the fallback is `int(currentEpochPositiveOpenPnl)` -- meaning the new epoch uses the **previous epoch's** positive open PnL value. This is by design as a safety mechanism, but creates a scenario where:

1. Actual open PnL has changed significantly since the last epoch
2. Oracles are slow or some requests failed (common during network congestion)
3. `forceNewEpoch` is called, locking in a stale value
4. The stale value persists until the next successful epoch

Since `forceNewEpoch` is permissionless, a strategic actor could call it at precisely the right moment (when oracles are delayed but PnL has moved unfavorably) to lock in a favorable stale price.

**Impact:** The PnL feed may use stale data, which affects `shareToAssetsPrice` in GToken. However, the existing `maxAccOpenPnlDelta` parameter in GToken caps the maximum per-epoch price change, limiting exploitability. The impact is bounded but still creates a window for information asymmetry.

**Recommendation:**
Consider requiring a minimum number of oracle responses (e.g., at least 1) before allowing `forceNewEpoch` to proceed, or adding a longer timeout when using the fallback stale value.

---

## FINDING-005: Bridge Rate Limiter Epoch Can Be Gamed At Boundaries

**Severity:** LOW

**File:** `/root/defi-audit-targets/audits/gains-network/contracts/bridge/contracts/abstract/EpochBasedLimiter.sol`
**Lines:** 95-103

**Description:**

The `tryUpdateEpoch` function resets `currentEpochCount` to zero when a new epoch starts:

```solidity
function tryUpdateEpoch() public {
    if (block.timestamp >= currentEpochStart + epochDuration) {
        currentEpoch ++;
        currentEpochStart = block.timestamp;
        currentEpochCount = 0;

        emit EpochStarted(currentEpoch, currentEpochStart);
    }
}
```

A user can effectively get 2x the rate limit by timing transactions around epoch boundaries:
1. Use up to `epochLimit` just before the epoch ends
2. Wait for the next block (new epoch)
3. Immediately use up to `epochLimit` again

Within a very short wall-clock time (2 blocks), the user can mint up to `2 * epochLimit` tokens. Since `epochDuration` is a minimum of 30 minutes, this is not catastrophic but effectively doubles the burst capacity.

Note also that `tryUpdateEpoch` uses `block.timestamp` for `currentEpochStart` rather than `currentEpochStart + epochDuration`, which means epoch drift accumulates. If an epoch starts late (e.g., no transactions for a while), the next epoch's countdown starts from that late timestamp, not from when it should have started.

**Impact:** The rate limiting is effectively 2x the configured limit in burst scenarios. Combined with epoch drift, this weakens the protection the rate limiter is intended to provide.

**Recommendation:**
Set `currentEpochStart = currentEpochStart + epochDuration` instead of `block.timestamp` to prevent drift. For the double-spend issue, consider tracking a rolling window rather than discrete epochs.

---

## FINDING-006: GNSStaking 100-Second Cooldown Is Too Short For Front-Running Protection

**Severity:** LOW

**File:** `/root/defi-audit-targets/audits/gains-network/contracts/staking-impl/contracts/core/GNSStaking.sol`
**Lines:** 23, 93-99, 585-610, 617-638

**Description:**

The `UNSTAKING_COOLDOWN_SECONDS` is set to 100 seconds. The `notInCooldown` modifier only applies to `unstakeGns`, not to `harvestToken` / `harvestTokens`. The workflow for front-running reward distribution is:

1. Monitor mempool for `distributeReward` transactions
2. Front-run with `stakeGns` (large amount)
3. `distributeReward` executes, `accRewardPerGns` increases based on new `gnsBalance` (which includes attacker's stake)
4. Wait 100 seconds
5. Call `unstakeGns` to withdraw (which auto-harvests rewards)

100 seconds is trivially short -- a standard MEV bot can easily sequence this. The attacker captures a proportional share of rewards by flash-staking for only ~2 blocks worth of time.

The `stakeGns` function auto-harvests existing rewards before increasing the stake (line 590-591), and then syncs debt (line 602), which is correct. The issue is that the cooldown is too short to provide meaningful protection against just-in-time liquidity attacks on reward distributions.

**Impact:** MEV bots can capture disproportionate staking rewards by front-running `distributeReward` calls with 100 seconds of capital deployment. This dilutes rewards for honest long-term stakers.

**Recommendation:**
Increase the cooldown period to at least 1 epoch or 24 hours. Alternatively, implement a "warm-up" period where newly staked tokens don't earn rewards for the first N seconds/blocks after staking.

---

## FINDING-007: GToken `scaleVariables` Integer Division Loses Precision For `accPnlPerToken` On Deposits/Withdrawals

**Severity:** LOW

**File:** `/root/defi-audit-targets/audits/gains-network/contracts/gtoken-impl/contracts/core/GToken.sol`
**Lines:** 555-569

**Description:**

```solidity
function scaleVariables(uint256 shares, uint256 assets, bool isDeposit) private {
    uint256 supply = totalSupply();

    if (accPnlPerToken < 0) {
        accPnlPerToken =
            (accPnlPerToken * int256(supply)) /
            (isDeposit ? int256(supply + shares) : int256(supply - shares));
    } else if (accPnlPerToken > 0) {
        totalLiability +=
            ((int256(shares) * totalLiability) / int256(supply)) *
            (isDeposit ? int256(1) : int256(-1));
    }
    ...
}
```

When `accPnlPerToken < 0`, the scaling `(accPnlPerToken * supply) / (supply + shares)` truncates toward zero (Solidity rounds toward zero for negative division). Each deposit/withdrawal introduces a small positive bias to `accPnlPerToken`.

Over many deposits/withdrawals, this rounding error accumulates systematically, gradually inflating the perceived value (`shareToAssetsPrice`) of GToken shares. The effect is that the vault becomes very slightly over-reported in its price, and when an epoch updates `accPnlPerTokenUsed`, this accumulated error crystallizes.

When `accPnlPerToken > 0`, the `totalLiability` calculation has a similar issue: `(int256(shares) * totalLiability) / int256(supply)` truncates, and since this is a statistics-only variable, it doesn't directly affect accounting.

**Impact:** Over thousands of deposit/withdrawal cycles, `accPnlPerToken` drifts slightly upward (less negative). Practically, the effect is minuscule per transaction (sub-wei level), and the per-epoch PnL updates dominate the value. Impact is negligible at realistic transaction volumes.

**Recommendation:**
This is a known pattern in share-based accounting. Consider using `mulDiv` with explicit rounding direction for the negative case, or accept the negligible drift.

---

## FINDING-008: Bridge Pending Claims Overwritten When Multiple Bridge Messages Arrive During Pause

**Severity:** INFORMATIONAL

**File:** `/root/defi-audit-targets/audits/gains-network/contracts/bridge/contracts/abstract/ERC20BridgeRateLimiter.sol`
**Lines:** 76-82

**Description:**

```solidity
function addPendingClaim(address to, uint amount) internal {
    PendingClaim storage pendingClaim = pendingClaims[to];
    pendingClaim.amount += amount;
    pendingClaim.claimTimestamp = block.timestamp + epochDuration;
}
```

When the bridge is paused, all incoming messages go to `addPendingClaim`. If multiple messages arrive for the same user, the amounts accumulate correctly (`+=`), but `claimTimestamp` is overwritten each time to `block.timestamp + epochDuration`. This means a user who received a message early during a pause period has their unlock time pushed to `lastMessageTimestamp + epochDuration`, rather than `firstMessageTimestamp + epochDuration`.

This is an inconvenience rather than a funds-at-risk issue, as the amounts are preserved. The claim delay is at most `pauseDuration + epochDuration`.

**Impact:** Minor delay extension for users receiving multiple bridge messages during a pause period.

---

## FINDING-009: GTokenOpenPnlFeed Oracle Answer Ordering Bias In Quicksort Median

**Severity:** INFORMATIONAL

**File:** `/root/defi-audit-targets/audits/gains-network/contracts/pnlfeed/contracts/v6.3/GTokenOpenPnlFeed.sol`
**Lines:** 366-389

**Description:**

The `sort` function implements Lomuto partition quicksort with `array[begin]` as the pivot. This is a well-known worst-case O(n^2) sorting algorithm when the input is already sorted (or nearly sorted). Since oracle responses arrive in order of response time, and oracle nodes likely report similar values, the input array is likely nearly sorted.

With `minAnswers` between 3 and at most `oracles.length / 2`, the array lengths are small (3-5 typically), so this is not a gas DoS risk in practice. However, the Lomuto partition scheme is also not stable, and for even-length arrays, the median computation `(array[length/2-1] + array[length/2]) / 2` may not behave optimally under integer overflow for extreme PnL values.

For very large negative PnL values (e.g., `int256.min/2`), the sum of two negative values could overflow in the median calculation. However, since `minAnswers` is required to be odd (line 111 in constructor), the even-length branch of the median function is never reached via the normal `fulfill` path.

**Impact:** No practical impact. The sort is gas-inefficient for sorted inputs but operates on tiny arrays (3-10 elements). The even-length median overflow is unreachable due to the odd `minAnswers` constraint.

---

## FINDING-010: TradingStorageUtils `currentIndex` Counter Can Only Increment, Never Reclaim Indices

**Severity:** INFORMATIONAL

**File:** `/root/defi-audit-targets/audits/gains-network/contracts/facets/GNSTradingStorage/contracts/libraries/TradingStorageUtils.sol`
**Lines:** 143-165, 371-416

**Description:**

Both trade and pending order counters use a `currentIndex` that only increments:

```solidity
counter.currentIndex++;
counter.openCount++;
```

When trades/orders are closed, only `openCount` is decremented (lines 360, 428). The `currentIndex` never decreases, meaning it acts as a monotonically increasing nonce. After `2^32` trades per user (since index is stored in uint32), the counter would overflow.

At realistic trading frequencies (even 1 trade per block, ~31.5M per year), it would take ~136 years to overflow uint32. This is not a practical concern.

The `traders` array (line 168) also only grows -- once a trader is added, they are never removed. This could cause gas issues for any function that iterates over `traders`, but the current codebase does not appear to iterate over it in any on-chain function.

**Impact:** No practical impact. Theoretical uint32 overflow in ~136 years at extreme trading frequency.

---

## Hypotheses Tested But Not Yielding Findings

1. **Staking double-harvest via vest + regular claim overlap:** Verified that vested (unlock schedule) and regular (non-vested) staking use completely separate accounting (`userTokenRewards` vs `userTokenUnlockRewards`). No double-claim possible.

2. **Staking reward drain via `createUnlockSchedule` without `transferFrom`:** Verified that `createUnlockSchedule` always calls `gns.safeTransferFrom(msg.sender, ...)` to pull tokens from the caller. No free staking.

3. **Bridge mint/burn asymmetry:** The bridge correctly burns on `bridgeTokens` before sending the LZ message, and only mints on the receiving side when a valid LZ message arrives from a trusted remote. The `tryBurn` checks `amount <= epochLimit` but `tryMint` checks `amount <= MAX_EPOCH_LIMIT` -- this is intentional since the receiving side may accumulate from multiple sends within an epoch.

4. **OTC oracle manipulation for price exploitation:** The `getGnsPriceCollateralIndex` returns a Chainlink-derived price from the diamond. The OTC premium is additive (higher price = buyer pays more GNS), not exploitable via price manipulation at the OTC level since the price comes from an external oracle.

5. **GToken first-depositor attack:** The GToken uses OpenZeppelin's ERC4626Upgradeable with `shareToAssetsPrice` starting at `PRECISION_18` (1:1). The vault is initialized with `totalSupply() = 0` but the price being fixed at 1:1 means the first depositor gets shares = assets. Since there's no virtual shares offset, a theoretical inflation attack exists, but the `shareToAssetsPrice` mechanism (which is set independently of actual reserves) means the oracle-driven price prevents the classical ERC4626 inflation attack.

6. **GToken withdrawal epoch manipulation:** The withdrawal timelock system (`makeWithdrawRequest` -> wait epochs -> `redeem`) is properly enforced. The `maxRedeem` function correctly checks `nextEpochValuesRequestCount == 0`, preventing withdrawals during epoch transitions. The `totalSharesBeingWithdrawn` check in `transfer`/`transferFrom` prevents selling shares that are queued for withdrawal.

7. **OTC collateral index validation:** `sellGnsForCollateral` does not explicitly validate `_collateralIndex`, but the `getGnsPriceCollateralIndex` call on the diamond would revert for invalid indices, providing implicit validation.

8. **GNSStaking `revokeUnlockSchedule` reward theft:** Verified that revocation first claims unlocked GNS and harvests all pending rewards for the staker, then sends remaining locked GNS to `owner()`. The staker does not lose earned rewards.

9. **TradingStorage storage collision via crafted inputs:** The storage uses fixed slots with `assembly { s.slot := storageSlot }` and standard Solidity mappings. No collision vectors found.

10. **GToken `deplete` can be called to drain vault:** `deplete` requires `assets <= assetsToDeplete`, which is only increased in `receiveAssets` (when vault receives losing PnL). The function burns GNS from the caller in exchange for collateral, acting as a designed deflationary mechanism.

11. **Bridge `tryBurn` does not increment epoch counter:** Confirmed -- burning (sending) tokens does not count toward the epoch mint limit, which is intentional. Only minting (receiving) is rate-limited.

---

## Architecture Notes

- The staking contract's upgrade path from V1 (single DAI reward) to V2 (multi-token rewards) is well-handled, with legacy `debtDai`/`accDaiPerToken` fields maintained alongside the new system.
- The bridge rate limiter design is sound in principle, with `MAX_EPOCH_LIMIT` as an immutable hard cap, owner-adjustable `epochLimit`, and the pausing mechanism as a circuit breaker.
- The GToken vault's epoch-based withdrawal system with collateralization-dependent timelock is a clever design to prevent bank runs while maintaining user accessibility during healthy periods.
- The OTC module's `onlySelf` restriction on `addOtcCollateralBalance` correctly ensures only the diamond proxy can fund OTC balances, preventing unauthorized collateral injection.
