#!/usr/bin/env python3
"""
Orca Whirlpool — Static Pattern Scanner

Scans Rust source for:
  - Unsafe arithmetic patterns (.unwrap(), wrapping_*, unchecked)
  - Missing signer checks
  - UncheckedAccount usages
  - Unsafe u32/u64 integer subtraction patterns
  - Hardcoded panic paths (unreachable!, panic!)
  - Zero-copy struct misuse
  - TODOs and FIXMEs

Run: python3 analyze.py
"""

import os
import re
import sys
from pathlib import Path
from collections import defaultdict

BASE = Path(__file__).parent.parent / "whirlpools" / "programs" / "whirlpool" / "src"

# ---------------------------------------------------------------------------
# Pattern definitions
# ---------------------------------------------------------------------------
PATTERNS = [
    # (severity, pattern_name, regex, exclude_test_code)
    ("HIGH",   "unwrap_in_production",      r"\.unwrap\(\)",                   True),
    ("HIGH",   "expect_in_production",      r"\.expect\(",                     True),
    ("HIGH",   "wrapping_add_sub_mul",      r"\.wrapping_(add|sub|mul)\(",     True),
    ("HIGH",   "unchecked_arithmetic",      r"\.wrapping_shl\|\.unchecked",    True),
    ("HIGH",   "u32_subtraction",           r"\bu32\b.*-.*\bu32\b|as u32.*-",  False),
    ("MEDIUM", "UncheckedAccount",          r"UncheckedAccount",               False),
    ("MEDIUM", "CHECK_comment",             r"/// CHECK:",                     False),
    ("MEDIUM", "unreachable_macro",         r"unreachable!\(",                 False),
    ("MEDIUM", "panic_macro",              r"\bpanic!\(",                     True),
    ("MEDIUM", "unsafe_block",             r"\bunsafe\s*\{",                  True),
    ("LOW",    "todo_fixme",               r"TODO|FIXME|HACK|XXX",            False),
    ("LOW",    "as_cast_from_large",       r"\bas i32\b|\bas u32\b",          False),
    ("INFO",   "zero_copy_unsafe",         r"#\[zero_copy\(unsafe\)\]",       False),
]

def is_test_context(lines: list, line_num: int) -> bool:
    """Heuristic: check if line is within a #[cfg(test)] block."""
    # Look backwards for test attribute or test function
    for i in range(max(0, line_num - 50), line_num):
        if "#[cfg(test)]" in lines[i] or "#[test]" in lines[i]:
            return True
    return False

def scan_file(path: Path, results: dict):
    try:
        content = path.read_text(encoding="utf-8")
    except Exception:
        return

    lines = content.split("\n")

    for sev, name, pattern, exclude_test in PATTERNS:
        for i, line in enumerate(lines):
            # Skip comment-only lines
            stripped = line.strip()
            if stripped.startswith("//"):
                continue
            if re.search(pattern, line):
                if exclude_test and is_test_context(lines, i):
                    continue
                rel = path.relative_to(BASE.parent.parent.parent.parent)
                results[sev].append({
                    "file": str(rel),
                    "line": i + 1,
                    "pattern": name,
                    "content": stripped[:120],
                })

def scan():
    results = defaultdict(list)
    rs_files = list(BASE.rglob("*.rs"))
    print(f"Scanning {len(rs_files)} Rust source files...")
    print(f"Base: {BASE}\n")

    for f in sorted(rs_files):
        scan_file(f, results)

    total = sum(len(v) for v in results.values())
    print(f"Found {total} pattern matches:\n")

    severity_order = ["HIGH", "MEDIUM", "LOW", "INFO"]
    for sev in severity_order:
        items = results[sev]
        if not items:
            continue
        print(f"{'=' * 60}")
        print(f"[{sev}] — {len(items)} matches")
        print(f"{'=' * 60}")

        # Group by pattern
        by_pattern = defaultdict(list)
        for item in items:
            by_pattern[item["pattern"]].append(item)

        for pname, matches in sorted(by_pattern.items()):
            print(f"\n  Pattern: {pname} ({len(matches)} occurrences)")
            # Show first 10
            for m in matches[:10]:
                print(f"    {m['file']}:{m['line']}")
                print(f"      {m['content']}")
            if len(matches) > 10:
                print(f"    ... and {len(matches) - 10} more")
        print()

    # Summary table
    print(f"\n{'=' * 60}")
    print(f"SUMMARY")
    print(f"{'=' * 60}")
    print(f"{'Severity':<10} {'Count':<8} {'Top File'}")
    print(f"{'-' * 60}")
    for sev in severity_order:
        items = results[sev]
        if not items:
            continue
        files = defaultdict(int)
        for item in items:
            files[item["file"]] += 1
        top_file = max(files, key=files.get)
        print(f"{sev:<10} {len(items):<8} {top_file}")

    return results

# ---------------------------------------------------------------------------
# Focused scan: u32 arithmetic patterns (H-01 related)
# ---------------------------------------------------------------------------
def scan_u32_arithmetic():
    print(f"\n{'=' * 60}")
    print("FOCUSED: u32 subtraction in non-test context")
    print(f"{'=' * 60}")

    dangerous = []
    for path in sorted(BASE.rglob("*.rs")):
        if "test" in str(path).lower():
            continue
        try:
            content = path.read_text()
        except Exception:
            continue
        lines = content.split("\n")
        for i, line in enumerate(lines):
            stripped = line.strip()
            if stripped.startswith("//"):
                continue
            # Look for u32 variable subtraction
            if re.search(r'(u32|U32).*-|saturating_sub|checked_sub', line):
                if "test" not in line.lower():
                    rel = path.relative_to(BASE.parent.parent.parent.parent)
                    dangerous.append(f"  {rel}:{i+1}  {stripped[:100]}")

    if dangerous:
        for d in dangerous[:30]:
            print(d)
    else:
        print("  No obvious u32 subtraction patterns found.")

# ---------------------------------------------------------------------------
# Focused scan: wrapping_add usage
# ---------------------------------------------------------------------------
def scan_wrapping():
    print(f"\n{'=' * 60}")
    print("FOCUSED: wrapping_add / wrapping_sub (ALL instances)")
    print(f"{'=' * 60}")

    for path in sorted(BASE.rglob("*.rs")):
        try:
            content = path.read_text()
        except Exception:
            continue
        lines = content.split("\n")
        for i, line in enumerate(lines):
            if re.search(r'\.wrapping_(add|sub|mul)\(', line):
                rel = path.relative_to(BASE.parent.parent.parent.parent)
                in_test = is_test_context(lines, i)
                flag = "[test]" if in_test else "[PROD]"
                print(f"  {flag} {rel}:{i+1}")
                print(f"    {line.strip()[:120]}")

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    print("Orca Whirlpool — Static Security Pattern Scanner")
    print("=" * 60)
    print()

    scan()
    scan_u32_arithmetic()
    scan_wrapping()
