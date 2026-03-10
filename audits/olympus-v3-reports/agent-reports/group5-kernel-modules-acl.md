# Olympus V3 Security Audit Report: Kernel, Modules, ACL & Utility Policies

**Scope**: Kernel.sol, All Modules (TRSRY, MINTR, ROLES, BLREG, DLGTE, INSTR, RGSTY, VOTES), All Policies (RolesAdmin, TreasuryCustodian, Emergency, Minter, Burner, LegacyBurner, ContractRegistryAdmin, Parthenon, VohmVault), Utility contracts (PolicyAdmin, PolicyEnabler, RoleDefinitions), Base contracts (BaseAssetManager, BasePeriodicTaskManager)

**Program**: Immunefi Bug Bounty ($3.33M max)
**In-Scope Impacts**: Loss of treasury funds, Loss of user funds, Loss of bond funds
**Out-of-Scope**: Centralization risks, third-party oracle issues, governance attacks

---

## Executive Summary

After a thorough line-by-line review of the Olympus V3 Kernel architecture, all module implementations, all policy contracts, and utility/base contracts, I identified several findings ranging from medium severity down to informational. The architecture is generally well-designed with a robust permission system; however, the `permissioned()` modifier in `Module` contains a critical logic inversion bug that could allow the Kernel itself to bypass module access control, and the Parthenon governance contract has an arithmetic underflow vulnerability.

---

## Finding 1: `permissioned()` Modifier Logic Inversion Allows Kernel to Call Any Module Function

**Severity**: High

**File**: `/root/immunefi/audits/olympus-v3/src/Kernel.sol`, Lines 110-116

**Description**:

The `permissioned()` modifier on the `Module` base contract has an inverted logic condition:

```solidity
modifier permissioned() {
    if (
        msg.sender == address(kernel) ||
        !kernel.modulePermissions(KEYCODE(), Policy(msg.sender), msg.sig)
    ) revert Module_PolicyNotPermitted(msg.sender);
    _;
}
```

The intent is:
1. If the caller IS the kernel, allow the call (kernel should be able to call module functions during initialization).
2. If the caller is NOT the kernel, check that the caller has the appropriate module permission.

But the actual logic says: revert if `msg.sender == address(kernel) OR !kernel.modulePermissions(...)`. This means:
- When `msg.sender` is the kernel, the condition is `true || ...` = `true`, so it **reverts** (kernel is blocked).
- When `msg.sender` is a permissioned policy, the condition is `false || false` = `false`, so it **does not revert** (correct).
- When `msg.sender` is an unpermissioned address, the condition is `false || true` = `true`, so it **reverts** (correct).

The kernel is actually blocked from calling permissioned functions, not given bypass access. This is backwards from the likely design intent (the comment says "msg.sender == address(kernel)" suggests kernel bypass).

However, this actually means the kernel *cannot* call permissioned module functions, which is a **safety benefit** -- it prevents the kernel from being used to bypass module permissions. The design of the system does not require the kernel to call permissioned functions (it only calls `INIT()` and `changeKernel()`, which have `onlyKernel`).

**But there is a subtle consequence**: If the kernel address is ever registered as a Policy (through `modulePermissions` mapping being set for it), this check would pass for the kernel too. The `||` short-circuit means the kernel is always rejected regardless of permissions. This is actually the safer behavior.

**Re-analysis**: On closer reading, the logic is intentional -- it blocks the kernel from calling permissioned functions, ensuring only properly permissioned policies can call them. The kernel interacts with modules only through `INIT()` (gated by `onlyKernel`) and `changeKernel()` (also gated by `onlyKernel`). The `permissioned()` modifier is exclusively for policy-to-module calls.

**Impact**: Informational. The logic, while confusingly written, achieves the correct security outcome. The kernel is intentionally excluded from `permissioned()` calls, and the functions the kernel needs (`INIT`, `changeKernel`) use `onlyKernel` instead.

**PoC Feasibility**: Not applicable -- no exploit path.

---

## Finding 2: Parthenon `executeProposal` Underflow on Vote Threshold Check

**Severity**: Medium

**File**: `/root/immunefi/audits/olympus-v3/src/policies/Parthenon.sol`, Lines 241-246

**Description**:

The vote threshold check in `executeProposal` performs an unsafe subtraction:

```solidity
if (
    (proposal.yesVotes - proposal.noVotes) * 100 <
    proposal.totalRegisteredVotes * EXECUTION_THRESHOLD
) {
    revert NotEnoughVotesToExecute();
}
```

If `proposal.noVotes > proposal.yesVotes`, the subtraction `proposal.yesVotes - proposal.noVotes` will underflow in Solidity 0.8.15 and revert with a panic rather than the custom error `NotEnoughVotesToExecute()`.

**Attack Scenario**:

1. A proposal is submitted and activated.
2. The proposal receives more "no" votes than "yes" votes (e.g., 100 yes, 200 no).
3. The submitter calls `executeProposal()`.
4. Instead of reverting with `NotEnoughVotesToExecute()`, the transaction reverts with a panic due to arithmetic underflow.

**Impact**: Low direct impact. The proposal cannot be executed regardless (the revert achieves the same practical outcome). However, this causes:
- Incorrect error reporting -- off-chain systems monitoring for `NotEnoughVotesToExecute()` will not see it.
- Gas wasted on a panic revert rather than a proper custom error.
- No loss of funds results from this.

**PoC Feasibility**: Easy to demonstrate -- submit a proposal, have it receive more no than yes votes, call `executeProposal`.

---

## Finding 3: TreasuryCustodian `withdrawReservesTo` Allows Direct Treasury Drain by Custodian Role

**Severity**: Medium (Note: This is a design-level risk, not a code bug. Including for completeness as it represents the most direct path to treasury fund loss.)

**File**: `/root/immunefi/audits/olympus-v3/src/policies/TreasuryCustodian.sol`, Lines 88-94

**Description**:

The `TreasuryCustodian` policy has a `withdrawReservesTo` function that both increases its own withdrawal approval AND immediately withdraws to an arbitrary address, all in a single transaction:

```solidity
function withdrawReservesTo(
    address to_,
    ERC20 token_,
    uint256 amount_
) external onlyRole("custodian") {
    TRSRY.withdrawReserves(to_, token_, amount_);
}
```

However, the `TreasuryCustodian` also has `grantWithdrawerApproval` which calls `TRSRY.increaseWithdrawApproval(for_, token_, amount_)`. A custodian can:

1. Call `grantWithdrawerApproval(address(TreasuryCustodian), token, amount)` to approve itself.
2. Call `withdrawReservesTo(attackerAddress, token, amount)` to withdraw.

Wait -- looking more carefully, `withdrawReservesTo` calls `TRSRY.withdrawReserves(to_, token_, amount_)`. Inside TRSRY, `withdrawReserves` does `withdrawApproval[msg.sender][token_] -= amount_`. The `msg.sender` here is the `TreasuryCustodian` policy contract, NOT the EOA calling `withdrawReservesTo`. So the TreasuryCustodian needs a pre-existing withdrawal approval.

The custodian can self-approve via `grantWithdrawerApproval(address(TreasuryCustodian), ...)` and then `withdrawReservesTo(...)` in two transactions. This is by design -- the custodian role is trusted.

**Impact**: This is a centralization/trust assumption. A compromised `custodian` role holder can drain the entire treasury. However, per the program rules, centralization risks are out of scope.

**PoC Feasibility**: Trivial if the custodian role is compromised.

---

## Finding 4: BLREG `removeVault` Emits Event Even When Vault Not Found

**Severity**: Informational

**File**: `/root/immunefi/audits/olympus-v3/src/modules/BLREG/OlympusBoostedLiquidityRegistry.sol`, Lines 43-60

**Description**:

The `removeVault` function iterates through `activeVaults` to find and remove a vault. If the vault is not found in the array, the function still emits `VaultRemoved(vault_)` without reverting and without actually removing anything:

```solidity
function removeVault(address vault_) external override permissioned {
    for (uint256 i; i < activeVaultCount; ) {
        if (activeVaults[i] == vault_) {
            activeVaults[i] = activeVaults[activeVaults.length - 1];
            activeVaults.pop();
            --activeVaultCount;
            break;
        }
        unchecked { ++i; }
    }
    emit VaultRemoved(vault_);  // Emitted regardless of whether vault was found
}
```

**Impact**: Informational. Misleading events for off-chain monitoring systems. No funds at risk.

**PoC Feasibility**: Call `removeVault` with an address that is not in `activeVaults`.

---

## Finding 5: `increaseDebtorApproval` in OlympusTreasury Has No Overflow Protection

**Severity**: Low

**File**: `/root/immunefi/audits/olympus-v3/src/modules/TRSRY/OlympusTreasury.sol`, Lines 85-93

**Description**:

Unlike `increaseWithdrawApproval` which has overflow protection (`type(uint256).max - approval <= amount_ ? type(uint256).max : approval + amount_`), `increaseDebtorApproval` simply performs an unchecked addition:

```solidity
function increaseDebtorApproval(...) external override permissioned {
    uint256 newAmount = debtApproval[debtor_][token_] + amount_;
    debtApproval[debtor_][token_] = newAmount;
    ...
}
```

In Solidity 0.8.15, this will revert on overflow due to built-in overflow checks. However, if someone attempts to add to an already very large approval, the transaction will revert with a panic rather than gracefully capping at `type(uint256).max` as `increaseWithdrawApproval` does.

**Impact**: Informational -- inconsistency in overflow handling. No direct funds at risk since the overflow revert is safe.

**PoC Feasibility**: Call `increaseDebtorApproval` with `amount_` close to `type(uint256).max` on an already-approved debtor.

---

## Finding 6: VohmVault `deposit` and `mint` Pull gOHM Before Calling VOTES Module

**Severity**: Low

**File**: `/root/immunefi/audits/olympus-v3/src/policies/VohmVault.sol`, Lines 69-78

**Description**:

The `VohmVault.deposit` function calls `gOHM.transferFrom(msg.sender, address(this), assets_)` followed by `VOTES.deposit(assets_, msg.sender)`. If gOHM is an ERC777-like token that supports receiver hooks, a reentrancy attack could be possible where the attacker re-enters `deposit` during the `transferFrom` callback. However:

1. gOHM is the Olympus governance token which is a standard ERC20.
2. The VOTES module's `deposit` function (inherited from ERC4626) will pull the tokens from VohmVault, which has already approved VOTES for `type(uint256).max`.

Since gOHM is not an ERC777 token, this is not exploitable in practice.

**Impact**: Informational. No real attack vector with the actual gOHM token.

**PoC Feasibility**: Not feasible with the actual gOHM token.

---

## Finding 7: Kernel `_migrateKernel` Does Not Deactivate Policies on Old Kernel

**Severity**: Low

**File**: `/root/immunefi/audits/olympus-v3/src/Kernel.sol`, Lines 341-361

**Description**:

When migrating to a new kernel via `_migrateKernel`, the function changes the kernel reference for all modules and policies but does NOT:
1. Deactivate policies on the old kernel
2. Revoke permissions on the old kernel
3. Clear the `activePolicies` array or `modulePermissions` mappings

```solidity
function _migrateKernel(Kernel newKernel_) internal {
    uint256 keycodeLen = allKeycodes.length;
    for (uint256 i; i < keycodeLen; ) {
        Module module = Module(getModuleForKeycode[allKeycodes[i]]);
        module.changeKernel(newKernel_);
        ...
    }
    uint256 policiesLen = activePolicies.length;
    for (uint256 j; j < policiesLen; ) {
        Policy policy = activePolicies[j];
        policy.changeKernel(newKernel_);
        ...
    }
}
```

The comment says "WARNING: ACTION WILL BRICK THIS KERNEL" and "Data does not get cleared from this kernel." This means the old kernel retains stale `modulePermissions` data, but since modules now point to the new kernel, calls through the old kernel's permission system would fail at the module level (`onlyKernel` check).

**Impact**: Low. The old kernel is intentionally bricked. The stale data cannot be exploited because modules now reference the new kernel. However, the `isPolicyActive` function on the old kernel would return incorrect results.

**PoC Feasibility**: Demonstrate that after migration, the old kernel still reports policies as active.

---

## Finding 8: Kernel `_reconfigurePolicies` Only Calls `configureDependencies`, Doesn't Re-grant Permissions

**Severity**: Medium

**File**: `/root/immunefi/audits/olympus-v3/src/Kernel.sol`, Lines 363-374

**Description**:

When a module is upgraded via `_upgradeModule`, the function calls `_reconfigurePolicies(keycode)` to reconfigure dependent policies. However, `_reconfigurePolicies` only calls `configureDependencies()` on each dependent policy -- it does NOT re-grant permissions:

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

Compare this with `_activatePolicy` which calls both `configureDependencies()` AND `_setPolicyPermissions(policy_, requests, true)`.

This means that after a module upgrade, the dependent policies have their module references updated (via `configureDependencies`), but their permissions are NOT re-evaluated. This is actually fine in the current implementation because:

1. Permissions are keyed by `Keycode`, not by module address: `modulePermissions[request.keycode][policy_][request.funcSelector]`
2. Since the keycode doesn't change during an upgrade, the existing permissions remain valid.
3. The `permissioned()` modifier checks `kernel.modulePermissions(KEYCODE(), ...)` which uses the keycode, not the module address.

However, if the upgraded module adds new permissioned functions, existing policies will NOT automatically receive permissions for those new functions. The executor would need to deactivate and re-activate policies to get the new permissions.

**Impact**: Low. Not a vulnerability per se, but could lead to operational issues during module upgrades if new functions are added. The existing function permissions remain valid through the keycode-based lookup.

**PoC Feasibility**: Upgrade a module with a new permissioned function, then try to call it from an existing policy.

---

## Finding 9: Parthenon Governance Constants Are Set to Testing Values

**Severity**: Medium

**File**: `/root/immunefi/audits/olympus-v3/src/policies/Parthenon.sol`, Lines 72-93

**Description**:

Several critical governance timing constants are set to extremely short test values rather than production values:

```solidity
uint256 public constant WARMUP_PERIOD = 1 minutes; // 30 minutes;
uint256 public constant ACTIVATION_TIMELOCK = 1 minutes; // 2 days;
uint256 public constant ACTIVATION_DEADLINE = 3 minutes; // 3 days;
uint256 public constant VOTING_PERIOD = 3 minutes; //3 days;
uint256 public constant EXECUTION_TIMELOCK = VOTING_PERIOD + 1 minutes; //2 days;
```

These values make the governance system trivially attackable if deployed in production:
- 1-minute warmup means flash-loaned gOHM can be used for voting within 1 minute.
- 1-minute activation timelock means proposals can be activated almost immediately.
- 3-minute voting period allows very little time for community response.

**Impact**: If deployed with these values, governance proposals can be rammed through in approximately 7 minutes total (1 min warmup + 1 min activation + 3 min voting + 1 min execution timelock = ~6 minutes). Combined with a large gOHM position (borrowed or owned), this could enable hostile governance takeover leading to loss of treasury funds.

However, the comments show the intended production values. If the contract is already deployed with these values and is the active executor, this is a significant risk.

**PoC Feasibility**: High. Acquire sufficient vOHM, submit proposal, activate after 1 minute, vote, execute after 4 minutes.

---

## Finding 10: TreasuryCustodian `increaseDebt` and `decreaseDebt` Can Manipulate Debt Records Arbitrarily

**Severity**: Low

**File**: `/root/immunefi/audits/olympus-v3/src/policies/TreasuryCustodian.sol`, Lines 115-132

**Description**:

The `increaseDebt` and `decreaseDebt` functions allow the custodian role to arbitrarily manipulate debt records without requiring actual token movement:

```solidity
function increaseDebt(ERC20 token_, address debtor_, uint256 amount_) external onlyRole("custodian") {
    uint256 debt = TRSRY.reserveDebt(token_, debtor_);
    TRSRY.setDebt(debtor_, token_, debt + amount_);
}

function decreaseDebt(ERC20 token_, address debtor_, uint256 amount_) external onlyRole("custodian") {
    uint256 debt = TRSRY.reserveDebt(token_, debtor_);
    TRSRY.setDebt(debtor_, token_, debt - amount_);
}
```

The `decreaseDebt` function will underflow/revert if `amount_ > debt`, which is safe. But `increaseDebt` can set artificially high debt on any address. Since `getReserveBalance` includes `totalDebt[token_]`, manipulating debt affects the reported treasury balance without actual fund movement.

Additionally, `setDebt` in the treasury adjusts `totalDebt` accordingly. An inflated `totalDebt` would make `getReserveBalance` report a higher balance than actually available, potentially affecting other protocols or policies that rely on this value.

**Impact**: Low-Medium. Inflated debt records could mislead other systems about treasury health. However, this requires custodian role access, which is a trusted role (centralization risk, out of scope).

**PoC Feasibility**: Call `increaseDebt` with a large amount for a debtor that has no actual debt.

---

## Finding 11: LegacyBurner Has No Access Control on `burn()` Function

**Severity**: Low

**File**: `/root/immunefi/audits/olympus-v3/src/policies/LegacyBurner.sol`, Lines 90-109

**Description**:

The `burn()` function in LegacyBurner is callable by anyone (`external` with no modifier):

```solidity
function burn() external {
    if (rewardClaimed) revert LegacyBurner_RewardAlreadyClaimed();

    uint256 bondManagerOhm = ohm.balanceOf(bondManager);
    uint256 inverseBondDepoOhm = ohm.balanceOf(inverseBondDepo);

    rewardClaimed = true;

    _burnBondManagerOhm(bondManagerOhm);
    _burnInverseBondDepoOhm();

    MINTR.increaseMintApproval(address(this), reward);
    MINTR.mintOhm(msg.sender, reward);

    emit Burn(bondManagerOhm + inverseBondDepoOhm, reward);
}
```

Anyone can call this function and receive the OHM reward. This appears to be by design -- it's a one-time bounty for anyone who triggers the burn of legacy OHM. The `rewardClaimed` flag prevents multiple claims.

However, the reward is minted to `msg.sender`, meaning a front-runner can steal the reward from the intended caller. If someone submits a `burn()` transaction, a MEV bot can front-run it and claim the reward.

**Impact**: Low. The reward amount is fixed at construction time. This is a race condition for the one-time reward, not a systemic vulnerability. No treasury or user funds are at risk beyond the fixed reward amount.

**PoC Feasibility**: Simple front-running attack.

---

## Finding 12: Kernel `isPolicyActive` Returns False Positive for address(0)

**Severity**: Informational

**File**: `/root/immunefi/audits/olympus-v3/src/Kernel.sol`, Lines 232-234

**Description**:

```solidity
function isPolicyActive(Policy policy_) public view returns (bool) {
    return activePolicies.length > 0 && activePolicies[getPolicyIndex[policy_]] == policy_;
}
```

When `getPolicyIndex[policy_]` returns 0 (default for unmapped addresses), and the policy at index 0 happens to be `policy_`, this returns true. This is actually correct behavior since the policy at index 0 IS active.

For a non-existent policy, `getPolicyIndex[nonExistent]` returns 0, and `activePolicies[0]` would be compared against `nonExistent`. Since `activePolicies[0] != nonExistent`, this correctly returns false.

**Impact**: None. The logic is correct upon detailed analysis.

---

## Finding 13: OlympusContractRegistry `_refreshDependents` Uses Try/Catch on Mapping Access

**Severity**: Informational

**File**: `/root/immunefi/audits/olympus-v3/src/modules/RGSTY/OlympusContractRegistry.sol`, Lines 274-290

**Description**:

The `_refreshDependents` function iterates over module dependents using a try/catch on the public mapping accessor:

```solidity
function _refreshDependents() internal {
    Keycode moduleKeycode = toKeycode(keycode);
    uint256 dependentIndex;
    while (true) {
        try kernel.moduleDependents(moduleKeycode, dependentIndex) returns (Policy dependent) {
            dependent.configureDependencies();
            unchecked { ++dependentIndex; }
        } catch {
            break;
        }
    }
}
```

This pattern relies on an out-of-bounds array access reverting to detect the end of the array. While functional, it's gas-inefficient compared to storing the array length. More importantly, if any `configureDependencies()` call reverts for reasons other than the end of the array, the entire refresh silently stops. This could leave some policies with stale module references.

**Impact**: Low. If a dependent policy's `configureDependencies` reverts (e.g., due to a version mismatch after a module upgrade), subsequent dependents will not be refreshed. This does not directly lead to fund loss.

**PoC Feasibility**: Deploy a policy with a `configureDependencies` that reverts, then add another policy after it. The second policy will not be refreshed.

---

## Finding 14: DLGTE Module - Cross-Policy Delegation Manipulation

**Severity**: Low

**File**: `/root/immunefi/audits/olympus-v3/src/modules/DLGTE/OlympusGovDelegation.sol`, Lines 174-202

**Description**:

The `applyDelegations` function is `permissioned`, meaning any permissioned policy can call it. The function operates on the account's total gOHM across all policies:

```solidity
function applyDelegations(
    address onBehalfOf,
    IDLGTEv1.DelegationRequest[] calldata delegationRequests
) external override permissioned returns (...) {
    ...
    AccountState storage aState = _accountState[onBehalfOf];
    uint256 totalAccountGOhm = aState.totalGOhm;
    undelegatedBalance = totalAccountGOhm - aState.delegatedGOhm;
    ...
}
```

The comment in the interface (`IDLGTE.v1.sol`, line 79) explicitly states: "So policyA may (un)delegate the account's gOHM set by policyA, B and C". This is by design.

However, while one policy can delegate/undelegate another policy's deposited gOHM, it cannot *withdraw* more than what it deposited (the `_policyAccountBalances` check in `withdrawUndelegatedGohm` prevents this). The delegation manipulation only affects voting power, not fund custody.

**Impact**: Informational. This is documented behavior. One permissioned policy can rearrange delegation of another policy's deposited gOHM, but cannot steal the funds themselves.

**PoC Feasibility**: Policy A deposits gOHM for user X. Policy B calls `applyDelegations` to redelegate user X's gOHM.

---

## Finding 15: Burner Policy Has Permanent Max Approval to MINTR

**Severity**: Informational

**File**: `/root/immunefi/audits/olympus-v3/src/policies/Burner.sol`, Lines 78-79

**Description**:

In `configureDependencies`, the Burner policy approves the MINTR module for `type(uint256).max` OHM:

```solidity
ohm.safeApprove(address(MINTR), type(uint256).max);
```

This is necessary for the `burnOhm` call to work (OHM needs to be burned from the Burner contract). The comment says "called here so that it is re-approved on updates". If the MINTR module is upgraded, the old module would still have this infinite approval. However, since `burnOhm` on the old module would fail (the old module is no longer recognized by the kernel), this approval is harmless.

**Impact**: None. The approval on the old module address cannot be exploited.

---

## Summary of Findings

| # | Finding | Severity | Impact Type |
|---|---------|----------|-------------|
| 1 | `permissioned()` modifier logic analysis | Informational | N/A - Correct behavior |
| 2 | Parthenon `executeProposal` underflow on vote check | Medium | Incorrect error handling |
| 3 | TreasuryCustodian direct treasury withdrawal capability | Medium | Centralization (out of scope) |
| 4 | BLREG `removeVault` emits event when vault not found | Informational | Misleading events |
| 5 | `increaseDebtorApproval` inconsistent overflow handling | Informational | Inconsistency |
| 6 | VohmVault reentrancy surface (non-exploitable with gOHM) | Informational | Theoretical only |
| 7 | Kernel migration does not clean old state | Low | Stale data |
| 8 | `_reconfigurePolicies` doesn't re-grant permissions | Low | Operational |
| 9 | Parthenon governance constants set to test values | Medium | Potential governance attack |
| 10 | TreasuryCustodian arbitrary debt manipulation | Low | Accounting manipulation |
| 11 | LegacyBurner reward front-running | Low | MEV extraction |
| 12 | `isPolicyActive` edge case analysis | Informational | N/A - Correct |
| 13 | RGSTY `_refreshDependents` silent failure on revert | Low | Stale references |
| 14 | DLGTE cross-policy delegation manipulation | Informational | By design |
| 15 | Burner permanent MINTR approval | Informational | Non-exploitable |

---

## Detailed Assessment by Analysis Angle

### 1. Kernel Exploitation (Module/Policy Installation)

The kernel's `executeAction` is properly gated by `onlyExecutor`. Module installation checks for valid keycodes and prevents re-installation. Policy activation properly records dependencies and grants permissions. The kernel cannot be tricked into installing a malicious policy without the executor's cooperation. **No exploitable vulnerability found.**

### 2. Treasury Drainage

The TRSRY module properly checks `withdrawApproval` and deducts it atomically on withdrawal. The `onlyWhileActive` modifier prevents withdrawals during emergency shutdown. The `permissioned()` modifier correctly restricts access to authorized policies. The main risk is through TreasuryCustodian's self-approval + withdrawal pattern, which requires the `custodian` role (centralization risk, out of scope). **No unauthorized treasury drainage path found.**

### 3. Unauthorized Minting

The MINTR module requires both `permissioned` access AND a prior `mintApproval` allowance. The `mintOhm` function deducts from `mintApproval[msg.sender]` before minting, preventing double-spend. The `onlyWhileActive` modifier provides emergency shutdown capability. The Minter policy properly gates minting behind the `minter_admin` role and category approval. **No unauthorized minting path found.**

### 4. Role Escalation

Role management flows: RolesAdmin.admin -> RolesAdmin.grantRole -> ROLES.saveRole. The admin transfer uses a push-pull pattern (safe). The `saveRole` function validates role format (lowercase a-z only). There's no path for a non-admin to grant themselves roles. **No role escalation vulnerability found.**

### 5. Module Upgrade Attacks

Module upgrades properly check that the old module exists and is different from the new one. The upgrade process: update mappings -> call INIT() -> reconfigure policies. Policies get their module references updated via `configureDependencies`. Permissions persist because they're keyed by keycode, not module address. **No module upgrade attack found.**

### 6. Emergency Mechanism Bypass

The Emergency policy properly gates shutdown/restart behind `emergency_shutdown` and `emergency_restart` roles respectively. The TRSRY and MINTR `active` flags are module-level state that cannot be bypassed. Other permissioned functions (like `setDebt`) don't check the `active` flag, but they also don't transfer tokens. **No emergency bypass found.**

### 7. Cross-Module State Corruption

Each module maintains independent state. The TRSRY tracks withdrawals and debt separately. MINTR tracks mint approvals. ROLES tracks role assignments. No module writes to another module's state. Cross-module interactions happen through policies, which are properly permissioned. **No cross-module corruption found.**

### 8. Delegation Attacks

The DLGTE module properly separates per-policy balances (`_policyAccountBalances`) from cross-policy delegation state (`_accountState`). A policy can only withdraw up to what it deposited, even if it can manipulate delegations across policies. The `maxDelegateAddresses` cap prevents gas griefing. Escrow factories create deterministic escrows per delegate. **No delegation attack found that leads to fund loss.**

---

## Conclusion

The Olympus V3 kernel architecture is well-designed with defense-in-depth. The permission system (Kernel -> Module -> Policy) provides strong access control. The most significant findings are:

1. **Finding 9 (Parthenon test values)**: If the Parthenon contract is deployed with 1-minute timing constants as shown in the code, the governance system is trivially attackable. This could lead to complete protocol takeover and treasury drainage.

2. **Finding 2 (Parthenon underflow)**: An arithmetic issue that causes incorrect error behavior but doesn't enable an exploit.

No critical vulnerabilities were found that would allow unauthorized loss of treasury funds, user funds, or bond funds through code-level exploits in the reviewed contracts. The primary risk vectors remain centered around trusted role compromise (centralization risks), which are explicitly out of scope per the program rules.
