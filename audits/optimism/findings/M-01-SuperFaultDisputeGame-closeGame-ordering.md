# M-01: SuperFaultDisputeGame.closeGame() Blocks Credit Claims During System Pause After Bond Distribution Decided

## Severity: Medium

## Target: Optimism (Immunefi)
- **Program**: https://immunefi.com/bug-bounty/optimism/
- **Max Bounty**: $2,000,042
- **Rules**: Primacy of Impact (Smart Contracts)

## Vulnerability Details

### Summary

`SuperFaultDisputeGame.closeGame()` has an incorrect ordering of checks compared to `FaultDisputeGame.closeGame()`. The pause check executes **before** the early return for already-decided bond distribution modes, causing `claimCredit()` to revert during any system pause -- even when the game is fully resolved and bond distribution was already finalized.

### Root Cause

In `FaultDisputeGame.closeGame()` (lines 1026-1077), the early return for already-decided bond distribution is placed **before** the pause check:

```solidity
// FaultDisputeGame.closeGame() -- CORRECT ordering
function closeGame() public {
    // FIRST: Early return if bond distribution mode already decided
    if (bondDistributionMode == BondDistributionMode.REFUND || bondDistributionMode == BondDistributionMode.NORMAL)
    {
        // We can't revert or we'd break claimCredit().
        return;
    }

    // SECOND: Pause check (only reached if UNDECIDED)
    if (anchorStateRegistry().paused()) {
        revert GamePaused();
    }
    // ...
}
```

In `SuperFaultDisputeGame.closeGame()` (lines 1007-1057), the order is **reversed**:

```solidity
// SuperFaultDisputeGame.closeGame() -- INCORRECT ordering
function closeGame() public {
    // FIRST: Pause check (ALWAYS checked, even if already decided)
    if (anchorStateRegistry().paused()) {
        revert GamePaused();       // <-- Blocks claimCredit() during pause!
    }

    // SECOND: Early return (never reached during pause)
    if (bondDistributionMode == BondDistributionMode.REFUND || bondDistributionMode == BondDistributionMode.NORMAL)
    {
        // We can't revert or we'd break claimCredit().  <-- Ironic: already broken above
        return;
    }
    // ...
}
```

### Impact

Since `claimCredit()` calls `closeGame()` internally (line 965), any system pause blocks ALL credit claims on SuperFaultDisputeGame instances -- even games where:
1. The dispute is fully resolved
2. `closeGame()` was already successfully called
3. Bond distribution mode is already set to NORMAL or REFUND
4. Users have rightful credit balances waiting to be claimed

This creates a **denial-of-service on fund withdrawal** for the duration of the pause.

### Attack Scenario

1. A `SuperFaultDisputeGame` resolves. `closeGame()` is called, setting `bondDistributionMode = NORMAL`.
2. Before honest participants claim their credits, the Guardian pauses the system (for any reason: emergency, upgrade, maintenance).
3. A user calls `claimCredit()` to withdraw their earned bonds.
4. `claimCredit()` -> `closeGame()` -> `anchorStateRegistry().paused()` returns true -> reverts with `GamePaused()`.
5. The user cannot access their funds until the system is unpaused (which could be hours, days, or up to 3 months via the PAUSE_EXPIRY).

### Comparison with FaultDisputeGame

In `FaultDisputeGame.closeGame()`, the early return executes first, bypassing the pause check for already-decided games. Users of FaultDisputeGame **can** claim credits during a system pause if the bond distribution was already decided. This inconsistency between the two game implementations confirms the SuperFaultDisputeGame ordering is a bug.

### Evidence This Is Unintentional

1. **FaultDisputeGame comment** (line 1041-1042) explicitly says: *"If the game has already been closed and a refund mode has been selected, we'll already have returned and we won't hit this revert."* -- This reasoning was not applied to SuperFaultDisputeGame.
2. **SuperFaultDisputeGame comment** (line 1020) still says: *"We can't revert or we'd break claimCredit()"* -- But the pause check above already reverts, breaking claimCredit().
3. **No test coverage** for the paused-after-decided scenario in SuperFaultDisputeGame tests.

## Recommendation

Swap the ordering in `SuperFaultDisputeGame.closeGame()` to match `FaultDisputeGame.closeGame()`:

```solidity
function closeGame() public {
    // Early return FIRST
    if (bondDistributionMode == BondDistributionMode.REFUND || bondDistributionMode == BondDistributionMode.NORMAL)
    {
        return;
    } else if (bondDistributionMode != BondDistributionMode.UNDECIDED) {
        revert InvalidBondDistributionMode();
    }

    // Pause check SECOND (only for undecided games)
    if (anchorStateRegistry().paused()) {
        revert GamePaused();
    }
    // ... rest of logic
}
```

## Files Affected

- `packages/contracts-bedrock/src/dispute/SuperFaultDisputeGame.sol` lines 1007-1057
- Comparison: `packages/contracts-bedrock/src/dispute/FaultDisputeGame.sol` lines 1026-1077
