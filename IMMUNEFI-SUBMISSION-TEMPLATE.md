# Immunefi Bug Report Submission Template

This template defines the structure and rules for all Immunefi bug report submissions. Follow this for every vulnerability found across any audit target.

---

## Submission File Structure

For each vulnerability, create the following files inside `audits/<project>/findings/`:

```
audits/<project>/findings/
  IMMUNEFI-SUBMISSION-<NNN>.md     # The report (Description field content)
  SUBMISSION-<NNN>-POC.md          # Self contained PoC (Proof of Concept field content)
  SUBMISSION-<NNN>-READY.md        # Submission guide: title, field mappings, checklist
```

If the PoC has runnable code, also create:

```
audits/<project>/PoC/
  Cargo.toml (or package.json, foundry.toml, etc.)
  src/lib.rs (or test/*.sol, test/*.js, etc.)
```

---

## File 1: SUBMISSION-NNN-READY.md (Submission Guide)

This file maps everything to the Immunefi form fields. Include:

1. **Title** — One sentence. Use format: `<vulnerability classification> in <component> allows <actor> to <action> leading to <impact>`. Keep under 150 chars. Do not use hyphens in compound words (use "per share" not "per-share", "on chain" not "on-chain").

2. **Assets and Impact** — Program name, asset type (Smart Contract / Websites and Applications / Blockchain/DLT), on chain address, selected impact from the program's in scope list.

3. **Severity Level** — Must match the impact selected. Reference the program's severity table and minimum thresholds.

4. **Description** — Points to `IMMUNEFI-SUBMISSION-<NNN>.md`.

5. **Proof of Concept** — Points to `SUBMISSION-<NNN>-POC.md`.

6. **Gist** — Command to create a secret gist from the PoC files. Always use `gh gist create --desc "..." <files>`.

7. **Acknowledgment** — Confirm the checkbox text.

---

## File 2: IMMUNEFI-SUBMISSION-NNN.md (The Report / Description)

This is the main report. It gets pasted into the Description field. Structure it with these sections:

### Required Sections

```markdown
# <Title (same as submission title)>

## Bug Description
One paragraph. What is broken, where is it, what happens if exploited.
Keep it conversational. No filler. State the program, the function, the file, the line numbers.
End with estimated funds at risk and why it qualifies for the selected severity.

## Vulnerability Details

### Target Asset
- Program name, repo URL, on chain address
- File, function, line numbers
- Version/commit

### Root Cause
Show the vulnerable code. Explain what validations are missing.
Number each missing validation and explain why it matters.

## Attack Vector 1: <descriptive name>
Full attack scenario. Step by step. Include:
- Who can trigger it (permissionless? admin? specific role?)
- What the preconditions are
- What happens at each step
- Dollar amounts where possible

## Attack Vector 2: <descriptive name> (if applicable)
...repeat for each distinct attack path...

## Impact

### Impact Classification
State the selected in scope impact. Show the attack chain as a numbered list.

### Funds at Risk
Table with TVL, market size, LTV ratios, calculated bad debt.
Use real on chain data. Cite sources (DeFiLlama, project docs, on chain reads).

### Historical Precedents (optional but recommended)
Table of similar incidents with date, loss amount, root cause, relevance.

## Proof of Concept
Brief summary pointing to the PoC file. Include:
- Compliance note (no mainnet/testnet testing)
- How to run
- Dependencies
- Test matrix table
- Test results output
- On chain evidence (if applicable, read only)

## Recommendation
Numbered list of fixes. Include code diffs where possible.
Order by importance. Most critical fix first.

## References
Bullet list of all source code references and external links.
```

### Writing Style Rules

- Write in natural conversational english. Not too formal, not too casual.
- No hyphens in compound words: write "per share" not "per-share", "on chain" not "on-chain", "pre split" not "pre-split", "off market" not "off-market", "end to end" not "end-to-end".
- No filler phrases like "it is important to note", "it should be noted", "this is particularly concerning".
- No bullet point lists where a sentence works better. Use tables for structured data.
- Show dont tell. Code snippets > descriptions of code.
- Use specific numbers. "$5M to $20M" not "significant funds".
- Every claim must be verifiable. Cite the file, line number, account address, or URL.
- Do not say "I" or "we". Write from a third person or neutral perspective when describing the vulnerability. Use "attacker", "crank operator", "the function" etc.
- The word "claude" must never appear anywhere in any submission file.

---

## File 3: SUBMISSION-NNN-POC.md (Proof of Concept)

This file gets pasted into the Proof of Concept field. It must be fully self contained with no references to local system paths.

### Required Sections

```markdown
## Proof of Concept

### Compliance Note
State: no mainnet/testnet testing performed. Describe what the PoC does (local math replication, forked state, etc).

### How to Run
Step by step commands. Start from scratch (mkdir, create files, run tests).
Do not reference paths like /root/... or ~/... — everything should be relative.

### Dependencies
List all dependencies with exact versions. Note if they match on chain versions.

### <Build File> (e.g., Cargo.toml, foundry.toml)
Full file content in a code block.

### <Source File> (e.g., src/lib.rs, test/Exploit.t.sol)
Full source code in a code block. This must be the complete file, ready to copy paste.

### Test Results
Paste the actual test output showing all tests pass.

### Test Matrix
Table mapping each test to what it proves and what the impact is.

### End to End Attack Flow (if applicable)
Numbered steps showing the complete attack sequence from setup to profit.

### On Chain Evidence (if applicable)
Tables of on chain data used in the report. State clearly that this is read only data and no transactions were submitted.
```

### PoC Rules (from Immunefi)

- **Never test on mainnet or public testnet.** Use local forks, local math replication, or the project's existing test suite.
- **Must be runnable.** The reviewer should be able to clone/copy, install deps, and run tests.
- **Include clear print statements and comments** that detail each step and display relevant numbers (funds stolen, price deviation, etc).
- **No screenshots of code.** Full source code in text.
- **No partial or incomplete PoCs.** Every test must pass. Every claim must be demonstrated.
- **Use the same libraries the target uses on chain** when replicating math. This proves the vulnerability exists in the actual arithmetic, not a different implementation.

---

## Verification Checklist (Before Submission)

Run through this before submitting any report:

- [ ] All on chain data verified live (not carried over from previous work)
- [ ] All line number references verified against the actual source code
- [ ] All account addresses verified on chain (program ID, data accounts, etc)
- [ ] All external links verified (repos, docs, post mortems)
- [ ] PoC compiles and all tests pass
- [ ] No system paths in any submission file
- [ ] No "claude" or AI tells in any file
- [ ] Title follows the format: vulnerability + component + actor + impact
- [ ] Selected severity matches the impact and the program's in scope list
- [ ] Funds at risk calculation uses real numbers with cited sources
- [ ] Report uses natural conversational tone, no hyphenated compounds
- [ ] PoC compliance note states no mainnet/testnet testing
- [ ] Gist creation command is ready

---

## Severity Classification Reference

### Critical
- Direct loss of funds or protocol insolvency
- Funds at risk must exceed the program's minimum (often $50K)
- Requires a working PoC demonstrating the exploit path

### High
- Temporary freezing of funds or denial of service
- Indirect financial impact through price manipulation (when bounded)
- Griefing with material cost to users

### Medium
- Logic errors without direct fund loss
- Missing validation that could be exploited under specific conditions
- Design issues that deviate from documented behavior

### Low / Informational
- Best practice violations
- Code quality issues
- Theoretical vulnerabilities requiring unrealistic preconditions

---

## Quick Reference: Immunefi Form Fields

| Form Field | Source | Notes |
|---|---|---|
| Title | `SUBMISSION-NNN-READY.md` section 1 | Under 150 chars |
| Assets and Impact | `SUBMISSION-NNN-READY.md` section 2 | Must match program's in scope list |
| Severity Level | `SUBMISSION-NNN-READY.md` section 3 | Must match selected impact |
| Description | `IMMUNEFI-SUBMISSION-NNN.md` full content | Paste entire file |
| Proof of Concept | `SUBMISSION-NNN-POC.md` full content | Paste entire file |
| Gist | Create from PoC source files | `gh gist create --desc "..." <files>` |
| Attachments | Optional PNGs/JPEGs | Under 8MB each, max 20 |
