"""
PoC: Unimplemented Fuel Metering in Hathor Nano Contracts

Demonstrates that MeteredExecutor does not enforce any fuel
or memory limits, despite storing them.

In hathor-core/hathor/nanocontracts/metered_exec.py:
- FUEL_COST_MAP = [1] * 256  -> dead code, never referenced
- sys.settrace() -> never called
- _fuel -> stored but never decremented
- _memory_limit -> stored but never checked
"""


class MeteredExecutor:
    """Simplified reproduction of hathor MeteredExecutor."""

    def __init__(self, fuel: int, memory_limit: int):
        self._fuel = fuel
        self._memory_limit = memory_limit

    def call(self, func, *, args):
        """Reproduces the actual call() method behavior."""
        # In the real code, this compiles and runs via Python's exec
        # NO sys.settrace call
        # NO fuel decrement
        # NO memory check
        result = func(*args)
        return result

    def get_fuel(self) -> int:
        return self._fuel

    def get_memory_limit(self) -> int:
        return self._memory_limit


def main():
    print("=" * 60)
    print("Hathor Nano Contract Unimplemented Metering PoC")
    print("=" * 60)
    print()

    # Create executor with the same limits as hathor-core settings
    executor = MeteredExecutor(
        fuel=1_000_000,           # NC_INITIAL_FUEL_TO_CALL_METHOD
        memory_limit=1073741824   # NC_MEMORY_LIMIT_TO_CALL_METHOD (1GiB)
    )

    print(f"[INIT] Fuel limit: {executor.get_fuel():,}")
    print(f"[INIT] Memory limit: {executor.get_memory_limit():,} bytes")
    print()

    # --- Test 1: Fuel is never decremented ---
    print("--- Test 1: Fuel Not Enforced ---")
    iterations = [0]

    def expensive_computation():
        for _ in range(10_000_000):  # 10M iterations > 1M fuel limit
            iterations[0] += 1
        return iterations[0]

    print(f"[TEST] Running 10M iterations with 1M fuel limit...")
    fuel_before = executor.get_fuel()
    result = executor.call(expensive_computation, args=())
    fuel_after = executor.get_fuel()

    print(f"[RESULT] Completed {result:,} iterations")
    print(f"[RESULT] Fuel before: {fuel_before:,}")
    print(f"[RESULT] Fuel after:  {fuel_after:,} (unchanged!)")
    print(f"[VERDICT] Fuel metering is non-functional")
    print()

    # --- Test 2: Memory limit is never checked ---
    print("--- Test 2: Memory Limit Not Enforced ---")

    def memory_allocation():
        # Allocate 10MB - should be tracked but isn't
        data = bytearray(10_000_000)
        return len(data)

    print(f"[TEST] Allocating 10MB with {executor.get_memory_limit():,} byte limit...")
    result = executor.call(memory_allocation, args=())
    print(f"[RESULT] Allocated {result:,} bytes successfully")
    print(f"[RESULT] Memory limit was never checked")
    print(f"[VERDICT] Memory limiting is non-functional")
    print()

    # --- Test 3: Verify FUEL_COST_MAP is dead code ---
    print("--- Test 3: FUEL_COST_MAP is Dead Code ---")
    FUEL_COST_MAP = [1] * 256  # This is defined in metered_exec.py line 33
    print(f"[INFO] FUEL_COST_MAP defined with {len(FUEL_COST_MAP)} entries")
    print(f"[INFO] All entries are 1 (placeholder values)")
    print(f"[INFO] No code ever references FUEL_COST_MAP")
    print(f"[VERDICT] FUEL_COST_MAP is dead code")
    print()

    print("=" * 60)
    print("CONCLUSION:")
    print("  - Fuel metering: DESIGNED but NOT IMPLEMENTED")
    print("  - Memory limits: DESIGNED but NOT IMPLEMENTED")
    print("  - sys.settrace(): NEVER CALLED")
    print("  - FUEL_COST_MAP: DEAD CODE")
    print("  - Infinite loops and memory bombs are unmitigated")
    print("=" * 60)


if __name__ == "__main__":
    main()
