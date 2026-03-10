# Second-Pass Audit: Convertible Deposit Pipeline

## Scope

Full line-by-line review of the Olympus V3 Convertible Deposit pipeline:

| Contract | Path |
|----------|------|
| ConvertibleDepositAuctioneer | `src/policies/deposits/ConvertibleDepositAuctioneer.sol` |
| ConvertibleDepositFacility | `src/policies/deposits/ConvertibleDepositFacility.sol` |
| BaseDepositFacility | `src/policies/deposits/BaseDepositFacility.sol` |
| DepositManager | `src/policies/deposits/DepositManager.sol` |
| DepositRedemptionVault | `src/policies/deposits/DepositRedemptionVault.sol` |
| CDAuctioneerLimitOrders | `src/policies/deposits/LimitOrders.sol` |
| ReceiptTokenManager | `src/policies/deposits/ReceiptTokenManager.sol` |
| OlympusDepositPositionManager | `src/modules/DEPOS/OlympusDepositPositionManager.sol` |
| ERC6909Wrappable | `src/libraries/ERC6909Wrappable.sol` |
| CloneableReceiptToken | `src/libraries/CloneableReceiptToken.sol` |
| BaseAssetManager | `src/bases/BaseAssetManager.sol` |

---

## Executive Summary

After exhaustive line-by-line analysis of the entire Convertible Deposit pipeline, I identified several findings ranging from medium to informational severity. The system is generally well-designed with strong isolation between operators, proper solvency checks, and consistent accounting. However, there are subtle economic edge cases and accounting discrepancies that could be exploited or lead to protocol loss under specific conditions.

---

## Attack Vector A: Conversion Price vs. Market Price Divergence

### Analysis

The conversion price is set at auction time in `ConvertibleDepositAuctioneer._bid()` (line 306):

```solidity
conversionPrice: depositIn.mulDivUp(_ohmScale, ohmOut), // Assets per OHM, deposit token scale
```

The price is locked into the DEPOS position and used later in `ConvertibleDepositFacility._previewConvert()` (line 232):

```solidity
convertedTokenOut = FullMath.mulDiv(
    amount_, // Scale: deposit token
    _OHM_SCALE,
    position.conversionPrice // Scale: deposit token
);
```

**Key observations:**

1. **Bounded by auction dynamics, not by market price**: The conversion price is determined purely by auction tick mechanics (supply/demand within the auction), not by any oracle or market reference. The `minPrice` parameter sets a floor, but there is no ceiling except the tick step mechanism. If the `minPrice` is set too low relative to OHM market price, users can acquire conversion rights at a significant discount.

2. **No maximum conversion price divergence check**: There is no check that the locked conversion price remains within some bound of the current market price at conversion time. This is by design (the conversion is a call option), but it means the protocol accepts unlimited dilution risk if OHM price appreciates significantly after the auction.

3. **Expiry provides bounded exposure**: Positions have an expiry (`block.timestamp + periodMonths * 30 days`), which limits the time window for divergence. However, with long periods (e.g., 12 months), the exposure window is significant.

**Mitigations already in place:**
- The auction uses exponential tick size reduction after the daily target is met, making it progressively more expensive to acquire large amounts at low prices.
- The `minPrice` floor prevents zero-cost or near-zero-cost conversion.
- `setAuctionParameters()` is called daily by the emission manager, allowing governance to adjust.

### Verdict: BY DESIGN (Informational)

The conversion price divergence is inherent to the convertible deposit mechanism. The protocol accepts this as the cost of attracting deposits. The key governance controls (minPrice, target, tickStep) appear sufficient if properly managed.

---

## Attack Vector B: Receipt Token Arbitrage via Wrapping/Unwrapping

### Analysis

The `ERC6909Wrappable` contract allows wrapping ERC6909 tokens to ERC20 and back. The critical path:

**Wrapping** (`ERC6909Wrappable.wrap()`, line 196):
```solidity
function wrap(uint256 tokenId_, uint256 amount_) public returns (address wrappedToken) {
    _burn(msg.sender, tokenId_, amount_, false);   // Burns ERC6909
    IERC20BurnableMintable wrappedToken_ = _getWrappedToken(tokenId_);
    wrappedToken_.mintFor(msg.sender, amount_);     // Mints ERC20
```

**Unwrapping** (`ERC6909Wrappable.unwrap()`, line 216):
```solidity
function unwrap(uint256 tokenId_, uint256 amount_) public {
    _burn(msg.sender, tokenId_, amount_, true);     // Burns ERC20
    _mint(msg.sender, tokenId_, amount_);           // Mints ERC6909
```

**Key observations:**

1. **1:1 conversion**: Wrapping and unwrapping maintain a strict 1:1 ratio. No value is created or destroyed.

2. **Total supply tracking**: The `_totalSupplies` mapping in `ERC6909Wrappable._update()` correctly tracks mints and burns of the ERC6909 side. The ERC20 supply is tracked separately in the CloneableReceiptToken.

3. **Burns are gated on ERC6909 allowances**: The `_burn()` function (line 120) checks `_spendAllowance(onBehalfOf_, msg.sender, tokenId_, amount_)` for both wrapped and unwrapped burns when `onBehalfOf_ != msg.sender`. This means ERC6909 allowances control both wrapped and unwrapped burn permissions.

4. **Dual-use concern**: A user holding wrapped ERC20 receipt tokens COULD use them in DeFi (e.g., as collateral in a lending protocol). However, the conversion in `ConvertibleDepositFacility.convert()` requires burning receipt tokens (`DEPOSIT_MANAGER.withdraw()` which calls `_RECEIPT_TOKEN_MANAGER.burn()`). You cannot convert without burning the receipt tokens, so dual-use does not lead to double conversion.

5. **DepositManager.withdraw burns based on `isWrapped` parameter**: When converting, the `wrappedReceipt_` flag is passed to `DEPOSIT_MANAGER.withdraw()`, which routes to the correct burn path. This is a user-provided flag -- if the user says `wrappedReceipt_ = true` but holds ERC6909 tokens (or vice versa), the burn will fail because the balance check will fail.

### Verdict: NO VULNERABILITY FOUND

The wrapping/unwrapping system maintains strict 1:1 invariants and burns are properly gated.

---

## Attack Vector C: Position Splitting + Conversion Gaming

### Analysis

The split function in `BaseDepositFacility.split()` (line 547-601) and `OlympusDepositPositionManager.split()` (line 248-306):

**BaseDepositFacility.split():**
```solidity
function split(uint256 positionId_, uint256 amount_, address to_, bool wrap_)
    external nonReentrant onlyEnabled returns (uint256)
{
    Position memory position = DEPOS.getPosition(positionId_);
    if (position.operator != address(this)) revert ...;
    if (position.owner != msg.sender) revert ...;
    if (amount_ == 0 || amount_ > position.remainingDeposit) revert ...;

    // Minimum deposit validation
    if (minimumDeposit > 0) {
        if (amount_ < minimumDeposit) revert ...;
        if (position.remainingDeposit - amount_ < minimumDeposit) revert ...;
    }

    _split(positionId_, amount_);  // Virtual hook (no-op in base)
    uint256 newPositionId = DEPOS.split(positionId_, amount_, to_, wrap_);
    return newPositionId;
}
```

**OlympusDepositPositionManager.split():**
```solidity
function split(uint256 positionId_, uint256 amount_, address to_, bool wrap_) external ... {
    Position storage position = _positions[positionId_];
    if (amount_ == 0) revert ...;
    if (amount_ > position.remainingDeposit) revert ...;
    if (to_ == address(0)) revert ...;

    uint256 remainingDeposit = position.remainingDeposit - amount_;
    position.remainingDeposit = remainingDeposit;  // Reduce old position

    newPositionId = _create(
        position.operator,
        MintParams({
            ...
            remainingDeposit: amount_,             // New position gets split amount
            conversionPrice: position.conversionPrice,  // SAME conversion price
            expiry: position.expiry,                     // SAME expiry
            ...
        })
    );
}
```

**Key observations:**

1. **Total value invariant maintained**: `oldPosition.remainingDeposit - amount + newPosition.remainingDeposit (= amount)` = original `remainingDeposit`. The split does NOT create additional conversion rights.

2. **Conversion price and expiry preserved**: Both positions inherit the same conversion price and expiry. No advantage is gained from splitting.

3. **No receipt tokens involved in split**: Splitting only affects the DEPOS position (NFT). Receipt tokens are NOT split or created during this operation. The user still needs to burn receipt tokens proportional to the amount being converted.

4. **Minimum deposit enforced**: Both the new position and the remaining position must meet the minimum deposit requirement, preventing dust position attacks.

### Verdict: NO VULNERABILITY FOUND

The split function correctly maintains the total value invariant. No conversion rights are created.

---

## Attack Vector D: Deposit -> Borrow -> Default Cycle

### Analysis

This is the most complex attack path. Let me trace the full flow:

### Step 1: User deposits, gets receipt tokens + position

**ConvertibleDepositFacility.createPosition():**
- Calls `DEPOSIT_MANAGER.deposit()` -> mints receipt tokens to depositor, records `_assetLiabilities[key] += actualAmount`
- Creates DEPOS position with `remainingDeposit = actualAmount`

### Step 2: User starts redemption via DepositRedemptionVault

**DepositRedemptionVault.startRedemption(positionId, amount):**
- Creates UserRedemption record
- Calls `facility.handleCommit()` -> increases `_assetCommittedDeposits` and `_assetOperatorCommittedDeposits`
- Calls `facility.handlePositionRedemption()` -> decreases `position.remainingDeposit`
- Pulls receipt tokens from user to vault

### Step 3: Borrow against redemption

**DepositRedemptionVault.borrowAgainstRedemption():**
- Calculates `principal = amount * maxBorrowPercentage / 100%`
- Calls `facility.handleBorrow()` which calls:
  - `DEPOSIT_MANAGER.borrowingWithdraw()` -> withdraws from vault, increases `_borrowedAmounts[key]`
  - Then decreases `_assetCommittedDeposits` and `_assetOperatorCommittedDeposits`
- User receives deposit tokens (e.g., USDS)

### Step 4: Loan defaults

**DepositRedemptionVault.claimDefaultedLoan():**
- `retainedCollateral = redemption.amount - loan.initialPrincipal`
- Burns receipt tokens for `previousPrincipal` via `facility.handleLoanDefault()` which calls:
  - `DEPOSIT_MANAGER.borrowingDefault()` -> burns receipt tokens, decreases `_assetLiabilities[key]`, decreases `_borrowedAmounts[key]`
- Withdraws `retainedCollateral` via `facility.handleCommitWithdraw()` which calls:
  - `DEPOSIT_MANAGER.withdraw()` -> burns receipt tokens, decreases `_assetLiabilities[key]`
  - Also decreases `_assetCommittedDeposits` and `_assetOperatorCommittedDeposits`
- Remaining `redemption.amount` (= initialPrincipal - previousPrincipal) stays

**Critical accounting check for the default path:**

Let's trace with concrete numbers. User deposits 100 USDS, maxBorrow = 85%:
1. After deposit: `liabilities = 100`, `receiptTokens = 100`, `position.remainingDeposit = 100`
2. After startRedemption(positionId, 100): `committed = 100`, `position.remainingDeposit = 0`, vault holds 100 receipt tokens
3. After borrowAgainstRedemption: `principal = 85`, `borrowed = 85`, `committed -= 85 -> 15`. Vault withdraws 85 USDS from ERC4626.
4. After claimDefaultedLoan (no repayment, full default):
   - `retainedCollateral = 100 - 85 = 15`
   - `previousPrincipal = 85`
   - `handleLoanDefault(85)`: burns 85 receipt tokens, `liabilities -= 85 -> 15`, `borrowed -= 85 -> 0`
   - `handleCommitWithdraw(15)`: burns 15 receipt tokens, `liabilities -= 15 -> 0`, `committed -= 15 -> 0`
   - `redemption.amount -= (15 + 85) -> 0`

**What did the user get?** 85 USDS (from the borrow). The protocol lost 85 USDS from the vault.

**What did the protocol get?** The retained collateral (15 USDS), split between keeper reward and treasury.

**Is this a vulnerability?** The protocol loses `principal - retainedCollateral = 85 - 15 = 70 USDS` net. But this is expected behavior for a lending system where defaults happen. The question is whether the user can **also** retain conversion rights.

**Critical check -- does the user still have conversion rights?**
- `position.remainingDeposit` was set to 0 in step 2 (handlePositionRedemption)
- The user has no receipt tokens (they were transferred to vault in step 2 and burned in step 4)
- `redemption.amount` is now 0

**The user has lost all conversion rights.** The protocol design correctly prevents the user from having both the borrowed funds AND conversion rights.

### FINDING D-1: Self-Default Economic Attack (Informational/Low)

**However**, there is a subtle economic incentive issue. The user can:
1. Deposit 100 USDS, get position + receipt tokens
2. Start redemption
3. Borrow 85 USDS
4. Have a friend call `claimDefaultedLoan()` after due date
5. Friend receives keeper reward

If the keeper reward percentage is set high enough (e.g., 100%), the user and friend together can extract `85 (borrow) + 15 (full keeper reward) = 100 USDS`, essentially getting all their money back without the lock-up period.

The protocol devs are aware of this (see the comments on `setMaxBorrowPercentage`, `setAnnualInterestRate`, and `setClaimDefaultRewardPercentage`):
> "When setting the max borrow percentage, keep in mind the annual interest rate and claim default reward percentage, as the three configuration values can create incentives for borrowers to not repay their loans (e.g. claim default on their own loan)"

### Verdict: DESIGN ACKNOWLEDGED (Informational)

The self-default attack is acknowledged in the code comments. Configuration must be carefully managed to prevent it.

---

## Attack Vector E: Cross-Operator Deposit Manipulation

### Analysis

The DepositManager uses operator-isolated accounting:

1. **Receipt token IDs include the operator**: `getReceiptTokenId(owner, asset, depositPeriod, operator)` -- receipt tokens are unique per operator.

2. **Asset liabilities are per-operator**: `_assetLiabilities[keccak256(asset, operator)]`

3. **Borrowed amounts are per-operator**: `_borrowedAmounts[keccak256(asset, operator)]`

4. **BaseDepositFacility committed deposits are per-operator**: `_assetOperatorCommittedDeposits[keccak256(depositToken, operator)]`

5. **Solvency check is per-operator**: `_validateOperatorSolvency()` checks that `liabilities <= depositedSharesInAssets + borrowedAmount` for the specific operator.

6. **Key isolation**: The `_getAssetLiabilitiesKey()` and `_getOperatorKey()` both use `keccak256(abi.encode(address(asset), operator))`. These match, ensuring consistency.

**Can a malicious operator inflate committed deposits?**

Looking at `BaseDepositFacility.handleCommit()` (line 143):
```solidity
function handleCommit(...) external nonReentrant onlyEnabled onlyAuthorizedOperator {
    uint256 availableDeposits = getAvailableDeposits(depositToken_);
    if (amount_ > availableDeposits) revert ...;

    _assetOperatorCommittedDeposits[key] += amount_;
    _assetCommittedDeposits[depositToken_] += amount_;
}
```

The `getAvailableDeposits()` function (line 408):
```solidity
function getAvailableDeposits(IERC20 depositToken_) public view returns (uint256) {
    uint256 assetLiabilities = DEPOSIT_MANAGER.getOperatorLiabilities(depositToken_, address(this));
    uint256 borrowedAmount = DEPOSIT_MANAGER.getBorrowedAmount(depositToken_, address(this));
    uint256 committedDeposits = _assetCommittedDeposits[depositToken_];

    if (committedDeposits + borrowedAmount > assetLiabilities) return 0;
    return assetLiabilities - committedDeposits - borrowedAmount;
}
```

**Key observation**: `getAvailableDeposits()` uses `address(this)` (the facility address) for liabilities, not the operator. This means available deposits are calculated at the FACILITY level, not the per-operator level. However, committed deposits are tracked at BOTH the facility level (`_assetCommittedDeposits`) and the per-operator level (`_assetOperatorCommittedDeposits`).

**The committed deposits from all operators are summed in `_assetCommittedDeposits`**, and this sum is used to bound `getAvailableDeposits()`. This means one operator cannot over-commit because the total committed deposits are bounded by the total facility liabilities.

**Can operator A access operator B's committed deposits?**

No. The `handleBorrow()` function checks `getCommittedDeposits(depositToken_, msg.sender)` which returns the per-operator committed deposits. An operator can only borrow against its own committed deposits.

Similarly, `handleCommitWithdraw()` checks per-operator committed deposits.

### Verdict: NO VULNERABILITY FOUND

Operator isolation is correctly maintained. The per-operator and per-facility accounting are consistent and prevent cross-operator manipulation.

---

## Attack Vector F: Redemption Vault Timing Attack

### Analysis

The redemption lifecycle: `startRedemption` -> (optional: `borrowAgainstRedemption` -> `repayLoan`) -> `finishRedemption`

**Timing concerns:**

1. **Start + immediate cancel**: User calls `startRedemption()` then immediately `cancelRedemption()`. This moves receipt tokens to the vault and back. The `handleCommit()` and `handleCommitCancel()` are called. No economic advantage since the user gets back exactly what they put in.

2. **Start + borrow + cancel attempt**: After borrowing, `cancelRedemption()` reverts because `_redemptionLoan[key].principal > 0` (line 403). This prevents the user from canceling a redemption with an outstanding loan.

3. **Start + borrow + repay + finish before lock-up**: `finishRedemption()` checks `block.timestamp < redemption.redeemableAt` (line 483), so the user cannot finish early. The `redeemableAt` is set to `block.timestamp + depositPeriod * 30 days` (for receipt-token based redemption) or `position.expiry` (for position-based redemption).

4. **Start + borrow + repay + cancel**: After full repayment (`loan.principal == 0`), the loan principal check in `cancelRedemption()` passes. But wait -- looking more carefully at the loan:

```solidity
// repayLoan updates:
loan.principal -= principalRepaidActual > loan.principal ? loan.principal : principalRepaidActual;
```

After full repayment, `loan.principal = 0`. Now `cancelRedemption()`:
```solidity
if (_redemptionLoan[redemptionKey].principal > 0)
    revert RedemptionVault_UnpaidLoan(msg.sender, redemptionId_);
```

This passes! So the user can cancel the redemption after repaying the loan. This is correct behavior -- they repaid the loan, so their collateral should be accessible.

### FINDING F-1: Position Redemption Not Cancelled When Position Ownership Changed (Low)

In `cancelRedemption()` (line 416-428), there is a conditional check for position-based redemptions:

```solidity
if (redemption.positionId != _NO_POSITION) {
    if (DEPOS.getPosition(redemption.positionId).owner == msg.sender) {
        IDepositFacility(redemption.facility).handlePositionCancelRedemption(
            redemption.positionId, amount_
        );
    }
    // If ownership changed, position is NOT modified
}
```

If the position has been transferred (via ERC721 transfer of the wrapped position), the original owner can still cancel the redemption and get receipt tokens back, but the position's `remainingDeposit` is NOT restored. This means:

- **Original owner** gets receipt tokens back (can reclaim or use them)
- **New position owner** has a position with reduced `remainingDeposit` and cannot restore it
- **No double-counting**: The receipt tokens returned to the original owner come from the vault's custody. The `handleCommitCancel()` correctly reduces committed deposits. The new position owner simply has a reduced position.

This is actually a feature, not a bug: it prevents the original owner from inflating the new owner's position. However, the original owner effectively received receipt tokens AND transferred (sold?) the position, which could be considered a form of extraction if the position buyer didn't know about the pending redemption. The position's `remainingDeposit` was already reduced during `startRedemption`, so a diligent buyer would see this.

### Verdict: NO SIGNIFICANT VULNERABILITY FOUND

The timing flow is well-handled with proper state checks at each step.

---

## Attack Vector G: Auction Price Decay + Limit Order Interaction

### Analysis

The `CDAuctioneerLimitOrders` contract allows users to create limit orders that MEV bots fill when the auction price is favorable.

**fillOrder flow:**
1. Filler calls `fillOrder(orderId, fillAmount)`
2. Checks `CD_AUCTIONEER.previewBid(depositPeriod, fillAmount)` for OHM output
3. Checks `(fillAmount * OHM_SCALE) / expectedOhmOut > order.maxPrice` to enforce the user's price limit
4. Withdraws USDS from sUSDS
5. Approves DEPOSIT_MANAGER for the fill amount
6. Calls `CD_AUCTIONEER.bid()` to execute
7. Transfers position NFT and receipt tokens to order owner
8. Pays incentive to filler

**Price check discrepancy (potential MEV extraction):**

Line 403-405:
```solidity
uint256 expectedOhmOut = CD_AUCTIONEER.previewBid(order.depositPeriod, fillAmount_);
if (expectedOhmOut == 0) revert ZeroOhmOut();
if ((fillAmount_ * OHM_SCALE) / expectedOhmOut > order.maxPrice) revert PriceAboveMax();
```

Line 418:
```solidity
(uint256 ohmOut, uint256 positionId, , uint256 actualAmount) = CD_AUCTIONEER.bid(
    order.depositPeriod, fillAmount_, expectedOhmOut, true, true
);
```

The `previewBid()` call is a VIEW function that does not update state. Between `previewBid()` and `bid()`, the auction state can change if another transaction is front-run. However, `bid()` receives `expectedOhmOut` as `minOhmOut_`, providing slippage protection.

**Wait -- examining more carefully**: The `bid()` function in the Auctioneer has `minOhmOut_` check:
```solidity
if (output.ohmOut < params.minOhmOut)
    revert ConvertibleDepositAuctioneer_ConvertedAmountSlippage(...);
```

So the order owner is protected by the minOhmOut check. The filler can't steal from the order owner.

### FINDING G-1: Sandwich Attack on Limit Order Fills (Informational)

A sophisticated attacker could:
1. See a pending `fillOrder()` transaction in the mempool
2. Front-run with their own `bid()` to push the auction price up
3. The `fillOrder()` executes at a higher price (worse for the order owner) but still within maxPrice
4. Back-run to reclaim any benefit

This is standard MEV and not specific to this protocol. The `maxPrice` limit provides protection for order owners, and the `minOhmOut` check (set to `expectedOhmOut` from `previewBid`) provides atomic slippage protection within the same block.

However, there is a subtle issue: if `previewBid` returns a value calculated before a front-running bid in the same block, and then `bid()` sees the post-front-run state, the `minOhmOut` check would revert. This is actually protective -- the fill would fail rather than execute at a worse price. The filler would need to retry.

### FINDING G-2: Yield Extraction from Limit Order sUSDS Holdings (Informational)

The limit order contract deposits all USDS into sUSDS. Yield accrues to a configurable `yieldRecipient`. The accounting is:

```solidity
function getAccruedYieldShares() public view returns (uint256) {
    uint256 sUsdsBalance = SUSDS.balanceOf(address(this));
    uint256 sharesRequired = SUSDS.previewWithdraw(totalUsdsOwed);
    return sUsdsBalance.saturatingSub(sharesRequired);
}
```

The `totalUsdsOwed` tracks the sum of all active order deposit + incentive budgets. Yield is the excess sUSDS shares beyond what's needed to cover obligations.

**Potential issue**: If sUSDS has a rebasing or variable rate, and the rate drops significantly, `previewWithdraw(totalUsdsOwed)` could require more shares than `sUsdsBalance`, meaning the contract becomes temporarily insolvent for its obligations.

However, `saturatingSub` prevents revert in the view function, and actual withdrawals in `cancelOrder()` and `fillOrder()` call `SUSDS.withdraw(usdsNeeded, ...)` which would revert if insufficient shares. This is a known risk of using yield-bearing vaults.

### Verdict: NO SIGNIFICANT VULNERABILITY FOUND

The limit order system has appropriate protections. Standard MEV risks apply.

---

## Additional Findings

### FINDING H-1: Conversion Does Not Reduce Committed Deposits in BaseDepositFacility (Medium/Low)

**Location**: `ConvertibleDepositFacility.convert()` (line 301-366)

When a user converts receipt tokens to OHM:

```solidity
function convert(...) external ... {
    // ... validation and position updates ...

    // Update remaining deposit on each position
    DEPOS.setRemainingDeposit(positionId, position.remainingDeposit - depositAmount);

    // Withdraw underlying asset and deposit into treasury
    DEPOSIT_MANAGER.withdraw(...);  // Burns receipt tokens, reduces liabilities

    // Mint OHM
    MINTR.mintOhm(msg.sender, convertedTokenOut);
}
```

The `DEPOSIT_MANAGER.withdraw()` call reduces `_assetLiabilities` for the facility operator. The `_withdrawAsset()` call withdraws from the ERC4626 vault, reducing the operator's shares.

**But note**: The conversion does NOT call `handleCommitCancel()` or directly modify `_assetCommittedDeposits` / `_assetOperatorCommittedDeposits` in BaseDepositFacility.

This means if an operator (e.g., DepositRedemptionVault) has committed deposits, and the user converts directly (not through the redemption path), the committed deposits figure could become stale. Specifically:

- If committed deposits were 50, total liabilities were 100
- User converts 30 receipt tokens -> liabilities drop to 70
- Available deposits = 70 - 50 (committed) - 0 (borrowed) = 20
- But the committed 50 may no longer be fully backed if the conversion withdrew from the same pool

**Wait -- re-examining**: The `handleCommit()` comes from the DepositRedemptionVault flow, not the convert flow. Committed deposits are only created through `startRedemption()`. The receipt tokens that are committed in the redemption vault are held by the vault, not by the user. The user converting would be using DIFFERENT receipt tokens (not the ones committed to redemption).

So a user who has:
- 100 receipt tokens total
- Committed 50 to redemption (held by vault)
- Kept 50

Can only convert 50 (the ones they still hold). The committed 50 are in the vault's custody and are not available for the user to burn during conversion.

**Actually, there is still a concern**: The `getAvailableDeposits()` calculation uses TOTAL facility liabilities (all receipt tokens minted for this facility, regardless of who holds them). When the user converts 50 tokens, liabilities drop by 50, but committed deposits remain at 50. Available = (100 - 50 liabilities) - 50 committed = 0. This is correct.

But what if liabilities drop below committed? If more tokens are converted than expected, `committedDeposits + borrowedAmount > assetLiabilities` returns 0 for available deposits, which is the safe behavior.

**More subtle**: The ERC4626 vault shares are shared across all operators of the same asset. When the user converts, `_withdrawAsset` redeems shares. These shares reduce the facility's total share balance. If committed deposits were assuming those shares existed for the committed users, there's a problem.

However, the solvency check `_validateOperatorSolvency()` ensures `liabilities <= depositedSharesInAssets + borrowedAmount`. After conversion, liabilities decreased by the converted amount, AND shares decreased. The net effect depends on vault appreciation. If the vault has appreciated (sharesInAssets > liabilities), this is fine. If it hasn't, conversion actually helps solvency (reduces liabilities by more than shares drop).

### Verdict: NO VULNERABILITY -- but tight coupling

The accounting is correct under normal conditions. The system is safe because conversion burns receipt tokens 1:1 with the liability reduction, and the vault withdrawal reduces shares proportionally.

---

### FINDING H-2: handleBorrow Does Not Validate Zero Amount Before State Changes (Low)

**Location**: `BaseDepositFacility.handleBorrow()` (line 258-291)

```solidity
function handleBorrow(...) external nonReentrant onlyEnabled onlyAuthorizedOperator returns (uint256) {
    uint256 operatorCommitments = getCommittedDeposits(depositToken_, msg.sender);
    if (amount_ > operatorCommitments) revert ...;

    // Process the borrowing through DepositManager
    uint256 actualAmount = DEPOSIT_MANAGER.borrowingWithdraw(...);

    // Reduce committed deposits
    _assetOperatorCommittedDeposits[key] -= amount_;
    _assetCommittedDeposits[depositToken_] -= amount_;

    // Validate that the amount is not zero
    if (actualAmount == 0) revert DepositFacility_ZeroAmount();

    return actualAmount;
}
```

The committed deposits are reduced by `amount_` (the requested amount) BEFORE validating that `actualAmount != 0`. If `DEPOSIT_MANAGER.borrowingWithdraw()` returns 0 for actualAmount (e.g., due to ERC4626 rounding on tiny amounts), the function reverts, which rolls back the state changes. So this is safe due to the transaction-level atomicity.

However, the `DEPOSIT_MANAGER.borrowingWithdraw()` itself updates `_borrowedAmounts` using `params_.amount` (the requested amount, not the actual amount):

```solidity
_borrowedAmounts[key] += params_.amount;
```

And then the revert in `handleBorrow()` rolls this back too. So the flow is safe.

### Verdict: NO VULNERABILITY (reverts protect against inconsistency)

---

### FINDING H-3: Loan Repayment Asymmetry Between Requested and Actual Amounts (Low)

**Location**: `BaseDepositFacility.handleLoanRepay()` (line 304-334) and `DepositManager.borrowingRepay()` (line 719-752)

In `handleLoanRepay()`:
```solidity
uint256 repaymentActual = DEPOSIT_MANAGER.borrowingRepay(...);

uint256 committedAmountAdjustment = maxAmount_ < repaymentActual
    ? maxAmount_
    : repaymentActual;
_assetOperatorCommittedDeposits[key] += committedAmountAdjustment;
_assetCommittedDeposits[depositToken_] += committedAmountAdjustment;
```

In `borrowingRepay()`:
```solidity
(actualAmount, ) = _depositAsset(params_.asset, params_.payer, params_.amount, false);

_borrowedAmounts[borrowingKey] -= params_.maxAmount < actualAmount
    ? params_.maxAmount
    : actualAmount;
```

The committed deposits are increased by `min(maxAmount, repaymentActual)`, while borrowed amounts are decreased by `min(maxAmount, actualAmount)`. Since `repaymentActual` is the value returned from `borrowingRepay()` which IS `actualAmount` from `_depositAsset()`, these values match: `repaymentActual == actualAmount`.

So `committedAmountAdjustment = min(maxAmount, actualAmount)` and `borrowedReduction = min(maxAmount, actualAmount)`. These are equal.

This is consistent. The committed deposits go up by the same amount that borrowed amounts go down, maintaining the invariant.

### Verdict: NO VULNERABILITY

---

### FINDING H-4: ERC4626 Rounding Creates Persistent 1 Wei Dust in maxClaimYield (Informational)

**Location**: `DepositManager.maxClaimYield()` (line 228-239)

```solidity
function maxClaimYield(IERC20 asset_, address operator_) external view returns (uint256) {
    (, uint256 depositedSharesInAssets) = getOperatorAssets(asset_, operator_);
    uint256 operatorLiabilities = _assetLiabilities[assetLiabilitiesKey];
    uint256 borrowedAmount = _borrowedAmounts[assetLiabilitiesKey];

    if (depositedSharesInAssets + borrowedAmount < operatorLiabilities + 1) return 0;
    return depositedSharesInAssets + borrowedAmount - operatorLiabilities - 1;
}
```

The `- 1` adjustment accounts for rounding differences between `previewRedeem` and `previewWithdraw`. This permanently locks 1 wei of yield per operator per asset as uncollectable. This is negligible and intentional.

### Verdict: BY DESIGN (Informational)

---

### FINDING H-5: Conversion Price Rounding Direction Inconsistency (Informational)

**Location**: `ConvertibleDepositAuctioneer._bid()` line 306 vs `ConvertibleDepositFacility._previewConvert()` line 232

At auction time (rounding UP, favoring protocol):
```solidity
conversionPrice: depositIn.mulDivUp(_ohmScale, ohmOut)
```

At conversion time (rounding DOWN, favoring protocol):
```solidity
convertedTokenOut = FullMath.mulDiv(amount_, _OHM_SCALE, position.conversionPrice);
```

Both roundings favor the protocol. The conversion price is rounded up (user pays more per OHM), and the conversion output is rounded down (user gets less OHM). This is consistent and intentional, but creates a small systematic disadvantage for users. Over many conversions with small amounts, this could accumulate.

### Verdict: BY DESIGN (Informational) -- both roundings favor the protocol

---

### FINDING H-6: LimitOrders totalUsdsOwed Can Underflow in Edge Case (Informational)

**Location**: `CDAuctioneerLimitOrders.fillOrder()` line 412 and `cancelOrder()` line 472

In `fillOrder()`:
```solidity
totalUsdsOwed -= usdsNeeded;  // usdsNeeded = fillAmount_ + incentive
```

In `cancelOrder()`:
```solidity
totalUsdsOwed -= totalRemaining;
```

Both use standard subtraction which would revert on underflow (Solidity 0.8+). The `totalUsdsOwed` is increased in `createOrder()` by `actualDepositBudget + actualIncentiveBudget`, and decreased by fills and cancels.

The only way underflow could occur is if the sum of all fills and cancels exceeds the sum of all creates. Given that fills are capped to remaining deposits and incentives, and cancels use saturating subtraction for individual orders, this should not happen. The `fillAmount_` is capped to `remainingDeposit` in `_calculateFillAndIncentive()`.

However, there is a very subtle edge case: if `SUSDS.withdraw()` in `fillOrder()` returns more USDS than expected due to favorable rounding (extremely unlikely with standard ERC4626), the remaining USDS balance could be deposited back into sUSDS:

```solidity
uint256 remainingBalance = USDS.balanceOf(address(this));
if (remainingBalance > 0 && SUSDS.previewDeposit(remainingBalance) > 0)
    SUSDS.deposit(remainingBalance, address(this));
```

This excess is deposited back but NOT tracked in `totalUsdsOwed`, so it would accrue as yield. This is safe -- it doesn't cause underflow.

### Verdict: NO VULNERABILITY

---

## Summary of Findings

| ID | Severity | Title | Status |
|----|----------|-------|--------|
| A | Informational | Conversion price divergence from market price | By Design |
| B | None | Receipt token wrapping/unwrapping arbitrage | No Vulnerability |
| C | None | Position split creating extra conversion rights | No Vulnerability |
| D-1 | Informational | Self-default economic incentive misalignment | Design Acknowledged |
| E | None | Cross-operator deposit manipulation | No Vulnerability |
| F-1 | Low | Position redemption not cancelled on ownership change | Edge Case, Protected |
| G-1 | Informational | Sandwich attack on limit order fills | Standard MEV Risk |
| G-2 | Informational | sUSDS rate risk for limit order obligations | Known ERC4626 Risk |
| H-1 | None | Conversion not reducing committed deposits | No Vulnerability (correct) |
| H-2 | None | handleBorrow zero-amount state change | No Vulnerability (reverts) |
| H-3 | None | Loan repayment asymmetry | No Vulnerability (consistent) |
| H-4 | Informational | 1 wei dust in maxClaimYield | By Design |
| H-5 | Informational | Conversion price rounding double-favoring protocol | By Design |
| H-6 | None | totalUsdsOwed underflow risk | No Vulnerability |

---

## Conclusion

The Convertible Deposit pipeline is well-architected with strong security properties:

1. **Operator isolation is robust**: Per-operator accounting in DepositManager, BaseDepositFacility, and ReceiptTokenManager prevents cross-operator manipulation.

2. **Position split maintains invariants**: The DEPOS module correctly preserves total remainingDeposit during splits, and the split function inherits conversion price and expiry.

3. **Borrowing/default accounting is consistent**: The interplay between committed deposits, borrowed amounts, and liabilities is correctly maintained across all operations (commit, borrow, repay, default).

4. **Receipt token wrapping is safe**: The 1:1 wrapping/unwrapping with ERC6909 allowance-gated burns prevents double-spending.

5. **Solvency checks are comprehensive**: The `_validateOperatorSolvency()` check after withdrawals and the `getAvailableDeposits()` bound on commitments prevent over-extraction.

The primary risk area is governance configuration (auction parameters, borrow percentages, interest rates, keeper rewards) rather than code-level vulnerabilities. Misconfigurations could create economic arbitrage opportunities, but the code correctly implements the intended design.

No critical or high-severity vulnerabilities were identified in this second-pass review.
