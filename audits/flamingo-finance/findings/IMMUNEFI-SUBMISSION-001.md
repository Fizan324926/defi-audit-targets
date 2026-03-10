# Immunefi Bug Report: ProxySwapTokenInForTokenOut Wrong Balance Check — DoS on Proxy Swap Functionality

## Bug Description

The `ProxySwapTokenInForTokenOut` function in the `ProxyTemplateContract` validates the sender's deposit balance against the **LP token (Pair01)** instead of the actual **input token being swapped**. This prevents users who have deposited tokens for swapping from executing swaps through the Proxy unless they coincidentally also hold LP tokens from providing liquidity.

### Vulnerable Code

**File:** [`ProxyTemplateContract.cs:180`](https://github.com/flamingo-finance/flamingo-contract-swap/blob/master/Swap/flamingo-contract-swap/ProxyTemplate/ProxyTemplateContract.cs#L180)

```csharp
public static bool ProxySwapTokenInForTokenOut(UInt160 sender, BigInteger amountIn, BigInteger amountOutMin, bool isToken0to1, BigInteger deadLine)
{
    // ...
    UInt160[] path = isToken0to1 ? new UInt160[] { Token0, Token1 } : new UInt160[] { Token1, Token0 };
    // ...

    // BUG: checks LP token balance instead of input token balance
    Assert(DepositOf(Pair01, sender) >= amountIn, "Insufficient Balance");  // <-- LINE 180
    Approve(path[0], sender, Pair01, amountIn);  // approves input token (correct)

    // ...

    YBurn(path[0], sender, amountIn);   // burns input token yToken (correct)
    YMint(path[1], sender, balanceAfter - balanceBefore);  // mints output token yToken (correct)
}
```

### Correct Implementation (for comparison)

The sibling function `ProxySwapTokenOutForTokenIn` at line 222 correctly validates against the input token:

```csharp
Assert(DepositOf(path[0], sender) >= amountInMax, "Insufficient Balance");  // <-- LINE 222 (CORRECT)
```

### Root Cause

Line 180 uses `Pair01` (the LP token contract hash) as the first argument to `DepositOf()`, while it should use `path[0]` (the input swap token). This is a copy-paste error where `Pair01` was hardcoded instead of being derived from the swap path. Every other reference in the function (Approve, YBurn, YMint) correctly uses `path[0]` or `path[1]`.

## Impact

**Severity: Medium — Permanent DoS on core swap functionality for Proxy users**

### Direct Impact

1. **Users who deposited Token0 or Token1 for swapping but have NOT provided liquidity (0 LP tokens) are completely blocked from using `ProxySwapTokenInForTokenOut`**. The assertion on line 180 fails because their LP token deposit is 0, even though they have sufficient input token deposited.

2. **Users are forced to add liquidity before they can swap** — an illogical and unnecessary prerequisite that breaks the Proxy's intended UX. The Proxy is designed to allow users to deposit tokens and then choose to swap OR add liquidity. The bug forces liquidity provision before swapping.

3. **Even when users have LP tokens, the validation is semantically wrong** — it checks an unrelated balance (LP tokens) instead of the balance that will actually be consumed (input tokens). This creates confusing failure modes where:
   - User has 1000 yToken0 and 500 yLPToken → cannot swap 800 Token0 (check fails: 500 < 800)
   - User has 500 yToken0 and 1000 yLPToken → check passes (1000 >= 800) but YBurn fails (500 < 800)

### No Fund Theft

Fund theft is prevented by `YBurn(path[0], sender, amountIn)` on line 193, which correctly validates and deducts the input token's yToken balance. If the sender doesn't have enough input token deposited, the `UpdateBalance` function returns false (balance goes negative), and the entire transaction reverts.

### Affected Users

All users of the ProxyTemplate contract who:
- Deposit tokens for the purpose of swapping (not liquidity provision)
- Attempt to use `ProxySwapTokenInForTokenOut` (fixed-input swap)
- Do not have a coincidental LP token balance >= their swap amount

The sister function `ProxySwapTokenOutForTokenIn` (fixed-output swap) is NOT affected — it correctly validates against `path[0]`.

## Risk Breakdown

- **Difficulty to Exploit:** N/A (this is a DoS bug, not an exploit)
- **Weakness:** CWE-697 (Incorrect Comparison)
- **CVSS:** 5.3 (Medium) — Availability impact, no confidentiality/integrity impact

## Recommendation

Replace `Pair01` with `path[0]` on line 180 to match the correct pattern used in `ProxySwapTokenOutForTokenIn`:

```diff
  // Approve transfer
- Assert(DepositOf(Pair01, sender) >= amountIn, "Insufficient Balance");
+ Assert(DepositOf(path[0], sender) >= amountIn, "Insufficient Balance");
  Approve(path[0], sender, Pair01, amountIn);
```

## Proof of Concept

### Scenario Setup (Pseudocode — Neo N3 C# test)

```csharp
// Setup: Deploy ProxyTemplate with Token0=fWBTC, Token1=fUSDT, Pair01=FLP-fWBTC-fUSDT

// Step 1: User deposits 1000 fWBTC into Proxy
user.Call(proxyTemplate, "deposit", user, Token0_fWBTC, 1000_00000000);
// Result: user has yToken0 = 1000_00000000, yLPToken = 0

// Step 2: User attempts to swap 500 fWBTC for fUSDT via ProxySwapTokenInForTokenOut
user.Call(proxyTemplate, "proxySwapTokenInForTokenOut",
    user,           // sender
    500_00000000,   // amountIn (500 fWBTC)
    1,              // amountOutMin
    true,           // isToken0to1 (fWBTC → fUSDT)
    maxDeadline     // deadLine
);

// EXPECTED: Swap succeeds (user has 1000 yToken0 >= 500 amountIn)
// ACTUAL: Transaction FAILS at line 180:
//   DepositOf(Pair01, user) = 0 (no LP tokens deposited)
//   Assert(0 >= 500_00000000) → FAILS with "Insufficient Balance"

// Step 3: Verify the sister function works correctly
// User deposits 1000 fUSDT
user.Call(proxyTemplate, "deposit", user, Token1_fUSDT, 1000_00000000);

// ProxySwapTokenOutForTokenIn succeeds (uses correct check)
user.Call(proxyTemplate, "proxySwapTokenOutForTokenIn",
    user,           // sender
    100_00000000,   // amountOut (100 fUSDT)
    1000_00000000,  // amountInMax (max 1000 fWBTC)
    true,           // isToken0to1
    maxDeadline     // deadLine
);
// Result: Line 222 checks DepositOf(path[0], sender) = DepositOf(Token0, user) = 1000 >= 1000 ✓
// Swap succeeds!
```

### Key Evidence

1. **Line 180 (BUG):** `DepositOf(Pair01, sender)` — checks LP token
2. **Line 222 (CORRECT):** `DepositOf(path[0], sender)` — checks input token
3. **Line 181:** `Approve(path[0], sender, Pair01, amountIn)` — approves input token (not LP)
4. **Line 193:** `YBurn(path[0], sender, amountIn)` — burns input yToken (not LP)

The inconsistency between line 180 (checking LP token) and lines 181/193 (operating on input token) conclusively proves this is a bug, not intentional behavior.

## References

- ProxyTemplateContract.cs: https://github.com/flamingo-finance/flamingo-contract-swap/blob/master/Swap/flamingo-contract-swap/ProxyTemplate/ProxyTemplateContract.cs
- Bug line (180): `Assert(DepositOf(Pair01, sender) >= amountIn, "Insufficient Balance");`
- Correct pattern (222): `Assert(DepositOf(path[0], sender) >= amountInMax, "Insufficient Balance");`
