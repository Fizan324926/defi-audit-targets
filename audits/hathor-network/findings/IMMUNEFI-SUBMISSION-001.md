# Nano contract blueprint can raise SystemExit and crash the full node

Hathor's nano contract sandbox exposes `SystemExit` as a builtin available to blueprint code (`custom_builtins.py:800`). A blueprint method can call `raise SystemExit()`, and this exception escapes the entire execution pipeline because the exception handlers only catch `Exception` and `NCFail`, never `BaseException` subclasses.

In Python, `SystemExit` inherits from `BaseException`, not `Exception`. So `except Exception` at `metered_exec.py:107` misses it. `except NCFail` at `block_executor.py:248` also misses it. The exception bubbles up to `vertex_handler.py:178` where `except BaseException` catches it and calls `crash_and_exit()`, which runs `reactor.stop(); reactor.crash(); sys.exit(-1)` (`execution_manager.py:65-67`). The same applies to `KeyboardInterrupt` (line 782), `GeneratorExit` (line 774), and `BaseException` itself (line 759). All four are in `EXEC_BUILTINS` and none are in `DISABLED_BUILTINS`. Ironically, the `exit` builtin IS in `DISABLED_BUILTINS` (line 358) with the comment "used to raise SystemExit exception" -- they blocked the function that raises `SystemExit` but left `SystemExit` itself available.

The whole attack is one line of blueprint code: `raise SystemExit()`. When a miner includes a transaction calling this method in a block, every full node that processes it runs the blueprint code, `SystemExit` escapes the sandbox, and the node calls `crash_and_exit()`.

This is not a one time crash. The block gets saved to RocksDB before the exception even propagates. `_unsafe_save_and_run_consensus` (`vertex_handler.py:229`) calls `save_transaction(vertex)` before `unsafe_update` runs consensus and NC execution at line 232. So the block is in storage before `SystemExit` is raised. The `except BaseException` handler at lines 180-182 then writes `CONSENSUS_FAIL_ID` to the block metadata and calls `save_transaction(vertex, only_metadata=True)` before calling `crash_and_exit` at line 183. Any node syncing this chain receives the same block, processes it through vertex_handler, re-executes the NC code, and crashes the same way.

The PoC runs inside hathor-core's own test framework (v0.70.0). I used `SimulatorTestCase` which spins up a real full node with its own peer ID, RocksDB instance, wallet, miner, consensus engine, and vertex handler. The output starts by dumping the live environment so you can see it's a real node, not a mock:

```
hathor-core: 0.70.0-ac98edd-local
network: unittests
nano_contracts: enabled
peer_id: af9fea6df813eb77...
rocksdb: /tmp/tmpnqgbd5rw
wallet_address: HKFNZ5gkwkxWhitH6pFKWEFA31AfiHgp8T
best_block_height: 11
```

First thing I checked was the sandbox builtins. `SystemExit` is in `EXEC_BUILTINS` but not in `DISABLED_BUILTINS`, and same for `BaseException`, `KeyboardInterrupt`, and `GeneratorExit`. Meanwhile `exit` (the function that raises `SystemExit`) is in `DISABLED_BUILTINS`. They blocked the wrapper but left the exception class itself exposed.

I deployed a contract with a `crash_node()` method that just does `raise SystemExit()`, confirmed it on chain (mined 2 blocks, verified `token_uid` stored in contract state, `voided_by: None`), then sent a transaction calling `crash_node()` and mined a block containing it. The output shows `crash_and_exit called: True` with `reason: on_new_vertex() failed for tx ...` -- that's the `except BaseException` handler at `vertex_handler.py:178` catching the escaped `SystemExit` and triggering the crash path.

The only mock is `crash_and_exit` itself, since I can't let `sys.exit(-1)` kill the test process. The mock doesn't affect any of the preceding logic. Looking at `vertex_handler.py:175-183`, the `except BaseException` handler writes `CONSENSUS_FAIL_ID` metadata at lines 180-182 and saves it to RocksDB, then calls `crash_and_exit` at line 183. Those writes happen sequentially before the mock is even reached. The block persistence is even more straightforward: `_unsafe_save_and_run_consensus` at `vertex_handler.py:229` calls `save_transaction(vertex)` synchronously before `unsafe_update` at line 232 runs consensus and NC execution. The block is in RocksDB before `SystemExit` is even raised.

After the crash, I queried RocksDB directly. Both the block and the crash transaction are still in storage, and the block has `voided_by: {b'consensus-fail'}`. This is the `CONSENSUS_FAIL_ID` written at lines 180-182 before `crash_and_exit`. On restart, the node loads this block from storage and re-processes it through vertex handler, hitting the same `SystemExit` -> `crash_and_exit` path. Any node syncing this chain gets the same block and crashes the same way.

The second test is a control comparison. I ran `raise SystemExit()` and `raise ValueError()` through the same NC pipeline (`Runner.call_public_method`). `SystemExit` escapes the sandbox entirely, while `ValueError` gets caught by `metered_exec.py:107` and wrapped as `NCFail`. That's the gap: `except Exception` catches `ValueError` (which inherits from `Exception`) but not `SystemExit` (which inherits from `BaseException`).

Blueprint deployment is currently restricted to whitelisted addresses (`NC_ON_CHAIN_BLUEPRINT_RESTRICTED = True`), but the code comment at `settings.py:530` says this will be lifted. Localnet already runs with it disabled.

To fix this, remove `SystemExit`, `KeyboardInterrupt`, `BaseException`, and `GeneratorExit` from `EXEC_BUILTINS` and add them to `DISABLED_BUILTINS`. Also change `except Exception` to `except BaseException` in `metered_exec.py:107` as defense in depth.
