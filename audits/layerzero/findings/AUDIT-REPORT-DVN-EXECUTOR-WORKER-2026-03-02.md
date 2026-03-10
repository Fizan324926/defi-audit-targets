# LayerZero V2 DVN / Executor / Worker Deep Security Audit Report

**Date:** 2026-03-02
**Scope:** DVN, MultiSig, ReceiveUlnBase, UlnBase, ReceiveUln302, Executor, Worker, WorkerUpgradeable, DVNFeeLib, ExecutorFeeLib, PriceFeed, Treasury
**Repository:** `LayerZero-v2/packages/layerzero-v2/evm/messagelib/contracts/`
**Bounty context:** Immunefi $15M critical bug bounty

---

## Executive Summary

After a deep line-by-line analysis of all 5 attack vectors across 12+ contracts, **zero confirmed critical/high exploitable vulnerabilities** were found in the DVN, Executor, and Worker subsystems. One **LOW severity code defect** was identified in PriceFeed._estimateFeeByEid() (dead-code double-computation for hardcoded L2 eids). All other hypotheses were confirmed as false positives with specific protection mechanisms documented below.

---

## ATTACK VECTOR 1: DVN Signature / Multisig Bypass

### Hypothesis 1.1: Can DVN.execute() be called with forged signatures?

**VERDICT: FALSE POSITIVE**

**Protection mechanisms:**

1. `execute()` requires `onlyRole(ADMIN_ROLE)` (line 176) -- only authorized admins can call it.
2. `verifySignatures()` in MultiSig.sol (line 93-112) performs rigorous checks:
   - Exact length check: `_signatures.length != uint256(quorum) * 65` (line 94)
   - Uses `ECDSA.tryRecover()` from OpenZeppelin v4.8.1+ which handles signature malleability (rejects `s` values in upper half of the curve)
   - Each recovered signer must be in the `signerSet` (line 108)
   - Uses eth_sign prefix via `_getEthSignedMessageHash` (line 98), preventing cross-protocol signature reuse
3. The hash is computed deterministically from `(vid, target, callData, expiration)` via `hashCallData()` (line 376), preventing parameter manipulation.

**Files:** `/root/defi-audit-targets/audits/layerzero/LayerZero-v2/packages/layerzero-v2/evm/messagelib/contracts/uln/dvn/DVN.sol` (lines 176-220), `/root/defi-audit-targets/audits/layerzero/LayerZero-v2/packages/layerzero-v2/evm/messagelib/contracts/uln/dvn/MultiSig.sol` (lines 93-112)

---

### Hypothesis 1.2: Can usedHashes be exploited? (hash is unset on failure, re-allowing execution)

**VERDICT: FALSE POSITIVE**

**Analysis of the hash-unset pattern (DVN.sol lines 206-214):**

1. `usedHashes[hash] = true` is set BEFORE the external call (line 206), preventing reentrancy with the same hash.
2. On call failure, `usedHashes[hash] = false` (line 214) allows the admin to retry the same operation -- this is INTENTIONAL for error recovery.
3. The only scenario where this could be concerning is if a call succeeds with side effects, then the same hash is replayed. But success does NOT unset the hash (only failure does), so replay after success is blocked.
4. For verify-type calls (`_shouldCheckHash` returns false), replay is harmless because `_verify()` just overwrites the same mapping entry with identical data.

**Files:** `/root/defi-audit-targets/audits/layerzero/LayerZero-v2/packages/layerzero-v2/evm/messagelib/contracts/uln/dvn/DVN.sol` (lines 199-218)

---

### Hypothesis 1.3: Can _shouldCheckHash() skip hash validation for dangerous operations?

**VERDICT: FALSE POSITIVE**

**Analysis (DVN.sol lines 386-392):**

The three exempt selectors are:
- `IReceiveUlnE2.verify.selector` (0x0223536e) -- replaying overwrites the same mapping entry; idempotent.
- `ReadLib1002.verify.selector` (0xab750e75) -- same reasoning; idempotent.
- `ILayerZeroUltraLightNodeV2.updateHash.selector` (0x704316e5) -- replaying will revert at the ULN level.

All other function selectors (including `setSigner`, `setQuorum`, `grantRole`, `revokeRole`, `withdrawFee`, etc.) DO have hash checks. Dangerous operations cannot bypass hash validation.

Edge case: If callData is shorter than 4 bytes, `bytes4(param.callData)` zero-pads, producing a selector that matches NONE of the exempt selectors, so hash IS checked. Safe direction.

---

### Hypothesis 1.4: Can quorumChangeAdmin() bypass the multisig quorum requirement?

**VERDICT: FALSE POSITIVE**

**Protection mechanisms (DVN.sol lines 137-160):**

1. Despite having no access control modifier, `quorumChangeAdmin` requires valid quorum signatures (line 150-153).
2. Checks: expiration (line 138), target must be `address(this)` (line 141), vid must match (line 144), signatures must be valid (line 150), hash must not be reused (line 154).
3. It ONLY grants `ADMIN_ROLE` (line 159) -- it cannot modify signers, quorum, allowlist, denylist, or MESSAGE_LIB_ROLE.
4. This is an emergency admin recovery mechanism: if all admins lose access, the quorum signers can add a new admin.

---

### Hypothesis 1.5: Can verifySignatures() be tricked with signature malleability?

**VERDICT: FALSE POSITIVE**

**Protection:** OpenZeppelin ECDSA v4.8.1+ `tryRecover` normalizes signatures and rejects malleable `s` values (those in the upper half of the secp256k1 curve). This is handled internally by OZ, making signature malleability impossible.

**File:** `/root/defi-audit-targets/audits/layerzero/LayerZero-v2/packages/layerzero-v2/evm/messagelib/contracts/uln/dvn/MultiSig.sol` (line 104)

---

### Hypothesis 1.6: Can the sorted-signer requirement be bypassed?

**VERDICT: FALSE POSITIVE**

**Protection (MultiSig.sol line 107):**

```solidity
if (currentSigner <= lastSigner) return (false, Errors.DuplicatedSigner);
```

`lastSigner` starts at `address(0)`. Each recovered signer must be strictly greater than the previous one. This enforces:
- No duplicate signers (same address can't sign twice)
- No zero-address signers (address(0) <= lastSigner=address(0) fails)
- A canonical ordering that makes it impossible to submit the same set of signatures in a different order

---

### Hypothesis 1.7: Can a DVN operator call verify() on ReceiveUln302 with false data?

**VERDICT: FALSE POSITIVE (by design -- trusted operator model)**

**Analysis:**

Yes, a DVN operator CAN call `ReceiveUln302.verify()` with arbitrary data through `DVN.execute()`. However:

1. The verification is recorded at `hashLookup[headerHash][payloadHash][msg.sender]` where `msg.sender` is the DVN contract address.
2. For a message to be committed, ALL required DVNs (and threshold of optional DVNs) must have verified the SAME headerHash and payloadHash.
3. The security model explicitly relies on DVN honesty. If a single DVN is malicious, the OApp's config should require multiple independent DVNs.
4. This is the fundamental LayerZero trust assumption -- not a vulnerability.

**File:** `/root/defi-audit-targets/audits/layerzero/LayerZero-v2/packages/layerzero-v2/evm/messagelib/contracts/uln/ReceiveUlnBase.sol` (line 44)

---

## ATTACK VECTOR 2: DVN Verification Logic

### Hypothesis 2.1: Can _checkVerifiable() be passed with fewer DVNs than required?

**VERDICT: FALSE POSITIVE**

**Protection (ReceiveUlnBase.sol lines 90-124):**

1. Required DVNs: The loop at lines 96-102 checks EVERY required DVN individually. If ANY required DVN has not verified with sufficient confirmations, the function returns false immediately.
2. Optional DVNs: The threshold counter (line 110) starts at `optionalDVNThreshold` and decrements for each verified optional DVN. Only returns true when threshold reaches exactly 0.
3. When both required and optional DVNs are configured (requiredDVNCount > 0 AND optionalDVNCount > 0), BOTH checks must pass -- all required DVNs must verify AND the optional threshold must be met.

---

### Hypothesis 2.2: Can optional DVN threshold be gamed (e.g., same DVN counted twice)?

**VERDICT: FALSE POSITIVE**

**Protection:**

1. `_assertNoDuplicates` in UlnBase.sol (lines 187-194) enforces that optionalDVNs are sorted ascending with no duplicates: `if (dvn <= lastDVN) revert LZ_ULN_Unsorted()`.
2. The `_checkVerifiable` loop iterates the optionalDVNs array sequentially. Since there are no duplicates in the array, no DVN address can be counted twice.
3. The comment on UlnConfig explicitly allows overlap between required and optional lists, but this is a FEATURE: an OApp might want DVN A to be required AND also count toward the optional threshold.

---

### Hypothesis 2.3: Can a required DVN be replaced by an optional DVN?

**VERDICT: FALSE POSITIVE**

The required DVN loop (lines 96-102) and optional DVN loop (lines 111-120) are independent. A required DVN must verify regardless of how many optional DVNs have verified. There is no mechanism to substitute one for the other.

---

### Hypothesis 2.4: Can confirmations be faked (block.number manipulation)?

**VERDICT: FALSE POSITIVE**

The `confirmations` field in `_verify()` is provided by the DVN when it calls `verify()`. The DVN is trusted to report accurate confirmation counts. The `_verified` function (line 56) checks `verification.confirmations >= _requiredConfirmation`. If a DVN lies about confirmations, it's equivalent to the DVN being malicious, which is the fundamental trust assumption. On-chain, `block.number` manipulation is not relevant because the confirmation count is not derived from on-chain block numbers at the verification step.

---

### Hypothesis 2.5: Can _verifyAndReclaimStorage() leave the system in an inconsistent state?

**VERDICT: FALSE POSITIVE**

**Analysis (ReceiveUlnBase.sol lines 59-77):**

1. `_checkVerifiable` is called FIRST (line 60). If it fails, the function reverts.
2. Only if verification passes, ALL DVN entries (both required and optional) are deleted.
3. This deletion makes the message non-verifiable again, preventing double-commitment.
4. The deletion of optional DVNs that didn't verify simply clears zero-initialized storage -- harmless.
5. After storage reclaim, `commitVerification` calls `endpoint.verify()` which tracks nonces and prevents replay at the endpoint level.

---

### Hypothesis 2.6: Can UlnConfig resolution (custom vs default) be exploited?

**VERDICT: FALSE POSITIVE**

**Analysis (UlnBase.sol lines 74-118):**

The config resolution follows a clear priority:
1. Custom OApp config (if set, i.e., not DEFAULT and not NIL)
2. Default config (if custom is DEFAULT=0)
3. None (if custom is NIL_DVN_COUNT=255)

The `_assertAtLeastOneDVN` check (line 117) ensures the final resolved config always has at least one DVN (either required or optional threshold > 0). The resolution is deterministic and cannot be exploited by external parties. Only the OApp owner (through the endpoint) and the messagelib owner can change configs.

---

### Hypothesis 2.7: Can NIL_DVN_COUNT (255) or DEFAULT (0) values cause misconfigurations?

**VERDICT: FALSE POSITIVE**

**Protection:**

- Default configs CANNOT use NIL values (UlnBase.sol lines 60-62): `if (param.config.requiredDVNCount == NIL_DVN_COUNT) revert`.
- Default configs must have at least one DVN (line 65): `_assertAtLeastOneDVN(param.config)`.
- Custom configs CAN use NIL to explicitly override the default to "none" for that category.
- The `_setConfig` function (lines 151-185) validates array lengths match counts, enforces MAX_COUNT=127, and checks for sorted/unique DVNs.
- The final `_assertAtLeastOneDVN` in `getUlnConfig` (line 117) catches any combination that results in 0 DVNs.

---

### Hypothesis 2.8: Can the MAX_COUNT=127 limit be bypassed?

**VERDICT: FALSE POSITIVE**

The `_setConfig` function (lines 159, 176) explicitly checks: `_param.requiredDVNs.length != _param.requiredDVNCount || _param.requiredDVNCount > MAX_COUNT`. Since MAX_COUNT=127 and there's a separate check for both required and optional, the total DVN count is at most 254, which fits in uint8.

---

## ATTACK VECTOR 3: Executor Exploits

### Hypothesis 3.1: Can execute302() be called by a non-admin to deliver messages?

**VERDICT: FALSE POSITIVE**

**Protection (Executor.sol line 131):** `onlyRole(ADMIN_ROLE)` modifier restricts all execution functions to admin-only. The admin role is managed through AccessControlUpgradeable with DEFAULT_ADMIN_ROLE as the role admin.

---

### Hypothesis 3.2: Can nativeDrop() send native tokens to attacker-controlled addresses?

**VERDICT: FALSE POSITIVE**

**Protection:**

1. `nativeDrop()` requires `onlyRole(ADMIN_ROLE)` (line 112) -- only trusted admins can specify drop recipients.
2. `nonReentrant` guard prevents reentrancy.
3. The gas limit `_nativeDropGasLimit` prevents griefing by recipients.
4. The admin controls all parameters and is trusted to specify legitimate recipients.

---

### Hypothesis 3.3: Can the try/catch in execute302() suppress errors that should propagate?

**VERDICT: FALSE POSITIVE (design trade-off, not vulnerability)**

**Analysis (Executor.sol lines 131-154):**

If `lzReceive` fails, the catch block calls `lzReceiveAlert` on the endpoint, which records the failure for the OApp to handle. This is the INTENDED design: the executor should not be blocked by a failing OApp. The OApp can retry the message through the endpoint's retry mechanism. If `lzReceiveAlert` itself fails, the entire transaction reverts, which is safe.

---

### Hypothesis 3.4: Can compose302() be used to re-enter the executor?

**VERDICT: FALSE POSITIVE**

**Protection (Executor.sol line 164):** `nonReentrant` modifier using OpenZeppelin's ReentrancyGuardUpgradeable. Even if the composed contract tries to call back into the Executor, the reentrancy guard will revert.

---

### Hypothesis 3.5: Can the executor steal msg.value during execution?

**VERDICT: FALSE POSITIVE**

**Analysis:**

In `execute302()` (line 133), `msg.value` is forwarded to `lzReceive`. If lzReceive reverts, the ETH stays in the Executor contract. However, the admin who called `execute302()` is the one who sent the msg.value in the first place. The admin can withdraw any ETH via `withdrawToken(address(0), to, amount)`. The admin is trusted and self-manages funds.

In `nativeDropAndExecute302()` (lines 191-227), if native drops fail, `spent` is overcounted (includes failed drop amounts). The ETH stays in the Executor. This reduces the value sent to `lzReceive` but doesn't result in fund theft -- the admin recovers funds through `withdrawToken`.

---

## ATTACK VECTOR 4: Worker ACL Bypass

### Hypothesis 4.1: Can the denylist > allowlist > deny pattern be bypassed?

**VERDICT: FALSE POSITIVE**

**Analysis (Worker.sol lines 71-79):**

```solidity
function hasAcl(address _sender) public view returns (bool) {
    if (hasRole(DENYLIST, _sender)) {
        return false;
    } else if (allowlistSize == 0 || hasRole(ALLOWLIST, _sender)) {
        return true;
    } else {
        return false;
    }
}
```

The logic is:
1. Denylist takes absolute priority -- if on denylist, always denied.
2. If allowlist is empty (allowlistSize == 0), everyone is allowed (open access).
3. If allowlist is non-empty, only allowlisted addresses pass.

This is a complete evaluation with no gaps. The `else` clause catches all remaining cases with `return false`.

---

### Hypothesis 4.2: Can renounceRole() really not be called? (it reverts, check)

**VERDICT: FALSE POSITIVE (confirmed -- renounce is disabled)**

Both Worker.sol (line 164-166) and WorkerUpgradeable.sol (line 176-178) override `renounceRole` to unconditionally revert:

```solidity
function renounceRole(bytes32 /*role*/, address /*account*/) public pure override {
    revert Worker_RoleRenouncingDisabled();
}
```

The `pure` keyword means it doesn't even read state -- it always reverts. This prevents any role holder from accidentally or maliciously removing their own role.

---

### Hypothesis 4.3: Can allowlistSize tracking go out of sync?

**VERDICT: FALSE POSITIVE**

**Protection (Worker.sol lines 146-161):**

- `_grantRole`: Only increments `allowlistSize` if `_role == ALLOWLIST && !hasRole(_role, _account)` -- prevents double-counting.
- `_revokeRole`: Only decrements `allowlistSize` if `_role == ALLOWLIST && hasRole(_role, _account)` -- prevents under-counting.
- `renounceRole` is disabled, preventing any path that bypasses these checks.
- Both checks happen BEFORE `super._grantRole()`/`super._revokeRole()`, ensuring the count is updated consistently with the actual role state.

---

### Hypothesis 4.4: Can a worker withdraw more fees than accumulated?

**VERDICT: FALSE POSITIVE**

**Analysis:**

The `withdrawFee` function (Worker.sol line 117) delegates to `ISendLib(_lib).withdrawFee(_to, _amount)`. The SendLib's `withdrawFee` function calls `_debitFee(_amount)` (SendLibBase.sol lines 228-234), which:

```solidity
function _debitFee(uint256 _amount) internal {
    uint256 fee = fees[msg.sender];
    if (_amount > fee) revert LZ_MessageLib_InvalidAmount(_amount, fee);
    unchecked {
        fees[msg.sender] = fee - _amount;
    }
}
```

The fee balance is tracked per-worker in the SendLib. The check `_amount > fee` prevents withdrawing more than accumulated. The `unchecked` subtraction is safe because of the preceding check.

---

## ATTACK VECTOR 5: Fee Library Exploits

### Hypothesis 5.1: Can PriceFeed price manipulation cause under/overpayment?

**VERDICT: FALSE POSITIVE (trusted operator model)**

Price updates are restricted to `onlyPriceUpdater` (PriceFeed.sol line 57-64). The priceUpdater is a trusted off-chain service. If compromised, it could set incorrect prices, causing:
- Underpricing: Workers lose money (economic damage, not fund theft)
- Overpricing: Users overpay (excess goes to worker fee pool)

However, neither scenario enables direct fund theft from the protocol. The PriceFeed is upgradeable (`OwnableUpgradeable, Proxied`), and the owner can change the priceUpdater if compromised.

---

### Hypothesis 5.2: Can Treasury.payFee() be manipulated to steal funds?

**VERDICT: FALSE POSITIVE**

`Treasury.payFee()` (line 28-35) is `payable` but only returns a fee quote via `_getFee()`. It doesn't enforce that `msg.value` matches the returned fee. Any ETH sent to `payFee()` accumulates in the Treasury contract, which the owner can withdraw via `withdrawToken()`. The caller (SendLib) handles the accounting separately, using the returned fee value to charge the sender.

---

### Hypothesis 5.3: Can DVNFeeLib or ExecutorFeeLib return 0 fees, causing free execution?

**VERDICT: FALSE POSITIVE**

**DVNFeeLib (line 134):** `if (_dstConfig.gas == 0) revert DVN_EidNotSupported(_params.dstEid)` -- reverts if the destination is not configured with gas parameters.

**ExecutorFeeLib (line 54):** `if (_dstConfig.lzReceiveBaseGas == 0) revert Executor_EidNotSupported(_params.dstEid)` -- same protection.

For configured destinations, the fee computation involves `gasPriceInUnit * gasAmount * priceRatio / denominator + premium`. If the admin sets `gasPriceInUnit=0` or `priceRatio=0` in the PriceFeed, the fee could be 0, but this requires malicious admin action and only results in workers not being compensated -- no fund theft.

---

### Hypothesis 5.4: Can treasuryNativeFeeCap be set to 0 to block all sends?

**VERDICT: FALSE POSITIVE**

Setting `treasuryNativeFeeCap = 0` (via `setTreasuryNativeFeeCap`, SendLibBase.sol line 80) does NOT block sends. The fee computation (SendLibBase.sol lines 219-223):

```solidity
uint256 maxNativeFee = _totalNativeFee > treasuryNativeFeeCap ? _totalNativeFee : treasuryNativeFeeCap;
nativeFee = treasureFeeQuote > maxNativeFee ? maxNativeFee : treasureFeeQuote;
```

If `treasuryNativeFeeCap = 0` but `_totalNativeFee > 0`, then `maxNativeFee = _totalNativeFee`. The treasury can still charge up to the total fee amount. If both are 0, treasury fee is 0 -- sends still work, just without treasury fee.

---

## LOW SEVERITY: PriceFeed._estimateFeeByEid() Double-Computation Bug

### Description

**File:** `/root/defi-audit-targets/audits/layerzero/LayerZero-v2/packages/layerzero-v2/evm/messagelib/contracts/PriceFeed.sol`, lines 238-262

The `_estimateFeeByEid()` function has two sequential fee computation blocks. The first block (lines 244-248) handles hardcoded Arbitrum/Optimism eids (110, 10143, 20143, 111, 10132, 20132) with L2-specific models. The second block (lines 251-258) uses `eidToModelType` lookup. Due to missing `return` statements in the first block, execution ALWAYS falls through to the second block, which OVERWRITES the fee computed by the first block.

**Vulnerable code:**

```solidity
function _estimateFeeByEid(uint32 _dstEid, uint256 _callDataSize, uint256 _gas)
    internal view returns (uint256 fee, uint128 priceRatio, uint128 priceRatioDenominator, uint128 priceUSD)
{
    uint32 dstEid = _dstEid % 30_000;
    // Block 1: Hardcoded L2 handling
    if (dstEid == 110 || dstEid == 10143 || dstEid == 20143) {
        (fee, priceRatio) = _estimateFeeWithArbitrumModel(dstEid, _callDataSize, _gas);
        // BUG: no return statement here
    } else if (dstEid == 111 || dstEid == 10132 || dstEid == 20132) {
        (fee, priceRatio) = _estimateFeeWithOptimismModel(dstEid, _callDataSize, _gas);
        // BUG: no return statement here
    }

    // Block 2: ALWAYS executes, overwrites Block 1's results
    ModelType _modelType = eidToModelType[dstEid];
    if (_modelType == ModelType.OP_STACK) { ... }
    else if (_modelType == ModelType.ARB_STACK) { ... }
    else {
        (fee, priceRatio) = _estimateFeeWithDefaultModel(dstEid, _callDataSize, _gas);
        // DEFAULT model overwrites L2 model for hardcoded eids!
    }
    ...
}
```

**Compare with correct implementation** in `estimateFeeByChain()` (lines 173-194):

```solidity
function estimateFeeByChain(uint16 _dstEid, ...) {
    if (_dstEid == 110 || _dstEid == 10143 || _dstEid == 20143) {
        return _estimateFeeWithArbitrumModel(_dstEid, _callDataSize, _gas);
        // Correct: has return statement
    } else if (_dstEid == 111 || _dstEid == 10132 || _dstEid == 20132) {
        return _estimateFeeWithOptimismModel(_dstEid, _callDataSize, _gas);
        // Correct: has return statement
    }
    ...
}
```

### Impact

- If `eidToModelType[110]` is not explicitly set to `ARB_STACK`, Arbitrum fees are computed with the default model, which ignores L1 data costs. This causes UNDERPAYMENT for DVN/Executor services on Arbitrum.
- Same for Optimism eids if not explicitly set to `OP_STACK`.
- The default model typically computes lower fees for L2s because it doesn't account for L1 calldata posting costs.
- The hardcoded eid checks in Block 1 become dead code (computation is wasted gas).

### Severity: LOW

**Rationale:** This is an operational bug, not a direct exploit. The operator can mitigate by explicitly setting `eidToModelType` for the hardcoded eids. The bug does not enable fund theft, message forgery, or access control bypass. In production, the LayerZero team has likely already set these mappings. The economic impact is limited to fee miscalculation (under-charging workers).

### Recommendation

Add `return` statements in the first block, or remove the dead-code hardcoded checks entirely since the `eidToModelType` lookup covers all cases:

```diff
 function _estimateFeeByEid(uint32 _dstEid, uint256 _callDataSize, uint256 _gas) internal view
     returns (uint256 fee, uint128 priceRatio, uint128 priceRatioDenominator, uint128 priceUSD)
 {
     uint32 dstEid = _dstEid % 30_000;
-    if (dstEid == 110 || dstEid == 10143 || dstEid == 20143) {
-        (fee, priceRatio) = _estimateFeeWithArbitrumModel(dstEid, _callDataSize, _gas);
-    } else if (dstEid == 111 || dstEid == 10132 || dstEid == 20132) {
-        (fee, priceRatio) = _estimateFeeWithOptimismModel(dstEid, _callDataSize, _gas);
-    }
-
     // lookup map stuff
     ModelType _modelType = eidToModelType[dstEid];
     if (_modelType == ModelType.OP_STACK) {
```

---

## Summary Table

| # | Hypothesis | Verdict | Severity |
|---|-----------|---------|----------|
| 1.1 | Forged signatures in DVN.execute() | FALSE POSITIVE | N/A |
| 1.2 | usedHashes exploit via failure-unset | FALSE POSITIVE | N/A |
| 1.3 | _shouldCheckHash skipping dangerous ops | FALSE POSITIVE | N/A |
| 1.4 | quorumChangeAdmin bypass | FALSE POSITIVE | N/A |
| 1.5 | Signature malleability | FALSE POSITIVE | N/A |
| 1.6 | Sorted-signer bypass | FALSE POSITIVE | N/A |
| 1.7 | DVN verify with false data | FALSE POSITIVE (by design) | N/A |
| 2.1 | Fewer DVNs than required | FALSE POSITIVE | N/A |
| 2.2 | Optional DVN double-counting | FALSE POSITIVE | N/A |
| 2.3 | Required/optional DVN substitution | FALSE POSITIVE | N/A |
| 2.4 | Confirmation count faking | FALSE POSITIVE (trust model) | N/A |
| 2.5 | Inconsistent state after reclaim | FALSE POSITIVE | N/A |
| 2.6 | UlnConfig resolution exploit | FALSE POSITIVE | N/A |
| 2.7 | NIL_DVN_COUNT/DEFAULT misconfiguration | FALSE POSITIVE | N/A |
| 2.8 | MAX_COUNT=127 bypass | FALSE POSITIVE | N/A |
| 3.1 | Non-admin execute302() | FALSE POSITIVE | N/A |
| 3.2 | nativeDrop to attacker addresses | FALSE POSITIVE | N/A |
| 3.3 | try/catch error suppression | FALSE POSITIVE (design) | N/A |
| 3.4 | compose302() reentrancy | FALSE POSITIVE | N/A |
| 3.5 | Executor msg.value theft | FALSE POSITIVE | N/A |
| 4.1 | ACL denylist>allowlist bypass | FALSE POSITIVE | N/A |
| 4.2 | renounceRole() not disabled | FALSE POSITIVE (confirmed disabled) | N/A |
| 4.3 | allowlistSize desync | FALSE POSITIVE | N/A |
| 4.4 | Worker withdraw excess fees | FALSE POSITIVE | N/A |
| 5.1 | PriceFeed price manipulation | FALSE POSITIVE (trust model) | N/A |
| 5.2 | Treasury.payFee() manipulation | FALSE POSITIVE | N/A |
| 5.3 | Zero-fee execution | FALSE POSITIVE | N/A |
| 5.4 | treasuryNativeFeeCap=0 blocking sends | FALSE POSITIVE | N/A |
| -- | PriceFeed double-computation | CONFIRMED (code defect) | LOW |

**Final result: 0 critical/high findings. 1 low-severity code defect (PriceFeed dead-code overwrite). 28 false positives with protection mechanisms documented.**
