# Immunefi Submission Guide: SUBMISSION-002

Ready to submit checklist and field mappings for the Kamino Scope ChainlinkX v10 bug report.

---

## 1. Title

```
Missing multiplier validation in ChainlinkX v10 oracle allows permissionless crank operator to corrupt xStocks prices on KLend
```

## 2. Assets and Impact

- **Program**: Kamino (https://immunefi.com/bug-bounty/kamino/)
- **Asset**: Smart Contract — Scope Price Oracle (`HFn8GnPADiny6XqUoWE8uRPPxb29ikn4yTuPa9MF2fWJ`)
- **Impact**: Protocol insolvency

## 3. Severity Level

- **Critical** — Protocol insolvency via oracle price manipulation
- Funds at risk: $5M to $20M in xStocks collateral on KLend
- Well above the $50,000 minimum for Critical under Kamino's program rules

## 4. Description (Main Report)

Paste the full content of **IMMUNEFI-SUBMISSION-002.md** into the Description field.

The report is already structured with the required Immunefi sections:
- `## Bug Description` → maps to **Brief/Intro**
- `## Vulnerability Details` + all Attack Vectors → maps to **Vulnerability Details**
- `## Impact` → maps to **Impact Details**
- `## References` → maps to **References**

## 5. Proof of Concept

Paste the full content of **SUBMISSION-002-POC.md** into the Proof of Concept field.

That file is fully self contained with:
- Compliance note (no mainnet/testnet testing)
- How to run instructions
- Dependencies
- Full Rust source code (Cargo.toml + lib.rs)
- Test matrix with explanations
- All 10 test results
- End to end attack flow
- On chain evidence table (read only data, no transactions)

## 6. Gist (Optional)

Create a secret GitHub Gist containing two files:
- `Cargo.toml` — the package manifest
- `src/lib.rs` — the full PoC source

To create from the command line:
```bash
gh gist create --desc "Kamino Scope ChainlinkX v10 PoC" \
  PoC/Cargo.toml PoC/src/lib.rs
```

Then paste the gist URL into the Immunefi Gist field.

## 7. Attachments

None required. The PoC is text based and self contained.

## 8. Acknowledgment

Check the box: "I confirm that my submission includes a clear, original explanation and a working PoC."

---

## File References

| Immunefi Field | Source File |
|---|---|
| Title | Use the title string above |
| Description | `IMMUNEFI-SUBMISSION-002.md` |
| Proof of Concept | `SUBMISSION-002-POC.md` |
| Gist | Create from `PoC/Cargo.toml` + `PoC/src/lib.rs` |
