# Hathor Network Security Audit Report

**Date:** 2026-03-03
**Target:** hathor-core (Python full node), hathor-wallet-lib, hathor-wallet-headless
**Scope:** Nano contracts sandbox, P2P sync, consensus, DAG validation
**Immunefi Max Bounty:** $30,000 (Critical)

## Executive Summary

The Hathor Network audit focused on the nano contracts sandbox system, P2P layer, and consensus mechanism. The audit identified **1 Critical**, **2 High**, **2 Medium**, **2 Low**, and **4 Informational** findings. The most severe issue is a sandbox escape via Python's `SystemExit` exception that can permanently crash any full node.

The nano contracts system uses Python code running under a restricted builtins sandbox with AST validation. While the import whitelist and builtin restrictions are well-implemented, the exception handling chain has critical gaps, and the fuel/memory metering system is entirely unimplemented.

A compensating control (`NC_ON_CHAIN_BLUEPRINT_RESTRICTED=True`) limits blueprint deployment to whitelisted addresses on mainnet, mitigating immediate exploitability. However, the code comment explicitly states this restriction will be lifted in the future.

## Findings Summary

| ID | Title | Severity | Category | Immunefi |
|----|-------|----------|----------|----------|
| F-01 | SystemExit/KeyboardInterrupt Sandbox Escape | **Critical** | Sandbox Escape | Submission #001 |
| F-02 | Fuel Metering Completely Unimplemented | **High** | Resource Exhaustion | Submission #002 |
| F-03 | Memory Limit Not Enforced | **High** | Resource Exhaustion | Submission #002 |
| F-04 | C-level Builtin DoS (Unmetered Native Code) | **Medium** | Resource Exhaustion | — |
| F-05 | Wrong parent_hash in Vertex Verifier Loop | **Low** | DAG Validation | — |
| F-06 | Consensus Assert as Runtime Guarantee | **Low** | Consensus | — |
| F-07 | DFS Stack Memory Exhaustion in Sync v2 | **Low** | P2P DoS | — |
| F-08 | GeneratorExit Unmetered Cleanup | **Informational** | Sandbox | — |
| F-09 | Timestamp Validation Window Inconsistency | **Informational** | P2P | — |
| F-10 | Unbounded Transaction Cache in Sync Agent | **Informational** | P2P DoS | — |
| F-11 | Insufficient Rate Limiting on Sync Requests | **Informational** | P2P DoS | — |

---

## F-01: SystemExit/KeyboardInterrupt Sandbox Escape [CRITICAL]

**Files:** `custom_builtins.py:759,782,800`, `metered_exec.py:103-109`, `vertex_handler.py:175-183`, `execution_manager.py:50-67`

**Description:** `SystemExit`, `KeyboardInterrupt`, and `BaseException` are exposed as builtins to nano contract code. These inherit from `BaseException` (not `Exception`), so they escape the `except Exception` handler in `MeteredExecutor.call()` and the `except NCFail` handler in `NCBlockExecutor.execute_transaction()`. The exception propagates to `vertex_handler._old_on_new_vertex()` which has an `except BaseException` handler that calls `crash_and_exit()`, terminating the node via `reactor.stop(); reactor.crash(); sys.exit(-1)`.

**Call chain:**
```
raise SystemExit() -> metered_exec(except NCFail: miss, except Exception: miss)
  -> block_executor(except NCFail: miss) -> vertex_handler(except BaseException: CRASH)
  -> crash_and_exit() -> sys.exit(-1)
```

**Impact:** Permanent node crash + boot loop. Any node syncing a chain containing the malicious transaction crashes. New nodes cannot join.

**Compensating control:** `NC_ON_CHAIN_BLUEPRINT_RESTRICTED=True` (default) limits deployment to whitelisted addresses. Code comments indicate this will be lifted.

**Fix:** Remove `SystemExit`, `KeyboardInterrupt`, `BaseException`, `GeneratorExit` from `EXEC_BUILTINS` and add to `DISABLED_BUILTINS`. Additionally change `except Exception` to `except BaseException` in `metered_exec.py`.

---

## F-02: Fuel Metering Completely Unimplemented [HIGH]

**Files:** `metered_exec.py:29-78`

**Description:** `FUEL_COST_MAP = [1] * 256` is dead code. `sys.settrace` is never called. `MeteredExecutor` stores `_fuel` but never decrements it. The settings define `NC_INITIAL_FUEL_TO_CALL_METHOD = 1,000,000` opcodes but this is never enforced. A single nano contract method can run `while True: pass` and consume CPU indefinitely.

**Impact:** CPU exhaustion DoS. Processing node hangs on the block containing the malicious transaction.

**Fix:** Implement `sys.settrace` callback that decrements fuel per opcode.

---

## F-03: Memory Limit Not Enforced [HIGH]

**Files:** `metered_exec.py:49`, `settings.py:539`

**Description:** `_memory_limit` is stored but never checked. `NC_MEMORY_LIMIT_TO_CALL_METHOD = 1GiB` is configured but unenforced. No `sys.setrecursionlimit`, no `tracemalloc`, no allocation tracking. A nano contract can allocate `bytearray(10**9)` repeatedly to OOM-kill the node process.

**Impact:** Memory exhaustion DoS. Node process killed by OS OOM killer.

**Fix:** Implement memory tracking via `tracemalloc` or custom allocation hooks.

---

## F-04: C-level Builtin DoS [MEDIUM]

**Files:** `custom_builtins.py` lines 571, 633, 706, 717, 735

**Description:** Native C builtins `sorted()`, `list()`, `dict()`, `set()`, `max()`, `min()`, `sum()` run unmetered C code. Even with `sys.settrace` metering, these bypass Python opcode tracing because they run in CPython's C implementation. Example: `sorted(custom_range(10**9))` runs O(N*log(N)) in C.

**Impact:** CPU/memory exhaustion via single builtin call. Bypasses even theoretical fuel metering.

**Fix:** Replace with Python wrappers (like `custom_range` already is) that enforce collection size limits, or add size-checking wrapper functions.

---

## F-05: Wrong parent_hash in Vertex Verifier Loop [LOW]

**File:** `hathor/verification/vertex_verifier.py:107-108`

**Description:** The loop at line 107 iterates over `parent.parents` (grandparent hashes) with variable `pi_hash`, but line 108 fetches `vertex.storage.get_transaction(parent_hash)` using the outer loop variable `parent_hash` instead of `pi_hash`. This means the grandparent timestamp check always uses the parent's timestamp, not the actual grandparent timestamps, weakening the DAG timestamp validation.

```python
for pi_hash in parent.parents:                           # iterates grandparent hashes
    pi = vertex.storage.get_transaction(parent_hash)     # BUG: should be pi_hash
    if not pi.is_block:
        min_timestamp = ...
```

**Impact:** Weakened timestamp validation may allow blocks with slightly out-of-order parent timestamps to pass verification.

**Fix:** Change `parent_hash` to `pi_hash` on line 108.

---

## F-06: Consensus Assert as Runtime Guarantee [LOW]

**File:** `hathor/consensus/transaction_consensus.py:368`

**Description:** `assert bool(meta.conflict_with)` with developer FIXME comment: "this looks like a runtime guarantee, MUST NOT be an assert". Running with `python -O` strips asserts, removing this consensus invariant check.

**Impact:** If node runs with optimization flag, consensus invariant is not verified.

**Fix:** Replace `assert` with `if not meta.conflict_with: raise ConsensusError(...)`.

---

## F-07: DFS Stack Memory Exhaustion in Sync v2 [LOW]

**File:** `hathor/p2p/sync_v2/mempool.py:123-124`

**Description:** The DFS stack has `MAX_STACK_LENGTH = 1000`, but when exceeded, it calls `popleft()` which removes the oldest item rather than aborting. This loses context for dependency resolution.

**Impact:** Malicious peer can craft deep dependency chains causing memory waste and broken state.

**Fix:** Abort DFS instead of removing oldest items when stack limit exceeded.

---

## F-08: GeneratorExit Unmetered Cleanup [INFORMATIONAL]

**Description:** `GeneratorExit` is exposed as a builtin. Generator `finally` blocks during cleanup run without fuel accounting (even if metering were implemented). Can be used for unmetered computation.

---

## F-09: Timestamp Validation Window Inconsistency [INFORMATIONAL]

**Files:** `hathor/p2p/states/hello.py:147`, `vertex_handler.py:194`

**Description:** Hello state checks peer timestamps within `MAX_FUTURE_TIMESTAMP_ALLOWED / 2` (150s), while vertex validation allows `MAX_FUTURE_TIMESTAMP_ALLOWED` (300s). Two peers at exactly 150s skew could accept transactions the other rejects.

---

## F-10: Unbounded Transaction Cache in Sync Agent [INFORMATIONAL]

**File:** `hathor/p2p/sync_v2/agent.py:163`

**Description:** `_get_tx_cache_maxsize = 1000` with no eviction policy when exceeded. Memory grows unbounded under cache pressure.

---

## F-11: Insufficient Rate Limiting on Sync Requests [INFORMATIONAL]

**File:** `hathor/p2p/sync_v2/agent.py:55-56`

**Description:** `MAX_GET_TRANSACTIONS_BFS_LEN = 8` and `DEFAULT_STREAMING_LIMIT = 1000` are relatively lenient. High-volume legitimate-looking requests can consume bandwidth.

---

## Methodology

1. **Static analysis** of nano contracts sandbox: custom_builtins.py, metered_exec.py, blueprint AST validation, allowed imports
2. **Call chain tracing** from blueprint code through runner, block executor, consensus, vertex handler to crash_and_exit
3. **Exception hierarchy analysis**: Python BaseException vs Exception inheritance
4. **Resource limit verification**: searched for settrace, setprofile, tracemalloc, memory_limit usage
5. **P2P protocol review**: sync_v2 agent, mempool, blockchain streaming client
6. **Consensus analysis**: transaction_consensus.py, block_consensus.py, vertex_verifier.py

## Compensating Controls Assessment

| Control | Status | Effectiveness |
|---------|--------|--------------|
| `NC_ON_CHAIN_BLUEPRINT_RESTRICTED` | Active on mainnet | High (limits deployment to 2 addresses) |
| AST name blacklist | Active | Moderate (blocks known dangerous names) |
| Import whitelist | Active | High (well-curated allowed imports) |
| Disabled builtins | Active | High (but missing BaseException subclasses) |
| Cross-contract call limits | Active | High for contract-to-contract, zero for within-method |
| Fuel metering | **NOT ACTIVE** | Zero (completely unimplemented) |
| Memory limiting | **NOT ACTIVE** | Zero (completely unenforced) |
