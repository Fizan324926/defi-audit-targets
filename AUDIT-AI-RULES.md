# AI Audit Rules & Methodology

Authoritative rulebook for conducting smart contract and protocol security audits for Immunefi bug bounties. Every rule here is a standing instruction — follow it without re-prompting.

**Cross-references:**
- Reporting format → [`IMMUNEFI-REPORT-GUIDE.md`](IMMUNEFI-REPORT-GUIDE.md)
- Real-world exploit patterns → [`EXPLOIT-REFERENCE.md`](EXPLOIT-REFERENCE.md) **(READ THIS FIRST — 12 zero-day patterns from $77B+ in losses)**
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
10. [Vulnerability Catalog](#10-vulnerability-catalog) *(incl. Solana-specific, Python/VM Sandbox-specific)*
11. [Auditor Quick-Reference Checklist](#11-auditor-quick-reference-checklist)

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

**BEFORE starting analysis, read [`EXPLOIT-REFERENCE.md`](EXPLOIT-REFERENCE.md)** for 12 zero-day patterns extracted from $77B+ in real losses. Pattern-match every code structure against these known attack templates. Key patterns to apply:
- Pattern 1 (Oracle Inconsistency): Every price feed, every adapter, every multiplier/scaling field
- Pattern 2 (Missing Health Check): Every function that changes collateral/debt without post-check
- Pattern 10 (Cross-Protocol Shadow): Every CPI/external call where combined state creates new invariants
- Pattern 11 (Permissionless Crank): Every instruction accepting external data — who can submit, what can they choose?
- Pattern 12 (Corporate Action Window): Every RWA/tokenized asset with transition/suspension logic

Analyze every component from these nine angles (original 6 + 3 new critical angles). Findings emerge from applying multiple angles simultaneously.

### 4.1 Single-File Analysis

For each file in isolation:
- What invariants does this file enforce?
- What are the preconditions and postconditions of each function?
- Are there any integer operations that could overflow/underflow?
- Are there any unchecked calls whose failure would corrupt state?
- Are there any assumptions about caller identity that are not validated?
- What happens if called with boundary inputs (0, max uint, empty arrays)?
- **Are there TODO/FIXME/HACK/TEMP comments?** These signal incomplete implementations and are HIGH PRIORITY audit targets.
- **Is this code newer than the rest of the codebase?** (recent git commits, different style, fewer tests). Newer code is more likely to have bugs.

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

**CRITICAL — Per-Instruction/Function Access Control Matrix:**

For EVERY public/external function or instruction in the protocol, build an explicit matrix:

```
| Function/Instruction       | Signer Required | Admin? | CPI Protected? | Caller-Controlled Data  | Validation on Data |
|---------------------------|-----------------|--------|----------------|------------------------|-------------------|
| refresh_price_list        | None            | No     | YES            | token IDs              | Full price checks |
| refresh_chainlink_price   | Any keypair     | No     | NO             | serialized report blob | ???               |
```

**DO NOT generalize defenses from one function to another.** If Function A has CPI protection, do NOT assume Function B does. Check EACH function independently. This is the #1 cause of missed bugs in oracle and admin-adjacent code.

**Asymmetry signals:** If two functions do similar things but one has significantly less validation than the other, this asymmetry is itself a red flag. Investigate why one path is less protected.

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

### 4.7 External Data Ingestion Analysis (CRITICAL — #1 Source of Missed Bugs)

**For every function that accepts external data blobs (oracle reports, signed messages, serialized payloads, user-supplied bytes):**

1. **Enumerate ALL fields** in the external data structure — not just the ones the code uses. Check the upstream documentation (Chainlink, Pyth, etc.) for the complete field list.
2. **For each field the code USES**: What validation exists? Can the value be 0? Negative? Extremely large? What bounds make sense?
3. **For each field the code IGNORES**: Should it be checked? Does it contain security-relevant information (expiry timestamps, confidence intervals, cross-reference prices)?
4. **Trace the complete data flow**: External blob → parsing → validation → math operations → state storage. At EVERY step, verify that invalid/extreme values are caught.
5. **Who controls submission?** If the instruction is permissionless (any signer can submit), the external data is attacker-controlled even if cryptographically signed — because the attacker CHOOSES WHICH valid data to submit and WHEN.

**Permissionless + caller-chosen data = HIGHEST PRIORITY ATTACK SURFACE.**

Example of what to check:
```
Oracle report has fields: price, multiplier, confidence, expires_at, valid_from, tokenized_price
Code uses: price, multiplier (multiplied together, stored as oracle price)
Code ignores: confidence, expires_at, valid_from, tokenized_price

Questions:
- Can multiplier be 0? → price * 0 = $0 → mass liquidation
- Can multiplier be 1000x? → inflated price → undercollateralized borrowing
- Is expires_at checked? → stale reports could be replayed
- Is tokenized_price compared to price*multiplier? → cross-reference would catch anomalies
- Is there a confidence interval check? → all other adapters have one, this doesn't → ASYMMETRY SIGNAL
```

### 4.8 Cross-Adapter / Cross-Handler Comparison (CRITICAL)

When a protocol has multiple handlers/adapters for similar functionality (e.g., different oracle types, different token standards, different chain adapters):

1. **Build a validation comparison table** across ALL adapters. List every check each adapter performs.
2. **Flag ANY adapter that is missing a check that ALL others have.** This is almost always a bug — the developer forgot to add it or considered the adapter "temporary."
3. **Check test coverage per adapter.** An adapter with zero tests is far more likely to have bugs.
4. **Check for TODO/FIXME comments** in the less-validated adapter — these confirm the developer knew it was incomplete.

Example table format:
```
| Validation              | Adapter A | Adapter B | Adapter C (v10) |
|------------------------|-----------|-----------|-----------------|
| Confidence interval    | YES       | YES       | MISSING ← BUG   |
| Staleness check        | YES       | YES       | YES             |
| CPI protection         | YES       | YES       | MISSING ← BUG   |
| Bounds on multiplier   | N/A       | N/A       | MISSING ← BUG   |
| Test coverage          | 15 tests  | 8 tests   | 0 tests ← FLAG  |
```

### 4.9 Configuration-Dependent Protection Verification

When a protection mechanism is configurable per-asset/per-entry (e.g., ref_price, TWAP enabled, confidence factor):

1. **Don't just verify the mechanism EXISTS — verify it's ENABLED for every asset.**
2. **Check for default/sentinel values** that disable the protection (e.g., `ref_price = 0xFFFF` means "skip check").
3. **Count how many assets have the protection disabled.** If any critical assets are unprotected, that's a finding even if the mechanism itself is well-implemented.
4. **Query on-chain state** (if accessible) to verify live configuration, not just code defaults.

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
| **Missing multiplier/scaling bounds** | **Oracle adapters that accept multiplier/scaling fields without validating range (0, extreme values). Can produce $0 or inflated prices** |
| **Permissionless oracle crank** | **Instruction that lets ANY signer submit oracle data. Attacker selects WHICH valid report to submit and WHEN — enables stale report replay, selective pricing during transitions** |
| **Missing cross-reference validation** | **Oracle report contains multiple price fields (e.g., `tokenized_price` vs `price * multiplier`) but only one is used without cross-checking** |
| **Adapter validation asymmetry** | **One oracle adapter missing validation that ALL others have (e.g., confidence interval present in v3 but absent in v10)** |
| **Missing report expiry/validity window** | **Oracle report has `expires_at`/`valid_from` fields that aren't checked — enables consumption of expired or premature reports** |
| **Corporate action transition window** | **Tokenized assets (stocks/RWA) have multiplier changes during splits/dividends. Code handles the transition but bypass exists when activation flag is in default state** |

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

### PYTHON / VM SANDBOX-SPECIFIC (execution sandboxes, WASM VMs, custom interpreters)

**What to grep for:** `compile(`, `__builtins__`, `sys.settrace`, `sys.setprofile`, `BaseException`, `SystemExit`, `settrace`, `FUEL`, `fuel`, `metering`, `memory_limit`, `DISABLED_BUILTINS`, `AST_NAME_BLACKLIST`

| Pattern | Tier | What to Look For |
|---------|------|-----------------|
| Exception hierarchy escape | Critical | Sandbox catches `Exception` but not `BaseException` — `SystemExit`, `KeyboardInterrupt`, `GeneratorExit` propagate through all handlers to crash the host process |
| Dangerous builtins exposed | Critical | `SystemExit`, `KeyboardInterrupt`, `BaseException`, `GeneratorExit`, `__import__`, `compile` available to sandboxed code |
| Unimplemented metering / dead code | High | Fuel/gas constants defined but never decremented; `sys.settrace()` or `sys.setprofile()` never called; cost maps defined as dead code |
| Memory limits stored but unchecked | High | `memory_limit` field stored in sandbox but never enforced via `resource.setrlimit`, `tracemalloc`, or custom tracking |
| C-level builtin bypass of tracing | High | Even with `sys.settrace`, native C builtins (`sorted`, `list`, `dict`, `set`, `max`, `min`, `sum`) run unmetered C code that bypasses Python opcode tracing |
| AST validator gaps | High | AST validation missing `visit_Raise()`, `visit_Import()`, or `visit_Call()` for dangerous patterns; dangerous names not in blacklist |
| Persistent crash / boot loop | Critical | Malicious input saved to persistent storage (blockchain, DB) BEFORE validation — on restart, host re-encounters same input and crashes again permanently |
| Compensating control mistaken for fix | Medium | Configuration-level restriction (e.g., address whitelist for deployment) treated as security fix — code comments indicate restriction will be lifted |
| `__build_class__` metaclass escape | High | Metaclass `__init_subclass__`, `__set_name__`, or descriptor protocol methods run outside sandbox tracing |
| Infinite recursion without stack limit | High | No `sys.setrecursionlimit()` or equivalent — sandboxed code can stack overflow the host |

**Key methodology for Python sandbox audits:**

1. **Map the exception hierarchy**: `BaseException` -> `SystemExit`, `KeyboardInterrupt`, `GeneratorExit` are NOT caught by `except Exception`. Trace every `except` clause in the call chain from sandboxed code to the process boundary.

2. **Verify metering is IMPLEMENTED, not just DESIGNED**: Search for actual `sys.settrace`/`sys.setprofile` calls, actual fuel decrement operations, actual memory tracking. Configuration values that are stored but never checked = HIGH severity.

3. **Trace crash propagation**: When a crash vector is found, determine if the trigger persists across restarts. If the malicious data is in a blockchain/DAG/database and the host re-processes it on restart = permanent boot loop.

4. **Audit builtin exposure**: Compare allowed builtins vs disabled builtins against Python full builtin list. Every `BaseException` subclass in the allowed list is a potential crash vector.

5. **Distinguish compensating controls from code fixes**: Config-based restrictions (address whitelists, feature flags) are NOT code-level fixes. Check code comments and roadmaps for plans to lift restrictions — the vulnerability remains latent.

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
[ ] Every function pair doing similar things — same validation? Build comparison table!
[ ] Every external data ingestion — ALL fields from upstream schema enumerated and checked?
[ ] Every permissionless function — what data can the caller choose? Bounds on every field?
[ ] Every configurable protection — verified ENABLED per-asset, not just exists in code?
[ ] Every TODO/FIXME/HACK — security implications of incomplete implementation?
[ ] Every newer/recently-added code path — extra scrutiny, zero-test-coverage check?
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
[ ] Every instruction — CPI protected? If one is but another isn't, WHY?
[ ] Every permissionless instruction — what data can caller control? All fields validated?
[ ] Every oracle adapter — same validation as peer adapters? Build comparison table!
[ ] Every external report/blob — ALL fields traced? Unused fields checked for security relevance?
[ ] Every configurable protection — enabled for ALL assets? Check for sentinel/default that disables it
[ ] Every TODO/FIXME/HACK comment — does incomplete code have security implications?
```

### Python / VM Sandbox Additional Checks

```
[ ] Every except clause — does it catch BaseException or only Exception? (SystemExit escapes)
[ ] Every builtin exposed to sandboxed code — is it in the safe set? Check BaseException subclasses
[ ] Every metering/fuel system — is it actually enforced? (settrace called? fuel decremented?)
[ ] Every memory limit — is it checked at runtime or just stored?
[ ] Every AST validator — visit_Raise, visit_Import, visit_Call present? Blacklist complete?
[ ] Every crash handler — does malicious input persist across restarts? (boot loop?)
[ ] Every C builtin in sandbox — does it bypass opcode tracing?
[ ] Every configuration restriction — is it a compensating control or a real fix? Will it be lifted?
[ ] Every sandbox escape vector — trace full call chain to process boundary
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

*Last updated: 2026-03-03 (v4 — added Python/VM Sandbox-Specific vulnerability catalog and checklist: exception hierarchy escapes, dead code metering, C-level builtin bypass, boot loop analysis, compensating control vs code fix distinction — from Hathor Network nano contracts audit)*
*Cross-references: [IMMUNEFI-REPORT-GUIDE.md](IMMUNEFI-REPORT-GUIDE.md) | [all_programs.txt](all_programs.txt) | [audits/](audits/)*
