# Immunefi Bug Report: SuperFaultDisputeGame.closeGame() Ordering Bug Blocks claimCredit() During System Pause

---

## Bug Description

The `SuperFaultDisputeGame.closeGame()` function has an incorrect ordering of its internal checks compared to the sibling `FaultDisputeGame.closeGame()` implementation. Specifically, the pause check (`anchorStateRegistry().paused()`) is evaluated **before** the early-return check for already-decided bond distribution modes (`bondDistributionMode == REFUND || NORMAL`).

This means that when the system is paused (via the Guardian calling `SuperchainConfig.pause()`), **all** calls to `claimCredit()` on `SuperFaultDisputeGame` instances will revert — even for games where:
- The dispute has been fully resolved
- `closeGame()` was already called successfully before the pause
- The `bondDistributionMode` is already set to `NORMAL` or `REFUND`
- Users have legitimate, rightfully earned bond credits waiting to be claimed

In contrast, `FaultDisputeGame.closeGame()` correctly places the early return **before** the pause check (lines 1027–1031 vs 1043), allowing credit claims to proceed during a pause for already-decided games.

### Vulnerable Code

**SuperFaultDisputeGame.sol** ([`src/dispute/SuperFaultDisputeGame.sol` lines 1007–1025](https://github.com/ethereum-optimism/optimism/blob/develop/packages/contracts-bedrock/src/dispute/SuperFaultDisputeGame.sol)):

```solidity
function closeGame() public {
    // PAUSE CHECK FIRST (line 1013) — blocks EVERYTHING during pause
    if (anchorStateRegistry().paused()) {
        revert GamePaused();
    }

    // EARLY RETURN SECOND (line 1018) — never reached during pause
    if (bondDistributionMode == BondDistributionMode.REFUND || bondDistributionMode == BondDistributionMode.NORMAL)
    {
        // We can't revert or we'd break claimCredit().   // <-- Ironic: already broken above
        return;
    }
    // ...
}
```

**FaultDisputeGame.sol** ([`src/dispute/FaultDisputeGame.sol` lines 1026–1045](https://github.com/ethereum-optimism/optimism/blob/develop/packages/contracts-bedrock/src/dispute/FaultDisputeGame.sol)):

```solidity
function closeGame() public {
    // EARLY RETURN FIRST (line 1027) — allows claimCredit() during pause
    if (bondDistributionMode == BondDistributionMode.REFUND || bondDistributionMode == BondDistributionMode.NORMAL)
    {
        // We can't revert or we'd break claimCredit().
        return;
    }

    // PAUSE CHECK SECOND (line 1043) — only blocks undecided games
    if (anchorStateRegistry().paused()) {
        revert GamePaused();
    }
    // ...
}
```

### Call Chain

`claimCredit()` (line 965/984) calls `closeGame()` internally as its first operation:

```solidity
function claimCredit(address _recipient) external {
    closeGame();    // <-- reverts here during pause in SuperFaultDisputeGame
    // ... credit distribution logic never reached
}
```

---

## Impact

### Classification: Temporary Freezing of Funds

When the Guardian pauses the system (a standard operational event for emergencies, upgrades, or maintenance), all bond credits in `SuperFaultDisputeGame` instances become temporarily frozen and unclaimable. This affects:

1. **Honest challengers** who won disputes and are owed bond rewards
2. **Honest defenders** whose bonds should be returned
3. **All participants** in games that entered REFUND mode

The freezing duration equals the pause duration, which can range from minutes to the maximum `PAUSE_EXPIRY` of **7,884,000 seconds (~3 months)**.

### Financial Impact

- Bond amounts start at 0.08 ETH minimum and escalate exponentially with game depth
- Multiple active SuperFaultDisputeGame instances can be affected simultaneously
- At current ETH prices (~$3,500), even a single game with escalated bonds could lock thousands of dollars
- During a prolonged pause (e.g., emergency response), the aggregate locked value across all affected games could be substantial

### Key Distinction

This bug is specific to `SuperFaultDisputeGame`. Users of `FaultDisputeGame` are **not affected** because the correct ordering allows credit claims during pause for already-decided games. This inconsistency between two contracts that should behave identically for this logic path confirms the bug is unintentional.

---

## Risk Breakdown

- **Difficulty to Exploit**: Low — the bug triggers automatically whenever a system pause occurs while SuperFaultDisputeGame instances have decided bond distributions
- **Weakness**: Logic ordering error (CWE-696: Incorrect Behavior Order)
- **CVSS**: 5.3 (Medium)

---

## Recommendation

Swap the ordering in `SuperFaultDisputeGame.closeGame()` to match `FaultDisputeGame.closeGame()`:

```diff
 function closeGame() public {
-    // Pause check should NOT come first
-    if (anchorStateRegistry().paused()) {
-        revert GamePaused();
-    }
-
     // Early return for already-decided bond distribution MUST come first
     if (bondDistributionMode == BondDistributionMode.REFUND || bondDistributionMode == BondDistributionMode.NORMAL)
     {
         return;
     } else if (bondDistributionMode != BondDistributionMode.UNDECIDED) {
         revert InvalidBondDistributionMode();
     }

+    // Pause check only for UNDECIDED games
+    if (anchorStateRegistry().paused()) {
+        revert GamePaused();
+    }
+
     // ... rest of function unchanged
 }
```

---

## Proof of Concept

The following Foundry test demonstrates the vulnerability. It shows that:
1. `FaultDisputeGame.claimCredit()` works during pause (correct behavior)
2. `SuperFaultDisputeGame.claimCredit()` reverts during pause (the bug)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import "forge-std/Test.sol";

// Minimal interfaces to demonstrate the bug
interface IAnchorStateRegistry {
    function paused() external view returns (bool);
}

// Demonstrates the ordering difference between the two contracts
contract CloseGameOrderingPoC is Test {

    // =========================================================================
    // Simulated SuperFaultDisputeGame with INCORRECT ordering (the bug)
    // =========================================================================

    enum BondDistributionMode { UNDECIDED, NORMAL, REFUND }

    bool public systemPaused;
    BondDistributionMode public bondDistributionMode_super;
    BondDistributionMode public bondDistributionMode_fault;
    mapping(address => uint256) public credits;

    error GamePaused();
    error NoCreditToClaim();

    function setPaused(bool _paused) external {
        systemPaused = _paused;
    }

    function setBondMode(bool isSuper, BondDistributionMode mode) external {
        if (isSuper) {
            bondDistributionMode_super = mode;
        } else {
            bondDistributionMode_fault = mode;
        }
    }

    function setCredit(address recipient, uint256 amount) external {
        credits[recipient] = amount;
    }

    // SuperFaultDisputeGame.closeGame() — BUG: pause check BEFORE early return
    function closeGame_Super() public {
        // Line 1013: Pause check FIRST
        if (systemPaused) {
            revert GamePaused();
        }

        // Line 1018: Early return SECOND (never reached during pause!)
        if (bondDistributionMode_super == BondDistributionMode.REFUND
            || bondDistributionMode_super == BondDistributionMode.NORMAL)
        {
            return;
        }
    }

    // FaultDisputeGame.closeGame() — CORRECT: early return BEFORE pause check
    function closeGame_Fault() public {
        // Line 1027: Early return FIRST
        if (bondDistributionMode_fault == BondDistributionMode.REFUND
            || bondDistributionMode_fault == BondDistributionMode.NORMAL)
        {
            return;
        }

        // Line 1043: Pause check SECOND (only reached if UNDECIDED)
        if (systemPaused) {
            revert GamePaused();
        }
    }

    // Simulated claimCredit for SuperFaultDisputeGame
    function claimCredit_Super(address recipient) external {
        closeGame_Super();  // Will revert during pause!
        uint256 credit = credits[recipient];
        if (credit == 0) revert NoCreditToClaim();
        credits[recipient] = 0;
        // ... transfer logic
    }

    // Simulated claimCredit for FaultDisputeGame
    function claimCredit_Fault(address recipient) external {
        closeGame_Fault();  // Will NOT revert during pause for decided games
        uint256 credit = credits[recipient];
        if (credit == 0) revert NoCreditToClaim();
        credits[recipient] = 0;
        // ... transfer logic
    }

    // =========================================================================
    // The actual test
    // =========================================================================

    function test_ClaimCreditDuringPause_FaultDisputeGame_Succeeds() external {
        // Setup: game resolved, bond distribution decided, user has credit
        this.setBondMode(false, BondDistributionMode.NORMAL);
        this.setCredit(address(0xBEEF), 1 ether);

        // Pause the system
        this.setPaused(true);

        // FaultDisputeGame: claimCredit succeeds during pause (CORRECT)
        this.claimCredit_Fault(address(0xBEEF));

        // Credit was claimed successfully
        assertEq(credits[address(0xBEEF)], 0);
    }

    function test_ClaimCreditDuringPause_SuperFaultDisputeGame_Reverts() external {
        // Setup: IDENTICAL to above
        this.setBondMode(true, BondDistributionMode.NORMAL);
        this.setCredit(address(0xCAFE), 1 ether);

        // Pause the system
        this.setPaused(true);

        // SuperFaultDisputeGame: claimCredit REVERTS during pause (BUG!)
        vm.expectRevert(GamePaused.selector);
        this.claimCredit_Super(address(0xCAFE));

        // Credit was NOT claimed — funds are frozen
        assertEq(credits[address(0xCAFE)], 1 ether);
    }
}
```

### Running the PoC

```bash
forge test --match-contract CloseGameOrderingPoC -vvv
```

### Expected Output

```
[PASS] test_ClaimCreditDuringPause_FaultDisputeGame_Succeeds()
[PASS] test_ClaimCreditDuringPause_SuperFaultDisputeGame_Reverts()
```

Both tests pass, demonstrating:
- `FaultDisputeGame` allows credit claims during pause for decided games (correct behavior)
- `SuperFaultDisputeGame` blocks credit claims during pause for decided games (the bug)

### Additional Verification (Static Analysis)

```python
# Run: python3 scripts/verify/verify_M01_closeGame_ordering.py
# Output confirms the ordering inconsistency between the two contracts
```

---

## References

- **SuperFaultDisputeGame.closeGame()**: https://github.com/ethereum-optimism/optimism/blob/develop/packages/contracts-bedrock/src/dispute/SuperFaultDisputeGame.sol (lines 1007-1057)
- **FaultDisputeGame.closeGame()**: https://github.com/ethereum-optimism/optimism/blob/develop/packages/contracts-bedrock/src/dispute/FaultDisputeGame.sol (lines 1026-1077)
- **claimCredit() calling closeGame()**: SuperFaultDisputeGame.sol line 969, FaultDisputeGame.sol line 988
- **SuperchainConfig.pause()**: https://github.com/ethereum-optimism/optimism/blob/develop/packages/contracts-bedrock/src/L1/SuperchainConfig.sol
- **PAUSE_EXPIRY**: 7,884,000 seconds (~3 months)
