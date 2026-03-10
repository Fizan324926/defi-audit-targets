# Vyper 0.3.7 Compiler Bugs -- Comprehensive Security Analysis

## Summary

Yearn V3 Vault (`VaultV3.vy`) is compiled with `# @version 0.3.7`. This version of the Vyper compiler
has **multiple known security vulnerabilities** that were fixed in later releases (0.3.8, 0.3.10, 0.4.0, 0.4.1).
This document catalogs every known issue, whether VaultV3.vy is affected, and the severity for the vault specifically.

**Total known Vyper 0.3.7 vulnerabilities: 18+**
**VaultV3.vy actually affected: 3 (1 Medium, 1 Low, 1 Informational)**

---

## CRITICAL FINDING: Reentrancy Guard (NOT Affected)

### GHSA-5824-cm3x-3c38 / CVE-2023-39363 -- Incorrectly Allocated Named Re-entrancy Locks
- **Affected versions:** 0.2.15, 0.2.16, 0.3.0 only
- **Fixed in:** 0.3.1
- **VaultV3.vy status: NOT AFFECTED** -- Version 0.3.7 is well past the fix.
- **Details:** The Curve pool exploit ($52M+ stolen, July 2023) was caused by this bug where each
  `@nonreentrant` decorator got a unique storage slot regardless of key, breaking cross-function
  reentrancy protection. VaultV3.vy uses `@nonreentrant("lock")` on 7 functions and is safe.

### GHSA-3hg2-r75x-g69m / CVE-2023-42441 -- Incorrect Re-entrancy Lock with Empty String Key
- **Affected versions:** >=0.2.9, <0.3.10
- **Fixed in:** 0.3.10
- **VaultV3.vy status: NOT AFFECTED** -- VaultV3.vy uses `@nonreentrant("lock")` (non-empty string).
  The bug only triggers with empty-string keys like `@nonreentrant("")`.

---

## VULNERABILITIES THAT AFFECT VaultV3.vy

### 1. [MEDIUM] GHSA-f5x6-7qgp-jhf3 / CVE-2023-37902 -- ecrecover Returns Undefined Data for Invalid Signatures

- **Affected versions:** <=0.3.9
- **Fixed in:** 0.3.10
- **CVSS:** 5.3 (Medium)
- **VaultV3.vy status: AFFECTED** -- The `_permit()` function (line 385) uses `ecrecover()`.

**Technical Details:**
The `ecrecover` precompile does not fill the output buffer if the signature does not verify. The Vyper
compiler reads memory location 0 regardless of whether the precompile succeeded. If the compiler has
written specially crafted data to memory location 0 (via hashmap access or immutable read) just before
the `ecrecover` call, a signature check might pass on an invalid signature.

**VaultV3.vy Impact Analysis:**
```vyper
# Line 385-387
assert ecrecover(
    digest, v, r, s
) == owner, "invalid signature"
```
The code computes `keccak256(concat(...))` which writes to memory location 0 as part of the hash
computation, then calls `ecrecover`. If ecrecover fails (invalid signature), memory location 0 may
contain leftover data from the keccak256 computation. The result is compared to `owner`.

**Practical exploitability: LOW.** For this to be exploitable, the leftover memory value would need to
exactly match the `owner` address, which is extremely unlikely given that keccak256 output is
pseudorandom. However, the theoretical vulnerability exists.

**Recommendation:** Upgrade to Vyper >= 0.3.10 or add an explicit `owner != empty(address)` check
(which VaultV3.vy already does at line 366).

---

### 2. [LOW] GHSA-g2xh-c426-v8mf -- Reversed Order of Side Effects for Some Operations

- **Affected versions:** <=0.4.2 (still present in many versions)
- **Fixed in:** 0.4.0+ (partially), fully in later versions
- **VaultV3.vy status: THEORETICALLY AFFECTED** but no exploitable instances found.

**Technical Details:**
For operations like `unsafe_add`, `unsafe_sub`, `unsafe_mul`, `unsafe_div`, and comparison operators,
the compiler evaluates arguments right-to-left instead of left-to-right. This becomes problematic when
argument evaluation produces side effects (state changes, external calls, storage reads/writes).

**VaultV3.vy Usage:**
VaultV3.vy uses `unsafe_add` and `unsafe_sub` extensively (25+ instances). However, all instances use
simple variable references or constant expressions as arguments -- none involve side-effecting
expressions:
```vyper
self.balance_of[sender] = unsafe_sub(sender_balance, amount)      # Both args are simple values
self.balance_of[receiver] = unsafe_add(self.balance_of[receiver], amount)  # Storage read + value
```
The `self.balance_of[receiver]` read is a side-effect-free storage read. No instance in VaultV3.vy
passes a function call, `pop()`, or state-modifying expression as an argument to these operations.

**Practical exploitability: NONE with current code patterns.**

---

### 3. [INFORMATIONAL] GHSA-2q8v-3gqq-4f8p -- concat Built-in Can Corrupt Memory

- **Affected versions:** <=0.3.10
- **Fixed in:** 0.4.0
- **VaultV3.vy status: PRESENT but unexploitable.

**VaultV3.vy uses `concat` in 3 places:**
1. Line 370-383: `_permit()` -- building EIP-712 digest with `keccak256(concat(...))`
2. Line 2182-2188: `domain_separator()` -- building domain separator with `keccak256(concat(...))`

In both cases, `concat` operates on fixed-size `bytes32` values and short byte literals (`b'\x19\x01'`).
The memory corruption bug relates to buffer allocation with dynamically-sized inputs. The fixed-size
inputs used in VaultV3.vy are not affected.

**Practical exploitability: NONE.**

---

## VULNERABILITIES PRESENT IN COMPILER BUT NOT TRIGGERED BY VaultV3.vy

### 4. GHSA-w9g2-3w7p-72g9 / CVE-2023-30629 -- raw_call with revert_on_failure=False and max_outsize=0

- **Affected versions:** 0.3.1 through 0.3.7
- **Fixed in:** 0.3.8
- **Severity:** Medium (7.4)
- **VaultV3.vy status: NOT AFFECTED** -- VaultV3.vy does not use `raw_call` anywhere.

### 5. GHSA-ph9x-4vc9-m39g / CVE-2023-32059 -- Incorrect Ordering of Default Arguments in Internal Calls

- **Affected versions:** <0.3.8
- **Fixed in:** 0.3.8
- **Severity:** High
- **VaultV3.vy status: NOT AFFECTED**
- **Condition:** Requires internal functions with **more than 1** default argument.
- VaultV3.vy has only one internal function with default args:
  `_revoke_strategy(strategy: address, force: bool=False)` -- has exactly **1** default argument, not "more than 1".

### 6. GHSA-6r8q-pfpv-7cgj / CVE-2023-32058 -- Integer Overflow in range(a, a+N) Loops

- **Affected versions:** <=0.3.7
- **Fixed in:** 0.3.8
- **Severity:** High (7.5)
- **VaultV3.vy status: NOT AFFECTED** -- VaultV3.vy does not use `for i in range(...)` loops at all.
  All loops use `for strategy in _strategies` (iterator-based, not range-based).

### 7. GHSA-3p37-3636-q8wv / CVE-2023-31146 -- OOB DynArray Access (LHS and RHS Same Array)

- **Affected versions:** <=0.3.7
- **Fixed in:** 0.3.8
- **Severity:** High (8.7)
- **VaultV3.vy status: NOT AFFECTED** -- No DynArray self-assignment patterns exist.
  VaultV3.vy's DynArray usage is read-iteration (`for strategy in _strategies`) and
  `append()` / reassignment (`self.default_queue = new_queue`), never self-referential assignment.

### 8. GHSA-mgv8-gggw-mrg6 / CVE-2023-30837 -- Storage Allocator Overflow

- **Affected versions:** <0.3.8
- **Fixed in:** 0.3.8
- **Severity:** High
- **VaultV3.vy status: NOT AFFECTED** -- The vulnerability requires an extremely large storage array
  that can overflow mod 2^256 back to overwrite the owner variable. VaultV3.vy uses no large storage
  arrays susceptible to this; the largest array is `DynArray[address, 10]` (MAX_QUEUE = 10).

### 9. GHSA-vxmm-cwh2-q762 / CVE-2023-32675 -- Nonpayable Default Function Can Receive Ether

- **Affected versions:** <=0.3.7
- **Fixed in:** 0.3.8
- **Severity:** Low (3.7)
- **VaultV3.vy status: NOT AFFECTED** -- VaultV3.vy has no `__default__` function.

### 10. GHSA-4hwq-4cpm-8vmx / CVE-2024-24564 -- extract32 Can Read Dirty Memory

- **Affected versions:** <=0.3.10
- **Fixed in:** 0.4.0
- **Severity:** Low (3.7)
- **VaultV3.vy status: NOT AFFECTED** -- VaultV3.vy does not use `extract32`.

### 11. GHSA-6845-xw22-ffxv / CVE-2024-24559 -- sha3 Codegen Bug

- **Affected versions:** <=0.3.10
- **Fixed in:** 0.4.0+
- **VaultV3.vy status: NOT AFFECTED** -- This bug can only be triggered by writing IR by hand
  using the `fang` binary (formerly `vyper-ir`). It cannot be triggered from regular Vyper source code.

### 12. GHSA-vgf2-gvx8-xwc3 -- Precompile Success Not Checked (ecrecover, identity)

- **Affected versions:** <=0.4.0
- **Fixed in:** 0.4.1
- **VaultV3.vy status: THEORETICAL CONCERN** -- VaultV3.vy uses `ecrecover` at line 385.
  However, the practical impact is negligible: the ecrecover precompile consumes 3000 gas, so after an
  OOG failure, only ~47 gas remains (1/64 of the pre-call gas), which is insufficient for any
  meaningful execution. The `assert` statement checking the result would fail.

### 13. GHSA-cx2q-hfxr-rj97 / CVE-2023-42460 -- _abi_decode Not Validated in Complex Expressions

- **Affected versions:** >=0.3.4, <0.3.10
- **Fixed in:** 0.3.10
- **VaultV3.vy status: NOT AFFECTED** -- VaultV3.vy does not use `_abi_decode`.

### 14. GHSA-9p8r-4xp4-gw5w / CVE-2024-26149 -- _abi_decode Memory Overflow

- **Affected versions:** <=0.3.10
- **Fixed in:** 0.4.0
- **VaultV3.vy status: NOT AFFECTED** -- No `_abi_decode` usage.

### 15. GHSA-c647-pxm2-c52w -- Memory Corruption in raw_call/create_from_blueprint/create_copy_of via msize

- **Affected versions:** >=0.3.4, <=0.3.10
- **Fixed in:** 0.4.0
- **VaultV3.vy status: NOT AFFECTED** -- VaultV3.vy uses none of these builtins.

### 16. GHSA-9x7f-gwxq-6f2c / CVE-2024-24561 -- slice() Bounds Check Overflow

- **Affected versions:** <=0.3.10
- **Fixed in:** 0.4.0
- **VaultV3.vy status: NOT AFFECTED** -- VaultV3.vy does not use `slice()`.

### 17. GHSA-5jrj-52x8-m64h -- Multiple Evaluation of sqrt() Argument

- **Affected versions:** <=0.3.10
- **Fixed in:** 0.4.0
- **VaultV3.vy status: NOT AFFECTED** -- VaultV3.vy does not use `sqrt()` or `isqrt()`.

### 18. GHSA-4hg4-9mf5-wxxq -- Incorrect Order of Evaluation for Some Builtins

- **Affected versions:** <=0.3.10
- **Fixed in:** 0.4.0
- **VaultV3.vy status: NOT TRIGGERED** -- This is the builtin-specific variant of the side-effects
  ordering issue. VaultV3.vy does not pass side-effecting expressions to affected builtins.

### 19. GHSA-4w26-8p97-f4jp / CVE-2025-27105 -- AugAssign Evaluation Order OOB Write

- **Affected versions:** <=0.4.0
- **Fixed in:** 0.4.1
- **VaultV3.vy status: NOT AFFECTED** -- Requires `a[idx] += a.pop()` pattern (AugAssign on
  DynArray element with RHS modifying the same array). VaultV3.vy's AugAssign operations
  (`self.total_idle += ...`, `self.total_debt -= ...`) operate on simple storage variables, not
  DynArray elements.

### 20. GHSA-gp3w-2v2m-p686 / CVE-2024-24560 -- External Calls Overflow Return Data

- **Affected versions:** <=0.3.10
- **Fixed in:** 0.4.0
- **VaultV3.vy status: NOT AFFECTED** -- This requires external calls whose return data
  overwrites the input buffer. VaultV3.vy's external calls use standard interface-based calls
  with proper return types, not raw_call patterns.

---

## ANALYSIS OF VaultV3.vy SPECIFIC PATTERNS

### @nonreentrant("lock") Usage -- SAFE
All 7 `@nonreentrant("lock")` decorated functions use the same key `"lock"` (non-empty string).
The reentrancy lock bug (0.2.15-0.3.0) is not present in 0.3.7, and the empty-string bug does not
apply since the key is `"lock"`.

Protected functions:
- `process_report` (line 1637)
- `buy_debt` (line 1648)
- `update_debt` (line 1746)
- `deposit` (line 1794)
- `mint` (line 1813)
- `withdraw` (line 1826)
- `redeem` (line 1849)

### unsafe_add / unsafe_sub / unsafe_mul Usage -- SAFE (Design Choice)
VaultV3.vy uses `unsafe_sub` (16 instances) and `unsafe_add` (8 instances) as a deliberate gas
optimization. In every case, the code performs bounds checking *before* the unsafe operation:

```vyper
# Pattern: check first, then unsafe_sub
if (current_allowance < max_value(uint256)):
    assert current_allowance >= amount, "insufficient allowance"
    self._approve(owner, spender, unsafe_sub(current_allowance, amount))

# Pattern: guard ensures no underflow
sender_balance: uint256 = self.balance_of[sender]
assert sender_balance >= amount, "insufficient funds"
self.balance_of[sender] = unsafe_sub(sender_balance, amount)
```

This is correct usage -- the unsafe variants save gas on redundant overflow checks.

### ecrecover Usage -- THEORETICAL CONCERN
The `_permit` function (line 385) uses `ecrecover` and is subject to CVE-2023-37902. While the
theoretical vulnerability exists, practical exploitation requires the leftover memory at address 0
to exactly match the `owner` address parameter, which is probabilistically negligible.

### concat Usage -- SAFE
Three uses of `concat`, all with fixed-size `bytes32` inputs for EIP-712 hashing. Not affected by
the concat memory corruption bug which requires dynamic-size inputs.

### DynArray Usage -- SAFE
VaultV3.vy uses `DynArray[address, MAX_QUEUE]` (MAX_QUEUE=10) for withdrawal queues. No
self-referential assignment patterns or pop-during-iteration patterns exist.

### default_return_value Usage -- SAFE
Three instances of `default_return_value=True` for ERC20 interactions (approve, transfer,
transferFrom). This is a Vyper feature for handling non-compliant tokens, not affected by any
known compiler bug.

---

## SEVERITY SUMMARY

| # | Vulnerability | CVE | Affects VaultV3.vy? | Severity |
|---|---|---|---|---|
| 1 | Reentrancy lock (Curve exploit) | CVE-2023-39363 | NO (fixed in 0.3.1) | N/A |
| 2 | ecrecover undefined data | CVE-2023-37902 | YES (permit function) | Medium (theoretical) |
| 3 | Reversed side effects order | N/A | YES (no exploitable instances) | Low |
| 4 | concat memory corruption | N/A | YES (unexploitable with fixed inputs) | Informational |
| 5 | raw_call success value | CVE-2023-30629 | NO (no raw_call) | N/A |
| 6 | Default args ordering | CVE-2023-32059 | NO (only 1 default arg) | N/A |
| 7 | Integer overflow in range | CVE-2023-32058 | NO (no range loops) | N/A |
| 8 | DynArray OOB self-assign | CVE-2023-31146 | NO (no self-assign) | N/A |
| 9 | Storage allocator overflow | CVE-2023-30837 | NO (small arrays) | N/A |
| 10 | Nonpayable default ETH | CVE-2023-32675 | NO (no __default__) | N/A |
| 11 | extract32 dirty memory | CVE-2024-24564 | NO (no extract32) | N/A |
| 12 | sha3 codegen | CVE-2024-24559 | NO (requires hand-written IR) | N/A |
| 13 | Precompile success unchecked | N/A | THEORETICAL (negligible) | N/A |
| 14 | _abi_decode complex exprs | CVE-2023-42460 | NO (no _abi_decode) | N/A |
| 15 | _abi_decode memory overflow | CVE-2024-26149 | NO (no _abi_decode) | N/A |
| 16 | msize memory corruption | N/A | NO (no raw_call/create) | N/A |
| 17 | slice bounds overflow | CVE-2024-24561 | NO (no slice) | N/A |
| 18 | sqrt multiple eval | N/A | NO (no sqrt) | N/A |
| 19 | Empty string reentrancy | CVE-2023-42441 | NO (uses "lock", not "") | N/A |
| 20 | AugAssign DynArray OOB | CVE-2025-27105 | NO (no DynArray AugAssign) | N/A |

---

## RECOMMENDATION

**VaultV3.vy is largely safe from Vyper 0.3.7 compiler bugs** due to its conservative coding patterns:
- No `raw_call`, `extract32`, `slice`, `sqrt`, `_abi_decode`, `create_from_blueprint`, `create_copy_of`
- No range-based loops
- No DynArray self-assignment
- Single default argument functions (not multiple)
- Non-empty reentrancy key
- unsafe_* operations preceded by bounds checks
- concat with fixed-size inputs only

**The only real concern is the ecrecover undefined data issue (CVE-2023-37902) in the `permit` function,
but practical exploitation probability is astronomically low.**

If Yearn ever redeploys or upgrades the vault, upgrading to Vyper >= 0.4.1 would eliminate all
known compiler vulnerabilities.

---

## Sources

- [Vyper Nonreentrancy Lock Post-Mortem (HackMD)](https://hackmd.io/@vyperlang/HJUgNMhs2)
- [Curve Pool Reentrancy Exploit Post-Mortem (LlamaRisk)](https://hackmd.io/@LlamaRisk/BJzSKHNjn)
- [State of Vyper Security -- September 2024](https://blog.vyperlang.org/posts/vyper-security/)
- [Vyper GitHub Security Advisories](https://github.com/vyperlang/vyper/security/advisories)
- [CVE-2023-30629 (raw_call)](https://github.com/vyperlang/vyper/security/advisories/GHSA-w9g2-3w7p-72g9)
- [CVE-2023-32059 (default args)](https://github.com/vyperlang/vyper/security/advisories/GHSA-ph9x-4vc9-m39g)
- [CVE-2023-32058 (range overflow)](https://github.com/vyperlang/vyper/security/advisories/GHSA-6r8q-pfpv-7cgj)
- [CVE-2023-31146 (DynArray OOB)](https://github.com/vyperlang/vyper/security/advisories/GHSA-3p37-3636-q8wv)
- [CVE-2023-30837 (storage allocator)](https://github.com/vyperlang/vyper/security/advisories/GHSA-mgv8-gggw-mrg6)
- [CVE-2023-32675 (nonpayable default)](https://github.com/vyperlang/vyper/security/advisories/GHSA-vxmm-cwh2-q762)
- [CVE-2023-37902 (ecrecover)](https://github.com/vyperlang/vyper/security/advisories/GHSA-f5x6-7qgp-jhf3)
- [CVE-2023-39363 (reentrancy locks)](https://github.com/vyperlang/vyper/security/advisories/GHSA-5824-cm3x-3c38)
- [CVE-2023-42441 (empty string reentrancy)](https://github.com/vyperlang/vyper/security/advisories/GHSA-3hg2-r75x-g69m)
- [CVE-2023-42460 (_abi_decode)](https://github.com/vyperlang/vyper/security/advisories/GHSA-cx2q-hfxr-rj97)
- [CVE-2024-24564 (extract32)](https://github.com/vyperlang/vyper/security/advisories/GHSA-4hwq-4cpm-8vmx)
- [CVE-2024-24559 (sha3 codegen)](https://github.com/vyperlang/vyper/security/advisories/GHSA-6845-xw22-ffxv)
- [CVE-2024-24561 (slice overflow)](https://github.com/vyperlang/vyper/security/advisories/GHSA-9x7f-gwxq-6f2c)
- [CVE-2024-26149 (_abi_decode overflow)](https://github.com/vyperlang/vyper/security/advisories/GHSA-9p8r-4xp4-gw5w)
- [CVE-2025-27105 (AugAssign OOB)](https://github.com/vyperlang/vyper/security/advisories/GHSA-4w26-8p97-f4jp)
- [Precompile success unchecked](https://github.com/vyperlang/vyper/security/advisories/GHSA-vgf2-gvx8-xwc3)
- [Reversed side effects](https://github.com/vyperlang/vyper/security/advisories/GHSA-g2xh-c426-v8mf)
- [concat memory corruption](https://github.com/vyperlang/vyper/security/advisories/GHSA-2q8v-3gqq-4f8p)
- [msize memory corruption](https://github.com/vyperlang/vyper/security/advisories/GHSA-c647-pxm2-c52w)
- [Snyk -- Vyper 0.3.7 Vulnerabilities](https://security.snyk.io/package/pip/vyper/0.3.7)
- [Halborn -- Vyper Bug Hack Explained](https://www.halborn.com/blog/post/explained-the-vyper-bug-hack-july-2023)
