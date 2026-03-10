# Immunefi Submission Guide: SUBMISSION-001

## Title

```
Nano contract blueprint can raise SystemExit and crash the full node
```

## Assets and Impact

- **Program**: Hathor Network (https://immunefi.com/bug-bounty/hathornetwork/)
- **Asset**: Blockchain/DLT -- hathor-core (https://github.com/HathorNetwork/hathor-core)
- **Impact**: Network unable to confirm new transactions

## Severity

**High** -- permanent node crash via sandbox escape, block persists in DAG causing boot loop on restart and crash on sync

## Fields

- **Description**: paste `IMMUNEFI-SUBMISSION-001.md`
- **Proof of Concept**: paste `SUBMISSION-001-POC.md`
- **Gist**: create from `PoC/test_systemexit_escape.py` with a README

## Notes

- PoC runs inside hathor-core's test framework, not standalone mocks
- Full node integration test uses SimulatorTestCase with real mining, consensus, DAG, vertex handler
- Only mock is crash_and_exit (can't let sys.exit kill the test process)
- Test proves block + tx persist in RocksDB and block is marked CONSENSUS_FAIL_ID after crash
