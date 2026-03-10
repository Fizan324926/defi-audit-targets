# LayerZero V2 OFT/OApp Deep Security Audit Report

**Date:** 2026-03-02
**Scope:** OFT, OFTAdapter, OFTCore, OApp, PreCrime, Options, Compose (EVM)
**Repositories:**
- `LayerZero-v2/packages/layerzero-v2/evm/oapp/contracts/` (main V2)
- `devtools/packages/oft-evm/contracts/` (devtools reference)
- `LayerZero-v2/packages/layerzero-v2/evm/protocol/contracts/` (endpoint)

---

## Executive Summary

After a thorough line-by-line review of all 6 attack vectors across ~30 contracts, **zero confirmed critical/high exploitable vulnerabilities** were found in the default OFT/OApp implementations. One **LOW severity design gap** was identified in the main V2 OFTCore (silent uint64 truncation in `_toSD`), which was subsequently fixed in the devtools version. The remaining hypotheses were all confirmed as false positives with specific protection mechanisms documented below.

---

## ATTACK VECTOR 1: OFT Decimal Conversion Exploits

### Hypothesis 1.1: Can `_toSD()` / `_toLD()` precision loss be exploited to mint more tokens than burned?

**VERDICT: FALSE POSITIVE (with one LOW-severity caveat for V2 main)**

**Analysis of the send flow:**

1. `send()` calls `_debit()`, which calls `_debitView()`.
2. `_debitView()` calls `_removeDust(_amountLD)` first, producing `amountSentLD` (dust-free).
3. `amountSentLD == amountReceivedLD` in the default implementation.
4. `_debit()` burns `amountSentLD` from the sender.
5. `_buildMsgAndOptions()` encodes `_toSD(amountReceivedLD)` into the message.
6. On the receive side, `_lzReceive()` decodes `_message.amountSD()` and calls `_toLD(amountSD)`.
7. `_credit()` mints `_toLD(amountSD)`.

**Protection mechanism:** Since `amountReceivedLD` was already dust-removed (it equals `amountSentLD = _removeDust(_amountLD)`), the `_toSD()` division is exact -- no precision loss occurs. Specifically:
- `_removeDust(x) = (x / rate) * rate`
- `_toSD(_removeDust(x)) = _removeDust(x) / rate = (x / rate) * rate / rate = x / rate` (exact integer)
- `_toLD(_toSD(_removeDust(x))) = (x / rate) * rate = _removeDust(x) = amountSentLD`

The round-trip is lossless for dust-removed amounts. The amount minted on destination exactly equals the amount burned on source.

**Caveat (LOW severity) -- V2 main OFTCore silent uint64 truncation:**

File: `/root/defi-audit-targets/audits/layerzero/LayerZero-v2/packages/layerzero-v2/evm/oapp/contracts/oft/OFTCore.sol`, line 335-337

```solidity
function _toSD(uint256 _amountLD) internal view virtual returns (uint64 amountSD) {
    return uint64(_amountLD / decimalConversionRate);
}
```

This performs a **silent truncation** via `uint64()` cast. If `_amountLD / decimalConversionRate > type(uint64).max`, the value wraps around silently. The devtools version (file: `/root/defi-audit-targets/audits/layerzero/devtools/packages/oft-evm/contracts/OFTCore.sol`, lines 364-368) fixes this:

```solidity
function _toSD(uint256 _amountLD) internal view virtual returns (uint64 amountSD) {
    uint256 _amountSD = _amountLD / decimalConversionRate;
    if (_amountSD > type(uint64).max) revert AmountSDOverflowed(_amountSD);
    return uint64(_amountSD);
}
```

**Exploitability:** With the default `sharedDecimals=6` and `localDecimals=18`, overflow requires > 18.4 trillion tokens in a single transfer, which exceeds the total supply of virtually all tokens. If a deployer overrides `sharedDecimals()` to equal `localDecimals()` (e.g., both 18), the overflow ceiling drops to ~18.4 tokens -- but this is a non-default, custom configuration that would be immediately apparent in testing. **Not practically exploitable with default parameters.**

### Hypothesis 1.2: Can `_removeDust()` leave dust that accumulates over time?

**VERDICT: FALSE POSITIVE**

`_removeDust()` is called in `_debitView()` and the dust-removed amount is what gets burned/locked. The "dust" (the fractional part below the shared-decimal precision) is simply never taken from the sender. The sender keeps their dust. There is no accumulation inside the contract -- the user's balance retains the unrepresentable fraction.

```solidity
// _debitView:
amountSentLD = _removeDust(_amountLD); // dust stays with sender
_burn(_from, amountSentLD);            // only burn the clean amount
```

### Hypothesis 1.3: Can `decimalConversionRate` be set to cause overflow in multiplication?

**VERDICT: FALSE POSITIVE**

`decimalConversionRate` is `immutable`, set in the constructor as `10 ** (_localDecimals - sharedDecimals())`. Since `_localDecimals` is `uint8` (max 255) and `sharedDecimals()` defaults to 6, the maximum conversion rate is `10^249`. However, the constructor also requires `_localDecimals >= sharedDecimals()`, so the exponent is non-negative.

The multiplication in `_toLD()` is `uint64 * uint256`, which cannot overflow in Solidity 0.8+ for any realistic conversion rate, since `uint64_max * 10^249` fits within `uint256`. No overflow is possible.

### Hypothesis 1.4: Can `sharedDecimals() > localDecimals` cause underflow in constructor?

**VERDICT: FALSE POSITIVE**

The constructor explicitly checks:
```solidity
if (_localDecimals < sharedDecimals()) revert InvalidLocalDecimals();
```

This reverts deployment if `sharedDecimals > localDecimals`, preventing any underflow in the subtraction `_localDecimals - sharedDecimals()`.

### Hypothesis 1.5: Can an attacker send 0 tokens (after dust removal) but trigger a credit on the other side?

**VERDICT: FALSE POSITIVE**

If a user sends an amount where `_removeDust(amountLD) == 0`, then `amountSentLD = 0` and `amountReceivedLD = 0`. The slippage check `amountReceivedLD < _minAmountLD` would only pass if `_minAmountLD == 0`. Even if 0 passes slippage:
1. `_debit` burns 0 tokens (no-op).
2. `_toSD(0) = 0`, so the message encodes `amountSD = 0`.
3. On destination: `_toLD(0) = 0`, so `_credit(toAddress, 0, srcEid)` mints 0 tokens.

Zero tokens in, zero tokens out. No exploit possible.

---

## ATTACK VECTOR 2: OFT Mint/Burn Accounting

### Hypothesis 2.1: Can `_debit()` burn tokens without a corresponding `_credit()` on destination?

**VERDICT: FALSE POSITIVE (by design -- cross-chain atomicity is not guaranteed)**

The `send()` function burns/locks tokens on the source chain and dispatches a LayerZero message. If the message fails to be delivered or executed on the destination chain (e.g., due to insufficient gas, DVN failure), the tokens remain burned/locked. However, this is an inherent cross-chain design property, not a vulnerability:
- The message is verified by DVNs and can always be retried.
- The endpoint stores undelivered messages in the channel (`inboundPayloadHash`) for later execution.
- The OApp owner can `clear()` or `skip()` messages via the endpoint if needed.

### Hypothesis 2.2: Can `_credit()` mint more tokens than `_debit()` burned? (cross-chain accounting mismatch)

**VERDICT: FALSE POSITIVE**

As proven in Hypothesis 1.1, the round-trip conversion `_toLD(_toSD(_removeDust(amount)))` is exactly lossless. The amount encoded in the message (`amountSD`) precisely corresponds to the amount that was burned. On the receiving side, `_toLD(amountSD) * decimalConversionRate` reconstructs the exact `amountSentLD` that was burned. No mismatch is possible.

### Hypothesis 2.3: Can OFTAdapter's lock/unlock be exploited with fee-on-transfer tokens?

**VERDICT: FALSE POSITIVE (documented known limitation, not a bug)**

The OFTAdapter code explicitly documents this limitation:

File: `/root/defi-audit-targets/audits/layerzero/LayerZero-v2/packages/layerzero-v2/evm/oapp/contracts/oft/OFTAdapter.sol`, lines 17-18:
```
WARNING: The default OFTAdapter implementation assumes LOSSLESS transfers, ie. 1 token in, 1 token out.
IF the 'innerToken' applies something like a transfer fee, the default will NOT work...
a pre/post balance check will need to be done to calculate the amountSentLD/amountReceivedLD.
```

This is a documented design decision, not a vulnerability. Deployers using fee-on-transfer tokens must override `_debit()` with pre/post balance checks. This is not exploitable by external attackers since it requires the deployer to misuse the contract against its documented constraints.

### Hypothesis 2.4: Can the `address(0x0) -> address(0xdead)` protection in OFT._credit() be bypassed?

**VERDICT: FALSE POSITIVE**

In `OFT._credit()` (line 83):
```solidity
if (_to == address(0x0)) _to = address(0xdead);
```

The `_to` address comes from the cross-chain message: `_message.sendTo().bytes32ToAddress()`. The sender sets `_sendParam.to` on the source chain. If they set it to `bytes32(0)`, the receive side converts it to `address(0)`, which is then redirected to `0xdead`. Tokens are minted to `0xdead` rather than being burned via mint-to-zero. This is correct behavior -- it prevents ERC20's `_mint` from reverting while ensuring tokens are not lost (they go to a known dead address).

Note: `OFTAdapter._credit()` does NOT have this protection, but `safeTransfer` to `address(0)` would revert on virtually all standard ERC20 implementations (OpenZeppelin's ERC20 explicitly blocks transfers to address(0)), so it is not exploitable.

### Hypothesis 2.5: Can an OApp with compose messages exploit the credit flow to double-mint?

**VERDICT: FALSE POSITIVE**

The compose flow in `_lzReceive()`:
1. Tokens are credited (minted/unlocked) to `toAddress`.
2. If the message has a compose part, `endpoint.sendCompose(toAddress, guid, 0, composeMsg)` is called.
3. `sendCompose()` in the endpoint only stores the message hash in `composeQueue` -- it does NOT execute anything.
4. The compose is executed later in a separate transaction via `endpoint.lzCompose()`.
5. `lzCompose()` checks the hash matches and marks it as `RECEIVED_MESSAGE_HASH` before calling the composer, preventing reentrancy and replay.

The credit happens exactly once during `_lzReceive()`. The compose message execution is completely separate and cannot trigger additional credits. The `sendCompose` call in the endpoint is a simple storage write, not a callback.

---

## ATTACK VECTOR 3: OApp Peer Trust Model

### Hypothesis 3.1: Can `lzReceive()` be called with a spoofed peer address?

**VERDICT: FALSE POSITIVE**

`OAppReceiver.lzReceive()` has two critical checks (lines 103, 106):
```solidity
if (address(endpoint) != msg.sender) revert OnlyEndpoint(msg.sender);
if (_getPeerOrRevert(_origin.srcEid) != _origin.sender) revert OnlyPeer(_origin.srcEid, _origin.sender);
```

1. Only the LayerZero endpoint contract can call `lzReceive()`.
2. The endpoint is immutable and set at construction.
3. The endpoint's `lzReceive()` function calls `_clearPayload()` first, which verifies the payload hash matches what was verified by the DVN(s).
4. The DVN verification ensures the message actually originated from the claimed sender on the source chain.
5. Even if the endpoint calls `lzReceive()`, the OApp verifies `_origin.sender == peers[_origin.srcEid]`.

An attacker would need to compromise both the endpoint AND the DVN(s) to spoof a peer.

### Hypothesis 3.2: Can `allowInitializePath()` be tricked into initializing a path from an untrusted sender?

**VERDICT: FALSE POSITIVE**

```solidity
function allowInitializePath(Origin calldata origin) public view virtual returns (bool) {
    return peers[origin.srcEid] == origin.sender;
}
```

This only returns true if the sender matches the configured peer for that endpoint ID. The endpoint calls this during `verify()` to check if the path should be initialized. Since `peers[eid]` can only be set by the `onlyOwner`-protected `setPeer()`, an untrusted sender cannot pass this check.

### Hypothesis 3.3: Can the endpoint check in OAppReceiver be bypassed?

**VERDICT: FALSE POSITIVE**

The endpoint is `immutable`:
```solidity
ILayerZeroEndpointV2 public immutable endpoint;
```

It cannot be changed after deployment. The check `address(endpoint) != msg.sender` is unbypassable. No proxy upgrade, no admin function, no storage manipulation can change an immutable variable.

### Hypothesis 3.4: Can `setPeer()` be front-run to set a malicious peer before the legitimate one?

**VERDICT: FALSE POSITIVE**

`setPeer()` is protected by `onlyOwner`:
```solidity
function setPeer(uint32 _eid, bytes32 _peer) public virtual onlyOwner {
```

Only the contract owner can set peers. An attacker cannot front-run this call because they cannot satisfy the `onlyOwner` modifier. The owner is set during contract construction (via OpenZeppelin's `Ownable`), so ownership must be compromised for this to work -- which would be a separate, unrelated vulnerability.

---

## ATTACK VECTOR 4: Compose Message Exploits in OFT

### Hypothesis 4.1: Can the compose message in OFT be manipulated to credit the wrong recipient?

**VERDICT: FALSE POSITIVE**

In `_lzReceive()`, the recipient is decoded from the first 32 bytes of the message:
```solidity
address toAddress = _message.sendTo().bytes32ToAddress();
uint256 amountReceivedLD = _credit(toAddress, _toLD(_message.amountSD()), _origin.srcEid);
```

The compose message is sent to the SAME `toAddress`:
```solidity
endpoint.sendCompose(toAddress, _guid, 0, composeMsg);
```

The message content (including `sendTo`) is verified by the endpoint's `_clearPayload()` against the DVN-verified hash. An attacker cannot modify the message in transit without invalidating the hash. The recipient in the compose and the credit are always consistent.

### Hypothesis 4.2: Can SEND_AND_CALL type messages be exploited for reentrancy?

**VERDICT: FALSE POSITIVE**

The compose execution flow is:
1. `_lzReceive()` credits tokens to `toAddress`.
2. `endpoint.sendCompose()` stores the compose message hash -- this is NOT a callback, just a storage write.
3. The compose is executed later via `endpoint.lzCompose()` in a SEPARATE transaction.
4. In `lzCompose()`, the compose queue entry is set to `RECEIVED_MESSAGE_HASH` BEFORE the external call, preventing reentrancy:
```solidity
composeQueue[_from][_to][_guid][_index] = RECEIVED_MESSAGE_HASH; // before call
ILayerZeroComposer(_to).lzCompose{...}(...);                      // external call
```

Additionally, the endpoint's `lzReceive()` calls `_clearPayload()` before delivering the message, which deletes the payload hash, preventing replay. No reentrancy vector exists.

### Hypothesis 4.3: Can OFTMsgCodec encoding/decoding mismatches cause fund theft?

**VERDICT: FALSE POSITIVE**

The encoding in `OFTMsgCodec.encode()`:
```
[sendTo: 32 bytes][amountSD: 8 bytes][optional: composeFrom(32 bytes) + composeMsg]
```

Decoding:
- `sendTo()`: `bytes32(_msg[:32])` -- correct
- `amountSD()`: `uint64(bytes8(_msg[32:40]))` -- correct
- `isComposed()`: `_msg.length > 40` -- correct
- `composeMsg()`: `_msg[40:]` -- returns `[composeFrom][composeMsg]`

The offsets are consistent: `SEND_TO_OFFSET=32`, `SEND_AMOUNT_SD_OFFSET=40`. Encoding and decoding use the same offsets. No mismatch possible.

### Hypothesis 4.4: Can `isComposeMsgSender()` be bypassed?

**VERDICT: FALSE POSITIVE**

`isComposeMsgSender()` defaults to:
```solidity
return _sender == address(this);
```

This is called by the endpoint's `lzCompose()` flow, where `_from` is the OApp that called `sendCompose()`. The composer receiving the message can optionally use this to verify the sender. However, this is an informational check used by the composer, not a security gate in the OFT itself. The OFT always sends compose from `address(this)`, which matches correctly.

---

## ATTACK VECTOR 5: Options and Execution Manipulation

### Hypothesis 5.1: Can malformed options cause incorrect gas/value on destination?

**VERDICT: FALSE POSITIVE**

Options are parsed by the off-chain executor, not by the OApp. The executor uses `ExecutorOptions.nextExecutorOption()` which strictly parses `[worker_id(1)][size(2)][type(1)][option(size-1)]` format. Malformed options would:
1. Cause the executor to fail/skip execution (no funds at risk).
2. The `decodeLzReceiveOption`, `decodeNativeDropOption`, and `decodeLzComposeOption` functions all have strict length checks that revert on invalid lengths.

The sender bears the cost of providing proper options. Insufficient gas/value means the delivery fails, but tokens are already burned/locked. The message can be retried with proper options via the endpoint.

### Hypothesis 5.2: Can `combineOptions()` in OAppOptionsType3 be exploited to override security-critical options?

**VERDICT: FALSE POSITIVE**

`combineOptions()` concatenates enforced options with user-provided options:
```solidity
return bytes.concat(enforced, _extraOptions[2:]); // [2:] strips the type3 prefix
```

This means enforced options always come FIRST. The executor sums duplicated options (e.g., multiple `lzReceive` gas limits are added together). This means:
- The enforced minimum gas/value is always included.
- User-provided options can only ADD to the enforced minimums.
- A user cannot reduce the enforced gas below the minimum.

The only "exploit" would be a user providing excessive gas/value, which they pay for themselves.

### Hypothesis 5.3: Can ExecutorOptions parsing overflow or underflow?

**VERDICT: FALSE POSITIVE**

In `nextExecutorOption()`, the `unchecked` block is used for cursor arithmetic:
```solidity
unchecked {
    cursor = _cursor + 1;
    uint16 size = _options.toU16(cursor);
    cursor += 2;
    ...
    cursor += size;
}
```

While `unchecked` disables overflow checks, `_options` is a `calldata bytes` slice. If `cursor + size` exceeds the calldata length, any subsequent access to `_options[startCursor:endCursor]` will revert with an out-of-bounds error. Calldata slicing in Solidity always checks bounds. No exploitable overflow exists.

---

## ATTACK VECTOR 6: PreCrime Bypass

### Hypothesis 6.1: Can PreCrime simulation be tricked into accepting a malicious message?

**VERDICT: FALSE POSITIVE**

The PreCrime simulation flow:
1. `simulate()` is called with `onlyOffChain` modifier (requires `msg.sender == 0xDEAD`).
2. Packets are decoded and checked for size/order.
3. `_simulate()` calls `simulator.lzReceiveAndRevert()` which processes each packet through `_lzReceive()`.
4. The function ALWAYS reverts with `SimulationResult` -- the revert is the intended output.
5. `_parseRevertResult()` only accepts the `SimulationResult` selector; any other revert is treated as failure.

The simulation runs the actual `_lzReceive()` logic (with state changes), then reverts to undo them. The simulation result captures the state delta. A malicious message would either:
- Fail during simulation (revert bubbles up as `SimulationFailed`).
- Succeed during simulation but show anomalous state in `_preCrime()` checks (implementation-specific).

### Hypothesis 6.2: Can the simulation sandbox be escaped?

**VERDICT: FALSE POSITIVE**

`lzReceiveAndRevert()` calls `this.lzReceiveSimulate()` as an external call, which:
1. Ensures `msg.sender == address(this)` (line 92).
2. Calls `_lzReceiveSimulate()` which delegates to `_lzReceive()`.
3. After all packets are processed, the function ALWAYS reverts: `revert SimulationResult(...)`.

The `this.lzReceiveSimulate()` external call creates a new call frame. Even if `_lzReceive()` uses `assembly { return(0,0) }` to exit the inner call, the outer `lzReceiveAndRevert()` function continues and still reverts. The comment in the code explains this design:
```
// Calling this.lzReceiveSimulate removes ability for assembly return 0 callstack exit,
// which would cause the revert to be ignored.
```

### Hypothesis 6.3: Can `preCrimePeers` be manipulated?

**VERDICT: FALSE POSITIVE**

`setPreCrimePeers()` and `setMaxBatchSize()` are both `onlyOwner`:
```solidity
function setPreCrimePeers(PreCrimePeer[] calldata _preCrimePeers) external onlyOwner {
```

Only the owner can modify the PreCrime configuration. Additionally, all PreCrime entry points (`getConfig`, `simulate`, `preCrime`) have the `onlyOffChain` modifier requiring `msg.sender == 0xDEAD`, making on-chain manipulation impossible.

---

## DEVTOOLS-SPECIFIC FINDINGS

### NativeOFTAdapter: Native ETH handling

File: `/root/defi-audit-targets/audits/layerzero/devtools/packages/oft-evm/contracts/NativeOFTAdapter.sol`

The `NativeOFTAdapter._credit()` sends native ETH via a low-level `call`:
```solidity
(bool success, bytes memory data) = payable(_to).call{value: _amountLD}("");
if (!success) revert CreditFailed(_to, _amountLD, data);
```

This correctly reverts if the transfer fails. The `_payNative` override returns `_nativeFee` without checking `msg.value` because the `send()` override already validates `msg.value == _fee.nativeFee + _removeDust(_sendParam.amountLD)`. This is correct -- no double-spend or missing validation.

### MintBurnOFTAdapter: Trust in external minter/burner

File: `/root/defi-audit-targets/audits/layerzero/devtools/packages/oft-evm/contracts/MintBurnOFTAdapter.sol`

The `minterBurner` contract is `immutable` and must correctly implement `mint()` and `burn()`. If the minter/burner has bugs or access control issues, the OFT accounting could break. However, this is a deployment-time trust assumption, not a vulnerability in the OFT code itself.

### Fee contract: Rounding-down on fee calculation

File: `/root/defi-audit-targets/audits/layerzero/devtools/packages/oft-evm/contracts/Fee.sol`

```solidity
function getFee(uint32 _dstEid, uint256 _amount) public view virtual returns (uint256) {
    uint16 bps = _getFeeBps(_dstEid);
    return bps == 0 ? 0 : (_amount * bps) / BPS_DENOMINATOR;
}
```

The fee rounds down due to integer division, which slightly favors the sender. This is standard practice and not exploitable -- the maximum rounding error is `BPS_DENOMINATOR - 1 = 9999` wei, which is negligible.

---

## SUMMARY TABLE

| # | Hypothesis | Verdict | Severity | Protection Mechanism |
|---|-----------|---------|----------|---------------------|
| 1.1 | _toSD/_toLD precision loss | FALSE POSITIVE (with caveat) | LOW (V2 main) | _removeDust ensures lossless round-trip; devtools adds overflow check |
| 1.2 | Dust accumulation | FALSE POSITIVE | N/A | Dust stays with sender, never enters contract |
| 1.3 | decimalConversionRate overflow | FALSE POSITIVE | N/A | uint8 exponent, Solidity 0.8 checked math |
| 1.4 | sharedDecimals > localDecimals underflow | FALSE POSITIVE | N/A | Constructor revert check |
| 1.5 | Send 0 tokens, credit non-zero | FALSE POSITIVE | N/A | 0 -> 0 throughout pipeline |
| 2.1 | Burn without credit | FALSE POSITIVE | N/A | Cross-chain design; messages retryable |
| 2.2 | Credit > debit mismatch | FALSE POSITIVE | N/A | Lossless SD/LD round-trip |
| 2.3 | Fee-on-transfer token exploit | FALSE POSITIVE | N/A | Documented known limitation |
| 2.4 | address(0)->0xdead bypass | FALSE POSITIVE | N/A | ERC20 blocks transfer to 0; OFT redirects mint |
| 2.5 | Compose double-mint | FALSE POSITIVE | N/A | sendCompose is storage-only, not callback |
| 3.1 | Spoofed peer in lzReceive | FALSE POSITIVE | N/A | Endpoint-only + peer check + DVN verification |
| 3.2 | allowInitializePath trick | FALSE POSITIVE | N/A | Requires peer match (owner-set) |
| 3.3 | Endpoint check bypass | FALSE POSITIVE | N/A | Immutable endpoint address |
| 3.4 | setPeer front-run | FALSE POSITIVE | N/A | onlyOwner modifier |
| 4.1 | Compose wrong recipient | FALSE POSITIVE | N/A | Message hash verified by DVN + endpoint |
| 4.2 | SEND_AND_CALL reentrancy | FALSE POSITIVE | N/A | Two-phase compose (store then execute separately) |
| 4.3 | Codec encoding mismatch | FALSE POSITIVE | N/A | Consistent offset constants |
| 4.4 | isComposeMsgSender bypass | FALSE POSITIVE | N/A | Informational check, OFT always sends from self |
| 5.1 | Malformed options | FALSE POSITIVE | N/A | Executor-side parsing with strict length checks |
| 5.2 | combineOptions override | FALSE POSITIVE | N/A | Enforced options prepended; executor sums |
| 5.3 | ExecutorOptions overflow | FALSE POSITIVE | N/A | Calldata bounds checking |
| 6.1 | PreCrime accepts malicious msg | FALSE POSITIVE | N/A | Full _lzReceive simulation + revert |
| 6.2 | Simulation sandbox escape | FALSE POSITIVE | N/A | External call prevents assembly return escape |
| 6.3 | preCrimePeers manipulation | FALSE POSITIVE | N/A | onlyOwner + onlyOffChain |

---

## KEY ARCHITECTURAL SECURITY PROPERTIES

1. **Immutability:** `endpoint`, `decimalConversionRate`, `innerToken`, and `minterBurner` are all immutable, preventing post-deployment manipulation.

2. **Two-phase compose:** The compose flow uses store-then-execute pattern via the endpoint's `composeQueue`, eliminating reentrancy vectors in the OFT itself.

3. **Endpoint as trust root:** All message delivery goes through the immutable endpoint, which enforces payload hash verification, nonce ordering, and DVN authentication.

4. **Dust handling:** The `_removeDust` -> `_toSD` -> `_toLD` pipeline is mathematically lossless for dust-free amounts, preventing any inflation/deflation across chains.

5. **Owner-gated configuration:** All security-critical configuration (`setPeer`, `setEnforcedOptions`, `setPreCrime`, `setMsgInspector`, `setDelegate`) requires owner privileges.

---

## RECOMMENDATION

The only actionable finding is the silent `uint64` truncation in the V2 main `OFTCore._toSD()`. While not practically exploitable with default parameters, it should be updated to match the devtools version's explicit overflow check. The devtools version already contains this fix (with `AmountSDOverflowed` error), confirming the LayerZero team recognized this gap.
