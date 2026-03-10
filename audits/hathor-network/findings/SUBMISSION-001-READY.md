# Immunefi Submission Guide: SUBMISSION-001

Ready to submit checklist and field mappings for the Hathor nano contracts SystemExit sandbox escape.

---

## 1. Title

```
SystemExit sandbox escape in nano contracts crashes full nodes permanently via crash_and_exit
```

## 2. Assets and Impact

- **Program**: Hathor Network (https://immunefi.com/bug-bounty/hathornetwork/)
- **Asset**: Blockchain/DLT — hathor-core (https://github.com/HathorNetwork/hathor-core)
- **Impact**: Network unable to confirm new transactions

## 3. Severity Level

- **High** — Permanent node crash + boot loop, syncing nodes excluded, network halt
- Max bounty for High: $15,000
- Also qualifies under Medium ("Shutdown of 30%+ of full nodes") but the permanent + unrecoverable nature and syncing node exclusion push it to High

### Severity Justification

This is not a temporary DoS. The malicious transaction persists in the DAG after the crash. Every restart re triggers the crash. New nodes cannot sync past the malicious block. This is permanent network disruption requiring manual database surgery to recover.

## 4. Description (Main Report)

Paste the full content of **IMMUNEFI-SUBMISSION-001.md** into the Description field.

## 5. Proof of Concept

Paste the full content of **SUBMISSION-001-POC.md** into the Proof of Concept field.

## 6. Gist

Gist URL (created):
```
https://gist.github.com/Fizan324926/1612b60f1496f12b08eea36135d25b8a
```

## 7. Acknowledgment

Check the box: "I confirm that my submission includes a clear, original explanation and a working PoC."

## 8. Important Program Notes

- **PoC required for all severities** — we have a 6 test PoC
- **KYC required** — government ID + proof of address needed for payout
- **Paid in HTR** — USD denominated but paid in HTR tokens
- **Out of scope note**: "unbounded loops or unmetered resources are not valid for nano contracts" — this submission is about a sandbox ESCAPE (SystemExit reaching crash_and_exit), NOT about unbounded loops or unmetered resources

---

## File References

| Immunefi Field | Source File |
|---|---|
| Title | Use the title string above |
| Description | `IMMUNEFI-SUBMISSION-001.md` |
| Proof of Concept | `SUBMISSION-001-POC.md` |
| Gist | Create from `PoC/poc_systemexit_sandbox_escape.py` |
