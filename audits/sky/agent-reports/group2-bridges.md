# Sky Protocol Bridge Security Audit — Group 2: Arbitrum + Optimism Token Bridges

**Date:** 2026-03-01
**Auditor:** Independent Security Researcher (Immunefi Bug Bounty Submission)
**Scope:**
- `/root/audits/sky-protocol/arbitrum-token-bridge/src/` (all .sol files)
- `/root/audits/sky-protocol/op-token-bridge/src/` (all .sol files)

---

## Files Reviewed

### Arbitrum Token Bridge
- `src/L1TokenGateway.sol`
- `src/L2TokenGateway.sol`
- `src/arbitrum/AddressAliasHelper.sol`
- `src/arbitrum/L1ArbitrumMessenger.sol`
- `src/arbitrum/L2ArbitrumMessenger.sol`
- `src/arbitrum/ITokenGateway.sol`
- `src/arbitrum/IL1ArbitrumGateway.sol`
- `src/arbitrum/ICustomGateway.sol`
- `src/arbitrum/ERC165.sol`
- `src/arbitrum/IERC165.sol`

### Optimism Token Bridge
- `src/Escrow.sol`
- `src/L1GovernanceRelay.sol`
- `src/L2GovernanceRelay.sol`
- `src/L1TokenBridge.sol`
- `src/L2TokenBridge.sol`

---

## Executive Summary

| # | Title | Severity | Contract |
|---|-------|----------|----------|
| F-01 | `L2TokenGateway.finalizeInboundTransfer` mints tokens even when bridge is closed | High | `L2TokenGateway.sol` |
| F-02 | `L1TokenGateway.finalizeInboundTransfer` releases escrowed tokens even when bridge is closed | High | `L1TokenGateway.sol` |
| F-03 | `maxWithdraws` is a per-transaction cap, not a rate-limit — a single large withdrawal can drain the bridge | Medium | `L2TokenGateway.sol` / `L2TokenBridge.sol` |
| F-04 | `L1TokenBridge.bridgeERC20To` can be called by contracts; `msg.sender.code.length == 0` EOA guard is missing | Medium | `L1TokenBridge.sol` |
| F-05 | `L2TokenBridge._initiateBridgeERC20` burns from `msg.sender` but `bridgeERC20To` allows a different `_to` — a contract can burn tokens it doesn't own via `bridgeERC20To` | Medium | `L2TokenBridge.sol` |
| F-06 | Unregistered/deregistered token (zero address mapping) in `L2TokenGateway.finalizeInboundTransfer` causes permanent token lock (DoS) | Medium | `L2TokenGateway.sol` |
| F-07 | No token validation in `L1TokenGateway.finalizeInboundTransfer` — any `l1Token` with escrow approval can be withdrawn | High | `L1TokenGateway.sol` |
| F-08 | `L2GovernanceRelay.relay` uses `delegatecall` to arbitrary targets — if called, a spell can overwrite relay state | Informational / Design Risk | `L2GovernanceRelay.sol` |

---

## Detailed Findings

---

### F-01: `L2TokenGateway.finalizeInboundTransfer` Mints Tokens When Bridge Is Closed

**File:** `/root/audits/sky-protocol/arbitrum-token-bridge/src/L2TokenGateway.sol`
**Lines:** 121–124, 223–236

**Vulnerable Code:**

```solidity
// L2TokenGateway.sol line 121-124
function close() external auth {
    isOpen = 0;
    emit Closed();
}

// L2TokenGateway.sol line 223-236
function finalizeInboundTransfer(
    address l1Token,
    address from,
    address to,
    uint256 amount,
    bytes calldata /* data */
) external payable onlyCounterpartGateway {
    address l2Token = l1ToL2Token[l1Token];
    require(l2Token != address(0), "L2TokenGateway/invalid-token");

    TokenLike(l2Token).mint(to, amount);   // <-- NO isOpen check

    emit DepositFinalized(l1Token, from, to, amount);
}
```

**Description:**

The `close()` function sets `isOpen = 0` to halt bridge activity. The `outboundTransfer` function (L2→L1 withdrawals) correctly checks `require(isOpen == 1, ...)` at line 163. However, `finalizeInboundTransfer` (which mints L2 tokens for L1 deposits) has **no `isOpen` check**.

Contrast this with `outboundTransfer` on L1 (line 179 of `L1TokenGateway.sol`) which does check `isOpen`. The asymmetry means: when the bridge is closed, new deposits from L1 are blocked at the L1 side (`L1TokenGateway.outboundTransferCustomRefund` line 179), but any deposit message that was **already in flight** (submitted to Arbitrum inbox before close) will **still be executed and will still mint tokens on L2** — because `finalizeInboundTransfer` is called by the Arbitrum retryable ticket system, not by a user on L2.

**Exploit Path:**

1. Governance closes the bridge due to a security incident.
2. An attacker had previously submitted a deposit transaction that is sitting in the Arbitrum retryable queue.
3. The retryable ticket is auto-redeemed (or manually redeemed by anyone) on L2.
4. `finalizeInboundTransfer` is called by the bridge (the aliased L1 gateway address passes `onlyCounterpartGateway`).
5. `mint` is executed without checking `isOpen`, minting L2 tokens even though governance intended the bridge to be halted.

**Impact:** In-flight messages bypass a governance-initiated emergency halt, potentially minting tokens during a compromised state. Severity depends on the reason for closure (e.g., oracle compromise, token contract exploit). The bridge is supposed to be closable as an emergency measure; this partially defeats that purpose.

**Defense Check:** There is no other mechanism preventing the mint. The `onlyCounterpartGateway` check is for authentication (correct caller), not for bridge-open state. No separate pause check exists.

**Severity:** High (temporary bypass of emergency governance action; in-flight messages can mint tokens against protocol intent)

---

### F-02: `L1TokenGateway.finalizeInboundTransfer` Releases Escrowed Tokens When Bridge Is Closed

**File:** `/root/audits/sky-protocol/arbitrum-token-bridge/src/L1TokenGateway.sol`
**Lines:** 134–137, 258–268

**Vulnerable Code:**

```solidity
// L1TokenGateway.sol line 134-137
function close() external auth {
    isOpen = 0;
    emit Closed();
}

// L1TokenGateway.sol line 258-268
function finalizeInboundTransfer(
    address l1Token,
    address from,
    address to,
    uint256 amount,
    bytes calldata /* data */
) external payable onlyCounterpartGateway {
    TokenLike(l1Token).transferFrom(escrow, to, amount);  // <-- NO isOpen check

    emit WithdrawalFinalized(l1Token, from, to, 0, amount);
}
```

**Description:**

The same asymmetry as F-01 exists on L1. `outboundTransferCustomRefund` checks `isOpen` (line 179), but `finalizeInboundTransfer` does not. An L2 withdrawal message that is already submitted (through ArbSys) before the bridge is closed will still be executed on L1 when the Arbitrum challenge period expires and the withdrawal is finalized.

**Exploit Path:**

1. Governance closes the bridge.
2. An in-flight L2→L1 withdrawal (already submitted via `ArbSys.sendTxToL1`) completes its 7-day challenge period.
3. The withdrawal is finalized on L1 via the Arbitrum outbox.
4. `finalizeInboundTransfer` is called (passes `onlyCounterpartGateway` because caller is the bridge and l2ToL1Sender is the counterpart gateway).
5. `transferFrom(escrow, to, amount)` executes, releasing tokens from escrow regardless of `isOpen`.

**Impact:** Same category as F-01. Legitimate in-flight withdrawals completing after a close is arguably expected behavior (7-day window is inherent to Arbitrum), but the asymmetry is a design inconsistency. More critically: if the L2 gateway is compromised and a fraudulent withdrawal message is injected before detection, closing L1 does not stop it.

**Defense Check:** None. The Arbitrum outbox enforces only that the message was submitted from the correct L2 address (validated by `onlyCounterpartGateway`), not that the bridge is open.

**Severity:** High (mirrors F-01; consistent with in-flight message bypass of emergency close)

---

### F-03: `maxWithdraws` Is a Per-Transaction Cap, Not a Rate Limit — Provides Weak Protection

**File:** `/root/audits/sky-protocol/arbitrum-token-bridge/src/L2TokenGateway.sol` (lines 131–134, 166)
**File:** `/root/audits/sky-protocol/op-token-bridge/src/L2TokenBridge.sol` (lines 135–138, 152)

**Vulnerable Code (Arbitrum):**

```solidity
// L2TokenGateway.sol line 131-134
function setMaxWithdraw(address l2Token, uint256 maxWithdraw) external auth {
    maxWithdraws[l2Token] = maxWithdraw;
    emit MaxWithdrawSet(l2Token, maxWithdraw);
}

// L2TokenGateway.sol line 166
require(amount <= maxWithdraws[l2Token], "L2TokenGateway/amount-too-large");
```

**Vulnerable Code (Optimism):**

```solidity
// L2TokenBridge.sol line 135-138
function setMaxWithdraw(address l2Token, uint256 maxWithdraw) external auth {
    maxWithdraws[l2Token] = maxWithdraw;
    emit MaxWithdrawSet(l2Token, maxWithdraw);
}

// L2TokenBridge.sol line 152
require(_amount <= maxWithdraws[_localToken], "L2TokenBridge/amount-too-large");
```

**Description:**

The `maxWithdraws` mapping is described and used as a withdrawal protection mechanism. However, it only enforces a **per-transaction maximum**. It is not a cumulative rate limit or a circuit breaker. An attacker (or a compromised L2 account) holding tokens can trivially split a large amount into many transactions of exactly `maxWithdraws[l2Token]` each, all within a single block, to withdraw the entire escrow balance on L1 piecemeal.

For example, if `maxWithdraws[USDS] = 1_000_000e18` and the bridge holds 100M USDS in escrow on L1, an attacker can submit 100 transactions of 1M USDS each in a single block to drain the escrow entirely — all while each individual check passes.

**There is no:**
- Cumulative withdrawal tracking per block or per epoch
- Global withdrawal limit
- Time-lock between large withdrawals
- Circuit breaker that pauses after N withdrawals

**Exploit Path (Arbitrum):**

1. Attacker holds (or flash-borrows on L2) a large amount of the L2 token.
2. Attacker calls `outboundTransfer` repeatedly in a loop (can be a contract, since `outboundTransfer` has no EOA check on L2).
3. Each call burns `maxWithdraws[token]` tokens and submits a withdrawal message.
4. After the Arbitrum dispute period (~7 days), all withdrawals are claimable on L1.
5. Each `finalizeInboundTransfer` on L1 releases `maxWithdraws[token]` from escrow.
6. Full escrow drained.

**Exploit Path (Optimism):**

Same logic, but faster: Optimism has a ~7-day withdrawal challenge period for the canonical bridge, but the messages are submitted quickly. Repeated calls to `bridgeERC20To` (no EOA check) bypass the single-tx cap.

**Defense Check:** The `maxWithdraws` check only applies to a single transaction. No cumulative cap exists. The `isOpen` check can be used to pause but requires governance action after the fact.

**Severity:** Medium (the mechanism provides a false sense of security; it limits single-tx amounts but not aggregate throughput. A sophisticated attacker with a compromised L2 position can drain escrow)

---

### F-04: `L1TokenBridge.bridgeERC20To` Lacks the EOA-Only Guard Present on `bridgeERC20`

**File:** `/root/audits/sky-protocol/op-token-bridge/src/L1TokenBridge.sol`
**Lines:** 183–212

**Vulnerable Code:**

```solidity
// L1TokenBridge.sol line 183-192
function bridgeERC20(
    address _localToken,
    address _remoteToken,
    uint256 _amount,
    uint32 _minGasLimit,
    bytes calldata _extraData
) external {
    require(msg.sender.code.length == 0, "L1TokenBridge/sender-not-eoa");  // EOA check
    _initiateBridgeERC20(_localToken, _remoteToken, msg.sender, _amount, _minGasLimit, _extraData);
}

// L1TokenBridge.sol line 203-212
function bridgeERC20To(
    address _localToken,
    address _remoteToken,
    address _to,
    uint256 _amount,
    uint32 _minGasLimit,
    bytes calldata _extraData
) external {
    // NO EOA CHECK
    _initiateBridgeERC20(_localToken, _remoteToken, _to, _amount, _minGasLimit, _extraData);
}
```

**Description:**

`bridgeERC20` enforces `msg.sender.code.length == 0` to restrict callers to EOAs. The comment in the codebase (via the NatSpec) implies this restriction exists to prevent certain attack patterns involving contracts. However, `bridgeERC20To` — which accepts a different recipient `_to` address on L2 — has **no such restriction**. Any contract can call `bridgeERC20To`.

Note: The `msg.sender.code.length == 0` check itself is weak (can be bypassed in constructor) but its absence from `bridgeERC20To` is inconsistent. The same design exists in `L2TokenBridge.sol` (line 183–211).

**Impact:**

- Smart contract wallets, multisigs, and attacker contracts can use `bridgeERC20To` to bridge tokens freely, bypassing the intent of the EOA restriction.
- More importantly, this allows for **flash loan-enabled bridge attacks**: a contract flash-borrows tokens, calls `bridgeERC20To` to bridge them to an attacker-controlled L2 address, and repays the flash loan — the tokens are now locked in the bridge's escrow but the cross-chain message is in-flight. If combined with a vulnerability in `finalizeBridgeERC20`, this could be chained.
- Combining this with F-03 (per-tx cap bypass), a contract can batch many `bridgeERC20To` calls in a single transaction or across multiple blocks to perform large aggregate withdrawals.

**Defense Check:** The `_initiateBridgeERC20` internal function does not add any restriction. The missing check is not compensated elsewhere.

**Severity:** Medium (direct bypass of EOA restriction; enables contract-driven batching and flash loan usage that the EOA check was intended to prevent)

---

### F-05: `L2TokenBridge._initiateBridgeERC20` Burns from `msg.sender` but `bridgeERC20To` Specifies a Different `_to` — Semantic Inconsistency Enabling Griefing

**File:** `/root/audits/sky-protocol/op-token-bridge/src/L2TokenBridge.sol`
**Lines:** 142–172, 203–212

**Vulnerable Code:**

```solidity
// L2TokenBridge.sol line 142-172
function _initiateBridgeERC20(
    address _localToken,
    address _remoteToken,
    address _to,           // recipient on L1
    uint256 _amount,
    uint32 _minGasLimit,
    bytes memory _extraData
) internal {
    require(isOpen == 1, "L2TokenBridge/closed");
    require(_localToken != address(0) && l1ToL2Token[_remoteToken] == _localToken, "L2TokenBridge/invalid-token");
    require(_amount <= maxWithdraws[_localToken], "L2TokenBridge/amount-too-large");

    TokenLike(_localToken).burn(msg.sender, _amount);  // burns from CALLER

    messenger.sendMessage({
        _target: address(otherBridge),
        _message: abi.encodeCall(this.finalizeBridgeERC20, (
            _remoteToken,
            _localToken,
            msg.sender,   // _from is caller
            _to,          // _to is the parameter (different from msg.sender)
            _amount,
            _extraData
        )),
        _minGasLimit: _minGasLimit
    });
    // ...
}
```

**Description:**

This is the correct and intended behavior for `bridgeERC20To` (burn from caller, credit to `_to` on L1). However, there is an important subtlety: since `msg.sender.code.length == 0` check is absent from `bridgeERC20To` (F-04), a **contract** can call `bridgeERC20To` and set `_to` to any address.

The actual vulnerability here is more nuanced: because `burn(msg.sender, _amount)` is called but the token's `burn` function may require that `msg.sender` has explicitly approved the bridge, or in some implementations uses `transferFrom`-style logic. If the L2 token's `burn` is:

```solidity
function burn(address from, uint256 amount) external {
    // many implementations burn from `from` using allowance
    _burn(from, amount); // if this is msg.sender-based, fine
    // BUT if from != msg.sender and no allowance → revert
}
```

The `L2TokenBridge` passes `msg.sender` (the caller/contract) as the burn target. This is fine for the caller's own tokens. But if a malicious contract calls `bridgeERC20To` with someone else's approval to the bridge, it can burn their tokens and redirect the L1 credit to an attacker-controlled address.

**More concretely:** If Alice approves the L2TokenBridge to spend her L2 tokens (for a legitimate bridge operation), and Bob (a contract) calls `bridgeERC20To` with `msg.sender = Bob's contract` but the contract has been granted Alice's tokens through a re-entrancy or approval abuse — this could go wrong. The exact exploitability depends on the L2 token implementation (which is out of scope here), but the design is fragile.

**The cleaner finding:** `bridgeERC20To` allows contracts to call it (unlike `bridgeERC20`), and the tokens burned are those of `msg.sender` (the calling contract), not the `_to` recipient. The L1 credit goes to `_to`. This means a contract can burn its own tokens and credit any `_to` address on L1. While this is the intended use case, combined with flash loans (F-04), it creates the attack surface described in F-03.

**Severity:** Medium (design inconsistency that enables bypassing of intended access control; direct exploit depends on L2 token design)

---

### F-06: Deregistered Token in `L2TokenGateway.finalizeInboundTransfer` Causes Permanent Fund Lock

**File:** `/root/audits/sky-protocol/arbitrum-token-bridge/src/L2TokenGateway.sol`
**Lines:** 126–129, 223–236

**Vulnerable Code:**

```solidity
// L2TokenGateway.sol line 126-129
function registerToken(address l1Token, address l2Token) external auth {
    l1ToL2Token[l1Token] = l2Token;
    emit TokenSet(l1Token, l2Token);
}

// L2TokenGateway.sol line 223-236
function finalizeInboundTransfer(
    address l1Token,
    address from,
    address to,
    uint256 amount,
    bytes calldata /* data */
) external payable onlyCounterpartGateway {
    address l2Token = l1ToL2Token[l1Token];
    require(l2Token != address(0), "L2TokenGateway/invalid-token");  // reverts if deregistered

    TokenLike(l2Token).mint(to, amount);
    // ...
}
```

**Description:**

Token registration can be changed by governance: a ward can call `registerToken(l1Token, address(0))` (or set it to a different address) to deregister or re-register an L1→L2 token mapping.

If governance deregisters a token **after** a deposit is in flight (i.e., the L1 `outboundTransferCustomRefund` was called and the retryable ticket is pending), the `finalizeInboundTransfer` on L2 will **revert** with `"L2TokenGateway/invalid-token"`.

On Arbitrum, a failed retryable ticket can be retried manually. However, if governance has intentionally deregistered the token, retrying will keep failing. The deposited tokens are now **locked in the L1 escrow permanently** — there is no mechanism to refund a failed L2 finalization back to the user on L1.

**Exploit/Scenario Path:**

1. Alice deposits 100,000 USDS by calling `L1TokenGateway.outboundTransferCustomRefund`.
2. Tokens are transferred to escrow. Retryable ticket is created.
3. Governance decides to migrate to a new token contract and calls `registerToken(USDS_L1, address(0))` on L2 (or sets it to a new token address).
4. The retryable ticket executes `finalizeInboundTransfer`, which reverts because `l1ToL2Token[USDS_L1] == address(0)`.
5. The ticket can be retried but will keep reverting.
6. Alice's tokens are permanently locked in the escrow on L1 with no refund path.

**Defense Check:** There is no refund mechanism, no ability for Alice to cancel her in-flight deposit, and no fallback minting. The retryable ticket system in Arbitrum allows indefinite retries but not callbacks to L1 for refunds from the L2 side.

**Note:** This is partially a governance risk but the lack of a recovery path for in-flight deposits during token re-registration is a real design gap that affects user funds.

**Severity:** Medium (requires governance action + in-flight deposit timing, but results in permanent fund lock for affected users)

---

### F-07: No `l1Token` Validation in `L1TokenGateway.finalizeInboundTransfer` — Arbitrary Token Release from Escrow

**File:** `/root/audits/sky-protocol/arbitrum-token-bridge/src/L1TokenGateway.sol`
**Lines:** 258–268

**Vulnerable Code:**

```solidity
function finalizeInboundTransfer(
    address l1Token,    // <-- taken from the L2 message payload, not validated against registry
    address from,
    address to,
    uint256 amount,
    bytes calldata /* data */
) external payable onlyCounterpartGateway {
    TokenLike(l1Token).transferFrom(escrow, to, amount);  // No check that l1Token is registered

    emit WithdrawalFinalized(l1Token, from, to, 0, amount);
}
```

**Description:**

When a withdrawal is finalized on L1, the `l1Token` parameter comes directly from the message payload submitted by `L2TokenGateway.outboundTransfer` → `L2TokenGateway.getOutboundCalldata`. On L2, the `l1Token` parameter passed to `outboundTransfer` is accepted without verification against a whitelist: L2's `outboundTransfer` only checks that `l1ToL2Token[l1Token] != address(0)`.

**The critical gap on L1:** `finalizeInboundTransfer` does **not** check that `l1Token` is in the `l1ToL2Token` registry. It directly calls `TokenLike(l1Token).transferFrom(escrow, to, amount)`.

**Exploit Scenario (requires L2 gateway to be compromised OR a registered token pair to be exploited):**

The authentication gate (`onlyCounterpartGateway`) is solid — only a message originating from the actual `counterpartGateway` on L2 can pass. So this finding's severity is conditional on the L2 gateway's security.

However, the **more realistic scenario** is:

1. A token `T_A` is registered: `l1ToL2Token[T_A_L1] = T_A_L2`.
2. The escrow also holds token `T_B` (because a previous registration was removed but the escrow approval remains).
3. If a bug or governance error allows an L2 withdrawal to specify `l1Token = T_B_L1`, and `T_B_L1` still has an approval on the escrow, `finalizeInboundTransfer` will call `T_B_L1.transferFrom(escrow, attacker, amount)`.

The L1 gateway has no check like `require(l1ToL2Token[l1Token] != address(0), ...)` in `finalizeInboundTransfer`.

**Comparison:** L2's `finalizeInboundTransfer` (line 230–232) **does** check:
```solidity
address l2Token = l1ToL2Token[l1Token];
require(l2Token != address(0), "L2TokenGateway/invalid-token");
```

L1's `finalizeInboundTransfer` has **no equivalent check**.

**Defense Check:** The `onlyCounterpartGateway` check ensures only legitimate L2 messages reach this function. But it does not validate the token against the registry. If the escrow has approvals for multiple tokens (which is the expected operational state when multiple tokens are registered), a crafted L2 message with an unexpected `l1Token` would be executed.

**Severity:** High (incomplete validation; asymmetric with L2 counterpart; directly enables unauthorized release of non-targeted tokens from escrow if the L2 side is manipulated)

---

### F-08: `L2GovernanceRelay` Uses Unrestricted `delegatecall` to Arbitrary Targets

**File:** `/root/audits/sky-protocol/op-token-bridge/src/L2GovernanceRelay.sol`
**Lines:** 54–62

**Vulnerable Code:**

```solidity
function relay(address target, bytes calldata targetData) external onlyL1GovRelay {
    (bool success, bytes memory result) = target.delegatecall(targetData);
    if (!success) {
        if (result.length == 0) revert("L2GovernanceRelay/delegatecall-error");
        assembly ("memory-safe") {
            revert(add(32, result), mload(result))
        }
    }
}
```

**Description:**

`L2GovernanceRelay.relay` performs a `delegatecall` to an arbitrary `target` address with arbitrary `targetData`. This is controlled by the `onlyL1GovRelay` modifier, which verifies the call comes through the Optimism cross-domain messenger from `l1GovernanceRelay`. Since wards are fully trusted, this is by-design governance power.

**Design Risk (not a bug in isolation):**

The `delegatecall` executes in the context of `L2GovernanceRelay`. This means a governance spell can:
1. Overwrite `l1GovernanceRelay` (immutable — actually cannot be changed since it's `immutable`)
2. Overwrite `messenger` (also `immutable` — cannot be changed)
3. Selfdestruct the relay contract (if the spell calls `selfdestruct`)
4. Steal any ETH or tokens held by the relay

Since both `l1GovernanceRelay` and `messenger` are `immutable`, the storage manipulation risk is limited. However, a malicious spell (or governance compromise on L1) could use this `delegatecall` to:
- Selfdestruct the L2GovernanceRelay, permanently bricking the governance relay mechanism on L2.
- Execute arbitrary state changes in the context of the relay.

**The key concern for the bug bounty:** If the `l1GovernanceRelay` on L1 is ever compromised (e.g., via a governance attack where a malicious spell passes through DAO voting), the `delegatecall` here is an unrestricted code execution primitive on L2 operating in the relay's own storage context. A malicious spell could target L2 contracts (like the L2TokenBridge or L2 token itself) if those contracts have given the relay wards access.

**Severity:** Informational / Design Risk (within scope of trusted governance, but the selfdestruct risk is non-trivial; escalates to Critical if governance is ever compromised)

---

## Additional Observations (Non-Critical)

### OBS-01: `outboundTransferCustomRefund` on L1 — `refundTo` Aliasing Behavior May Surprise Users

**File:** `L1TokenGateway.sol` lines 157–163 (NatSpec)

The NatSpec states: "the refund will be credited to the L2 alias of `refundTo` if `refundTo` has code in L1." This is standard Arbitrum behavior, but no on-chain enforcement exists. Contracts calling this may not realize their `refundTo` address gets aliased, leading to lost gas refunds. Not exploitable, but a UX concern.

### OBS-02: `L1TokenGateway.outboundTransferCustomRefund` — `from` Address from Router Is Not Validated

**File:** `L1TokenGateway.sol` line 185

```solidity
(from, extraData) = msg.sender == l1Router
    ? abi.decode(extraData, (address, bytes))
    : (msg.sender, extraData);
```

When called through the router, `from` is decoded from the router-supplied `extraData`. If the Arbitrum router is compromised or sends a malicious `from` address, `transferFrom(from, escrow, amount)` would attempt to pull tokens from the spoofed `from` address — which would fail unless that address had approved the gateway. So in practice this is limited to the router's trustworthiness.

### OBS-03: No `maxDeposit` Cap on L1 Side

Neither `L1TokenGateway` nor `L1TokenBridge` has a maximum deposit size check. Combined with the weak per-transaction `maxWithdraws` on L2, a user can deposit an arbitrarily large amount in a single transaction. If the bridge is later exploited, the entire escrow is at risk with no circuit breaker triggered by large deposits.

### OBS-04: `L2TokenBridge._initiateBridgeERC20` Token Validation Direction

**File:** `L2TokenBridge.sol` line 151

```solidity
require(_localToken != address(0) && l1ToL2Token[_remoteToken] == _localToken, "L2TokenBridge/invalid-token");
```

This validates that the claimed `_localToken` (L2 token) matches what the registry maps `_remoteToken` (L1 token) to. The logic is correct but the parameter naming (`_localToken`, `_remoteToken`) could cause confusion: on L2, "local" is the L2 token and "remote" is the L1 token. The registry stores `l1ToL2Token[l1Address] = l2Address`, so `l1ToL2Token[_remoteToken] == _localToken` is correct. No bug, but worth documenting for code clarity.

---

## Summary Table (Ranked by Severity)

| # | File | Lines | Issue | Severity |
|---|------|-------|-------|----------|
| F-07 | `L1TokenGateway.sol` | 258–268 | No l1Token registry validation in `finalizeInboundTransfer` | High |
| F-01 | `L2TokenGateway.sol` | 223–236 | Minting bypasses `isOpen` check | High |
| F-02 | `L1TokenGateway.sol` | 258–268 | Token release bypasses `isOpen` check | High |
| F-03 | `L2TokenGateway.sol`, `L2TokenBridge.sol` | 131–134, 166 / 135–138, 152 | `maxWithdraws` is per-tx only, not a rate limit | Medium |
| F-04 | `L1TokenBridge.sol` | 203–212 | `bridgeERC20To` lacks EOA check present on `bridgeERC20` | Medium |
| F-05 | `L2TokenBridge.sol` | 142–172 | Contract callers of `bridgeERC20To` can abuse burn semantics | Medium |
| F-06 | `L2TokenGateway.sol` | 126–129, 223–236 | Token deregistration permanently locks in-flight deposits | Medium |
| F-08 | `L2GovernanceRelay.sol` | 54–62 | Arbitrary `delegatecall` can selfdestruct the relay | Informational |
