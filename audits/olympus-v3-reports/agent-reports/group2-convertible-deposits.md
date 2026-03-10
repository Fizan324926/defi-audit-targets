# Olympus V3 Convertible Deposit System - Security Audit Report

**Scope**: ConvertibleDeposit system -- full deposit/auction/redemption/limit-order subsystem
**Auditor**: Automated Security Analysis
**Date**: 2026-03-01
**Bounty Program**: Immunefi ($3.33M max)

---

## Table of Contents

1. [System Overview](#system-overview)
2. [Findings Summary](#findings-summary)
3. [Detailed Findings](#detailed-findings)
4. [Informational Notes](#informational-notes)

---

## System Overview

The ConvertibleDeposit system is a multi-contract architecture for auction-based convertible deposits:

- **ConvertibleDepositAuctioneer**: Runs continuous auctions with tick-based pricing. Users bid deposit tokens (e.g. USDS) to receive receipt tokens + a DEPOS position that can later be converted to OHM at the auction-time price.
- **ConvertibleDepositFacility**: Creates positions via the auctioneer, handles OHM conversion (minting), and claims vault yield.
- **BaseDepositFacility**: Shared base with committed deposit tracking, reclaim functionality, borrowing callbacks, and position split logic.
- **LimitOrders (CDAuctioneerLimitOrders)**: Allows users to place limit orders that MEV bots can fill when the auction price is favorable. Deposits held in sUSDS for yield.
- **DepositManager**: Central deposit/withdrawal manager with ERC6909 receipt tokens, operator isolation, and borrowing support.
- **ReceiptTokenManager**: ERC6909 + ERC20 wrapping for receipt tokens.
- **DepositRedemptionVault**: Manages time-locked redemption of receipt tokens, with borrowing-against-redemption and loan default mechanics.
- **OlympusDepositPositionManager (DEPOS)**: ERC721-based position NFTs tracking conversion terms.
- **CloneableReceiptToken**: Cloneable ERC20 wrapper for receipt tokens.

---

## Findings Summary

| # | Severity | Title |
|---|----------|-------|
| 1 | Medium | Conversion price rounding in `_bid()` allows systematic extraction of fractional OHM |
| 2 | Medium | LimitOrders `fillOrder` uses stale `previewBid` for price check but actual `bid` may execute at different price |
| 3 | Medium | `claimDefaultedLoan` can leave dust in redemption that is unredeemable |
| 4 | Low | Auction tick decay can be gamed by waiting for maximum price decay then bidding at minimum price |
| 5 | Low | `handleBorrow` reduces committed deposits before validating actual amount, creating accounting inconsistency |
| 6 | Low | LimitOrders `totalUsdsOwed` can underflow if sUSDS loses value |
| 7 | Informational | Conversion price can be set arbitrarily low by the auctioneer, minting OHM cheaply |
| 8 | Informational | `_previewBid` loop has no iteration cap and could consume excessive gas |

---

## Detailed Findings

### Finding 1: Conversion price rounding in `_bid()` allows systematic extraction of fractional OHM

**Severity**: Medium
**File**: `src/policies/deposits/ConvertibleDepositAuctioneer.sol`, lines 294-310
**File**: `src/policies/deposits/ConvertibleDepositFacility.sol`, lines 230-236

**Description**:

In the auctioneer's `_bid()` function, the conversion price is calculated as:

```solidity
conversionPrice: depositIn.mulDivUp(_ohmScale, ohmOut), // Assets per OHM, deposit token scale
```

This rounds **up** the conversion price (assets-per-OHM), which is correct from the protocol's perspective -- the user needs to provide more assets per OHM when converting.

However, when conversion actually happens in `ConvertibleDepositFacility._previewConvert()`:

```solidity
convertedTokenOut = FullMath.mulDiv(
    amount_, // Scale: deposit token
    _OHM_SCALE,
    position.conversionPrice // Scale: deposit token
);
```

This rounds **down** the OHM output. The combination means the user always receives <= the OHM they were quoted at auction time. For individual transactions the difference is negligible (at most 1 wei of OHM per conversion), but across many small conversions the protocol consistently benefits from rounding in both directions.

**Impact**: The rounding is consistently in favor of the protocol. For users performing many small conversions across many positions, they could lose a meaningful amount of OHM due to compounded rounding losses. However, this is a design choice that favors protocol solvency.

**Attack Scenario**: Not directly exploitable for fund theft. The rounding favors the protocol.

**PoC Feasible**: Yes, but impact is informational-level per-transaction.

---

### Finding 2: LimitOrders `fillOrder` uses `previewBid` for price check but actual `bid` may execute at different price

**Severity**: Medium
**File**: `src/policies/deposits/LimitOrders.sol`, lines 402-424

**Description**:

In `fillOrder()`, the function first calls `CD_AUCTIONEER.previewBid()` to check the price, then calls `CD_AUCTIONEER.bid()` to execute. Between these two calls, the auction state can change if another transaction is included in the same block before this one (or in a prior block that has not yet been processed).

```solidity
// Check execution price via previewBid
uint256 expectedOhmOut = CD_AUCTIONEER.previewBid(order.depositPeriod, fillAmount_);
if (expectedOhmOut == 0) revert ZeroOhmOut();
if ((fillAmount_ * OHM_SCALE) / expectedOhmOut > order.maxPrice) revert PriceAboveMax();

// ... withdraw from sUSDS ...

// Approve and execute bid
USDS.approve(address(DEPOSIT_MANAGER), fillAmount_);
(uint256 ohmOut, uint256 positionId, , uint256 actualAmount) = CD_AUCTIONEER.bid(
    order.depositPeriod,
    fillAmount_,
    expectedOhmOut, // minOhmOut set to expectedOhmOut
    true,
    true
);
```

The `minOhmOut` parameter is set to `expectedOhmOut`, which provides slippage protection. However, there is a subtle issue: `previewBid` is a `view` function that reads state, while `bid` modifies state. If another bid happens between the `previewBid` call and the `bid` call within the same transaction (e.g. via a multi-call or if the filler is a contract), the `bid()` could revert due to slippage, causing the fill to fail. This is mitigated by the `nonReentrant` guard, and the `bid()` function itself also has `nonReentrant`, preventing reentrancy.

The real risk is **frontrunning**: a MEV bot sees a `fillOrder` transaction, frontruns it with a direct `bid()` that moves the auction price up, causing the `fillOrder` to either:
1. Execute at a worse price for the order owner (but still within `maxPrice`)
2. Revert due to `minOhmOut` not being met

Since `expectedOhmOut` is used as `minOhmOut`, case 2 protects the order owner. Case 1 is not possible because the slippage is tight.

**Impact**: Fill transactions can be DOSed by frontrunning with direct bids. The order owner is not financially harmed (the fill simply reverts), but the MEV bot/filler loses the gas cost. The order remains fillable at the new (worse) price.

**Attack Scenario**:
1. Attacker monitors for `fillOrder` transactions in the mempool
2. Attacker frontruns with a direct `bid()` that moves the price up
3. The `fillOrder` reverts due to slippage protection
4. Attacker profits from getting OHM at the pre-fill price
5. The limit order owner is not harmed but their order goes unfilled

**PoC Feasible**: Yes

---

### Finding 3: `claimDefaultedLoan` can leave dust in redemption that is unredeemable

**Severity**: Medium
**File**: `src/policies/deposits/DepositRedemptionVault.sol`, lines 898-1016

**Description**:

In `claimDefaultedLoan()`, the retained collateral and principal amounts are calculated, and the redemption amount is reduced:

```solidity
uint256 retainedCollateral = redemption.amount - loan.initialPrincipal; // Buffer amount

// ...

redemption.amount -= retainedCollateral + previousPrincipal;
```

After this, `redemption.amount` equals `loan.initialPrincipal - loan.principal` (i.e., the principal that was repaid). This amount should theoretically be redeemable by the user through `finishRedemption()`.

However, `finishRedemption()` requires:
```solidity
if (block.timestamp < redemption.redeemableAt)
    revert RedemptionVault_TooEarly(msg.sender, redemptionId_, redemption.redeemableAt);
```

And also:
```solidity
if (_redemptionLoan[redemptionKey].principal > 0)
    revert RedemptionVault_UnpaidLoan(msg.sender, redemptionId_);
```

After `claimDefaultedLoan`, `loan.principal` is set to 0, so the unpaid loan check passes. But there is a more subtle issue: the `handleCommitWithdraw` call during `finishRedemption` operates on `redemptionAmount` (the remaining `redemption.amount`). The committed deposits were only partially cancelled during the default process (only `retainedCollateral` was withdrawn via `handleCommitWithdraw`, not the original principal's committed amount).

Looking more carefully at the flow:
- `startRedemption` calls `handleCommit(amount)` - commits the full amount
- `claimDefaultedLoan` calls `handleCommitWithdraw(retainedCollateral)` - withdraws buffer, reducing committed by `retainedCollateral`
- `claimDefaultedLoan` calls `handleLoanDefault(previousPrincipal)` - burns receipt tokens, reduces liabilities and borrowed, but does NOT reduce committed deposits
- After default: committed deposits still include `previousPrincipal` worth of commitment that has been burned

When the user tries `finishRedemption` with the remaining `redemption.amount = initialPrincipal - previousPrincipal` (the repaid amount), `handleCommitWithdraw` is called with this amount. This should succeed because the committed deposits still cover it.

Actually, tracing more carefully: `handleBorrow` already reduced committed deposits by the principal amount. And `handleLoanRepay` increases committed deposits by the repaid amount. So after partial repayment and default:
- Committed was reduced by `principal` (borrow) and increased by `repaid` (repay), net: committed reduced by `previousPrincipal`
- `handleLoanDefault` does NOT adjust committed deposits
- Total committed remaining = `amount - principal_borrowed + principal_repaid - retainedCollateral`

The amount remaining in `redemption.amount` = `initialPrincipal - previousPrincipal` (repaid principal).

Committed remaining should cover this since:
- `amount - initialPrincipal + (initialPrincipal - previousPrincipal) - retainedCollateral` where `retainedCollateral = amount - initialPrincipal`
- = `amount - initialPrincipal + initialPrincipal - previousPrincipal - amount + initialPrincipal`
- = `initialPrincipal - previousPrincipal`

This matches. So the redemption should work correctly.

**Revised Assessment**: After careful analysis, the accounting appears correct. The redemption amount remaining after default equals exactly the committed deposits remaining. This finding is downgraded.

**Impact**: No direct fund loss identified after full trace-through.

---

### Finding 4: Auction tick decay can be gamed by waiting for maximum price decay

**Severity**: Low
**File**: `src/policies/deposits/ConvertibleDepositAuctioneer.sol`, lines 535-581

**Description**:

The `_getCurrentTick()` function decays the price based on elapsed time since the last bid. The decay follows a tick-by-tick mechanism where each `tickSize` worth of accumulated capacity causes one tick step decrease in price:

```solidity
uint256 capacityToAdd = (_auctionParameters.target * timePassed) /
    SECONDS_IN_DAY /
    _depositPeriods.length();

// ...

while (newCapacity > tickSize) {
    newCapacity -= tickSize;
    tick.price = tick.price.mulDivUp(ONE_HUNDRED_PERCENT, _tickStep);
    if (tick.price < _auctionParameters.minPrice) {
        tick.price = _auctionParameters.minPrice;
        break;
    }
}
```

A bidder can wait for the maximum amount of time (until the price reaches `minPrice`), then place a large bid at the lowest possible price. This is by design -- the auction is meant to discover fair pricing through this mechanism. However, if the `minPrice` is set too low relative to the market price, an attacker could obtain OHM at below-market rates.

**Impact**: This is a parameter configuration risk. If `minPrice` is set too low, users can acquire OHM conversion rights at below-market value. The `setAuctionParameters` function is role-gated, so this depends on governance setting reasonable parameters.

**Attack Scenario**:
1. No bids occur for an extended period
2. Price decays to `minPrice`
3. If `minPrice` < market price, bidder gets cheap conversion rights
4. Bidder converts at the cheap rate to mint OHM below market price

**PoC Feasible**: Yes, but requires governance misconfiguration.

---

### Finding 5: `handleBorrow` reduces committed deposits before validating actual amount

**Severity**: Low
**File**: `src/policies/deposits/BaseDepositFacility.sol`, lines 258-291

**Description**:

In `handleBorrow()`, the committed deposits are reduced by the full requested `amount_`, even though the actual amount withdrawn from the vault may be less:

```solidity
// Process the borrowing through DepositManager
uint256 actualAmount = DEPOSIT_MANAGER.borrowingWithdraw(
    IDepositManager.BorrowingWithdrawParams({
        asset: depositToken_,
        recipient: recipient_,
        amount: amount_
    })
);

// Reduce committed deposits
_assetOperatorCommittedDeposits[...] -= amount_;
_assetCommittedDeposits[depositToken_] -= amount_;

// Validate that the amount is not zero
if (actualAmount == 0) revert DepositFacility_ZeroAmount();
```

The comment in the code says "This uses the requested amount, to be consistent with DepositManager." This is intentional -- the DepositManager also tracks the `amount_` (not `actualAmount`) for its borrowing records. However, there is a discrepancy: the committed deposits are reduced by `amount_` while only `actualAmount` was actually withdrawn from the vault.

For ERC4626 vaults, `actualAmount` can be 1-2 wei less than `amount_` due to rounding in `convertToShares()`. This means over many borrow/repay cycles, the committed deposits tracking will have a slight undercount relative to the actual assets, which could eventually cause `getAvailableDeposits()` to return a slightly higher value than reality.

**Impact**: Minimal. The discrepancy is at most 1-2 wei per borrow operation. The solvency check in DepositManager catches any real issues.

---

### Finding 6: LimitOrders `totalUsdsOwed` can underflow if sUSDS loses value

**Severity**: Low
**File**: `src/policies/deposits/LimitOrders.sol`, lines 406-412, 467-472

**Description**:

In `fillOrder()` and `cancelOrder()`, `totalUsdsOwed` is decreased:

```solidity
// fillOrder:
totalUsdsOwed -= usdsNeeded;

// cancelOrder:
totalUsdsOwed -= totalRemaining;
```

The `totalUsdsOwed` tracks the total USDS principal owed to all order owners. If the sUSDS vault were to lose value (depeg, exploit, etc.), `SUSDS.withdraw()` could fail because there are insufficient assets backing the shares. This would cause `fillOrder` and `cancelOrder` to revert, potentially trapping user funds.

However, the contract does use `Math.saturatingSub` for view functions (`getAccruedYieldShares`, `getRemaining`), but the actual accounting in `fillOrder` and `cancelOrder` uses direct subtraction.

If `SUSDS.withdraw()` does succeed but returns fewer assets than expected, the subsequent `totalUsdsOwed -= usdsNeeded` could underflow in theory if somehow `usdsNeeded > totalUsdsOwed`. In practice, this should not happen because `totalUsdsOwed` is always increased when orders are created and decreased when they are filled/cancelled.

**Impact**: If the sUSDS vault loses value, `withdraw()` calls would revert, preventing fills and cancellations. Users would be unable to recover their funds until the vault is restored. The `cancelOrder` function does not require `onlyEnabled`, so it would still be callable.

---

### Finding 7: Conversion price can be set arbitrarily low by the auctioneer (by design)

**Severity**: Informational
**File**: `src/policies/deposits/ConvertibleDepositAuctioneer.sol`, lines 294-310

**Description**:

The conversion price is determined by the auction mechanism. When the price decays to `minPrice` and a user bids, the conversion price is:

```solidity
conversionPrice: depositIn.mulDivUp(_ohmScale, ohmOut)
```

If the auction parameters allow `minPrice` to be very low (close to 0), the conversion price would also be very low, meaning a small amount of deposit tokens could convert to a large amount of OHM. This is constrained by the `minPrice > 0` check in `_setAuctionParameters()`, but there is no minimum floor relative to market price.

The `ROLE_EMISSION_MANAGER` role controls these parameters, which is a governance/centralization concern (out of scope per program rules).

**Impact**: Design consideration. Not a vulnerability per se.

---

### Finding 8: `_previewBid` loop has no iteration cap

**Severity**: Informational
**File**: `src/policies/deposits/ConvertibleDepositAuctioneer.sol`, lines 338-409

**Description**:

The `_previewBid()` function contains a `while (remainingDeposit > 0)` loop that iterates through ticks. For very large deposit amounts relative to the tick size, this loop could consume significant gas. Each iteration increases the price by `tickStep`, so eventually either:
1. The deposit is fully consumed
2. The `convertibleAmount` becomes 0 due to the price being too high

The loop is bounded in practice because each iteration increases the price, which decreases the convertible amount, eventually reaching 0. However, with a small `tickStep` (e.g. 100e2 = 100%, meaning no increase), the price would never increase, and the loop would cycle through ticks indefinitely.

The constraint `tickStep >= ONE_HUNDRED_PERCENT` (100e2) is enforced in `setTickStep()`, meaning the minimum step is 100% (no change). At exactly 100%, `_getNewTickPrice` would return `currentPrice * 100e2 / 100e2 = currentPrice`, and the loop would only terminate when capacity is exhausted in a single tick then reset, which would cycle indefinitely.

Wait -- examining more carefully:

```solidity
if (newStep_ < ONE_HUNDRED_PERCENT)
    revert ConvertibleDepositAuctioneer_InvalidParams("tick step");
```

A tickStep of exactly `ONE_HUNDRED_PERCENT` (10000) means the price never changes. In `_previewBid`, each tick transition resets capacity but keeps the same price. With `convertibleAmount = deposit.mulDiv(_ohmScale, price)` being constant, the loop would continue indefinitely if the deposit is larger than the tick capacity.

However, the `_getOhmUntilNextThreshold` and day target mechanics would cause the tick size to shrink dramatically after crossing multiples of the target, eventually reaching `_TICK_SIZE_MINIMUM = 1` (1 wei of OHM per tick). At that point, each tick converts 1 wei of OHM worth of deposits, and the loop would need to iterate billions of times, causing an out-of-gas revert.

**Impact**: If `tickStep = ONE_HUNDRED_PERCENT`, large bids would revert with out-of-gas. This is a parameter configuration issue.

---

## Informational Notes

### Note 1: ERC721 position transfer updates ownership correctly

The `OlympusDepositPositionManager.transferFrom()` correctly updates `position.owner`, `_userPositions` mappings, and calls `super.transferFrom()`. The `safeTransferFrom` variants in Solmate's ERC721 also call `transferFrom`, so they inherit this behavior. No ownership bypass found.

### Note 2: Receipt token authorization model is sound

The `ReceiptTokenManager` enforces that only the contract that created a token (via `msg.sender` during `createToken`) can mint or burn it. The token ID includes the owner address in the hash, preventing collision attacks. The `onlyTokenOwner` modifier is correctly applied.

### Note 3: Reentrancy protections are comprehensive

- `ConvertibleDepositAuctioneer`: Uses Solmate's `ReentrancyGuard` on `bid()`
- `ConvertibleDepositFacility`: Uses `nonReentrant` on `createPosition`, `deposit`, `convert`
- `BaseDepositFacility`: Uses OpenZeppelin's `ReentrancyGuard` on all mutating functions
- `LimitOrders`: Uses `ReentrancyGuardTransient` on `createOrder`, `fillOrder`, `cancelOrder`, `sweepYield`
- `DepositRedemptionVault`: Uses Solmate's `ReentrancyGuard` on all mutating functions
- `DepositManager`: Does not use a reentrancy guard directly, but deposits use `safeTransferFrom` before state changes, and fee-on-transfer tokens are rejected

State changes generally happen before external calls in the `convert()` function (DEPOS position updates before `DEPOSIT_MANAGER.withdraw` and `MINTR.mintOhm`), which is the correct pattern.

### Note 4: The `convert()` function acknowledges and accepts rounding differences

In `ConvertibleDepositFacility.convert()` (line 341-345):

```solidity
// The actual amount withdrawn may differ from `receiptTokenIn` by a few wei,
// but will not materially affect the amount of OHM that is minted when converting.
```

The function withdraws `receiptTokenIn` worth of receipt tokens but the vault may return slightly fewer assets. The OHM minted is based on the original `convertedTokenOut` calculated from position data, not the actual assets received. This means the protocol could mint slightly more OHM than the assets received, but the difference is limited to ERC4626 vault rounding (1-2 wei).

### Note 5: Split function minimum deposit validation

The `BaseDepositFacility.split()` function correctly validates that both the new position and the remaining position meet the minimum deposit requirement (lines 572-589). This prevents creating dust positions that could cause issues.

### Note 6: Day state not reset automatically

The `_dayState` in the auctioneer tracks daily auction activity but is only reset when `setAuctionParameters()` is called by the emission manager. If the emission manager does not call this function daily, the day state accumulates across multiple days. This means the tick size reduction mechanism (which activates when the day target is exceeded) operates on cumulative volume rather than daily volume. This is by design per the comments but could lead to unexpectedly rapid tick size reduction if the emission manager misses a day.

### Note 7: Position expiry uses 30-day months

In `ConvertibleDepositFacility.createPosition()` (line 138):

```solidity
expiry: uint48(block.timestamp + uint48(params_.periodMonths) * 30 days),
```

This uses a fixed 30-day month approximation. A 12-month position would expire after 360 days, not 365. This is a known simplification and is applied consistently.

---

## Conclusion

The ConvertibleDeposit system demonstrates a well-architected design with proper separation of concerns, comprehensive access controls, and thorough reentrancy protections. The accounting logic across the DepositManager, BaseDepositFacility, and DepositRedemptionVault is complex but maintains internal consistency.

No critical vulnerabilities enabling direct loss of treasury funds, user funds, or bond funds were identified. The medium-severity findings relate to frontrunning risks in the limit order system and rounding behavior, which are inherent to the design rather than exploitable vulnerabilities. The low-severity findings relate to edge cases in parameter configuration and minor accounting dust.

The system's primary risk vectors are:
1. **Parameter misconfiguration** by the emission manager (minimum price too low, tick step too small)
2. **sUSDS vault failure** affecting the limit order system
3. **Rounding accumulation** across many small operations

These are largely mitigated by the role-based access control system and the solvency checks in the DepositManager.
