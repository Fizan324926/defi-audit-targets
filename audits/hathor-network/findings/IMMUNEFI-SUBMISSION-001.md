# Nano contract blueprint can raise SystemExit and crash the full node

## The bug

Hathor's nano contract sandbox exposes `SystemExit` as a builtin available to blueprint code (`custom_builtins.py:800`). A blueprint method can call `raise SystemExit()`, and this exception escapes the entire execution pipeline because the exception handlers only catch `Exception` and `NCFail`, never `BaseException` subclasses.

In Python, `SystemExit` inherits from `BaseException`, not `Exception`. So `except Exception` at `metered_exec.py:107` misses it. `except NCFail` at `block_executor.py:248` also misses it. The exception bubbles up to `vertex_handler.py:178` where `except BaseException` catches it and calls `crash_and_exit()`, which runs `reactor.stop(); reactor.crash(); sys.exit(-1)` (`execution_manager.py:65-67`).

The same applies to `KeyboardInterrupt` (line 782), `GeneratorExit` (line 774), and `BaseException` itself (line 759). All four are in `EXEC_BUILTINS` and none are in `DISABLED_BUILTINS`.

Ironically, the `exit` builtin IS in `DISABLED_BUILTINS` (line 358) with the comment "used to raise SystemExit exception". They blocked the function that raises `SystemExit` but left `SystemExit` itself available.

## How it works

The whole attack is one line of blueprint code:

```python
@public
def crash_node(self, ctx: Context) -> None:
    raise SystemExit()
```

When a miner includes a transaction calling this method, every full node that processes the block runs the blueprint code. `SystemExit` escapes the sandbox, hits the `except BaseException` in vertex_handler, and the node calls `crash_and_exit()`.

The transaction gets saved to the DAG before the crash happens (the save runs inside `_unsafe_save_and_run_consensus` at vertex_handler.py:176, before the exception from NC execution propagates up). So when the node restarts and re syncs, it hits the same transaction again and crashes again. Permanent boot loop. Any new node trying to sync from genesis also crashes when it reaches that block.

## PoC

The PoC has 7 tests at three levels, all running against the real hathor-core codebase with no mocks of the vulnerable code path.

Clone hathor-core, install with `pip install -e ".[dev]"` (Python 3.11+), place the test file at `hathor_tests/nanocontracts/test_systemexit_escape.py`, and run:

```bash
python -m pytest hathor_tests/nanocontracts/test_systemexit_escape.py -v -o "addopts="
```

Output:

```
TestSystemExitEscapesRunner::test_keyboardinterrupt_escapes_sandbox PASSED
TestSystemExitEscapesRunner::test_normal_exception_is_caught PASSED
TestSystemExitEscapesRunner::test_systemexit_escapes_sandbox PASSED
TestSystemExitCrashesNode::test_systemexit_triggers_crash_and_exit PASSED
TestBuiltinsExposure::test_all_baseexception_subclasses_exposed PASSED
TestBuiltinsExposure::test_exception_hierarchy PASSED
TestBuiltinsExposure::test_systemexit_exposed_not_blocked PASSED

7 passed in 6.93s
```

The strongest test is `TestSystemExitCrashesNode::test_systemexit_triggers_crash_and_exit`. It uses `SimulatorTestCase` to run a complete Hathor full node with mining, consensus, DAG, and vertex handler. It deploys the malicious blueprint, creates a contract via a NC transaction, mines blocks to confirm it, then creates a second transaction calling `crash_node()`. When that transaction is included in a mined block and processed by the vertex handler, `SystemExit` escapes the sandbox and `crash_and_exit()` is triggered. The only thing mocked is `crash_and_exit` itself (we can't let `sys.exit(-1)` kill the test process). Everything else runs through the real code path: real NC execution, real MeteredExecutor, real Runner, real block executor, real vertex handler.

The unit level tests (`TestSystemExitEscapesRunner`) prove the sandbox escape at the Runner level. `test_systemexit_escapes_sandbox` deploys a blueprint through the real NC pipeline with RocksDB storage and calls the method via `Runner.call_public_method()`. `SystemExit` escapes uncaught. The control test confirms `ValueError` IS caught as `NCFail`, so the sandbox works for `Exception` subclasses but fails for `BaseException` subclasses.

## Current protection

Blueprint deployment is restricted to whitelisted addresses (`NC_ON_CHAIN_BLUEPRINT_RESTRICTED = True`). But the code comment at `settings.py:530` says this restriction will be lifted ("possibly through a feature activation"). Localnet already runs with it disabled. And a compromised whitelisted key could deploy the attack today.

## Fix

Remove `SystemExit`, `KeyboardInterrupt`, `BaseException`, and `GeneratorExit` from `EXEC_BUILTINS` and add them to `DISABLED_BUILTINS`. Also change `except Exception` to `except BaseException` in `metered_exec.py:107` as defense in depth.
