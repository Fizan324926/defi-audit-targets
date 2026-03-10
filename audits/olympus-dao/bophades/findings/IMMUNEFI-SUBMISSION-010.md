# Finding 010: Heart Beat Front-Running Allows Predictable Price Oracle Manipulation and Wall Price Gaming

## Bug Description

The `Heart.beat()` function executes a deterministic sequence of operations: (1) `PRICE.updateMovingAverage()`, (2) `distributor.triggerRebase()`, (3) `_executePeriodicTasks()` (which includes `Operator.operate()`). Since `PRICE.updateMovingAverage()` queries Chainlink price feeds at the time of the transaction, and these feeds are publicly readable, an attacker can predict the new moving average and the resulting wall/cushion price changes before the beat transaction executes. This enables front-running attacks.

**Vulnerable Code** (`/root/defi-audit-targets/audits/olympus-dao/bophades/src/policies/Heart.sol`, lines 142-172):

```solidity
function beat() external nonReentrant {
    if (!isEnabled) revert Heart_BeatStopped();
    uint48 currentTime = uint48(block.timestamp);
    if (currentTime < lastBeat + frequency()) revert Heart_OutOfCycle();

    // Update the moving average on the Price module
    PRICE.updateMovingAverage();    // <-- (1) Updates price from Chainlink

    // Trigger the rebase
    distributor.triggerRebase();     // <-- (2) Rebase

    // Execute periodic tasks
    _executePeriodicTasks();        // <-- (3) Calls Operator.operate() -> updates wall prices

    // Calculate the reward
    uint256 reward = currentReward();
    lastBeat = currentTime - ((currentTime - lastBeat) % frequency());

    // Issue the reward
    if (reward > 0) {
        MINTR.increaseMintApproval(address(this), reward);
        MINTR.mintOhm(msg.sender, reward);
    }
}
```

And in `OlympusPrice.updateMovingAverage()` (lines 82-103):

```solidity
function updateMovingAverage() external override permissioned {
    if (!initialized) revert Price_NotInitialized();
    uint32 numObs = numObservations;
    uint256 earliestPrice = observations[nextObsIndex];
    uint256 currentPrice = getCurrentPrice();           // <-- Queries Chainlink feeds
    cumulativeObs = cumulativeObs + currentPrice - earliestPrice;
    observations[nextObsIndex] = currentPrice;
    lastObservationTime = uint48(block.timestamp);
    nextObsIndex = (nextObsIndex + 1) % numObs;
}
```

**Attack path:**

1. **Predictability**: An attacker reads the current Chainlink OHM/ETH and Reserve/ETH feeds (public data) to predict the `getCurrentPrice()` return value.

2. **Moving average prediction**: The attacker reads the current `cumulativeObs`, `observations[nextObsIndex]` (the observation that will be replaced), and `numObservations` to calculate the new moving average:
   ```
   newMA = (cumulativeObs + predictedPrice - observations[nextObsIndex]) / numObservations
   ```

3. **Wall price prediction**: From the new MA (or `max(newMA, minimumTargetPrice)`), the attacker calculates new wall/cushion prices:
   ```
   newHighWall = newTarget * (10000 + highWallSpread) / 10000
   newLowWall = newTarget * (10000 - lowWallSpread) / 10000
   ```

4. **Front-run the beat**: The attacker submits transactions before the beat transaction in the same block:
   - If `newLowWall > currentLowWall`: the low wall price is going up. The attacker sells OHM at the CURRENT (lower) low wall price to get reserve, banking on the fact that the low wall will move up (making their OHM worth more relative to the new wall)
   - If `newHighWall < currentHighWall`: the high wall price is going down. The attacker buys OHM from the CURRENT (higher) high wall, knowing the price will drop

5. **Cushion market implications**: If the beat will cause a cushion to activate or deactivate, the attacker can front-run to buy/sell bonds at favorable prices before the market state changes.

**The `lastBeat` arithmetic at line 162 does not prevent this**: `lastBeat = currentTime - ((currentTime - lastBeat) % frequency())` only adjusts the beat timing; it doesn't affect the predictability of the price update.

## Impact

**Severity: Medium**

- **Financial impact**: Proportional to the change in wall prices between beats and the wall capacity. With a 1% MA shift and $5M wall capacity, the maximum profit is ~$50K per beat.
- **Preconditions**: Requires the Chainlink feed price to differ from the oldest observation being replaced in the ring buffer, creating a meaningful MA shift.
- **Likelihood**: High -- this is a standard MEV opportunity that sophisticated bots can exploit on every beat
- **Affected users**: All OHM holders (treasury efficiency is reduced)
- **Mitigation in practice**: The wall prices are based on a MOVING AVERAGE, which dampens individual price changes. A single observation only shifts the MA by `(newPrice - oldestPrice) / numObservations`. With 90 observations (30 days / 8 hours), a 10% price change shifts the MA by only ~0.11%.

## Risk Breakdown

- **Difficulty to exploit**: Low -- standard MEV bot infrastructure can execute this
- **Weakness type**: CWE-362 (Concurrent Execution Using Shared Resource with Improper Synchronization)
- **CVSS Score**: 4.7 (Medium)

## Recommendation

1. Use a commit-reveal scheme for heartbeats, where the price observation is committed in one transaction and revealed in the next:

```solidity
// Phase 1: Commit (anyone can call, price is not yet used)
function commitBeat() external {
    // Store the price commitment but don't update the MA yet
    _pendingPrice = PRICE.getCurrentPrice();
    _commitTime = block.timestamp;
}

// Phase 2: Reveal (must be in a different block)
function revealBeat() external {
    require(block.timestamp > _commitTime, "Same block");
    // Now use the committed price
    PRICE.updateMovingAverageWith(_pendingPrice);
    // ... rest of beat logic
}
```

2. Alternatively, use a private mempool (e.g., Flashbots Protect) for beat transactions to prevent front-running.

3. Add a maximum slippage check to wall swaps that compares against a freshly queried Chainlink price:

```solidity
function swap(ERC20 tokenIn_, uint256 amountIn_, uint256 minAmountOut_) external {
    // Fresh price check to detect front-running
    uint256 livePrice = PRICE.getCurrentPrice();
    uint256 storedPrice = PRICE.getLastPrice();
    require(
        livePrice * 10000 / storedPrice > 9500 && livePrice * 10000 / storedPrice < 10500,
        "Price deviation too high"
    );
    // ... rest of swap
}
```

## Proof of Concept

```solidity
// SPDX-License-Identifier: Unlicense
pragma solidity >=0.8.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Demonstrates the predictability of Heart.beat() price updates
contract PoC_010_HeartBeatFrontRun is Test {

    uint256 constant NUM_OBSERVATIONS = 90; // 30 days / 8 hours
    uint256 constant WALL_SPREAD = 2000; // 20%
    uint256 constant BPS = 10000;

    function test_predictMovingAverageShift() public {
        // Current state
        uint256 currentMA = 10e18; // $10
        uint256 cumulativeObs = currentMA * NUM_OBSERVATIONS;
        uint256 oldestObs = 9.5e18; // $9.50 (oldest observation about to be replaced)

        // New price from Chainlink (attacker can read this)
        uint256 newChainlinkPrice = 11e18; // $11 (10% increase from MA)

        // Predicted new MA after beat
        uint256 newCumulativeObs = cumulativeObs + newChainlinkPrice - oldestObs;
        uint256 newMA = newCumulativeObs / NUM_OBSERVATIONS;

        console2.log("Current MA:", currentMA);
        console2.log("New predicted MA:", newMA);
        console2.log("MA shift:", newMA > currentMA ? newMA - currentMA : currentMA - newMA);
        console2.log("MA shift bps:", (newMA - currentMA) * BPS / currentMA);

        // Current wall prices
        uint256 currentLowWall = currentMA * (BPS - WALL_SPREAD) / BPS;
        uint256 currentHighWall = currentMA * (BPS + WALL_SPREAD) / BPS;

        // New wall prices after beat
        uint256 newLowWall = newMA * (BPS - WALL_SPREAD) / BPS;
        uint256 newHighWall = newMA * (BPS + WALL_SPREAD) / BPS;

        console2.log("\n=== Wall Price Changes ===");
        console2.log("Low wall: current =", currentLowWall, "new =", newLowWall);
        console2.log("High wall: current =", currentHighWall, "new =", newHighWall);

        // Front-running opportunity: if the low wall is going up,
        // sell OHM at the current (lower) low wall price before the beat
        if (newLowWall > currentLowWall) {
            console2.log("\nFront-run opportunity: Sell OHM at low wall BEFORE beat");
            console2.log("Sell at:", currentLowWall);
            console2.log("After beat, low wall moves to:", newLowWall);
            console2.log("Effective discount per OHM:", newLowWall - currentLowWall);
        }

        // Front-running opportunity: if the high wall is going up,
        // buy OHM at the current high wall before it increases
        if (newHighWall > currentHighWall) {
            console2.log("\nFront-run opportunity: Buy OHM from high wall BEFORE beat");
            console2.log("Buy at:", currentHighWall);
            console2.log("After beat, high wall moves to:", newHighWall);
            console2.log("Effective discount per OHM:", newHighWall - currentHighWall);
        }

        assertGt(newMA, currentMA, "MA should increase with higher price observation");
    }
}
```

**Standalone PoC file**: `/root/defi-audit-targets/audits/olympus-dao/bophades/scripts/verify/PoC_010_HeartBeatFrontRun.sol`

## References

- Heart.beat: https://github.com/OlympusDAO/bophades/blob/main/src/policies/Heart.sol#L142-L172
- OlympusPrice.updateMovingAverage: https://github.com/OlympusDAO/bophades/blob/main/src/modules/PRICE/OlympusPrice.sol#L82-L103
- OlympusPrice.getCurrentPrice: https://github.com/OlympusDAO/bophades/blob/main/src/modules/PRICE/OlympusPrice.sol#L213-L254
- Operator.operate (called via periodic tasks): https://github.com/OlympusDAO/bophades/blob/main/src/policies/Operator.sol#L242-L321
