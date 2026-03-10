# Olympus V3 Second-Pass Audit: Rare Attack Vectors

## Audit Scope
Deep-dive analysis of unusual attack vectors across the Olympus V3 codebase, focused on cross-contract interactions, state machine violations, encoding bugs, and economic loops.

---

## A. gOHM Delegation + Flash Loan Governance Attack

### Files Analyzed
- `/root/immunefi/audits/olympus-v3/src/modules/DLGTE/OlympusGovDelegation.sol`
- `/root/immunefi/audits/olympus-v3/src/policies/cooler/MonoCooler.sol`
- `/root/immunefi/audits/olympus-v3/src/external/cooler/DelegateEscrow.sol`
- `/root/immunefi/audits/olympus-v3/src/external/governance/GovernorBravoDelegate.sol`

### Attack Hypothesis
An attacker flash borrows gOHM, deposits as collateral in MonoCooler, delegates through DLGTE, votes in governance, and repays -- all in one transaction.

### Analysis

**Step-by-step breakdown:**

1. **Flash borrow gOHM**: Attacker obtains gOHM via flash loan.
2. **Deposit as collateral**: `MonoCooler.addCollateral()` calls `DLGTE.depositUndelegatedGohm()`, which physically transfers gOHM from MonoCooler to the DLGTE module contract.
3. **Delegate the gOHM**: `MonoCooler.applyDelegations()` calls `DLGTE.applyDelegations()` which creates a `DelegateEscrow` and transfers gOHM to it. The escrow calls `IVotes(address(gohm)).delegate(delegateAccount)` during initialization (line 43 of DelegateEscrow.sol).
4. **Vote in governance**: `GovernorBravoDelegate.castVoteInternal()` uses `gohm.getPriorVotes(voter, proposal.startBlock)` and `gohm.getPriorVotes(voter, block.number - 1)` (lines 591-593). It takes the **minimum** of votes at proposal start and current votes.

**Key mitigation: `getPriorVotes(voter, block.number - 1)`**

The governance system uses `block.number - 1` as the snapshot. Within the same block, any delegation that occurs will NOT be reflected in `getPriorVotes(voter, block.number - 1)` because the snapshot is from the previous block. The gOHM token's `getPriorVotes()` uses checkpoints that are written at the current block but only queryable for past blocks.

Additionally, `castVoteInternal()` takes `min(originalVotes, currentVotes)`, meaning even if the delegation DID register, the attacker would need to have had votes at `proposal.startBlock` as well.

**Furthermore**, withdrawing collateral requires sender authorization AND an LTV check. The attacker would need to repay any debt before withdrawing. But the core issue is that you cannot deposit, delegate, vote, undelegate, and withdraw in a single transaction because the gOHM checkpoint system prevents same-block voting power from being counted.

### Verdict: NOT EXPLOITABLE

The gOHM token's `getPriorVotes()` checkpoint system provides robust protection against flash loan governance attacks. The `block.number - 1` snapshot means delegations in the current block are invisible to the voting system. The `min(start, current)` approach adds a second layer of defense.

### Residual Risk: LOW
An attacker holding gOHM across blocks could still use MonoCooler delegation to amplify their governance influence without directly holding the tokens in their wallet, but this is the intended design of the delegation system.

---

## B. SafeCast / encodeUInt128 Edge Cases

### Files Analyzed
- `/root/immunefi/audits/olympus-v3/src/libraries/SafeCast.sol`
- `/root/immunefi/audits/olympus-v3/src/policies/cooler/MonoCooler.sol`

### Analysis

The SafeCast library properly validates all downcasts:

```solidity
function encodeUInt128(uint256 amount) internal pure returns (uint128) {
    if (amount > type(uint128).max) {
        revert Overflow(amount);
    }
    return uint128(amount);
}
```

This is used extensively in MonoCooler:
- `totalDebt` is `uint128` (max ~3.4e38, representing ~3.4e20 USDS with 18 decimals)
- `totalCollateral` is `uint128`
- `AccountState.collateral` and `debtCheckpoint` are `uint128`
- `interestAccumulatorRay` is `uint256` (no truncation risk)

**Potential overflow scenario for totalDebt:**
In `_initGlobalStateCache()` (line 922-924):
```solidity
gStateCache.totalDebt = newInterestAccumulatorRay
    .mulDivUp(gStateCache.totalDebt, gStateCache.interestAccumulatorRay)
    .encodeUInt128();
```

If interest compounds for an extremely long time without any interaction, the compounded `totalDebt` could theoretically exceed `uint128.max`. With a 10% max rate (`MAX_INTEREST_RATE = 0.1e18`) and continuous compounding, the time to overflow from even 1e18 USDS initial debt would be:

- `e^(0.1 * t) * 1e18 > 3.4e38` -> `t > (38 * ln(10) + ln(3.4)) / 0.1` -> `t > ~890 years`

This is not practically exploitable given realistic time horizons and debt amounts.

**AccountState.debtCheckpoint overflow**: Similarly, individual account debt is bounded by totalDebt which is bounded by `uint128.max`.

### Verdict: NOT EXPLOITABLE

The SafeCast library correctly reverts on overflow. The maximum values are astronomically large relative to realistic protocol usage. Even under extreme compounding, overflow would take centuries.

---

## C. Timestamp Manipulation Across Contracts

### Files Analyzed
- `/root/immunefi/audits/olympus-v3/src/libraries/Timestamp.sol`
- `/root/immunefi/audits/olympus-v3/src/libraries/CompoundedInterest.sol`
- `/root/immunefi/audits/olympus-v3/src/policies/cooler/MonoCooler.sol`
- `/root/immunefi/audits/olympus-v3/src/policies/Heart.sol`

### Analysis

**Timestamp.sol**: Only used for date formatting (year/month/day strings). Not security-critical.

**CompoundedInterest.sol**: Uses `elapsedSecs` derived from `block.timestamp` difference:
```solidity
function continuouslyCompounded(
    uint256 principal,
    uint256 elapsedSecs,
    uint96 interestRatePerYear
) internal pure returns (uint256 result) {
    return principal.mulWadDown(
        uint256(wadExp(int256((interestRatePerYear * elapsedSecs) / ONE_YEAR)))
    );
}
```

In MonoCooler's `_initGlobalStateCache()`:
```solidity
uint40 timeElapsed;
unchecked {
    timeElapsed = uint40(block.timestamp) - interestAccumulatorUpdatedAt;
}
```

**Miner manipulation window**: Post-merge (PoS), block proposers have ~12 seconds of control over `block.timestamp`. The timestamp must be >= parent timestamp and <= current wall clock time + some tolerance.

**Impact calculation**: With 10% annual rate (max), 12 seconds of manipulation:
- Interest for 12 seconds on 1M USDS: `1,000,000 * (e^(0.1 * 12/31,536,000) - 1) = ~0.000038 USDS`
- This is negligible (~$0.000038) even at maximum rate

**Cross-contract timing attacks**: The Heart `beat()` function uses:
```solidity
uint48 currentTime = uint48(block.timestamp);
if (currentTime < lastBeat + frequency()) revert Heart_OutOfCycle();
```

A block proposer could manipulate the timestamp to make a beat available slightly early, then sandwich the `PRICE.updateMovingAverage()` call. However:
1. The price update uses oracles/observations, not direct timestamp-dependent calculations
2. The 12-second window is tiny relative to the observation frequency
3. The reward auction is linearly increasing, so earlier execution means smaller reward

### Verdict: NOT EXPLOITABLE

Timestamp manipulation provides negligible financial benefit (sub-cent) at the interest rate level. Cross-contract timing attacks via Heart are bounded by the oracle's observation frequency and provide no meaningful economic advantage.

---

## D. ERC4626 Vault Donation Attacks (sUSDS/sDAI)

### Files Analyzed
- `/root/immunefi/audits/olympus-v3/src/policies/cooler/CoolerTreasuryBorrower.sol`
- `/root/immunefi/audits/olympus-v3/src/policies/EmissionManager.sol`

### Analysis

**CoolerTreasuryBorrower interaction with sUSDS:**

In `borrow()` (line 96-99):
```solidity
uint256 susdsAmount = SUSDS.previewWithdraw(amountInWad);
TRSRY.increaseWithdrawApproval(address(this), SUSDS, susdsAmount);
TRSRY.withdrawReserves(address(this), SUSDS, susdsAmount);
SUSDS.withdraw(amountInWad, recipient, address(this));
```

**Donation attack scenario**: An attacker donates raw USDS directly to the sUSDS vault, inflating the share price. This would cause `previewWithdraw()` to return fewer shares for the same USDS amount. However:

1. The Treasury holds sUSDS shares. If the vault is inflated, Treasury's shares are worth more -- this benefits the protocol.
2. The borrow flow requests a fixed `amountInWad` of USDS. The `previewWithdraw()` correctly computes how many sUSDS shares are needed to withdraw that exact amount. The actual `withdraw()` call specifies the exact USDS amount.
3. sUSDS (Sky's savings contract) is a battle-tested vault with likely billions in TVL. A first-depositor attack is not feasible on an already-active vault.

**In `repay()` (line 107-108):**
```solidity
_USDS.safeApprove(address(SUSDS), debtTokenAmount);
SUSDS.deposit(debtTokenAmount, address(TRSRY));
```

Here the protocol deposits USDS back into sUSDS. If shares were inflated, the protocol would receive fewer shares for the same USDS, but this rounding loss would be negligible on a mature vault.

**EmissionManager with sReserve**: The EmissionManager stores `sReserve` as an immutable `ERC4626`. The interactions are similar -- converting between reserve tokens and their savings wrappers.

### Verdict: NOT EXPLOITABLE

The protocol interacts with mature, battle-tested ERC4626 vaults (sUSDS) that already have significant TVL. First-depositor attacks are infeasible. Donation-based share price inflation would primarily benefit the protocol (since Treasury holds shares). Rounding errors from share price manipulation would be negligible.

---

## E. Kernel Module Upgrade + Stale State

### Files Analyzed
- `/root/immunefi/audits/olympus-v3/src/Kernel.sol` (lines 275-374)

### Analysis

**Module upgrade flow (`_upgradeModule`, lines 275-289):**
```solidity
function _upgradeModule(Module newModule_) internal {
    Keycode keycode = newModule_.KEYCODE();
    Module oldModule = getModuleForKeycode[keycode];

    if (address(oldModule) == address(0) || oldModule == newModule_)
        revert Kernel_InvalidModuleUpgrade(keycode);

    getKeycodeForModule[oldModule] = Keycode.wrap(bytes5(0));
    getKeycodeForModule[newModule_] = keycode;
    getModuleForKeycode[keycode] = newModule_;

    newModule_.INIT();

    _reconfigurePolicies(keycode);
}
```

**`_reconfigurePolicies` (lines 363-374):**
```solidity
function _reconfigurePolicies(Keycode keycode_) internal {
    Policy[] memory dependents = moduleDependents[keycode_];
    uint256 depLength = dependents.length;

    for (uint256 i; i < depLength; ) {
        dependents[i].configureDependencies();
        unchecked { ++i; }
    }
}
```

**Key observations:**

1. **Non-atomic state**: Between `getModuleForKeycode[keycode] = newModule_` (line 284) and `_reconfigurePolicies(keycode)` (line 288), the Kernel's module mapping points to the new module, but policies still have cached references to the OLD module. The `newModule_.INIT()` call happens first.

2. **During INIT execution**: If `INIT()` on the new module makes any external calls or callbacks, policies that depend on the upgraded module would still reference the old module address in their local state variables. However, `INIT()` is `onlyKernel` gated and typically just initializes internal state.

3. **reconfigurePolicies calls `configureDependencies()`**: This updates each policy's cached module references. In MonoCooler's `configureDependencies()` (lines 171-208):
   - If MINTR changed: revokes approval from old, grants to new
   - If DLGTE changed: revokes approval from old, grants to new
   - If during MINTR upgrade, MonoCooler's old MINTR approval is still active, and some other function were to call `MINTR.burnOhm()` before reconfiguration, it would call the OLD module (which is no longer registered).

4. **Critical: Permissions are NOT re-granted during `_reconfigurePolicies`**: The `_reconfigurePolicies` only calls `configureDependencies()` on each policy. It does NOT update the `modulePermissions` mapping. The old permissions map `oldModule.KEYCODE() -> policy -> funcSelector -> true`, but the keycode mapping now points to `newModule`. Since `modulePermissions` is keyed by `Keycode` (not module address), the permissions should still work correctly because the keycode hasn't changed -- only the module address behind it.

5. **HOWEVER**: There is a subtle race condition. If a transaction that calls a module function is pending in the mempool while a module upgrade executes in the same block, the pending transaction's `msg.sender` (a policy) would now call the NEW module, which has the same permissions. This is actually the intended behavior.

6. **State migration concern**: When MINTR or TRSRY is upgraded, the old module retains its state. The new module starts fresh (from INIT). If there were any pending mint approvals, reserve balances tracked by the module, or debt records, they would be lost. This is a governance-level concern rather than an exploit -- the executor must ensure proper state migration.

### Verdict: LOW RISK (Governance concern, not exploitable by external attacker)

The upgrade mechanism is sound from an access control perspective. The executor (governance/multisig) must ensure state migration is handled properly. There is no window for an external attacker to exploit the upgrade transition. The `permissioned` modifier correctly checks permissions by keycode, which survives module upgrades.

---

## F. CoolerFactory Address Prediction + Frontrunning

### Files Analyzed
- `/root/immunefi/audits/olympus-v3/src/external/cooler/CoolerFactory.sol`
- `/root/immunefi/audits/olympus-v3/src/external/cooler/Cooler.sol`

### Analysis

**CoolerFactory uses ClonesWithImmutableArgs (`clone()` method):**
```solidity
cooler = address(coolerImplementation).clone(coolerData);
```

The `ClonesWithImmutableArgs` library uses `CREATE` (not `CREATE2`). The clone address is determined by the factory's nonce, which increments with each deployment. This means:

1. **Address is NOT predictable from off-chain** in the same way CREATE2 addresses are (which depend on salt + initcode + deployer address). CREATE addresses depend on deployer nonce, which requires knowing the exact nonce at deployment time.

2. **The factory stores `coolerFor[msg.sender][collateral_][debt_]`**: Each user can only have one Cooler per collateral-debt pair. Calling `generateCooler()` with the same parameters returns the existing address.

3. **Frontrunning scenario**: Could an attacker front-run `generateCooler()` and deploy a malicious contract at the predicted address? Since CREATE is used, the attacker would need to deploy from the factory's address with the factory's nonce, which is impossible without controlling the factory.

4. **The `created[cooler] = true` mapping** prevents any external contract from masquerading as a factory-created Cooler.

### Verdict: NOT EXPLOITABLE

CREATE-based deployment prevents address prediction attacks. The factory's nonce-based addressing and the `created` mapping provide robust protection. An attacker cannot pre-deploy a malicious contract at the Cooler's future address.

---

## G. GovernorBravo Proposal + Timelock Self-Modification

### Files Analyzed
- `/root/immunefi/audits/olympus-v3/src/external/governance/GovernorBravoDelegate.sol`
- `/root/immunefi/audits/olympus-v3/src/external/governance/Timelock.sol`

### Analysis

**Can a governance proposal change the Timelock delay to 0?**

Timelock.setDelay():
```solidity
function setDelay(uint256 delay_) public {
    if (msg.sender != address(this)) revert Timelock_OnlyInternalCall();
    if (delay_ < MINIMUM_DELAY || delay_ > MAXIMUM_DELAY) revert Timelock_InvalidDelay();
    delay = delay_;
}
```

**Key constraints:**
1. `MINIMUM_DELAY = 1 days` -- cannot set to 0
2. `MAXIMUM_DELAY = 3 days` -- bounded above
3. `msg.sender != address(this)` -- only callable via a queued and executed transaction through the Timelock itself

**Can a proposal bypass the Timelock entirely?**

A proposal executes through `Timelock.executeTransaction()`, which requires:
- Transaction is queued: `queuedTransactions[txHash] == true`
- ETA has passed: `block.timestamp >= eta`
- Not stale: `block.timestamp <= eta + GRACE_PERIOD`
- Code hash hasn't changed: `ContractUtils.getCodeHash(target) == codehash`

**Code hash check (important)**: The Timelock verifies that the target contract's code hasn't changed between queuing and execution. This prevents upgrading a target to a malicious implementation between queue and execute.

**Attack: Change delay to 1 day (minimum)**

A valid governance proposal COULD set the delay to 1 day. This is the minimum, which is by design. The delay bounds (1-3 days) are hardcoded as constants and cannot be modified.

**Attack: Change pendingAdmin to seize Timelock**

`Timelock.setPendingAdmin()` requires `msg.sender == address(this)`. A governance proposal could change the pendingAdmin to a new GovernorBravo instance or a malicious contract. However:
- This requires passing quorum (20% of gOHM supply)
- This requires 60% approval threshold
- The veto guardian can veto the proposal
- There's a timelock delay before execution

**`_isHighRiskProposal` gap**: The function correctly identifies proposals targeting the Timelock or GovernorBravo itself as high risk (line 754: `if (target == address(this) || target == address(timelock)) return true`). However, the high risk quorum is currently NOT used -- lines 299-306 in the `activate()` function show this is commented out, and all proposals use the same quorum.

**InstallModule (action=0) not checked as high risk**: In `_isHighRiskProposal()`, actions 1-5 are checked but action 0 (`InstallModule`) is not explicitly handled. Installing a new module could potentially be dangerous, but new keycodes can only be 5 uppercase letters and cannot collide with existing ones (the install function reverts if the keycode already has a module).

### Verdict: LOW RISK (By design, with governance safeguards)

The Timelock has robust minimum delay enforcement (1 day minimum, hardcoded). The code hash verification prevents contract upgrade attacks during the queue period. The veto guardian provides an additional safety layer. The main concern is that high risk quorum is not yet implemented, so all proposals have the same 20% quorum -- this could theoretically make it easier to pass a dangerous proposal, but this is a governance design choice, not a code vulnerability.

---

## H. Heart.beat() + Operator.operate() + EmissionManager.execute() Ordering

### Files Analyzed
- `/root/immunefi/audits/olympus-v3/src/policies/Heart.sol`

### Analysis

**Heart.beat() execution order:**
```solidity
function beat() external nonReentrant {
    if (!isEnabled) revert Heart_BeatStopped();
    uint48 currentTime = uint48(block.timestamp);
    if (currentTime < lastBeat + frequency()) revert Heart_OutOfCycle();

    // 1. Update price moving average
    PRICE.updateMovingAverage();

    // 2. Trigger the rebase
    distributor.triggerRebase();

    // 3. Execute periodic tasks (may include Operator.operate(), EmissionManager.execute())
    _executePeriodicTasks();

    // 4. Calculate reward
    uint256 reward = currentReward();

    // 5. Update lastBeat
    lastBeat = currentTime - ((currentTime - lastBeat) % frequency());

    // 6. Issue reward to keeper
    if (reward > 0) { ... }
}
```

**Sandwich attack on beat():**

1. **Before beat**: Attacker observes a pending `beat()` transaction. The price oracle is about to update. If the attacker knows what the new price will be (e.g., they see a large trade in the mempool), they could:
   - Front-run: Buy/sell OHM based on expected price impact
   - Back-run: Reverse the trade after the price update

2. **Mitigations in place:**
   - `nonReentrant` modifier prevents reentrancy
   - Price updates use moving averages which smooth out single-observation volatility
   - The reward auction incentivizes early execution, making sandwich timing more predictable
   - RBS (Range Bound Stability) operations are bounded by wall/cushion parameters

3. **Ordering exploitation**: The fixed order means that Operator sees the LATEST price (after step 1), while EmissionManager also uses updated prices. This is the correct order -- price should update before operations that depend on it.

4. **lastBeat calculation**: `lastBeat = currentTime - ((currentTime - lastBeat) % frequency())` -- This ensures beats stay aligned to the frequency grid even if a beat is late. An attacker cannot manipulate this to cause double-beats.

### Verdict: LOW RISK

The execution order is correct (price update before dependent operations). The `nonReentrant` guard prevents reentrancy. Sandwich attacks on the heartbeat are theoretically possible but economically bounded by moving average smoothing and RBS parameters. The fixed ordering does not introduce exploitable asymmetries.

---

## I. MonoCooler Interest Rate Manipulation

### Files Analyzed
- `/root/immunefi/audits/olympus-v3/src/policies/cooler/MonoCooler.sol` (interest accumulator code)
- `/root/immunefi/audits/olympus-v3/src/policies/cooler/CoolerLtvOracle.sol`

### Analysis

**Interest rate change mechanism:**
```solidity
function setInterestRateWad(uint96 newInterestRate) external override onlyAdminRole {
    if (newInterestRate > MAX_INTEREST_RATE) revert InvalidParam();

    // Force an update of state on the old rate first.
    _globalStateRW();

    emit InterestRateSet(newInterestRate);
    interestRateWad = newInterestRate;
}
```

**How the accumulator works:**
```solidity
function _initGlobalStateCache(...) private view returns (bool dirty) {
    gStateCache.interestAccumulatorRay = interestAccumulatorRay;
    gStateCache.totalDebt = totalDebt;

    uint40 timeElapsed;
    unchecked {
        timeElapsed = uint40(block.timestamp) - interestAccumulatorUpdatedAt;
    }

    if (timeElapsed > 0) {
        dirty = true;
        uint256 newInterestAccumulatorRay = gStateCache
            .interestAccumulatorRay
            .continuouslyCompounded(timeElapsed, interestRateWad);
        gStateCache.totalDebt = newInterestAccumulatorRay
            .mulDivUp(gStateCache.totalDebt, gStateCache.interestAccumulatorRay)
            .encodeUInt128();
        gStateCache.interestAccumulatorRay = newInterestAccumulatorRay;
    }
}
```

**Rate change fairness analysis:**

1. **`_globalStateRW()` is called before rate change**: This ensures the accumulator is updated with the OLD rate up to the current block. Then the new rate applies from this point forward. This is correct -- existing debt is not retroactively affected.

2. **Per-account debt calculation**:
```solidity
function _currentAccountDebt(
    uint128 accountDebtCheckpoint_,
    uint256 accountInterestAccumulatorRay_,
    uint256 globalInterestAccumulatorRay_
) private pure returns (uint128 result) {
    uint256 debt = globalInterestAccumulatorRay_.mulDivUp(
        accountDebtCheckpoint_,
        accountInterestAccumulatorRay_
    );
    return debt.encodeUInt128();
}
```

Each account stores their `interestAccumulatorRay` at the time of their last interaction. Their current debt = `checkpoint * (globalAccumulator / accountAccumulator)`. When the rate changes, the global accumulator continues from its current value but at the new rate. This means accounts that haven't interacted since before the rate change will accumulate interest at the weighted average of the old and new rates for their respective periods. This is correct behavior.

3. **Potential issue: Rate frontrunning**: An admin could see a large borrow pending and frontrun it with a rate increase. However:
   - The admin role is governed (multisig/timelock)
   - `MAX_INTEREST_RATE = 0.1e18` (10%) caps the damage
   - The borrower can see the current rate before borrowing

4. **Edge case: Rate set to 0 then back**: If rate is set to 0, the accumulator stops growing. When rate is restored, the accumulator resumes from where it stopped. No interest is charged for the period at 0%. This is correct.

5. **`uint40` timestamp wrapping**: `interestAccumulatorUpdatedAt` is `uint40`. Max value: 2^40 - 1 = ~1,099,511,627,775 seconds, which is year 36812. No wrapping risk.

### Verdict: NOT EXPLOITABLE

The interest rate change mechanism correctly snapshots the accumulator before applying the new rate. Existing borrowers are not retroactively affected. The per-account accumulator design ensures fair interest calculation across rate changes. The admin governance controls prevent malicious rate manipulation.

---

## J. AddressStorageArray and TimestampLinkedList Edge Cases

### Files Analyzed
- `/root/immunefi/audits/olympus-v3/src/libraries/AddressStorageArray.sol`
- `/root/immunefi/audits/olympus-v3/src/libraries/TimestampLinkedList.sol`

### Analysis

**AddressStorageArray:**

`insert()`:
```solidity
function insert(address[] storage array, address value_, uint256 index_) internal {
    if (index_ > array.length) revert ...;
    array.push(address(0));
    for (uint256 i = array.length - 1; i > index_; i--) {
        array[i] = array[i - 1];
    }
    array[index_] = value_;
}
```

- Bounds checking is correct: `index_ > array.length` reverts (not >=, since inserting at the end is valid)
- The shift loop correctly moves elements right
- Gas cost: O(n) for insertion -- potential gas griefing if array is very large, but this depends on how it's used

`remove()`:
```solidity
function remove(address[] storage array, uint256 index_) internal returns (address) {
    if (index_ >= array.length) revert ...;
    address removedValue = array[index_];
    for (uint256 i = index_; i < array.length - 1; i++) {
        array[i] = array[i + 1];
    }
    array.pop();
    return removedValue;
}
```

- Bounds checking correct: `index_ >= array.length` reverts
- Shift loop correctly moves elements left
- No underflow risk: `array.length - 1` is safe because we already verified `index_ < array.length` (array is non-empty)

**No edge case corruption identified** for AddressStorageArray. The implementation is straightforward and correct.

**TimestampLinkedList:**

`add()`:
```solidity
function add(List storage list, uint48 timestamp) internal {
    if (timestamp == 0) revert ...;
    if (contains(list, timestamp)) return; // Already exists
    if (list.head == 0 || timestamp > list.head) {
        list.previous[timestamp] = list.head;
        list.head = timestamp;
        return;
    }
    uint48 current = list.head;
    while (list.previous[current] != 0 && list.previous[current] > timestamp) {
        current = list.previous[current];
    }
    list.previous[timestamp] = list.previous[current];
    list.previous[current] = timestamp;
}
```

**Edge case analysis:**
1. **Duplicate timestamp**: `contains()` check prevents duplicates. Correct.
2. **Insertion at head**: If `timestamp > list.head`, it becomes the new head. Correct.
3. **Insertion in middle**: Traverses until `list.previous[current] <= timestamp`, then inserts. Correct.
4. **Insertion at tail**: When `list.previous[current] == 0`, the loop exits and the new timestamp is inserted at the end with `previous = 0`. Correct.

**`contains()` inefficiency**: The `contains()` function is O(n) and is called within `add()`, making `add()` O(n) as well. This is acceptable for small lists but could be gas-griefed with many timestamps.

**Subtle issue: No `remove()` function**: The TimestampLinkedList has no `remove()` function. Once a timestamp is added, it can never be removed. This means the list grows monotonically. If this is used in a context where entries should be cleaned up, it would be a storage leak. However, whether this is a vulnerability depends on usage context.

**Potential corruption**: Can `previous[0]` be set? No -- the function checks `timestamp == 0` at the start and reverts. The zero value is used as the sentinel/null value, and it's properly protected.

### Verdict: NOT EXPLOITABLE

Both data structures have correct implementations with proper bounds checking. The TimestampLinkedList's lack of a `remove()` function could lead to unbounded growth, but this is a design choice rather than a bug. No corruption through specific call sequences is possible.

---

## CROSS-CUTTING FINDINGS

### Finding 1: Kernel `permissioned` Modifier Logic (INFORMATIONAL)

**File**: `/root/immunefi/audits/olympus-v3/src/Kernel.sol`, lines 110-116

```solidity
modifier permissioned() {
    if (
        msg.sender == address(kernel) ||
        !kernel.modulePermissions(KEYCODE(), Policy(msg.sender), msg.sig)
    ) revert Module_PolicyNotPermitted(msg.sender);
    _;
}
```

This modifier has potentially confusing logic: it reverts if `msg.sender IS the kernel` OR if the sender lacks permissions. The kernel is intentionally blocked from calling permissioned functions. The kernel only calls `INIT()` (which uses `onlyKernel` instead) and `changeKernel()` (also `onlyKernel`). This is correct but could be a source of bugs if future code assumes the kernel can call permissioned functions.

**Severity**: INFORMATIONAL

### Finding 2: GovernorBravo `_isHighRiskProposal` Missing InstallModule Check (LOW)

**File**: `/root/immunefi/audits/olympus-v3/src/external/governance/GovernorBravoDelegate.sol`, lines 740-808

The `_isHighRiskProposal()` function does not check action 0 (`InstallModule`). While `InstallModule` can only add a new keycode (not replace existing ones), a malicious module could potentially interact with existing policies if policies are later reconfigured to depend on it. However, since this function is currently unused (high risk quorum is commented out in `activate()`), this has no practical impact at present.

**Severity**: LOW

### Finding 3: CoolerLtvOracle `setMaxOriginationLtvRateOfChange` Division Truncation (LOW)

**File**: `/root/immunefi/audits/olympus-v3/src/policies/cooler/CoolerLtvOracle.sol`, line 138

```solidity
function setMaxOriginationLtvRateOfChange(
    uint96 originationLtvDelta,
    uint32 timeDelta
) external override onlyAdminRole {
    uint96 maxRateOfChange = originationLtvDelta / timeDelta;
    ...
}
```

If `timeDelta` is 0, this will revert with a division-by-zero panic. While this is admin-only and the revert is not harmful, it would be cleaner to have an explicit check. More importantly, if `originationLtvDelta < timeDelta`, the result truncates to 0, effectively disabling rate-of-change limits. An admin setting this to 0 would mean `setOriginationLtvAt()` would pass the rate check for any delta, since `0 > 0` is false. However, the `maxOriginationLtvDelta` check still bounds the absolute change.

**Severity**: LOW

### Finding 4: CoolerTreasuryBorrower sUSDS Conversion Rounding (INFORMATIONAL)

**File**: `/root/immunefi/audits/olympus-v3/src/policies/cooler/CoolerTreasuryBorrower.sol`, lines 96-99

```solidity
uint256 susdsAmount = SUSDS.previewWithdraw(amountInWad);
TRSRY.increaseWithdrawApproval(address(this), SUSDS, susdsAmount);
TRSRY.withdrawReserves(address(this), SUSDS, susdsAmount);
SUSDS.withdraw(amountInWad, recipient, address(this));
```

`previewWithdraw()` rounds up (per ERC4626 spec) to return the number of shares needed. The actual `withdraw()` call may burn fewer shares if the exchange rate changes between the `previewWithdraw()` and `withdraw()` calls (which can happen if there's a pending sUSDS distribution in the same block). This could leave a dust amount of sUSDS with the CoolerTreasuryBorrower. However, this dust amount would be negligible and subsequent operations would naturally reuse these shares.

**Severity**: INFORMATIONAL

---

## SUMMARY TABLE

| Vector | Severity | Exploitable? | Notes |
|--------|----------|-------------|-------|
| A. Flash loan governance | NOT EXPLOITABLE | No | `getPriorVotes(block.number - 1)` prevents same-block voting |
| B. SafeCast overflow | NOT EXPLOITABLE | No | Proper overflow checks; uint128 max is astronomically large |
| C. Timestamp manipulation | NOT EXPLOITABLE | No | 12-second window yields sub-cent profit at max rate |
| D. ERC4626 donation attack | NOT EXPLOITABLE | No | Mature vaults; donation benefits protocol |
| E. Module upgrade stale state | LOW | No (governance concern) | Executor must handle state migration |
| F. CoolerFactory frontrunning | NOT EXPLOITABLE | No | CREATE prevents address prediction |
| G. Timelock self-modification | LOW | By design | 1-day minimum delay; veto guardian protection |
| H. Heart ordering exploit | LOW | No | Correct ordering; nonReentrant; moving average smoothing |
| I. Interest rate manipulation | NOT EXPLOITABLE | No | Accumulator snapshots before rate change |
| J. Data structure corruption | NOT EXPLOITABLE | No | Correct bounds checking throughout |

---

## OVERALL ASSESSMENT

The Olympus V3 codebase demonstrates strong defensive programming across the investigated attack vectors. The key security properties are:

1. **gOHM checkpoint system** effectively prevents flash loan governance attacks
2. **SafeCast library** provides consistent overflow protection across all narrowing casts
3. **Interest accumulator design** correctly handles rate changes without retroactive effects
4. **Kernel permission system** survives module upgrades due to keycode-based indexing
5. **Timelock bounds** are hardcoded constants that cannot be bypassed
6. **ClonesWithImmutableArgs** deployment prevents address prediction attacks

No critical or high-severity vulnerabilities were identified in this second-pass review. The low-severity findings are primarily governance design choices or informational notes about code clarity.
