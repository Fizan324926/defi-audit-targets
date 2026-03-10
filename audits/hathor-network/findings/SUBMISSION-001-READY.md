# Immunefi Submission Guide: SUBMISSION-001

## 1. Title

```
Nano contract blueprint can raise SystemExit and crash the full node
```

## 2. Assets and Impact

- **Program**: Hathor Network (https://immunefi.com/bug-bounty/hathornetwork/)
- **Asset**: Blockchain/DLT -- hathor-core (https://github.com/HathorNetwork/hathor-core)
- **Impact**: Network unable to confirm new transactions

## 3. Severity Level

- **High** -- permanent node crash via sandbox escape, boot loop from DAG persistence
- Max bounty for High: $15,000

## 4. Description (Main Report)

Paste the full content of **IMMUNEFI-SUBMISSION-001.md** into the Description field.

## 5. Proof of Concept

Paste the full content of **SUBMISSION-001-POC.md** into the Proof of Concept field.

## 6. Gist

Create a gist with:
- `README.md` -- setup instructions and what the tests prove
- `test_systemexit_escape.py` -- the PoC test file (7 tests, 3 test classes)

## 7. Acknowledgment

Check the box: "I confirm that my submission includes a clear, original explanation and a working PoC."

## 8. Notes

- PoC runs inside hathor-core's own test framework, not standalone mocks
- Full node integration test uses SimulatorTestCase with mining, consensus, DAG, vertex handler
- The only mock is crash_and_exit itself (can't let sys.exit(-1) kill the test process)
- All NC execution goes through real MeteredExecutor, Runner, block executor, vertex handler
- 7 tests, 3 test classes, all passing
