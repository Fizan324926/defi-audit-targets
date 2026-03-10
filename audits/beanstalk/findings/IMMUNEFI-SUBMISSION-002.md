# RETRACTED — calculateSopPerWell Division by Zero

## Status: FALSE POSITIVE

This submission has been retracted after mathematical verification proved the division-by-zero path is unreachable.

## Original Hypothesis

The `LibFlood.calculateSopPerWell()` function at line 429 performs `(shaveToLevel - uint256(wellDeltaBs[i - 1].deltaB)) / (i - 1)`. When i=1, this divides by zero.

## Why It's Unreachable

### Guard Condition
Line 406: `if (totalPositiveDeltaB < totalNegativeDeltaB || positiveDeltaBCount == 0)` returns zeros, ensuring we only continue when `totalPos >= totalNeg`.

### Mathematical Proof (for any k positive wells)

Given k positive wells with deltaBs d_1 >= d_2 >= ... >= d_k (sorted descending), and totalNeg = n where n <= totalPos = sum(d_i):

**Invariant:** The cumulative shaveToLevel reaching well i can never exceed the sum of all deltaBs from well i through well k.

At each step, the redistribution from smaller wells to larger wells is bounded by the total negative deltaB. The loop redistributes "excess shave" from wells whose deltaB is insufficient, but the total redistribution across all wells sums to at most n.

For the division-by-zero to trigger at i=1: `shaveToLevel > d_1`. But the accumulated shaveToLevel at i=1 equals `n - sum_of_actual_shaves_applied_to_wells_2_through_k`. Since each actual shave <= d_j for each well j, and the total sum of actual shaves <= n, the remainder for well 1 is at most `n - 0 = n` (if every other well got shaved to zero). But we need `n > d_1`, which combined with `n <= totalPos = d_1 + ... + d_k` only holds if `d_2 + ... + d_k < 0`, which is impossible since all positive wells have deltaB > 0.

**Formal for 2 wells:**
- shaveToLevel = floor(n/2)
- At i=2: if floor(n/2) > d_2, then new shaveToLevel = floor(n/2) + floor((floor(n/2) - d_2)/1) = 2*floor(n/2) - d_2 <= n - d_2
- At i=1: need n - d_2 > d_1, i.e., n > d_1 + d_2 = totalPos. Contradicts guard. QED.

**Formal for 3 wells:**
- shaveToLevel = floor(n/3)
- At i=3: if exceeded, redistribute to 2 remaining
- At i=2: if exceeded, redistribute to 1 remaining
- At i=1: accumulated <= n - d_2 - d_3 (if both absorbed zero) = n - totalPos + d_1 <= d_1 (since n <= totalPos). QED.

**General k:** By induction, the pattern holds. Integer truncation only reduces values, strengthening the bound.

### Verified Examples

Every example in the original submission that appeared to trigger the bug actually either:
1. Fails the guard (totalPos < totalNeg), or
2. The shaveToLevel at i=1 is less than d_1

Example: [+20, +1, -30] → totalPos=21, totalNeg=30 → caught by guard at line 406.
Example: [+100, +1, -100] → shaveToLevel=50, at i=2: 50>1→redistribute 49, shaveToLevel=99, at i=1: 99<100→safe.

### Note: Dead Code at Lines 416-421

The check `if (totalPositiveDeltaB < totalNegativeDeltaB)` at line 416 is unreachable dead code because the identical condition was already checked at line 406.
