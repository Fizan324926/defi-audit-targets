# Floe Labs — Security Audit Report

**Protocol:** Floe Labs (LendingIntentMatcher)
**Type:** P2P Intent-Based Lending Protocol
**Chain:** Base (L2)
**Date:** 2026-03-03
**Immunefi Bounty:** Max $50,000 (Critical)
**Previous Audit:** Omniscia (November 22, 2025)
**Methodology:** AUDIT-AI-RULES v4 — 34 hypotheses tested across 3 parallel audit tracks

## Executive Summary

Floe Labs is a peer-to-peer intent-based lending protocol on Base. Lenders and borrowers sign EIP-712 typed intents specifying their terms (rates, LTV, duration, hooks, conditions). Matcher bots find compatible intent pairs and execute them on-chain, creating isolated loan positions with Chainlink+Pyth oracle price feeds.

**Result: CLEAN — 0 exploitable vulnerabilities found. 8 informational/design findings.**

No Immunefi submissions warranted. The protocol demonstrates strong security fundamentals with comprehensive reentrancy protection, CEI compliance, gas-bounded hook execution, and dual-oracle resilience.

## Architecture Overview

```
User Intents (EIP-712 signed)
         │
    ┌────▼────┐
    │ Matcher  │ (off-chain solver bot)
    │  Bot     │
    └────┬────┘
         │ matchLoanIntents()
    ┌────▼────────────────────┐
    │ LendingIntentMatcher    │ ← UUPS Proxy (entry point)
    │ (nonReentrant, pauses,  │
    │  circuit breaker)       │
    └────┬────────────────────┘
         │ delegatecall
    ┌────▼────────────────────┐
    │ LendingLogicsManager    │ ← Delegatecall target
    │ (onlyProxy guard)       │
    └────┬────────────────────┘
         │ inherits
    ┌────▼────────────────────┐
    │ LendingLogicsInternal   │ ← All business logic
    │ (~1000 lines)           │
    └─────────────────────────┘
         │
    ┌────▼──────┐  ┌──────────┐  ┌───────────────┐
    │PriceOracle│  │HookExec. │  │FallbackOracle │
    │(Chainlink)│  │(gas-bound│  │(Pyth)         │
    └───────────┘  └──────────┘  └───────────────┘
```

**Key Design Patterns:**
- ERC-7201 namespaced storage for upgrade safety
- Dual oracle: Chainlink primary (5-point validation) + Pyth fallback
- Gas-bounded hook execution (adapted from Chainlink's CallWithExactGas)
- Circuit breaker with guardian activation
- Separate intent registration (on-chain) and signature verification (off-chain) paths
- Partial fill tracking for lend intents (Bug #64228 fix)

## In-Scope Contracts (6 Proxy Addresses)

| Contract | Proxy Address | Implementation |
|----------|--------------|----------------|
| LendingIntentMatcher | 0x10FC25F...6A7DAc | UUPS proxy, main entry point |
| PriceOracle | 0xEA058a06...210Cc | Chainlink + fallback |
| FallbackPriceOracle | 0xB459D4...6A9f | Pyth-based |
| HookExecutor | 0x71f0A88...5C3fA | Gas-bounded calls |
| LendingLogicsManager | 0x5835973...1C2010 | Business logic (delegatecall target) |
| LendingViews | — | View-only, off-chain queries |

## Hypothesis Testing Results (34 total)

### Track 1: Oracle Security (10 hypotheses)

| # | Hypothesis | Result | Severity |
|---|-----------|--------|----------|
| 1 | Stale/zero price exploitation | SAFE | — |
| 2 | USD-to-WETH conversion precision loss | SAFE | Informational |
| 3 | Token decimal uint8 underflow | SAFE | — |
| 4 | L2 sequencer uptime bypass | SAFE | — |
| 5 | Circuit breaker activation gap | Noted | Informational |
| 6 | Dual oracle simultaneous failure | SAFE | — |
| 7 | Price deviation check coverage | SAFE | Informational |
| 8 | Division by zero (ltvToUse=0) | SAFE | — |
| 9 | collateralPrice * scalingFactor overflow | SAFE | — |
| 10 | Pyth confidence interval manipulation | SAFE | Informational |

### Track 2: Intent Matching & EIP-712 (12 hypotheses)

| # | Hypothesis | Result | Severity |
|---|-----------|--------|----------|
| 1 | EIP-712 typehash mismatch | SAFE | — |
| 2 | Cross-chain signature replay | SAFE | — |
| 3 | ERC-1271 smart wallet bypass | SAFE | — |
| 4 | On-chain to off-chain intent replay | SAFE | — |
| 5 | Partial fill tracking gaps | SAFE | — |
| 6 | MathLib.getFillAmount edge cases | SAFE | — |
| 7 | Intent expiry race condition | SAFE | — |
| 8 | Lender filledAmount manipulation | SAFE | — |
| 9 | Hook/condition array hash collision | SAFE | — |
| 10 | Condition evaluation bypass | SAFE | — |
| 11 | Intent revocation TOCTOU | SAFE | — |
| 12 | Interest calculation overflow | SAFE | — |
| +1 | Hook callData EIP-712 encoding | Noted | Low |

### Track 3: Hooks, Callbacks & Access Control (12 hypotheses)

| # | Hypothesis | Result | Severity |
|---|-----------|--------|----------|
| 1 | Hook reentrancy into matcher | SAFE | — |
| 2 | Hook gas griefing | SAFE | — |
| 3 | Hook expiry off-by-one | SAFE | — |
| 4 | Flash loan reentrancy | SAFE | — |
| 5 | liquidateWithCallback theft | SAFE | — |
| 6 | delegateCall logicsManager swap | Noted | Informational |
| 7 | Role hierarchy self-escalation | Noted | Informational |
| 8 | Flash loan missing pause flag | Noted | Informational |
| 9 | setHookExecutor allows address(0) | Noted | Informational |
| 10 | Circuit breaker bypass on repay | SAFE | — |
| 11 | Function selector collision | SAFE | — |
| 12 | Instant upgrade without timelock | Noted | Informational |

### Manual Deep Analysis (additional vectors)

| # | Vector | Result |
|---|--------|--------|
| 1 | Flash loan draining collateral pool | SAFE — nonReentrant + post-balance check |
| 2 | Fee-on-transfer token accounting | Noted (Informational) |
| 3 | `onBehalfOf` abuse to steal from third party | SAFE — collateral always from signer |
| 4 | Matcher MEV extraction via rate selection | SAFE — by design (borrower consents to max rate) |
| 5 | Repayment rounding dust accumulation | SAFE — final repayment returns all remaining |
| 6 | Partial liquidation collateral seizure overflow | SAFE — underwater check math is sound |
| 7 | Condition validator state modification | SAFE — `view` function uses staticcall |

## Findings

### Finding 1: Hook callData EIP-712 Non-Compliance (Low)

**File:** `IntentLib.sol:114` vs `IntentLib.sol:150`

The `hashHooks` function passes `hooks[i].callData` (a `bytes` dynamic type) directly to `abi.encode`, but EIP-712 requires dynamic types to be encoded as `keccak256(value)`. The same library's `hashCondition` function at line 150 correctly uses `keccak256(condition.callData)`.

```solidity
// Hooks — INCORRECT per EIP-712
hookHashes[i] = keccak256(abi.encode(
    HOOK_TYPEHASH,
    hooks[i].target,
    hooks[i].callData,    // raw bytes — should be keccak256(hooks[i].callData)
    ...
));

// Conditions — CORRECT per EIP-712
keccak256(abi.encode(
    CONDITION_TYPEHASH,
    condition.target,
    keccak256(condition.callData),   // correctly hashed
    ...
));
```

**Impact:** EIP-712-compliant wallets/signing tools would produce different hashes for hook-containing intents than the contract expects. The protocol works because custom off-chain tooling matches the contract's encoding. Not exploitable for fund loss.

**Recommendation:** Replace `hooks[i].callData` with `keccak256(hooks[i].callData)` at line 114 for EIP-712 compliance, and update off-chain signing tooling accordingly.

### Finding 2: Circuit Breaker Requires Manual Guardian Activation (Informational)

**File:** `PriceOracle.sol:228-233, 496-497`

When a price deviation exceeds the threshold, `_checkAndUpdatePrice` **reverts** the current transaction but does **not** automatically activate the circuit breaker (because EVM reverts roll back all state changes). An off-chain keeper must detect the revert and call `activateCircuitBreaker()` (GUARDIAN_ROLE only).

The protocol explicitly documents this trade-off in comments. The deviation check is integrated into liquidation (`_prepareLiquidation:534`) and withdrawal (`_withdrawCollateral:692`) paths, limiting the attack window. Health checks use unchecked `getPrice`, but any false-positive liquidation would be blocked by the deviation check in the liquidation path itself.

**Impact:** Bounded race condition between oracle anomaly and guardian response. Mitigated by defense-in-depth: deviation checks on state-changing paths, circuit breaker modifier on all entry points.

### Finding 3: No Flash Loan Pause Mechanism (Informational)

**File:** `LendingIntentMatcher.sol:434`, `ILendingTypes.sol:114-120`

The `PauseStatuses` struct has flags for borrow, repay, liquidate, add collateral, and withdraw collateral — but no `isFlashLoanPaused`. Flash loans can only be blocked via the global circuit breaker. During emergencies where flash loans should be restricted but the oracle is still functional, there is no independent kill switch.

### Finding 4: Repay/AddCollateral Blocked During Circuit Breaker (Informational — Design)

**File:** `LendingIntentMatcher.sol:354,408`

All entry points including `repayLoan` and `addCollateral` are gated by `onlyWhenCircuitBreakerNotActive`. This means borrowers cannot protect their positions (add collateral, repay loans) during oracle emergencies. This is a deliberate safety-first design choice — the protocol prefers to freeze all state changes when price data is unreliable — but it could disadvantage borrowers during L2 sequencer downtime or oracle outages.

### Finding 5: setHookExecutor Missing Zero-Address Check (Informational)

**File:** `LendingIntentMatcherSetters.sol:44-48`

`setHookExecutor` only checks for duplicate assignment but not `address(0)`, unlike `setFeeRecipient` (line 89), `setPriceOracle` (line 96), and `setLogicsManager` (line 103) which all validate against zero address. Setting hookExecutor to address(0) would brick all hook-bearing intent matches.

### Finding 6: No On-Chain Timelock on LogicsManager/Upgrades (Informational — Centralization)

**Files:** `LendingIntentMatcherSetters.sol:102`, `LendingIntentMatcher.sol:197`

`setLogicsManager` (PROTOCOL_ADMIN_ROLE) and `_authorizeUpgrade` (UPGRADER_ROLE) have no on-chain timelock enforcement. The Roles.sol documentation recommends UPGRADER_ROLE be held by a TimelockController, but this is an operational guideline, not an on-chain constraint. A compromised admin could instantly swap the logicsManager to a malicious contract that executes via delegatecall, gaining full control over protocol storage and funds.

Standard centralization risk for upgradeable protocols. Immunefi typically classifies pure admin key compromise as out of scope.

### Finding 7: Pyth ETH/USD Feed Missing Confidence Interval Check (Informational)

**File:** `FallbackPriceOracle.sol:185-216` vs `FallbackPriceOracle.sol:139-150`

The `getAssetPrice` function validates the Pyth confidence interval (`confidenceBps <= maxConfidenceBps`), but `_getEthUsdPriceScaled` does not apply the same check to the ETH/USD feed. Since the ETH/USD price denominates ALL USD-to-WETH conversions, a wide confidence interval would affect every asset's final price. Practically low risk given ETH/USD feed liquidity.

### Finding 8: Fee-on-Transfer Token Collateral Accounting (Informational)

**File:** `LendingLogicsInternal.sol:312, 667`

Collateral is tracked via internal accounting (`loan.collateralAmount`) but transfers use `safeTransferFrom` without post-balance verification. For fee-on-transfer tokens, the actual balance held would be less than the recorded amount, potentially causing the last loan to be unable to withdraw its full collateral. The flash loan path (line 726) does have post-balance protection, showing awareness of this pattern. Most Base tokens are not fee-on-transfer.

## Security Strengths

1. **Comprehensive nonReentrant:** Every single entry point on LendingIntentMatcher uses `nonReentrant` (OpenZeppelin ReentrancyGuardUpgradeable).

2. **CEI Pattern:** All state-changing functions (repay, liquidate, add/withdraw collateral) mutate state before external calls.

3. **Gas-Bounded Hooks:** Hook execution adapted from Chainlink's production-grade `CallWithExactGas`, with EIP-150 1/64th rule compliance and no return data read (immune to returndata bombs).

4. **Dual Oracle Resilience:** Chainlink primary with 5-point validation (positive, initialized, not-future, not-stale, not-frozen) + Pyth fallback. Both fail → graceful revert (protocol freezes rather than using bad data).

5. **EIP-712 Implementation:** ChainId in both domain separator AND struct hash. Fork-safe domain separator recomputation. Proper ERC-1271 smart wallet support with staticcall.

6. **Partial Fill Safety:** Bug #64228 fix properly tracks off-chain fill amounts. Bug #64298 fix handles both-no-partial-fill case. Bug #64109 prevents on-chain→off-chain replay.

7. **Liquidation Design:** Underwater loans require full liquidation (preventing gaming). Solvent liquidations are mathematically proven sound (seizure never exceeds available collateral).

8. **Flash Loan Protection:** Post-balance check catches fee-on-transfer tokens. nonReentrant prevents callback abuse.

## Methodology Notes

- **Source Code Acquisition:** No public GitHub repo. All source fetched from Blockscout API for verified implementation contracts behind EIP-1967 UUPS proxies.
- **LendingLogicsManager Discovery:** The Immunefi scope listed `0x09E7...` but the actual on-chain logicsManager is `0x5835...` (verified via `getLogicsManager()` call). Both addresses were investigated.
- **Cross-Validation:** All 3 parallel audit tracks were cross-validated against manual deep analysis. Two agent findings were identified as false positives (EIP-712 typehash mismatch, getPriceChecked never called) and corrected.

## False Positive Log

| Agent Finding | Claimed Severity | Actual | Reason |
|--------------|-----------------|--------|--------|
| EIP-712 typehash mismatch (duration field) | HIGH | FALSE POSITIVE | Typehash correctly declares `uint256 minDuration,uint256 maxDuration` matching the struct and encoding |
| getPriceChecked never called by lending logic | MEDIUM | FALSE POSITIVE | `_validatePriceDeviation` at LendingLogicsInternal.sol:838 calls `getPriceChecked`, used in liquidation (line 534) and withdrawal (line 692) paths |

## Conclusion

Floe Labs demonstrates mature security engineering with a defense-in-depth approach. The protocol's core invariants (reentrancy protection, CEI compliance, oracle validation, signature verification) are sound. All 34 hypotheses tested across oracle security, intent matching, and hook/callback safety found no exploitable vulnerabilities. The 8 informational findings are primarily design trade-offs and centralization risks common to upgradeable protocols, none meeting the threshold for Immunefi submission.
