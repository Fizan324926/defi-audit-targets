# Flamingo Finance — Security Audit Report

**Protocol:** Flamingo Finance (Neo N3 DEX + Staking)
**Bounty:** Immunefi, max $1,000,000 (Critical), $40,000 (High), $4,000 (Medium)
**Chain:** Neo N3
**Language:** C# Smart Contracts
**Date:** 2026-03-03
**Scope:**
- `flamingo-contract-swap` (FlamingoSwapFactory, FlamingoSwapPair, FlamingoSwapRouter, ProxyTemplate, FlamingoSwapPairWhiteList)
- `flamingo-contract-staking-n3` (FLM Token, Staking Vault)
- ~3,500 LOC across 38 C# contract files

---

## Executive Summary

Flamingo Finance is a Uniswap V2-style AMM DEX and staking protocol on the Neo N3 blockchain. The core swap contracts (Pair, Router, Factory) are a faithful implementation of the Uniswap V2 constant-product AMM pattern with appropriate reentrancy guards and whitelist-based access control.

**Findings: 2 Medium, 2 Low, 2 Informational**

| ID | Severity | Title | File | Line |
|----|----------|-------|------|------|
| M-01 | Medium | ProxySwapTokenInForTokenOut checks wrong deposit balance (LP instead of input token) | ProxyTemplateContract.cs | 180 |
| M-02 | Medium | Staking profit rate integer division truncation permanently loses rewards | Staking.Record.cs | 78 |
| L-01 | Low | CheckFLM public function has unguarded write side effects | Staking.cs | 139 |
| L-02 | Low | Pair OnNEP17Payment validation commented out — accepts any NEP-17 token | FlamingoSwapPairContract.Nep17.cs | 50 |
| I-01 | Informational | Fund fee truncated to zero for small swaps | FlamingoSwapPairContract.cs | 196 |
| I-02 | Informational | GASAdmin uninitialized causes ClaimGASFrombNEO permanent DoS | FlamingoSwapPairContract.Admin.cs | 97 |

---

## Hypotheses Tested (55+)

### Swap Pair Contract
1. K-invariant bypass via rounding → **False positive** (K increases after each swap; 0.3% fee ensures surplus)
2. Fund fee extraction violates K → **False positive** (fee taken from 0.3% deduction; 0.25% stays in pool, K still increases)
3. First-depositor inflation attack → **False positive** (MINIMUM_LIQUIDITY = 1000 burned to address(0))
4. Reentrancy via onNEP17Payment callback during swap → **False positive** (EnteredStorage guard active during Swap/Mint/Burn)
5. Cross-pair reentrancy via callback → **False positive** (whitelist check blocks non-router callers)
6. LP token transfer reentrancy (Transfer lacks guard) → **False positive** (callback can't call Swap/Mint/Burn without being whitelisted router)
7. DynamicBalanceOf donation attack → **False positive** (reserves updated atomically; external donation doesn't affect swap calculation)
8. Zero-amount output swap → **False positive** (line 153 requires at least one output > 0)
9. Stale reserves during fund fee transfer callback → **Not exploitable** (reentrancy guard blocks re-entry to same pair)
10. TWAP manipulation via single block → **Not exploitable** (cumulative price; single-block manipulation averages out)
11. Burn rounding accumulation → **Negligible** (rounds down, sub-1-unit per token per burn)
12. Price accumulator overflow → **Safe** (BigInteger has arbitrary precision on Neo)
13. Fund fee rounds to 0 for small amounts → **CONFIRMED** (I-01)
14. OnNEP17Payment accepts any token → **CONFIRMED** (L-02)

### Router Contract
15. Path injection with circular tokens → **False positive** (line 411 checks paths[0] != paths[max])
16. Path with non-existent pair → **False positive** (GetExchangePairWithAssert reverts)
17. Zero slippage protection (amountOutMin=0) → **Low risk** (Neo dBFT consensus limits MEV opportunity)
18. Multi-hop routing amount calculation mismatch → **False positive** (sequential GetAmountOut/In is mathematically correct)
19. RequestTransfer balance verification bypass → **False positive** (pre/post balance check catches discrepancies)

### Factory Contract
20. Pair overwrite via RegisterExchangePair → **Admin-only** (requires witness)
21. Pair key collision (tokenA == tokenB) → **False positive** (CreateExchangePair checks tokenA != tokenB)

### WhiteList Contract
22. Router addition without validation → **Admin-only** (witness required)
23. CheckRouter returns false for removed routers → **Safe** (deletion removes key; Get returns 0)

### ProxyTemplate Contract
24. ProxySwapTokenInForTokenOut wrong balance check → **CONFIRMED** (M-01)
25. ProxySwapTokenOutForTokenIn equivalent bug → **False positive** (line 222 correctly uses path[0])
26. Global allowance accumulation across users → **False positive** (atomic transactions prevent interleaving)
27. ApprovedTransfer callable by anyone → **Not exploitable** (requires prior Approve in same atomic tx)
28. Leftover approval after failed swap → **False positive** (Neo transaction atomicity reverts all state on failure)
29. YBurn underflow allows fund theft → **False positive** (UpdateBalance returns false if balance < 0, Assert catches it)
30. ProxyAddLiquidity LP token accounting mismatch → **False positive** (pre/post balance tracking is correct)

### FLM Token Contract
31. Mint authorization bypass via CallingScriptHash → **False positive** (minter must be IsAuthor; CallingScriptHash must match minter)
32. ConvertDecimal = 10^30 extreme truncation → **Amplifies M-02** (small profits round to 0 at minting)
33. Burn allows reducing supply below 0 → **False positive** (BalanceStorage.Reduce returns false if insufficient)
34. Transfer reentrancy via onNEP17Payment → **Not exploitable** (callback on receiver, not sender; no sensitive state to corrupt)
35. Zero-amount transfer → **Safe** (TransferInternal checks `amount >= 0`; amount=0 is no-op)

### Staking Contract
36. Staking profit rate truncation → **CONFIRMED** (M-02)
37. CheckFLM write side effects → **CONFIRMED** (L-01)
38. OnNEP17Payment reentrancy → **False positive** (only outbound call is ReadOnly balanceOf)
39. Double-claim via ClaimFLM reentrancy → **False positive** (EnteredStorage per-tx guard + atomic rollback)
40. Profit manipulation via stake-unstake timing → **False positive** (same-timestamp updates skip history accumulation)
41. Donation to staking contract inflates totalStaked → **False positive** (NEP-17 OnNEP17Payment always triggers, which either records the stake or reverts)
42. balanceOf-based totalStaked vs internal accounting divergence → **False positive** (all token movements go through OnNEP17Payment or Refund)
43. Refund zeroes profit → **False positive** (profit IS stored in currentProfit parameter; user claims via ClaimFLM)
44. MintFLM → FLM.TransferInternal callback reenters staking → **False positive** (FLM.onNEP17Payment calls receiver, not staking; EnteredStorage blocks same-tx re-entry)
45. SetCurrentShareAmount unbounded → **Admin operational** (no exploitable impact)
46. UpgradeStart timelock bypass → **False positive** (Update checks timeLockTimeStamp > 0 && currentTime - timeLockTimeStamp >= 86400)

### Cross-Contract
47. Flash loan via pair Swap pattern → **Safe** (K-invariant enforced post-swap; fee charged)
48. Router + Pair + Fund callback chain → **Safe** (reentrancy guard prevents re-entry; callback is after K check)
49. Staking → FLM mint path manipulation → **False positive** (FLM address stored in admin-controlled storage)
50. ProxyTemplate → Router → Pair chain reentrancy → **Safe** (each pair has independent reentrancy guard; whitelist blocks unauthorized callers)

### Neo N3-Specific
51. BigInteger overflow → **Safe** (arbitrary precision in Neo VM)
52. CallFlags.All vs ReadOnly misuse → **Safe** (ReadOnly used for balanceOf queries, All for state-changing calls)
53. Transaction atomicity bypass → **Safe** (Neo N3 provides full transaction atomicity)
54. GASAdmin null handling → **CONFIRMED** (I-02)
55. Block timestamp manipulation → **Limited** (Neo dBFT uses consensus time; no miner manipulation)

---

## Finding Details

### M-01: ProxySwapTokenInForTokenOut Checks Wrong Deposit Balance

**File:** `flamingo-contract-swap/Swap/flamingo-contract-swap/ProxyTemplate/ProxyTemplateContract.cs:180`

**Severity:** Medium — Denial of Service on core swap functionality

**Description:**
`ProxySwapTokenInForTokenOut` validates the sender's deposit balance against the LP token (Pair01) instead of the actual input token being swapped.

**Vulnerable Code (line 180):**
```csharp
Assert(DepositOf(Pair01, sender) >= amountIn, "Insufficient Balance");
```

**Correct Code (compare with ProxySwapTokenOutForTokenIn, line 222):**
```csharp
Assert(DepositOf(path[0], sender) >= amountInMax, "Insufficient Balance");
```

**Impact:**
1. Users who deposited Token0/Token1 into the Proxy for swapping but have NOT provided liquidity (thus have 0 LP tokens) are completely blocked from calling `ProxySwapTokenInForTokenOut`
2. Users must first add liquidity to obtain LP tokens before they can swap — an unnecessary and illogical prerequisite
3. Even when users DO have LP tokens, the validated amount is the LP balance, which is unrelated to the input token balance, causing incorrect approval gates

**No fund theft is possible** because `YBurn(path[0], sender, amountIn)` on line 193 correctly validates and deducts the input token's yToken balance. If the sender doesn't have enough input token deposited, the transaction reverts at this point.

**Recommendation:**
```diff
- Assert(DepositOf(Pair01, sender) >= amountIn, "Insufficient Balance");
+ Assert(DepositOf(path[0], sender) >= amountIn, "Insufficient Balance");
```

---

### M-02: Staking Profit Rate Integer Division Truncation Permanently Loses Rewards

**File:** `flamingo-contract-staking-n3/Staking/Staking.Record.cs:78`

**Severity:** Medium — Permanent loss of staking rewards

**Description:**
The per-unit staking profit rate is calculated using integer division:

```csharp
currentUintStackProfit = currentShareAmount / currentTotalStakingAmount;
```

When `currentShareAmount < currentTotalStakingAmount`, this truncates to **exactly 0**. Unlike proportional rounding (where small amounts are merely imprecise), this creates a **binary precision cliff** — either the full per-unit rate is computed, or ZERO is.

This is compounded by the FLM minting function which divides by `ConvertDecimal = 10^30`:
```csharp
// FLM.Owner.cs:83
amount = amount / ConvertDecimal;  // ConvertDecimal = 10^30
```

**Attack Scenario:**
1. Staking pool holds 1,000,000 tokens (totalStaked = 10^14 with 8 decimals)
2. Admin distributes reward of 500,000 tokens via `SetCurrentShareAmount(asset, 5 * 10^13, admin)`
3. `currentUintStackProfit = 5 * 10^13 / 10^14 = 0` (integer division)
4. ALL rewards for this distribution period are permanently lost
5. No user receives any FLM regardless of their stake size or duration
6. The lost rewards cannot be recovered by the admin or users

**Profit Accumulation Path:**
```
SettleProfit(recordTimestamp, amount, asset):
  SumProfit = HistorySum[now] - HistorySum[stake_time]
  profit = SumProfit * userAmount

UpdateHistoryUintStackProfitSum():
  increaseAmount = currentUintStackProfit * (now - lastTimestamp)  // = 0 * anything = 0
  HistorySum[now] = HistorySum[last] + 0  // No accumulation!

MintFLM():
  FLM.Mint(receiver, profit):
    mintedAmount = profit / 10^30  // Even non-zero profit may round to 0 here
```

**Impact:** Any distribution where `currentShareAmount < totalStaked` results in 100% reward loss for that period. With the additional 10^30 divisor at minting, even periods where `currentUintStackProfit > 0` may result in zero FLM if the accumulated profit is insufficient.

**Recommendation:**
Use scaled arithmetic with a precision multiplier:
```csharp
private static readonly BigInteger PRECISION = BigInteger.Pow(10, 18);

// In UpdateStackRecord:
if (currentTotalStakingAmount != 0)
{
    currentUintStackProfit = currentShareAmount * PRECISION / currentTotalStakingAmount;
}

// In SettleProfit:
BigInteger currentProfit = (SumProfit - MinusProfit) * amount / PRECISION;
```

---

### L-01: CheckFLM Public Function Has Unguarded Write Side Effects

**File:** `flamingo-contract-staking-n3/Staking/Staking.cs:139-147`

**Severity:** Low

**Description:**
`CheckFLM` is a public function intended to let users preview their pending rewards. However, it calls `UpdateStackRecord(asset, GetCurrentTimestamp())` which writes to three storage maps:
- `HistoryStackProfitSumStorage` (cumulative profit history)
- `CurrentRateTimestampStorage` (last update timestamp)
- `CurrentStackProfitStorage` (current per-unit profit rate)

```csharp
public static BigInteger CheckFLM(UInt160 fromAddress, UInt160 asset)
{
    ExecutionEngine.Assert(CheckAddrValid(true, fromAddress, asset), "CheckFLM: invald params");
    StakingReocrd stakingRecord = UserStakingStorage.Get(fromAddress, asset);
    UpdateStackRecord(asset, GetCurrentTimestamp());  // WRITES to storage!
    BigInteger newProfit = SettleProfit(stakingRecord.timeStamp, stakingRecord.amount, asset);
    var profitAmount = stakingRecord.Profit + newProfit;
    return profitAmount;
}
```

**Impact:**
1. Unlike `GetUintProfit` (marked `[Safe]`), `CheckFLM` is not read-only
2. Any user can force profit rate recalculation for any asset at any time
3. No reentrancy guard (unlike `ClaimFLM` and `Refund`)
4. Could be used as a griefing vector to force unnecessary storage writes (gas cost to other users in subsequent reads)

**Recommendation:** Mark as `[Safe]` and remove the `UpdateStackRecord` call, or add the reentrancy guard and access control.

---

### L-02: Pair OnNEP17Payment Validation Commented Out

**File:** `flamingo-contract-swap/Swap/flamingo-contract-swap/FlamingoSwapPair/FlamingoSwapPairContract.Nep17.cs:50-54`

**Severity:** Low

**Description:**
The pair contract's `OnNEP17Payment` has its token validation commented out:

```csharp
public static void OnNEP17Payment(UInt160 from, BigInteger amount, object data)
{
    //UInt160 asset = Runtime.CallingScriptHash;
    //Assert(asset == Token0 || asset == Token1, "Invalid Asset");
}
```

**Impact:** The pair contract accepts ANY NEP-17 token, not just Token0 and Token1. Tokens sent to the pair contract that are not Token0 or Token1 become permanently locked with no recovery mechanism. While this doesn't affect reserves or swap calculations (DynamicBalanceOf queries specific tokens), it creates a user fund loss risk for accidental transfers.

**Recommendation:** Uncomment the validation to reject non-pool tokens.

---

### I-01: Fund Fee Truncated to Zero for Small Swaps

**File:** `flamingo-contract-swap/Swap/flamingo-contract-swap/FlamingoSwapPair/FlamingoSwapPairContract.cs:196`

**Description:**
```csharp
var fee = amount0In * 5 / 10000;
```

For `amountIn < 2000` base units, the fund fee evaluates to 0 due to integer division. The protocol fee (0.05%) is not collected on small swaps.

**Impact:** Minor protocol revenue loss. The uncollected fee stays in the pool, marginally benefiting LPs instead of the fund address.

---

### I-02: GASAdmin Uninitialized Causes ClaimGASFrombNEO Permanent DoS

**File:** `flamingo-contract-swap/Swap/flamingo-contract-swap/FlamingoSwapPair/FlamingoSwapPairContract.Admin.cs:97-101`

**Description:**
```csharp
public static UInt160 GetGASAdmin()
{
    var admin = StorageGet(GASAdminKey);
    return (UInt160)admin;  // Returns null/zero if never set
}
```

If `SetGASAdmin` is never called, `GetGASAdmin()` returns a null/zero UInt160. `Runtime.CheckWitness(UInt160.Zero)` always fails, permanently blocking `ClaimGASFrombNEO`. The regular admin cannot call this function either (it checks GASAdmin, not the general admin).

---

## Architecture Assessment

### Defensive Patterns (Strong)
- **Reentrancy guard** in swap pair (EnteredStorage) — covers Swap, Mint, Burn
- **Whitelist-based access control** — pair functions restricted to approved routers
- **Constant product K-invariant** with fee accounting — mathematically sound
- **MINIMUM_LIQUIDITY = 1000** — prevents first-depositor inflation attack
- **Pre/post balance verification** in Router.RequestTransfer — catches transfer discrepancies
- **Transaction atomicity** — Neo N3 provides full ACID guarantees per transaction
- **Upgrade timelock** on staking contract — 24-hour delay for contract upgrades

### Design Observations
- Faithful Uniswap V2 implementation adapted for Neo N3
- TWAP price accumulator present but external-only (not used internally for swaps)
- ProxyTemplate provides custody wrapper with yToken receipt pattern
- FLM minting controlled by staking contract via IsAuthor/CallingScriptHash authorization
- Fund fee (0.05%) correctly deducted from the 0.3% swap fee, leaving 0.25% for LPs

### Scope of Prior Audits
The `flamingo-audits` repo contains audits for FUSD, OrderBook v2, Flocks, and LP-Staking — but NOT for the core swap contracts (Pair, Router, Factory) or the FLM/Staking contracts that are in the Immunefi scope. This may indicate these core contracts have not been independently audited since initial deployment.
