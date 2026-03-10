# Olympus V3 Audit Report: Group 6 -- Governance, Tokens, Libraries, LoanConsolidator, ReserveMigrator, Remaining Policies

## Scope

- `src/external/governance/GovernorBravoDelegate.sol`
- `src/external/governance/GovernorBravoDelegator.sol`
- `src/external/governance/Timelock.sol`
- `src/external/governance/abstracts/GovernorBravoStorage.sol`
- `src/external/OlympusERC20.sol`
- `src/external/OlympusAuthority.sol`
- `src/external/ClaimTransfer.sol`
- `src/policies/pOLY.sol`
- `src/policies/LoanConsolidator.sol`
- `src/policies/ReserveMigrator.sol`
- `src/policies/ReserveWrapper.sol`
- `src/policies/PriceConfig.sol`
- `src/libraries/FullMath.sol`
- `src/libraries/TransferHelper.sol`
- `src/libraries/SafeCast.sol`
- `src/libraries/Timestamp.sol`
- `src/libraries/TimestampLinkedList.sol`
- `src/libraries/DecimalString.sol`
- `src/libraries/ERC6909Wrappable.sol`
- `src/libraries/AddressStorageArray.sol`
- `src/libraries/String.sol`
- `src/libraries/Uint2Str.sol`
- All proposal files in `src/proposals/`

---

## Executive Summary

After a thorough line-by-line review of every file in scope, I identified several findings of varying severity. Most of the contracts in scope are either well-established (fork of Compound's GovernorBravo), utility libraries with limited attack surface, or policies with adequate access control. The most interesting attack surfaces are in the ClaimTransfer contract (fractionalized pOLY claims), the LoanConsolidator flashloan logic, and edge cases in the governance system. No critical vulnerabilities with direct, unconditional fund-loss paths were found in the current deployed state, but several medium-to-low severity issues warrant attention.

---

## Findings

---

### Finding 1: ClaimTransfer `_transfer` Division-by-Zero When `percent` is Zero

**Severity**: Medium

**File**: `src/external/ClaimTransfer.sol`, lines 153-170

**Description**:

The `_transfer` function computes `gClaimedToTransfer` and `maxToTransfer` by dividing by `terms.percent`:

```solidity
uint256 gClaimedToTransfer = (amount_ * terms.gClaimed) / terms.percent;
uint256 maxToTransfer = (amount_ * terms.max) / terms.percent;
```

If a user calls `fractionalizeClaim()` when their pOLY term has `percent == 0`, the `fractionalizedTerms[msg.sender]` will be stored with `percent = 0`. Subsequently, any call to `transfer()` or `transferFrom()` for this user (even from an approved spender) will revert with a division-by-zero panic. This is not directly exploitable for fund theft but does cause a permanent DoS for the user's claim position: once fractionalized with percent=0, the user can never transfer or interact meaningfully with their fractionalized claim.

More critically, if a user's `percent` is non-zero and they transfer amounts such that `fractionalizedTerms[from_].percent` becomes zero, any subsequent call to `transfer()` or `transferFrom()` on that user's remaining terms will also revert -- trapping the gClaimed and max values permanently in the mapping. This is a griefing vector: if a user transfers their entire `percent` to another address, the residual `gClaimed` and `max` values (if non-zero due to rounding) are permanently locked.

**Attack Scenario**:

1. User A calls `fractionalizeClaim()` and has `percent = 10000`, `gClaimed = 100`, `max = 500`.
2. User A transfers `amount_ = 10000` (their full percent) to User B.
3. `fractionalizedTerms[A].percent` becomes 0.
4. If any rounding dust remains in `gClaimed` or `max`, those values are stuck. Not directly exploitable for theft, but constitutes a permanent DoS and locked accounting state.

**Impact**: Griefing / permanent locking of dust amounts in accounting. Not directly a loss of treasury or user funds in the monetary sense, but locked accounting entries.

**PoC Feasibility**: Straightforward -- just call `transfer` with the user's full `percent` amount.

---

### Finding 2: ClaimTransfer `_transfer` Rounding Error Allows Inflation of Recipient's Max Claim

**Severity**: Medium

**File**: `src/external/ClaimTransfer.sol`, lines 153-170

**Description**:

In the `_transfer` function:

```solidity
uint256 gClaimedToTransfer = (amount_ * terms.gClaimed) / terms.percent;
uint256 maxToTransfer = (amount_ * terms.max) / terms.percent;
uint256 maxAdjustment = gOHM.balanceFrom(gClaimedToTransfer);
maxToTransfer += maxAdjustment;
```

The logic adds `maxAdjustment` (the OHM equivalent of the gClaimed being transferred) to `maxToTransfer`. The intent is that the recipient gets a proportional share of `max` plus enough extra max to account for what has already been claimed. However, this `maxAdjustment` is added to the recipient's `max` AND subtracted from the sender's `max`.

The issue is that `maxToTransfer` now exceeds the proportional fraction of `max`. The sender loses `maxToTransfer` from their `max`, while the recipient gains the same. Over multiple rounds of splitting and merging claims, the total `max` across all holders can gradually inflate or deflate due to integer rounding in the division `(amount_ * terms.max) / terms.percent` and the non-linear relationship between `gClaimed` and OHM through the `balanceFrom` conversion.

If a user carefully engineers a sequence of fractional transfers, they can potentially inflate their total effective max claimable OHM slightly above what was originally allocated.

**Attack Scenario**:

1. User A has terms: percent=10000, gClaimed=X, max=M.
2. User A transfers a small fraction to User B. Due to rounding, User B receives slightly more max than the proportional share.
3. User B transfers back to User A. Again rounding may favor inflation.
4. Repeated transfers accumulate rounding benefits.

**Impact**: Potential over-claiming of OHM beyond original allocation. However, the pOLY contract's `redeemableFor` function provides an additional cap based on circulating supply, and `validateClaim` checks both `redeemable` and `max - claimed`. The magnitude of exploitation is bounded by rounding dust per operation, making large-scale theft impractical but theoretically possible with many iterations.

**PoC Feasibility**: Requires many transactions; the gain per iteration is tiny (sub-wei for reasonable values). Economically impractical given gas costs but mathematically valid.

---

### Finding 3: LoanConsolidator Uses Unsafe `transfer`/`transferFrom` for IERC20

**Severity**: Low

**File**: `src/policies/LoanConsolidator.sol`, lines 375-376, 391-398, 461-464, 482-486, 507

**Description**:

The LoanConsolidator contract uses `IERC20.transfer()` and `IERC20.transferFrom()` directly (from forge-std's IERC20 interface) rather than using safe transfer wrappers. For example:

```solidity
reserveTo.transferFrom(msg.sender, address(this), ...);  // line 375
DAI.transfer(msg.sender, daiBalanceAfter);                // line 393
USDS.transfer(msg.sender, usdsBalanceAfter);              // line 397
GOHM.transferFrom(flashLoanData.coolerFrom.owner(), ...); // line 461
```

While DAI, USDS, and gOHM are known to return `bool` correctly, the return values are not checked. If a transfer fails silently (returning `false` without reverting), the contract would proceed with incorrect balances.

In practice, DAI, USDS, and gOHM all revert on failure rather than returning false, so this is not exploitable with the current token implementations. However, if the contract were ever used with a non-reverting token (or if the RGSTY registry pointed to a malicious/broken token), this could lead to fund loss.

**Impact**: Low -- current tokens revert on failure. The risk is in future token changes.

**PoC Feasibility**: Not feasible with current mainnet DAI/USDS/gOHM. Would require a non-standard token.

---

### Finding 4: Timelock GRACE_PERIOD is Only 1 Day -- Tight Execution Window

**Severity**: Informational

**File**: `src/external/governance/Timelock.sol`, line 58

**Description**:

The Timelock's `GRACE_PERIOD` is set to `1 days`:

```solidity
uint256 public constant GRACE_PERIOD = 1 days;
```

This means that after a proposal's eta is reached, there is only a 1-day window to execute it before it expires. Combined with the `MINIMUM_DELAY` of 1 day, this gives proposers a very tight 24-hour execution window. If a proposal is queued and the execution is delayed by even 1 day beyond eta (due to gas issues, coordinating multisig, etc.), the proposal expires and must be re-submitted.

This is by design but notable. Compound's standard Timelock uses a 14-day grace period.

**Impact**: Operational risk. Not a vulnerability per se, but can lead to failed governance actions.

**PoC Feasibility**: N/A -- operational concern.

---

### Finding 5: GovernorBravo Emergency Proposal Can Be Queued and Executed Without Votes

**Severity**: Low (by design, but worth noting)

**File**: `src/external/governance/GovernorBravoDelegate.sol`, lines 220-281, 316-362, 385-429

**Description**:

Emergency proposals bypass the normal voting process entirely. The `emergencyPropose` function creates a proposal with `startBlock = 0` and no voting period. The `queue` and `execute` functions for emergency proposals only check that `msg.sender == vetoGuardian` and the state is `Emergency`.

This means:
1. The vetoGuardian can propose, queue, and execute arbitrary actions through the Timelock without any token holder vote.
2. The only constraint is the Timelock delay (minimum 1 day).
3. Emergency mode is triggered when `gohm.totalSupply() < MIN_GOHM_SUPPLY` (1000 gOHM).

The risk here is that if gOHM supply drops below 1000e18 (which could happen through mass unstaking), the vetoGuardian gains unilateral execution power. This is the documented design for emergency scenarios, but worth flagging.

**Impact**: Centralization risk in emergency mode. Out of scope per program rules, but noted for completeness.

**PoC Feasibility**: Requires gOHM supply to drop below 1000e18 AND vetoGuardian cooperation.

---

### Finding 6: GovernorBravo `state()` Returns `Pending` for Proposal ID 0

**Severity**: Low

**File**: `src/external/governance/GovernorBravoDelegate.sol`, lines 959-1007

**Description**:

The `state()` function checks `if (proposalCount < proposalId) revert`, but does not check that `proposalId != 0`. When `proposalId == 0`, it accesses `proposals[0]` which is an uninitialized proposal. Since all fields default to zero:

- `startBlock == 0` and `proposer == address(0)` -- so the emergency check fails (proposer is address(0)).
- `vetoed`, `canceled` are false.
- `block.number > proposal.startBlock + activationGracePeriod` is likely true if `activationGracePeriod` is small enough.

The function would either return `Expired` or `Pending` depending on `activationGracePeriod` and the current block number. This is not exploitable since proposal 0 cannot be voted on, queued, or executed (the proposer check and other guards will fail), but returning a valid state for a non-existent proposal is misleading.

**Impact**: Informational -- no fund risk. Affects off-chain tooling that might incorrectly interpret proposal 0 as a real proposal.

**PoC Feasibility**: Trivially call `state(0)`.

---

### Finding 7: OlympusAuthority `pushGovernor` with `_effectiveImmediately = true` Can Lock Out Governance

**Severity**: Low (centralization risk -- out of scope)

**File**: `src/external/OlympusAuthority.sol`, lines 120-124

**Description**:

When `pushGovernor` is called with `_effectiveImmediately = true`, the `governor` role is changed immediately without requiring the new governor to pull:

```solidity
function pushGovernor(address _newGovernor, bool _effectiveImmediately) external onlyGovernor {
    if (_effectiveImmediately) governor = _newGovernor;
    newGovernor = _newGovernor;
    emit GovernorPushed(governor, newGovernor, _effectiveImmediately);
}
```

If the governor pushes to an incorrect address (e.g., address(0) or a contract that cannot call `pullGovernor`), governance over the OHM token's authority is permanently lost. The same applies to vault, guardian, and policy roles. This is a known pattern (push/pull) but the "effective immediately" bypass weakens it.

**Impact**: Centralization/admin error risk. Out of scope per program rules.

---

### Finding 8: pOLY `claim` Allows Any Address to Claim on Behalf of msg.sender

**Severity**: Low

**File**: `src/policies/pOLY.sol`, lines 106-115

**Description**:

The `claim` function:

```solidity
function claim(address to_, uint256 amount_) external {
    uint256 ohmAmount = _claim(amount_);
    MINTR.increaseMintApproval(address(this), ohmAmount);
    MINTR.mintOhm(to_, ohmAmount);
    emit Claim(msg.sender, to_, amount_);
}
```

The `_claim` function (line 264) reads terms from `terms[msg.sender]`, pulls DAI from `msg.sender`, and updates `terms[msg.sender].gClaimed`. The minted OHM is sent to `to_`. This means:

1. Anyone can call `claim` with their own terms but direct minted OHM to any address `to_`.
2. The DAI is still pulled from `msg.sender`.
3. The `msg.sender`'s terms are updated.

This is the intended design -- the `to_` parameter allows the caller to direct their own claim to a different wallet. There is no way to claim using someone else's terms. No vulnerability here.

**Impact**: None -- working as designed.

---

### Finding 9: ReserveMigrator Does Not Check Migration Output Amount Precisely

**Severity**: Low

**File**: `src/policies/ReserveMigrator.sol`, lines 118-131

**Description**:

The migration logic:

```solidity
uint256 toBalance = to.balanceOf(address(this));
migrator.daiToUsds(address(this), fromBalance);
uint256 newToBalance = to.balanceOf(address(this));
if (newToBalance < toBalance + fromBalance) revert ReserveMigrator_BadMigration();
```

The check `newToBalance < toBalance + fromBalance` assumes a 1:1 exchange rate between DAI and USDS. If the Maker migrator ever introduces a fee or changes the exchange rate, the check would simply need `newToBalance >= toBalance + fromBalance`. Currently, the DAI/USDS migration is 1:1 by design in the Maker contracts, so this is a valid assumption. However, if `daiToUsds` somehow returns more than 1:1 (a surplus), the extra tokens would be deposited into the TRSRY -- which is actually fine.

The concern is: if a malicious or upgraded `migrator` contract returns less than 1:1, the revert check catches it. If it returns more (e.g., due to a vulnerability in the migrator), the extra goes to TRSRY which is the desired behavior anyway.

**Impact**: Informational. The check is adequate for the current Maker DAI/USDS migration.

---

### Finding 10: LoanConsolidator `consolidateWithNewOwner` Allows Consolidation to Any Cooler

**Severity**: Medium

**File**: `src/policies/LoanConsolidator.sol`, lines 297-318, 460-486

**Description**:

The `consolidateWithNewOwner` function allows the owner of `coolerFrom_` to consolidate their loans into a `coolerTo_` that belongs to a different owner. The flow:

1. The caller (owner of coolerFrom) repays all loans, collateral returns to coolerFrom owner.
2. The contract takes collateral from coolerFrom owner via `GOHM.transferFrom(flashLoanData.coolerFrom.owner(), ...)`.
3. A new loan is created on `coolerTo_` with the `coolerTo_` owner receiving the principal.
4. The contract then calls `flashLoanData.reserveTo.transferFrom(flashLoanData.coolerTo.owner(), ...)` to pull back the principal from the coolerTo owner.

This requires:
- The coolerFrom owner to have approved GOHM to this contract.
- The coolerTo owner to have approved reserveTo to this contract.

The critical observation is that at step (3), the new loan is taken on `coolerTo_`'s behalf. The coolerTo owner receives the loan proceeds and the contract pulls them back at step (4). If the coolerTo owner has set approval, this works. But the coolerTo owner must explicitly approve the contract, meaning they consent to this operation.

There is no griefing vector because the coolerTo owner must set approvals. However, this creates an interesting attack surface: if the coolerTo owner has granted a blanket approval for this contract (e.g., type(uint256).max), any coolerFrom owner can consolidate loans into coolerTo's Cooler, effectively creating debt for coolerTo (the new loan is on coolerTo). The coolerTo owner receives back the same principal they lent, so they are net-neutral on reserves, but they now have a Cooler loan with gOHM collateral that belongs to the coolerFrom owner.

Effectively, this moves collateral and debt to a different user -- but both parties must consent via approvals. The design seems intentional for cases where loan ownership needs to be transferred.

**Impact**: Low -- requires explicit approval from the coolerTo owner. No fund loss possible without consent.

**PoC Feasibility**: Requires coolerTo owner to have approved the LoanConsolidator for both gOHM and reserveTo.

---

### Finding 11: ERC6909Wrappable `_burn` with `wrapped_ = true` Burns From onBehalfOf But Allowance Check Uses ERC6909 Allowance

**Severity**: Low

**File**: `src/libraries/ERC6909Wrappable.sol`, lines 110-133

**Description**:

The `_burn` function checks `_spendAllowance(onBehalfOf_, msg.sender, tokenId_, amount_)` when the caller is not the owner. This spends the ERC6909 allowance. However, when `wrapped_ = true`, it burns the ERC20 wrapped token via `_getWrappedToken(tokenId_).burnFrom(onBehalfOf_, amount_)`.

The ERC20 `burnFrom` typically checks the ERC20's own allowance system. But the ERC6909Wrappable contract already spends the ERC6909 allowance before calling `burnFrom`. This means:
1. The ERC6909 allowance is decreased.
2. The ERC20 `burnFrom` will also check its own allowance.

This results in a double-allowance requirement: the caller needs both an ERC6909 allowance AND an ERC20 allowance to burn wrapped tokens on behalf of another user. This is documented in the code comment on line 121: "Spend allowance (since it is not implemented in `ERC6909._burn()` or `CloneableReceiptToken.burnFrom()`)".

The behavior depends on the CloneableReceiptToken implementation -- if `burnFrom` does NOT check its own allowance (as the comment suggests), then only the ERC6909 allowance matters, which is the correct behavior.

**Impact**: Informational -- depends on the CloneableReceiptToken implementation. If implemented correctly, no issue.

---

### Finding 12: GovernorBravo Proposal Cancellation Allows Anyone to Cancel When Proposer Falls Below Threshold

**Severity**: Informational

**File**: `src/external/governance/GovernorBravoDelegate.sol`, lines 435-462

**Description**:

The `cancel` function allows anyone to cancel a proposal if the proposer's voting power has dropped below the proposal threshold:

```solidity
if (msg.sender != proposal.proposer) {
    if (gohm.getPriorVotes(proposal.proposer, block.number - 1) >= proposal.proposalThreshold)
        revert GovernorBravo_Cancel_AboveThreshold();
}
```

This is the standard GovernorBravo design. It incentivizes proposers to maintain their voting weight throughout the proposal lifecycle. A proposer who sells/unstakes their gOHM can have their active proposal canceled by anyone.

**Impact**: By design. Not a vulnerability.

---

### Finding 13: ProposalScript `run()` Incorrectly Adjusts Proposal ID

**Severity**: Low

**File**: `src/proposals/ProposalScript.sol`, lines 41-46

**Description**:

```solidity
uint256 proposalId = abi.decode(proposalReturnData, (uint256));
// The value returned by the GovernorBravoDelegate is actually 1 more than the actual ID, so adjust for that.
proposalId -= 1;
```

The comment states the returned value is 1 more than the actual ID. However, looking at `GovernorBravoDelegate.propose()`:

```solidity
proposalCount++;
uint256 newProposalID = proposalCount;
// ...
return newProposalID;
```

The returned `newProposalID` IS the actual proposal ID (the incremented count). Subtracting 1 would produce the wrong ID. This is a bug in the proposal submission script.

However, this only affects off-chain scripting/logging, not on-chain security. The proposal is correctly created and stored regardless of what the script logs.

**Impact**: Informational -- affects off-chain scripting only. No fund risk.

---

### Finding 14: LoanConsolidator Does Not Verify Cooler Loan Ownership Before Repayment

**Severity**: Informational

**File**: `src/policies/LoanConsolidator.sol`, lines 603-619

**Description**:

The `_repayDebtForLoans` function calls `cooler.repayLoan(ids_[i], principal + interestDue)` for each loan ID. It trusts that the Cooler contract will properly validate loan ownership and handle the repayment. If a loan ID does not exist or has already been repaid, the Cooler contract will revert.

The LoanConsolidator does verify that the Cooler was created by the CoolerFactory for the specified Clearinghouse (`_isValidCooler`), and that the caller owns the Cooler. However, it does not independently verify that the loan IDs are active/valid before attempting repayment. This is fine because the Cooler itself enforces these checks, but it means the entire flashloan transaction reverts on invalid loan IDs, leaving the user to pay gas for a failed transaction.

**Impact**: None. Failed transactions just waste gas.

---

## Summary Table

| # | Finding | Severity | Impact | File |
|---|---------|----------|--------|------|
| 1 | ClaimTransfer division-by-zero on zero percent | Medium | DoS/locked accounting | ClaimTransfer.sol:157 |
| 2 | ClaimTransfer rounding inflation of max claim | Medium | Potential over-claiming (micro-amounts) | ClaimTransfer.sol:157-160 |
| 3 | LoanConsolidator unsafe ERC20 transfer | Low | No current risk; future token risk | LoanConsolidator.sol:375-507 |
| 4 | Timelock 1-day GRACE_PERIOD | Informational | Operational risk | Timelock.sol:58 |
| 5 | Emergency proposal bypass of voting | Low | By design, vetoGuardian power | GovernorBravoDelegate.sol:220-281 |
| 6 | state(0) returns valid state for non-existent proposal | Low | Off-chain tooling confusion | GovernorBravoDelegate.sol:959-1007 |
| 7 | pushGovernor effectiveImmediately bypass | Low | Centralization (out of scope) | OlympusAuthority.sol:120-124 |
| 8 | pOLY claim to arbitrary address | Low | By design, no vulnerability | pOLY.sol:106-115 |
| 9 | ReserveMigrator 1:1 assumption | Informational | Adequate for current implementation | ReserveMigrator.sol:131 |
| 10 | consolidateWithNewOwner loan transfer | Low | Requires explicit consent | LoanConsolidator.sol:297-318 |
| 11 | ERC6909Wrappable double-allowance concern | Informational | Depends on implementation | ERC6909Wrappable.sol:110-133 |
| 12 | Proposal cancellation by anyone below threshold | Informational | By design | GovernorBravoDelegate.sol:435-462 |
| 13 | ProposalScript wrong proposal ID | Low | Off-chain only | ProposalScript.sol:44 |
| 14 | LoanConsolidator no pre-validation of loan IDs | Informational | Gas waste on failure only | LoanConsolidator.sol:603-619 |

---

## Detailed Analysis by Category

### Governance Exploitation

The GovernorBravo system is a well-known fork of Compound's governance. The Olympus modifications (emergency mode, activation mechanism, veto guardian) are implemented correctly. The voting uses `min(votes_at_proposal_start, votes_at_vote_time)` which prevents accumulation attacks. The codehash check in the Timelock prevents rug-pull via upgradeable contracts. No bypass of the timelock delay was found.

The emergency mode (gOHM supply < 1000e18) grants the vetoGuardian unilateral execution power, which is the intended design for catastrophic scenarios.

### OHM Token Vulnerabilities

The OlympusERC20Token contract is a standard ERC20 with access-controlled minting (onlyVault). The authority system uses a two-step push/pull pattern (with an optional immediate mode). No unauthorized minting/burning paths were found. The `burnFrom` function correctly decreases allowance before burning.

### LoanConsolidator

The LoanConsolidator is well-structured with appropriate guards:
- `nonReentrant` modifier prevents reentrancy.
- `onlyPolicyActive` and `onlyConsolidatorActive` prevent use when disabled.
- Clearinghouse and Cooler validation through the CHREG registry and CoolerFactory.
- Ownership checks on both coolerFrom and coolerTo.

The main concern is the use of raw `transfer`/`transferFrom` instead of safe wrappers, but this is mitigated by the known behavior of DAI/USDS/gOHM.

### ReserveMigrator

Clean implementation with proper access control (`onlyRole("heart")`). The 1:1 migration check is adequate for the Maker DAI/USDS migrator. The rescue function provides a safety net for stuck tokens.

### pOLY / ClaimTransfer

The pOLY contract itself is well-secured. The ClaimTransfer contract has the division-by-zero and rounding issues described in Findings 1 and 2. These are the most notable findings in this group.

### Libraries

All library contracts (FullMath, TransferHelper, SafeCast, Timestamp, TimestampLinkedList, DecimalString, ERC6909Wrappable, AddressStorageArray, String, Uint2Str) are correctly implemented standard utilities. FullMath is the well-audited Uniswap V3 implementation. No arithmetic bugs were found.

### Proposals

All proposal files are governance scripts that configure roles and activate policies. They are correctly structured and follow the expected patterns. The only issue noted is the off-by-one in ProposalScript.sol (Finding 13) which only affects logging.

---

## Conclusion

No critical or high-severity vulnerabilities were found that would enable direct loss of treasury funds, user funds, or bond funds. The most impactful findings are the ClaimTransfer division-by-zero DoS (Finding 1) and rounding inflation (Finding 2), both rated Medium. The codebase is generally well-written with appropriate access controls, and the governance system follows battle-tested patterns.
