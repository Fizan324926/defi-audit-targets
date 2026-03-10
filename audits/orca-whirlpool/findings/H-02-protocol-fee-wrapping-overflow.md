# H-02: Protocol Fee Counter Uses Wrapping Arithmetic — Silent Overflow Loses Protocol Revenue

**Severity:** Medium (real confirmed bug; practical feasibility is very low for standard tokens)
**Files:**
- `programs/whirlpool/src/manager/swap_manager.rs:284` — explicit `wrapping_add` within a swap
- `programs/whirlpool/src/state/whirlpool.rs:274,278` — plain `+=` across swaps
**Build:** `overflow-checks = false` in workspace `Cargo.toml:14` — all plain `+=` silently wrap
**Status:** Confirmed code bug — borderline submittable to Immunefi

---

## Description

The protocol fee accumulator is updated using `wrapping_add` instead of `checked_add` or `saturating_add`:

```rust
// swap_manager.rs:284
next_protocol_fee = next_protocol_fee.wrapping_add(delta);
```

`next_protocol_fee` and `protocol_fee_owed_a/b` in the `Whirlpool` struct are `u64`. When the accumulated protocol fee balance overflows `u64::MAX` (≈ 18.4 × 10^18 in the token's smallest unit), the value wraps silently back to near-zero.

---

## Context: Two-Level Wrapping in the Protocol Fee Path

### Level 1: Within-swap accumulation (swap_manager.rs:284)

`calculate_fees()` is called once per step inside the swap loop. It accumulates `curr_protocol_fee` starting from `0` for each swap:

```rust
// swap_manager.rs:73 — starts at zero for each swap
let mut curr_protocol_fee: u64 = 0;

// swap_manager.rs:284 — explicit wrapping add per step
next_protocol_fee = next_protocol_fee.wrapping_add(delta);
```

The final `curr_protocol_fee` (the sum of all per-step fees for one swap) is returned as `PostSwapUpdate.next_protocol_fee`.

### Level 2: Across-swap accumulation (whirlpool.rs:274,278)

After each swap, `update_after_swap` adds the swap's protocol fee to the persistent counter:

```rust
// whirlpool.rs:271-279 — plain += across multiple swaps
if is_token_fee_in_a {
    self.fee_growth_global_a = fee_growth_global;
    self.protocol_fee_owed_a += protocol_fee;  // ← LINE 274: plain += wraps silently
} else {
    self.fee_growth_global_b = fee_growth_global;
    self.protocol_fee_owed_b += protocol_fee;  // ← LINE 278: plain += wraps silently
}
```

**Confirmed wrapping:** `Cargo.toml` (workspace root, line 14):
```toml
[profile.release]
overflow-checks = false
```

With `overflow-checks = false`, plain `+=` on `u64` wraps silently in the released BPF binary — identical behavior to `wrapping_add`.

### Summary

| Level | Location | Wrapping mechanism |
|-------|----------|--------------------|
| Within-swap | `swap_manager.rs:284` | Explicit `wrapping_add` |
| Across-swaps | `whirlpool.rs:274,278` | Plain `+=` + `overflow-checks = false` |

When `collect_protocol_fees` is called, `protocol_fee_owed_a/b` are transferred and reset to zero. If the counter wraps before collection, the protocol receives a fraction of the actual accumulated fees.

---

## Impact

| Scenario | Result |
|----------|--------|
| `protocol_fee_owed` wraps u64::MAX | Protocol collects near-zero instead of 2^64 tokens |
| No collect called for extended period on high-volume pool | Protocol loses up to u64::MAX tokens per pool per token |

**Who loses:** Orca protocol treasury (not LPs or users).

**Realistic threshold for overflow:**
- For USDC (6 decimals): `u64::MAX / 1e6 ≈ 18.4 × 10^12` USDC — essentially impossible
- For a 9-decimal token: `u64::MAX / 1e9 ≈ 18.4 × 10^9` tokens — still extremely high
- In practice, `collect_protocol_fees` would be called long before this threshold

---

## Root Cause

The comment in the Uniswap V3 whitepaper explains fee growth accumulators use intentional wrapping (Q128.128 overflow is designed). However, `protocol_fee_owed` is NOT a growth accumulator — it is a balance that should be strictly monotone between collections. Wrapping here is unintentional.

The fee growth accumulators (`fee_growth_global_a/b`) DO intentionally wrap (Uniswap V3 design). The protocol fee owed counter should NOT.

---

## Proof of Concept

```python
# From scripts/verify/verify_H02_protocol_fee_overflow.py
U64_MAX = 0xFFFF_FFFF_FFFF_FFFF

# Simulate repeated swaps that accumulate protocol fee
protocol_fee_owed = 0
delta_per_swap = 100_000  # 0.1 USDC per swap

num_swaps_to_overflow = (U64_MAX // delta_per_swap) + 1

# At this point, wrapping_add causes:
protocol_fee_owed = (protocol_fee_owed + delta_per_swap * num_swaps_to_overflow) & U64_MAX
# Result: small residual value, not u64::MAX + delta

print(f"Swaps to overflow: {num_swaps_to_overflow:,}")
print(f"Overflow results in protocol_fee_owed = {protocol_fee_owed}")
# For 0.1 USDC delta: ~184 trillion swaps needed
```

---

## Fix

```rust
// BEFORE:
next_protocol_fee_a = next_protocol_fee_a.wrapping_add(delta);

// AFTER: use saturating_add to prevent loss (fee is stuck at max until collected)
next_protocol_fee_a = next_protocol_fee_a.saturating_add(delta);
// OR use checked_add and require collect before proceeding:
next_protocol_fee_a = next_protocol_fee_a.checked_add(delta)
    .ok_or(ErrorCode::ProtocolFeeOverflow)?;
```

`saturating_add` is the simplest fix: it stalls protocol fee accumulation when the counter hits `u64::MAX` until `collect_protocol_fees` is called, after which accumulation resumes normally.

---

## References

- Vulnerable line: `swap_manager.rs:284`
- Protocol fee collection: `instructions/collect_protocol_fees.rs`
- Intentional wrapping (correct usage): `fee_growth_global_a/b` in `Whirlpool` and tick structs
