# Second-Pass Audit: Treasury Drainage Attack Vectors

**Target**: Olympus V3 Treasury (TRSRY) and Cross-Policy Withdrawal Paths
**Scope**: Cross-contract economic attacks exploiting the approval-based withdrawal system
**Bounty**: $3.33M Immunefi

---

## Executive Summary

This second-pass audit examined all withdrawal paths from the Olympus Treasury (TRSRY) and the interactions between policies that can chain approvals, debt manipulation, and ERC4626 vault conversions. The analysis covers seven specific attack patterns (A through G). Two findings have potential economic impact: a debt-inflation capacity amplification in the Operator (Pattern A, Medium-High severity) and a structural rounding leakage across multiple ERC4626 conversion sites (Pattern G, Low severity). The remaining patterns were found to have adequate protections or require privileged access that mitigates exploitability.

---

## Table of Contents

1. [TRSRY Withdrawal Architecture Overview](#1-trsry-withdrawal-architecture-overview)
2. [Pattern A: Debt Manipulation to Withdrawal Amplification](#2-pattern-a-debt-manipulation--withdrawal-amplification)
3. [Pattern B: sUSDS/sDAI Share Price Manipulation](#3-pattern-b-susdsdai-share-price-manipulation)
4. [Pattern C: Cross-Policy Approval Accumulation](#4-pattern-c-cross-policy-approval-accumulation)
5. [Pattern D: DepositManager Committed vs Actual Deposits](#5-pattern-d-depositmanager-committed-vs-actual-deposits)
6. [Pattern E: TRSRY Debt vs Actual Debt Divergence](#6-pattern-e-trsry-debt-vs-actual-debt-divergence)
7. [Pattern F: Redemption Vault Loan/Default Interaction](#7-pattern-f-redemption-vault-loandefault-interaction)
8. [Pattern G: ERC4626 Vault Rounding Across Multiple Contracts](#8-pattern-g-erc4626-vault-rounding-across-multiple-contracts)
9. [Complete Withdrawal Path Inventory](#9-complete-withdrawal-path-inventory)
10. [Findings Summary](#10-findings-summary)

---

## 1. TRSRY Withdrawal Architecture Overview

### Core Mechanism

The Treasury (`OlympusTreasury.sol`) uses a per-policy, per-token approval system:

```solidity
// State
mapping(address => mapping(ERC20 => uint256)) public withdrawApproval;

// Withdrawal (line 70-80)
function withdrawReserves(address to_, ERC20 token_, uint256 amount_)
    public override permissioned onlyWhileActive
{
    withdrawApproval[msg.sender][token_] -= amount_;  // Underflow reverts
    token_.safeTransfer(to_, amount_);
}
```

Key properties:
- Each policy has independent withdrawal approval per token
- `withdrawReserves` decrements the caller's approval (underflow-protected by Solidity 0.8.x)
- Only policies registered via the Kernel with `TRSRY.withdrawReserves.selector` permission can call this
- The `permissioned` modifier validates via `kernel.modulePermissions(KEYCODE(), Policy(msg.sender), msg.sig)`

### Debt System

```solidity
// getReserveBalance (line 177-179)
function getReserveBalance(ERC20 token_) external view returns (uint256) {
    return token_.balanceOf(address(this)) + totalDebt[token_];
}

// setDebt (line 147-160) - arbitrary debt setting by permissioned policies
function setDebt(address debtor_, ERC20 token_, uint256 amount_) external permissioned {
    uint256 oldDebt = reserveDebt[token_][debtor_];
    reserveDebt[token_][debtor_] = amount_;
    if (oldDebt < amount_) totalDebt[token_] += amount_ - oldDebt;
    else totalDebt[token_] -= oldDebt - amount_;
}
```

### Policies with Withdrawal Access

| Policy | `withdrawReserves` | `increaseWithdrawApproval` | `setDebt` | Notes |
|--------|:--:|:--:|:--:|-------|
| TreasuryCustodian | Yes | Yes | Yes | Custodian role-gated |
| Operator | Yes | Yes | No | Heart + role-gated |
| YieldRepurchaseFacility | Yes | Yes | No | Heart-gated |
| CoolerTreasuryBorrower | Yes | Yes | Yes (`setDebt`) | Cooler role-gated |
| BondCallback | Yes | Yes | No | Market-whitelisted |
| EmissionManager | No | No | No | Only MINTR permissions |
| DepositManager | No | No | No | Only ROLES dependency |
| DepositRedemptionVault | No | No | No | Only TRSRY/ROLES/DEPOS |
| BaseDepositFacility | No | No | No | Operates through DepositManager |

---

## 2. Pattern A: Debt Manipulation -> Withdrawal Amplification

### Attack Hypothesis

`TRSRY.getReserveBalance()` returns `token_.balanceOf(address(this)) + totalDebt[token_]`. If a policy can inflate `totalDebt` via `setDebt()` without corresponding actual token outflows, then another policy that reads `getReserveBalance` to compute withdrawal amounts could over-withdraw.

### Analysis

**Who calls `getReserveBalance`?**

The critical consumer is `Operator.fullCapacity()` (line 902-916):

```solidity
function fullCapacity(bool high_) public view override returns (uint256) {
    uint256 capacity = ((sReserve.previewRedeem(TRSRY.getReserveBalance(sReserve)) +
        TRSRY.getReserveBalance(reserve) +
        TRSRY.getReserveBalance(oldReserve)) * _config.reserveFactor) / ONE_HUNDRED_PERCENT;
    // ... price conversions for high side ...
    return capacity;
}
```

This is used in `_regenerate()` (line 630-691) to:
1. Calculate the wall capacity
2. Set the TRSRY withdrawal approval to match that capacity

**Who can inflate `totalDebt`?**

Two policies have `setDebt` permission:

1. **TreasuryCustodian** - via `increaseDebt()` (line 115-122):
   ```solidity
   function increaseDebt(ERC20 token_, address debtor_, uint256 amount_)
       external onlyRole("custodian")
   {
       uint256 debt = TRSRY.reserveDebt(token_, debtor_);
       TRSRY.setDebt(debtor_, token_, debt + amount_);
   }
   ```
   This is gated by the `"custodian"` role -- a privileged multisig/governance address.

2. **CoolerTreasuryBorrower** - via `borrow()` (line 80-100):
   ```solidity
   function borrow(uint256 amountInWad, address recipient) external onlyEnabled onlyRole(COOLER_ROLE) {
       uint256 outstandingDebt = TRSRY.reserveDebt(_USDS, address(this));
       TRSRY.setDebt({debtor_: address(this), token_: _USDS, amount_: outstandingDebt + amountInWad});
       // ... withdraws sUSDS from TRSRY ...
   }
   ```
   This also withdraws actual tokens, so the debt increase is matched by a withdrawal.

   However, `CoolerTreasuryBorrower.setDebt()` (line 119-121) allows the admin to set debt arbitrarily:
   ```solidity
   function setDebt(uint256 debtTokenAmount) external override onlyEnabled onlyAdminRole {
       TRSRY.setDebt({debtor_: address(this), token_: _USDS, amount_: debtTokenAmount});
   }
   ```
   This is admin-role gated. An admin could inflate debt without withdrawing tokens.

**The attack chain (requires privileged access):**

1. Admin calls `CoolerTreasuryBorrower.setDebt(X)` where X is very large, inflating `totalDebt[USDS]`
2. `TRSRY.getReserveBalance(reserve)` now returns `actualBalance + X`
3. When Operator regenerates low wall: `fullCapacity(false)` returns an inflated value
4. Operator sets `TRSRY.increaseWithdrawApproval(address(this), sReserve, inflatedAmount)`
5. Users performing low-wall swaps via `Operator.swap(ohm, ...)` can now withdraw more sReserve than the treasury actually holds in reserve tokens

**Severity Assessment:**

The attack requires the `onlyAdminRole` or `"custodian"` role, which represents governance. This is a **governance trust assumption** -- if governance is compromised, many attack vectors open up. However, the interesting aspect is that a single admin action on one policy (`CoolerTreasuryBorrower.setDebt`) can amplify withdrawals from a completely separate policy (`Operator`) without any explicit link between the two.

**Finding**: **MEDIUM** -- Debt inflation via `CoolerTreasuryBorrower.setDebt()` (admin-gated) or `TreasuryCustodian.increaseDebt()` (custodian-gated) inflates `getReserveBalance()`, which amplifies `Operator.fullCapacity()`, causing the Operator to approve itself for more sReserve withdrawal than actually exists. The withdrawal approval is set in `_regenerate()` and would only be consumed during actual wall swaps, but the approval itself could exceed treasury holdings.

**Important caveat**: The actual `withdrawReserves` call on line 363 of Operator.sol will revert if the treasury doesn't have enough sReserve tokens. The protection is the token balance check in `safeTransfer`. So the over-approval alone doesn't drain funds -- the drain requires the inflated debt to somehow correspond to sReserve tokens being held. This significantly reduces the severity.

---

## 3. Pattern B: sUSDS/sDAI Share Price Manipulation

### Attack Hypothesis

Multiple contracts use `sReserve.previewWithdraw()` and `sReserve.previewRedeem()` to convert between share and asset amounts. If the sUSDS/sDAI exchange rate can be manipulated (e.g., via a donation attack), conversions could over/under-estimate amounts.

### Analysis

**Conversion sites:**

1. **Operator.swap()** (line 363):
   ```solidity
   TRSRY.withdrawReserves(address(this), sReserve, sReserve.previewWithdraw(amountOut));
   sReserve.withdraw(amountOut, msg.sender, address(this));
   ```
   Uses `previewWithdraw` to calculate sReserve shares needed for `amountOut` of reserve.

2. **Operator._regenerate()** (line 669-685):
   ```solidity
   uint256 currentApproval = sReserve.previewRedeem(
       TRSRY.withdrawApproval(address(this), sReserve)
   );
   ```
   Reads current approval in reserve terms, then adjusts.

3. **Operator.fullCapacity()** (line 904):
   ```solidity
   sReserve.previewRedeem(TRSRY.getReserveBalance(sReserve))
   ```

4. **CoolerTreasuryBorrower.borrow()** (line 96):
   ```solidity
   uint256 susdsAmount = SUSDS.previewWithdraw(amountInWad);
   ```

5. **BondCallback.callback()** (line 218-222):
   ```solidity
   TRSRY.withdrawReserves(address(this), wrappedPayoutToken,
       wrappedPayoutToken.previewWithdraw(outputAmount_));
   wrappedPayoutToken.withdraw(outputAmount_, msg.sender, address(this));
   ```

6. **YieldRepurchaseFacility._withdraw()** (line 286-293):
   ```solidity
   uint256 amountInSReserve = sReserve.previewWithdraw(amount);
   TRSRY.increaseWithdrawApproval(address(this), ..., amountInSReserve);
   TRSRY.withdrawReserves(address(this), ..., amountInSReserve);
   ```

**Donation attack feasibility:**

For sUSDS (Sky's Savings USDS), the vault is a large, production ERC4626 vault with substantial TVL. A donation attack would require donating massive amounts of USDS to the sUSDS vault to move the exchange rate. The cost would far exceed any potential gain from the rounding differences across these contracts.

The sDAI/sUSDS vaults use standard `previewWithdraw`/`previewRedeem` which round up and down respectively per ERC4626 spec. The rounding differences are at most 1 wei per conversion.

**Critical observation**: In Operator.swap() (line 363), there is a potential sandwich pattern:
1. Attacker donates to sUSDS vault to inflate share price
2. User calls `Operator.swap(ohm, amountIn, minAmountOut)` to buy reserve
3. `previewWithdraw(amountOut)` returns fewer shares than expected
4. The treasury gives away fewer shares, but the `sReserve.withdraw()` on line 366 would give the user the full `amountOut` in reserve tokens

This is actually **protective** -- the Operator withdraws shares, then redeems them. If shares are underestimated, the `withdraw` call on the sReserve would revert because the Operator wouldn't have enough shares. If shares are overestimated (deflated share price), the Operator would give back excess shares when it calls `withdraw`, but those shares stay in the Operator contract (not returned to TRSRY).

Wait -- let me re-examine:

```solidity
// Line 363-366 (Operator.swap, low wall path)
TRSRY.withdrawReserves(address(this), sReserve, sReserve.previewWithdraw(amountOut));
sReserve.withdraw(amountOut, msg.sender, address(this));
```

`previewWithdraw(amountOut)` returns the number of shares needed to withdraw `amountOut` assets. This rounds up per ERC4626.
Then `sReserve.withdraw(amountOut, ...)` withdraws exactly `amountOut` assets, burning shares.

If between the `previewWithdraw` call and the actual `withdraw`, the exchange rate changes (e.g., via a front-running donation):
- If rate increases: `previewWithdraw` returns X shares, but `withdraw` needs fewer than X shares. Extra shares remain in the Operator. No loss to treasury, minor loss to Operator (shares stranded).
- If rate decreases: `previewWithdraw` returns X shares, but `withdraw` needs more than X shares. `withdraw` reverts (insufficient shares). No loss.

**Finding**: **NOT EXPLOITABLE**. The two-step pattern (preview then actual operation) is safe because `previewWithdraw` rounds up (worst case: more shares withdrawn from TRSRY than needed, which stay in Operator), and the actual `withdraw` would revert if insufficient.

---

## 4. Pattern C: Cross-Policy Approval Accumulation

### Attack Hypothesis

Can policies accumulate withdrawal approvals over time without properly decrementing them, allowing a single policy to withdraw far more than intended?

### Analysis

**Operator approvals** (in `_regenerate`, line 668-685):

```solidity
uint256 currentApproval = sReserve.previewRedeem(
    TRSRY.withdrawApproval(address(this), sReserve)
);
unchecked {
    if (currentApproval < capacity) {
        TRSRY.increaseWithdrawApproval(
            address(this), sReserve,
            sReserve.previewWithdraw(capacity - currentApproval)
        );
    } else if (currentApproval > capacity) {
        TRSRY.decreaseWithdrawApproval(
            address(this), sReserve,
            sReserve.previewWithdraw(currentApproval - capacity)
        );
    }
}
```

This is a delta-based adjustment. It reads the current approval, computes the difference from the desired capacity, and adjusts. This is correct -- it doesn't blindly increase. However, there is a subtle issue:

**Rounding in the approval adjustment:**

1. `currentApproval` = `previewRedeem(withdrawApproval)` -- converts shares to assets (rounds down)
2. If `currentApproval < capacity`, it increases by `previewWithdraw(capacity - currentApproval)` -- converts assets to shares (rounds up)

This means each regeneration cycle could add a tiny rounding excess (~1 wei of shares). Over thousands of regeneration cycles, this could accumulate. However, at 1 wei per cycle and ~3 cycles per day (8-hour heartbeat), this would take years to accumulate even 1e15 shares (less than 1 USDS at current rates). **Negligible**.

**YieldRepurchaseFacility approvals** (in `_withdraw`, line 286-293):

```solidity
function _withdraw(uint256 amount) internal {
    uint256 amountInSReserve = sReserve.previewWithdraw(amount);
    TRSRY.increaseWithdrawApproval(address(this), ERC20(address(sReserve)), amountInSReserve);
    TRSRY.withdrawReserves(address(this), ERC20(address(sReserve)), amountInSReserve);
}
```

This always increases approval by the exact amount it withdraws immediately after. No accumulation possible -- the approval is consumed in the same transaction.

**BondCallback approvals** (in `whitelist`, line 160-168):

```solidity
TRSRY.increaseWithdrawApproval(
    address(this), wrappedPayoutToken,
    wrappedPayoutToken.previewWithdraw(toApprove)
);
```

Approval is increased when a market is whitelisted. It is consumed when `callback()` is called for actual bond purchases. Approval is set based on the market capacity. If the market closes without full capacity being used, the excess approval remains. This is addressed by `TreasuryCustodian.revokePolicyApprovals()` which can clean up approvals from deactivated policies.

But: **if BondCallback is never deactivated, unused approvals from past markets accumulate**. Each time a new market is whitelisted, more approval is added. The old approval from expired markets is never subtracted (only consumed by actual bond redemptions).

This is a known design pattern -- the approval serves as a ceiling, and the actual token transfer in `withdrawReserves` is what matters. Even with accumulated approval, the withdrawal is bounded by the treasury's actual token balance (via `safeTransfer`).

**Finding**: **LOW** -- BondCallback accumulates withdrawal approval from whitelisted markets that don't fully execute. This does not directly cause fund loss because `withdrawReserves` -> `safeTransfer` is bounded by actual token balance. However, the accumulated approval could theoretically be exploited if a new market is created with the BondCallback address and the callback mechanism is used to withdraw against old, stale approvals.

---

## 5. Pattern D: DepositManager Committed vs Actual Deposits

### Attack Hypothesis

Can committed deposits (tracked by BaseDepositFacility) be inflated relative to actual deposits in the DepositManager, allowing over-borrowing?

### Analysis

The committed deposit tracking in `BaseDepositFacility`:

```solidity
// handleCommit (line 143-176)
function handleCommit(IERC20 depositToken_, uint8 depositPeriod_, uint256 amount_)
    external nonReentrant onlyEnabled onlyAuthorizedOperator
{
    // Validate enough uncommitted funds
    uint256 availableDeposits = getAvailableDeposits(depositToken_);
    if (amount_ > availableDeposits) revert ...;

    // Record the commitment
    _assetOperatorCommittedDeposits[...] += amount_;
    _assetCommittedDeposits[depositToken_] += amount_;
}
```

`getAvailableDeposits()` (line 408-423):
```solidity
function getAvailableDeposits(IERC20 depositToken_) public view returns (uint256) {
    uint256 assetLiabilities = DEPOSIT_MANAGER.getOperatorLiabilities(depositToken_, address(this));
    uint256 borrowedAmount = DEPOSIT_MANAGER.getBorrowedAmount(depositToken_, address(this));
    uint256 committedDeposits = _assetCommittedDeposits[depositToken_];

    if (committedDeposits + borrowedAmount > assetLiabilities) return 0;
    return assetLiabilities - committedDeposits - borrowedAmount;
}
```

The constraint is: `committedDeposits + borrowedAmount <= assetLiabilities` (from DepositManager).

`assetLiabilities` in DepositManager equals the total receipt tokens minted for this operator. When someone deposits, `assetLiabilities` increases by the `actualAmount` (which uses `previewRedeem(shares)` to be conservative). When someone withdraws, `assetLiabilities` decreases by the requested `amount`.

**Borrowing capacity** in DepositManager (line 823-836):
```solidity
function getBorrowingCapacity(IERC20 asset_, address operator_) public view returns (uint256) {
    uint256 operatorLiabilities = _assetLiabilities[...];
    uint256 currentBorrowed = getBorrowedAmount(asset_, operator_);
    if (currentBorrowed >= operatorLiabilities) return 0;
    return operatorLiabilities - currentBorrowed;
}
```

The borrowing capacity is `liabilities - currentBorrowed`. Borrowing from DepositManager (via `borrowingWithdraw`) increases `_borrowedAmounts` by the **requested** amount (not actual), and also withdraws actual assets from the vault.

**Potential issue with requested vs actual amounts:**

In `borrowingWithdraw()` (line 662-702):
```solidity
(, actualAmount) = _withdrawAsset(params_.asset, params_.recipient, params_.amount);
_borrowedAmounts[...] += params_.amount;  // Uses REQUESTED amount
```

And in `_withdrawAsset()` (BaseAssetManager, line 131-166):
```solidity
shares = vault.convertToShares(amount_);
if (shares == 0) return (0, 0);
if (vault.previewRedeem(shares) == 0) return (0, 0);
assetAmount = vault.redeem(shares, depositor_, address(this));
```

The actual amount withdrawn could be less than `params_.amount` (due to rounding in `convertToShares` which rounds down). But `_borrowedAmounts` increases by the full `params_.amount`. This means the borrowed amount tracking is slightly higher than the actual assets withdrawn, which is **conservative** (the operator is penalized, not benefited).

Then in `handleBorrow` in BaseDepositFacility (line 258-291):
```solidity
uint256 actualAmount = DEPOSIT_MANAGER.borrowingWithdraw(...amount_...);
_assetOperatorCommittedDeposits[...] -= amount_;  // Decreases by requested amount
_assetCommittedDeposits[depositToken_] -= amount_;
if (actualAmount == 0) revert DepositFacility_ZeroAmount();
```

Committed deposits decrease by the requested amount. Borrowed amount in DepositManager increases by the requested amount. The solvency check in DepositManager (`_validateOperatorSolvency`) ensures:
```
operatorLiabilities <= depositedSharesInAssets + borrowedAmount
```

This is correct because borrowing withdraws vault shares (reducing `depositedSharesInAssets`) while increasing `borrowedAmount` by the same notional -- the check should still pass.

**Finding**: **NOT EXPLOITABLE**. The DepositManager + BaseDepositFacility accounting is internally consistent. Committed deposits cannot be inflated beyond `assetLiabilities - borrowedAmount`, and borrowing always uses the requested amount (conservative) for both committed deposits reduction and borrowed amount increase. The solvency check after every operation prevents insolvency.

---

## 6. Pattern E: TRSRY Debt vs Actual Debt Divergence

### Attack Hypothesis

Can `reserveDebt` tracked by TRSRY diverge from actual token balances, allowing a policy to reclaim more than owed?

### Analysis

**Debt creation paths:**

1. **`incurDebt()`** (line 107-120): Increases `reserveDebt` and `totalDebt`, then transfers tokens. The debt accounting matches the token transfer exactly.

2. **`setDebt()`** (line 147-160): Arbitrarily sets debt without any token transfer. This is the divergence point.

3. **`repayDebt()`** (line 123-144): Uses the actual received amount (not the passed amount) to reduce debt:
   ```solidity
   uint256 received = token_.balanceOf(address(this)) - prevBalance;
   if (received > amount_) received = amount_;
   reserveDebt[token_][debtor_] -= received;
   ```
   This is safe against fee-on-transfer tokens.

**CoolerTreasuryBorrower debt flow:**

```solidity
// borrow(): setDebt to increase, then withdraw sUSDS
TRSRY.setDebt({debtor_: address(this), token_: _USDS, amount_: outstandingDebt + amountInWad});
// ... withdraws sUSDS from TRSRY (NOT USDS)

// repay(): reduces debt, then deposits sUSDS
_reduceDebtToTreasury(debtTokenAmount);  // setDebt to reduce
SUSDS.deposit(debtTokenAmount, address(TRSRY));  // deposits into TRSRY
```

The debt is denominated in USDS but the actual treasury holdings are in sUSDS. Over time, as sUSDS accrues yield, the sUSDS shares become worth more USDS. This means:
- When borrowing: X USDS debt is created, X USDS worth of sUSDS is withdrawn
- When repaying: X USDS debt is reduced, X USDS is deposited as sUSDS to TRSRY

The yield on the lent sUSDS during the loan period is NOT captured in the debt tracking. The USDS debt stays flat while the sUSDS that was withdrawn would have appreciated. This is a known design choice (the interest is implicitly handled by the Cooler loan terms), not a bug.

**writeOffDebt() in CoolerTreasuryBorrower** (line 112-116):
```solidity
function writeOffDebt(uint256 debtTokenAmount) external onlyEnabled onlyRole(COOLER_ROLE) {
    _reduceDebtToTreasury(debtTokenAmount);
}
```

This reduces debt without any token deposit back. This is for loan defaults -- the Cooler writes off the debt. No tokens are returned. This is intentional but does create a divergence where `totalDebt` decreases while no tokens return to TRSRY. The impact is that `getReserveBalance()` decreases, which reduces Operator capacity and other reserve-dependent calculations. This is the correct behavior for a default.

**Finding**: **NOT EXPLOITABLE**. Debt can diverge from actual token flows through `setDebt()` and `writeOffDebt()`, but these are all role-gated. The divergence is by design for specific use cases (admin corrections, loan defaults). No unprivileged user can cause divergence.

---

## 7. Pattern F: Redemption Vault Loan/Default Interaction

### Attack Hypothesis

Can a user start a redemption, take a loan against it, default on the loan, and still extract value?

### Analysis

**The full flow:**

1. **Start redemption**: User deposits receipt tokens, facility marks deposits as committed
2. **Borrow against redemption**: Loan is created, facility lends out committed deposit funds
3. **Default**: Loan expires, anyone calls `claimDefaultedLoan()`

**Default handling** (DepositRedemptionVault line 898-1016):

```solidity
uint256 retainedCollateral = redemption.amount - loan.initialPrincipal; // Buffer amount

loan.isDefaulted = true;
loan.principal = 0;
loan.interest = 0;

uint256 totalToConsume = retainedCollateral + previousPrincipal;

// Burn receipt tokens for the principal
IDepositFacility(facility).handleLoanDefault(IERC20(depositToken), depositPeriod, previousPrincipal, address(this));

// Withdraw retained collateral
retainedCollateralActual = IDepositFacility(facility).handleCommitWithdraw(..., retainedCollateral, ...);

// Reduce redemption amount
redemption.amount -= retainedCollateral + previousPrincipal;
```

**Walk through a concrete scenario:**

- User starts redemption with 100 receipt tokens
- Max borrow = 85% -> principal = 85
- User borrows 85 and receives ~85 in actual deposit tokens
- User never repays
- Loan expires, keeper calls `claimDefaultedLoan()`
- `retainedCollateral` = 100 - 85 = 15 (the buffer)
- `totalToConsume` = 15 + 85 = 100
- Burns 85 receipt tokens via `handleLoanDefault` (reduces assetLiabilities and borrowedAmount by 85)
- Withdraws 15 via `handleCommitWithdraw` (burns 15 receipt tokens, gives deposit tokens)
- `redemption.amount` = 100 - 100 = 0
- Keeper gets reward from the 15, rest goes to treasury

**Net outcome for the attacker (borrower):**
- Received: 85 in deposit tokens (from the loan)
- Lost: 100 in receipt tokens
- Net: -15 in value (lost the 15% buffer)

The attacker loses 15% of their deposit. This is the intended design -- the buffer protects the protocol.

**Can the attacker self-default to gain?**

If the attacker is also the keeper who calls `claimDefaultedLoan()`:
- Received from loan: 85
- Keeper reward: `retainedCollateralActual * _claimDefaultRewardPercentage / ONE_HUNDRED_PERCENT`
- If `_claimDefaultRewardPercentage` = 5%, keeper gets ~0.75
- Lost receipt tokens worth: 100
- Net: 85 + 0.75 - 100 = -14.25

Still a loss. The attacker would need `borrow_percentage + keeper_reward_percentage * (1 - borrow_percentage) > 100%` to profit, which requires the borrow percentage to be extremely close to 100% AND a large keeper reward. The dev comments explicitly warn about this:

> "When setting the max borrow percentage, keep in mind the annual interest rate and claim default reward percentage, as the three configuration values can create incentives for borrowers to not repay their loans"

**Edge case: Can the user cancel the redemption after borrowing?**

`cancelRedemption()` checks:
```solidity
if (_redemptionLoan[redemptionKey].principal > 0)
    revert RedemptionVault_UnpaidLoan(msg.sender, redemptionId_);
```

Cannot cancel while a loan is outstanding. Good.

**Edge case: Can the user finish the redemption after borrowing?**

`finishRedemption()` checks:
```solidity
if (_redemptionLoan[redemptionKey].principal > 0)
    revert RedemptionVault_UnpaidLoan(msg.sender, redemptionId_);
```

Cannot finish while a loan is outstanding. Good.

**Finding**: **NOT EXPLOITABLE**. The loan buffer (redemption amount - borrowed principal) protects the protocol. Self-default is unprofitable unless governance misconfigures the parameters (borrow percentage + keeper reward > 100%), which the code comments explicitly warn about.

---

## 8. Pattern G: ERC4626 Vault Rounding Across Multiple Contracts

### Attack Hypothesis

Rounding differences in `previewWithdraw` (rounds up), `previewRedeem` (rounds down), and `convertToShares` (rounds down) across multiple contracts could accumulate to create meaningful discrepancies.

### Analysis

**Rounding direction summary:**

| Function | Rounds | Direction favors |
|----------|--------|------------------|
| `previewWithdraw(assets)` -> shares | Up | Vault (more shares burned) |
| `previewRedeem(shares)` -> assets | Down | Vault (fewer assets given) |
| `convertToShares(assets)` -> shares | Down | Vault (fewer shares) |
| `deposit(assets)` -> shares | Down | Vault |
| `withdraw(assets)` burns shares | Up | Vault |
| `redeem(shares)` -> assets | Down | Vault |

**Operator low-wall swap flow (line 362-366):**
```
shares_needed = sReserve.previewWithdraw(amountOut)  // rounds UP
TRSRY.withdrawReserves(this, sReserve, shares_needed)  // transfers shares_needed
sReserve.withdraw(amountOut, user, this)  // burns shares (rounds UP)
```

The shares withdrawn from TRSRY (`shares_needed`) could be >= the shares actually burned by `withdraw`. The difference (0-1 wei) stays in the Operator contract. Over many swaps, the Operator could accumulate dust amounts of sReserve.

**YieldRepurchaseFacility flow (line 286-293):**
```
shares = sReserve.previewWithdraw(amount)  // rounds UP
TRSRY.increaseWithdrawApproval(this, sReserve, shares)
TRSRY.withdrawReserves(this, sReserve, shares)
```

Then later in `endEpoch` (line 185-189):
```
sReserve.redeem(sReserve.previewWithdraw(bidAmountFromSReserve), ...)  // rounds UP then redeems
```

`previewWithdraw` inside `redeem`'s argument is problematic -- it calculates shares needed, but `redeem` expects shares as input. This is actually computing `previewWithdraw(amount)` to get shares, then redeeming those shares. The shares given would yield `<= amount` in assets. The rounding is: slightly more shares redeemed than strictly necessary, slightly less or equal assets received.

**CoolerTreasuryBorrower flow (line 96-99):**
```
susdsAmount = SUSDS.previewWithdraw(amountInWad)  // rounds UP
TRSRY.increaseWithdrawApproval(this, SUSDS, susdsAmount)
TRSRY.withdrawReserves(this, SUSDS, susdsAmount)
SUSDS.withdraw(amountInWad, recipient, this)  // burns shares (rounds UP)
```

Same pattern as Operator. Potential dust accumulation in CoolerTreasuryBorrower.

**BaseAssetManager._withdrawAsset flow (used by DepositManager):**
```
shares = vault.convertToShares(amount_)  // rounds DOWN
assetAmount = vault.redeem(shares, depositor_, this)  // rounds DOWN
```

Here `convertToShares` rounds down (fewer shares), then `redeem` rounds down (fewer assets). The user receives slightly less than `amount_`. The shares tracking in `_operatorShares` decreases by the rounded-down shares. This means the operator retains slightly more shares than the theoretical minimum, which is correct (vault retains value).

**Cumulative impact assessment:**

Each rounding error is at most 1 wei per operation. For sUSDS (18 decimals), 1 wei = 1e-18 USDS. Even at 1000 operations per day for 10 years:
- 1000 * 365 * 10 * 1e-18 = 3.65e-12 USDS

This is completely negligible.

**Finding**: **INFORMATIONAL**. Rounding errors across contracts are bounded to 1 wei per operation per contract and always favor the vault/protocol side. Cumulative impact is negligible even over extreme timeframes. No exploitable discrepancy exists.

---

## 9. Complete Withdrawal Path Inventory

### Direct TRSRY Withdrawals (via `withdrawReserves`)

| # | Policy | Function | Token | Approval Source | Rate Limit |
|---|--------|----------|-------|----------------|------------|
| 1 | Operator | `swap(ohm, ...)` | sReserve | `_regenerate()` sets to fullCapacity | Wall capacity |
| 2 | BondCallback | `callback()` | sReserve/reserve | `whitelist()` sets per market | Market capacity |
| 3 | YieldRepurchaseFacility | `_withdraw()` | sReserve | Self-approves per epoch | Weekly yield |
| 4 | CoolerTreasuryBorrower | `borrow()` | sUSDS | Self-approves per borrow | Cooler role-gated |
| 5 | TreasuryCustodian | `withdrawReservesTo()` | Any | External (custodian grants) | Custodian role |

### Indirect Withdrawals (via DepositManager -> Vault)

| # | Policy | Function | Path | Rate Limit |
|---|--------|----------|------|------------|
| 6 | BaseDepositFacility | `handleCommitWithdraw()` | DM.withdraw -> vault.redeem | Committed deposits |
| 7 | BaseDepositFacility | `handleBorrow()` | DM.borrowingWithdraw -> vault.redeem | Borrowing capacity |
| 8 | BaseDepositFacility | `reclaim()` | DM.withdraw -> vault.redeem | Available + reclaim rate |
| 9 | DepositManager | `claimYield()` | vault.redeem | Yield excess |
| 10 | DepositManager | `withdraw()` | vault.redeem | Receipt token balance |

### Debt-Based Withdrawals (via `incurDebt`)

| # | Policy | Function | Rate Limit |
|---|--------|----------|------------|
| 11 | (Any debtor-approved policy) | `TRSRY.incurDebt()` | debtApproval |

### Can paths be chained?

The key question is whether a single entity can trigger multiple independent withdrawal paths. The analysis shows:

- **Different policies have separate, independent approvals**. A user cannot combine Operator's approval with BondCallback's approval.
- **Within a policy**, the approval is decremented atomically on withdrawal. No double-spend is possible.
- **Debt inflation** (Pattern A) affects `getReserveBalance` which only impacts Operator's `fullCapacity` calculation. It does not grant additional approvals to other policies.
- **No policy can delegate its approval to another policy** -- the `permissioned` modifier checks `msg.sender`.

---

## 10. Findings Summary

### FINDING-001: Debt Inflation Amplifies Operator Capacity (Medium)

**File**: `/root/immunefi/audits/olympus-v3/src/policies/Operator.sol` (line 902-916)
**Interacts with**: `/root/immunefi/audits/olympus-v3/src/policies/cooler/CoolerTreasuryBorrower.sol` (line 119-121) and `/root/immunefi/audits/olympus-v3/src/policies/TreasuryCustodian.sol` (line 115-122)

**Description**: `Operator.fullCapacity()` reads `TRSRY.getReserveBalance()` which includes `totalDebt`. If an admin uses `CoolerTreasuryBorrower.setDebt()` or a custodian uses `TreasuryCustodian.increaseDebt()` to inflate debt without actual token outflow, the Operator's calculated capacity increases. On the next `_regenerate()`, the Operator approves itself for a larger sReserve withdrawal than the treasury actually holds in liquid sReserve. While the actual `safeTransfer` in `withdrawReserves` would revert if insufficient balance exists, this creates a window where the approved amount exceeds actual holdings. If debt is subsequently inflated to match (e.g., through further admin action), the over-approval could be consumed.

**Severity**: Medium. Requires privileged access (admin/custodian role). The `safeTransfer` provides a backstop. However, this represents a cross-policy coupling that is not obvious from reading any single contract.

**Recommendation**: Consider having `Operator.fullCapacity()` use the actual token balance rather than `getReserveBalance()`, or add explicit debt-awareness so the capacity calculation excludes illiquid debt positions.

### FINDING-002: BondCallback Approval Accumulation (Low)

**File**: `/root/immunefi/audits/olympus-v3/src/policies/BondCallback.sol` (line 99-169)

**Description**: Each time a bond market is whitelisted via `whitelist()`, the BondCallback receives additional withdrawal approval from TRSRY. If a market closes without fully executing (common for cushion markets), the unused approval persists. Over many market cycles, the BondCallback could accumulate withdrawal approval significantly exceeding any single market's capacity. While this does not cause direct fund loss (bounded by `safeTransfer`), it represents excess permission that could be leveraged if the BondCallback contract is compromised or if an unintended interaction with the aggregator/teller system allows replaying bond callbacks against stale approvals.

**Severity**: Low. The accumulated approval alone cannot drain funds beyond the treasury's token balance. Would require BondCallback compromise to exploit.

**Recommendation**: Implement approval cleanup when markets close, similar to how the Operator handles MINTR approval in `_regenerate()`. Alternatively, `BondCallback.blacklist()` should reduce the outstanding approval for the closed market.

### FINDING-003: Operator sReserve Dust Accumulation (Informational)

**File**: `/root/immunefi/audits/olympus-v3/src/policies/Operator.sol` (line 362-366)

**Description**: The Operator uses `previewWithdraw` (rounds up) to calculate shares to withdraw from TRSRY, then calls `sReserve.withdraw()` which burns the actual required shares. The difference (0-1 wei per swap) remains in the Operator contract and is never returned to TRSRY. Over thousands of swaps, this amounts to negligible dust.

**Severity**: Informational. Economic impact is negligible (well below gas costs to exploit).

### No Finding: Patterns D, E, F

Patterns D (committed deposit inflation), E (debt divergence), and F (redemption vault loan/default) were thoroughly analyzed and found to have adequate protections. The DepositManager solvency checks, role-gated debt operations, and loan buffer mechanism (15%+ overcollateralization) prevent exploitation.

---

## Appendix: Key File References

| File | Path |
|------|------|
| OlympusTreasury | `/root/immunefi/audits/olympus-v3/src/modules/TRSRY/OlympusTreasury.sol` |
| TRSRY v1 Interface | `/root/immunefi/audits/olympus-v3/src/modules/TRSRY/TRSRY.v1.sol` |
| TreasuryCustodian | `/root/immunefi/audits/olympus-v3/src/policies/TreasuryCustodian.sol` |
| Operator | `/root/immunefi/audits/olympus-v3/src/policies/Operator.sol` |
| YieldRepurchaseFacility | `/root/immunefi/audits/olympus-v3/src/policies/YieldRepurchaseFacility.sol` |
| CoolerTreasuryBorrower | `/root/immunefi/audits/olympus-v3/src/policies/cooler/CoolerTreasuryBorrower.sol` |
| BondCallback | `/root/immunefi/audits/olympus-v3/src/policies/BondCallback.sol` |
| EmissionManager | `/root/immunefi/audits/olympus-v3/src/policies/EmissionManager.sol` |
| DepositManager | `/root/immunefi/audits/olympus-v3/src/policies/deposits/DepositManager.sol` |
| DepositRedemptionVault | `/root/immunefi/audits/olympus-v3/src/policies/deposits/DepositRedemptionVault.sol` |
| BaseDepositFacility | `/root/immunefi/audits/olympus-v3/src/policies/deposits/BaseDepositFacility.sol` |
| BaseAssetManager | `/root/immunefi/audits/olympus-v3/src/bases/BaseAssetManager.sol` |
| Kernel | `/root/immunefi/audits/olympus-v3/src/Kernel.sol` |
