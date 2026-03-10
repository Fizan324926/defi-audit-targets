# Agent Report: Relay/Router System Re-Verification

**Scope:** `router/relay/*`, `router/*.sol`, `subaccount/SubaccountUtils.sol`

## Re-Verification Results

### VULN-003: CONFIRMED STILL PRESENT
`RelayUtils.sol:269` — `minOutputAmount: 0` hardcoded in `swapFeeTokens()`. No fix applied in current source.

```solidity
minOutputAmount: 0,  // CONFIRMED hardcoded — no slippage protection
```

### VULN-011: CONFIRMED STILL PRESENT
`IRelayUtils.sol:75` — `userNonce` documented as randomly generated: "interface generates a random nonce". Digest storage (`digests[digest] = true`) in `BaseGelatoRelayRouter` provides anti-replay only. No sequential counter, no cancellation mechanism. Confirmed still present.

## Domain Separator Analysis: FALSE POSITIVE

**Claim:** `RelayUtils.getDomainSeparator()` is `external`, so `address(this)` = library address, meaning all relay routers share the same domain separator, enabling cross-router replay.

**Verification:** `BaseGelatoRelayRouter._validateCall()` at line 385 calls `RelayUtils.getDomainSeparator(srcChainId)`. This IS an external call to the library (library address as `address(this)`). The domain separator IS the same for all relay routers.

**But cross-replay is NOT possible** because the two routers use different struct hash overloads:

- `GelatoRelayRouter.createOrder()` (line 65) calls: `RelayUtils.getCreateOrderStructHash(relayParams, params)` → 2-param overload → uses `address(0)` for account field, `bytes32(0)` for subaccountApprovalHash
- `SubaccountGelatoRelayRouter.createOrder()` calls: `RelayUtils.getCreateOrderStructHash(relayParams, subaccountApproval, account, params)` → 4-param overload → uses actual `account`, actual `keccak256(abi.encode(subaccountApproval))`

The struct hashes are different, so the digests are different. A signature for GelatoRelayRouter cannot be replayed on SubaccountGelatoRelayRouter.

**Verdict: FALSE POSITIVE** — shared domain separator is benign because struct hash overloads provide disambiguation.

## Silent Permit Failure: GRIEFING ONLY (No Fund Loss)

`BaseGelatoRelayRouter._handleTokenPermits()` uses `try {...} catch {}` swallowing permit failures silently. An attacker can front-run a user's permit transaction to exhaust it before the relay executes.

**Analysis:** If the permit fails and the subsequent `pluginTransfer` (for collateral) also fails, the ENTIRE transaction reverts (Solidity atomicity), including the relay fee collection. User loses only gas, not funds. Severity: LOW/griefing.

## Other Reviewed Areas

### Simulation Origin Bypass: SAFE
`GMX_SIMULATION_ORIGIN = address(uint160(uint256(keccak256("GMX SIMULATION ORIGIN"))))`. No known private key for a keccak-derived address. Not exploitable on standard EVM.

### Subaccount ActionType Cross-Validation: LOW (Current Impact Minimal)
`SubaccountGelatoRelayRouter` hardcodes `Keys.SUBACCOUNT_ORDER_ACTION` while `SubaccountApproval.actionType` is signed. No cross-validation that the signed type matches the hardcoded type. Currently only one action type exists, so no exploit is possible. Structural issue for future expansion.

### WNT Balance Accounting: SAFE
`residualFeeAmount = balanceOf(address(this))` includes any pre-existing WNT in the relay router. An attacker sending WNT to the router just donates to the next relay caller. Not extractable by the attacker. By-design pass-through behavior.

### Digest Per-Router Isolation: SAFE
Each relay router has its own `digests` mapping. Once a digest is stored in `GelatoRelayRouter.digests`, the SubaccountGelatoRelayRouter.digests does NOT contain it (different contract state). However, since the two routers produce different digests for the same parameters (different struct hash overloads), there is no cross-router replay concern.

## Conclusion

VULN-003 and VULN-011 confirmed still present. Domain separator collision is a false positive (different struct hash overloads prevent replay). No new submittable findings.
