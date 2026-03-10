# Reserve Protocol Index DTF (Folio) - Security Audit Report

**Date:** 2026-03-02
**Auditor:** Independent Security Review
**Scope:** Folio.sol, FolioDeployer.sol, StakingVault.sol, RebalancingLib.sol, FolioLib.sol, UnstakingManager.sol
**Version:** 5.0.0 / 6.0.0 storage layout

---

## Summary

10 hypotheses were investigated across the Folio rebalancing/auction system, fee distribution, share accounting, StakingVault rewards, and access control. The codebase is well-engineered with comprehensive safeguards. **0 exploitable critical/high findings were identified.** 2 low-severity observations are noted below.

---

## Findings

### Finding 1: Residual Token Approval After Trusted Fill Closure (Low / Informational)

**Location:** `/root/defi-audit-targets/audits/reserve-protocol/reserve-index-dtf/contracts/Folio.sol` line 841, `/root/defi-audit-targets/audits/reserve-protocol/reserve-index-dtf/contracts/utils/RebalancingLib.sol` lines 394-420

**Description:**
When `createTrustedFill()` is called, the Folio grants the trusted filler a token approval via `SafeERC20.forceApprove(sellToken, address(filler), sellAmount)` at Folio.sol line 841. When `_closeTrustedFill()` later calls `RebalancingLib.closeTrustedFill()`, the filler's `closeFiller()` is invoked but the approval is never explicitly revoked.

If the filler contract does not consume the full approval, and if the filler contract has any vulnerability or remaining functionality after closure, it could theoretically pull additional sell tokens from the Folio. The risk is mitigated by:
- Trusted fillers are deployed per-fill with unique salts via the registry
- The registry only allows vetted filler implementations
- Well-implemented fillers should consume the full approval or be inert after closure

**Impact:** Low. Requires a vulnerability in the trusted filler implementation (external dependency).

**Recommendation:** Add `SafeERC20.forceApprove(sellToken, address(activeTrustedFill), 0)` after `activeTrustedFill.closeFiller()` in `RebalancingLib.closeTrustedFill()`.

---

### Finding 2: First Fee Period Undercharges by up to ~24 Hours (Informational)

**Location:** `/root/defi-audit-targets/audits/reserve-protocol/reserve-index-dtf/contracts/Folio.sol` lines 246, 1011-1017

**Description:**
During `initialize()`, `lastPoke` is set to `block.timestamp` (line 246), which is typically NOT a UTC day boundary. The `_getPendingFeeShares()` function computes fee periods in full-day increments: `_accountedUntil = (block.timestamp / ONE_DAY) * ONE_DAY` (line 1012). The first `_poke()` that crosses a day boundary computes `elapsed = _accountedUntil - lastPoke`, which is less than a full day since `lastPoke` was mid-day.

This means the first fee accrual period is shortened by up to ~24 hours. After the first period, `lastPoke` snaps to a day boundary and subsequent periods are exact.

**Impact:** Negligible. At most ~24 hours of 10% annual fee (max) is missed on the first period, amounting to ~0.027% of supply. One-time, non-exploitable.

**Recommendation:** Consider setting `lastPoke = (block.timestamp / ONE_DAY) * ONE_DAY` in `initialize()` to ensure the first fee period starts cleanly at a day boundary.

---

## Hypothesis Analysis

### H1: openAuction() Price Manipulation — FALSE POSITIVE

**Code:** `/root/defi-audit-targets/audits/reserve-protocol/reserve-index-dtf/contracts/Folio.sol` lines 675-707, `/root/defi-audit-targets/audits/reserve-protocol/reserve-index-dtf/contracts/utils/RebalancingLib.sol` lines 122-242

**Safeguards preventing exploitation:**
1. `PriceControl.NONE`: Auction prices MUST exactly match initial prices set by REBALANCE_MANAGER (RebalancingLib.sol lines 196-200). Auction length must equal `maxAuctionLength` (Folio.sol line 684).
2. `PriceControl.PARTIAL`: Prices can only be NARROWED within REBALANCE_MANAGER's initial bounds (lines 204-209). `prices[i].low >= initialPrices.low && prices[i].high <= initialPrices.high`.
3. `PriceControl.ATOMIC_SWAP`: Same narrowing constraint plus `startPrice == endPrice` (lines 156, 212).
4. Basket weight ranges can only be TIGHTENED (lines 181-188): `rebalanceDetails.weights.low <= weights[i].low` and `weights[i].high <= rebalanceDetails.weights.high`.
5. Rebalance limits can only be NARROWED (lines 140-144): `rebalanceLimits.low <= limits.low` and `limits.high <= rebalanceLimits.high`.
6. Initial price ranges validated at rebalance start: `price.high <= MAX_TOKEN_PRICE_RANGE * price.low` (max 100x spread).

The AUCTION_LAUNCHER cannot set advantageous prices beyond what the REBALANCE_MANAGER has already approved.

---

### H2: closeTrustedFill() Sandwich Attack — FALSE POSITIVE

**Code:** `/root/defi-audit-targets/audits/reserve-protocol/reserve-index-dtf/contracts/utils/RebalancingLib.sol` lines 394-420

**Safeguards preventing exploitation:**
1. `closeTrustedFill()` is called internally by `_poke()` via the `sync` modifier. It cannot be directly called by external actors.
2. The trusted fill execution happens externally (e.g., on CowSwap) where the fill provider's own MEV protections apply.
3. No price check occurs in `closeTrustedFill()` because the fill was already validated at creation time via `_getBid()`.
4. The Folio tracks `sold` and `bought` from actual balance changes, not from trusted filler claims.

The MEV risk exists at the external DEX level (e.g., CowSwap batch auction), not at the Folio contract level. This is an external system concern bounded by the filler implementation's protections.

---

### H3: Dutch Auction Price Curve Exploitation — FALSE POSITIVE

**Code:** `/root/defi-audit-targets/audits/reserve-protocol/reserve-index-dtf/contracts/utils/RebalancingLib.sol` lines 427-475

**Safeguards preventing exploitation:**
1. Exponential decay curve: `P(t) = P_0 * e^(-kt)` where `k = ln(P_0/P_t) / T`. The curve starts at the most expensive price for the bidder (sellPrice.high/buyPrice.low) and decays to the least expensive (sellPrice.low/buyPrice.high).
2. Floor enforced: `if (p < endPrice) { p = endPrice; }` (line 472-474).
3. All price calculations use `Math.Rounding.Ceil` (line 450, 456, 471) which rounds in favor of the Folio.
4. 30-second warmup period (`AUCTION_WARMUP`) delays auction start to prevent first-block sniping at the most favorable price.
5. The price spread is bounded by the REBALANCE_MANAGER's initial price ranges (max 100x per token, max 10000x combined pair ratio).

The design intentionally allows bidders to receive better prices over time -- this IS the Dutch auction mechanism. The REBALANCE_MANAGER controls the maximum possible discount through price range settings.

---

### H4: distributeFees() Fee Theft — FALSE POSITIVE

**Code:** `/root/defi-audit-targets/audits/reserve-protocol/reserve-index-dtf/contracts/Folio.sol` lines 521-551, `/root/defi-audit-targets/audits/reserve-protocol/reserve-index-dtf/contracts/utils/FolioLib.sol` lines 67-99

**Safeguards preventing exploitation:**
1. Fee recipients validated: portions must sum to exactly D18 (FolioLib.sol line 51), addresses sorted and unique (line 42).
2. DAO captures all rounding dust: `daoShares = daoPendingFeeShares + _feeRecipientsPendingFeeShares - feeRecipientsTotal` (Folio.sol line 544). Since `feeRecipientsTotal` uses truncating division, it is always <= `_feeRecipientsPendingFeeShares`.
3. Empty fee recipients table: all fees go to DAO (documented behavior, FolioLib.sol line 16).
4. Zero totalSupply: `computeFeeShares` computes `feeShares = 0` when supply is 0. No division by zero.
5. Function is `nonReentrant` and `sync`.

---

### H5: Share Price Manipulation via Donation — FALSE POSITIVE

**Code:** `/root/defi-audit-targets/audits/reserve-protocol/reserve-index-dtf/contracts/Folio.sol` lines 891-928, 1155-1161

**Safeguards preventing exploitation:**
1. Folio is NOT an ERC4626 vault. It's a multi-asset backed token where shares are minted with explicit amounts during `initialize()`.
2. `_update()` (line 1155-1161) blocks share transfers to the Folio contract itself: `require(to != address(this), Folio__InvalidTransferToSelf())`.
3. Underlying token donations inflate the per-share value proportionally for ALL shareholders. The donor loses value to all existing holders equally -- no first-depositor advantage.
4. Initial shares are set by the deployer with actual token transfers (FolioDeployer.sol lines 79-86), preventing the classic 1-wei initial deposit attack.

---

### H6: Mint/Redeem Rounding Exploit — FALSE POSITIVE

**Code:** `/root/defi-audit-targets/audits/reserve-protocol/reserve-index-dtf/contracts/Folio.sol` lines 441-508

**Safeguards preventing exploitation:**
1. `mint()` uses `Math.Rounding.Ceil` (line 460): minters pay MORE tokens.
2. `redeem()` uses `Math.Rounding.Floor` (line 489): redeemers receive FEWER tokens.
3. Rounding consistently favors the Folio, not the user. Each mint/redeem cycle, the protocol GAINS dust.
4. `require(sharesOut != 0, Folio__InsufficientSharesOut())` (FolioLib.sol line 163) prevents zero-share minting.

Concrete example: With totalSupply=1000e18 and USDC balance=500e6, minting 1 share costs 1 wei USDC (ceil) and redeeming 1 share returns 0 USDC (floor). Net: attacker loses 1 wei per cycle.

---

### H7: StakingVault Reward Theft — FALSE POSITIVE

**Code:** `/root/defi-audit-targets/audits/reserve-protocol/reserve-index-dtf/contracts/staking/StakingVault.sol` lines 299-371

**Safeguards preventing exploitation:**
1. Reward accrual uses a global `rewardIndex` incremented proportionally to `tokensToHandout / totalSupply` (line 341).
2. User rewards computed as `balanceOf * deltaIndex / SCALAR / 10^decimals` (line 365), proportional to shares held.
3. `_update()` override (line 394-400) triggers `accrueRewards(from, to)` on every transfer, ensuring both sender and receiver are properly accrued before balance changes.
4. The `_calculateHandout` function (lines 376-389) uses exponential decay with `rewardRatio` to smooth reward distribution over time, preventing flash-stake attacks.
5. Early return for `totalSupply() == 0` prevents division by zero (line 381).
6. The `- 1` in `handoutPercentage` (line 385) cannot underflow because for `elapsed >= 1`, `(1e18 - rewardRatio)^elapsed < 1e18`.

---

### H8: StakingVault Double-Earning During Unstaking — FALSE POSITIVE

**Code:** `/root/defi-audit-targets/audits/reserve-protocol/reserve-index-dtf/contracts/staking/StakingVault.sol` lines 177-202, `/root/defi-audit-targets/audits/reserve-protocol/reserve-index-dtf/contracts/staking/UnstakingManager.sol`

**Safeguards preventing exploitation:**
1. On withdrawal, shares are BURNED immediately (`_burn(_owner, _shares)` at line 195).
2. `totalDeposited -= _assets` (line 184) reduces the deposited tracking.
3. UnstakingManager holds tokens in a simple escrow with no yield mechanism.
4. User's `balanceOf` becomes 0 (or reduced), so reward accrual via `_accrueUser` (line 365: `balanceOf(_user) * deltaIndex`) correctly produces 0 additional rewards.
5. `cancelLock()` re-deposits through `vault.deposit()` which properly triggers `accrueRewards` and mints new shares.

---

### H9: Rebalancing Token Double-Counting — FALSE POSITIVE

**Code:** `/root/defi-audit-targets/audits/reserve-protocol/reserve-index-dtf/contracts/Folio.sol` lines 919-928, 983-1002

**Safeguards preventing exploitation:**
1. `_balanceOfToken()` includes tokens held by the active trusted filler (line 926), providing accurate total NAV.
2. Only ONE trusted fill can be active at a time (single `activeTrustedFill` storage slot).
3. Every external entry point with the `sync` modifier closes any active trusted fill BEFORE executing the function body.
4. Regular `bid()` operates on the Folio's actual balance (tokens transferred in/out directly), with `_getBid()` checking real-time availability.
5. `getBid()` uses `_balanceOfToken()` which correctly includes trusted filler balances for surplus/deficit calculations.

---

### H10: Governor/Admin Privilege Escalation — FALSE POSITIVE

**Code:** `/root/defi-audit-targets/audits/reserve-protocol/reserve-index-dtf/contracts/Folio.sol` lines 879-886, `/root/defi-audit-targets/audits/reserve-protocol/reserve-index-dtf/contracts/deployer/FolioDeployer.sol`

**Safeguards preventing exploitation:**
1. Strict role separation: `DEFAULT_ADMIN_ROLE` for governance, `REBALANCE_MANAGER` for rebalancing, `AUCTION_LAUNCHER` for auction operations.
2. AUCTION_LAUNCHER cannot: set fees, change basket, modify rebalance control, deprecate, grant/revoke roles, start rebalances.
3. REBALANCE_MANAGER cannot: set fees, directly change basket, grant/revoke roles.
4. Only `DEFAULT_ADMIN_ROLE` can grant/revoke roles (inherited from AccessControlEnumerable).
5. AUCTION_LAUNCHER's `restrictedUntil` extension (line 701-706) is bounded by `rebalance.availableUntil` set by REBALANCE_MANAGER.
6. Weight/price/limit narrowing is one-directional -- the AUCTION_LAUNCHER can only tighten, never loosen.
7. The deployer properly renounces admin after setup (FolioDeployer.sol line 111).

---

## Architecture Quality Assessment

**Strengths:**
- Multi-layered access control with clear role separation
- One-directional narrowing of weights/prices/limits prevents AUCTION_LAUNCHER manipulation
- Exponential decay Dutch auction with correct rounding (Ceil for prices)
- Comprehensive `sync` modifier ensures consistent state on every entry point
- `nonReentrant` on all state-changing external functions
- Prevention of self-transfers (`_update` override)
- Fee computation in full-day increments prevents micro-timing attacks
- Trusted filler balance inclusion in NAV calculations

**Design Observations:**
- The `createTrustedFill()` function has no role restriction (callable by anyone), which is intentional -- the fill is bounded by the current auction parameters
- The `closeAuction()` and `endRebalance()` functions intentionally do not revert on no-op cases to prevent griefing
- The `bidsEnabled` flag provides an additional control layer for permissionless bidding
- The trade allowlist feature adds token-level control over rebalancing
