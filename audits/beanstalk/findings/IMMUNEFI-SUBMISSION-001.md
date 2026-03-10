# SOP/Flood swap has no slippage protection and uses manipulable spot reserves

## Bug Description

`sopWell()` in LibFlood.sol swaps newly minted sopBeans for WETH during Flood events. It passes `minAmountOut = 0` to the Well (line 362). There is no floor on the exchange rate. Any amount of WETH — including nearly zero — is accepted.

```solidity
// LibFlood.sol:358-365
uint256 amountOut = IWell(wellDeltaB.well).swapFrom(
    BeanstalkERC20(s.sys.tokens.bean),
    sopToken,
    sopBeans,
    0,                    // <-- no slippage protection
    address(this),
    type(uint256).max
);
```

On top of that, `getWellsByDeltaB()` (line 270) decides how many sopBeans to mint by reading spot reserves via `LibDeltaB.currentDeltaB()`, which calls `IWell.getReserves()` (LibDeltaB.sol:46-57). Spot reserves change instantly within the same block. Every other critical path in Beanstalk uses TWA reserves from the MultiFlowPump for this exact reason — Bean minting, Convert, BDV. The Flood path is the exception.

```solidity
// LibFlood.sol:270
wellDeltaBs[i] = WellDeltaB(wells[i], LibDeltaB.currentDeltaB(wells[i]));
```

`sunrise()` is fully permissionless (SeasonFacet.sol:39). No access control, no EOA check. The fork test confirms this — calling from a random address reverts with "Season: Still current Season." (a timing check), not an access control error. This means the attacker controls exactly when Flood triggers.

## Impact

An attacker deploys a contract that:

1. Sells Bean into the Well (drains WETH, degrades the exchange rate)
2. Calls `sunrise()` which triggers `sopWell()` internally — the SOP swap executes at the degraded rate with zero slippage protection
3. Buys Bean back from the Well (Bean is cheap because the pool is flooded with it)

All three steps happen in a single atomic transaction. No mempool monitoring needed. No front-running of other users' transactions. The attacker IS the caller. On Arbitrum there is no public mempool anyway (sequencer processes transactions).

The fork test against the live Bean/WETH Well shows:
- **23% extraction** with a 15% Bean reserve front-run
- **68% extraction** with an 80% Bean dump (still does not revert)
- Attacker profits 475 Bean per cycle at current reserves

The extraction rate scales with the attacker's capital. There is no upper bound because there is no slippage check. With proper slippage protection, the SOP swap would revert instead of executing at a terrible rate.

Stalkholders lose their SOP WETH proceeds. This is theft of unclaimed yield.

Additionally, the spot reserve manipulation inflates deltaB before sunrise(), causing Beanstalk to mint more sopBeans than the real economic imbalance warrants. This dilutes Bean supply unnecessarily.

### Conditions

Flood requires: Bean price above peg, pod rate under 5%, raining for 2+ consecutive seasons. These conditions have occurred historically and are part of normal Beanstalk economic cycles.

### Why this is not a front-running attack

The program excludes "impacts that require users to send transactions through the public mempool." This vulnerability does not require that. The attacker:
- Deploys a smart contract
- Calls it when Flood conditions are met
- The contract calls `sunrise()` directly (permissionless)
- Everything happens atomically in one transaction
- No other user's pending transaction is being front-run

The root cause is a code defect — the protocol swaps with zero slippage protection and uses manipulable reserves for price calculation.

## Proof of Concept

Everything below was run against the live Bean/WETH Basin Well on Arbitrum, forked at block 440420446. ETH was $2,040 at that block. All swaps go through the actual deployed Well contract. Full source code and setup instructions are in the PoC gist.

```
forge test --fork-url https://arb1.arbitrum.io/rpc -vvv
```

**First I checked if sunrise() has access control.** I called it from a random address:

```
sunrise() revert reason: Season: Still current Season.
```

Not "Unauthorized." Not "Only owner." It is a timing check. When the season is ready, anyone can call it.

**Then I checked if spot reserves are manipulable.** I swapped 1 WETH ($2,040) into the Well and read reserves before and after:

```
bean reserve before: 38330626648
bean reserve after:  31222866607
bean drop:           18%
```

A single $2,040 swap moved Bean reserves by 18% in the same block. This is what `getWellsByDeltaB()` reads to decide how many sopBeans to mint.

**Then I ran the actual attack.** I simulated a realistic SOP (5% of Bean reserves) with and without a sandwich. The attacker sells 15% of Bean reserves into the Well before the SOP, then buys Bean back after:

```
fair WETH to stalkholders:     209180271072758757 (~$425)
attacked WETH to stalkholders: 159158901847673638 (~$324)
stalkholder WETH loss:          50021369225085119 (~$101)
extraction rate:               23%
attacker Bean profit:          475530331
```

Stalkholders got $324 instead of $425. The attacker walked away with 475 extra Bean. The swap did not revert because `minAmountOut = 0`.

**I pushed it further.** With an 80% Bean dump before the SOP:

```
fair SOP output:  209180271072758757 (~$425)
bad SOP output:    65957743108011792 (~$134)
stalkholder loss: 68%
swap reverted:    NO
```

68% stolen. Still did not revert. There is no amount of manipulation that causes a revert when `minAmountOut = 0`.

**Finally I deployed an actual exploit contract** (`AtomicFloodExploit`) on the fork. It front-runs, the SOP executes at the degraded rate, then it back-runs. Same 23% extraction. No mempool monitoring needed — the contract calls `sunrise()` directly.

```
exploit contract:  0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f
extraction:        23%
attacker profit:   475530331 Bean
mempool needed:    NO
```

## Recommendation

Both fixes should be applied together:

### 1. Use TWA reserves for SOP amount calculation

```diff
 wellDeltaBs[i] = WellDeltaB(
     wells[i],
-    LibDeltaB.currentDeltaB(wells[i])
+    LibDeltaB.cappedReservesDeltaB(wells[i])
 );
```

### 2. Add slippage protection to the SOP swap

```diff
+uint256 expectedOut = IWellFunction(wf.target).getSwapOut(
+    twaReserves, sopBeans, beanIdx, sopTokenIdx, wf.data
+);
+uint256 minAmountOut = expectedOut * 95 / 100;
+
 uint256 amountOut = IWell(wellDeltaB.well).swapFrom(
     BeanstalkERC20(s.sys.tokens.bean),
     sopToken,
     sopBeans,
-    0,
+    minAmountOut,
     address(this),
     type(uint256).max
 );
```

## References

- LibFlood.sopWell(): lines 348-374
- LibFlood.getWellsByDeltaB(): lines 256-281
- LibDeltaB.currentDeltaB(): lines 46-57
- LibDeltaB.cappedReservesDeltaB(): lines 74-98
- SeasonFacet.sunrise(): line 39
