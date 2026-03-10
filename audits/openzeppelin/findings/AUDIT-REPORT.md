# OpenZeppelin Security Audit Report

**Date:** 2026-03-03
**Auditor:** Independent Security Researcher
**Scope:** OpenZeppelin Contracts v5.6, OpenZeppelin Confidential Contracts, OpenZeppelin Uniswap V4 Hooks
**Repositories:**
- `openzeppelin-contracts` (v5.6.0) — Core Solidity library
- `openzeppelin-contracts-upgradeable` — Upgradeable variants
- `openzeppelin-confidential-contracts` — FHE/ERC7984 confidential tokens (Zama fhEVM)
- `uniswap-hooks` (v1.2.0) — Uniswap V4 hooks library

**Methodology:** Hypothesis-driven manual audit with automated exploration agents. Focused on Critical/High zero-day vulnerabilities across all 4 repositories. 100+ hypotheses tested.

---

## Summary

| Severity | Count |
|----------|-------|
| High | 2 |
| Medium | 4 |
| Low | 4 |
| Informational | 4 |
| **Total** | **14** |

### Finding Index

| ID | Severity | Title | File |
|----|----------|-------|------|
| H-01 | High | LimitOrderHook withdrawal underflow permanently locks funds | `uniswap-hooks/src/general/LimitOrderHook.sol` |
| H-02 | High | VotesConfidential FHE.sub underflow wraps voting power | `openzeppelin-confidential-contracts/.../VotesConfidential.sol` |
| M-01 | Medium | BridgeFungible toEvm address length not validated | `openzeppelin-contracts/.../BridgeFungible.sol` |
| M-02 | Medium | ReHypothecationHook first deposit spot price manipulation | `uniswap-hooks/src/general/ReHypothecationHook.sol` |
| M-03 | Medium | ERC4337Utils BLOCK_RANGE_FLAG asymmetric detection | `openzeppelin-contracts/.../draft-ERC4337Utils.sol` |
| M-04 | Medium | AntiSandwichHook incomplete checkpoint tick data | `uniswap-hooks/src/general/AntiSandwichHook.sol` |
| L-01 | Low | AntiSandwichHook first-swap large iteration range | `uniswap-hooks/src/general/AntiSandwichHook.sol` |
| L-02 | Low | LimitOrderHook fee dilution for early order placers | `uniswap-hooks/src/general/LimitOrderHook.sol` |
| L-03 | Low | BridgeERC721 uses transferFrom instead of safeTransferFrom | `openzeppelin-contracts/.../BridgeERC721.sol` |
| L-04 | Low | VotesConfidential checkpoint handle ACL gap | `openzeppelin-confidential-contracts/.../VotesConfidential.sol` |
| I-01 | Info | AntiSandwichHook one-sided swap protection | `uniswap-hooks/src/general/AntiSandwichHook.sol` |
| I-02 | Info | Confidential observer ACL irrevocable | `openzeppelin-confidential-contracts/` |
| I-03 | Info | Confidential silent zero transfer on frozen balance | `openzeppelin-confidential-contracts/` |
| I-04 | Info | Oracle.sol truncated tick clamp direction ambiguity | `uniswap-hooks/src/oracles/panoptic/libraries/Oracle.sol` |

---

## High Severity

### H-01: LimitOrderHook Withdrawal Underflow Permanently Locks Funds

**File:** `uniswap-hooks/src/general/LimitOrderHook.sol:418`

**Description:**

The `withdraw()` function uses a proportional distribution formula that underflows when multiple users have different checkpoints. When user A (early joiner, checkpoint=0) withdraws before user B (late joiner, checkpoint=fees_at_join_time), A's withdrawal reduces `currency0Total`/`currency1Total` below B's checkpoint values, causing a `uint256` underflow revert on line 418:

```solidity
amount0 = FullMath.mulDiv(orderInfo.currency0Total - checkpointAmountCurrency0, liquidity, liquidityTotal);
```

Since `orderInfo.currency0Total` can be less than `checkpointAmountCurrency0` after an earlier user's proportional withdrawal, the subtraction underflows. This permanently locks the late user's funds — there is no admin rescue function, no alternative withdrawal path, and the order is already marked as filled (preventing cancel).

**Root Cause:**

The checkpoint mechanism (lines 284-285) snapshots `currency0Total`/`currency1Total` at the time each user joins an order. The proportional withdrawal formula assumes each user's share of the post-checkpoint delta can be cleanly separated, but this is false when fees accrue asymmetrically between joins.

When the first user withdraws their proportional share of the ENTIRE total (including pre-second-user fees), the remaining total drops below the second user's checkpoint.

**Exploit Scenario:**

1. **User A** places a `zeroForOne` limit order with `liquidity = 1000`
   - `checkpoints[A] = {currency0: 0, currency1: 0}`
2. **Fees accrue** from swaps: `currency0Total = 100, currency1Total = 50`
3. **User B** places into the same order with `liquidity = 1000`
   - `checkpoints[B] = {currency0: 100, currency1: 50}`
   - `liquidityTotal = 2000`
4. **Price crosses tick**, order fills:
   - Fill adds `amount0 = 5, amount1 = 200`
   - `currency0Total = 105, currency1Total = 250`
5. **User A withdraws:**
   - `amount0 = mulDiv(105 - 0, 1000, 2000) = 52`
   - `currency0Total = 105 - 52 = 53`
6. **User B tries to withdraw:**
   - `currency0Total - checkpointCurrency0 = 53 - 100` → **UNDERFLOW REVERT**
   - B's funds are **permanently locked**

**Impact:**
- **Severity:** High — Permanent loss of funds
- **Likelihood:** Medium — Occurs naturally when multiple users join the same limit order at different times with fee accumulation in between
- **Affected users:** Any user who joins a limit order after fees have already accrued, if they withdraw after an earlier user

**Recommendation:**

Replace the proportional checkpoint subtraction with per-user tracked earnings, or use a `min()` clamp:

```solidity
uint256 effectiveCheckpoint0 = checkpointAmountCurrency0 > orderInfo.currency0Total
    ? orderInfo.currency0Total
    : checkpointAmountCurrency0;
amount0 = FullMath.mulDiv(orderInfo.currency0Total - effectiveCheckpoint0, liquidity, liquidityTotal);
```

Alternatively, track per-user accrued fees separately (similar to Sushiswap's `rewardDebt` pattern) rather than relying on global totals minus checkpoints.

---

### H-02: VotesConfidential FHE.sub Underflow Wraps Voting Power

**File:** `openzeppelin-confidential-contracts/contracts/governance/utils/VotesConfidential.sol:186`

**Description:**

The `_moveDelegateVotes` function uses raw `FHE.sub` to decrease a delegate's voting power:

```solidity
euint64 newValue = store.latest().sub(amount);
```

In Zama's fhEVM (v0.11.1, as specified in the project's package.json), FHE arithmetic operations on encrypted integers perform **modular arithmetic** — they wrap on underflow instead of reverting. If a subtraction would produce a negative result, it wraps to a value near `type(uint64).max`.

OpenZeppelin's own `FHESafeMath` library provides `tryDecrease()` which uses `FHE.ge(oldValue, delta)` to check for underflow before subtracting, using `FHE.select` to conditionally apply. **VotesConfidential does not use this pattern.**

**Root Cause:**

The existence of `FHESafeMath.tryDecrease()` in the same repository indicates awareness of the FHE underflow risk, but `VotesConfidential._moveDelegateVotes` bypasses it. While the standard ERC20 transfer flow should prevent underflow by validating balances first, the encrypted domain introduces scenarios where:

1. ERC20Confidential transfers use `FHE.select` to conditionally zero out invalid transfers (no revert)
2. The voting units update may still execute with the original (non-zero) amount
3. If the conditional zeroing in the token layer and the voting power update are not perfectly synchronized, an underflow can occur

**Impact:**
- **Severity:** High — A delegate's voting power could wrap from a small value to near `2^64 - 1`, giving them overwhelming governance control
- **Likelihood:** Low-Medium — Requires specific interaction between encrypted transfer conditionals and voting power updates
- **Affected users:** All governance participants in confidential voting systems using this library

**Recommendation:**

Use `FHESafeMath.tryDecrease()` instead of raw `FHE.sub`:

```solidity
// Before (vulnerable):
euint64 newValue = store.latest().sub(amount);

// After (safe):
(ebool success, euint64 newValue) = FHESafeMath.tryDecrease(store.latest(), amount);
// Handle the failure case appropriately
```

---

## Medium Severity

### M-01: BridgeFungible toEvm Address Length Not Validated

**File:** `openzeppelin-contracts/contracts/crosschain/bridges/abstract/BridgeFungible.sol:71`

**Description:**

The `_processMessage` function decodes the destination address from cross-chain payloads and casts it without length validation:

```solidity
(bytes memory from, bytes memory toEvm, uint256 amount) = abi.decode(payload, (bytes, bytes, uint256));
address to = address(bytes20(toEvm));
```

If `toEvm` is longer than 20 bytes, `bytes20(toEvm)` silently takes only the first 20 bytes, discarding the rest. If `toEvm` is shorter than 20 bytes, it left-pads with zeros.

On the send side, `InteroperableAddress.parseV1(to)` extracts arbitrary-length address bytes without validation (unlike `parseEvmV1` which enforces 20 bytes). A user sending to a malformed InteroperableAddress targeting an EVM chain would have their tokens burned/locked on the source chain and minted to a truncated/padded address on the destination.

**Impact:**
- **Severity:** Medium — Permanent token loss
- **Likelihood:** Low — Requires user to craft a non-standard InteroperableAddress; self-harm scenario
- **Mitigation:** The `parseEvmV1()` function exists and validates 20-byte addresses, but `BridgeFungible` doesn't use it on the receive side

**Recommendation:**

Add length validation before casting:

```solidity
require(toEvm.length == 20, "Invalid EVM address length");
address to = address(bytes20(toEvm));
```

---

### M-02: ReHypothecationHook First Deposit Spot Price Manipulation

**File:** `uniswap-hooks/src/general/ReHypothecationHook.sol:307-314`

**Description:**

The first depositor's liquidity amount is calculated using `LiquidityAmounts.getAmountsForLiquidity` with the current spot pool price from `poolManager.getSlot0()`. An attacker can:

1. Flash-loan to manipulate the pool's spot price
2. Make the first deposit at the distorted price, receiving an inflated liquidity position
3. Repay the flash loan, restoring normal price
4. Subsequent depositors deposit at fair price but receive fewer shares relative to the attacker

This is the classic first-depositor/spot-price manipulation vector. The ReHypothecation hook does not have minimum deposit requirements or dead share mechanisms to mitigate this.

**Impact:**
- **Severity:** Medium — Value extraction from subsequent depositors
- **Likelihood:** Medium — Exploitable on any newly created pool using this hook

**Recommendation:**

Use TWAP pricing for initial deposits, require a minimum first deposit, or implement dead shares (similar to ERC4626 virtual offset).

---

### M-03: ERC4337Utils BLOCK_RANGE_FLAG Asymmetric Detection

**File:** `openzeppelin-contracts/contracts/account/utils/draft-ERC4337Utils.sol:64`

**Description:**

The `parseValidationData` function uses bitwise AND to detect block-range mode:

```solidity
range = ((validAfter & validUntil & BLOCK_RANGE_FLAG) == 0)
    ? ValidationRange.TIMESTAMP
    : ValidationRange.BLOCK;
```

This requires BOTH `validAfter` and `validUntil` to have `BLOCK_RANGE_FLAG` set. If only one field has the flag:
- The data is silently interpreted as TIMESTAMP range
- `packValidationData` (line 98) then strips the flag via `&= BLOCK_RANGE_MASK`
- Block numbers get compared against `block.timestamp`, causing incorrect validation

The `packValidationData` overload without explicit range (line 73-84) uses the same detection logic, silently converting mixed-flag inputs to TIMESTAMP and stripping the flag.

**Impact:**
- **Severity:** Medium — Silent data corruption; block-based validation could be misinterpreted as timestamp-based
- **Likelihood:** Low — Requires non-standard input construction with inconsistent flags

**Recommendation:**

Either revert on asymmetric flags or use OR instead of AND to detect any flag presence:

```solidity
// Option 1: Revert on inconsistent flags
bool afterFlag = (validAfter & BLOCK_RANGE_FLAG) != 0;
bool untilFlag = (validUntil & BLOCK_RANGE_FLAG) != 0;
require(afterFlag == untilFlag, "Inconsistent range flags");

// Option 2: Detect any flag
range = (((validAfter | validUntil) & BLOCK_RANGE_FLAG) == 0)
    ? ValidationRange.TIMESTAMP
    : ValidationRange.BLOCK;
```

---

### M-04: AntiSandwichHook Incomplete Checkpoint Tick Data

**File:** `uniswap-hooks/src/general/AntiSandwichHook.sol:96-115`

**Description:**

The checkpoint mechanism copies tick data only for ticks between `lastTick` and `currentTick`. Ticks outside this range that may have been modified (e.g., by direct liquidity operations between checkpoints) are not captured. This means the hook's sandwich protection operates on stale liquidity data for positions outside the last price movement range.

A sophisticated attacker could:
1. Add liquidity at ticks outside the recent price range
2. Wait for a checkpoint that doesn't capture those ticks
3. Execute a sandwich attack that moves price through the uncaptured ticks
4. The hook's reference data won't detect the manipulation at those ticks

**Impact:**
- **Severity:** Medium — Partial bypass of sandwich protection
- **Likelihood:** Low-Medium — Requires understanding of the checkpoint range limitation

**Recommendation:**

Expand the checkpoint range to include all initialized ticks, or maintain a separate data structure tracking all tick modifications since the last checkpoint.

---

## Low Severity

### L-01: AntiSandwichHook First-Swap Large Iteration Range

**File:** `uniswap-hooks/src/general/AntiSandwichHook.sol`

**Description:**

When `_lastCheckpoint.blockNumber == 0` (first block after initialization), `lastTick` defaults to `0`. If the current tick is far from 0 (e.g., tick = 50000 for a high-ratio pair), the checkpoint loop iterates over all ticks from 0 to 50000, potentially consuming excessive gas or hitting the block gas limit.

**Recommendation:** Initialize `lastTick` to the pool's current tick on `afterInitialize`.

---

### L-02: LimitOrderHook Fee Dilution for Early Order Placers

**File:** `uniswap-hooks/src/general/LimitOrderHook.sol:276-285`

**Description:**

When a user joins an existing order, their checkpoint is set to the current `currency0Total`/`currency1Total`. However, early placers' checkpoints remain at their original (lower) values. Fees that accrue between the early and late placement are shared proportionally by total liquidity, but early placers' entitlement to those fees gets diluted by the new liquidity. The late joiner effectively "freeloads" on the proportional share because the formula doesn't isolate per-period earnings.

This is related to H-01 but represents the economic unfairness even in cases where the underflow doesn't occur (e.g., when fill proceeds are large enough to prevent underflow).

**Recommendation:** Use a `rewardPerShare` accumulator pattern (similar to MasterChef/Sushi) to track per-unit fee earnings, ensuring each user only receives fees proportional to their time-weighted liquidity contribution.

---

### L-03: BridgeERC721 Uses transferFrom Instead of safeTransferFrom

**File:** `openzeppelin-contracts/contracts/crosschain/bridges/abstract/BridgeERC721.sol`

**Description:**

The bridge uses `transferFrom` rather than `safeTransferFrom` when delivering NFTs on the destination chain. If the recipient is a contract that doesn't implement `IERC721Receiver`, the NFT is transferred but the contract cannot interact with it, effectively locking the token.

**Recommendation:** Use `safeTransferFrom` and handle the potential revert with a fallback (e.g., escrow).

---

### L-04: VotesConfidential Checkpoint Handle ACL Gap

**File:** `openzeppelin-confidential-contracts/contracts/governance/utils/VotesConfidential.sol:80-94`

**Description:**

`getVotes()` and `getPastVotes()` return encrypted `euint64` handles directly without contract-level ACL enforcement. While the fhEVM coprocessor prevents unauthorized decryption, any governance contract that calls `getVotes()` receives the handle and could potentially be granted decryption rights if the `HandleAccessManager.getHandleAllowance()` is called. This is a defense-in-depth concern — contract-level access control on sensitive voting data would add an additional security layer.

**Recommendation:** Consider adding `onlyAuthorized` checks or allowlisting governance contracts that may call these functions.

---

## Informational

### I-01: AntiSandwichHook One-Sided Swap Protection

The hook only applies sandwich protection for `!zeroForOne` swaps (line 151). `zeroForOne` swaps return `(type(uint256).max, false)`, bypassing all protection. This is a known design choice documented in the Umbra Research specification, but users should be aware that sandwich attacks in the `zeroForOne` direction are unmitigated.

### I-02: Confidential Observer ACL Irrevocable

Once observer access is granted to an account via the HandleAccessManager in the confidential contracts, it cannot be revoked. This is a design limitation of the current ACL system — encrypted handles that have been shared remain accessible.

### I-03: Confidential Silent Zero Transfer on Frozen Balance

When a confidential token account is frozen, transfers from that account are silently zeroed via `FHE.select` rather than reverting. The sender sees a successful transaction but no tokens move. This design choice (necessary for FHE privacy) may confuse users and integrating contracts that rely on transfer failure to detect frozen accounts.

### I-04: Oracle.sol Truncated Tick Clamp Direction Ambiguity

In `Oracle.transform()` (line 50), when the tick delta exceeds `maxAbsTickDelta`, the truncated tick is clamped:

```solidity
truncatedTick = last.prevTruncatedTick + (tickDelta > 0 ? maxAbsTickDelta : -maxAbsTickDelta);
```

The `tickDelta` comparison uses the casted `int24` value. For extreme tick movements that span the full `int24` range, the sign of `tickDelta` could be ambiguous due to wrapping in the `unchecked` block (line 43). This is unlikely in practice but worth noting for edge-case analysis.

---

## Areas Reviewed (No Issues Found)

The following areas were reviewed and found to be well-implemented:

- **BaseHook.sol** — `onlyPoolManager` modifier, `_validateHookAddress` constructor validation
- **BaseCustomAccounting.sol** — Position salt derivation, fee handling
- **BaseCustomCurve.sol** — ERC-6909 claim token management, swap logic override
- **BaseAsyncSwap.sol** — Exact-input only constraint, claim token minting
- **BaseDynamicAfterFee.sol** — Transient storage for target amounts
- **BaseHookFee.sol** — Fee capping at 100% (1e6)
- **BaseOverrideFee.sol** — Override flag usage
- **CurrencySettler.sol** — Settle/take logic, early return for zero amounts
- **OracleHookWithV3Adapters.sol** — Adapter deployment pattern
- **BaseOracleHook.sol** — Observation write in beforeSwap, cardinality management
- **openzeppelin-contracts-upgradeable** — Faithful mirror of openzeppelin-contracts with storage gaps and initializers
- **ERC7786Recipient / CrosschainLinked** — Gateway validation pattern
- **ERC20Confidential core** — FHE.select conditional transfers, ACL management

---

## Hypotheses Tested (Selected False Positives)

1. **LiquidityPenaltyHook double penalty** — FALSE POSITIVE. Traced full delta accounting: hook settles withheldFees (+), donates liquidityPenalty (-), return delta takes `(liquidityPenalty - withheldFees)` from LP. Net for hook = 0. LP receives: `principal + totalFees - penalty`. Correct.

2. **LiquidityPenaltyHook inverted sign** — FALSE POSITIVE. Same as above; the sign convention `liquidityPenalty - withheldFees` in the return delta is correct.

3. **AntiSandwichHook lpFeeOverride=0 divergence** — FALSE POSITIVE. When override fee is 0 (no `OVERRIDE_FEE_FLAG` set), `Pool.swap` uses `self.slot0.lpFee()` as the actual fee, so the simulated swap correctly uses the checkpoint's LP fee.

4. **BaseCustomCurve reentrancy via ERC-6909** — FALSE POSITIVE. All mutations happen within `poolManager.unlock()` callback which has reentrancy protection.

5. **Oracle binary search infinite loop** — FALSE POSITIVE. The loop terminates because `left` and `right` converge and the data is guaranteed to contain the answer (enforced by `getSurroundingObservations`).
