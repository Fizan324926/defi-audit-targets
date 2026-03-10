# H-01 (REVISED → LOW): Unsafe U32 Subtraction in Adaptive Fee Range Calculation

**Severity:** Low / Informational (originally assessed High — downgraded after full invariant analysis)
**File:** `programs/whirlpool/src/manager/fee_rate_manager.rs`
**Lines:** 62–74
**Status:** Open — Not yet reported

---

## Description

In `FeeRateManager::new()`, the adaptive fee range calculation performs a raw u32 subtraction:

```rust
// Lines 62-64 — RAW U32 SUBTRACTION (no explicit guard)
let max_volatility_accumulator_tick_group_index_delta = ceil_division_u32(
    adaptive_fee_constants.max_volatility_accumulator
        - adaptive_fee_variables.volatility_reference,   // u32 - u32
    VOLATILITY_ACCUMULATOR_SCALE_FACTOR as u32,
);
```

In Rust release mode (used by Solana BPF), `u32` subtraction wraps on underflow without panicking. If `volatility_reference > max_volatility_accumulator`, the result wraps to an astronomically large value, producing a swap range of ±27M ticks that disables the skip optimization.

---

## Why It Is Low (Not High) — Invariant Analysis

After full analysis of the codebase, the invariant `volatility_reference <= max_volatility_accumulator` is maintained by multiple layers:

### Layer 1: update_reference() produces bounded output

```rust
// oracle.rs ~line 186-189
self.volatility_reference = (u64::from(self.volatility_accumulator)
    * u64::from(adaptive_fee_constants.reduction_factor)
    / u64::from(REDUCTION_FACTOR_DENOMINATOR))
    as u32;
```

- `volatility_accumulator` is capped to `max_volatility_accumulator` by `min()` in `update_volatility_accumulator`
- `reduction_factor <= REDUCTION_FACTOR_DENOMINATOR` (10000) is validated on creation
- Therefore: `volatility_reference = accumulator * factor / denom ≤ max_acc`

### Layer 2: set_adaptive_fee_constants always resets variables

```rust
// instructions/adaptive_fee/set_adaptive_fee_constants.rs:55-56
oracle.initialize_adaptive_fee_constants(updated_constants, whirlpool.tick_spacing)?;
oracle.reset_adaptive_fee_variables();  // ← always resets to default (all zeros)
```

When the admin changes `max_volatility_accumulator`, the Oracle's `AdaptiveFeeVariables` are atomically reset to default (all zeros, including `volatility_reference = 0`). So the "admin reduces max after high volatility" attack path is CLOSED.

### Layer 3: AdaptiveFeeVariables::default() always valid

```rust
volatility_reference: 0  // 0 ≤ any max_volatility_accumulator
```

---

## Residual Risk

The code has **no explicit assertion** of the invariant at the subtraction site. This means:

- A future code change that adds a new path to modify `volatility_reference` independently of `max_volatility_accumulator` could silently introduce this bug
- Any state corruption (serialization bug, migration error) could trigger wrap
- The defensive programming fix is trivial

---

## Recommended Fix

```rust
// Add guard before subtraction
let accumulator_headroom = adaptive_fee_constants.max_volatility_accumulator
    .saturating_sub(adaptive_fee_variables.volatility_reference);
let max_volatility_accumulator_tick_group_index_delta =
    ceil_division_u32(accumulator_headroom, VOLATILITY_ACCUMULATOR_SCALE_FACTOR as u32);
```

---

## References

- Vulnerable code: `fee_rate_manager.rs:62-74`
- Invariant source 1: `state/oracle.rs` — `update_reference()` and `update_volatility_accumulator()`
- Invariant source 2: `instructions/adaptive_fee/set_adaptive_fee_constants.rs:56`
- Validation: `state/adaptive_fee_tier.rs` — `validate_constants()` validates `reduction_factor <= 10_000`
