#!/usr/bin/env python3
"""
Orca Whirlpool — Adaptive Fee State Space Fuzzer

Explores the adaptive fee state machine for:
  1. States where volatility_reference can exceed max_volatility_accumulator
  2. Tick group index drift / inversion
  3. Fee rate computation overflow paths
  4. Major swap timestamp logic edge cases

Run: python3 fuzz_adaptive_fee.py [--seed N] [--iters N]
"""

import random
import math
import argparse
import sys
from dataclasses import dataclass, field
from typing import Optional, List, Tuple

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
U32_MAX = 0xFFFF_FFFF
U64_MAX = 0xFFFF_FFFF_FFFF_FFFF
VOLATILITY_ACCUMULATOR_SCALE_FACTOR = 10_000
ADAPTIVE_FEE_CONTROL_FACTOR_DENOMINATOR = 1_000_000_000
FEE_RATE_HARD_LIMIT = 100_000  # 10%
MAX_TICK_INDEX = 443636
MIN_TICK_INDEX = -443636

# ---------------------------------------------------------------------------
# Python simulation of AdaptiveFeeVariables
# ---------------------------------------------------------------------------
@dataclass
class AdaptiveFeeConstants:
    filter_period: int         # u16
    decay_period: int          # u16
    reduction_factor: int      # u16  (0..10000)
    adaptive_fee_control_factor: int   # u32
    max_volatility_accumulator: int    # u32
    tick_group_size: int       # u16
    major_swap_threshold_ticks: int    # u16

@dataclass
class AdaptiveFeeVariables:
    last_reference_update_timestamp: int  # u64
    last_major_swap_timestamp: int        # u64
    volatility_accumulator: int           # u32
    volatility_reference: int             # u32
    tick_group_index_reference: int       # i32

def wrapping_u32(x: int) -> int:
    return x & U32_MAX

def wrapping_u64(x: int) -> int:
    return x & U64_MAX

def ceil_div_u32(a: int, b: int) -> int:
    if b == 0:
        return U32_MAX  # saturate
    return (a + b - 1) // b

def floor_div_i32(a: int, b: int) -> int:
    return int(math.floor(a / b))

def as_i32(x: int) -> int:
    x = x & U32_MAX
    if x > 0x7FFF_FFFF:
        return x - (1 << 32)
    return x

def min_u32(a: int, b: int) -> int:
    return min(a & U32_MAX, b & U32_MAX)

def saturating_add_u32(a: int, b: int) -> int:
    r = a + b
    return min(r, U32_MAX)

# ---------------------------------------------------------------------------
# Simulate update_reference
# ---------------------------------------------------------------------------
def update_reference(
    vars: AdaptiveFeeVariables,
    new_tick_group_index: int,
    timestamp: int,
    consts: AdaptiveFeeConstants,
) -> AdaptiveFeeVariables:
    """Python simulation of AdaptiveFeeVariables::update_reference"""
    v = AdaptiveFeeVariables(**vars.__dict__)

    if timestamp == v.last_reference_update_timestamp:
        # Same timestamp, just update tick group index reference if needed
        # (simplified)
        return v

    elapsed = timestamp - v.last_reference_update_timestamp
    in_filter_period = elapsed <= consts.filter_period
    in_decay_period = elapsed <= consts.filter_period + consts.decay_period

    if in_filter_period:
        # No change to volatility_reference
        pass
    elif in_decay_period:
        # Decay: volatility_reference = volatility_accumulator * reduction_factor
        v.volatility_reference = (v.volatility_accumulator * consts.reduction_factor) // 10_000
    else:
        # Full reset: volatility_reference = 0
        v.volatility_reference = 0
        v.tick_group_index_reference = new_tick_group_index

    v.last_reference_update_timestamp = timestamp
    return v

# ---------------------------------------------------------------------------
# Simulate update_volatility_accumulator
# ---------------------------------------------------------------------------
def update_volatility_accumulator(
    vars: AdaptiveFeeVariables,
    tick_group_index: int,
    consts: AdaptiveFeeConstants,
) -> AdaptiveFeeVariables:
    """Python simulation of AdaptiveFeeVariables::update_volatility_accumulator"""
    v = AdaptiveFeeVariables(**vars.__dict__)

    delta = abs(tick_group_index - v.tick_group_index_reference)
    increment = delta * VOLATILITY_ACCUMULATOR_SCALE_FACTOR
    new_acc = saturating_add_u32(v.volatility_reference, increment)
    v.volatility_accumulator = min_u32(new_acc, consts.max_volatility_accumulator)
    return v

# ---------------------------------------------------------------------------
# Simulate FeeRateManager::new - the vulnerable part
# ---------------------------------------------------------------------------
def fee_rate_manager_new_vulnerable(
    consts: AdaptiveFeeConstants,
    vars: AdaptiveFeeVariables,
    tick_group_index: int,
) -> dict:
    """
    Simulates the vulnerable calculation in FeeRateManager::new.
    Returns info about what happens (including underflow scenarios).
    """
    max_acc = consts.max_volatility_accumulator
    vol_ref = vars.volatility_reference

    # Rust: max_acc - vol_ref  (u32 subtraction, wraps in release mode)
    raw_sub = wrapping_u32(max_acc - vol_ref)
    underflow = vol_ref > max_acc

    # ceil_division_u32
    delta = ceil_div_u32(raw_sub, VOLATILITY_ACCUMULATOR_SCALE_FACTOR)

    # Cast to i32 (truncating)
    delta_i32 = as_i32(delta)
    negative_delta = delta_i32 < 0

    core_lower_index = vars.tick_group_index_reference - delta_i32
    core_upper_index = vars.tick_group_index_reference + delta_i32
    inverted = core_lower_index > core_upper_index

    lower_tick = core_lower_index * consts.tick_group_size
    upper_tick = core_upper_index * consts.tick_group_size + consts.tick_group_size

    return {
        "underflow": underflow,
        "raw_sub": raw_sub,
        "delta": delta,
        "delta_i32": delta_i32,
        "negative_delta": negative_delta,
        "core_lower_index": core_lower_index,
        "core_upper_index": core_upper_index,
        "inverted": inverted,
        "lower_tick": lower_tick,
        "upper_tick": upper_tick,
    }

# ---------------------------------------------------------------------------
# Compute adaptive fee rate
# ---------------------------------------------------------------------------
def compute_adaptive_fee_rate(consts: AdaptiveFeeConstants, vars: AdaptiveFeeVariables) -> int:
    """
    adaptive_fee = (volatility_accumulator^2 * control_factor) / DENOM
    """
    sq = vars.volatility_accumulator ** 2  # u64 in Rust
    rate = (sq * consts.adaptive_fee_control_factor) // ADAPTIVE_FEE_CONTROL_FACTOR_DENOMINATOR
    return min(rate, FEE_RATE_HARD_LIMIT)  # capped

def compute_total_fee_rate(base_fee_rate: int, consts: AdaptiveFeeConstants, vars: AdaptiveFeeVariables) -> int:
    adaptive = compute_adaptive_fee_rate(consts, vars)
    total = base_fee_rate + adaptive
    return min(total, FEE_RATE_HARD_LIMIT)

# ---------------------------------------------------------------------------
# Fuzzer
# ---------------------------------------------------------------------------
class AdaptiveFeeFuzzer:
    def __init__(self, seed: int = 42, iters: int = 10_000):
        self.rng = random.Random(seed)
        self.iters = iters
        self.findings: List[dict] = []

    def random_consts(self) -> AdaptiveFeeConstants:
        filter_p = self.rng.randint(1, 3600)
        decay_p  = self.rng.randint(filter_p, filter_p + 86400)
        return AdaptiveFeeConstants(
            filter_period=filter_p,
            decay_period=decay_p,
            reduction_factor=self.rng.randint(0, 10000),
            adaptive_fee_control_factor=self.rng.randint(0, U32_MAX),
            max_volatility_accumulator=self.rng.randint(0, U32_MAX),
            tick_group_size=self.rng.choice([1, 8, 16, 64, 128, 256]),
            major_swap_threshold_ticks=self.rng.randint(1, 1000),
        )

    def random_vars(self, consts: AdaptiveFeeConstants) -> AdaptiveFeeVariables:
        max_acc = consts.max_volatility_accumulator
        # Sometimes set volatility_reference > max to explore underflow
        if self.rng.random() < 0.1:  # 10% chance of buggy state
            vol_ref = self.rng.randint(max_acc, U32_MAX)
        else:
            vol_ref = self.rng.randint(0, max_acc)

        vol_acc = self.rng.randint(0, max_acc)
        return AdaptiveFeeVariables(
            last_reference_update_timestamp=self.rng.randint(0, 10**9),
            last_major_swap_timestamp=self.rng.randint(0, 10**9),
            volatility_accumulator=vol_acc,
            volatility_reference=vol_ref,
            tick_group_index_reference=self.rng.randint(-100_000, 100_000),
        )

    def fuzz(self):
        print(f"Running {self.iters} adaptive fee fuzz iterations...")
        underflows = 0
        inversions = 0
        negative_deltas = 0
        fee_overflows = 0

        for i in range(self.iters):
            consts = self.random_consts()
            vars = self.random_vars(consts)
            tick_idx = self.rng.randint(MIN_TICK_INDEX, MAX_TICK_INDEX)
            tick_group_idx = floor_div_i32(tick_idx, consts.tick_group_size)

            result = fee_rate_manager_new_vulnerable(consts, vars, tick_group_idx)

            if result["underflow"]:
                underflows += 1
                if result["inverted"]:
                    inversions += 1
                if result["negative_delta"]:
                    negative_deltas += 1
                # Record interesting finding
                if len(self.findings) < 5:
                    self.findings.append({
                        "iter": i,
                        "max_acc": consts.max_volatility_accumulator,
                        "vol_ref": vars.volatility_reference,
                        "tick_group_ref": vars.tick_group_index_reference,
                        **result,
                    })

            # Check fee rate overflow
            total_fee = compute_total_fee_rate(1000, consts, vars)
            if total_fee > FEE_RATE_HARD_LIMIT:
                fee_overflows += 1

        pct = lambda n: f"{n}/{self.iters} ({100*n/self.iters:.2f}%)"
        print(f"\nResults:")
        print(f"  Underflow cases:      {pct(underflows)}")
        print(f"  Inverted ranges:      {pct(inversions)}")
        print(f"  Negative delta casts: {pct(negative_deltas)}")
        print(f"  Fee rate overflows:   {pct(fee_overflows)}")

        if self.findings:
            print(f"\nSample underflow scenarios:")
            for f in self.findings[:3]:
                print(f"  iter={f['iter']}")
                print(f"    max_acc={f['max_acc']}, vol_ref={f['vol_ref']}")
                print(f"    raw_sub={f['raw_sub']}, delta_i32={f['delta_i32']}")
                print(f"    core_range=[{f['core_lower_index']}, {f['core_upper_index']}] inverted={f['inverted']}")
                print()

# ---------------------------------------------------------------------------
# Simulate admin reducing max_volatility_accumulator after pool is live
# ---------------------------------------------------------------------------
def simulate_admin_attack():
    print("=" * 60)
    print("Admin Attack Simulation: Reduce max_volatility_accumulator")
    print("=" * 60)

    # Initial pool state with normal parameters
    consts = AdaptiveFeeConstants(
        filter_period=60,
        decay_period=600,
        reduction_factor=5000,  # 50%
        adaptive_fee_control_factor=1_000_000,
        max_volatility_accumulator=200_000,
        tick_group_size=64,
        major_swap_threshold_ticks=100,
    )

    vars = AdaptiveFeeVariables(
        last_reference_update_timestamp=1_700_000_000,
        last_major_swap_timestamp=1_700_000_000,
        volatility_accumulator=180_000,
        volatility_reference=150_000,  # After some volatile swaps
        tick_group_index_reference=1000,
    )

    print(f"\n  Initial state:")
    print(f"  max_volatility_accumulator = {consts.max_volatility_accumulator}")
    print(f"  volatility_reference       = {vars.volatility_reference}")
    print(f"  (safe: ref <= max)")

    r1 = fee_rate_manager_new_vulnerable(consts, vars, 1000)
    print(f"\n  Before admin action:")
    print(f"    delta={r1['delta']}, core_range=[{r1['core_lower_index']}, {r1['core_upper_index']}]")
    print(f"    inverted={r1['inverted']}")

    # Admin reduces max_volatility_accumulator (via set_adaptive_fee_constants)
    consts_after = AdaptiveFeeConstants(**consts.__dict__)
    consts_after.max_volatility_accumulator = 50_000  # Drastically reduced

    print(f"\n  Admin calls set_adaptive_fee_constants(max_volatility_accumulator=50_000)")
    print(f"  Now: max_acc={consts_after.max_volatility_accumulator} < vol_ref={vars.volatility_reference}")

    r2 = fee_rate_manager_new_vulnerable(consts_after, vars, 1000)
    print(f"\n  After admin action (next swap):")
    print(f"    raw_sub (u32 wrapped) = {r2['raw_sub']}")
    print(f"    delta = {r2['delta']}")
    print(f"    delta_as_i32 = {r2['delta_i32']}")
    print(f"    core_lower = {r2['core_lower_index']}, core_upper = {r2['core_upper_index']}")
    print(f"    INVERTED RANGE: {r2['inverted']}")
    print(f"    NEGATIVE DELTA CAST: {r2['negative_delta']}")
    if r2['inverted']:
        print(f"    IMPACT: swap fee computation uses garbage tick group bounds")
        print(f"    RESULT: incorrect adaptive fee or DoS depending on downstream handling")
    print()

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Orca Whirlpool Adaptive Fee Fuzzer")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--iters", type=int, default=50_000)
    args = parser.parse_args()

    print("\nOrca Whirlpool — Adaptive Fee Security Fuzzer")
    print("=" * 60)
    print()

    simulate_admin_attack()

    fuzzer = AdaptiveFeeFuzzer(seed=args.seed, iters=args.iters)
    fuzzer.fuzz()
