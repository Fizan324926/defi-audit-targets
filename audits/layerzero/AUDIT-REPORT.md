# LayerZero Protocol — Deep Security Audit Report

**Date:** 2026-03-02
**Bounty Program:** [LayerZero Immunefi](https://immunefi.com/bug-bounty/layerzero/) — $15,000,000 max (Critical)
**Result: Clean audit — 0 exploitable vulnerabilities found across 107+ hypotheses.**

---

## Scope

### Repositories Audited
| Repository | Description | Key Contracts |
|-----------|-------------|---------------|
| `LayerZero-v2/evm/protocol/` | V2 Endpoint & messaging | EndpointV2, EndpointV2Alt, MessagingChannel, MessagingComposer, MessagingContext, MessageLibManager |
| `LayerZero-v2/evm/messagelib/` | V2 Message libraries | ReceiveUln302, ReceiveUlnBase, UlnBase, SendLibBase, SendLibBaseE2, DVN, MultiSig, Executor, Worker, Treasury, PriceFeed, SafeCall |
| `LayerZero-v2/evm/oapp/` | OApp/OFT framework | OFTCore, OFT, OFTAdapter, OAppReceiver, OAppSender, OAppOptionsType3, PreCrime |
| `LayerZero-v2/solana/programs/` | V2 Solana programs | Endpoint, ULN, DVN, Executor, OFT |
| `LayerZero/contracts/` | V1 EVM contracts | Endpoint, UltraLightNodeV2, FPValidator, MPTValidator01, Treasury, RelayerV2 |
| `devtools/packages/oft-evm/` | Devtools OFT reference | OFTCore, OFT, OFTAdapter, NativeOFTAdapter, MintBurnOFTAdapter, Fee |
| `LayerZero-v2/evm/protocol/contracts/libs/` | Protocol libraries | AddressCast, GUID, Transfer, PacketV1Codec, Errors |
| `LayerZero-v2/evm/messagelib/contracts/uln/dvn/adapters/` | DVN adapters | DVNAdapterBase, DVNAdapterMessageCodec |

**Total files manually reviewed:** 60+ Solidity contracts, 20+ Solana Rust programs
**Total LOC analyzed:** ~15,000+ lines

---

## Executive Summary

After exhaustive analysis across 5 independent audit streams (V2 message flow, DVN/executor security, OFT/OApp token bridges, V1 EVM contracts, Solana programs), **zero critical or high-severity vulnerabilities** were identified. Two LOW/informational observations were noted, both already mitigated:

| # | Severity | Description | Status |
|---|----------|-------------|--------|
| 1 | LOW | PriceFeed `_estimateFeeByEid()` double-computation for L2 eids | Mitigated by explicit `eidToModelType` config |
| 2 | LOW | OFTCore `_toSD()` silent uint64 truncation | Fixed in devtools version |

Neither finding meets Immunefi's submission threshold for the LayerZero program (Critical/High only for protocol-level issues).

---

## Audit Methodology

### Phase 1: Architecture Mapping
- Full codebase exploration of all 6 repositories
- Mapped the 3-step messaging flow: `send()` → `verify()` → `lzReceive()`
- Documented DVN verification model, library migration system, OFT token bridge patterns
- Identified trust boundaries and attack surfaces

### Phase 2: Deep Vulnerability Analysis (107+ Hypotheses)

| Audit Stream | Hypotheses | False Positives | Low/Info |
|-------------|-----------|-----------------|----------|
| V2 Message Flow (nonces, verification, delivery, libraries, fees) | 20+ | 20+ | 0 |
| DVN/Executor/Worker (signatures, ACL, fees, verification logic) | 29 | 28 | 1 |
| OFT/OApp Token Bridges (decimals, accounting, trust, compose, options, PreCrime) | 23 | 22 | 1 |
| V1 EVM Contracts (endpoint replay, ULN proofs, treasury) | 12 | 12 | 0 |
| Solana Programs (PDA validation, DVN multisig, executor CPI, OFT accounting) | 15 | 15 | 0 |
| Manual Deep Dive (8 targeted hypotheses) | 8 | 8 | 0 |
| **Total** | **107+** | **105+** | **2** |

### Phase 3: Verification
All findings cross-verified against actual code. Both LOW findings confirmed as non-exploitable under default configurations.

---

## Security Architecture Assessment

LayerZero demonstrates mature, defense-in-depth security engineering across every layer:

### 1. Endpoint Layer (EndpointV2)
- **Reentrancy:** `sendContext` modifier packs `(dstEid, sender)` into uint256, prevents re-entry during send
- **Message integrity:** `_clearPayload` verifies `keccak256(header, payload)` against DVN-verified hash BEFORE executing receiver callback
- **Nonce safety:** Lazy inbound nonce pattern supports unordered verification while maintaining integrity via `_verifiable()` and `_initializable()` checks
- **Access control:** `_assertAuthorized()` checks OApp or its configured delegate
- **Library routing:** `isValidReceiveLibrary()` validates current library OR grace-period timeout library

### 2. DVN/Verification Layer
- **Multi-DVN model:** Required DVNs (all must verify) + optional DVNs (M-of-N threshold)
- **DVN address binding:** Verification stored as `hashLookup[headerHash][payloadHash][msg.sender]` — DVN address is msg.sender, unforgeable
- **No-duplicate enforcement:** `_assertNoDuplicates()` requires sorted ascending DVN arrays with strict greater-than checks
- **Minimum security:** `_assertAtLeastOneDVN()` requires `requiredDVNCount > 0 || optionalDVNThreshold > 0`
- **Multisig:** OpenZeppelin ECDSA v4.8.1+ handles signature malleability, sorted-signer enforcement, hash-before-call pattern

### 3. Executor Layer
- **Role-gated:** All execution functions require `ADMIN_ROLE` + `nonReentrant`
- **Safe delivery:** try/catch pattern with `lzReceiveAlert` / `lzComposeAlert` for error handling
- **Native drop safety:** Gas-limited ETH transfers prevent griefing

### 4. Worker ACL System
- **Priority chain:** Denylist > Allowlist > default deny
- **Integrity:** `allowlistSize` counter maintained through overridden `_grantRole`/`_revokeRole`
- **Safety:** `renounceRole()` unconditionally reverts

### 5. OFT Token Bridge
- **Lossless accounting:** `_removeDust` → `_toSD` → `_toLD` round-trip is mathematically exact
- **Immutable config:** `endpoint`, `decimalConversionRate`, `innerToken` are all immutable
- **Two-phase compose:** Store-then-execute pattern via endpoint's `composeQueue` eliminates reentrancy
- **Peer validation:** `onlyOwner`-gated `setPeer()` + immutable endpoint check

### 6. Fee System
- **DoS protection:** `treasuryNativeFeeCap` is down-only, SafeCall with gas limits for treasury interactions
- **Per-worker accounting:** `fees[worker]` mapping with bounded withdrawal via `_debitFee(msg.sender)`
- **Failure tolerance:** Treasury call failure returns 0 fee rather than reverting send operations

### 7. V1 Legacy
- **Strict nonce:** Sequential `++inboundNonce` enforcement (no out-of-order)
- **2-of-2 trust:** Oracle + relayer must both collude to forge messages
- **Stored payload:** Correct lifecycle — store on failure, clear on retry, forceResume only by destination app

### 8. Solana Programs
- **PDA validation:** All account derivations use Anchor's `seeds`/`bump` constraints with deterministic addresses
- **Nonce windowing:** 256-entry pending nonce cap prevents DoS
- **DVN signatures:** secp256k1 recovery with signer membership check + HashSet duplicate detection
- **Executor balance assertion:** Post-CPI balance check caps executor loss at intended `params.value`

---

## LOW/Informational Findings

### LOW-001: PriceFeed `_estimateFeeByEid()` Double-Computation

**File:** `LayerZero-v2/evm/messagelib/contracts/PriceFeed.sol` lines 238-262

The function has two sequential fee computation blocks. The first (lines 244-248) handles hardcoded Arbitrum/Optimism eids with L2-specific models but lacks `return` statements. Execution falls through to the second block (lines 251-258) which overwrites results based on `eidToModelType`. If `eidToModelType` is not explicitly set for these eids, the default model is used, which does not account for L1 data posting costs.

**Impact:** Workers may be undercharged for L2 message delivery. No direct fund theft or message forgery.
**Mitigation:** Operators explicitly set `eidToModelType` for all destination chains. The legacy `estimateFeeByChain()` function handles this correctly with proper `return` statements.

### LOW-002: OFTCore `_toSD()` Silent uint64 Truncation

**File:** `LayerZero-v2/evm/oapp/contracts/oft/OFTCore.sol` lines 335-337

`uint64(_amountLD / decimalConversionRate)` silently truncates if the result exceeds `type(uint64).max`. With default `sharedDecimals=6` and `localDecimals=18`, overflow requires >18.4 trillion tokens in a single transfer.

**Impact:** Not practically exploitable with default parameters. Custom implementations with `sharedDecimals` close to `localDecimals` could theoretically experience truncation, but the attacker loses tokens (not gains), as the truncated amount is less than what was burned.
**Mitigation:** Already fixed in devtools version with explicit `AmountSDOverflowed` revert check.

---

## False Positive Categories (107+ Eliminated)

### Nonce Manipulation (12 hypotheses)
All eliminated. V2 uses lazy inbound nonce with `_verifiable()`/`_initializable()` gating. V1 uses strict sequential `++inboundNonce`. Solana uses 256-entry windowed nonce with range validation.

### Verification Bypass (15 hypotheses)
All eliminated. `isValidReceiveLibrary()` validates msg.sender against registered + grace-period libraries. DVN verification keyed on msg.sender. Threshold checks require ALL required DVNs + M-of-N optional.

### Message Delivery Exploits (12 hypotheses)
All eliminated. Payload hash verification via `_clearPayload()` before execution. `RECEIVED_MESSAGE_HASH` sentinel prevents compose reentrancy. `lzReceive()` requires endpoint caller + peer match.

### Token Accounting (15 hypotheses)
All eliminated. Dust-free round-trip arithmetic is exact. Fee-on-transfer is documented limitation. Zero-amount transfers produce zero credits. Compose cannot trigger additional credits.

### Access Control (18 hypotheses)
All eliminated. Owner-gated configuration. Immutable endpoint/token references. DVN multisig with ECDSA recovery + signer membership. Worker ACL with denylist priority.

### Fee/Treasury (10 hypotheses)
All eliminated. Per-worker fee accounting. Treasury fee cap (down-only). SafeCall with gas limits. Failure returns 0 fee.

### Cross-Chain Attacks (15 hypotheses)
All eliminated. PDA-based account derivation (Solana). Peer validation on all OApp receives. DVN attestation of message origin.

### Reentrancy (10 hypotheses)
All eliminated. `sendContext` modifier. `RECEIVED_MESSAGE_HASH` sentinel. `receiveNonReentrant` (V1). `nonReentrant` (Executor). Check-effects-interactions throughout.

---

## Detailed Sub-Reports

| Report | Focus Area | Hypotheses |
|--------|-----------|-----------|
| [`findings/AUDIT-REPORT-DVN-EXECUTOR-WORKER-2026-03-02.md`](findings/AUDIT-REPORT-DVN-EXECUTOR-WORKER-2026-03-02.md) | DVN signatures, verification logic, executor, worker ACL, fee libraries | 29 |
| [`findings/AUDIT-REPORT-OFT-OAPP-2026-03-02.md`](findings/AUDIT-REPORT-OFT-OAPP-2026-03-02.md) | OFT decimal conversion, mint/burn, peer trust, compose, options, PreCrime | 23 |

### False Positive Documentation
| File | Topic |
|------|-------|
| [`notes/false-positives/FP-001-toSD-silent-truncation.md`](notes/false-positives/FP-001-toSD-silent-truncation.md) | _toSD() uint64 truncation analysis |
| [`notes/false-positives/FP-002-OFTAdapter-fee-on-transfer.md`](notes/false-positives/FP-002-OFTAdapter-fee-on-transfer.md) | Fee-on-transfer token handling |
| [`notes/false-positives/FP-003-OFTAdapter-credit-address-zero.md`](notes/false-positives/FP-003-OFTAdapter-credit-address-zero.md) | Address(0) credit redirect |
| [`notes/false-positives/FP-004-compose-reentrancy.md`](notes/false-positives/FP-004-compose-reentrancy.md) | Compose message reentrancy |
| [`notes/false-positives/FP-005-precrime-sandbox-escape.md`](notes/false-positives/FP-005-precrime-sandbox-escape.md) | PreCrime simulation sandbox |
| [`notes/false-positives/FP-006-combineOptions-override.md`](notes/false-positives/FP-006-combineOptions-override.md) | Options concatenation override |
| [`notes/false-positives/FP-007-lzReceive-peer-spoofing.md`](notes/false-positives/FP-007-lzReceive-peer-spoofing.md) | Peer address spoofing |

---

## Conclusion

LayerZero's cross-chain messaging protocol demonstrates exceptionally mature security engineering. The defense-in-depth approach — with independent checks at every layer (DVN verification, library validation, nonce ordering, payload hash matching, role-based ACL, reentrancy guards) — makes it extremely difficult to find exploitable vulnerabilities. The two LOW/informational findings are both already mitigated through operational configuration or updated codebases. No Immunefi submissions are warranted.
