"""
PoC: SystemExit sandbox escape in Hathor nano contracts.
Run with: python -m pytest hathor_tests/nanocontracts/test_systemexit_escape.py -s -o "addopts="
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
        # check builtins exposure
        print(f"\nEXEC_BUILTINS has SystemExit: {'SystemExit' in EXEC_BUILTINS}")
        print(f"DISABLED_BUILTINS has SystemExit: {'SystemExit' in DISABLED_BUILTINS}")
        print(f"DISABLED_BUILTINS has exit: {'exit' in DISABLED_BUILTINS}")
        for name in ('BaseException', 'KeyboardInterrupt', 'GeneratorExit'):
            print(f"EXEC_BUILTINS has {name}: {name in EXEC_BUILTINS}, "
                  f"DISABLED_BUILTINS has {name}: {name in DISABLED_BUILTINS}")

        assert 'SystemExit' in EXEC_BUILTINS
        assert 'SystemExit' not in DISABLED_BUILTINS

        # deploy contract with crash_node() method
        nc_tx = self._gen_nc_tx(self.crash_blueprint_id, 'initialize', [self.token_uid])
        self.manager.cpu_mining_service.resolve(nc_tx)
        self.manager.on_new_tx(nc_tx)
        nc_id = nc_tx.hash

        trigger = StopAfterNMinedBlocks(self.miner, quantity=2)
        self.assertTrue(self.simulator.run(14400, trigger=trigger))

        nc_storage = self.manager.get_best_block_nc_storage(nc_id)
        stored_token = nc_storage.get_obj(b'token_uid', TOKEN_NC_TYPE)
        self.assertEqual(stored_token, self.token_uid)

        print(f"\nnc_id: {nc_id.hex()}")
        print(f"token_uid: {stored_token.hex()}")
        print(f"voided_by: {nc_tx.get_metadata().voided_by}")

        # send tx calling crash_node()
        self.miner.stop()
        self.manager.reactor.advance(10)
        crash_tx = self._gen_nc_tx(nc_id, 'crash_node', [])
        self.manager.cpu_mining_service.resolve(crash_tx)
        self.manager.on_new_tx(crash_tx)
        self.assertIsNone(crash_tx.get_metadata().voided_by)

        print(f"\ncrash_tx: {crash_tx.hash.hex()}")
        print(f"crash_tx voided_by: {crash_tx.get_metadata().voided_by}")

        # mock crash_and_exit (it calls sys.exit(-1), can't let it kill the process)
        execution_manager_mock = Mock(spec_set=ExecutionManager)
        self.manager.vertex_handler._execution_manager = execution_manager_mock

        # mine block containing crash_tx
        self.manager.reactor.advance(1)
        block = self.manager.generate_mining_block()
        self.manager.cpu_mining_service.resolve(block)
        self.manager.propagate_tx(block)

        crash_called = execution_manager_mock.crash_and_exit.called
        call_args = execution_manager_mock.crash_and_exit.call_args
        reason = call_args.kwargs.get('reason', '') if call_args else ''
        print(f"\ncrash_and_exit called: {crash_called}")
        print(f"reason: {reason}")

        assert crash_called
        assert 'on_new_vertex() failed' in reason

        # check DAG persistence
        block_persisted = self.manager.tx_storage.transaction_exists(block.hash)
        tx_persisted = self.manager.tx_storage.transaction_exists(crash_tx.hash)
        block_from_storage = self.manager.tx_storage.get_transaction(block.hash)
        block_meta = block_from_storage.get_metadata()
        voided = block_meta.voided_by or set()
        has_fail_id = self._settings.CONSENSUS_FAIL_ID in voided

        print(f"\nblock in storage: {block_persisted} ({block.hash.hex()[:16]}...)")
        print(f"crash_tx in storage: {tx_persisted} ({crash_tx.hash.hex()[:16]}...)")
        print(f"block voided_by: {voided}")
        print(f"CONSENSUS_FAIL_ID: {has_fail_id}")

        assert block_persisted
        assert tx_persisted
        assert has_fail_id


class TestSandboxEscapeControl(BlueprintTestCase):

    def test_sandbox_escape_vs_normal_exception(self):
        # SystemExit through the real NC pipeline
        contract_id = self.gen_random_contract_id()
        blueprint_id = self._register_blueprint_contents(StringIO(MALICIOUS_BLUEPRINT_SRC))
        self.runner.create_contract(contract_id, blueprint_id, self.create_context())

        escaped = False
        try:
            self.runner.call_public_method(
                contract_id, 'crash_node', self.create_context()
            )
        except SystemExit:
            escaped = True

        print(f"\nSystemExit escaped sandbox: {escaped}")
        assert escaped

        # ValueError through the same pipeline
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

        caught_as_ncfail = False
        try:
            self.runner.call_public_method(
                contract_id2, 'raise_error', self.create_context()
            )
        except NCFail:
            caught_as_ncfail = True
        except Exception:
            pass

        print(f"ValueError caught as NCFail: {caught_as_ncfail}")
        assert caught_as_ncfail
