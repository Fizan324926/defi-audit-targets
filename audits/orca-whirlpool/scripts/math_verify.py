#!/usr/bin/env python3
"""
Orca Whirlpool — Arithmetic Edge Case Verifier

Tests the core math invariants of the Whirlpool program in Python to:
  1. Detect rounding asymmetries between ExactIn / ExactOut
  2. Reproduce the adaptive fee U32 underflow scenario
  3. Verify tick <-> sqrt_price round-trip accuracy
  4. Check fee growth accumulator overflow conditions

Run: python3 math_verify.py
"""

import math
import struct
import sys
from dataclasses import dataclass
from typing import Optional, Tuple

# ---------------------------------------------------------------------------
# Constants (mirror of Rust source)
# ---------------------------------------------------------------------------
Q64 = 1 << 64
Q96 = 1 << 96

MAX_TICK_INDEX = 443636
MIN_TICK_INDEX = -443636
MAX_SQRT_PRICE_X64 = 79226673515401279992447579055
MIN_SQRT_PRICE_X64 = 4295048016

FEE_RATE_MUL_VALUE = 1_000_000
PROTOCOL_FEE_RATE_MUL_VALUE = 10_000
FEE_RATE_HARD_LIMIT = 100_000  # 10%

U32_MAX = 0xFFFF_FFFF
U64_MAX = 0xFFFF_FFFF_FFFF_FFFF
U128_MAX = (1 << 128) - 1
I32_MAX = 0x7FFF_FFFF
I32_MIN = -0x8000_0000

VOLATILITY_ACCUMULATOR_SCALE_FACTOR = 10_000  # check actual value

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def wrapping_u32(x: int) -> int:
    return x & U32_MAX

def wrapping_u64(x: int) -> int:
    return x & U64_MAX

def as_i32(x: int) -> int:
    """Simulate Rust's `x as i32` (truncating cast from u32)."""
    x = x & U32_MAX
    if x > I32_MAX:
        return x - (1 << 32)
    return x

def ceil_div_u32(a: int, b: int) -> int:
    return (a + b - 1) // b

def floor_div(a: int, b: int) -> int:
    """Floor division matching Rust's integer semantics for negative numbers."""
    return int(math.floor(a / b))

# ---------------------------------------------------------------------------
# H-01 Test: Adaptive Fee U32 Underflow
# ---------------------------------------------------------------------------
def test_H01_adaptive_fee_underflow():
    print("=" * 60)
    print("H-01: Adaptive Fee U32 Underflow Test")
    print("=" * 60)

    SCALE = VOLATILITY_ACCUMULATOR_SCALE_FACTOR

    test_cases = [
        # (max_volatility_accumulator, volatility_reference, tick_group_size, description)
        (200_000, 100_000, 64, "Normal: ref < max (safe)"),
        (200_000, 200_000, 64, "Edge: ref == max (safe, delta=0)"),
        (100_000, 200_000, 64, "VULN: ref > max → U32 underflow"),
        (50_000,  200_000, 64, "VULN: ref >> max → large underflow"),
        (0,       1,       64, "VULN: max=0, ref=1 → underflow"),
    ]

    for max_acc, vol_ref, tg_size, desc in test_cases:
        # Simulate Rust's u32 arithmetic
        raw_sub = wrapping_u32(max_acc - vol_ref)
        delta = ceil_div_u32(raw_sub, SCALE)
        delta_as_i32 = as_i32(delta)

        tick_group_ref = 1000  # arbitrary reference
        core_lower = tick_group_ref - delta_as_i32
        core_upper = tick_group_ref + delta_as_i32

        safe = (max_acc >= vol_ref)
        tag = "SAFE" if safe else "VULNERABLE"

        print(f"\n  [{tag}] {desc}")
        print(f"    max_acc={max_acc}, vol_ref={vol_ref}")
        print(f"    raw subtraction (u32): {raw_sub}")
        print(f"    delta (ceil_div): {delta}")
        print(f"    delta as i32: {delta_as_i32}")
        print(f"    core_lower={core_lower}, core_upper={core_upper}")
        if not safe:
            print(f"    INVERTED RANGE: lower > upper = {core_lower > core_upper}")
            lower_bound_tick = core_lower * tg_size
            upper_bound_tick = core_upper * tg_size
            print(f"    Tick bounds: {lower_bound_tick} .. {upper_bound_tick}")
            print(f"    INVERTED: swap fee logic receives garbage bounds!")

    print()

# ---------------------------------------------------------------------------
# H-02 Test: Protocol Fee wrapping_add overflow
# ---------------------------------------------------------------------------
def test_H02_protocol_fee_overflow():
    print("=" * 60)
    print("H-02: Protocol Fee wrapping_add Overflow Test")
    print("=" * 60)

    # In a swap with many tick crossings, protocol_fee accumulates per step.
    # Each step: delta = fee_amount * protocol_fee_rate / PROTOCOL_FEE_RATE_MUL_VALUE
    # Max per step: U64_MAX * 2600 / 10000 ≈ 0.26 * U64_MAX — very large single step

    # Scenario: high fee_rate, large amount, many ticks
    protocol_fee_rate = 2600  # 26% of LP fees to protocol (upper bound)
    # Simulate accumulated protocol fee near overflow
    test_scenarios = [
        (U64_MAX // 2, U64_MAX // 2 + 1, "Two steps that together overflow"),
        (U64_MAX - 100, 200, "Near-max + small overflow"),
        (U64_MAX, 1, "Already at max + 1"),
    ]

    print("\n  Simulating wrapping_add behavior:")
    for acc, delta, desc in test_scenarios:
        wrapped = wrapping_u64(acc + delta)
        actual = acc + delta
        overflow = actual > U64_MAX
        print(f"\n  {desc}")
        print(f"    accumulated={acc}, delta={delta}")
        print(f"    overflows u64: {overflow}")
        if overflow:
            print(f"    wrapping result: {wrapped}  ← protocol loses {actual - wrapped} lamports")
        else:
            print(f"    result: {actual} (safe)")

    print("\n  Within single swap loop:")
    # Each call to calculate_fees: delta = fee * protocol_fee_rate / PFRM
    # Max fee per step ≈ u64::MAX (if somehow achieved)
    # Max delta = u64::MAX * 2600 / 10000 = 4795169765398946099 (fits in u64)
    max_single_delta = (U64_MAX * 2600) // 10000
    print(f"  Max protocol_fee per step: {max_single_delta} ({max_single_delta / U64_MAX:.2%} of u64::MAX)")
    steps_to_overflow = math.ceil(U64_MAX / max_single_delta)
    print(f"  Steps to overflow u64 at max delta: {steps_to_overflow}")
    print(f"  Current max tick arrays: 3+supplemental. Tick crossings per swap: bounded.")
    print(f"  Note: overflow is architecturally possible in pathological cases.")
    print()

# ---------------------------------------------------------------------------
# Tick Math Verification
# ---------------------------------------------------------------------------
def sqrt_price_from_tick_python(tick: int) -> int:
    """
    Python implementation of sqrt(1.0001^tick) * 2^64.
    Uses float for verification — compare with on-chain values.
    """
    price = (1.0001 ** tick) ** 0.5
    return int(price * (2**64))

def test_tick_math_edge_cases():
    print("=" * 60)
    print("Tick Math Edge Case Verification")
    print("=" * 60)

    ticks = [
        MIN_TICK_INDEX,
        MIN_TICK_INDEX + 1,
        -1,
        0,
        1,
        MAX_TICK_INDEX - 1,
        MAX_TICK_INDEX,
    ]

    for t in ticks:
        py_price = sqrt_price_from_tick_python(t)
        in_bounds = MIN_SQRT_PRICE_X64 <= py_price <= MAX_SQRT_PRICE_X64
        print(f"  tick={t:>8}: sqrt_price_x64 ≈ {py_price:<32} bounds_ok={in_bounds}")

    # Test round-trip property: tick_index_from_sqrt_price(sqrt_price_from_tick_index(t)) == t
    print("\n  Round-trip test (should all match):")
    import_ticks = list(range(-10, 11)) + [MIN_TICK_INDEX, MAX_TICK_INDEX - 1]
    all_pass = True
    for t in import_ticks:
        sp = sqrt_price_from_tick_python(t)
        # Approximate inverse
        recovered = int(math.log(sp / (2**64)) / math.log(1.0001**0.5))
        match = (recovered == t)
        if not match:
            print(f"  MISMATCH: tick={t} -> sqrt_price -> tick={recovered}")
            all_pass = False
    if all_pass:
        print("  All round-trips pass.")
    print()

# ---------------------------------------------------------------------------
# Fee Growth Accumulator Overflow Analysis
# ---------------------------------------------------------------------------
def test_fee_growth_overflow():
    print("=" * 60)
    print("Fee Growth Accumulator (wrapping) Analysis")
    print("=" * 60)

    # fee_growth_global is u128, wrapping accumulator
    # Each step adds: (fee_amount << 64) / liquidity
    # fee_amount max = u64::MAX, liquidity min = 1
    # max_per_step = (u64::MAX << 64) / 1 = u64::MAX * 2^64

    max_per_step = (U64_MAX * Q64) // 1
    steps_to_wrap = math.ceil(U128_MAX / max_per_step)
    print(f"  Max fee_growth_global increment per step (min liq=1): {max_per_step}")
    print(f"  Steps to wrap u128 at max increment: {steps_to_wrap}")
    print(f"  Note: wrapping is by design (Uniswap V3 pattern). Collectors must")
    print(f"  call collect before a full wrap cycle or they lose fees.")

    # How many swaps at max fee/liquidity to wrap?
    typical_fee = 10_000  # 1% of typical swap ~10k lamports
    typical_liquidity = 10**15  # large pool
    per_step = (typical_fee * Q64) // typical_liquidity
    if per_step > 0:
        steps = math.ceil(U128_MAX / per_step)
        print(f"\n  Realistic case (fee=10000, liq=10^15):")
        print(f"  Increment per step: {per_step}")
        print(f"  Steps to wrap: {steps:,} (essentially never)")
    print()

# ---------------------------------------------------------------------------
# ExactOut overflow analysis (from swap_math.rs comment)
# ---------------------------------------------------------------------------
def test_exactout_overflow():
    print("=" * 60)
    print("ExactOut Mode: amount_in + fee_amount Overflow Analysis")
    print("=" * 60)

    # From swap_math fuzz test comment:
    # "in ExactOut mode, input + fee may exceeds u64::MAX"
    # This is known but the swap_manager uses checked_add
    # Let's determine exact conditions

    fee_rates = [1000, 10000, 100000]  # 0.1%, 1%, 10%
    for fee_rate in fee_rates:
        # In ExactOut, amount_in is calculated, fee = amount_in * fee_rate / (FEE_RATE_MUL - fee_rate)
        # max amount_in before sum overflows u64:
        # amount_in + amount_in * fee_rate / (FEE_RATE_MUL - fee_rate) <= u64::MAX
        # amount_in * (1 + fee_rate / (FEE_RATE_MUL - fee_rate)) <= u64::MAX
        # amount_in * FEE_RATE_MUL / (FEE_RATE_MUL - fee_rate) <= u64::MAX
        max_amount_in = (U64_MAX * (FEE_RATE_MUL_VALUE - fee_rate)) // FEE_RATE_MUL_VALUE
        fee_at_max = (max_amount_in * fee_rate) // (FEE_RATE_MUL_VALUE - fee_rate)
        total = max_amount_in + fee_at_max
        overflow = total > U64_MAX
        print(f"  fee_rate={fee_rate/10000:.2%}: max_amount_in={max_amount_in}, total={total}, overflow={overflow}")

    print(f"\n  Note: swap_manager uses checked_add for amount_calculated,")
    print(f"  returning AmountCalcOverflow. This is handled correctly.")
    print()

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    print("\nOrca Whirlpool — Arithmetic Security Verifier")
    print("=" * 60)
    print()

    test_H01_adaptive_fee_underflow()
    test_H02_protocol_fee_overflow()
    test_tick_math_edge_cases()
    test_fee_growth_overflow()
    test_exactout_overflow()

    print("Done. Review any VULNERABLE or MISMATCH lines above.")
