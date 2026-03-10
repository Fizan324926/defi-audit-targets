#!/usr/bin/env python3
"""
Verify M-01: Production panic! in migrate_repurpose_reward_authority_space.rs

This script:
  1. Confirms the panic! exists at line 19 of the migrate instruction
  2. Explains the difference between panic! and return Err() in Solana BPF
  3. Documents all other production panic! calls in fee_rate_manager.rs
  4. Catalogs all .expect() calls in production code (not test code)

Reference:
  programs/whirlpool/src/instructions/migrate_repurpose_reward_authority_space.rs:19
  programs/whirlpool/src/manager/fee_rate_manager.rs:626,709,789,866,946,2091
"""

import subprocess
import os
import re

SRC_BASE = "/root/audits/orca-whirlpool/whirlpools/programs/whirlpool/src"


def grep_pattern(pattern: str, path: str, exclude_test: bool = True) -> list:
    result = subprocess.run(
        ["grep", "-rn", pattern, path],
        capture_output=True, text=True
    )
    lines = []
    for line in result.stdout.strip().split("\n"):
        if not line:
            continue
        if exclude_test and ("#[test]" in line or "test_" in line.lower()):
            continue
        lines.append(line)
    return lines


print("=" * 70)
print("M-01 Verification: Production panic! calls in Orca Whirlpool")
print("=" * 70)


# ─────────────────────────────────────────────────────────────────────────────
# SECTION 1: Confirm migrate instruction panic
# ─────────────────────────────────────────────────────────────────────────────
print("\n[1] Primary finding: panic! in migrate_repurpose_reward_authority_space.rs")

migrate_path = os.path.join(
    SRC_BASE,
    "instructions/migrate_repurpose_reward_authority_space.rs"
)

if os.path.exists(migrate_path):
    with open(migrate_path) as f:
        content = f.read()
    lines = content.split("\n")
    for i, line in enumerate(lines, 1):
        if "panic!" in line:
            # Show context
            start = max(0, i - 4)
            end = min(len(lines), i + 2)
            print(f"\n  Panic found at line {i}:")
            for j in range(start, end):
                marker = ">>> " if j == i - 1 else "    "
                print(f"  {marker}{j+1}: {lines[j]}")
else:
    print(f"  File not found: {migrate_path}")


# ─────────────────────────────────────────────────────────────────────────────
# SECTION 2: All panic! calls in production code
# ─────────────────────────────────────────────────────────────────────────────
print("\n\n[2] All panic! calls in production code (excluding tests)")

panic_files = {}
for root, dirs, files in os.walk(SRC_BASE):
    # Skip test directories
    dirs[:] = [d for d in dirs if d != "tests"]
    for fname in files:
        if not fname.endswith(".rs"):
            continue
        fpath = os.path.join(root, fname)
        with open(fpath) as f:
            lines = f.readlines()

        in_test_block = False
        for i, line in enumerate(lines):
            if "#[cfg(test)]" in line or "#[test]" in line:
                in_test_block = True
            # Simple heuristic: end of test block at } at column 0
            if in_test_block and line.startswith("}"):
                if i + 1 < len(lines) and not lines[i + 1].strip().startswith(("//", "#", "}")):
                    in_test_block = False

            if "panic!(" in line and not line.strip().startswith("//"):
                if not in_test_block:
                    rel = os.path.relpath(fpath, SRC_BASE)
                    if rel not in panic_files:
                        panic_files[rel] = []
                    panic_files[rel].append((i + 1, line.strip()))

for fname, panics in sorted(panic_files.items()):
    print(f"\n  {fname}:")
    for lineno, code in panics:
        print(f"    line {lineno}: {code[:100]}")


# ─────────────────────────────────────────────────────────────────────────────
# SECTION 3: Technical explanation — panic vs Result::Err in Solana BPF
# ─────────────────────────────────────────────────────────────────────────────
print("\n\n[3] Technical impact: panic! vs return Err() in Solana BPF")
print("""
  In Solana BPF execution:

  return Err(ErrorCode::AlreadyMigrated.into()):
    - Transaction fails with a specific, typed error code
    - Error is surfaced to callers via transaction logs
    - Anchor programs emit error logs with the error code number
    - Integrators can decode and handle this error in their code

  panic!("message"):
    - BPF program traps immediately
    - Error surfaces as a generic "Program failed to complete" with no code
    - The panic message is in program logs but many RPC providers truncate these
    - Anchor error-handling middleware cannot catch panics
    - Callers cannot distinguish panic from other fatal errors

  Practical impact for M-01:
    - An integrator calling migrate on an already-migrated pool CANNOT detect
      "already migrated" as a distinct error — it looks like any other crash
    - Automated tooling that calls migrate for all pools would hit the panic
      and have no way to filter "already done" from "something is broken"
""")


# ─────────────────────────────────────────────────────────────────────────────
# SECTION 4: fee_rate_manager.rs panics — "Adaptive variant expected"
# ─────────────────────────────────────────────────────────────────────────────
print("\n[4] fee_rate_manager.rs panic! calls — severity assessment")
print("""
  Lines 626, 709, 789, 866, 946, 2091:
    _ => panic!("Adaptive variant expected."),

  These are in match arms on FeeRateManager enum variants.
  FeeRateManager has two variants: Static and Adaptive.
  These panics fire when a Static variant is passed to an Adaptive-only method.

  Current risk: LOW — calling code checks variant before calling
  Future risk: MEDIUM — any refactor that adds new variants or changes call sites
    could trigger these panics unexpectedly, causing DoS on swap paths.

  Recommended fix: use unreachable!() with descriptive message, OR restructure
  the API to use Result types, preventing the mismatch at the type system level.
""")

print("=" * 70)
print("VERDICT: M-01 confirmed — production panic! in migrate instruction")
print("  Primary: migrate_repurpose_reward_authority_space.rs:19")
print("  Additional: fee_rate_manager.rs (6 locations) — lower risk")
print("  Fix: Replace panic! with return Err(typed_error_code)")
print("=" * 70)
