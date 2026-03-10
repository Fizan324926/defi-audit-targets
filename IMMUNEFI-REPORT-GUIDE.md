# Immunefi Bug Report & PoC Reference Guide

Distilled from official Immunefi documentation, tutorials, and field experience.
Use this as a checklist and template reference every time a vulnerability is found.

---

## Table of Contents

1. [Pre-Submission Checklist](#1-pre-submission-checklist)
2. [Severity Classification System](#2-severity-classification-system)
3. [Bug Report Format](#3-bug-report-format)
4. [PoC Requirements and Rules](#4-poc-requirements-and-rules)
5. [PoC Environment Setup](#5-poc-environment-setup)
6. [Optimizing Attack Parameters](#6-optimizing-attack-parameters)
7. [Negotiation and Mediation](#7-negotiation-and-mediation)
8. [Banned Behaviors (Instant Ban)](#8-banned-behaviors-instant-ban)
9. [Quick Reference: Report Template](#9-quick-reference-report-template)

---

## 1. Pre-Submission Checklist

Work through this before writing a single word of the report.

### Program Scope

- [ ] Read the project's full bug bounty program page
- [ ] Confirm the **asset** (file/contract/module) is in scope
- [ ] If asset is out of scope, check if program uses **Primacy of Impact** (then impact drives scope)
- [ ] Confirm the **impact** type is in the program's listed in-scope impacts
- [ ] Check if the specific vulnerability is listed as a **known issue** — if yes, do not submit
- [ ] Read the Out of Scope Rules section on the program page
- [ ] Check payout terms and KYC requirements
- [ ] Confirm whether a **PoC is required** for the severity level being reported

### Report Quality Gates

- [ ] Title is descriptive: includes vulnerability class + impact (e.g. "Reentrancy in withdraw leads to total loss of funds")
- [ ] Bug description is clear and complete — no gaps a project reviewer would have to fill
- [ ] Economic damage is quantified (funds at risk right now, maximum possible loss)
- [ ] Severity selected matches the impact table (see Section 2)
- [ ] Attack vector is realistic and executable (not speculative or requiring unlikely conditions)
- [ ] All claims are backed by evidence (code snippets, transaction hashes, math)
- [ ] PoC is runnable as-is on a forked local environment (not pseudocode, not steps-only)
- [ ] PoC is optimized for maximum economic damage

### PoC Gates

- [ ] PoC runs on a **local fork** — never mainnet or public testnet
- [ ] PoC uses self-explanatory variable names (`attacker`, `victim`, `target`)
- [ ] PoC uses self-explanatory function names (`_executeAttack`, `_setupAttack`, `_verifyDamage`)
- [ ] PoC demonstrates maximum impact (optimized parameters, not just proof of existence)
- [ ] PoC does not cause any real-world damage

---

## 2. Severity Classification System

Immunefi uses a **5-level scale**: Critical → High → Medium → Low → None.

Classification is driven by **impact of a successful exploit**, not technical complexity.
If exploit requires elevated privileges or uncommon user interaction, severity may be downgraded.

### Smart Contracts

| Level | Impact |
|-------|--------|
| **Critical** | Any governance voting result manipulation |
| | Direct theft of any user funds (at-rest or in-motion), other than unclaimed yield |
| | Direct theft of any user NFTs (at-rest or in-motion), other than unclaimed royalties |
| | Permanent freezing of funds |
| | Permanent freezing of NFTs |
| | Miner-extractable value (MEV) |
| | Unauthorized minting of NFTs |
| | Predictable or manipulable RNG resulting in abuse |
| | Unintended alteration of what an NFT represents |
| | Protocol insolvency |
| **High** | Theft of unclaimed yield |
| | Theft of unclaimed royalties |
| | Permanent freezing of unclaimed yield |
| | Permanent freezing of unclaimed royalties |
| | Temporary freezing of funds |
| | Temporary freezing of NFTs |
| **Medium** | Smart contract unable to operate due to lack of token funds |
| | Block stuffing for profit |
| | Griefing (no profit motive, but damage to users or protocol) |
| | Theft of gas |
| | Unbounded gas consumption |
| **Low** | Contract fails to deliver promised returns, but doesn't lose value |
| **None** | Best practices |

### Blockchain / DLT

| Level | Impact |
|-------|--------|
| **Critical** | Total network shutdown (cannot confirm transactions) |
| | Unintended permanent chain split requiring hard fork |
| | Direct loss of funds |
| | Permanent freezing of funds (fix requires hardfork) |
| | RPC API crash |
| **High** | Unintended chain split (network partition) |
| | Transient consensus failures |
| **Medium** | High compute consumption by validator/mining nodes |
| | Attacks against thin clients |
| | DoS of >30% of validator/miner nodes (without network shutdown) |
| **Low** | DoS of 10-30% of validator/miner nodes |
| | Underpricing transaction fees relative to computation time |
| **None** | Best practices |

### Websites and Apps

| Level | Impact |
|-------|--------|
| **Critical** | Execute arbitrary system commands |
| | Retrieve sensitive data (shadow file, DB passwords, blockchain keys) |
| | Taking down application/website |
| | Taking state-modifying authenticated actions on behalf of other users |
| | Direct theft of user funds or NFTs |
| | Malicious interactions with already-connected wallet |
| **High** | Injecting/modifying static content without JavaScript (Persistent) |
| | Changing sensitive details of other users without wallet interaction |
| | Improperly disclosing confidential user information |
| | Subdomain takeover without already-connected wallet interaction |
| **Medium** | Changing non-sensitive details without wallet interaction |
| | Injecting static content (Reflected) |
| | Redirecting users to malicious websites (Open Redirect) |
| **Low** | Changing details with significant user interaction |
| | Taking over broken/expired outgoing links |
| | Temporarily disabling user access |
| **None** | SPF/DMARC misconfigured records |
| | Missing HTTP Headers without demonstrated impact |
| | Automated scanner reports without demonstrated impact |
| | UI/UX best practices recommendations |

---

## 3. Bug Report Format

Every report must include all sections below. Do not skip any.

### Title

**Format:** `[Vulnerability Class] in [function/module] leads to [impact]`

**Good examples:**
- `Reentrancy in withdraw() leads to total loss of funds`
- `Lack of access control in setOwner() leads to privilege escalation`
- `Arithmetic overflow in calculateRewards() causes permanent fund freeze`
- `wrapping_add on protocol_fee_owed allows silent fee counter reset`

**Bad examples:**
- `Found a bug`
- `Overflow issue`
- `Access control problem in the contract`

---

### Bug Description

#### Brief / Intro (1 paragraph)
One clear, concise statement covering:
- What the problem is
- What happens if exploited in production

#### Details
Full technical explanation covering:
- The exact vulnerable code location (file + line number)
- Why the code is wrong (the root cause)
- The logical flaw or incorrect assumption
- Relevant code snippets (inline, not attached)
- How it differs from the intended/correct behavior

**Do not** leave gaps. The project should not have to ask questions after reading this section.

---

### Impact

- State the specific impact from the severity table (Section 2)
- Quantify the economic damage in concrete terms:
  - Exact funds at risk right now (current pool balances, TVL, etc.)
  - Maximum possible loss from a single exploit
  - Who loses (users, LPs, protocol treasury, governance)
  - Who gains (attacker, or no one — loss goes to void)
- Note whether impact is immediate or requires time/volume

---

### Risk Breakdown

Assess exploit difficulty. Be honest — Immunefi reviewers will downgrade if you overstate:

| Factor | Assessment |
|--------|-----------|
| Access required | None / User / Admin / Contract owner |
| User interaction required | Yes / No |
| Attack complexity | Low / Medium / High |
| Repeatability | One-shot / Requires sustained effort |
| Time to exploit | Immediate / Hours / Days / Years |
| Prerequisites | None / Specific market conditions / Admin key |

---

### Recommendation

- State the minimal fix (specific function + specific change)
- Provide before/after code snippets showing the fix
- Mention any related areas that should be reviewed as follow-up
- If multiple fix options exist, list them in order of preference

---

### References

- Vulnerable file paths and line numbers
- Related contracts or external dependencies
- Any relevant protocol documentation
- Prior audit reports that missed this (if applicable)

---

### Proof of Concept

**This is the most critical section.** A PoC must be:

- **Runnable code** — not pseudocode, not a list of steps, not just the project's contracts
- **Self-contained** — runs on a fresh forked environment with no manual setup
- **Demonstrating maximum impact** — not just proving existence, proving the worst case
- **Tested locally** — confirmed passing before submission

See Section 4 for full PoC requirements.

---

## 4. PoC Requirements and Rules

### What Counts as a Valid PoC

A valid PoC is **one of**:
- A Hardhat/Foundry test file that runs the exploit end-to-end
- A Solana test using Bankrun or similar local validator
- An attack smart contract with callable exploit functions
- Any runnable code that executes the full exploit path

**Not valid:**
- A list of steps (even detailed ones)
- Pseudocode
- Just the project's own contracts with comments
- A description of what the exploit would look like

### PoC Rules

- **Never test on mainnet or public testnet** — immediate permanent ban
- Always use a local fork (Hardhat, Foundry, Bankrun, etc.)
- Pin to a specific block number for reproducibility
- PoC must pass/succeed as-submitted — do not ask reviewers to modify it

### PoC Naming Conventions

```
// Variable names
address attacker = ...;
address victim = ...;
address target = ...;    // vulnerable contract

// Function names
function setUp() public { ... }
function _setupAttack() internal { ... }
function _executeAttack() internal { ... }
function _verifyDamage() internal { ... }
function testExploit() public { ... }
```

### PoC Optimization

Before submitting, optimize your attack parameters to demonstrate **maximum economic damage**:

- Try different input amounts to find the maximum drainable amount
- If exploit requires multiple steps, optimize ordering
- For complex parameter spaces, use linear programming (see Section 6)
- Document the optimal parameters in the PoC comments

---

## 5. PoC Environment Setup

### Foundry (recommended for Solana-adjacent EVM work and modern reports)

```toml
# foundry.toml
[default]
src = 'src'
out = 'out'
libs = ['lib']
chain_id = 1
eth_rpc_url = 'https://eth-mainnet.alchemyapi.io/v2/{API_KEY}'
block_number = 12345678          # pin to a recent block
etherscan_api_key = '{KEY}'      # improves trace readability
```

```solidity
// Basic Foundry test structure
contract ExploitTest is Test {
    address attacker = address(0xBEEF);
    VulnerableContract target;

    function setUp() public {
        // Fork state is already set via foundry.toml
        target = VulnerableContract(0x...);

        // Give attacker tokens using storage manipulation
        deal(address(token), attacker, 1_000_000e18);
    }

    function testExploit() public {
        vm.startPrank(attacker);
        _executeAttack();
        vm.stopPrank();
        _verifyDamage();
    }

    function _executeAttack() internal { ... }
    function _verifyDamage() internal {
        assertGt(token.balanceOf(attacker), initialBalance);
    }
}
```

**Useful Foundry cheat codes:**
```solidity
vm.startPrank(addr);              // impersonate address
vm.stopPrank();
deal(token, addr, amount);        // set token balance
vm.warp(timestamp);               // set block timestamp
skip(seconds);                    // advance time
vm.roll(blockNum);                // set block number
stdstore.target(...).sig(...).with_key(...).checked_write(val); // write storage slot
```

### Hardhat (for older projects or when Foundry not available)

```javascript
// hardhat.config.js
module.exports = {
    networks: {
        hardhat: {
            chainId: 1,
            forking: {
                url: "https://eth-mainnet.alchemyapi.io/v2/{API_KEY}",
                blockNumber: 12345678
            }
        }
    }
};
```

```javascript
// Basic Hardhat test structure
const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Exploit", function() {
    this.timeout(250000);
    let target, attacker;

    before(async () => {
        [attacker] = await ethers.getSigners();
        target = await hre.ethers.getVerifiedContractAt("0x...");
    });

    it("exploits the vulnerability", async function() {
        // Setup
        await target.connect(attacker).executeExploit();
        // Verify
        const balance = await token.balanceOf(attacker.address);
        expect(balance).to.be.gt(0);
    });
});
```

**Useful Hardhat tricks:**
```javascript
// Impersonate any address
await hre.network.provider.request({
    method: "hardhat_impersonateAccount",
    params: [victimAddress]
});
const victimSigner = await ethers.provider.getSigner(victimAddress);

// Expect revert
const {expectRevert} = require('@openzeppelin/test-helpers');
await expectRevert.unspecified(target.connect(victim).harvest(0));
```

### Solana (Bankrun / local validator)

For Solana/Anchor programs, use Bankrun or `solana-test-validator` with a cloned mainnet state:

```bash
# Clone mainnet accounts for local testing
solana-test-validator \
  --clone <program_id> \
  --clone <pool_account> \
  --url mainnet-beta
```

```typescript
// Anchor test structure
it("exploits the vulnerability", async () => {
    const attacker = Keypair.generate();

    // Airdrop SOL
    await provider.connection.confirmTransaction(
        await provider.connection.requestAirdrop(attacker.publicKey, 10e9)
    );

    // Execute exploit
    await program.methods
        .vulnerableInstruction(params)
        .accounts({ attacker: attacker.publicKey, ... })
        .signers([attacker])
        .rpc();

    // Verify damage
    const balance = await getTokenBalance(provider, victimVault);
    assert(balance === 0, "Vault should be drained");
});
```

---

## 6. Optimizing Attack Parameters

When the exploit involves multiple parameters that affect the amount drained, use optimization to find the maximum impact.

### Linear Programming with GEKKO (Python)

```python
from gekko import GEKKO

m = GEKKO()

# Fixed constants from chain state
pool_reserve_a = m.Param(value=1_000_000e18)
pool_reserve_b = m.Param(value=500_000e18)

# Decision variables (what the attacker controls)
flash_amount = m.Var(lb=0, value=100_000e18)
swap_amount  = m.Var(lb=0, value=100_000e18)

# Constraints
m.Equation(flash_amount + swap_amount <= 700_000e18)  # max flash loan

# Build profit expression from exploit math
# ... model your exploit steps as equations ...
profit = ...

# Maximize
m.Maximize(profit)
m.solve(disp=False)

print(f"Optimal flash_amount: {flash_amount.value[0]:.2f}")
print(f"Optimal swap_amount:  {swap_amount.value[0]:.2f}")
print(f"Maximum profit:       {-m.options.OBJFCNVAL:.2f}")
```

### When to Use Optimization

- Exploit requires choosing flash loan amounts, swap sizes, or deposit ratios
- Multiple steps where earlier steps affect the profitability of later steps
- When "guessing" optimal parameters by hand is infeasible
- When different token decimals or reserves significantly affect the outcome

### Problem Types

| Type | When to use |
|------|-------------|
| LP (Linear Program) | All equations are linear, variables are real numbers |
| MILP | Linear equations, some variables must be integers |
| NLP | Non-linear equations (e.g., AMM xy=k), real variables |
| MINLP | Non-linear equations, some integer variables |

---

## 7. Negotiation and Mediation

### SLA (Service Level Agreement) — Know Your Rights

When projects join Immunefi they agree to response time SLAs. If breached:
- Follow up directly in the submission thread
- Tag the Immunefi team in the dashboard
- Do not wait passively — be proactive

**When to request mediation:**
- Project hasn't responded to a **Critical bug in 14 days**
- Project responds but changes their rejection reason mid-process (red flag)
- Project declares a lower payout than agreed in their bounty program
- Project claims "duplicate" after a valid mediation ruling (ask for evidence immediately)

**What mediation is:**
- Immunefi performs an impartial third-party technical review
- Both sides present claims
- Immunefi issues a Mediation Summary
- Immunefi's ruling carries weight but **has limited enforcement for most programs**

### Negotiation Tips (Tactical Empathy)

- Know the project's needs: brand safety, user trust, TVL protection are often MORE valuable than the payout amount
- Frame your disclosure as having protected all of their users
- Align the narrative with facts that favor fair payment
- Know what "minimum critical payout" means for their program before negotiating
- Document every interaction in the report thread (not just DMs)

### Red Flags from Projects

- Closing a report as invalid without reading it (check if their rejection addresses the substance)
- Changing rejection reason after mediation begins
- Claiming "duplicate" without providing evidence
- Going silent after SLA deadlines

**If a project acts in bad faith:**
- Request Immunefi intervention immediately via the submission thread
- Note: Immunefi can pause a project's BBP but has limited enforcement for payouts beyond that
- Keep all communication on-platform

---

## 8. Banned Behaviors (Instant Ban)

These result in an immediate and permanent ban from Immunefi:

| Behavior | Consequence |
|----------|-------------|
| Testing PoC on mainnet or public testnet | Permanent ban |
| Submitting AI-generated or automated reports | Warning then ban |
| Spray-and-pray: many low-quality submissions | Ban |
| Submitting out-of-scope assets repeatedly | Ban |
| Submitting out-of-scope impacts repeatedly | Ban |
| Misclassifying severity repeatedly | Ban |
| Harassment of project teams | Ban |

---

## 9. Quick Reference: Report Template

Copy this for each new finding. Fill every section before submitting.

```
---
TITLE: [Vulnerability Class] in [file:line] leads to [impact]

SEVERITY: [Critical / High / Medium / Low]

AFFECTED FILE: [path/to/file.rs:line]
FUNCTION: [function_name()]

---

## Brief Summary

[1 paragraph: what is wrong and what happens if exploited]

---

## Vulnerability Details

### Root Cause

[Explain the code flaw at the source level. Include the exact vulnerable code.]

```[language]
// Vulnerable code (file.rs:LINE)
[paste the vulnerable snippet]
```

### Why This Is Wrong

[Explain the incorrect assumption or missing check. Compare to the correct pattern.]

### Attack Path

[Step-by-step: what the attacker does, in what order, and why each step works]

1. Attacker does X
2. This triggers Y because [reason]
3. State Z is now incorrect
4. Attacker calls collect() and receives [incorrect amount]

---

## Impact

- **Who loses:** [protocol treasury / LPs / users / NFT holders]
- **Who gains:** [attacker / nobody — funds go to void]
- **Funds at risk now:** [$ amount based on current TVL/balances]
- **Maximum possible loss:** [worst case calculation]
- **Affected operations:** [list of instructions/functions that fail or are exploited]

---

## Risk Assessment

| Factor | Value |
|--------|-------|
| Access required | [None / User / Admin] |
| User interaction | [Yes / No] |
| Complexity | [Low / Medium / High] |
| Repeatability | [One-shot / Requires sustained effort] |
| Time to trigger | [Immediate / Days / Years] |

---

## Recommendation

```[language]
// BEFORE (vulnerable):
[old code]

// AFTER (fixed):
[new code]
```

[Explanation of why the fix works and any follow-up areas to review]

---

## References

- Vulnerable code: `path/to/file.rs:LINE`
- Related code: `path/to/other.rs:LINE`
- [Any relevant documentation links]

---

## Proof of Concept

[Platform: Foundry / Hardhat / Anchor / Bankrun / Python]

[Setup instructions — should be one command to run]

```[language]
// Full runnable PoC
// Run with: forge test -vvv --match-test testExploit

[complete test code]
```

Expected output:
```
[what the test prints when it passes, showing the exploit worked]
```
---
```

---

## Lessons from the Field

Based on real researcher experience:

1. **A valid mediation ruling does not guarantee payment.** Keep all communications on-platform. Document everything.

2. **Watch for rejection reason changes.** If a project closes your report for reason X, then during mediation switches to reason Y (especially "duplicate"), request evidence immediately and flag it to Immunefi.

3. **Proactively follow up.** Immunefi will not chase the project for you unless you keep requesting status updates. Follow up at every SLA deadline.

4. **Primacy of Rules vs Primacy of Impact matters.** Many programs use Primacy of Rules — only explicitly listed impacts are in scope. Know which your target uses before submitting.

5. **Best practice critiques get zero.** A real bug needs real economic impact. Code quality issues (wrong error type, missing comments, sub-optimal patterns) are explicitly out of scope on many programs.

6. **"Best practice critique" is a common rejection.** When the impact is low or theoretical, projects often use this label. Make sure your finding has clear, quantifiable, realistic impact before submitting.

7. **PoC quality directly correlates to payout size.** A PoC that shows the maximum drained amount at optimal parameters earns more than one that just proves existence.

8. **Vault bonds and enforcement are limited.** Immunefi can pause a bad-faith project but cannot force payment in most cases. Research a project's payment history before investing days in an audit.
