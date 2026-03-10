"""
PoC: SystemExit sandbox escape in Hathor nano contracts

Three levels of proof:

1. Unit test: SystemExit escapes Runner.call_public_method() uncaught,
   while ValueError is properly caught as NCFail. Runs against real
   HathorManager + RocksDB.

2. Integration test: Full node simulation with Simulator. Registers a
   malicious blueprint, creates a NC transaction, mines blocks so it
   gets included and executed. Mocks crash_and_exit to capture the call
   instead of actually killing the process. Proves crash_and_exit is
   triggered through the real vertex_handler path with the real tx hash.

3. Builtins verification: SystemExit is in EXEC_BUILTINS and NOT in
   DISABLED_BUILTINS. exit() is blocked but SystemExit itself is not.
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


# -- The malicious blueprint. One line attack: raise SystemExit() --

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


# =========================================================================
# Test 1: Unit level -- SystemExit escapes Runner (real HathorManager)
# =========================================================================

class TestSystemExitEscapesRunner(BlueprintTestCase):
    """Proves SystemExit escapes the Runner's exception handlers.

    Uses BlueprintTestCase which creates a real HathorManager with RocksDB.
    The blueprint is registered through the actual NC pipeline and executed
    via Runner.call_public_method().
    """

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


# =========================================================================
# Test 2: Integration -- Full node simulation, crash_and_exit triggered
# =========================================================================

class TestSystemExitCrashesNode(SimulatorTestCase):
    """Proves SystemExit triggers crash_and_exit through the full node path.

    Uses SimulatorTestCase which runs a complete Hathor node with mining,
    consensus, DAG storage, and vertex handler. The malicious blueprint is
    registered in the NC catalog, a transaction calling the method is created,
    and blocks are mined to include and execute it. crash_and_exit is mocked
    to capture the call instead of killing the process.

    This is the same execution path as production: transaction enters mempool,
    miner includes it in a block, block is processed by vertex_handler, NC
    code runs, SystemExit escapes, vertex_handler catches it as BaseException,
    crash_and_exit is called.
    """
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
        """Full path: deploy blueprint, call method, mine block, node crashes.

        1. Create NC transaction calling initialize() -- succeeds
        2. Mine blocks so initialize() executes -- contract created
        3. Stop the miner (we'll mine manually from here)
        4. Create NC transaction calling crash_node() -- enters mempool
        5. Mock crash_and_exit so we can capture it
        6. Mine one block manually to execute crash_node()
        7. Assert crash_and_exit was called

        The only mock is crash_and_exit itself, because we can't let
        sys.exit(-1) kill the test process. Everything else is real:
        real DAG, real consensus, real vertex handler, real NC execution.
        """
        # Step 1-2: Deploy the contract
        nc_tx = self._gen_nc_tx(self.crash_blueprint_id, 'initialize', [self.token_uid])
        self.manager.cpu_mining_service.resolve(nc_tx)
        self.manager.on_new_tx(nc_tx)
        self.assertIsNone(nc_tx.get_metadata().voided_by)

        nc_id = nc_tx.hash

        trigger = StopAfterNMinedBlocks(self.miner, quantity=2)
        self.assertTrue(self.simulator.run(14400, trigger=trigger))

        # Verify contract was created successfully
        nc_storage = self.manager.get_best_block_nc_storage(nc_id)
        self.assertEqual(
            nc_storage.get_obj(b'token_uid', TOKEN_NC_TYPE),
            self.token_uid
        )

        # Step 3: Stop the miner so we control block creation
        self.miner.stop()

        # Step 4: Create the malicious transaction
        self.manager.reactor.advance(10)
        crash_tx = self._gen_nc_tx(nc_id, 'crash_node', [])
        self.manager.cpu_mining_service.resolve(crash_tx)
        self.manager.on_new_tx(crash_tx)
        self.assertIsNone(crash_tx.get_metadata().voided_by)

        # Step 5: Mock crash_and_exit so it doesn't kill the process.
        execution_manager_mock = Mock(spec_set=ExecutionManager)
        self.manager.vertex_handler._execution_manager = execution_manager_mock

        # Step 6: Mine a block manually. This block will include the
        # crash_node() transaction. When vertex_handler processes the
        # block, NC execution runs, SystemExit escapes, and crash_and_exit
        # is called.
        self.manager.reactor.advance(1)
        block = self.manager.generate_mining_block()
        self.manager.cpu_mining_service.resolve(block)
        self.manager.propagate_tx(block)

        # Step 7: crash_and_exit was called. The node would be dead.
        execution_manager_mock.crash_and_exit.assert_called()

        # The call includes the failing vertex info
        call_args = execution_manager_mock.crash_and_exit.call_args
        reason = call_args.kwargs.get('reason', call_args.args[0] if call_args.args else '')
        self.assertIn('on_new_vertex() failed', reason)


# =========================================================================
# Test 3: Builtins verification
# =========================================================================

class TestBuiltinsExposure(BlueprintTestCase):
    """Verifies the root cause: dangerous builtins exposed, not blocked."""

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
