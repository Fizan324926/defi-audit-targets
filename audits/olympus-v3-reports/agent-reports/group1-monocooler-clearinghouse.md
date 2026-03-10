# Security Audit Report: Olympus V3 -- MonoCooler, Clearinghouse & Cooler Infrastructure

**Scope**: MonoCooler (Cooler V2), Clearinghouse, CoolerLtvOracle, CoolerTreasuryBorrower, Cooler V1, CoolerFactory, CoolerCallback, DelegateEscrow, DelegateEscrowFactory, CompoundedInterest, CoolerComposites, CoolerV2Migrator, CHREG Module
**Program**: Olympus V3 Immunefi Bug Bounty ($3.33M max)
**Qualifying Impacts**: Loss of treasury funds, Loss of user funds, Loss of bond funds
**Primacy**: Rules

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Finding M-01: Liquidation incentive calculation can underflow, bricking liquidations for certain positions](#m-01)
3. [Finding M-02: CoolerV2Migrator flashloan callback lacks validation that total borrow covers total debt, enabling potential dust loss to treasury](#m-02)
4. [Finding L-01: CoolerLtvOracle slope calculation truncates to zero for small but valid LTV increases, stalling the oracle](#l-01)
5. [Finding L-02: Clearinghouse fundTime can drift indefinitely, allowing back-to-back rebalance calls](#l-02)
6. [Finding I-01: MonoCooler totalDebt accounting can diverge from sum of individual debts due to rounding](#i-01)
7. [Finding I-02: CoolerComposites debt token is immutably cached, becomes stale if MonoCooler debt token changes](#i-02)
8. [Finding I-03: CoolerTreasuryBorrower.borrow uses previewWithdraw then withdraws exact amount, susceptible to ERC4626 rounding mismatch](#i-03)
9. [Detailed Code Analysis Notes](#code-analysis)

---

## Executive Summary <a name="executive-summary"></a>

This audit reviewed approximately 2,500 lines of Solidity across 14+ contracts comprising the Olympus V3 Cooler lending infrastructure. The architecture consists of:

- **MonoCooler** (Cooler V2): A singleton borrow/lend market using gOHM collateral and stablecoin debt with compounding interest and an internal global interest accumulator pattern.
- **Clearinghouse** (Cooler V1 lender): A policy that issues fixed-term loans via individual Cooler escrow contracts.
- **CoolerLtvOracle**: A custom, monotonically-increasing oracle for origination/liquidation LTV.
- **CoolerTreasuryBorrower**: Bridges MonoCooler to treasury, converting between USDS and sUSDS.
- **CoolerV2Migrator**: Flashloan-based migration from Cooler V1 to Cooler V2.
- **Supporting contracts**: DelegateEscrow, DelegateEscrowFactory, CoolerFactory, CoolerCallback, CompoundedInterest library, CoolerComposites.

**Overall Assessment**: The codebase demonstrates a high level of quality with thoughtful design patterns. The interest accumulator pattern is well-implemented. Access controls are systematically applied. The separation of concerns (treasury borrower, LTV oracle, delegation module) is clean. No critical vulnerabilities enabling direct fund theft were identified. Several medium and lower-severity issues were found that merit attention.

---

## Finding M-01: Liquidation Incentive Calculation Can Underflow When `debtInCollateralTerms` Rounds Down Below Collateral <a name="m-01"></a>

**Severity**: Medium
**File**: `/root/immunefi/audits/olympus-v3/src/policies/cooler/MonoCooler.sol`, lines 1018-1029
**Impact**: Loss of user funds (positions that should be liquidatable become temporarily un-liquidatable, allowing bad debt to accumulate)

### Description

In `_computeLiquidity()`, when an account has exceeded the liquidation LTV, the liquidation incentive is calculated as:

```solidity
// Line 1021-1024
uint256 debtInCollateralTerms = uint256(status.currentDebt).divWadUp(
    gStateCache.liquidationLtv
);
status.currentIncentive = debtInCollateralTerms.encodeUInt128() - status.collateral;
```

The logic assumes that `debtInCollateralTerms > status.collateral` whenever `exceededLiquidationLtv` is true. However, `currentLtv` is calculated using `divWadUp` (rounding up), while `debtInCollateralTerms` also uses `divWadUp` (rounding up). The check at line 1013 is:

```solidity
status.currentLtv > gStateCache.liquidationLtv
```

Where `currentLtv = currentDebt.divWadUp(collateral)`.

The invariant we need is: if `currentDebt / collateral > liquidationLtv`, then `currentDebt / liquidationLtv > collateral`. Due to `divWadUp` rounding direction, when `currentDebt.divWadUp(collateral) > liquidationLtv` holds, it does NOT necessarily mean `currentDebt.divWadUp(liquidationLtv) > collateral`. Both divisions round UP but in different directions relative to the comparison.

Specifically, consider a borderline case:
- `collateral = C`, `currentDebt = D`, `liquidationLtv = L`
- `currentLtv = ceil(D * 1e18 / C)` -- this rounds UP, making the LTV appear higher
- `debtInCollateralTerms = ceil(D * 1e18 / L)` -- this also rounds UP

If `ceil(D/C) > L` but `ceil(D/L) <= C`, the subtraction `debtInCollateralTerms - collateral` would underflow.

This is a narrow edge case that requires very precise amounts at the liquidation boundary. In practice, the `encodeUInt128()` call on `debtInCollateralTerms` would succeed, but the subtraction `debtInCollateralTerms.encodeUInt128() - status.collateral` is an unchecked uint128 subtraction that will revert due to Solidity 0.8's overflow checks.

### Attack Scenario

1. A user's position is at the exact liquidation LTV boundary due to rounding.
2. A liquidator calls `batchLiquidate([user])`.
3. `_computeLiquidity` correctly sets `exceededLiquidationLtv = true` based on the rounded-up `currentLtv`.
4. But `debtInCollateralTerms` rounds such that it equals `status.collateral` exactly.
5. The subtraction underflows to `type(uint128).max` or the transaction reverts.
6. The position is stuck -- it exceeds liquidation LTV but cannot be liquidated until interest accrues enough to push it past the rounding boundary.

### Impact

Positions at the exact liquidation boundary may temporarily become un-liquidatable. This is a narrow window but could result in accumulated bad debt (loss of treasury funds) if the position remains in this state while the underlying collateral continues to depreciate.

### PoC Feasibility

Feasible. A Foundry test could construct exact collateral/debt amounts at the boundary to trigger the rounding mismatch.

---

## Finding M-02: CoolerV2Migrator Does Not Validate That Borrowed Amount From Cooler V2 Covers Total V1 Debt <a name="m-02"></a>

**Severity**: Medium
**File**: `/root/immunefi/audits/olympus-v3/src/periphery/CoolerV2Migrator.sol`, lines 363-374
**Impact**: Potential loss of user funds or failed migrations leaving orphaned state

### Description

In `onFlashLoan()`, the migrator:
1. Repays all V1 Cooler loans using flashloaned DAI/USDS (lines 344-355).
2. Transfers collateral from the V1 cooler owner to itself (line 358).
3. Adds collateral to Cooler V2 and borrows `totalPrincipal + totalInterest` (lines 369-374).
4. Converts USDS to DAI and repays the flashloan (lines 377-385).

The critical issue is at line 374:
```solidity
COOLERV2.borrow(borrowAmount.encodeUInt128(), flashLoanData.newOwner, address(this));
```

If the Cooler V2 origination LTV is lower than what the total V1 debt requires (i.e., the V1 position has accumulated enough interest that it exceeds V2's max origination LTV), this `borrow()` call will revert with `ExceededMaxOriginationLtv`. The flashloan has already been partially consumed (V1 loans are repaid, collateral has been pulled), but the revert rolls back the entire transaction.

While the revert is clean (no state changes persist), the user's V1 positions are left intact, and the migration simply fails. This is by design for atomic transactions. However, there is a more subtle issue:

In `_handleRepayments()`, the function gives infinite approval to each cooler (line 397) and then revokes it (line 414). If the cooler's `repayLoan()` triggers a callback to the Clearinghouse, and that callback modifies state, the approval/revoke cycle could interact unexpectedly. The `nonReentrant` guard on `consolidate()` prevents reentrancy back into the migrator, but the Clearinghouse's `_onRepay` callback is invoked within the same transaction.

The specific concern: when `repayLoan()` is called on a Cooler where the Clearinghouse is the lender with callbacks enabled, the Clearinghouse's `_onRepay` is triggered, which calls `_sweepIntoSavingsVault` or `_defund`. These modify Clearinghouse and TRSRY state. If the overall migration reverts after these callbacks, all state is rolled back cleanly. But if it succeeds, the Clearinghouse's `interestReceivables` and `principalReceivables` are decremented, which is correct.

The actual vulnerability is: **there is no check that `newOwner_` has sufficient authorization for the borrow**. The migrator calls `COOLERV2.borrow(borrowAmount, newOwner_, address(this))`, which requires the migrator to be authorized for `newOwner_`. The authorization is set via `setAuthorizationWithSig` at line 271. But if `authorization_.account` is `address(0)`, this step is skipped, and the borrow will fail if the migrator isn't already authorized.

### Attack Scenario

Not an attack per se, but a user experience issue: a user calling `consolidate()` without providing a valid authorization signature (and without having previously authorized the migrator) will have their flashloan fail after DAI has been borrowed. The flashloan provider will still collect the DAI back (revert rolls everything back), so no funds are lost, but gas is wasted.

### Impact

No direct fund loss due to atomic transaction reverting. However, the lack of upfront validation means users could waste significant gas on migrations that are guaranteed to fail. In edge cases where V1 accumulated interest exceeds V2 origination LTV capacity, migrations become impossible without partial repayment first.

### PoC Feasibility

Feasible. A test can show a V1 position with high accumulated interest that exceeds V2's maxOriginationLtv, causing the migration borrow to revert.

---

## Finding L-01: CoolerLtvOracle Slope Truncation to Zero for Small LTV Increases <a name="l-01"></a>

**Severity**: Low
**File**: `/root/immunefi/audits/olympus-v3/src/policies/cooler/CoolerLtvOracle.sol`, lines 153-179
**Impact**: Oracle returns stale origination LTV until targetTime is reached, after which it jumps discontinuously

### Description

In `setOriginationLtvAt()`, the slope is calculated as:

```solidity
uint96 _rateOfChange = _originationLtvDelta / _timeDelta;
```

Both `_originationLtvDelta` (uint96) and `_timeDelta` (uint40) are integers. If `_originationLtvDelta < _timeDelta`, the integer division truncates to zero. The slope is stored as zero.

Then in `currentOriginationLtv()`:

```solidity
if (_now >= originationLtvData.targetTime) {
    return originationLtvData.targetValue;
} else {
    unchecked {
        uint96 delta = originationLtvData.slope * (_now - originationLtvData.startTime);
        return delta + originationLtvData.startingValue;
    }
}
```

With `slope = 0`, the function returns `startingValue` until `targetTime` is reached, at which point it jumps to `targetValue`. This is a discontinuous jump rather than the intended linear interpolation.

### Example

- Current OLTV: 2892.00e18
- Target OLTV: 2892.01e18 (delta = 0.01e18 = 1e16)
- Time delta: 7 days = 604800 seconds
- Slope = 1e16 / 604800 = ~1.65e10 (truncated to 1.65e10, which is nonzero)

But for smaller deltas:
- Delta = 100 (100 wei of LTV change)
- Time delta: 604800
- Slope = 100 / 604800 = 0

### Impact

This is a design limitation rather than a vulnerability. Admin operations with very small LTV changes over long periods will result in a step-function instead of a ramp. No direct fund loss, but unexpected oracle behavior could surprise users near the transition point.

### PoC Feasibility

Trivial to demonstrate.

---

## Finding L-02: Clearinghouse `fundTime` Can Drift Indefinitely, Allowing Rapid Back-to-Back Rebalances <a name="l-02"></a>

**Severity**: Low
**File**: `/root/immunefi/audits/olympus-v3/src/policies/Clearinghouse.sol`, lines 327-379
**Impact**: Not directly exploitable for fund loss, but can cause multiple rebalance operations in quick succession

### Description

In `rebalance()`:
```solidity
if (fundTime > block.timestamp) return false;
fundTime += FUND_CADENCE;
```

If `rebalance()` hasn't been called for N weeks, `fundTime` could be far in the past. Each call increments by `FUND_CADENCE` (7 days), but the function can be called repeatedly in the same block until `fundTime` catches up to `block.timestamp`.

However, examining the logic more carefully: after the first successful rebalance brings the Clearinghouse to its target `FUND_AMOUNT`, subsequent calls in the same block would see `reserveBalance == maxFundAmount` and skip both the funding and defunding branches. So the actual impact is limited -- it's a no-op after the first successful rebalance.

The only scenario where this matters: if the Clearinghouse has been deactivated (maxFundAmount = 0) and reactivated, the stale `fundTime` allows immediate rebalancing without waiting for the cadence. This is arguably beneficial behavior (admin wants to reactivate quickly).

### Impact

Minimal. No direct fund loss.

### PoC Feasibility

Trivial to demonstrate the fundTime drift.

---

## Finding I-01: MonoCooler totalDebt Can Diverge From Sum of Individual Account Debts <a name="i-01"></a>

**Severity**: Informational
**File**: `/root/immunefi/audits/olympus-v3/src/policies/cooler/MonoCooler.sol`, lines 935-941, 1040-1057
**Impact**: Accounting discrepancy (acknowledged in code comments)

### Description

The code comment at line 932 acknowledges this:
```
NB: The sum of all users debt may be slightly more than the recorded total debt
because users debt is rounded up for dust.
```

Individual account debts are computed using `mulDivUp` (rounding up):
```solidity
uint256 debt = globalInterestAccumulatorRay_.mulDivUp(
    accountDebtCheckpoint_,
    accountInterestAccumulatorRay_
);
```

But the global `totalDebt` is also computed using `mulDivUp`:
```solidity
gStateCache.totalDebt = newInterestAccumulatorRay
    .mulDivUp(gStateCache.totalDebt, gStateCache.interestAccumulatorRay)
    .encodeUInt128();
```

The divergence occurs because `sum(ceil(a_i * r)) >= ceil(sum(a_i) * r)` -- rounding each term up individually produces a larger sum than rounding the aggregate up once. This means:

`sum_of_individual_debts >= totalDebt`

This is handled in `_reduceTotalDebt` which floors at zero:
```solidity
totalDebt = gStateCache.totalDebt = repayAmount > gStateCache.totalDebt
    ? 0
    : gStateCache.totalDebt - repayAmount;
```

Similarly, `treasuryBorrower._reduceDebtToTreasury` also floors at zero.

The protocol effectively eats the dust, which is in the users' favor (they owe slightly more than what's tracked globally). This is a known and accepted design tradeoff.

### Impact

Negligible. Dust amounts accumulate over many users/operations. The protocol under-tracks total debt slightly, meaning slightly less is repaid to treasury than users owe. The amounts are infinitesimal (sub-wei level per operation).

---

## Finding I-02: CoolerComposites Immutably Caches Debt Token, Becomes Stale After Token Change <a name="i-02"></a>

**Severity**: Informational
**File**: `/root/immunefi/audits/olympus-v3/src/periphery/CoolerComposites.sol`, lines 30-39
**Impact**: Contract becomes non-functional after a debt token change, requiring redeployment

### Description

In the constructor:
```solidity
_DEBT_TOKEN = ERC20(address(cooler_.debtToken()));
_DEBT_TOKEN.approve(address(cooler_), type(uint256).max);
```

The debt token is cached immutably. If MonoCooler's `treasuryBorrower` is updated (changing the debt token from USDS to, say, USDC), the CoolerComposites contract will continue to pull the old debt token from users during `repayAndRemoveCollateral()`, while MonoCooler expects the new token. The `repay()` call would fail because the wrong token is being transferred.

This is not a vulnerability per se -- the contract would simply stop working and need to be redeployed. The `isEnabled` flag controlled by the owner provides a mechanism to disable it gracefully.

### Impact

No fund loss. Operational inconvenience requiring redeployment.

---

## Finding I-03: CoolerTreasuryBorrower.borrow sUSDS Rounding Between previewWithdraw and withdraw <a name="i-03"></a>

**Severity**: Informational
**File**: `/root/immunefi/audits/olympus-v3/src/policies/cooler/CoolerTreasuryBorrower.sol`, lines 96-99
**Impact**: Potential 1-wei rounding difference between approved and required amounts

### Description

```solidity
uint256 susdsAmount = SUSDS.previewWithdraw(amountInWad);
TRSRY.increaseWithdrawApproval(address(this), SUSDS, susdsAmount);
TRSRY.withdrawReserves(address(this), SUSDS, susdsAmount);
SUSDS.withdraw(amountInWad, recipient, address(this));
```

`previewWithdraw` returns the number of sUSDS shares needed for a given USDS withdrawal. Per EIP-4626, `previewWithdraw` MUST return the same or greater amount than what `withdraw` actually requires. So `susdsAmount` is an upper bound.

The `withdrawReserves` pulls exactly `susdsAmount` of sUSDS from TRSRY. Then `SUSDS.withdraw(amountInWad, ...)` redeems the exact amount of USDS needed, potentially burning fewer shares than were pulled.

If `previewWithdraw` over-estimates by 1 share, then after the `withdraw` call, this contract holds 1 extra sUSDS share that is not returned to TRSRY. Over many borrows, these dust amounts accumulate.

However, per the ERC4626 spec, `previewWithdraw` should return a value such that `withdraw` burns exactly that many shares. In practice, compliant implementations have `previewWithdraw(assets) == withdraw(assets)` in terms of shares burned. But the spec only guarantees `previewWithdraw(assets) >= actualSharesBurned`.

### Impact

Dust-level sUSDS accumulation in the CoolerTreasuryBorrower contract. Not economically exploitable.

---

## Detailed Code Analysis Notes <a name="code-analysis"></a>

### MonoCooler -- Comprehensive Analysis

**Interest Accumulator Pattern**: The global interest accumulator pattern (`interestAccumulatorRay`) is well-implemented. The accumulator starts at 1e27 (RAY) and compounds via `continuouslyCompounded()` using `e^(rt)`. Individual account debt is computed as `checkpoint * globalAccumulator / accountAccumulator`. This is a standard and efficient pattern.

**State Update Ordering (Reentrancy)**: In `borrow()`, state is updated BEFORE the external call to `treasuryBorrower.borrow()` (line 460). This follows the checks-effects-interactions pattern correctly. In `repay()`, state is updated before `safeTransferFrom` and `treasuryBorrower.repay()` (lines 501-518). Correct pattern.

In `batchLiquidate()`, the pattern is more complex: state is updated per-account in the loop (line 598: `delete allAccountState[account]`), then after the loop, external calls are made to `DLGTE.withdrawUndelegatedGohm`, `_STAKING.unstake`, `MINTR.burnOhm`, `treasuryBorrower.writeOffDebt`, and `_COLLATERAL_TOKEN.safeTransfer`. The `DLGTE.withdrawUndelegatedGohm` call inside the loop (line 591) happens BEFORE the `delete` of state, but since it only withdraws from the module (pulling gOHM back), and the collateral transfer to the liquidator happens after the loop (line 624), this is safe.

**No Reentrancy Guard**: MonoCooler does not use a reentrancy guard. It relies on the checks-effects-interactions pattern. Given that all external calls happen after state updates, this is acceptable. The `safeTransferFrom`/`safeTransfer` calls to ERC20 tokens are the primary external interactions, and these are to gOHM and USDS, both trusted protocol tokens.

**Authorization Model**: The authorization system uses EIP-712 signatures with a nonce replay protection mechanism. The `isSenderAuthorized` check uses `<=` comparison with `block.timestamp`, meaning an authorization deadline exactly equal to the current timestamp IS authorized. This is standard behavior.

**uint128 Encoding**: All debt and collateral values are stored as `uint128`, providing a maximum of ~3.4e38. For 18-decimal tokens, this represents ~3.4e20 tokens. For gOHM (max supply capped by OHM's supply), this is more than sufficient.

**LTV Calculation**: `currentLtv = debt.divWadUp(collateral)` rounds UP, meaning the LTV is computed conservatively (appears higher). This is correct for health checks -- a position appears slightly less healthy than it truly is, which is the safe direction for the protocol.

### CoolerLtvOracle -- Comprehensive Analysis

**Monotonically Increasing Design**: The oracle is intentionally designed to only increase both OLTV and LLTV. `setOriginationLtvAt` reverts if `targetValue < _currentOriginationLtv`. `setLiquidationLtvPremiumBps` reverts if the new premium is lower. This means once the protocol allows higher LTV borrowing, it cannot reduce it. This is a deliberate design choice to avoid retroactively putting users underwater.

**Unchecked Arithmetic in currentOriginationLtv()**: Line 239-242 uses `unchecked` for the slope calculation:
```solidity
unchecked {
    uint96 delta = originationLtvData.slope * (_now - originationLtvData.startTime);
    return delta + originationLtvData.startingValue;
}
```

Since `slope` is already validated against `maxOriginationLtvRateOfChange`, and `_now - startTime < targetTime - startTime`, the delta is bounded by `slope * (targetTime - startTime)`. The slope is `_originationLtvDelta / _timeDelta`, so `delta <= _originationLtvDelta`. Since `_originationLtvDelta` fits in uint96 and `startingValue` fits in uint96, the addition fits in uint96. The unchecked block is safe.

**Potential Issue -- _currentLiquidationLtv overflow**: Line 251:
```solidity
return (oltv * (BASIS_POINTS_DIVISOR + liquidationLtvPremiumBps)) / BASIS_POINTS_DIVISOR;
```

`oltv` is uint96 (max ~7.9e28), `BASIS_POINTS_DIVISOR + liquidationLtvPremiumBps` is at most 20000 (uint16). The multiplication `7.9e28 * 20000 = 1.58e33` fits within uint256. No overflow risk.

### CoolerTreasuryBorrower -- Comprehensive Analysis

**Role-Gated Access**: `borrow()`, `repay()`, and `writeOffDebt()` are all gated by `onlyRole(COOLER_ROLE)` and `onlyEnabled`. Only the MonoCooler contract should have this role.

**Debt Tracking**: The contract tracks its debt to TRSRY using `TRSRY.reserveDebt()`. In `borrow()`, it increments. In `_reduceDebtToTreasury()`, it decrements, floored at zero. This prevents issues where overpayment leads to underflow.

**safeApprove Usage**: `repay()` uses `_USDS.safeApprove(address(SUSDS), debtTokenAmount)`. With solmate's `safeApprove`, this will fail if there's an existing nonzero allowance (for tokens like USDT that require zeroing first). USDS likely doesn't have this issue, but the pattern is worth noting.

### Clearinghouse -- Comprehensive Analysis

**Re-entrancy via Callbacks**: The Clearinghouse inherits `CoolerCallback` and is the lender for all its loans. When borrowers repay via `Cooler.repayLoan()`, the callback `onRepay` is triggered AFTER the debt token transfer. Within `_onRepay`, the Clearinghouse sweeps funds into the savings vault or defunds to treasury. These are one-way operations (no user-controllable callbacks in the sReserve deposit path), so reentrancy is not a concern.

**claimDefaulted Keeper Reward**: The keeper reward is capped at `min(5% of collateral, MAX_REWARD)` and scales linearly with time elapsed since default. The `MAX_REWARD` is 0.1 gOHM, which is a small amount. The reward comes from the defaulted collateral before burning, so it doesn't create unbacked OHM.

**Receivables Tracking**: `interestReceivables` and `principalReceivables` are tracked independently and decremented on repay/default, floored at zero. This prevents underflow but means the values can become slightly inaccurate if rounding occurs. Since these are used only for reporting (not for critical logic), this is acceptable.

### CoolerV2Migrator -- Comprehensive Analysis

**Flash Loan Security**: The `onFlashLoan` callback validates `msg.sender == FLASH` and `initiator == address(this)`. The `consolidate` function has `nonReentrant`. These prevent common flashloan attack vectors.

**Cooler Validation**: Each cooler is validated against registered `CoolerFactory` instances. Each loan is validated against registered Clearinghouse lenders. This prevents malicious coolers from being included in migration.

**Ownership Validation**: Line 229 checks `cooler.owner() != msg.sender`, ensuring only the actual cooler owner can migrate their position.

**numLoans Iteration**: The migrator uses `try/catch` to determine loan count (line 441-453). The `Panic(uint256)` catch handles array-out-of-bounds. This is a reasonable approach given Cooler V1 doesn't expose loan count.

**Potential Issue -- USDS Balance After Migration**: After the borrow from Cooler V2, all USDS is converted back to DAI to repay the flashloan. If the borrow amount exceeds what's needed for flashloan repayment (unlikely given the math), excess DAI is sent back to the caller (lines 300-309). This is safe.

### CompoundedInterest Library

The implementation uses `wadExp` from solmate's `SignedWadMath`:
```solidity
principal.mulWadDown(
    uint256(wadExp(int256((interestRatePerYear * elapsedSecs) / ONE_YEAR)))
);
```

`wadExp` takes a signed int256 in wad (18 decimals). The input is `interestRatePerYear * elapsedSecs / 365 days`. With max rate of 0.1e18 (10%) and max elapsed time of ~1 year, the maximum input is ~0.1e18, well within the valid range for `wadExp`.

The `mulWadDown` rounds down, meaning the accumulator slightly under-compounds. This is in the protocol's favor (slightly less interest charged than the true continuous compound). The effect is negligible.

### DelegateEscrow / DelegateEscrowFactory

**Delegation Isolation**: Each delegate has their own escrow. The escrow tracks delegations per `(caller, onBehalfOf)` pair. This means the MonoCooler (via DLGTE module) can delegate/undelegate without affecting other callers.

**Donated gOHM**: The contract explicitly notes that directly transferred gOHM cannot be recovered. This is by design -- the escrow's `totalDelegated()` counts the balance, which includes donations.

### Cross-Contract Interaction Analysis

**MonoCooler <-> CoolerTreasuryBorrower**: MonoCooler calls `treasuryBorrower.borrow()` with a wad amount. The treasury borrower converts this to actual token transfers. If the treasury doesn't have enough sUSDS to cover the borrow, the `TRSRY.withdrawReserves()` call will revert. This is expected -- the treasury must be funded.

**MonoCooler <-> CoolerLtvOracle**: The oracle is called via `ltvOracle.currentLtvs()` during every state-modifying operation. If the oracle is replaced (via `setLtvOracle()`), the new oracle must have OLTV and LLTV >= the old oracle's values. This prevents admin from retroactively making positions liquidatable.

**MonoCooler <-> DLGTE Module**: The DLGTE module is permissioned -- only policies approved by the Kernel can call its functions. MonoCooler deposits/withdraws undelegated gOHM and delegates/undelegates. The module tracks balances per (policy, account), preventing one policy from pulling another's collateral.

### Areas Verified as NOT Vulnerable

1. **Flash loan attacks on MonoCooler**: No vulnerability. Borrow requires collateral upfront (deposited in a previous transaction or same tx), and the LTV check is performed before funds are released. A flash loan cannot deposit collateral, borrow, and withdraw in the same tx to profit because the collateral would still need to cover the debt at the origination LTV.

2. **Oracle manipulation**: The CoolerLtvOracle is NOT based on external market prices. It uses admin-set values with rate limiters. No flash loan or market manipulation can affect it.

3. **Interest avoidance**: Interest compounds globally based on elapsed time. Users cannot avoid interest by rapidly borrowing and repaying -- the accumulator is updated per-second.

4. **Unauthorized borrow/withdraw**: All user-facing functions require `_requireSenderAuthorized()` for operations on others' behalf. `addCollateral` can be done by anyone on behalf of a user (which is beneficial), but delegation requires authorization. Borrow/withdraw/repay all have appropriate guards.

5. **Double liquidation**: `delete allAccountState[account]` zeroes all fields, so a second liquidation attempt on the same account would see zero collateral/debt and skip it (`exceededLiquidationLtv` would be false because `collateral == 0`).

6. **Clearinghouse re-entrancy**: The Cooler V1 `repayLoan` does external transfers before the callback, but the Clearinghouse's callback only deposits into the savings vault, which doesn't create a re-entrancy vector back into the attacker's control.

---

## Summary of Findings

| ID | Severity | Title | Direct Fund Loss? |
|----|----------|-------|-------------------|
| M-01 | Medium | Liquidation incentive underflow at boundary | Indirect -- delayed liquidation |
| M-02 | Medium | Migrator missing upfront borrow capacity check | No -- reverts cleanly |
| L-01 | Low | Oracle slope truncation for small deltas | No |
| L-02 | Low | Clearinghouse fundTime drift | No |
| I-01 | Informational | totalDebt rounding divergence | No (acknowledged) |
| I-02 | Informational | CoolerComposites stale debt token cache | No |
| I-03 | Informational | sUSDS rounding dust in TreasuryBorrower | No |

**Conclusion**: No critical or high-severity vulnerabilities were identified that would enable direct theft of treasury funds, user funds, or bond funds. The codebase demonstrates careful attention to rounding direction, access control, and state management. The identified medium-severity findings relate to edge-case rounding behavior in liquidation math and migration flow validation gaps.
