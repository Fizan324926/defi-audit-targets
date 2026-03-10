# H-02: Protocol Fee Counter Uses `wrapping_add` — Silent Overflow Loses Protocol Revenue

**Severity:** Medium (theoretical High, but requires astronomical trading volume)
**File:** `programs/whirlpool/src/manager/swap_manager.rs`
**Line:** 284
**Status:** Open — Not yet reported

---

## Description

The protocol fee accumulator is updated using `wrapping_add` instead of `checked_add` or `saturating_add`:

```rust
// swap_manager.rs:284
next_protocol_fee = next_protocol_fee.wrapping_add(delta);
```

`next_protocol_fee` and `protocol_fee_owed_a/b` in the `Whirlpool` struct are `u64`. When the accumulated protocol fee balance overflows `u64::MAX` (≈ 18.4 × 10^18 in the token's smallest unit), the value wraps silently back to near-zero.

---

## Context: How Protocol Fees Accumulate

```rust
// swap_manager.rs — full context
fn calculate_protocol_fee(global_fee: u64, protocol_fee_rate: u16) -> u64 {
    ((global_fee as u128) * (protocol_fee_rate as u128)
        / PROTOCOL_FEE_RATE_MUL_VALUE as u128)
        .try_into()
        .unwrap()  // ← separate potential panic, but bounded by fee_rate constraint
}

// Line 280-284
let delta = calculate_protocol_fee(fee_amount, whirlpool.protocol_fee_rate);
match a_to_b {
    true  => next_protocol_fee_a = next_protocol_fee_a.wrapping_add(delta),
    false => next_protocol_fee_b = next_protocol_fee_b.wrapping_add(delta),
}
```

When `collect_protocol_fees` is called, the `protocol_fee_owed_a/b` values are transferred to the fee authority and reset to zero. If overflow occurs BETWEEN two `collect_protocol_fees` calls, the transferred amount will be much smaller than what was actually earned.

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
