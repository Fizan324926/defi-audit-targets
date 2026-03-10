# Immunefi Bug Report: Staking Profit Rate Integer Division Truncation — Permanent Reward Loss

## Bug Description

The Flamingo staking contract calculates the per-unit profit rate using integer division that truncates to **exactly zero** when `currentShareAmount < currentTotalStakingAmount`. This creates a binary precision cliff where distributed rewards are permanently and irrecoverably lost — no user receives any FLM for that distribution period regardless of their stake size or duration.

### Vulnerable Code

**File:** [`Staking.Record.cs:78`](https://github.com/flamingo-finance/flamingo-contract-staking-n3/blob/main/Staking/Staking.Record.cs#L78)

```csharp
private static void UpdateStackRecord(UInt160 assetId, BigInteger currentTimestamp)
{
    // Settle history
    UpdateHistoryUintStackProfitSum(assetId, currentTimestamp);
    UpdateCurrentRecordTimestamp(assetId);

    var currentTotalStakingAmount = GetCurrentTotalAmount(assetId);  // balanceOf(stakingContract)
    var currentShareAmount = GetCurrentShareAmount(assetId);
    BigInteger currentUintStackProfit = 0;
    //TODO: 做正负号检查  (NOTE: TODO comment indicates incomplete implementation)
    if (currentTotalStakingAmount != 0)
    {
        currentUintStackProfit = currentShareAmount / currentTotalStakingAmount;  // <-- BUG: integer division
    }
    UpdateCurrentUintStackProfit(assetId, currentUintStackProfit);
}
```

### Amplification at FLM Minting

**File:** [`FLM.Owner.cs:83`](https://github.com/flamingo-finance/flamingo-contract-staking-n3/blob/main/FLM/FLM.Owner.cs#L83)

```csharp
public static bool Mint(UInt160 minter, UInt160 receiver, BigInteger amount)
{
    // ...
    amount = amount / ConvertDecimal;  // ConvertDecimal = 10^30
    TransferInternal(UInt160.Zero, receiver, amount);
    return true;
}
```

`ConvertDecimal = 10^30` (verified from hex `00000040eaed7446d09c2c9f0c` in little-endian BigInteger). This creates a second truncation point: even if some profit accumulates past the first truncation, the division by 10^30 can reduce it to zero again.

### Call Chain

```
SetCurrentShareAmount(asset, shareAmount, admin)
  → UpdateStackRecord(asset, timestamp)
    → currentUintStackProfit = shareAmount / totalStaked  // TRUNCATION POINT 1
    → UpdateHistoryUintStackProfitSum: increaseAmount = 0 * timeElapsed = 0

ClaimFLM(user, asset)
  → SettleProfit: profit = (SumProfit[now] - SumProfit[stake_time]) * userAmount  // = 0
  → MintFLM(user, profit=0, stakingContract)
    → FLM.Mint: mintedAmount = 0 / 10^30 = 0  // TRUNCATION POINT 2
```

## Impact

**Severity: Medium — Permanent freezing of unclaimed yield**

### Quantified Loss Scenario

**Scenario:** Pool with 10,000,000 FLM staked (10^15 base units), admin distributes 5,000,000 FLM reward (5 × 10^14 base units):

```
currentShareAmount = 5 × 10^14
currentTotalStakingAmount = 10^15
currentUintStackProfit = 5 × 10^14 / 10^15 = 0  (integer division)

Result: ALL 5,000,000 FLM in rewards are permanently lost.
No user can ever claim these rewards.
```

**Scenario:** Smaller pool with 1,000 FLM staked (10^11 base units), admin distributes 2,000 FLM reward (2 × 10^11 base units):

```
currentShareAmount = 2 × 10^11
currentTotalStakingAmount = 10^11
currentUintStackProfit = 2 × 10^11 / 10^11 = 2  (passes first truncation!)

After 1 day (86,400 seconds):
increaseAmount = 2 * 86400 = 172,800
profit = 172,800 * userStake

For user with 1,000 FLM (10^11 base units):
profit = 172,800 * 10^11 = 1.728 × 10^16

FLM minted = 1.728 × 10^16 / 10^30 = 0  (SECOND truncation at ConvertDecimal!)
```

Even when the first truncation point is avoided, the 10^30 ConvertDecimal creates a massive second barrier. Users need to accumulate `profit >= 10^30` before any FLM is minted — requiring extremely large stakes held for extremely long periods.

### Binary Cliff vs Proportional Rounding

This is NOT standard rounding loss. Standard rounding loses a fraction proportional to the remainder. Here, the loss is **binary**: either `shareAmount >= totalStaked` (full rate computed) or `shareAmount < totalStaked` (rate = 0, complete loss). There is no middle ground.

### Permanence

The lost rewards cannot be recovered because:
1. `HistoryStackProfitSumStorage` permanently records `increaseAmount = 0` for the affected period
2. The timestamp advances past the distribution period
3. No admin function exists to retroactively correct profit history
4. Subsequent distributions create new entries but cannot fill the gap

## Risk Breakdown

- **Difficulty to Exploit:** N/A (systematic design flaw, not an active exploit)
- **Weakness:** CWE-190 (Integer Overflow or Wraparound) — specifically, integer truncation at division
- **CVSS:** 5.3 (Medium) — Availability impact on yield distribution

## Recommendation

Implement scaled arithmetic to preserve precision through the division:

```csharp
// Add precision constant
private static readonly BigInteger PRECISION = BigInteger.Pow(10, 18);

// In UpdateStackRecord:
if (currentTotalStakingAmount != 0)
{
    // Scale UP before division to preserve fractional precision
    currentUintStackProfit = currentShareAmount * PRECISION / currentTotalStakingAmount;
}

// In SettleProfit:
private static BigInteger SettleProfit(BigInteger recordTimestamp, BigInteger amount, UInt160 asset)
{
    BigInteger MinusProfit = GetHistoryUintStackProfitSum(asset, recordTimestamp);
    BigInteger SumProfit = GetHistoryUintStackProfitSum(asset, GetCurrentTimestamp());
    // Scale DOWN after multiplication to remove precision factor
    BigInteger currentProfit = (SumProfit - MinusProfit) * amount / PRECISION;
    return currentProfit;
}
```

This ensures that even when `shareAmount < totalStaked`, the fractional rate is preserved with 18 decimal places of precision.

### Alternative: Adjust ConvertDecimal

If modifying the staking contract is not feasible, adjust `ConvertDecimal` in the FLM contract to a smaller value. The current 10^30 creates an unnecessarily high minting threshold. A value of 10^8 (matching FLM decimals) would be more appropriate:

```csharp
// In FLM.cs - adjust ConvertDecimal
[InitialValue("0000000000e1f505", ContractParameterType.ByteArray)]  // 10^8 in little-endian
private static readonly BigInteger ConvertDecimal;
```

## Proof of Concept

```csharp
// Pseudocode demonstrating the precision loss

// Setup
BigInteger totalStaked = 1_000_000_00000000;  // 1M tokens with 8 decimals = 10^14
BigInteger shareAmount = 500_000_00000000;    // 500K tokens reward = 5 × 10^13

// UpdateStackRecord calculation
BigInteger uintProfit = shareAmount / totalStaked;
// = 5 × 10^13 / 10^14
// = 0 (integer division truncation!)

Console.WriteLine($"Per-unit profit rate: {uintProfit}");  // Output: 0

// After 1 day (86400 seconds)
BigInteger timeElapsed = 86400;
BigInteger increaseAmount = uintProfit * timeElapsed;
// = 0 * 86400 = 0

Console.WriteLine($"Accumulated profit: {increaseAmount}");  // Output: 0

// User with 100,000 tokens tries to claim
BigInteger userAmount = 100_000_00000000;  // 10^13
BigInteger userProfit = increaseAmount * userAmount;
// = 0 * 10^13 = 0

Console.WriteLine($"User profit: {userProfit}");  // Output: 0

// Even if somehow non-zero, ConvertDecimal kills it
BigInteger ConvertDecimal = BigInteger.Pow(10, 30);
BigInteger mintedFLM = userProfit / ConvertDecimal;
// = 0 / 10^30 = 0

Console.WriteLine($"FLM minted: {mintedFLM}");  // Output: 0

// RESULT: 500,000 tokens in rewards permanently lost.
// Zero FLM minted to any user.

// ----- Comparison: With PRECISION scaling -----
BigInteger PRECISION = BigInteger.Pow(10, 18);
BigInteger uintProfitScaled = shareAmount * PRECISION / totalStaked;
// = 5 × 10^13 * 10^18 / 10^14
// = 5 × 10^17

BigInteger increaseAmountScaled = uintProfitScaled * timeElapsed;
// = 5 × 10^17 * 86400 = 4.32 × 10^22

BigInteger userProfitScaled = increaseAmountScaled * userAmount / PRECISION;
// = 4.32 × 10^22 * 10^13 / 10^18 = 4.32 × 10^17

BigInteger mintedFLMScaled = userProfitScaled / ConvertDecimal;
// = 4.32 × 10^17 / 10^30 = 0 (still too small for ConvertDecimal!)

// With adjusted ConvertDecimal = 10^8:
BigInteger ConvertDecimalFixed = BigInteger.Pow(10, 8);
BigInteger mintedFLMFixed = userProfitScaled / ConvertDecimalFixed;
// = 4.32 × 10^17 / 10^8 = 4.32 × 10^9 = 43.2 FLM ✓
```

## References

- Staking.Record.cs (truncation point): https://github.com/flamingo-finance/flamingo-contract-staking-n3/blob/main/Staking/Staking.Record.cs
- FLM.Owner.cs (ConvertDecimal amplification): https://github.com/flamingo-finance/flamingo-contract-staking-n3/blob/main/FLM/FLM.Owner.cs
- FLM.cs (ConvertDecimal value): https://github.com/flamingo-finance/flamingo-contract-staking-n3/blob/main/FLM/FLM.cs
- Staking.cs (full claim flow): https://github.com/flamingo-finance/flamingo-contract-staking-n3/blob/main/Staking/Staking.cs
