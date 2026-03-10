# AI Audit Rules & Methodology

Authoritative rulebook for conducting smart contract and protocol security audits for Immunefi bug bounties. Every rule here is a standing instruction — follow it without re-prompting.

**Cross-references:**
- Reporting format → [`IMMUNEFI-REPORT-GUIDE.md`](IMMUNEFI-REPORT-GUIDE.md)
- Program list → [`all_programs.txt`](all_programs.txt)
- Audit folders → [`audits/`](audits/)

---

## Table of Contents

1. [Absolute Constraints](#1-absolute-constraints)
2. [Phase 1 — Scope Determination](#2-phase-1--scope-determination)
3. [Phase 2 — Full Codebase Exploration](#3-phase-2--full-codebase-exploration)
4. [Phase 3 — Multi-Angle Analysis](#4-phase-3--multi-angle-analysis)
5. [Phase 4 — Finding Verification](#5-phase-4--finding-verification)
6. [Phase 5 — False Positive Elimination](#6-phase-5--false-positive-elimination)
7. [Phase 6 — Exploit Development](#7-phase-6--exploit-development)
8. [Phase 7 — Report Writing & Immunefi Submission](#8-phase-7--report-writing--immunefi-submission)
9. [Phase 8 — Repository Organization](#9-phase-8--repository-organization)
10. [Vulnerability Catalog](#10-vulnerability-catalog)
11. [Auditor Quick-Reference Checklist](#11-auditor-quick-reference-checklist)
12. [Comprehensive 280-Point Attack Vector Checklist](#12-comprehensive-280-point-attack-vector-checklist)

---

## 1. Absolute Constraints

These rules override everything else. No exceptions.

### 1.1 Real Vulnerabilities Only

- **NEVER submit theoretical or conceptual findings.** Every reported vulnerability must be confirmed by reading the actual deployed (production/mainnet) source code.
- A finding is only real if: the vulnerable code path exists in production, is reachable, produces the stated impact, and no existing defense prevents it.
- If a code path exists only in dev/test/migration scripts and cannot be triggered on mainnet, it is **not a finding**.

### 1.2 Full Codebase — No Partial Audits

- **ALWAYS audit the entire in-scope codebase, not a single file or module.**
- Read every in-scope contract, program, module, and library before reporting.
- Track what has been read. Do not report until every in-scope file has been analyzed.
- If the codebase is very large, use parallel agent exploration — do not skip sections.

### 1.3 Confirm In-Scope Before Reporting

- **Every finding must reference an in-scope asset.** Check `all_programs.txt` plus the target's Immunefi bounty page for explicit scope inclusions and exclusions.
- If the affected file/contract is not in scope, mark the finding OUT OF SCOPE and do not submit.
- Apply **Primacy of Rules**: if the program's rules exclude a category (e.g., "best practice critiques"), do not submit findings that fall in that category even if technically valid.

### 1.4 Test Before Reporting

- Write and run verification scripts (Python, Rust tests, Foundry, Hardhat, Anchor tests) for **every finding** before adding it to a report.
- Scripts must demonstrate the specific vulnerability, not a generic behavior.
- If you cannot write a working PoC, lower confidence and clearly state the limitation in the report. Do not fabricate test results.

### 1.5 Exploit Optimization

- For each confirmed finding, determine the maximum economic damage achievable under optimal attack parameters.
- Use linear programming (GEKKO or scipy) for multi-variable optimizations.
- Express loss in USD at current prices, not just token units.

---

## 2. Phase 1 — Scope Determination

### 2.1 Read the Program Entry from `all_programs.txt`

All bounty program data is already scraped and stored locally in [`all_programs.txt`](all_programs.txt). **Do not fetch the live Immunefi page** — read from the local file.

To locate a target, search by SLUG:
```bash
grep -A 100 "^SLUG: <target-slug>$" all_programs.txt
```

For every new target, extract and record:

| Field | Location in file | What to capture |
|-------|-----------------|-----------------|
| Primacy | `PRIMACY:` line | `Primacy Of Rules` vs `Primacy Of Impact` — determines whether only listed impacts qualify |
| Max bounty | `MAX BOUNTY:` line | Upper cap for Critical |
| Rewards by severity | `REWARDS BY SEVERITY:` block | USD amounts for Critical / High / Medium / Low |
| KYC required | `KYC REQUIRED:` line | Yes / No |
| PoC required | `TAGS:` → `PoC Required` | Whether a working PoC is mandatory |
| In-scope assets | `IN-SCOPE ASSETS:` block | Every contract/program address and asset type |
| Out-of-scope assets | `OUT OF SCOPE:` block | Excluded contracts, files, third-party protocols |
| Out-of-scope vuln types | `OUT OF SCOPE VULNERABILITIES:` block | Excluded categories (e.g., "best practice critiques") |
| Ecosystem / Language | `TAGS:` block | Solana/EVM, Rust/Solidity — determines audit toolchain |

### 2.2 Identify On-Chain Deployments

- Find all mainnet and relevant testnet addresses for in-scope contracts/programs.
- Confirm the deployed bytecode / program binary matches the source code being audited.
- Use block explorers (Etherscan, Solscan, Arbiscan, etc.) to verify deployment.
- Note the deployment block / date — vulnerabilities must be present in the live code.

### 2.3 Map External Dependencies

- List all external protocols, oracles, tokens, and bridges that the target interacts with.
- Note which are in scope vs. which are trusted third parties.
- Third-party issues are generally out of scope unless the target's integration of them is flawed.

---

## 3. Phase 2 — Full Codebase Exploration

### 3.1 Discovery Pass

Systematically enumerate every source file:
```
Glob all source files: *.sol, *.rs, *.ts (contracts), *.py
For Rust/Anchor: src/**/*.rs, programs/**/*.rs, Cargo.toml, Cargo.lock
For Solidity: contracts/**/*.sol, interfaces/**/*.sol, libraries/**/*.sol
For configuration: foundry.toml, hardhat.config.ts, package.json, Cargo.toml
```

Build a file inventory before reading any files. Track read status.

### 3.2 Build Configuration Review

For every project:
- **Rust**: Read workspace `Cargo.toml` for `overflow-checks`, `opt-level`, feature flags.
- **Solidity**: Read `foundry.toml` or `hardhat.config` for solc version, optimizer settings, via-IR.
- **Node**: Read `package.json` for dependency versions — look for known-vulnerable versions.
- These settings affect which vulnerability classes are possible.

### 3.3 Dependency Audit

- List all external library imports/dependencies.
- Check for known vulnerabilities in dependency versions.
- For Solidity: confirm OpenZeppelin version — older versions have known issues.
- For Rust: check for yanked crates or crates with security advisories.

### 3.4 Read Every In-Scope File

**No skipping.** Read:
- All instruction/function handlers
- All state definitions and account structs
- All math/calculation libraries
- All access control and authorization logic
- All external integration points (oracle calls, bridge calls, DEX calls)
- All administrative functions
- All initialization and upgrade logic

For large files, track which sections have been analyzed.

---

## 4. Phase 3 — Multi-Angle Analysis

Analyze every component from these six angles. Findings emerge from applying multiple angles simultaneously.

### 4.1 Single-File Analysis

For each file in isolation:
- What invariants does this file enforce?
- What are the preconditions and postconditions of each function?
- Are there any integer operations that could overflow/underflow?
- Are there any unchecked calls whose failure would corrupt state?
- Are there any assumptions about caller identity that are not validated?
- What happens if called with boundary inputs (0, max uint, empty arrays)?

### 4.2 Architecture / Data Flow Analysis

Across the whole protocol:
- Draw the fund flow: where do user funds enter, where do they exit, what state tracks them?
- Are there any states where the accounting sum does not equal the actual balance?
- Are there multiple paths to the same state — do they all have the same invariants?
- Is there any state that cannot be recovered from once set?
- What happens if the protocol is called in an unexpected order?

### 4.3 Feature / Functional Flow Analysis

For each core protocol feature:
- Trace the complete happy-path execution: every instruction, every state change, every event.
- Trace error paths: what happens if each step fails? Is the state left consistent?
- Trace cross-feature interactions: does feature A break when feature B is active?
- Trace upgrade paths: does initialization run correctly after upgrade?

### 4.4 Role / Privilege Analysis

Enumerate every privileged role (owner, admin, fee authority, governance, etc.):
- What can each role do?
- Can a role be captured by an attacker (key compromise, social engineering, frontrunning)?
- Can a role take actions that harm regular users?
- Are there missing roles — admin actions that any user can perform?
- Are there role handoff functions that could be frontrun or bricked?

### 4.5 Economic / Incentive Analysis

- Are there any states where an attacker profits by acting adversarially?
- Are there any states where an attacker profits by NOT acting (griefing, withholding)?
- Is the liquidation mechanism profitable enough to always attract liquidators?
- Are there any reward calculations where a larger stake produces disproportionate rewards?
- Can the protocol be drained by repeatedly entering/exiting a position?

### 4.6 Integration / Composability Analysis

For every external protocol call (oracle, DEX, bridge, ERC-20):
- What happens if the external call returns an unexpected value (0, max, stale, reverts)?
- What happens if the external contract is upgraded or becomes malicious?
- What happens if the external contract is a non-standard token (fee-on-transfer, rebasing, ERC-777)?
- What happens if the protocol is called atomically with another protocol (flash loan, same-block)?

---

## 5. Phase 4 — Finding Verification

For every potential vulnerability identified during Phase 3:

### 5.1 Confirm the Vulnerable Code Path

- Identify the exact file and line number.
- Confirm the vulnerable code is in the production codebase, not test/dev code.
- Trace every call from a public entry point to the vulnerable line.
- Confirm there is no check earlier in the call stack that prevents reaching it.

### 5.2 Confirm the Absence of Defenses

Actively look for reasons the vulnerability might NOT be exploitable:
- Is there an access control check that prevents exploitation?
- Is there a separate invariant that prevents the bad state?
- Is there a circuit breaker or pause mechanism that would trigger first?
- Is the attack prevented by economic constraints (gas cost > profit, min deposit, etc.)?
- Is there a timelock or delay that gives the protocol time to respond?

If any defense is found, document it and assess if it is fully effective or can be bypassed.

### 5.3 Establish Impact

Define impact precisely:
- **Who loses funds?** (user, LP, protocol treasury, specific role)
- **How much?** (exact formula, worst-case amount, realistic-case amount)
- **Is it permanent or recoverable?** (funds drained vs. temporary lock vs. accounting error)
- **Is active exploitation required or is it passive?** (exploiter must act, or just wait)
- **What on-chain preconditions are required?**

### 5.4 Assign Preliminary Severity

Use the target's reward tiers. For Immunefi standard:

| Severity | Smart Contract Criteria |
|----------|------------------------|
| Critical | Direct theft of user funds; unauthorized minting; permanent fund lock |
| High | Theft requiring specific conditions; temporary fund lock; severe protocol disruption |
| Medium | Contract failure under rare conditions; temporary access loss; financial loss below threshold |
| Low | Minor griefing; cosmetic issues with no fund risk |
| None | Best practice; informational; out of scope; false positive |

---

## 6. Phase 5 — False Positive Elimination

**This is the most critical phase.** More than 95% of initial findings are false positives. Every finding MUST survive ALL of the following elimination filters before proceeding to exploit development. If a finding fails ANY filter, mark it FALSE POSITIVE with the specific reason and move on.

### 6.1 Feasibility Kill Switches — Instant Rejection

Reject immediately if ANY of these apply:

| Kill Switch | Rule | Example from Real Audits |
|-------------|------|--------------------------|
| **Astronomical precondition** | If exploit requires accumulating impossible amounts (>total supply, >100 years of volume), it will NEVER happen | Orca H-02: overflow needs 18.4 trillion USDC in uncollected fees — infeasible |
| **Admin-only trigger** | If only a trusted admin/owner/multisig can trigger the bug, it's centralization risk — most programs exclude this | Orca H-01: requires admin key to set bad parameters — out of scope |
| **Heat death timescale** | If the bug requires >1 billion transactions, >100 years, or >2^128 operations to trigger | Optimism: nonce overflow needs 2^240 transactions — physically impossible |
| **Zero net profit** | If the attack costs more (gas, capital, opportunity cost) than it extracts, no rational attacker would do it | Many DoS vectors: attacker pays gas but gains nothing |
| **Requires broken external dependency** | If the bug only triggers when Chainlink/Uniswap/Ethereum itself is broken, that's the dependency's bug | "If the oracle returns 0" — Chainlink has its own safeguards |

### 6.2 Defense Verification — Check ALL Existing Protections

Before reporting, systematically verify that NO existing defense prevents exploitation:

```
[ ] Access control: Is there a modifier/require/assert that blocks the attack path?
[ ] Reentrancy guard: Is there a lock, sentinel value, or checks-effects-interactions?
[ ] Invariant maintenance: Does a separate check/function maintain the invariant elsewhere?
[ ] Economic guard: Is there a minimum deposit, bond, or fee that makes the attack unprofitable?
[ ] Timelock/delay: Is there a waiting period that allows intervention?
[ ] Pause mechanism: Would the protocol's pause/guardian catch this before damage?
[ ] Type safety: Does the type system (uint256, Solidity 0.8 overflow checks) prevent it?
[ ] Boundary clamping: Is the value clamped, saturated, or bounded elsewhere?
[ ] Upstream validation: Does a caller higher in the call stack validate the input?
[ ] Downstream resilience: Does the consumer of the output handle the bad value safely?
```

### 6.3 Common False Positive Patterns — Learn to Recognize These

These patterns produce findings that LOOK real but ARE NOT. Eliminate instantly when recognized.

#### A. "Theoretical Overflow" (Most Common FP)

**Pattern**: "This uint64/uint128/uint256 can overflow if..."

**Reality check**:
- `uint256` overflow requires values >1.15e77 — impossible for any economic quantity
- `uint128` overflow requires values >3.4e38 — impossible for any token amount in existence
- `uint64` overflow requires values >1.8e19 — only possible for wei-denominated counters with extreme throughput
- Solidity 0.8+ reverts on overflow by default — wrapping only in `unchecked{}` blocks
- Rust with `overflow-checks = true` panics on overflow — wrapping only with `wrapping_*` methods

**Only report overflow if**: the value is a persistent accumulator, the type is realistically reachable, AND overflow-checks are disabled.

#### B. "Admin Can Rug" (Centralization Risk)

**Pattern**: "The owner can set X to a malicious value, draining all funds"

**Rejection criteria**:
- Most Immunefi programs explicitly exclude "centralization risk" and "admin privilege" issues
- If the function requires `onlyOwner`, `onlyAdmin`, or a governance multisig, it is a TRUSTED role
- Only report if: the admin action has no timelock AND contradicts the protocol's documented trust model AND the program does NOT exclude admin issues

#### C. "Division by Zero" / "Empty State Panic"

**Pattern**: "If the pool is empty / totalSupply is 0 / denominator is 0, this reverts"

**Reality check**:
- Most protocols initialize with non-zero values or check for zero before dividing
- A revert on empty state is often CORRECT behavior (fail-safe, not a bug)
- Only report if: the zero state is REACHABLE in production AND the revert causes permanent fund lock (not just a failed transaction)

#### D. "Best Practice Critique" (Not a Vulnerability)

**Pattern**: "This should use X instead of Y" / "Missing event emission" / "panic! instead of Error"

**Rejection criteria**:
- Many programs (especially Primacy of Rules) explicitly exclude "best practice critiques"
- If there is no financial impact to users/LPs/protocol, it is not a vulnerability
- Missing events, style issues, gas optimizations, and code organization are NEVER submittable

#### E. "Struct Size Mismatch" / "Schema Evolution"

**Pattern**: "If this struct grows beyond N bytes, the code will panic"

**Reality check**:
- Check if reserved/padding bytes prevent growth beyond the limit
- Check if the struct has fixed-size fields that can never change
- If the struct is compile-time fixed, the mismatch is unreachable

#### F. "First-Depositor Attack" (Already Mitigated)

**Pattern**: "Classic ERC-4626 share inflation on empty vault"

**Reality check**:
- Check for virtual offset (`_decimalsOffset()` in OpenZeppelin 4.9+)
- Check for minimum deposit requirements
- Check for dead shares minted to zero address during initialization
- Most modern vaults have at least one mitigation — verify ALL are absent before reporting

#### G. "Reentrancy" (Already Guarded)

**Pattern**: "External call before state update — classic reentrancy"

**Reality check**:
- Check for `nonReentrant` modifier (OpenZeppelin ReentrancyGuard)
- Check for sentinel value pattern (e.g., Optimism's `l2Sender`/`xDomainMsgSender`)
- Check for transient storage guards (EIP-1153)
- Check for checks-effects-interactions even if not obvious (state may be updated in a different way)
- ETH-only protocols on chains without ERC-777 may be safe from token callback reentrancy

#### H. "On-Chain/Off-Chain Divergence" (VMs, Oracles)

**Pattern**: "If the on-chain VM handles X differently than the off-chain VM..."

**Reality check**:
- Read BOTH implementations (Go/Rust off-chain AND Solidity on-chain)
- Check the test suite for parity tests
- If both implementations match (both panic, both return 0, both revert), there is no divergence
- Optimism lesson: division-by-zero handling matched perfectly across on-chain/off-chain VMs

#### I. "DoS via Gas" (Usually Not Submittable)

**Pattern**: "An attacker can make this function consume too much gas"

**Reality check**:
- If the attacker pays their own gas, it's self-griefing
- If the array/loop is only iterable by the affected user, it's user-griefing (their own fault)
- Only report if: the DoS affects OTHER users, is permanent or long-lasting, AND the attacker profits or pays negligible cost

#### J. "Ordering / Timing" (Check If By Design)

**Pattern**: "If function A is called before function B, bad things happen"

**Reality check**:
- Check if the protocol documents the expected call order
- Check if there are guards that enforce ordering (state machine, flags, timestamps)
- Check if the "bad" outcome is actually acceptable (failed transaction, not fund loss)
- Only report if: the misordering is reachable in normal usage AND causes financial impact

### 6.4 Severity Downgrade Rules

Even confirmed bugs may not be submittable. Apply these downgrades:

| Condition | Severity Adjustment |
|-----------|-------------------|
| Requires admin/privileged action to trigger | OUT OF SCOPE (most programs) |
| Temporary DoS only, no fund loss | Maximum: Medium (usually Low) |
| Funds recoverable via admin action within reasonable time | Downgrade one tier |
| Requires front-running with precise timing | Downgrade if MEV is excluded |
| Only affects attacker's own funds | NOT A VULNERABILITY |
| Requires > $1M in capital with < $100 profit | NOT ECONOMICALLY VIABLE |
| Requires protocol to be in a rare emergency state | Downgrade one tier |
| Impact is informational only (events, logging, display) | NOT SUBMITTABLE |

### 6.5 The Final Test — Would YOU Attack This?

Before writing the report, honestly answer:

1. **If you had unlimited capital and technical skill, would you actually execute this attack?**
   - If no → it's not a real vulnerability
2. **Would a rational economic actor spend time building this exploit?**
   - If the profit is < $1,000, probably not (unless it's a Critical mechanism bug)
3. **Has this exact pattern been found and reported before in this protocol?**
   - Check past Immunefi reports, Code4rena findings, and Sherlock audits for the same codebase
4. **Does the developer's own comment suggest they're aware of this?**
   - If there's a `// NOTE:`, `// SAFETY:`, or `// INVARIANT:` comment addressing it, it's likely known

---

## 7. Phase 6 — Exploit Development

### 7.1 When to Write a Full Exploit

Write a complete working exploit for:
- All Critical findings
- All High findings
- Medium findings where the exploitability is uncertain

For Low findings where impact is clear and mechanism is simple, a PoC script that demonstrates the vulnerable state is sufficient.

### 7.2 Exploit Environment

Choose the appropriate environment based on what the code runs on:

**EVM (Solidity):**
- Primary: Foundry fork test (`vm.createFork(RPC_URL, BLOCK_NUMBER)`)
- Secondary: Hardhat fork test (`hardhat_reset` with forking config)
- Never test on mainnet directly — always fork at a pinned block

**Solana (Rust/Anchor):**
- Primary: `anchor test` with `localnet` or `bankrun`
- Secondary: devnet with a funded test keypair (use provided IDs)
- For devnet testing: can use provided accounts/keypairs

**General scripting:**
- Python (web3.py, solana-py) for state verification and arithmetic proofs
- Rust test harness for Solana program unit tests
- Node.js (ethers.js, viem) for EVM interaction scripts

### 7.3 Exploit File Naming

```
audits/<target>/exploits/<VULN-ID>-<short-name>.md       # writeup
audits/<target>/scripts/<VULN-ID>-exploit.<ext>          # runnable code
audits/<target>/scripts/verify/<VULN-ID>-verify.<ext>    # verification only
```

### 7.4 Exploit Writeup Structure

Each exploit file (`exploits/<VULN-ID>-<name>.md`) must contain:

```
1. Summary: one paragraph — what breaks, how, who loses what
2. Prerequisites: role required, on-chain state required, capital required
3. Step-by-step attack scenario: numbered, with code snippets at each step
4. Transaction flow: function call trace showing state before/after
5. Impact quantification: dollar amounts, affected users/funds, time horizon
6. PoC output: actual output from running the exploit script
7. Detection: how to detect this on-chain after the fact
8. Fix: minimal code change that eliminates the vulnerability
```

### 7.5 Attack Parameter Optimization

When the exploit has tunable parameters, find the optimal values:

```python
# Example: optimize flash loan amount, fee tier, and block timing
from gekko import GEKKO
m = GEKKO(remote=False)
amount = m.Var(lb=0, ub=max_flash)
fee = m.Var(lb=0.0001, ub=0.01)
profit = m.Intermediate(amount * fee * price_impact_function(amount))
m.Maximize(profit)
m.solve(disp=False)
print(f"Optimal amount: {amount.value[0]}")
print(f"Max profit: {profit.value[0]}")
```

---

## 8. Phase 7 — Report Writing & Immunefi Submission

### 8.1 One Report Per Vulnerability

Each finding gets its own file: `audits/<target>/findings/<ID>-<slug>.md`

**NEVER bundle multiple vulnerabilities into one report.**

### 8.2 Required Report Sections

Follow the full format from [`IMMUNEFI-REPORT-GUIDE.md`](IMMUNEFI-REPORT-GUIDE.md):

```markdown
# [SEVERITY] Title — Short, specific (max 10 words)

**Severity:** Critical | High | Medium | Low
**Target:** Contract/Program Name
**File(s):** path/to/file.sol:line_number
**Immunefi Program:** https://immunefi.com/bug-bounty/<program>/

## Brief / TL;DR
One paragraph. What is broken, how it can be exploited, what is lost.

## Vulnerability Details
Exact code location, what the code does, what it should do, why the difference matters.
Include the vulnerable code snippet with line references.

## Impact
- Who loses: [user funds / LP funds / protocol treasury / all users]
- Amount: [formula and worst-case dollar value]
- Permanence: [permanent / recoverable with admin action / temporary]
- Likelihood: [passive accumulation / requires specific conditions / always exploitable]

## Risk Breakdown
| Factor | Assessment |
|--------|-----------|
| Attacker role required | None / User / Privileged |
| Capital required | None / Flash loan / $X minimum |
| On-chain conditions | Always present / Requires X |
| Profitability | Always profitable / Conditional |

## Proof of Concept
Link to exploit script and paste actual output.
Explain each step in plain English.

## Recommended Fix
Minimal code diff that eliminates the vulnerability. No refactoring.
```

### 8.3 What Makes a Report Submittable

- [ ] Severity matches Immunefi program's reward tier criteria
- [ ] Finding is in scope (asset + vulnerability type)
- [ ] PoC is runnable and produces the stated output
- [ ] Impact is quantified in dollar terms
- [ ] No existing defense prevents the exploit
- [ ] Fix is included
- [ ] No duplicate of existing public disclosure
- [ ] Passed ALL false positive elimination filters (Phase 5)

### 8.4 Immunefi Submission-Ready Report (MANDATORY)

For **every confirmed vulnerability**, produce a **ready-to-submit Immunefi report** saved as:

```
audits/<target>/findings/IMMUNEFI-SUBMISSION-<ID>.md
```

This file must be **copy-paste ready** for the Immunefi submission form. It must contain ALL of the following:

#### Required Sections

| Section | Content | Notes |
|---------|---------|-------|
| **Bug Description** | Clear summary, vulnerable code with exact file paths and line numbers, call chain analysis, comparison with correct behavior (if applicable) | Show the code, not just describe it |
| **Impact** | Severity classification per Immunefi tiers, financial impact estimate with math, affected user classes | Quantify in USD at current prices |
| **Risk Breakdown** | Difficulty to exploit, weakness type (CWE ID), CVSS score | Use standard classifications |
| **Recommendation** | Concrete fix as a diff (`-` old / `+` new) | Minimal change only |
| **Proof of Concept** | Working Foundry/Anchor/Python test that demonstrates the actual impact | Must be runnable on local fork |
| **References** | Direct links to affected source files on GitHub with line numbers | Use permalink format |

#### PoC Requirements

The PoC MUST:
- Run locally — no mainnet/testnet interaction
- Demonstrate the actual bug impact, not just a theoretical state
- Include clear setup, exploit steps, and assertions with descriptive names
- Be saved BOTH inline in the submission report AND as a standalone file:
  ```
  audits/<target>/scripts/verify/PoC_<ID>_<name>.sol   (Solidity/Foundry)
  audits/<target>/scripts/verify/PoC_<ID>_<name>.py     (Python)
  audits/<target>/scripts/verify/PoC_<ID>_<name>.rs     (Rust/Anchor)
  ```
- Use self-documenting variable names: `attacker`, `victim`, `honestChallenger`, etc.
- Include comments explaining each step of the attack

#### Example Submission Structure

```markdown
# Bug Description
[Clear explanation with vulnerable code snippets and line references]

# Impact
[Severity, financial estimate, affected users]

# Risk Breakdown
[Difficulty, CWE, CVSS]

# Recommendation
[Diff showing the fix]

# Proof of Concept
[Foundry/Hardhat test code, inline]

## Running the PoC
[Exact commands to run]

## Expected Output
[What the test output looks like]

# References
[GitHub links to affected files]
```

---

## 9. Phase 8 — Repository Organization

### 9.1 Folder Structure Per Target

```
audits/<target>/
├── README.md                    # audit summary, all findings, status table
├── findings/
│   ├── <ID>-<slug>.md           # final report, ready to submit
│   └── exploits/
│       └── <ID>-exploit.md      # detailed exploit writeup
├── scripts/
│   ├── <ID>-exploit.<ext>       # runnable exploit
│   └── verify/
│       └── <ID>-verify.<ext>    # verification-only scripts
└── notes/
    └── false-positives/         # eliminated findings with rationale
        └── <ID>-<slug>.md
```

### 9.2 Root README Updates

After each audit add/update a row in the root `README.md`:
- Active audits table: program, bounty, language, folder link, status
- Per-program section: findings table, exploit links, verification script links

The root README is the single source of truth for:
- Which programs are being audited
- Which findings are confirmed vs. eliminated
- Which reports are ready to submit
- Risk/impact summary for each finding
- Links to all exploit writeups and scripts

### 9.3 Audit README Requirements

Each `audits/<target>/README.md` must contain:
- Program overview (protocol description, TVL, chain, bounty size)
- Scope summary (in-scope contracts/programs)
- Findings table with severity, description, submission status
- Confirmed findings section with full detail links
- Eliminated findings section with brief rationale
- Files audited list
- Verification scripts table with commands to reproduce

---

## 10. Vulnerability Catalog

This catalog is a starting point — it is **not exhaustive**. Always analyze based on the specific architecture, language, and code patterns present. Novel vulnerabilities unique to a protocol's design are often the highest-value findings.

---

### TIER 1: CRITICAL ($50K–$15M) — Direct Fund Loss

#### 10.1 Reentrancy

**What to grep for:** `.call{value:`, `.transfer(`, `safeTransfer(`, `safeTransferFrom(`

| Pattern | Where It Hides |
|---------|---------------|
| State written AFTER external call | Withdraw / redeem / claim functions |
| Cross-function reentrancy | Function A calls external, Function B reads dirty state |
| Read-only reentrancy | `view` returns stale value during callback, consumed by another protocol |
| ERC-777 `tokensReceived` hook re-entry | Any `safeTransfer` on a token that could be ERC-777 |
| ERC-1155 `onERC1155Received` re-entry | NFT / multi-token transfer callbacks |

```solidity
// VULNERABLE: state update after external call
function withdraw(uint amount) external {
    token.safeTransfer(msg.sender, amount);  // external call
    balances[msg.sender] -= amount;          // state update AFTER
}
```

---

#### 10.2 Access Control Missing or Wrong

**What to grep for:** `onlyOwner`, `onlyAdmin`, `require(msg.sender`, `_checkRole`, `initialize(`, `__init__`

| Pattern | Where It Hides |
|---------|---------------|
| Public `initialize()` on implementation | Proxy patterns — implementation never initialized |
| Missing modifier on state-changing function | Admin setters, emergency functions, pause/unpause |
| `initializer` modifier missing on init function | OpenZeppelin upgradeable contracts |
| Wrong address checked (`msg.sender` vs parameter) | Functions checking the wrong variable |
| `onlyOwner` on proxy but not implementation | Direct calls to implementation bypass access control |

```solidity
// VULNERABLE: no access control
function setOracle(address _oracle) external {  // missing onlyOwner
    oracle = _oracle;
}
```

---

#### 10.3 Unchecked External Call Return Values

**What to grep for:** `.transfer(`, `.send(`, `.call(`, `approve(`, `IERC20(`

| Pattern | Where It Hides |
|---------|---------------|
| `token.transfer()` without return check | USDT doesn't return bool |
| `.send()` return value ignored | ETH transfer silently fails |
| `approve()` not checked | Some tokens require `approve(0)` first |
| Low-level `.call()` success not checked | `(bool success,) = addr.call(...)` without `require(success)` |

---

#### 10.4 Oracle Misuse

**What to grep for:** `latestRoundData`, `latestAnswer`, `getPrice`, `getReserves`, `slot0`, `observe`

| Pattern | Where It Hides |
|---------|---------------|
| No staleness check on Chainlink | Missing `require(updatedAt > block.timestamp - THRESHOLD)` |
| No check for price `<= 0` | Chainlink can return 0 or negative |
| No check `answeredInRound >= roundId` | Stale round data |
| Using spot price (`slot0`) as oracle | Uniswap V3 `slot0` manipulable same-block |
| Using `getReserves()` for pricing | AMM reserves manipulable via flash loan |
| Missing L2 sequencer uptime check | Chainlink on L2 without sequencer feed validation |
| Hardcoded decimals assumption | Assuming 18 when feed returns 8 |

---

#### 10.5 Arithmetic / Precision Errors

**What to grep for:** `/`, `*`, `unchecked`, `uint128(`, `uint96(`, `uint64(`, `type(uint`, `1e18`, `PRECISION`, `WAD`, `RAY`

| Pattern | Where It Hides |
|---------|---------------|
| Division before multiplication | `(a / b) * c` loses precision — should be `(a * c) / b` |
| Rounding in wrong direction | Protocol rounds DOWN when it should round UP, or vice versa |
| Unsafe downcast | `uint128(uint256Value)` silently truncates |
| `unchecked` block with user input | Overflow / underflow possible |
| Missing zero denominator check | Division by zero when pool is empty |
| Precision loss accumulation | Tiny per-tx rounding error drainable over many txs |

```solidity
// VULNERABLE: division before multiplication
uint256 reward = (userStake / totalStake) * rewardPool;
// if userStake < totalStake → result is 0
```

**Rust-specific:**
```toml
# CRITICAL: in workspace Cargo.toml
[profile.release]
overflow-checks = false  # ALL plain += and -= wrap silently in release build
```
When `overflow-checks = false`, every plain `+=`, `-=`, `*=` on primitives wraps on overflow. Look for any u64/u128/u32 accumulator that is never bounded.

---

#### 10.6 ERC-4626 / Vault Inflation Attack (First Depositor)

**What to grep for:** `totalSupply == 0`, `totalAssets`, `convertToShares`, `deposit`, `mint`, `previewDeposit`

| Pattern | Where It Hides |
|---------|---------------|
| No virtual offset in share calculation | Empty vault allows share price manipulation |
| No minimum deposit enforcement | Attacker deposits 1 wei, donates to inflate share price |
| `totalAssets()` includes donated tokens | Direct transfer inflates total assets without minting shares |

```solidity
// VULNERABLE: classic inflation attack
function convertToShares(uint256 assets) public view returns (uint256) {
    uint256 supply = totalSupply();
    return supply == 0 ? assets : (assets * supply) / totalAssets();
    // Attack: deposit 1 wei → get 1 share → donate 1e18 → next depositor gets 0 shares
}
```

---

#### 10.7 Signature Verification Flaws

**What to grep for:** `ecrecover`, `ECDSA`, `EIP712`, `permit`, `nonce`, `deadline`

| Pattern | Where It Hides |
|---------|---------------|
| `ecrecover` returns `address(0)` not checked | Invalid sig returns zero, matches unset mapping |
| No nonce → replay | Same signature usable twice |
| No `chainId` → cross-chain replay | Sig valid on mainnet AND fork/L2 |
| No deadline/expiry | Signature valid forever |
| `abi.encodePacked` hash collision | Adjacent dynamic types create ambiguous encoding |
| Signature malleability (s-value) | Two valid signatures for same message |
| Missing contract address in domain separator | Sig valid across different contracts |

---

#### 10.8 Token Accounting Mismatches

**What to grep for:** `balanceOf`, `transfer(`, `transferFrom(`, `amount`, `_mint`, `_burn`

| Pattern | Where It Hides |
|---------|---------------|
| Fee-on-transfer not handled | Assumes received == sent amount |
| Rebasing token balance desync | `balanceOf` changes between operations |
| Missing before/after balance pattern | Not computing `balanceAfter - balanceBefore` for actual received |

```solidity
// VULNERABLE: assumes amount received equals amount sent
function deposit(uint256 amount) external {
    token.safeTransferFrom(msg.sender, address(this), amount);
    balances[msg.sender] += amount;  // wrong if fee-on-transfer token
}
```

---

### TIER 2: HIGH ($10K–$250K) — Conditional Fund Loss / Protocol Disruption

#### 10.9 Liquidation Logic Errors

**What to grep for:** `liquidat`, `healthFactor`, `collateral`, `issolvent`, `LTV`, `threshold`

| Pattern | Where It Hides |
|---------|---------------|
| Self-liquidation profit | Liquidating own position yields net gain |
| Liquidation bonus exceeds debt | Bonus allows draining more collateral than debt value |
| Positions that can't be liquidated | LTV/threshold gap makes liquidation unprofitable |
| Partial liquidation accounting error | Leftover debt/collateral miscalculated |

---

#### 10.10 Flash Loan Integration Errors

**What to grep for:** `flashLoan`, `flashMint`, `callback`, `balanceOf.*==.*before`

| Pattern | Where It Hides |
|---------|---------------|
| Balance check uses `>=` instead of `==` | Allows keeping borrowed funds if balance is inflated |
| Missing fee enforcement | Flash loan fee can be bypassed |
| Callback function externally accessible | Attacker calls callback without flash loan |
| Reward/share calculation manipulable mid-flash | Temporarily inflate TVL to claim outsized rewards |

---

#### 10.11 Proxy Storage Layout Bugs

**What to grep for:** `__gap`, `Initializable`, `upgradeTo`, `delegatecall`, `IMPLEMENTATION_SLOT`

| Pattern | Where It Hides |
|---------|---------------|
| Missing `__gap` in base contract | New variable in base clobbers derived contract storage |
| Storage slot collision | Proxy admin slot overlaps with business logic slot |
| `immutable` variables in upgradeable contract | Stored in bytecode, differ between proxy and impl |
| Constructor logic in upgradeable contract | Constructor runs on implementation, not proxy |

---

#### 10.12 Cross-Chain Message Validation (Bridges)

**What to grep for:** `_lzReceive`, `onMessage`, `executeMessage`, `srcChainId`, `trustedRemote`

| Pattern | Where It Hides |
|---------|---------------|
| No source address validation | Accepts messages from any sender on source chain |
| No source chain validation | Message from unexpected chain accepted |
| Payload decoding without length check | Malformed payload causes unexpected behavior |
| Message replay (no nonce tracking) | Same message processed twice |

```solidity
// VULNERABLE: no sender check
function _lzReceive(uint16 srcChainId, bytes memory srcAddress,
    uint64 nonce, bytes memory payload) internal override {
    // missing: require(srcAddress == trustedRemote[srcChainId])
    (address to, uint256 amount) = abi.decode(payload, (address, uint256));
    _mint(to, amount);  // anyone on source chain can mint
}
```

---

#### 10.13 Slippage / Deadline Missing

**What to grep for:** `amountOutMin`, `deadline`, `block.timestamp`, `swap(`, `exactInput`

| Pattern | Where It Hides |
|---------|---------------|
| `amountOutMin = 0` in protocol's swap calls | Protocol calls DEX with no slippage protection |
| `deadline = block.timestamp` | Passes always — provides zero protection |
| `deadline = type(uint256).max` | Never expires |
| No slippage on LP add/remove | Sandwich-attackable liquidity operations |

---

#### 10.14 Denial of Service (Permanent State Lock)

**What to grep for:** `for (`, `while (`, `.length`, `push(`, `delete`, `selfdestruct`

| Pattern | Where It Hides |
|---------|---------------|
| Unbounded array iteration | Array grows until loop exceeds gas limit |
| Failed external call blocks batch | One revert prevents all users from withdrawing |
| ETH force-sent via `selfdestruct` | Breaks `address(this).balance == expected` invariant |
| Dust deposits grow withdrawal queue | Tiny deposits make queue un-processable |
| State that can never be cleared | Mapping entries that lock funds permanently |

---

### TIER 3: MEDIUM ($1K–$50K) — Limited Impact

#### 10.15 Event / State Inconsistency

| Pattern | Where It Hides |
|---------|---------------|
| Event emitted with wrong values | Event says X, state says Y — off-chain systems desync |
| State updated but event not emitted | Indexers miss critical changes |
| Event emitted before state change | Event reflects pre-state |

---

#### 10.16 Frontrunning in Privileged Operations

| Pattern | Where It Hides |
|---------|---------------|
| `approve()` race condition | Changing allowance N→M, spender extracts N+M |
| Parameter change without delay | Admin changes fee/rate, users sandwiched |
| Auction/bid frontrunning | No commit-reveal, bids are public |

---

#### 10.17 Incorrect Interface Implementation

| Pattern | Where It Hides |
|---------|---------------|
| ERC-20 missing `returns (bool)` | Breaks composability |
| ERC-721 `safeTransferFrom` missing callback | Token sent to contract that can't receive |
| ERC-4626 `maxDeposit` returns wrong value | Integrators deposit more than allowed |

---

### SOLANA-SPECIFIC (Anchor / Native / Pinocchio)

**What to grep for:** `#[account(`, `AccountInfo`, `Signer`, `has_one`, `seeds`, `bump`, `init`, `close`, `remaining_accounts`, `wrapping_add`, `overflow-checks`

| Pattern | Tier | What to Look For |
|---------|------|-----------------|
| Missing `has_one` or constraint | Critical | Account field not validated against expected value |
| Missing signer check | Critical | `AccountInfo` used where `Signer` needed |
| Missing owner check | Critical | Account owned by System Program instead of expected program |
| Account type confusion (no discriminator) | Critical | Passing wrong account type, deserialized as valid |
| Duplicate mutable accounts | High | Same account passed twice, arithmetic double-counts |
| Close account + re-init in same tx | High | Account data persists after close within transaction |
| PDA missing user-specific seed | High | One PDA for all users → shared state corruption |
| `remaining_accounts` unchecked | High | Extra accounts passed and used without validation |
| Integer overflow in release build | High | Rust wraps when `overflow-checks = false`, no `checked_*` |
| `wrapping_add` on persistent counter | Medium–High | Explicit wrapping on a counter that accumulates across txs |
| `.expect()` / `panic!` in production | Medium | Unreachable arm panics DoS the instruction permanently |
| Missing rent exemption check | Medium | Account can be garbage collected, losing data |

---

### PROTOCOL-ARCHITECTURE-SPECIFIC (Always Investigate)

These arise from specific protocol types — always check when the target uses these patterns:

| Protocol Pattern | Key Vulnerability Classes |
|-----------------|--------------------------|
| AMM / DEX | Spot price as oracle, sandwich protection, tick math overflow, fee accumulator overflow |
| Lending | Liquidation unprofitability, oracle staleness, bad debt accumulation, self-liquidation |
| Yield aggregator | Share inflation attack, fee-on-transfer, rebasing tokens, reward draining |
| Bridge | Message replay, source validation, payload decoding, double-spend |
| Staking / Rewards | Reward front-running, epoch boundary math, precision loss accumulation |
| Perpetuals | Mark price manipulation, funding rate manipulation, position isolation |
| Options / Structured products | Payoff math errors, collateral valuation, early exercise logic |
| Governance | Flash loan governance attack, proposal front-running, timelock bypasses |

---

## 11. Auditor Quick-Reference Checklist

Run this checklist on every in-scope contract / program. Mark each item before considering audit complete.

### Universal Checks

```
[ ] Every external call — is state updated BEFORE it?
[ ] Every function — does it have correct access control?
[ ] Every initialize() — is it protected? Can it be called on implementation?
[ ] Every oracle call — staleness check? zero check? decimals? L2 sequencer?
[ ] Every division — is there multiplication before it?
[ ] Every cast (uint128, uint96, u64) — can input exceed range?
[ ] Every vault deposit/withdraw — first depositor attack possible?
[ ] Every signature — nonce, deadline, chainId, address(0) check?
[ ] Every token transfer — fee-on-transfer handled? return value checked?
[ ] Every swap — slippage > 0? deadline != block.timestamp?
[ ] Every loop — bounded? single revert blocks all users?
[ ] Every bridge message — source chain validated? sender validated?
[ ] Every proxy — storage gaps present? implementation initialized?
[ ] Every unchecked{} block — can any input cause overflow?
[ ] Every balanceOf read — can it be manipulated by donation?
[ ] Build config — overflow-checks? optimizer? solc version?
```

### Solana/Rust Additional Checks

```
[ ] Workspace Cargo.toml — overflow-checks setting?
[ ] Every u64/u128 accumulator — wrapping possible? saturating used?
[ ] Every account in instruction — owner check? signer check? has_one?
[ ] Every PDA — includes user-specific seed?
[ ] Every remaining_accounts usage — fully validated?
[ ] Every panic!/expect() — truly unreachable? production code?
[ ] Every match arm — exhaustive? panic-free for all reachable variants?
[ ] Anchor discriminator checks — present for account type validation?
```

### False Positive Elimination Gates (Phase 5)

```
[ ] NOT an astronomical precondition (requires >total supply, >100 years, >2^128 ops)
[ ] NOT admin-only trigger (requires trusted multisig/owner action)
[ ] NOT zero net profit for attacker (costs more than it extracts)
[ ] NOT a broken external dependency issue (Chainlink/Uniswap/L1 itself)
[ ] NOT a "best practice critique" (style, events, gas, code org)
[ ] NOT theoretical overflow in uint256/uint128 with realistic inputs
[ ] NOT reentrancy with existing guard (ReentrancyGuard, sentinel, tstore)
[ ] NOT vault inflation with existing mitigation (virtual offset, dead shares, min deposit)
[ ] NOT division-by-zero in unreachable empty state
[ ] NOT struct size mismatch with fixed-size padding
[ ] NOT self-griefing DoS (attacker pays own gas, no one else affected)
[ ] NOT ordering issue that's documented as intentional design
[ ] Checked ALL 10 defense verification items (access control through downstream resilience)
[ ] Passed the "Would YOU attack this?" gut check
```

### Pre-Report Gates

```
[ ] Vulnerable code path confirmed in production (not test/dev)
[ ] No existing defense blocks the attack
[ ] Passed ALL false positive elimination gates above
[ ] PoC script written and passes
[ ] Impact quantified in USD
[ ] Severity matches program's reward tier criteria
[ ] Asset and vulnerability type are in scope
[ ] Report follows IMMUNEFI-REPORT-GUIDE.md format
[ ] Immunefi submission-ready report created (IMMUNEFI-SUBMISSION-<ID>.md)
[ ] Standalone PoC file created (PoC_<ID>_<name>.sol/py/rs)
[ ] Root README updated with finding
[ ] Exploit writeup in audits/<target>/findings/exploits/
```

---

## 12. Comprehensive 280-Point Attack Vector Checklist

> **Purpose:** Adversarial security research checklist — not just code review. Every item is a distinct attack vector, edge case, or reasoning lens aimed at finding critical, high, and zero-day vulnerabilities from source code, test suites, and deployed contracts.
>
> **AI Automation Notes:**
> - Nearly all 280 items are AI-automatable through source code analysis + writing/running tests (Foundry, Hardhat, Python, Rust, etc.)
> - Items marked `[MANUAL]` require human judgment or infrastructure access beyond code review — still flag the susceptibility but note manual verification is needed
> - For each item: grep for the pattern, read relevant code, write a targeted test if suspicious
> - Items from the existing Vulnerability Catalog (Section 10) provide deeper context — cross-reference when investigating

---

### 12.1 Arithmetic & Math Logic (1–20)

| # | Checklist Item | Severity | AI Action |
|---|----------------|----------|-----------|
| 1 | **Integer Overflow (Pre-0.8):** If any contract compiles under Solidity <0.8.0 without SafeMath, audit every `+`, `-`, `*` manually | Critical | Check pragma in all `.sol` files; grep for SafeMath imports |
| 2 | **Unchecked Block Abuse:** In Solidity ≥0.8, are `unchecked {}` blocks used only for loop counters, or applied to business logic math? | High | `grep -r "unchecked" --include="*.sol"` — review every hit |
| 3 | **Precision Loss via Integer Division:** Does `a / b * c` appear anywhere? This loses precision vs `a * c / b`. E.g., `1e6 / 3 * 3 = 999999` not `1000000` | High | Grep for division-before-multiplication patterns |
| 4 | **Rounding Direction (Protocol vs User):** Deposits should round DOWN shares minted; Withdrawals should round UP shares burned. If reversed, users can drain 1 wei at a time | High | Check every `mulDiv` call direction |
| 5 | **Decimal Asymmetry in Token Pairs:** If a pool pairs USDC (6 dec) with DAI (18 dec), does the math normalize? 1 raw unit DAI ≠ 1 raw unit USDC | Critical | Grep for raw `reserve0 * reserve1` math without decimal normalization |
| 6 | **Division Before Multiplication:** `(x / y) * z` vs `(x * z) / y` — the first loses precision. In yield calculations, this diverges significantly over time | Medium | Pattern search across all math operations |
| 7 | **Accumulation Rounding Drift:** Over 1M small transactions, does a 1-wei rounding error per tx compound into a drainable amount? | Medium | Write fuzzing invariant test for cumulative rounding |
| 8 | **Type Casting Truncation:** Does `uint128(largeUint256)` silently truncate? E.g., `uint128(2**128 + 1) == 1` | High | Grep for explicit casts to smaller uint types |
| 9 | **Signed vs Unsigned Underflow:** Can an `int256` subtraction result be cast to `uint256`, wrapping to a massive number? E.g., `uint256(int256(-1)) == type(uint256).max` | High | Grep for `uint256(int` cast patterns |
| 10 | **Fixed-Point Math Libraries (WAD/RAY):** If using Compound's/Aave's fixed-point math, are WAD (1e18) and RAY (1e27) multiplications scaled down correctly after each operation? Missing a `/ 1e18` yields astronomical values | High | Trace all WAD/RAY operations for correct scaling |
| 11 | **Square Root Precision:** Uniswap V2-style `sqrt(k)` — does the integer square root implementation round down consistently, causing LP share under-issuance? | Medium | Test with boundary values near perfect squares |
| 12 | **Newton's Method Convergence:** In Stable2/Curve-style pools, does the Newton's method loop have a maximum iteration cap? Without one, it can loop forever (DoS) or oscillate between two values | High | Check `for` vs `while` in AMM invariant solving; verify max iterations |
| 13 | **Percentage Calculation Overflow:** `amount * bps / 10000` — if `amount = type(uint256).max / 10000 + 1`, the multiplication overflows. Use `mulDiv` from OpenZeppelin | Medium | Check for raw percentage math without mulDiv |
| 14 | **Block Timestamp Math:** `block.timestamp - startTime` — what happens on the first block when `block.timestamp == startTime`? Division by zero? | Medium | Trace all timestamp arithmetic for edge cases |
| 15 | **Compound Interest Approximation:** Taylor series expansion for `(1+r)^n` — does it diverge from true exponential at high interest rates or long durations? | Medium | Write test comparing approximation vs exact at extreme values |
| 16 | **Phantom Liquidity in AMM:** Can a user manipulate `k = x * y` by calling a function that adds x without adding y (asymmetric deposit), inflating the price? | High | Trace all deposit paths for balanced vs unbalanced handling |
| 17 | **Negative DeltaB/DeltaP Handling:** When a signed integer represents a deficit, is it correctly handled when converting to an unsigned swap amount? `uint256(negative_int256)` is a critical mistake | High | Grep for int-to-uint conversions in AMM/oracle code |
| 18 | **Cumulative Reward Calculation (Staking):** Does `rewardPerToken()` grow unboundedly? Can it overflow after enough time, corrupting all user rewards? | High | Calculate max growth rate over realistic timeframes |
| 19 | **Dust Amount Threshold:** Are there operations that succeed with `amount = 0`? Can looping `deposit(0)` / `withdraw(0)` manipulate counters or state? | Medium | Write test for zero-amount operations on all entry points |
| 20 | **Modulo Bias:** When using `% N` for random selection (e.g., selecting a winner), is the range evenly divisible? `type(uint256).max % 7 != 0`, causing non-uniform distribution | Low | Grep for `%` in selection/random logic |

---

### 12.2 Access Control & Permissions (21–40)

| # | Checklist Item | Severity | AI Action |
|---|----------------|----------|-----------|
| 21 | **Missing `onlyOwner` / Role Check:** Are all admin functions (`pause`, `setFee`, `upgradeTo`) protected by a role modifier? | Critical | Run Slither `--detect missing-authorization`; manually verify all state-changing externals |
| 22 | **`tx.origin` Authentication:** Does any function use `require(tx.origin == owner)` instead of `msg.sender`? Phishing contracts bypass this | Critical | `grep -r "tx.origin"` — every hit is suspicious |
| 23 | **Implicit Trust in Internal Functions:** Is any `internal` function accidentally marked `public` or `external`? | Critical | Compare intended vs actual visibility on sensitive functions |
| 24 | **Two-Step Ownership Transfer:** Is ownership transferred via a single `transferOwnership(newAddr)` call? A typo permanently locks the contract. Should be propose → accept | High | Check for OZ Ownable2Step vs single-step transfer |
| 25 | **Role Renouncing Without Replacement:** Can `DEFAULT_ADMIN_ROLE` be renounced, permanently locking the protocol? | High | Check for `renounceRole` on critical roles |
| 26 | **Centralization Risk:** Is there a single EOA (not a multisig) that can pause the protocol, drain fees, or upgrade contracts? | High | Trace admin addresses — EOA vs multisig vs timelock |
| 27 | **Timelock Bypass via "Minor" Functions:** Is a sensitive parameter change routable through a low-priority function that has no timelock? | High | Map every state-changing function and its access path |
| 28 | **Function Visibility Audit:** Are all `public` functions that should be `external` correctly marked? `external` blocks internal calls and is cheaper | Low | Automated visibility analysis |
| 29 | **Modifier Ordering:** If a function has multiple modifiers (e.g., `onlyOwner nonReentrant`), does ordering affect security? (Reentrancy guard should come first) | Medium | Check modifier order on all protected functions |
| 30 | **Conditional Admin Logic:** Does any `if (msg.sender == owner)` branch inside a function skip critical safety checks for the owner? | High | Grep for conditional admin branches that bypass checks |
| 31 | **Operator vs Owner Confusion:** Is there a distinction between "Operator" (run keeper functions) and "Owner" (change protocol parameters)? | Medium | Map all roles and their capabilities |
| 32 | **Whitelisting `address(0)`:** If `setAdmin(address(0))` is allowed, does it break `onlyAdmin` by making it always fail or always pass? | Medium | Test admin setters with zero address |
| 33 | **Callback Authorization:** When the contract makes an external call and the callee calls back, is the callback entry point properly permissioned? E.g., Uniswap V3 `uniswapV3MintCallback` | High | Trace all callback functions for caller validation |
| 34 | **Initialization Guard:** Does the `initialize()` function have an `initializer` modifier that prevents re-initialization? | Critical | Verify `initializer` on all init functions |
| 35 | **Admin Function on Logic Contract:** If a proxy is used, can someone call admin functions directly on the bare implementation contract and gain ownership? | Critical | Check `_disableInitializers()` in constructor |
| 36 | **Pause Mechanism Coverage:** Does `paused()` check cover ALL critical functions, or does it miss some entry points? | High | Map all external functions and verify pause coverage |
| 37 | **Emergency Withdraw Backdoor:** Is there an `emergencyWithdraw` that bypasses fee/lock logic? Can it be called by anyone, not just the admin? | Critical | Check access control on all emergency functions |
| 38 | **Blacklist Bypass:** If a token has a blacklist (e.g., USDC), can a blacklisted user route through the contract to move their funds? | Medium | Trace token transfer paths for blacklist bypass |
| 39 | **Self-call Privilege Escalation:** Can a contract call itself via `address(this).call(...)` to trigger a privileged code path intended only for external callers? | High | Grep for `address(this).call` patterns |
| 40 | **Inherited Function Shadowing:** Does a child contract override a parent's modifier or security function, weakening its protection? | High | Check inheritance tree for shadowed security functions |

---

### 12.3 Reentrancy & Call Flow (41–55)

| # | Checklist Item | Severity | AI Action |
|---|----------------|----------|-----------|
| 41 | **Classic Reentrancy (CEI Pattern):** Does every function follow Checks → Effects → Interactions? Is state updated BEFORE the external call? | Critical | Trace all external calls; verify state updates precede them |
| 42 | **Cross-Function Reentrancy:** Is `nonReentrant` applied to all functions sharing state? Can `withdraw()` be entered via `deposit()` through a shared lock? | Critical | Map shared state across functions; verify lock coverage |
| 43 | **Cross-Contract Reentrancy:** If Contract A calls Contract B which calls back into Contract A via a different function, is there a global reentrancy lock? | Critical | Trace cross-contract call graphs for re-entry paths |
| 44 | **Read-Only Reentrancy:** Does Contract A call a `view` function of Contract B (e.g., `getPrice()`) while Contract B is mid-execution (e.g., during a Balancer flash loan)? The view sees a temporarily wrong state | High | Identify view function dependencies during state transitions |
| 45 | **ERC-777 Reentrancy:** If the protocol accepts ERC-777 tokens, does a `tokensReceived` hook fire before balance updates? | Critical | Check if token whitelist allows ERC-777; test with mock ERC-777 |
| 46 | **`receive()` / `fallback()` Reentrancy:** Can sending ETH to the contract trigger a `receive()` that re-enters a withdrawal function? | High | Check all ETH transfer paths for re-entry |
| 47 | **Flash Loan Callback Reentrancy:** In `executeOperation()` or `uniswapV2Call()`, is the contract in a valid intermediate state when the callback fires? | High | Trace flash loan callback execution state |
| 48 | **Reentrancy in Modifiers:** Does the `nonReentrant` modifier correctly set and reset the guard, even if the function reverts mid-execution? | High | Verify guard implementation matches OZ standard |
| 49 | **Delegatecall Reentrancy:** Can a `delegatecall` target modify the reentrancy lock storage slot, bypassing the guard? | Critical | Check if delegatecall targets can write to guard slot |
| 50 | **Token Transfer Hooks:** Does an ERC-1155 `safeTransferFrom` trigger `onERC1155Received` before the sender's balance is updated? | High | Trace ERC-1155 transfer ordering |
| 51 | **Reentrancy via Price Update:** Can a user trigger an oracle price update mid-execution that changes the outcome of a pending liquidation or swap? | High | Trace oracle update timing relative to liquidation flow |
| 52 | **Multi-Entry Point Reentrancy (Diamond):** In a Diamond proxy, if FacetA and FacetB both modify the same storage, is there a cross-facet reentrancy guard? | Critical | Map shared storage across facets; verify global lock |
| 53 | **ETH Refund Reentrancy:** If a function refunds excess ETH via `.call{value:}("")`, is the balance updated before the refund is sent? | Critical | Trace all ETH refund paths for CEI compliance |
| 54 | **`permit()` Reentrancy:** Can a malicious token's `permit()` function re-enter the protocol during a `depositWithPermit()` call? | High | Trace permit call ordering in deposit-with-permit flows |
| 55 | **Tractor/Blueprint Reentrancy:** Does the Tractor mechanism's `delegatecall` with a temporary reentrancy unlock allow re-entry into protected functions through the unlock window? | Critical | Trace Tractor unlock window for re-entry opportunities |

---

### 12.4 Oracle & Price Feed Security (56–75)

| # | Checklist Item | Severity | AI Action |
|---|----------------|----------|-----------|
| 56 | **Spot Price as Oracle:** Does ANY critical function use `getReserves()`, `balanceOf(pool)`, or spot price instead of a TWAP? This is always manipulable with a flash loan | Critical | Grep for `getReserves`, `balanceOf(pool)`, `slot0` in pricing logic |
| 57 | **Chainlink Heartbeat Check:** Is `updatedAt` compared to `block.timestamp`? If the feed hasn't updated in >2x the heartbeat interval, the price is stale | High | Verify `require(block.timestamp - updatedAt < MAX_DELAY)` exists |
| 58 | **Chainlink `minAnswer` / `maxAnswer` Circuit Breaker:** If the asset price crashes below `minAnswer` (e.g., $0.10), Chainlink still returns `minAnswer`. Does the protocol detect and reject this? | Critical | Check for min/max answer validation after Chainlink calls |
| 59 | **L2 Sequencer Uptime Feed:** On Arbitrum/Optimism/Base, if the sequencer goes offline, prices are stale. Is the Sequencer Uptime Feed checked before any oracle read? | High | Grep for sequencer uptime check on L2 deployments |
| 60 | **TWAP Window Too Short:** Is the TWAP window less than 30 minutes? A 5-minute TWAP can be manipulated by a well-capitalized attacker across multiple blocks | High | Check TWAP configuration parameters |
| 61 | **Multi-Block TWAP Manipulation:** Can an attacker control the last transaction of block N and the first of block N+1 to "steer" a TWAP reading in a specific direction? | High | Analyze TWAP window vs block time ratio |
| 62 | **Oracle Data Freshness (Slot-Based, Solana):** Does `current_slot - price.slot > ACCEPTABLE_STALENESS`? On Solana, time is measured in slots, not seconds | High | Check staleness in slot units for Solana oracles |
| 63 | **Pyth "Pull" Oracle Fee Griefing:** Can an attacker call the protocol without paying the Pyth update fee, forcing it to use a stale cached price? | Medium | Trace Pyth update fee handling in protocol calls |
| 64 | **Composite Oracle Manipulation:** If the protocol uses `Price_A * Price_B / Price_C`, can manipulating one leg distort the composite price significantly? | High | Test composite oracle with extreme single-leg values |
| 65 | **Oracle Rounding Direction:** Does the oracle round DOWN the collateral price and round UP the debt price? If reversed, users can borrow more than their collateral is worth | High | Check rounding in all oracle price consumption |
| 66 | **Single Oracle Dependency:** Is there only one oracle source? What happens if the Chainlink node operator is compromised or the feed goes offline? | Medium | Map all oracle dependencies; check for fallback |
| 67 | **Oracle Return Value Validation:** Is `answer > 0` checked after calling Chainlink? A negative or zero answer causes incorrect downstream behavior | High | Verify positive price assertion after every oracle call |
| 68 | **DEX Pool as Oracle Bypass:** Can an attacker use a low-liquidity pool as the oracle source even when a high-liquidity pool exists and should be preferred? | Critical | Check oracle pool selection logic for manipulation |
| 69 | **Sandwich-able Oracle Update:** Can a user front-run an oracle price update to take a favorable position, then back-run to close it profitably? | High | Write Foundry test simulating sandwich around oracle update |
| 70 | **EMA vs TWAP Oracle Confusion:** Does any code path accidentally use the EMA reserve instead of the TWAP reserve in a context where the other is required? | High | Trace every oracle read to verify EMA vs TWAP usage |
| 71 | **Oracle Decimals Mismatch:** Does the protocol assume all Chainlink feeds return 8 decimals? ETH/USD returns 8, but some feeds return 18. Always check `feed.decimals()` | High | Verify `decimals()` is called and used for normalization |
| 72 | **Zero Oracle Price Handling:** If `getPrice()` returns 0 (new token with no feed), does the protocol divide by zero or allow infinite-value collateral? | Critical | Test all oracle consumers with price = 0 |
| 73 | **Oracle Manipulation During Upgrade:** During a proxy upgrade, can the oracle be temporarily manipulated because the new implementation reads from a different storage slot? | High | Check storage layout consistency across upgrades for oracle slots |
| 74 | **Price Impact Not Accounted For:** For large liquidations, does the protocol assume the oracle price is achievable, ignoring the market impact of selling a massive position? | Medium | Check liquidation size limits and price impact modeling |
| 75 | **Off-Chain Signed Price (API3/Pyth):** Is the signer's address checked against a known on-chain allowlist? Can an attacker forge a signed price message if the validation is weak? | Critical | Verify signer validation in off-chain oracle integrations |

---

### 12.5 ERC Token Standard Edge Cases (76–95)

| # | Checklist Item | Severity | AI Action |
|---|----------------|----------|-----------|
| 76 | **Non-Standard `transfer()` Return Value:** USDT's `transfer()` returns `void`, not `bool`. Using `require(token.transfer(...))` reverts on USDT | Critical | Verify SafeERC20 usage everywhere; grep for raw `transfer(` |
| 77 | **Fee-on-Transfer Token Accounting:** Tokens like PAXG take a fee on transfer. Does the vault record the amount sent or the amount actually received? | High | Check for `balanceAfter - balanceBefore` pattern |
| 78 | **Rebasing Token Balance Desync:** stETH, aTokens, and ampleforth rebase. An internal `balances[user]` ledger will desync from actual `token.balanceOf(address(this))` | High | Check if internal accounting handles rebasing tokens |
| 79 | **ERC-777 `tokensReceived` Hook:** Can an ERC-777 token's receive hook re-enter the protocol during a transfer? | Critical | Check token whitelist; test with ERC-777 mock |
| 80 | **ERC-1155 `safeBatchTransferFrom` Hook:** Can `onERC1155BatchReceived` re-enter the protocol before state is finalized? | High | Trace ERC-1155 batch transfer state ordering |
| 81 | **Approve Race Condition:** Does the protocol use `approve(spender, newAmount)` directly instead of `safeIncreaseAllowance` / `safeDecreaseAllowance`? | Medium | Grep for raw `approve(` calls |
| 82 | **Zero-Value Transfer Revert:** Some tokens (e.g., old LEND) revert on `transfer(address, 0)`. Does the code guard against zero amounts before transferring? | Medium | Check for zero-amount guards before transfers |
| 83 | **Self-Transfer:** What happens when `token.transfer(address(this), amount)` is called? Does it double-count the internal balance? | High | Test self-transfer scenarios on vault/pool contracts |
| 84 | **Blacklistable Token (USDC/USDT):** If a user gets blacklisted by USDC after depositing, their funds are permanently locked. Is there an emergency recovery mechanism? | Medium | Check for emergency withdrawal paths for blacklisted users |
| 85 | **Pausable Token:** If the deposited token can be paused by its issuer (e.g., USDC), can it lock ALL protocol withdrawals simultaneously? | High | Check if protocol handles token-level pause gracefully |
| 86 | **Token Upgrade by Issuer:** If USDC upgrades its proxy contract, does the protocol still reference the correct proxy address? | Medium | Verify protocol uses proxy address, not implementation |
| 87 | **NFT (ERC-721) Safe Transfer Hook:** Does `safeTransferFrom` trigger `onERC721Received` before the protocol updates state, enabling reentrancy? | High | Trace ERC-721 safe transfer for CEI compliance |
| 88 | **ERC-2612 `permit()` Replay:** Is the `permit()` nonce checked on-chain to prevent replaying a signed approval? | High | Verify nonce increment in permit implementation |
| 89 | **Token With Multiple Entry Points:** Some tokens (like older DAI) have multiple addresses mapping to the same balance. Does the protocol's whitelist cover all entry points? | Medium | Check token address handling for multi-entry tokens |
| 90 | **Deflationary Token in AMM:** A deflationary token (burns 1% on transfer) will cause the pool's actual balance to diverge from its tracked internal reserves over time | High | Check AMM reserve tracking for deflationary token drift |
| 91 | **Token Freeze/Seizure:** USDT/USDC issuers can freeze individual accounts. Could this freeze the protocol's treasury or core vault? | Medium | Assess impact of token-level freeze on protocol addresses |
| 92 | **ERC-20 `decimals()` Not Guaranteed:** The `decimals()` function is optional in the ERC-20 standard. Does the code assume it always exists? | Low | Check for try/catch or fallback on `decimals()` calls |
| 93 | **Token Max Supply Inflation:** Can minting additional tokens by the token's owner cause the protocol's accounting to overflow its internal counters? | Medium | Check if internal counters can handle max supply scenarios |
| 94 | **Token Metadata Spoofing:** Does the protocol use `name()` or `symbol()` return values in any on-chain logic? These can be spoofed by a malicious token | Low | Grep for `name()` or `symbol()` in business logic |
| 95 | **Wrapped Native Token (WETH) Unwrapping:** Does the protocol correctly handle cases where WETH is unwrapped to ETH, and the recipient is a contract with a reverting `receive()`? | High | Test WETH unwrap to contract without receive/fallback |

---

### 12.6 Vault / ERC-4626 Accounting (96–110)

| # | Checklist Item | Severity | AI Action |
|---|----------------|----------|-----------|
| 96 | **ERC-4626 Inflation Attack:** First depositor deposits 1 wei, then donates 1e18 assets directly. `pricePerShare` inflates, rounding subsequent depositors to 0 shares | Critical | Check for virtual shares/assets offset; write first-depositor test |
| 97 | **Virtual Shares Implementation:** Does the vault add `1e8` virtual shares and `1e8` virtual assets in `totalSupply` and `totalAssets` to prevent the inflation attack? | High | Verify virtual offset in share calculation functions |
| 98 | **`convertToShares` vs `previewDeposit` Divergence:** Do these two functions return different values? If so, the difference can be arbitraged by MEV bots | Medium | Compare outputs of both functions with same inputs |
| 99 | **`maxWithdraw` Accuracy:** Does `maxWithdraw(user)` account for liquidity constraints, fees, and lock periods? If it overstates, `withdraw(maxWithdraw(user))` will revert | Medium | Test `withdraw(maxWithdraw(user))` for all user states |
| 100 | **Fee-on-Deposit/Withdrawal Rounding Consistency:** If a 0.1% fee is charged, is the fee rounding direction consistent with the share issuance rounding direction? | High | Test fee + share rounding interaction at small amounts |
| 101 | **Vault `totalAssets` Manipulation:** Can an attacker send tokens directly to the vault (not via `deposit`) to inflate `totalAssets` and steal yield from other depositors? | High | Test direct token transfer impact on share price |
| 102 | **Locked Assets After Withdrawal Queue Drain:** If a withdrawal queue exists, can one user drain it entirely, blocking others from withdrawing? | High | Test withdrawal queue exhaustion scenarios |
| 103 | **Reentrancy in `deposit()` / `withdraw()`:** Does `deposit()` call an external hook before updating `balances[msg.sender]`? | Critical | Trace deposit/withdraw for external calls before state updates |
| 104 | **Strategy Harvest MEV:** Can a keeper bot front-run a `harvest()` call to deposit just before `pricePerShare` increases, then immediately withdraw? | High | Write Foundry test simulating harvest sandwich |
| 105 | **Yield Stripping Attack:** Can a user deposit just before a large yield distribution and withdraw immediately after, capturing yield they did not earn? | High | Test deposit-before-yield-withdraw-after pattern |
| 106 | **Loss Socialization:** If a strategy incurs a loss, is it correctly socialized across ALL depositors proportionally? Or can early withdrawers escape while the loss is borne by the last users? | High | Test withdrawal ordering after strategy loss |
| 107 | **`previewRedeem` Slippage Bound:** Does the actual `redeem()` return less than `previewRedeem()` predicted, and is this difference bounded by a contract-level tolerance? | Medium | Compare previewRedeem vs actual redeem outputs |
| 108 | **Multi-Vault Circular Deposit:** If Vault A deposits into Vault B which deposits back into Vault A, can this circular path create shares without real underlying assets? | Critical | Map vault-to-vault deposit chains for cycles |
| 109 | **Slippage on Strategy Rebalance:** When the vault rebalances between strategies, is there slippage protection on the underlying DEX swaps? | High | Check rebalance swap calls for minAmountOut > 0 |
| 110 | **Dead Shares Accounting:** If a user burns shares to `address(0)`, does `totalSupply()` still count them, causing permanent vault inflation? | Medium | Test share burn to zero address impact on accounting |

---

### 12.7 Proxy & Upgradeability (111–125)

| # | Checklist Item | Severity | AI Action |
|---|----------------|----------|-----------|
| 111 | **Storage Slot Collision (Proxy):** Does the proxy's internal variables (e.g., `_implementation`, `_admin`) collide with the logic contract's storage slot 0, 1, or 2? | Critical | Verify EIP-1967 standard slots; check for non-standard proxy patterns |
| 112 | **Uninitialized Implementation Contract:** Can an attacker call `initialize()` on the bare logic contract and gain admin rights over the template? | Critical | Check `_disableInitializers()` in implementation constructor |
| 113 | **`selfdestruct` in Logic Contract:** Can anyone trigger `selfdestruct` on the implementation, bricking all proxies pointing to it? | Critical | Grep for `selfdestruct` / `SELFDESTRUCT` in implementation |
| 114 | **UUPS `_authorizeUpgrade` Missing:** In a UUPS proxy, if `_authorizeUpgrade` is not overridden or is empty, anyone can upgrade the contract to arbitrary code | Critical | Verify `_authorizeUpgrade` has access control |
| 115 | **Transparent Proxy Admin Collision:** Can the proxy admin accidentally trigger user-facing functions? The Transparent proxy pattern prevents this; verify it is correctly implemented | High | Verify transparent proxy routing logic |
| 116 | **Delegatecall to Attacker-Controlled Address:** If the implementation address is settable by a low-privilege role, can an attacker point it to a malicious contract? | Critical | Check implementation setter access control |
| 117 | **Re-initialization Attack:** After an upgrade, if the new implementation has a different `initialize()`, can it be called again to overwrite critical state variables? | Critical | Check `reinitializer(version)` for each upgrade |
| 118 | **Function Signature Change Across Upgrade:** If a function's parameter types change in v2, does the proxy ABI still route old calldata to the new implementation incorrectly? | High | Compare function selectors across implementation versions |
| 119 | **Storage Layout Append-Only Rule:** Does the upgrade add new state variables at the END of the storage layout, or does it insert them in the middle, corrupting existing data? | Critical | Verify storage layout ordering across versions |
| 120 | **Beacon Proxy Central Point of Failure:** Is a Beacon proxy used? If the Beacon's `upgradeTo()` is compromised, ALL contracts pointing to it are exploited simultaneously | Critical | Check Beacon upgrade access control and scope |
| 121 | **`fallback()` Selector Collision:** Does the proxy's `fallback()` forward all calls? If a function selector in the proxy itself matches one in the implementation, the proxy's version silently takes priority | High | Check for selector collisions between proxy and implementation |
| 122 | **Event Emission on Upgrade:** Is an `Upgraded(newImplementation)` event emitted for off-chain monitoring? Without it, a silent upgrade can go undetected | Low | Verify upgrade event emission |
| 123 | **Timelock on Upgrade:** Is there a 24-48 hour timelock before an upgrade takes effect, giving users time to exit before a potentially malicious change? | High | Check upgrade path for timelock enforcement |
| 124 | **Upgrade Introduces New External Calls:** Does the new implementation call a new external contract? Was that new external contract independently audited? | High | Map new external dependencies in upgraded code |
| 125 | **`delegatecall` Return Value:** Is the return value of a raw `delegatecall` always checked? A failed delegatecall that is silently ignored is a critical hidden failure | Critical | Grep for raw `delegatecall` and verify return check |

---

### 12.8 Diamond Architecture EIP-2535 (126–135)

| # | Checklist Item | Severity | AI Action |
|---|----------------|----------|-----------|
| 126 | **Function Selector Collision:** Does adding a new Facet introduce a function whose 4-byte selector matches an existing admin or critical function? Maintain a selector registry | Critical | Compute all selectors across facets; check for collisions |
| 127 | **AppStorage Slot Isolation:** Do all Facets read/write AppStorage via a fixed `keccak256`-based slot, or do some use sequential slot 0, 1, 2 (which can collide with proxy metadata)? | Critical | Verify consistent AppStorage slot derivation across all facets |
| 128 | **Library Storage Overlap:** Does a Solidity library used by a Facet define its own storage slot that overlaps with the AppStorage struct? | Critical | Map all library storage slots against AppStorage |
| 129 | **Facet Cut Authorization:** Is `diamondCut()` protected by a strict role check AND a timelock? A malicious cut can replace all facets with attacker code | Critical | Verify diamondCut access control and timelock |
| 130 | **Facet Removal Leaves Dead References:** If a Facet is removed, does any other Facet still internally reference its functions via a hardcoded interface call? | High | Trace cross-facet calls; check if removed facets break callers |
| 131 | **Cross-Facet Reentrancy:** Does Facet A call Facet B via an external call (triggering a new re-entry point) rather than a direct internal library call? | High | Map facet-to-facet calls; verify global reentrancy lock |
| 132 | **Loupe Functions Accuracy:** Do the `facets()` and `facetFunctionSelectors()` functions accurately reflect the current state? If cached off-chain, a mismatch can hide backdoors | Medium | Verify loupe output matches actual facet registration |
| 133 | **Initialization Facet Logic:** When `diamondCut` is called with an `init` calldata, does the initialization function itself require the caller to be an authorized role? | High | Trace diamondCut init calldata for auth checks |
| 134 | **Storage Migration During Cut:** If a Facet upgrade changes a struct's field order, does the on-chain stored data get corrupted for all existing users? | Critical | Verify struct layout compatibility across facet versions |
| 135 | **Multiple Inheritance in Facets:** If Facets inherit from shared base contracts, do the base contracts introduce duplicate storage slot definitions? | High | Map inheritance trees for storage slot duplication |

---

### 12.9 Flash Loan & MEV Attack Surface (136–150)

| # | Checklist Item | Severity | AI Action |
|---|----------------|----------|-----------|
| 136 | **Flash Loan Price Manipulation:** Can a flash loan inflate/deflate a pool's spot price to trigger a liquidation or manipulate an oracle reading? | Critical | Write Foundry test: flash loan → manipulate pool → trigger action |
| 137 | **Flash Loan Governance Attack:** Can flash-borrowed tokens be used to acquire voting power and pass a malicious proposal in a single block? | Critical | Check for snapshot-based voting with time delay |
| 138 | **Zero-Slippage Swap MEV:** Does any internal swap use `minAmountOut = 0`? This is a guaranteed sandwich target for MEV bots | High | Grep for `minAmountOut = 0`, `amountOutMin = 0`, `0,` in swap calls |
| 139 | **Permissionless Keeper Sandwiching:** Is there a permissionless `sunrise()`, `rebalance()`, or `harvest()` function that triggers swaps? MEV bots will sandwich these every time | High | Identify all permissionless functions that trigger swaps |
| 140 | **Flash Loan Reentrancy via ERC-3156:** Does the `flashLoan` callback allow re-entering deposit/withdraw functions before the loan is repaid? | Critical | Trace flash loan callback for re-entry to state-changing functions |
| 141 | **Multi-Block MEV via Sequencer Control:** On Arbitrum (single sequencer), can a bot pay for priority to front-run a large user transaction across consecutive blocks? | High | `[MANUAL]` Identify susceptible tx patterns; flag for sequencer MEV risk |
| 142 | **JIT Liquidity Attack (Uniswap V3):** Can a MEV bot provide concentrated liquidity just before a large swap and remove it immediately after, capturing the fee without price risk? | Medium | Check concentrated liquidity integration for JIT susceptibility |
| 143 | **Liquidation Front-Running:** Can a bot front-run a borrower's "Repay" transaction to force the borrower into liquidation and earn the liquidation bonus at the borrower's expense? | High | Analyze liquidation timing and mempool visibility |
| 144 | **Transaction Ordering Dependency:** For protocols that rely on a specific transaction order for security (e.g., oracle updates before liquidations), is this ordering enforced on-chain? | High | Check for on-chain ordering enforcement vs off-chain assumptions |
| 145 | **Commit-Reveal Front-Running:** If a protocol uses a commit-reveal scheme, can a validator or sequencer see the "Reveal" before it is included and act on it? | High | Check commit-reveal for sequencer/validator visibility |
| 146 | **Sandwich on Stablecoin Depeg:** During a depeg event, can a MEV bot sandwich the protocol's automated de-risking transactions? | High | Identify automated de-risk swaps; check slippage protection |
| 147 | **Flash Loan Dust Attack:** Can a tiny flash loan be used to "initialize" a state (e.g., create a price tick, touch a storage slot) that is exploitable by a larger subsequent transaction? | Medium | Test flash loan with minimal amounts for state initialization |
| 148 | **Back-Running Reward Harvest:** Can a user detect a pending `claimRewards()` in the mempool and back-run it to maximize their share of an end-of-epoch distribution? | Medium | Check reward distribution for mempool-visible timing exploitation |
| 149 | **Atomic Arbitrage Between Integrated Protocols:** If Protocol A integrates with Protocol B, can a bot atomically arbitrage a price discrepancy between them in a way that drains Protocol A? | High | Map cross-protocol price dependencies; test arbitrage paths |
| 150 | **Flash Loan to Bypass Time Locks:** Can a flash loan be used to temporarily meet a collateral threshold, execute a governance action, and repay within the same block? | High | Check governance/collateral thresholds for same-block bypass |

---

### 12.10 Governance & DAO Logic (151–160)

| # | Checklist Item | Severity | AI Action |
|---|----------------|----------|-----------|
| 151 | **Governance Flash-Mint / Flash-Borrow:** Can governance tokens be flash-borrowed to instantly acquire a majority vote and pass a malicious proposal? | Critical | Check for snapshot-based voting; test flash-borrow governance attack |
| 152 | **Proposal Spam Attack:** Can an attacker create thousands of proposals to hide a malicious one among them, causing proposal ID confusion in off-chain tooling? | High | Check proposal creation limits and thresholds |
| 153 | **Vote Buying via On-Chain Callback:** Can a voter be bribed with on-chain tokens within the same `castVote()` transaction via a callback? | High | Trace castVote for external calls/callbacks |
| 154 | **Quorum Manipulation:** If quorum is based on `totalSupply`, can a large token burn right before a vote lower the quorum threshold to make a low-participation vote pass? | High | Check quorum calculation source (totalSupply vs snapshot) |
| 155 | **Timelock Minimum Delay:** Is the minimum delay enforced in the Timelock contract itself, or only in the UI? An attacker with executor access can bypass a UI-only soft delay | High | Verify on-chain timelock minimum delay enforcement |
| 156 | **Timelock Queue Cancellation:** Who can cancel a queued proposal? If only the proposer can cancel, they can be DOSed. If anyone can cancel, governance can be griefed | Medium | Check cancel authorization logic |
| 157 | **Parameter Range Validation:** Does the governance system validate that new parameters (e.g., a fee of 10000 BPS = 100%) are within safe bounds before executing the proposal? | High | Check governance-settable parameters for range validation |
| 158 | **Multi-sig Threshold Fatigue:** Can legitimate multi-sig signers be overwhelmed with spam pending transactions, causing them to miss signing a critical real one? | Medium | `[MANUAL]` Check multi-sig transaction limits; flag if no spam protection |
| 159 | **Cross-Chain Governance Relay:** If a governance message is relayed cross-chain, can it be replayed on the destination chain? Is there a per-message nullifier? | Critical | Check cross-chain governance for replay protection |
| 160 | **Voting Power Snapshot Manipulation:** Can a user transfer tokens just before the snapshot block to an address that already voted, then vote again with the same tokens? | High | Verify snapshot timing prevents double-voting |

---

### 12.11 DeFi Protocol-Specific Logic (161–175)

| # | Checklist Item | Severity | AI Action |
|---|----------------|----------|-----------|
| 161 | **Bad Debt Socialization:** In a lending protocol, if a borrower's collateral goes to zero (bad debt), who bears the loss? Is it properly accounted for in the accounting system? | Critical | Trace bad debt handling; test with underwater positions |
| 162 | **Liquidation Incentive Too High:** If the liquidation bonus is >10%, it can create a "death spiral" where large liquidations drive the collateral price further down | High | Check liquidation bonus configuration and caps |
| 163 | **Liquidation Incentive Too Low:** If the liquidation bonus is 0%, liquidators have no economic incentive to liquidate, leaving bad debt to accumulate silently | High | Check minimum liquidation incentive |
| 164 | **Interest Accrual Before Liquidation Check:** Is interest accrued (`accrueInterest()`) called before checking if a position is liquidatable? Stale interest can make a position appear healthy when it is not | High | Trace liquidation flow for interest accrual ordering |
| 165 | **Borrow Cap Not Enforced Atomically:** Is the borrow cap checked per transaction, or cumulatively? Can parallel transactions in the same block bypass a per-tx cap? | High | Test concurrent borrows against cap |
| 166 | **LP Token as Collateral Price Manipulation:** If LP tokens are used as collateral, is their price calculated using the geometric mean (manipulation-resistant) or raw spot reserves? | Critical | Check LP token pricing formula for flash-loan resistance |
| 167 | **Reward Distribution Rounding:** In a staking contract, does `rewardPerTokenStored` accumulate rounding errors that allow the last user to claim slightly more than their fair share? | Medium | Write invariant test: sum(claimed) <= totalRewards |
| 168 | **Perpetual Funding Rate Manipulation:** Can a trader manipulate the funding rate in a perps protocol to extract guaranteed payments from the opposing side over many blocks? | High | Analyze funding rate formula for manipulation vectors |
| 169 | **AMM K-Value Drift:** After a fee collection event, does the AMM's `k = x * y` invariant decrease slightly? Over millions of swaps, does this cause the "real k" to drift from the expected k? | Medium | Write test tracking k-value across many fee-collecting swaps |
| 170 | **Price Impact Not Modeled:** For protocols that buy/sell large positions automatically, does the code assume zero price impact? Large automated orders can move the market significantly | High | Check automated swap sizes against pool liquidity |
| 171 | **Insurance Fund Depletion:** Can an attacker craft a series of trades that deplete the insurance fund, after which the protocol has no backstop for any subsequent bad debt? | Critical | Test insurance fund depletion scenarios |
| 172 | **Order Book Front-Running (On-Chain):** For on-chain order books, can limit orders be front-run by traders who see them in the public mempool before they are included? | High | Check on-chain order book for mempool visibility |
| 173 | **Yield Aggregator Re-Entrancy via Strategy:** If an aggregator calls a strategy's `deposit()` which calls an external pool, can the external pool's callback re-enter the aggregator before it finalizes state? | Critical | Trace aggregator → strategy → external pool → callback chain |
| 174 | **Cross-Protocol Circular Debt:** Can Protocol A use Protocol B's token as collateral, while Protocol B uses Protocol A's token as collateral, creating a circular dependency that unwinds catastrophically? | Critical | Map collateral dependencies for circular references |
| 175 | **Unstake During Lock Period:** Is there any code path (e.g., an "emergency exit") that allows unstaking during a lock period, bypassing the intended lock? | High | Test all unstake/withdraw paths during active lock |

---

### 12.12 Solana / SVM Account Integrity (176–195)

| # | Checklist Item | Severity | AI Action |
|---|----------------|----------|-----------|
| 176 | **Missing Account Discriminator (Non-Anchor):** In raw Rust programs, does every account type start with a unique 8-byte identifier? Without it, a `StakeAccount` can be passed as a `UserAccount` | Critical | Check all account deserialization for discriminator validation |
| 177 | **Missing `account.owner == program_id` Check:** Is every account verified to be owned by the correct program? An attacker can create an account with identical data owned by a malicious program | Critical | Verify owner checks on all accounts in every instruction |
| 178 | **Missing `is_signer` Check:** Is the `is_signer` flag verified for all authority accounts? Solana allows passing any account; unsigned accounts can control funds if this check is missing | Critical | Check signer validation on all authority/payer accounts |
| 179 | **Missing `is_writable` Check:** Is `is_writable` verified for accounts that must be mutated? Passing a read-only account where a writable one is expected causes silent partial failures | High | Verify writable constraints on all mutated accounts |
| 180 | **PDA Seed Collision:** Are PDA seeds globally unique? Can two different users generate the same PDA by using the same seed structure? | High | Analyze PDA seed construction for uniqueness guarantees |
| 181 | **Canonical Bump Not Enforced:** Does the program accept any valid PDA bump, or does it enforce the canonical (highest) bump? Non-canonical bumps allow multiple valid PDAs for the same seeds | High | Check bump validation (canonical vs any) |
| 182 | **Account Data Deserialization Confusion:** If two account types have the same byte layout but different discriminators, does the deserializer correctly reject the wrong type? | Critical | Test deserialization with wrong account type |
| 183 | **Missing Rent-Exempt Check:** If an account's lamport balance drops below the rent-exempt threshold, the Solana runtime can garbage-collect it, permanently locking the program | High | Check rent exemption enforcement on critical accounts |
| 184 | **Account Reloading After CPI:** If Program A calls Program B via CPI, and Program B modifies an account that Program A also holds a reference to, does Program A reload the account data after the CPI returns? | High | Trace CPI calls for stale account data usage |
| 185 | **`realloc` Lamport Check:** When using `realloc` to expand account data, are the additional lamports for rent deposited first? If not, the account becomes non-rent-exempt and may be deleted | High | Check realloc paths for rent lamport handling |
| 186 | **Account Initialization Timing:** Can an attacker create an account with all zeros before the program initializes it, causing the program's "is initialized?" check to skip actual initialization? | High | Test pre-creation attack on account initialization |
| 187 | **System Program Account Confusion:** Can an account owned by the System Program (uninitialized, all zeros) be passed as a program-owned account and pass data checks if the expected data is also zeros? | Critical | Test zero-data account confusion scenarios |
| 188 | **Token Account Owner Check:** Is the `authority` field of a Token account verified against the expected user before allowing any transfer from it? | Critical | Verify authority validation on all token account operations |
| 189 | **Mint Account Confusion:** Can a different SPL Mint account be passed in place of the expected one, causing the program to mint or burn the wrong token? | Critical | Check mint account validation in all token operations |
| 190 | **Associated Token Account (ATA) Not Required:** Does the program allow non-ATA token accounts? Non-ATAs can have unusual authority configurations that introduce edge cases | Medium | Check if program enforces ATA usage |
| 191 | **Versioned Transaction / ALT Manipulation:** Does the program handle Address Lookup Tables correctly? Can an ALT entry be manipulated to swap in a malicious account after the instruction is signed by the user? | Critical | Analyze ALT usage for post-sign manipulation |
| 192 | **Account Closed Mid-Instruction:** Can an account be closed (lamports set to 0) during a CPI call, and then the outer instruction still attempt to write to it? | Critical | Test account closure during CPI for use-after-close |
| 193 | **Duplicate Account in Instruction:** What happens if the same account is passed twice in an instruction (e.g., `source` and `destination` are the same token account)? Does the program handle this safely? | High | Test duplicate account passing on all instructions |
| 194 | **`remaining_accounts` Validation:** Does the program iterate over `remaining_accounts` without validating their types, owners, or whether they are signers? | High | Audit all remaining_accounts usage for validation |
| 195 | **Compute Budget Exhaustion Griefing:** Can a malicious instruction be crafted to consume the maximum compute units, causing co-transactions in the same bundle to fail due to budget exhaustion? | Medium | Estimate worst-case CU consumption for each instruction |

---

### 12.13–12.20 Remaining Sections (196–280)

> **TODO:** The following sections need to be added when provided:
>
> | Section | Items | Topic |
> |---------|-------|-------|
> | 13 | 196–210 | Solana CPI & Runtime Security |
> | 14 | 211–215 | Cross-Chain & Bridge Security |
> | 15 | 216–225 | Gas, DoS & Griefing |
> | 16 | 226–235 | Signature & Cryptography |
> | 17 | 236–243 | Assembly & Low-Level EVM |
> | 18 | 244–258 | Supply Chain & Infrastructure |
> | 19 | 259–270 | Economic Game Theory & Zero-Day Scenarios |
> | 20 | 271–280 | Testing & Tooling Strategy |
>
> Provide these sections to complete the full 280-point checklist.

---

### Checklist Usage Guide

**How to use this checklist during an audit:**

1. **Scope Filter:** Skip entire sections that don't apply (e.g., skip Solana sections 12–13 for EVM-only targets, skip Diamond section 8 for non-Diamond protocols)
2. **Automated Grep Pass:** For each item with a grep pattern, run the search across all in-scope files first
3. **Targeted Test Writing:** For each suspicious hit, write a focused Foundry/Python/Rust test
4. **Cross-Reference:** Items often combine — e.g., oracle manipulation (#56) + flash loan (#136) + zero slippage (#138) form a complete attack chain
5. **Severity Context:** Adjust severity based on the specific protocol — a Medium in a lending protocol may be Critical in a bridge
6. **False Positive Gate:** Every finding from this checklist MUST still pass Phase 5 (False Positive Elimination) before reporting

---

*Last updated: 2026-03-02 (v3 — added 280-point comprehensive attack vector checklist, sections 1-12)*
*Cross-references: [IMMUNEFI-REPORT-GUIDE.md](IMMUNEFI-REPORT-GUIDE.md) | [all_programs.txt](all_programs.txt) | [audits/](audits/)*
