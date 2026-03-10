# Immunefi Bug Report: WJST.getPriorVotes Lacks Checkpoint Mechanism — Governance Manipulation

## Bug Description

The `WJST` governance token contract (`contracts/Governance/WJST.sol`) implements `getPriorVotes()` without any checkpoint or historical snapshot mechanism. The function completely ignores the `blockNumber` parameter and returns the caller's **current** balance:

```solidity
// WJST.sol:93-96
function getPriorVotes(address account, uint256 blockNumber) public view returns (uint256){
    blockNumber;                    // parameter silently discarded
    return balanceOf_[account];     // returns CURRENT balance, not historical snapshot
}
```

This function is called by `GovernorBravoDelegate` in three critical governance operations:

### 1. Proposal creation (`propose()`, line 78)
```solidity
require(wjst.getPriorVotes(msg.sender, sub256(block.number, 1)) > proposalThreshold || isWhitelisted(msg.sender),
    "GovernorBravo::propose: proposer votes below proposal threshold");
```
**Intended behavior:** Check proposer's voting power at the previous block.
**Actual behavior:** Checks proposer's current balance — allows instant proposal creation after acquiring tokens.

### 2. Vote casting (`castVoteInternal()`, line 278)
```solidity
require(votesAdded <= wjst.getPriorVotes(voter, proposal.startBlock),
    "GovernorBravo::castVoteInternal: short of vote power");
```
**Intended behavior:** Limit voting power to balance at proposal start block (snapshot).
**Actual behavior:** Uses current balance — tokens acquired AFTER proposal creation count as voting power.

### 3. Proposal cancellation (`cancel()`, lines 167, 170)
```solidity
require((wjst.getPriorVotes(proposal.proposer, sub256(block.number, 1)) < proposalThreshold),
    "GovernorBravo::cancel: proposer above threshold");
```
**Intended behavior:** Check if proposer's historical voting power dropped below threshold.
**Actual behavior:** Uses current balance — selling/transferring tokens after proposal creation allows cancellation.

### Root Cause

Compound V2's `Comp.sol` implements `getPriorVotes()` with a checkpoint array and binary search that provides historical balance lookups. JustLend replaced the entire COMP token with a custom WJST "vote-and-lock" wrapper but did not implement the checkpoint mechanism, breaking the fundamental governance snapshot property.

### Call Chain
```
User → GovernorBravoDelegate.castVote(proposalId, votes, support)
  → castVoteInternal(voter, proposalId, votes, support)
    → wjst.getPriorVotes(voter, proposal.startBlock)  // returns CURRENT balance
    → wjst.voteFresh(voter, proposalId, support, votesAdded)  // locks tokens
```

## Impact

### Governance Manipulation Attack

**Attack scenario:**
1. Attacker monitors mempool/governance for new proposals
2. Attacker purchases JST tokens on TRON DEXes (e.g., SunSwap) after seeing proposal
3. Attacker deposits JST into WJST via `deposit()`, receiving WJST balance
4. When voting begins (`block.number > proposal.startBlock`), attacker calls `castVote()` with their full WJST balance
5. GovernorBravo checks `votesAdded <= wjst.getPriorVotes(voter, proposal.startBlock)` — returns current balance (post-acquisition), check passes
6. `voteFresh()` locks tokens for the proposal duration
7. After proposal resolves (state >= 2), attacker calls `withdrawVotes()` to unlock
8. Attacker sells JST, potentially profiting from governance manipulation

**Governance consequences:**
- Pass malicious proposals to change oracle addresses → price manipulation → bad debt/liquidation cascades
- Modify collateral factors → undercollateralized borrowing
- Change reserve factors → redirect protocol revenue
- Update interest rate models → market manipulation
- If timelock is short, limited window for community response

**Mitigating factors:**
- `voteFresh()` locks tokens during voting, preventing flash-loan attacks (tokens deducted from `balanceOf_` cannot be used to repay flash loan in same transaction)
- Quorum is 600,000,000 WJST (≈6% of 9.9B JST supply) — requires significant capital
- Attacker bears JST price risk for the entire voting period (24 hours to 2 weeks)
- Timelock delay provides window for detection and response (if monitoring exists)

### Severity Classification

**Severity: Medium**

Per Immunefi's classification:
- **Smart Contracts — Medium:** Governance vote manipulation allowing post-proposal vote buying
- Not High/Critical because: flash-loan path is blocked by token locking, requires multi-block capital commitment with price risk, and quorum is substantial
- Above Low because: the fundamental governance security model (snapshot-based voting) is broken, and successful exploitation enables protocol-level parameter manipulation

### Affected Users
- All JustLend governance participants
- All JustLend depositors/borrowers (indirectly, via governance manipulation)

## Risk Breakdown

- **Difficulty to exploit:** Medium — Requires significant JST capital but no technical sophistication
- **Weakness type:** CWE-284 (Improper Access Control) — Voting power not properly scoped to historical state
- **CVSS 3.1:** 6.5 (Medium) — AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:H/A:N (integrity of governance process)

## Recommendation

Implement a checkpoint-based voting power system, following Compound's `Comp.sol` or OpenZeppelin's `ERC20Votes` pattern:

```diff
+ struct Checkpoint {
+     uint32 fromBlock;
+     uint256 votes;
+ }
+
+ mapping(address => mapping(uint32 => Checkpoint)) public checkpoints;
+ mapping(address => uint32) public numCheckpoints;

  function getPriorVotes(address account, uint256 blockNumber) public view returns (uint256){
-     blockNumber;
-     return balanceOf_[account];
+     require(blockNumber < block.number, "WJST::getPriorVotes: not yet determined");
+
+     uint32 nCheckpoints = numCheckpoints[account];
+     if (nCheckpoints == 0) {
+         return 0;
+     }
+
+     // First check most recent balance
+     if (checkpoints[account][nCheckpoints - 1].fromBlock <= blockNumber) {
+         return checkpoints[account][nCheckpoints - 1].votes;
+     }
+
+     // Next check implicit zero balance
+     if (checkpoints[account][0].fromBlock > blockNumber) {
+         return 0;
+     }
+
+     // Binary search
+     uint32 lower = 0;
+     uint32 upper = nCheckpoints - 1;
+     while (upper > lower) {
+         uint32 center = upper - (upper - lower) / 2;
+         Checkpoint memory cp = checkpoints[account][center];
+         if (cp.fromBlock == blockNumber) {
+             return cp.votes;
+         } else if (cp.fromBlock < blockNumber) {
+             lower = center;
+         } else {
+             upper = center - 1;
+         }
+     }
+     return checkpoints[account][lower].votes;
  }
```

Additionally, add a `_writeCheckpoint` internal function called during `deposit()`, `withdraw()`, `voteFresh()`, `withdrawVotesFresh()`, and `transferFrom()` to record balance changes with their block numbers.

## Proof of Concept

The following Foundry test demonstrates that WJST's `getPriorVotes` returns current balance instead of historical, enabling post-proposal vote accumulation.

**Note:** This PoC is designed as a logical demonstration. JustLend is deployed on TRON, which has EVM-compatible bytecode execution. The test uses standard Solidity/Foundry to demonstrate the vulnerability logic.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

// Minimal reproduction of WJST's broken getPriorVotes
contract MockWJST {
    mapping(address => uint256) public balanceOf_;

    function deposit(address user, uint256 amount) external {
        balanceOf_[user] += amount;
    }

    function withdraw(address user, uint256 amount) external {
        balanceOf_[user] -= amount;
    }

    // JustLend's broken implementation — ignores blockNumber
    function getPriorVotes(address account, uint256 blockNumber) public view returns (uint256) {
        blockNumber; // silently discarded
        return balanceOf_[account];
    }
}

// Reference: Compound's correct implementation with checkpoints
contract MockCompVotes {
    struct Checkpoint {
        uint32 fromBlock;
        uint256 votes;
    }

    mapping(address => mapping(uint32 => Checkpoint)) public checkpoints;
    mapping(address => uint32) public numCheckpoints;
    mapping(address => uint256) public balanceOf_;

    function deposit(address user, uint256 amount) external {
        balanceOf_[user] += amount;
        _writeCheckpoint(user, balanceOf_[user]);
    }

    function _writeCheckpoint(address user, uint256 newVotes) internal {
        uint32 nCheckpoints = numCheckpoints[user];
        checkpoints[user][nCheckpoints] = Checkpoint(uint32(block.number), newVotes);
        numCheckpoints[user] = nCheckpoints + 1;
    }

    function getPriorVotes(address account, uint256 blockNumber) public view returns (uint256) {
        require(blockNumber < block.number, "not yet determined");
        uint32 nCheckpoints = numCheckpoints[account];
        if (nCheckpoints == 0) return 0;
        if (checkpoints[account][nCheckpoints - 1].fromBlock <= blockNumber) {
            return checkpoints[account][nCheckpoints - 1].votes;
        }
        if (checkpoints[account][0].fromBlock > blockNumber) return 0;
        uint32 lower = 0;
        uint32 upper = nCheckpoints - 1;
        while (upper > lower) {
            uint32 center = upper - (upper - lower) / 2;
            if (checkpoints[account][center].fromBlock <= blockNumber) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return checkpoints[account][lower].votes;
    }
}

contract WJSTGovernanceExploitTest is Test {
    MockWJST wjst;
    MockCompVotes compVotes;

    address attacker = address(0xBEEF);

    function setUp() public {
        wjst = new MockWJST();
        compVotes = new MockCompVotes();
    }

    function test_WJSTReturnsCurrentBalanceNotHistorical() public {
        // Block 100: proposal is created, attacker has 0 WJST
        vm.roll(100);
        uint256 proposalStartBlock = block.number;

        // Verify attacker has 0 votes at proposal creation
        assertEq(wjst.getPriorVotes(attacker, proposalStartBlock), 0);

        // Block 105: attacker acquires tokens AFTER proposal
        vm.roll(105);
        wjst.deposit(attacker, 1_000_000e18);

        // VULNERABILITY: getPriorVotes returns CURRENT balance for a PAST block
        // Should return 0 (balance at block 100), but returns 1_000_000e18
        uint256 votingPower = wjst.getPriorVotes(attacker, proposalStartBlock);
        assertEq(votingPower, 1_000_000e18, "WJST returns current balance for past block");

        // This means attacker can vote with tokens acquired AFTER the proposal
        assertTrue(votingPower > 0, "Attacker has voting power despite having 0 at proposal creation");
    }

    function test_CompoundCorrectlyReturnsHistoricalBalance() public {
        // Block 100: proposal is created, attacker has 0
        vm.roll(100);
        uint256 proposalStartBlock = block.number;

        // Block 105: attacker acquires tokens AFTER proposal
        vm.roll(105);
        compVotes.deposit(attacker, 1_000_000e18);

        // Block 106: check voting power
        vm.roll(106);

        // CORRECT: returns 0 for block 100 (attacker had no tokens then)
        uint256 votingPower = compVotes.getPriorVotes(attacker, proposalStartBlock);
        assertEq(votingPower, 0, "Compound correctly returns 0 for past block");

        // Returns current balance for block 105
        uint256 currentPower = compVotes.getPriorVotes(attacker, 105);
        assertEq(currentPower, 1_000_000e18, "Compound correctly returns deposited amount for current block");
    }

    function test_PostProposalVoteBuyingAttack() public {
        address legitimateVoter = address(0xCAFE);

        // Block 100: legitimate voter has 500M WJST, attacker has 0
        vm.roll(100);
        wjst.deposit(legitimateVoter, 500_000_000e18);
        uint256 proposalStartBlock = block.number;

        // Block 101: proposal is created (startBlock = 100)
        vm.roll(101);

        // Block 110: attacker sees proposal, buys 200M JST and deposits
        vm.roll(110);
        wjst.deposit(attacker, 200_000_000e18);

        // Attacker's voting power at proposal.startBlock (should be 0, but returns current)
        uint256 attackerVotes = wjst.getPriorVotes(attacker, proposalStartBlock);

        // VULNERABILITY DEMONSTRATED:
        // Attacker has 200M voting power despite having 0 at proposal creation
        assertEq(attackerVotes, 200_000_000e18);

        // This could swing a close vote:
        // For: legitimateVoter (500M) + attacker (200M) = 700M > quorum (600M)
        // Without attacker: only 500M < quorum (600M)
        // Attacker's post-proposal purchase swings the outcome
        uint256 legitimateVotes = wjst.getPriorVotes(legitimateVoter, proposalStartBlock);
        assertTrue(legitimateVotes < 600_000_000e18, "Legitimate votes alone don't reach quorum");
        assertTrue(legitimateVotes + attackerVotes >= 600_000_000e18, "With attacker's post-proposal votes, quorum is reached");
    }
}
```

### Running the PoC

```bash
forge test --match-test "test_WJSTReturnsCurrentBalanceNotHistorical|test_CompoundCorrectlyReturnsHistoricalBalance|test_PostProposalVoteBuyingAttack" -vvv
```

Expected output: All three tests pass, demonstrating:
1. WJST returns current balance for past blocks (broken)
2. Compound's checkpoint model correctly returns historical balance (reference)
3. Post-proposal vote buying can swing governance outcomes

## References

- **Vulnerable contract:** https://github.com/justlend/justlend-protocol/blob/master/contracts/Governance/WJST.sol#L93-L96
- **GovernorBravo usage:** https://github.com/justlend/justlend-protocol/blob/master/contracts/Governance/Bravo/GovernorBravoDelegate.sol#L278
- **Compound V2 reference (correct implementation):** https://github.com/compound-finance/compound-protocol/blob/master/contracts/Governance/Comp.sol#L176-L217
- **GovernorBravo propose():** https://github.com/justlend/justlend-protocol/blob/master/contracts/Governance/Bravo/GovernorBravoDelegate.sol#L78
- **GovernorBravo cancel():** https://github.com/justlend/justlend-protocol/blob/master/contracts/Governance/Bravo/GovernorBravoDelegate.sol#L167-L170
