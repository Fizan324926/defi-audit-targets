# Spark Protocol: Emergency/Freeze Mechanism & Governance Timing Attack Analysis

## Scope

This report analyzes the emergency freeze mechanisms, governance timelock patterns, and cross-chain governance relay in the Spark protocol, searching for exploitable bypasses and timing attacks.

**Contracts Analyzed:**
- `spark-alm-controller/src/ALMProxyFreezable.sol`
- `spark-alm-controller/src/ALMProxy.sol`
- `spark-alm-controller/src/ForeignController.sol`
- `spark-alm-controller/src/MainnetController.sol`
- `spark-alm-controller/src/RateLimits.sol`
- `spark-gov-relay/src/Executor.sol`

---

## 1. Freeze Bypass via Pending Transactions

### Architecture of Freeze

The Spark protocol does NOT use a boolean "frozen" flag. Instead, it uses **role revocation** as the freeze mechanism:

- **ALMProxyFreezable**: `removeController(address controller)` -- revokes CONTROLLER role from a controller, preventing it from calling `doCall`/`doCallWithValue`/`doDelegateCall` on the proxy.
- **MainnetController/ForeignController**: `removeRelayer(address relayer)` -- revokes RELAYER role from a relayer, preventing it from executing any operational function.

### Analysis: Race Condition with In-Flight Operations

**Finding: No race condition exists at the smart contract level.**

Because both the freeze (role revocation) and the operational functions (e.g., `transferAsset`, `depositPSM`) are on-chain transactions that execute atomically, there is no smart-contract-level race condition. A transaction either executes before the freeze or after. The `onlyRole` check is evaluated at execution time.

**However, there IS a mempool-level race condition:**

If a freezer submits `removeRelayer(relayer)` and a compromised relayer simultaneously submits a drain transaction, the outcome depends on which transaction is included first by validators. The compromised relayer could:
1. Monitor the mempool for freeze transactions
2. Front-run with a higher gas price
3. Execute their malicious action before the freeze lands

**Mitigant already in place:** The rate limit system bounds the maximum extractable value even if the relayer front-runs the freeze. The damage is limited to whatever the current rate limit allows.

**Verdict: Low/Informational** -- This is an inherent limitation of any permissioned system that uses role revocation. The rate limit system provides adequate bounds.

---

## 2. Freeze Then Drain (State Manipulation While Frozen)

### Analysis

The freeze mechanism in Spark (role revocation) is binary -- once a relayer/controller is removed, they cannot call ANY function protected by `onlyRole(RELAYER)` or `onlyRole(CONTROLLER)`.

**Can state be manipulated while "frozen"?**

After `removeRelayer(relayer)`:
- The frozen relayer cannot call ANY controller function (all require RELAYER role)
- The admin functions still work (setting slippage, mint recipients, etc.) but require `DEFAULT_ADMIN_ROLE`
- Rate limits continue to accrue time-based capacity (see Finding #7 below)

After `removeController(controller)` on ALMProxyFreezable:
- The frozen controller cannot call `doCall`, `doCallWithValue`, or `doDelegateCall`
- Tokens can still be sent TO the proxy via normal ERC20 transfers (the proxy has a `receive()` function for ETH)
- But no one can move tokens OUT without CONTROLLER role

**Can an attacker manipulate unprotected state?**

No exploitable path found. All meaningful state changes (rate limit configs, slippage settings, mint recipients, etc.) require `DEFAULT_ADMIN_ROLE` which is held by governance (Spark Proxy), not the freezer or relayer.

**Verdict: Not exploitable.** The freeze mechanism is complete -- there are no unprotected state mutations a frozen actor can perform.

---

## 3. Governance Timelock Bypass on Executor.sol

### Architecture

The `Executor.sol` uses:
- `delay`: Time between queuing and earliest execution
- `gracePeriod`: Window after delay during which execution is possible (minimum 10 minutes)
- `SUBMISSION_ROLE`: Can queue actions (bridge receiver)
- `GUARDIAN_ROLE`: Can cancel queued actions
- `DEFAULT_ADMIN_ROLE`: Can update delay/grace period (held by deployer AND `address(this)`)

### Attack Vector: Delay Set to Zero

**Critical architectural observation:** `_updateDelay()` has NO minimum delay check:

```solidity
function _updateDelay(uint256 newDelay) internal {
    emit DelayUpdate(delay, newDelay);
    delay = newDelay;  // Can be set to 0
}
```

A governance proposal can set `delay = 0`, meaning subsequent proposals could be queued and immediately executed in the same block.

**Attack scenario:**
1. Attacker gains `SUBMISSION_ROLE` (bridge receiver compromise)
2. Queues proposal A: `updateDelay(0)` (via delegatecall self-referential pattern)
3. Waits for current delay
4. Executes proposal A (delay is now 0)
5. Queues and immediately executes proposal B (malicious payload) in same block

**Mitigant:** Step 2-4 requires the attacker to wait the existing delay period. During this time, the GUARDIAN can cancel the proposal. This is by design -- the delay is explicitly settable to 0 as shown in tests and the `ReconfigurationPayload` mock.

**However:** If both SUBMISSION_ROLE (bridge) and GUARDIAN are compromised simultaneously, the delay-to-zero attack becomes viable with no defense.

**Already-queued proposals are NOT affected by delay changes.** Each proposal stores its own `executionTime = block.timestamp + delay` at queue time. Changing the delay only affects future proposals.

### Attack Vector: Multiple Proposals Interaction

**Can one proposal cancel another?** No. The `cancel` function requires `GUARDIAN_ROLE`, which is not the same as the execution context of a proposal. A proposal executing via delegatecall runs in the Executor's context and has DEFAULT_ADMIN_ROLE, but cancel requires GUARDIAN_ROLE specifically.

**Wait -- the Executor grants itself DEFAULT_ADMIN_ROLE.** Can a delegatecall payload grant itself GUARDIAN_ROLE and then cancel other proposals?

Yes! A delegatecall payload executes in the Executor's storage context with the Executor's permissions. The payload could:
```solidity
function execute() external {
    IExecutor(address(this)).grantRole(IExecutor(address(this)).GUARDIAN_ROLE(), address(this));
    IExecutor(address(this)).cancel(otherActionSetId);
}
```

This is technically possible but requires the payload to first pass through the normal timelock. This is a design feature, not a bug -- governance should be able to cancel other queued actions.

**Verdict: By design.** The delay-to-zero path exists but requires waiting the existing delay (during which the guardian can intervene).

---

## 4. L1-to-L2 Governance Front-Running

### Architecture

Cross-chain governance flow:
1. L1: Spark Proxy executes a crosschain payload
2. The payload sends a message through the native bridge (Arbitrum/Optimism/Gnosis)
3. L2: Bridge receiver contract receives the message and calls `Executor.queue()`
4. After L2 delay, anyone can call `Executor.execute()`

### Analysis: Bridge Transit Window

**The time between L1 execution and L2 queue is the bridge transit time:**
- Arbitrum: ~10-15 minutes for normal messages
- Optimism: ~20 minutes
- Gnosis: varies

During this window, the L2 state is observable (the L1 transaction is public) but the L2 change hasn't arrived yet.

**Concrete attack scenario -- Rate Limit Reduction:**
1. Governance sends "reduce USDC transfer rate limit from 100M to 10M" via cross-chain message
2. Attacker sees this L1 transaction
3. Before the message arrives on L2, attacker (if they are a relayer) uses the full 100M limit
4. By the time the rate limit reduction lands, the damage is done

**Severity assessment:** This requires the attacker to BE the relayer (RELAYER role), which is a privileged position. A compromised relayer can already do significant damage within rate limits regardless of governance changes.

**Additional time window after bridge arrival:** Even after the message arrives on L2 and gets queued, there's a `delay` period (600 seconds in default config) before execution. Combined with bridge transit, the total window is:
- Bridge transit (10-20 min) + L2 executor delay (10 min+) = 20-30+ minutes

During this entire window, the old configuration remains active.

**Verdict: Informational -- Known limitation of cross-chain governance.** The rate limit system bounds the maximum damage. The relayer is already a trusted role.

---

## 5. KillSwitchOracle

### Analysis

**No KillSwitchOracle contract was found in the audited source code.** A thorough search across all `.sol` files in the repository found zero matches for "KillSwitch" or "killswitch".

This either:
1. Does not exist in the in-scope contracts
2. Is an external dependency not included in this source tree
3. Was renamed or abstracted differently

**Verdict: Out of scope / Not found in audited code.**

---

## 6. Frozen ALMProxy -- Can Funds Still Be Moved?

### Architecture

`ALMProxyFreezable.removeController(controller)` revokes the `CONTROLLER` role. The proxy functions are:

```solidity
function doCall(address target, bytes memory data) external onlyRole(CONTROLLER) returns (bytes memory);
function doCallWithValue(address target, bytes memory data, uint256 value) external payable onlyRole(CONTROLLER) returns (bytes memory);
function doDelegateCall(address target, bytes memory data) external onlyRole(CONTROLLER) returns (bytes memory);
receive() external payable { }
```

### Analysis

**When the proxy's controller is removed:**

1. **Can direct token transfers still occur TO the proxy?** YES. Anyone can send ERC20 tokens or ETH to the proxy. This is standard ERC20 behavior and the proxy has `receive()` for ETH. These tokens are effectively trapped -- they can be received but not moved out.

2. **Can any function still execute?** NO operational function can execute. All three call functions (`doCall`, `doCallWithValue`, `doDelegateCall`) require `CONTROLLER` role. Without a controller, the proxy is completely inert.

3. **Does frozen state apply to ALL controllers?** `removeController` revokes the role for a SPECIFIC controller address. If multiple controllers are granted the `CONTROLLER` role, removing one does NOT affect others. This is by design -- the freezer would need to call `removeController` for each controller.

**Critical observation:** The `DEFAULT_ADMIN_ROLE` holder (governance) can always:
- Grant new CONTROLLER roles
- Revoke CONTROLLER roles
- Restore the system by granting a new controller

**The freezer can remove controllers but CANNOT grant new ones.** The freezer role is strictly one-way (removal only). Recovery requires governance action.

**Parallel freeze mechanisms:**
- ALMProxyFreezable freeze: removes controller from proxy (nuclear option -- stops ALL proxy operations)
- Controller freeze: removes relayer from controller (targeted -- stops specific relayers but controller still exists)

These are independent. The freezer on the controller removes relayers; the freezer on the proxy removes controllers.

**Verdict: Secure by design.** The freeze is comprehensive for removed controllers. Multiple controller support is intentional and documented.

---

## 7. Unfreezing Attack -- Rate Limit Accumulation During Freeze

### THIS IS THE MOST INTERESTING FINDING

### Architecture

Rate limits use a linear accumulation model:

```solidity
function getCurrentRateLimit(bytes32 key) public view returns (uint256) {
    RateLimitData memory d = _data[key];
    if (d.maxAmount == type(uint256).max) return type(uint256).max;
    return _min(
        d.slope * (block.timestamp - d.lastUpdated) + d.lastAmount,
        d.maxAmount
    );
}
```

The rate limit grows linearly from `lastAmount` at rate `slope` per second, capped at `maxAmount`.

### The Accumulation Problem

**When a relayer is frozen (removed), the rate limits are NOT reset.** The freeze only revokes the RELAYER role. The rate limit state (`lastAmount`, `lastUpdated`, `slope`, `maxAmount`) remains unchanged.

**During the freeze period:**
- Time passes
- `block.timestamp - d.lastUpdated` increases
- `slope * (block.timestamp - d.lastUpdated) + d.lastAmount` grows
- It caps at `maxAmount`

**When the system is unfrozen (new relayer granted or same relayer restored):**
- The rate limit has silently accumulated back to `maxAmount` (if enough time passed)
- The new/restored relayer can immediately use the FULL rate limit

### Is This Exploitable?

**Scenario: Compromised relayer drains, gets frozen, system unfreezes:**
1. Relayer uses rate limit capacity (e.g., transfers 50M out of 100M max)
2. `lastAmount = 50M`, `lastUpdated = now`
3. Relayer gets frozen (role revoked)
4. 10 days pass (system is frozen while governance deliberates)
5. Rate limit silently recharges: `slope * 10_days + 50M` (likely >= maxAmount)
6. New relayer is assigned
7. New relayer immediately has FULL 100M capacity

**Is this a vulnerability?**

For the freeze-and-restore case: NO, because the new relayer is trusted (governance assigned them).

For the freeze-and-replace-controller case (via governance spell upgrading the controller):
- The `upgradeController` function revokes the old controller's CONTROLLER role from RateLimits
- But `_initController` grants the new controller CONTROLLER role on RateLimits
- **The rate limit DATA is not touched** -- it carries over to the new controller
- The new controller's relayers inherit accumulated rate limits from the pre-freeze state

**This is by design** -- governance can explicitly reset rate limits via `setRateLimitData()` as part of the upgrade spell. But if they forget to reset rate limits during an upgrade after a freeze, the new system starts with potentially maxed-out limits.

**Verdict: Informational / Low.** The rate limit accumulation during freeze is expected behavior. The risk is operational -- governance must remember to reset rate limits when unfreezing/upgrading after a security incident. There is no enforcement mechanism that automatically resets limits on unfreeze.

---

## 8. Executor Payload Replay

### Analysis

**Can the same governance payload be executed twice?**

```solidity
function execute(uint256 actionsSetId) external payable override {
    if (getCurrentState(actionsSetId) != ActionsSetState.Queued) revert OnlyQueuedActions();
    ActionsSet storage actionsSet = _actionsSets[actionsSetId];
    if (block.timestamp < actionsSet.executionTime) revert TimelockNotFinished();
    actionsSet.executed = true;  // <-- Set BEFORE execution
    // ... execute actions ...
}
```

**No replay is possible.** The `executed = true` flag is set BEFORE the actions are executed. Once executed, `getCurrentState()` returns `Executed` instead of `Queued`, and the check at line 99 reverts.

**Can the same payload be queued again?**

Yes, but it gets a new `actionsSetId` (incrementing counter). Each queue creates a new, independent actions set. This is intentional -- governance may want to execute the same configuration change again.

**Reentrancy attack on execute?**

The `executed = true` is set before external calls (checks-effects-interactions pattern). Even if a payload calls back into `execute()` for the same ID, it would fail because the state is already `Executed`.

**Verdict: Secure. No replay vulnerability.**

---

## 9. Self-Destructing Spell Pattern (SpellFreezeAll, SpellPauseAll)

### Analysis

**No SpellFreezeAll, SpellPauseAll, SpellFreezeDai, or SpellPauseDai contracts were found in the audited source code.**

These appear to be part of the SparkLend/Aave fork governance module which may be deployed separately. They are not in the `spark-alm-controller` or `spark-gov-relay` source trees.

**Regarding the general question -- can spells be called multiple times?**

In the Executor pattern used by Spark governance:
- Spells are executed via `delegatecall` from the Executor
- The spell runs in the Executor's storage context
- After execution, the `executed` flag prevents re-execution of that specific actions set
- However, the spell CONTRACT itself is not destroyed -- it could theoretically be re-queued as a new actions set

**Verdict: Out of scope for the analyzed contracts. The Executor prevents replay of specific action sets but does not prevent re-queuing of the same target contract.**

---

## 10. BONUS FINDING: Non-Constant State Variables in MainnetController

### Description

In `MainnetController.sol`, ALL role identifiers and rate limit keys are declared as mutable state variables rather than constants:

```solidity
// MainnetController.sol -- MUTABLE (occupies storage slots)
bytes32 public FREEZER = keccak256("FREEZER");   // Storage slot
bytes32 public RELAYER = keccak256("RELAYER");    // Storage slot
bytes32 public LIMIT_4626_DEPOSIT = keccak256("LIMIT_4626_DEPOSIT");  // Storage slot
// ... 28+ more mutable state variables
```

Compare with ForeignController.sol:
```solidity
// ForeignController.sol -- CONSTANT (no storage used)
bytes32 public constant FREEZER = keccak256("FREEZER");
bytes32 public constant RELAYER = keccak256("RELAYER");
```

### Impact

1. **Gas waste:** Each access to these "constants" costs ~2100 gas (SLOAD) instead of ~3 gas (PUSH32). With 30+ such variables, this adds significant gas overhead to every controller operation.

2. **Storage collision risk:** These mutable variables occupy real storage slots. They appear at the beginning of the contract's storage layout (after ReentrancyGuard's slot and AccessControlEnumerable's slots). While there is no current exploit path (no delegatecall is used on MainnetController, and there are no setter functions), this is a deviation from best practices that increases the attack surface unnecessarily.

3. **Theoretical exploit:** If a future upgrade introduced delegatecall capability to MainnetController, these storage slots could be overwritten, potentially changing the FREEZER or RELAYER role identifiers to different values. This would break access control -- the freezer would need the hash of a different string to authenticate.

### Actual Exploitability

**Not currently exploitable.** MainnetController has no delegatecall path, no setter functions for these variables, and no way to modify storage arbitrarily. This is a code quality / gas optimization issue.

**Verdict: Informational (gas waste + deviation from best practices).** Should be `constant` like in ForeignController.

---

## 11. BONUS FINDING: Executor updateDelay Has No Minimum

### Description

The `Executor._updateDelay()` function has no minimum delay requirement:

```solidity
function _updateDelay(uint256 newDelay) internal {
    emit DelayUpdate(delay, newDelay);
    delay = newDelay;  // Can be 0
}
```

Contrast with `_updateGracePeriod()` which enforces a minimum:

```solidity
function _updateGracePeriod(uint256 newGracePeriod) internal {
    if (newGracePeriod < MINIMUM_GRACE_PERIOD) revert GracePeriodTooShort();
    ...
}
```

### Impact

A governance proposal (via delegatecall) could set `delay = 0`. After this, any SUBMISSION_ROLE holder can queue and execute actions in the SAME BLOCK with zero waiting period.

This eliminates the guardian's ability to cancel malicious proposals (no time window to react).

### Mitigant

Setting delay to 0 requires a governance proposal that itself must wait the current delay, giving the guardian time to cancel it. The risk only materializes if both the bridge (SUBMISSION_ROLE) and the guardian monitoring fail simultaneously.

**Verdict: Low severity -- by design, but lacks the defensive minimum that gracePeriod has.**

---

## Summary Table

| # | Finding | Severity | Exploitable? |
|---|---------|----------|-------------|
| 1 | Freeze bypass via mempool front-running | Informational | Bounded by rate limits |
| 2 | Freeze-then-drain state manipulation | Not vulnerable | No unprotected state |
| 3 | Executor delay can be set to 0 | Low | Requires timelock passage first |
| 4 | L1-to-L2 governance front-running window | Informational | Requires compromised relayer |
| 5 | KillSwitchOracle | N/A | Not found in source |
| 6 | Frozen proxy fund movement | Not vulnerable | Comprehensive freeze |
| 7 | Rate limit accumulation during freeze | Low/Informational | Operational risk on unfreeze |
| 8 | Executor payload replay | Not vulnerable | Prevented by executed flag |
| 9 | Self-destructing spells | N/A | Out of scope |
| 10 | Non-constant state vars in MainnetController | Informational | Gas waste, no exploit path |
| 11 | No minimum delay on Executor | Low | By design but lacks safeguard |

---

## Conclusion

The Spark protocol's emergency freeze mechanisms are well-designed:

1. **Freeze is role-revocation-based**, which is a clean and effective pattern. No boolean flag that could be toggled back.
2. **Rate limits provide bounded risk** even if a compromised relayer front-runs a freeze.
3. **The Executor prevents replay** via the executed flag with checks-effects-interactions.
4. **The two-tier freeze** (proxy-level controller removal vs. controller-level relayer removal) provides defense in depth.

The most notable findings are:
- **Rate limit accumulation during freeze** (Finding #7) is an operational risk that could bite governance teams who forget to reset limits during unfreeze/upgrade.
- **Non-constant state variables** (Finding #10) in MainnetController is a code quality deviation that wastes gas and unnecessarily increases the theoretical attack surface.
- **No minimum delay** (Finding #11) on the Executor's timelock, unlike the gracePeriod which has a floor.

None of these rise to the level of a Critical or High severity Immunefi submission. The freeze/governance architecture is sound.
