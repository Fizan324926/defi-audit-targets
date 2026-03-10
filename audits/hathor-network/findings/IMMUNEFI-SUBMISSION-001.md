# SystemExit sandbox escape in nano contracts crashes full nodes permanently via crash_and_exit

## Bug Description

The nano contracts sandbox in hathor-core exposes `SystemExit`, `KeyboardInterrupt`, `BaseException`, and `GeneratorExit` as builtins to user deployed blueprint code. These exception types inherit from `BaseException`, not `Exception`, so they slip past the `except Exception` handler in `MeteredExecutor.call()` and the `except NCFail` handler in `NCBlockExecutor.execute_transaction()`. The exception then hits the `except BaseException` handler in `vertex_handler._old_on_new_vertex()` which calls `crash_and_exit()`, killing the node with `reactor.stop(); reactor.crash(); sys.exit(-1)`.

The malicious transaction gets saved to the DAG before the crash happens (the save runs inside `_unsafe_save_and_run_consensus` at line 176, before the exception propagates). So when the node restarts and re syncs, it hits the same transaction and crashes again. This creates a permanent boot loop. Syncing nodes joining the network would also crash when they reach the malicious block, so new nodes cannot join.

Hathor's `NC_ON_CHAIN_BLUEPRINT_RESTRICTED = True` setting currently limits blueprint deployment to whitelisted addresses. But the code comment at `settings.py:530` explicitly says this restriction will be lifted. The `exit` builtin is already in `DISABLED_BUILTINS` with the comment "used to raise SystemExit exception", which shows the developers intended to block this attack surface but missed blocking `SystemExit` itself.

---

## Vulnerability Details

### Target Asset

- **Program**: hathor-core (Blockchain/DLT)
- **Repository**: https://github.com/HathorNetwork/hathor-core
- **Branch**: master (latest)
- **Files affected**:
  - `hathor/nanocontracts/custom_builtins.py` — lines 759, 774, 782, 800
  - `hathor/nanocontracts/metered_exec.py` — lines 103-109
  - `hathor/nanocontracts/execution/block_executor.py` — lines 241-248
  - `hathor/vertex_handler/vertex_handler.py` — lines 175-183
  - `hathor/execution_manager.py` — lines 50-67

### Root Cause

Four dangerous exception types are explicitly added to `EXEC_BUILTINS` (the builtins dict available to blueprint code) and none of them are in `DISABLED_BUILTINS`:

```python
# custom_builtins.py
EXEC_BUILTINS: dict[str, Any] = {
    # ...
    'BaseException': builtins.BaseException,       # line 759
    'GeneratorExit': builtins.GeneratorExit,       # line 774
    'KeyboardInterrupt': builtins.KeyboardInterrupt,  # line 782
    'SystemExit': builtins.SystemExit,             # line 800
}
```

The exception handlers in the execution chain only catch `NCFail` and `Exception`:

```python
# metered_exec.py lines 103-109
try:
    exec(code, env)              # line 104 - runs the blueprint code
except NCFail:                   # line 105
    raise
except Exception as e:           # line 107 - does NOT catch SystemExit
    raise NCFail from e
```

Python's exception hierarchy is the problem here. `SystemExit` inherits from `BaseException`, not from `Exception`. So `except Exception` does not catch it. Same goes for `KeyboardInterrupt` and `GeneratorExit`. This is documented in the Python docs at https://docs.python.org/3/library/exceptions.html#exception-hierarchy.

The `block_executor.py` handler at line 248 only catches `NCFail`, so the exception keeps propagating until it reaches `vertex_handler.py` line 178:

```python
# vertex_handler.py lines 175-183
try:
    consensus_events = self._unsafe_save_and_run_consensus(vertex)  # line 176
except BaseException:                                                # line 178
    self._execution_manager.crash_and_exit(                          # line 183
        reason=f'on_new_vertex() failed for tx {vertex.hash_hex}'
    )
```

This `except BaseException` catches everything, including `SystemExit`, and responds by terminating the node.

The `crash_and_exit` method at `execution_manager.py:50-67`:

```python
def crash_and_exit(self, *, reason: str) -> NoReturn:
    self._run_on_crash_callbacks()
    self._log.critical('Critical failure occurred...')
    self._reactor.stop()       # line 65
    self._reactor.crash()      # line 66
    sys.exit(-1)               # line 67
```

### The AST Validator Does Not Block This

The AST name blacklist at `custom_builtins.py:484-489` is defined as:

```python
AST_NAME_BLACKLIST: frozenset[str] = frozenset({
    '__builtins__',
    '__build_class__',
    '__import__',
    *DISABLED_BUILTINS,         # line 488
})
```

Since `SystemExit`, `KeyboardInterrupt`, `BaseException`, and `GeneratorExit` are not in `DISABLED_BUILTINS`, they are not in the blacklist either. Blueprint code using these names passes AST validation.

### The Irony

The `exit` builtin IS in `DISABLED_BUILTINS` at line 357-358:

```python
# XXX: used to raise SystemExit exception to close the process, we could make it raise a NCFail
'exit',
```

The developers clearly understood that `exit` raises `SystemExit` and that this is dangerous. They blocked `exit`. But they did not block `SystemExit` itself, which is the actual exception class. A blueprint cannot call `exit()` but it can directly `raise SystemExit()`, which has exactly the same effect.

### Complete Call Chain

```
raise SystemExit()              [malicious blueprint code]
  -> metered_exec.py:104        [code runs in sandboxed exec]
  -> except NCFail: (miss)      [metered_exec.py:105]
  -> except Exception: (miss)   [metered_exec.py:107 — SystemExit is BaseException, not Exception]
  -> runner._execute_public_method_call()  [runner.py:675]
  -> runner._unsafe_call_public_method()   [runner.py:272]
  -> runner.call_public_method_with_nc_args() [runner.py:259]
  -> runner.execute_from_tx()              [runner.py:163]
  -> block_executor.execute_transaction()  [block_executor.py:242]
  -> except NCFail: (miss)                 [block_executor.py:248]
  -> consensus_block_executor.execute_block_and_apply() [consensus_block_executor.py:157]
  -> vertex_handler._old_on_new_vertex()   [vertex_handler.py:176]
  -> except BaseException: (CAUGHT)        [vertex_handler.py:178]
  -> crash_and_exit()                      [vertex_handler.py:183]
  -> reactor.stop(); reactor.crash(); sys.exit(-1)  [execution_manager.py:65-67]
```

---

## Attack Scenario

### Precondition

Blueprint deployment requires either:
- `NC_ON_CHAIN_BLUEPRINT_RESTRICTED = False` (already the case on localnet, and the code comment says this will be lifted on mainnet), OR
- A compromised whitelisted address (only 2 addresses are whitelisted)

### Steps

1. Attacker deploys a blueprint with a method containing `raise SystemExit()`. The initialize method looks normal, the attack is in another public method.

2. Attacker sends a transaction that calls the malicious method.

3. A miner includes this transaction in a block.

4. Every full node processing this block executes the nano contract code:
   - `metered_exec.py` runs the blueprint method
   - `SystemExit` is raised
   - It escapes `except NCFail` (not NCFail)
   - It escapes `except Exception` (SystemExit is BaseException, not Exception)
   - It reaches `vertex_handler._old_on_new_vertex()`
   - The `except BaseException` handler catches it
   - `crash_and_exit()` is called
   - The node terminates

5. The node restarts and re syncs. It re encounters the block with the malicious transaction. Step 4 repeats. Permanent boot loop.

6. Any new node joining the network syncs from genesis, reaches the malicious block, and crashes. New nodes cannot join.

### Impact

This is not just a regular node crash. The transaction is saved to the DAG before the crash (at line 176, `_unsafe_save_and_run_consensus` saves first, then the exception from NC execution propagates). So the crash is permanent and unrecoverable without manual database surgery to remove or skip the malicious transaction.

---

## Impact

### Impact Classification

**Selected impact: Network unable to confirm new transactions (High)**

The attack chain:
1. Deploy malicious blueprint (one transaction)
2. Call the malicious method (one transaction)
3. Every node processing the block crashes permanently
4. If enough nodes crash, no new blocks can be confirmed
5. Syncing nodes cannot join, so the network cannot recover by adding new nodes

This also qualifies under "Shutdown of 30%+ of full nodes" (Medium) but the permanent boot loop and syncing node exclusion push it beyond a simple shutdown.

### Affected Systems

| System | Impact |
|--------|--------|
| Full nodes | Permanent crash + boot loop |
| Miners | Cannot mine, lose block rewards |
| Syncing nodes | Cannot join the network |
| Users | All transactions halt |
| Hathor Network | Complete network standstill until manual intervention |

### Compensating Control

`NC_ON_CHAIN_BLUEPRINT_RESTRICTED = True` is active on mainnet. This limits blueprint deployment to whitelisted addresses. However:

1. The code comment at `settings.py:530` says: "in the future this restriction will be lifted, possibly through a feature activation"
2. A compromised whitelisted key bypasses it completely
3. Localnet already has it set to `false` (`hathorlib/hathorlib/conf/localnet.yml`)
4. The `exit` builtin is blocked but `SystemExit` is not — showing this was an oversight, not a design decision
5. Configuration controls do not eliminate code level vulnerabilities

---

## Proof of Concept

### Compliance Note

**No mainnet or testnet testing was performed.** The PoC is a standalone Python script that replicates the exact exception handling chain from the hathor-core source code. Everything runs locally. No Hathor nodes were started, connected to, or interacted with.

### How to Run

```bash
python3 poc_systemexit_sandbox_escape.py
```

No dependencies beyond Python 3.8+.

### Test Matrix

| Test | What it proves | Result |
|------|---------------|--------|
| Test 1: Exception Hierarchy | SystemExit, KeyboardInterrupt, GeneratorExit are BaseException not Exception | PASS |
| Test 2: Sandbox Escape | SystemExit escapes metered_exec and block_executor, reaches crash_and_exit | PASS |
| Test 3: Builtins Exposure | All 4 dangerous types are in EXEC_BUILTINS and NOT in DISABLED_BUILTINS | PASS |
| Test 4: Boot Loop | Node crashes on every restart attempt (5/5), permanent loop | PASS |
| Test 5: Compensating Control | NC_ON_CHAIN_BLUEPRINT_RESTRICTED is a config workaround, not a code fix | PASS |
| Test 6: Malicious Blueprint | 14 line blueprint, passes AST validation, one line attack | PASS |

### Test Results

```
running 6 tests
Test 1: Python Exception Hierarchy Verification ... PASS
Test 2: SystemExit Sandbox Escape Through Exception Chain ... PASS
Test 3: Dangerous Builtins Exposure Verification ... PASS
Test 4: Permanent Boot Loop Scenario ... PASS
Test 5: Compensating Control Analysis ... PASS
Test 6: Malicious Blueprint Code ... PASS

ALL TESTS PASSED
```

---

## Recommendation

### Fix 1 (Critical): Block the dangerous builtins

Remove `SystemExit`, `KeyboardInterrupt`, `BaseException`, and `GeneratorExit` from `EXEC_BUILTINS` and add them to `DISABLED_BUILTINS`:

```diff
--- a/hathor/nanocontracts/custom_builtins.py
+++ b/hathor/nanocontracts/custom_builtins.py
@@ -326,6 +326,12 @@
 DISABLED_BUILTINS: frozenset[str] = frozenset({
+    # CRITICAL: these BaseException subclasses escape 'except Exception' handlers
+    # and cause crash_and_exit() via vertex_handler's except BaseException handler
+    'BaseException',
+    'GeneratorExit',
+    'KeyboardInterrupt',
+    'SystemExit',
+
     # XXX: async is disabled
     'aiter',
```

### Fix 2 (Defense in depth): Catch BaseException in metered_exec

```diff
--- a/hathor/nanocontracts/metered_exec.py
+++ b/hathor/nanocontracts/metered_exec.py
@@ -103,6 +103,9 @@
         try:
             exec(code, env)
         except NCFail:
             raise
-        except Exception as e:
+        except BaseException as e:
             raise NCFail from e
```

---

## References

- `custom_builtins.py:759,774,782,800` — dangerous exception types in EXEC_BUILTINS
- `custom_builtins.py:326-480` — DISABLED_BUILTINS (does not include SystemExit etc)
- `custom_builtins.py:357` — `exit` IS blocked ("used to raise SystemExit exception")
- `custom_builtins.py:484-489` — AST_NAME_BLACKLIST (expands DISABLED_BUILTINS)
- `metered_exec.py:103-109` — exception handlers that miss SystemExit
- `block_executor.py:241-248` — NCFail only catch
- `vertex_handler.py:175-183` — except BaseException -> crash_and_exit
- `execution_manager.py:50-67` — crash_and_exit terminates the node
- `runner.py:675` — metered_executor.call() invocation
- `settings.py:530-531` — NC_ON_CHAIN_BLUEPRINT_RESTRICTED + "will be lifted" comment
- `localnet.yml` — NC_ON_CHAIN_BLUEPRINT_RESTRICTED: false
- Python exception hierarchy — https://docs.python.org/3/library/exceptions.html#exception-hierarchy
