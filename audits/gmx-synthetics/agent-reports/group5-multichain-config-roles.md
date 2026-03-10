# Agent Report: Multichain + Config/DataStore + Access Control

**Scope:** `multichain/*`, `config/*`, `data/*`, `role/*`, `feature/FeatureUtils.sol`

## Findings Summary

No new submittable vulnerabilities found. All findings eliminated as design choices or out-of-scope admin risks.

### LayerZero Message Spoofing: SAFE
Both `from` (Stargate pool address) and `msg.sender` (LayerZero endpoint) are validated against admin-configured allowlists in DataStore via `validateMultichainProvider` and `validateMultichainEndpoint`. Token amounts are tracked via StrictBank balance deltas — not from user-supplied fields. A user supplying `account = victim` can only donate their own bridged tokens to the victim, not steal.

### MultichainVault Balance Manipulation: SAFE
`StrictBank.recordTransferIn` uses actual balance deltas. `MultichainUtils.transferOut` checks balance before decrementing with `InsufficientMultichainBalance` revert. `nonReentrant` guards on all external entry points. `transferOut` on vault is `onlyController`.

### Cross-Chain Accounting Desync: SAFE
`multichainBalanceKey(account, token)` = `keccak256(abi.encode(MULTICHAIN_BALANCE, account, token))` — does NOT include `srcChainId`. All balances for an `(account, token)` pair use a single mapping slot. Funds can only be spent once regardless of which chain they came from.

### Config/DataStore Manipulation: SAFE (Admin Level)
DataStore is `onlyController`. Config is `CONFIG_KEEPER`/`LIMITED_CONFIG_KEEPER`. The `_validateKey` function correctly differentiates roles — `LIMITED_CONFIG_KEEPER` can only set `allowedLimitedBaseKeys`. Admin-level risk, out of scope.

### MultichainRouter Permission Bypass: SAFE
Every state-modifying relay function uses `_validateCall` → ECDSA signature verification. The `account` parameter cannot be impersonated without the account's private key.

### BridgeOut Execution Control: SAFE
`bridgeOutFromController` is `onlyController`. Amounts validated against `MultichainUtils.transferOut` balance check. `_shouldProcessBridgeOut` prevents bridging when `account != receiver` in certain contexts.

### ConfigSyncer Race Conditions: SAFE
Each update has unique `updateId` tracked in `SYNC_CONFIG_UPDATE_COMPLETED`. Idempotent — same update cannot be applied twice.

### AutoCancelSyncer Manipulation: SAFE
Only removes orders where `order.account() == address(0)` (already executed/cancelled) OR `sizeDeltaUsd == 0 && initialCollateralDeltaAmount == 0`. Cannot remove active stop-loss orders.

### Role Escalation: OUT OF SCOPE
`ROLE_ADMIN` can grant any role including `CONTROLLER`. This is an intentional admin capability — `ROLE_ADMIN` is the top-level governance role. `TimelockConfig` provides timelocked role changes. Compromise of admin key = protocol-level compromise (out of scope for bug bounty).

### Feature Flag Bypass: SAFE
`FeatureUtils.validateFeature` is a simple `getBool` check applied at the beginning of all critical operations. No bypass path found.

### Keys Collision: SAFE
All key derivation uses `keccak256(abi.encode(...))` with distinct constants as prefixes. `getFullKey` uses `bytes.concat(bytes32, bytes)` — since baseKey is always exactly 32 bytes, the concatenation is unambiguous. No collision possible between different base keys.

### EID Mapping Configuration Risk: LOW (Operational)
`LayerZeroProvider.sol:119-128` — `_decodeLzComposeMsg` returns `srcChainId = 0` if EID is not configured in `EID_TO_SRC_CHAIN_ID` mapping. `BridgeOutFromControllerUtils.bridgeOutFromController` has guard `if (srcChainId == 0) return` at line 82-84. If EID is unconfigured, auto bridge-back is silently skipped. User's GM/GLV tokens remain on destination chain; user must manually withdraw. Not a theft vector — operational/configuration risk only.

### Fee Refund Event srcChainId=0: LOW (Off-chain Only)
`LayerZeroProvider.sol:269-283` — relay fee refunds emit `srcChainId = 0` in events regardless of actual srcChainId. On-chain balance is correct (srcChainId not in balance key). Only affects off-chain indexers that track per-chain balances from events.

## Conclusion

Multichain architecture, config system, and role model are correctly implemented. Two low-severity operational observations noted (EID mapping and event srcChainId). No new financial findings.
