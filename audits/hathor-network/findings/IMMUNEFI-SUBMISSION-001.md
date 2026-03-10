# Nano contract blueprint can raise SystemExit and crash the full node

Hathor's nano contract sandbox exposes `SystemExit` as a builtin available to blueprint code (`custom_builtins.py:800`). A blueprint method can call `raise SystemExit()`, and this exception escapes the entire execution pipeline because the exception handlers only catch `Exception` and `NCFail`, never `BaseException` subclasses.

In Python, `SystemExit` inherits from `BaseException`, not `Exception`. So `except Exception` at `metered_exec.py:107` misses it. `except NCFail` at `block_executor.py:248` also misses it. The exception bubbles up to `vertex_handler.py:178` where `except BaseException` catches it and calls `crash_and_exit()`, which runs `reactor.stop(); reactor.crash(); sys.exit(-1)` (`execution_manager.py:65-67`).

The same applies to `KeyboardInterrupt` (line 782), `GeneratorExit` (line 774), and `BaseException` itself (line 759). All four are in `EXEC_BUILTINS` and none are in `DISABLED_BUILTINS`. Ironically, the `exit` builtin IS in `DISABLED_BUILTINS` (line 358) with the comment "used to raise SystemExit exception" -- they blocked the function that raises `SystemExit` but left `SystemExit` itself available.

The whole attack is one line of blueprint code: `raise SystemExit()`. When a miner includes a transaction calling this method in a block, every full node that processes it runs the blueprint code, `SystemExit` escapes the sandbox, and the node calls `crash_and_exit()`.

This is not a one time crash. The block gets saved to RocksDB before the exception propagates. `_unsafe_save_and_run_consensus` (`vertex_handler.py:229`) calls `save_transaction(vertex)` before `unsafe_update` runs consensus and NC execution at line 232. So the block is persisted in storage even though the node crashed right after. The `except BaseException` handler at lines 178-182 also marks the block with `CONSENSUS_FAIL_ID` and saves the metadata before calling `crash_and_exit`. Any node syncing this chain would receive the same block, process it, execute the NC code, and crash the same way.

I wrote 7 tests that run inside hathor-core's own test framework. The key one is `test_systemexit_triggers_crash_and_exit`, which uses `SimulatorTestCase` to spin up a full Hathor node with mining, consensus, RocksDB DAG, and vertex handler. It deploys the malicious blueprint via a NC transaction, mines blocks to confirm it, then creates a second transaction calling `crash_node()` and mines a block that includes it. When `vertex_handler.propagate_tx` processes that block, SystemExit escapes the sandbox and `crash_and_exit()` is triggered. The test then checks that the block and the malicious transaction both persist in RocksDB storage after the crash, and that the block is marked with `CONSENSUS_FAIL_ID`. The only mock is `crash_and_exit` itself since we can't let `sys.exit(-1)` kill the test process. Everything else runs through the real code. To run it:

```bash
git clone https://github.com/HathorNetwork/hathor-core.git && cd hathor-core
python3.11 -m venv .venv && source .venv/bin/activate && pip install -e ".[dev]"
# place test_systemexit_escape.py at hathor_tests/nanocontracts/
python -m pytest hathor_tests/nanocontracts/test_systemexit_escape.py -v -o "addopts="
```

```
TestSystemExitEscapesRunner::test_systemexit_escapes_sandbox PASSED
TestSystemExitEscapesRunner::test_keyboardinterrupt_escapes_sandbox PASSED
TestSystemExitEscapesRunner::test_normal_exception_is_caught PASSED
TestSystemExitCrashesNode::test_systemexit_triggers_crash_and_exit PASSED
TestBuiltinsExposure::test_systemexit_exposed_not_blocked PASSED
TestBuiltinsExposure::test_all_baseexception_subclasses_exposed PASSED
TestBuiltinsExposure::test_exception_hierarchy PASSED

7 passed in 7.28s
```

The other tests cover the sandbox escape at the Runner level (SystemExit propagates uncaught from `Runner.call_public_method()` while ValueError is properly caught as NCFail) and verify that all four `BaseException` subclasses are in `EXEC_BUILTINS` and none are in `DISABLED_BUILTINS`.

Blueprint deployment is currently restricted to whitelisted addresses (`NC_ON_CHAIN_BLUEPRINT_RESTRICTED = True`), but the code comment at `settings.py:530` says this will be lifted. Localnet already runs with it disabled.

To fix this, remove `SystemExit`, `KeyboardInterrupt`, `BaseException`, and `GeneratorExit` from `EXEC_BUILTINS` and add them to `DISABLED_BUILTINS`. Also change `except Exception` to `except BaseException` in `metered_exec.py:107` as defense in depth.
