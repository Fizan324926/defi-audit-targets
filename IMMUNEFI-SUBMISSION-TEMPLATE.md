# Immunefi Bug Bounty: Complete Methodology and Submission Rules

This document defines the full methodology for finding bugs, writing reports, building PoCs, creating gists, and submitting on Immunefi. Follow this for every vulnerability found across any audit target.

---

## Part 1: Bug Hunting Methodology

### Phase 1: Target Selection and Recon

1. Pick a program from https://immunefi.com/bug-bounty/ or audit competitions
2. Read the entire program page carefully. Note:
   - Assets in scope (smart contracts, websites, blockchain/DLT)
   - Impacts in scope (what severities and impact types are eligible)
   - Out of scope items (known issues, design decisions, specific files)
   - PoC requirements (which severities require a PoC)
   - Reward structure and minimums per severity
   - KYC requirements
   - Any program specific rules or conditions
3. Clone the repository. Identify the exact commit/version in scope.
4. Map the architecture: entry points, privileged roles, external dependencies, oracle integrations, token flows, upgrade mechanisms.

### Phase 2: Vulnerability Research

Focus on these high value areas first:

**Access Control**
- Permissionless functions that should be restricted
- Missing role checks, missing signer validation
- Functions missing CPI protection or reentrancy guards
- Admin functions callable by non admins

**Oracle and Price Manipulation**
- Missing price validation (bounds, confidence intervals, staleness)
- Ignored fields in oracle reports (like Scope ignoring tokenized_price)
- Inconsistent validation across oracle adapters (one adapter validates, another does not)
- Stale price acceptance, missing expiration checks
- Cross reference gaps (price vs reference price)

**Math and Arithmetic**
- Integer overflow/underflow without checks
- Division by zero paths
- Rounding errors that compound
- Missing zero value guards
- Precision loss in decimal conversions

**State Management**
- Race conditions in multi step operations
- Replay attacks (reusing signed data, stale reports)
- Inconsistent state after partial failures
- Missing suspension/pause mechanisms
- Bypass paths around safety gates (like activation_date_time = 0 bypassing suspension)

**Token and Fund Flows**
- Unchecked transfer return values
- Missing balance validations before transfers
- Flash loan attack vectors
- Reentrancy in withdraw/deposit paths
- Fee calculation errors

**Downstream Impact**
- How does a corrupted oracle price propagate to lending (collateral valuation, liquidations)?
- How does a manipulated state affect other protocols that read this contract?
- What is the maximum funds at risk? Calculate: total tokens * price at submission time.

### Phase 3: Hypothesis Testing

For each potential vulnerability:
1. State the hypothesis clearly: "If X happens, then Y is the impact"
2. Read the actual source code at the specific lines. Verify the logic matches your hypothesis.
3. Check if any other code path prevents the attack (guards, modifiers, upstream checks)
4. Verify on chain state matches your assumptions (deployed version, account data, configuration)
5. Build the PoC to prove or disprove
6. If the hypothesis fails, document why and move on. Do not submit false positives.

### Phase 4: Impact Assessment

Before writing the report, determine:
- Is the impact in the program's in scope list? If not, do not submit.
- Does the severity match what you are claiming? Do not overstate.
- Can you calculate funds at risk with real numbers? Use on chain TVL, token prices, market data.
- Is there a historical precedent for this class of vulnerability? Reference it.
- Does the attack require unrealistic preconditions? If so, lower the severity or do not submit.

---

## Part 2: Immunefi Platform Rules

### Absolute Rules (violation = immediate permanent ban)

- **NEVER test on mainnet or public testnet.** Fork locally with Hardhat/Foundry, replicate math locally, or use the project's test suite. This is the number one rule.
- **NEVER exploit or attack a live project.** Not even to "save funds" without written consent.
- **NEVER publicly disclose** a bug report or even its existence before it is fixed and paid.
- **NEVER submit a partial or incomplete PoC** when the program requires one.
- **NEVER create multiple Immunefi accounts.**

### Prohibited Behaviors (violation = suspension or ban)

- Misrepresenting assets in scope (claiming a bug targets an in scope asset when it does not)
- Misrepresenting severity (claiming Critical when it is clearly not)
- Misrepresenting impacts (selecting impacts that do not actually apply)
- Submitting AI generated or automated scanner reports that lack required information about the vulnerability's impact on the reported asset
- Placeholder submissions (vague title, few details, no reproducible steps)
- Submitting a bug that has already been publicly disclosed
- Submitting duplicates of your own report to claim additional rewards
- Spam or very low quality reports
- Submitting in any language other than English
- Beg bounty behavior (begging for a reward not owed based on program terms)
- Requesting gas fees from Immunefi or projects
- Routing around Immunefi to communicate with the project directly
- Submitting bugs via email or any channel other than the Immunefi platform
- Submitting fixes to a project's repository without their consent
- Publicly posting screenshots from bug reports (except amount rewarded)
- Contacting non support staff at Immunefi about your report
- Unauthorized disclosure or access of sensitive information beyond what is necessary

### What Happens If You Break Rules

- Temporary suspension or permanent ban at Immunefi's discretion
- Forfeiture and loss of access to bug reports
- Zero payout
- These rules apply in addition to each program's specific rules

### Behavioral Code

- Be ethical, respectful, professional, patient, and privacy conscious
- Co submitting with another hacker (with their consent) is permitted
- You can choose any framework or language for your PoC
- Always comply with program specific guidelines on top of these general rules

---

## Part 3: Submission File Structure

For each vulnerability, create these files in `audits/<project>/findings/`:

```
audits/<project>/findings/
  IMMUNEFI-SUBMISSION-<NNN>.md     # The report (Description field content)
  SUBMISSION-<NNN>-POC.md          # Self contained PoC (Proof of Concept field content)
  SUBMISSION-<NNN>-READY.md        # Submission guide: title, field mappings, checklist
```

If the PoC has runnable code, also create:

```
audits/<project>/PoC/
  Cargo.toml (or package.json, foundry.toml, hardhat.config.js, etc.)
  src/lib.rs (or test/*.sol, test/*.js, etc.)
```

---

## Part 4: SUBMISSION-NNN-READY.md (Submission Guide)

This file maps everything to the Immunefi form. Include:

1. **Title** — One sentence. Format: `<vulnerability> in <component> allows <actor> to <action> leading to <impact>`. Under 150 chars. No hyphenated compounds.

2. **Assets and Impact** — Program name, asset type (Smart Contract / Websites and Applications / Blockchain/DLT), on chain address, selected impact from the program's in scope list.

3. **Severity Level** — Must match the selected impact. Reference the program's severity table and minimum thresholds.

4. **Description** — Points to `IMMUNEFI-SUBMISSION-<NNN>.md`.

5. **Proof of Concept** — Points to `SUBMISSION-<NNN>-POC.md`.

6. **Gist** — The live gist URL plus clone and run instructions (see Part 7 below).

7. **Acknowledgment** — Confirm: "I confirm that my submission includes a clear, original explanation and a working PoC."

---

## Part 5: IMMUNEFI-SUBMISSION-NNN.md (The Report / Description)

This is the main report. Gets pasted into the Description field.

### Required Sections

```markdown
# <Title (same as submission title)>

## Bug Description
One paragraph. What is broken, where, what happens if exploited.
Conversational tone. No filler. State program, function, file, line numbers.
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

## Impact

### Impact Classification
State the selected in scope impact. Show the attack chain as a numbered list.

### Funds at Risk
Table with TVL, market size, LTV ratios, calculated bad debt.
Use real on chain data. Cite sources (DeFiLlama, project docs, on chain reads).

### Historical Precedents (optional but recommended)
Table of similar incidents with date, loss amount, root cause, relevance.

## Proof of Concept
Brief summary pointing to the PoC. Include compliance note, how to run,
dependencies, test matrix table, test results, on chain evidence.

## Recommendation
Numbered list of fixes with code diffs. Most critical fix first.

## References
Bullet list of all source code references and external links.
```

### Writing Style Rules

- Write in natural conversational english. Not too formal, not too casual.
- No hyphens in compound words: "per share" not "per-share", "on chain" not "on-chain", "pre split" not "pre-split", "off market" not "off-market", "end to end" not "end-to-end".
- No filler phrases like "it is important to note", "it should be noted", "this is particularly concerning".
- No bullet point lists where a sentence works better. Use tables for structured data.
- Show dont tell. Code snippets over descriptions of code.
- Use specific numbers. "$5M to $20M" not "significant funds".
- Every claim must be verifiable. Cite the file, line number, account address, or URL.
- Do not say "I" or "we". Write from third person or neutral perspective. Use "attacker", "crank operator", "the function" etc.
- The word "claude" must never appear anywhere in any submission file.
- The report must not look AI generated. Use varied sentence lengths, natural flow, occasional short direct sentences. Avoid pattern of always starting with "The" or "This".

---

## Part 6: SUBMISSION-NNN-POC.md (Proof of Concept)

Gets pasted into the Proof of Concept field. Must be fully self contained with no local system paths.

### Required Sections

```markdown
## Proof of Concept

### Compliance Note
State: no mainnet/testnet testing. Describe what the PoC does
(local math replication, forked state, etc).

### How to Run
Step by step commands from scratch. No paths like /root/... or ~/...

### Dependencies
All dependencies with exact versions. Note if they match on chain versions.

### <Build File> (Cargo.toml, foundry.toml, etc.)
Full file content in a code block.

### <Source File> (src/lib.rs, test/Exploit.t.sol, etc.)
Full source code in a code block. Complete file, ready to copy paste.

### Test Results
Paste the actual test output showing all tests pass.

### Test Matrix
Table mapping each test to what it proves and its impact.

### End to End Attack Flow (if applicable)
Numbered steps: setup to profit.

### On Chain Evidence (if applicable)
Tables of on chain data. State clearly: read only, no transactions submitted.
```

### Web3 PoC Rules (from Immunefi — mandatory)

- **NEVER test on mainnet or public testnet.** Violation = immediate permanent ban.
- **Fork mainnet locally** using Hardhat or Foundry. If forking is not feasible, use the project's existing test suite with conditions that accurately reflect deployed state.
- **PoC must contain runnable code.** Screenshots of code are not acceptable.
- **Include clear print statements and comments** that detail each step of the attack and display relevant information (funds stolen/frozen, price deviations, etc).
- **No partial or incomplete PoCs.** Every test must pass. Every claim must be demonstrated.
- **Use the same libraries the target uses on chain** when replicating math.
- **Mention all dependencies, configuration files, and environment variables** required to run the PoC.
- **Calculate funds at risk:** total amount of tokens * average price at submission time.
- If you want to demonstrate a DoS vulnerability, you must ask for and receive permission from the project in the Dashboard first.
- Whitehats can upload PoCs to Google Drive and share the link, or paste code directly if simple enough.
- Whitehats must comply with any additional PoC guidelines specified by the specific program.
- If the project requests more PoC information and you refuse, the PoC is considered invalid.

### PoC Quality Standards (what makes an excellent PoC)

Based on Immunefi's own examples (like the Polygon transferWithSig $2.2M bounty PoC):

1. **Fork at the right block.** Use the block before the fix was deployed. Show the vulnerability existed at that state.
2. **Calculate and display dollar amounts.** "Estimated funds at risk: 9,260,856,583 MATIC * $2.29 = $21,207,361,575 USD"
3. **Step by step attack flow** in both code comments and README.
4. **Minimal setup.** Reviewer should clone, set one env var, run one command.
5. **Multiple test angles.** Not just "it works" — show edge cases, show what a fix looks like, show why existing guards fail.
6. **Use Immunefi's forge-poc-templates** when applicable: https://github.com/immunefi-team/forge-poc-templates (reentrancy, flash loan, token manipulation, oracle manipulation templates available).

---

## Part 7: GitHub Gist Rules

Immunefi recommends linking a secret Gist to support your PoC. Gists are not a replacement for the PoC field — they supplement it.

### What is a Gist

A GitHub Gist is a lightweight code sharing link. Instead of the reviewer extracting code from markdown, they click the link, see formatted code, and can clone it. It makes triage faster and signals professionalism.

### Gist Requirements

- **Must be a secret gist.** Not public. (Note: `gh gist create` creates public by default — this is fine as "secret" just means unlisted, not truly private. The URL is not discoverable.)
- **Not a replacement for the PoC field.** The PoC must still be in the submission. The gist supplements it.
- **Must contain all files needed to run the PoC.** Reviewer clones and runs, nothing else needed.

### Gist Structure

Every gist should contain:

1. **README.md** — What the PoC proves, how to clone and run, dependencies, test matrix, target info
2. **Build file** (Cargo.toml, foundry.toml, package.json, hardhat.config.js)
3. **Source file(s)** (lib.rs, Exploit.t.sol, exploit.js)

### Gist README.md Template

```markdown
# <Project> — <Vulnerability Summary> PoC

## What this proves
One paragraph describing the vulnerability and what the tests demonstrate.

## How to run
git clone https://gist.github.com/<GIST_ID>.git <project-name>
cd <project-name>
# Any setup steps (mkdir src, mv files, set env vars)
<test command>

## Dependencies
- Language version
- Package versions (note if they match on chain)

## Test matrix
| Test | What it proves | Impact |
|------|---------------|--------|
| ... | ... | ... |

## Target
- Program, on chain address
- Repository URL
- Version/commit
- Vulnerable function and file
```

### How to Create a Gist

```bash
# Create the gist with all PoC files plus a README
gh gist create --desc "<Project> — <Vulnerability> PoC (N tests, all pass)" \
  README.md Cargo.toml src/lib.rs

# Note the returned gist URL
# Update README.md with the actual gist ID in the clone URL
# Then update the gist:
python3 -c "
import json
with open('README.md') as f: content = f.read()
payload = {'files': {'README.md': {'content': content}}}
print(json.dumps(payload))
" > /tmp/gist_payload.json
gh api --method PATCH 'gists/<GIST_ID>' --input /tmp/gist_payload.json
```

### Gist in the Submission

In the Immunefi form, paste the gist URL in the "Add a secret Gist environment" field. Also include in `SUBMISSION-NNN-READY.md`:

```markdown
## Gist

URL: https://gist.github.com/<username>/<GIST_ID>

Contains N files: README.md, Cargo.toml, lib.rs
Reviewer can clone and run in 30 seconds:
git clone https://gist.github.com/<GIST_ID>.git
cd <dir> && <setup> && <test command>
```

---

## Part 8: Verification Checklist (Before Submission)

Run through every item before submitting any report:

### Content Verification
- [ ] All on chain data verified live (not carried over from previous work)
- [ ] All line number references verified against the actual source code at the exact commit
- [ ] All account addresses verified on chain (program ID, data accounts, owned by correct program)
- [ ] All external links verified and accessible (repos, docs, post mortems)
- [ ] Funds at risk calculation uses real numbers with cited sources
- [ ] Historical precedents are accurate (dates, amounts, root causes)

### PoC Verification
- [ ] PoC compiles and ALL tests pass
- [ ] No mainnet or testnet interaction in the PoC
- [ ] Print statements show dollar amounts, step by step flow, and impact
- [ ] Uses the same libraries and versions the target uses on chain
- [ ] All dependencies listed with exact versions

### Submission Quality
- [ ] Title follows format: vulnerability + component + actor + impact
- [ ] Selected severity matches the impact and the program's in scope list
- [ ] Selected impact is actually in the program's in scope impacts list
- [ ] Asset targeted is actually in the program's in scope assets list
- [ ] Report uses natural conversational tone, no hyphenated compounds
- [ ] No system paths (no /root/..., no ~/...) in any submission file
- [ ] No "claude" or AI tells in any file
- [ ] PoC compliance note states no mainnet/testnet testing
- [ ] Gist is created, URL is in the READY file, clone instructions work
- [ ] No public disclosure of the vulnerability anywhere

### Immunefi Form
- [ ] Title filled in
- [ ] Correct program selected
- [ ] Correct asset selected
- [ ] Correct impact selected
- [ ] Severity level matches impact
- [ ] Description field has full report content
- [ ] Proof of Concept field has full PoC content
- [ ] Gist URL pasted
- [ ] Acknowledgment checkbox checked
- [ ] Wallet address provided

---

## Part 9: Severity Classification Reference

### Critical
- Direct loss of funds, protocol insolvency, permanent freezing of funds
- Funds at risk must exceed the program's minimum (often $50K or more)
- Requires a working PoC demonstrating the complete exploit path
- Example: Polygon transferWithSig ($2.2M bounty) — missing balance check allowed minting arbitrary tokens

### High
- Temporary freezing of funds (recoverable by admin action)
- Theft of unclaimed yield or fees
- Permanent denial of service to critical functions
- Griefing with material cost to users
- Example: Oracle manipulation bounded by existing guards but still causing bad debt

### Medium
- Logic errors without direct fund loss but with incorrect protocol behavior
- Missing validation exploitable under specific but realistic conditions
- Design issues that deviate from documented or intended behavior
- Incorrect pricing that does not directly enable theft but creates risk
- Example: Ignored oracle field that could cause price divergence

### Low / Informational
- Best practice violations
- Code quality issues that do not affect security
- Theoretical vulnerabilities requiring unrealistic preconditions
- Gas optimization opportunities

---

## Part 10: Quick Reference

### Immunefi Form Field Mapping

| Form Field | Source | Notes |
|---|---|---|
| Title | `SUBMISSION-NNN-READY.md` section 1 | Under 150 chars |
| Assets and Impact | `SUBMISSION-NNN-READY.md` section 2 | Must match program's in scope list |
| Severity Level | `SUBMISSION-NNN-READY.md` section 3 | Must match selected impact |
| Description | `IMMUNEFI-SUBMISSION-NNN.md` full content | Paste entire file |
| Proof of Concept | `SUBMISSION-NNN-POC.md` full content | Paste entire file |
| Gist | Live gist URL | Secret gist with README + source files |
| Attachments | Optional PNGs/JPEGs | Under 8MB each, max 20 |
| Wallet Address | Your payment wallet | Required for bounty payout |
| Acknowledgment | Checkbox | Must be checked |

### Key Immunefi Links

- Explore bounties: https://immunefi.com/bug-bounty/
- PoC guidelines: https://immunefisupport.zendesk.com/hc/en-us/articles/9946217628561
- Forge PoC templates: https://github.com/immunefi-team/forge-poc-templates
- Example excellent PoC: https://github.com/immunefi-team/polygon-transferwithsig
- Platform rules: https://immunefi.com/rules/

### Common PoC Frameworks

| Chain | Framework | Fork Command | Test Command |
|---|---|---|---|
| EVM | Foundry | `forge test --fork-url $RPC` | `forge test -vvv` |
| EVM | Hardhat | `npx hardhat test --fork $RPC` | `npx hardhat test` |
| Solana | Native Rust | Local math replication | `cargo test -- --nocapture` |
| Solana | Anchor | `anchor test` with local validator | `anchor test` |
| Move | Aptos/Sui | Move unit tests | `aptos move test` |
