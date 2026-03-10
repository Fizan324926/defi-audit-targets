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

Foundry fork test against the live Bean/WETH Basin Well on Arbitrum. Pinned to block 440420446 for reproducibility. All swaps execute on the actual deployed Well contract — no mock AMM, no simplified math.

### How to run

```
cd PoC/
forge test --fork-url https://arb1.arbitrum.io/rpc -vvv
```

### Contracts (Arbitrum mainnet)

| Contract | Address |
|----------|---------|
| Beanstalk Diamond | `0xD1A0060ba708BC4BCD3DA6C37EFa8deDF015FB70` |
| Bean | `0xBEA0005B8599265D41256905A9B3073D397812E4` |
| WETH | `0x82aF49447D8a07e3bd95BD0d56f35241523fBab1` |
| Bean/WETH Well | `0xBeA00Aa8130aCaD047E137ec68693C005f8736Ce` |

### Test results (5 passing)

```
[PASS] test_sunriseIsPermissionless()
  sunrise() revert reason: Season: Still current Season.
  -> Confirms any address can call. No access control.

[PASS] test_spotReservesManipulable()
  bean reserve before: 38330626648
  bean reserve after:  31222866607  (18% drop from a single 1 WETH swap)
  -> Spot reserves are instantly manipulable in the same block.

[PASS] test_sopSandwichExtraction()
  fair WETH to stalkholders:     0.209 WETH (~$425)
  attacked WETH to stalkholders: 0.159 WETH (~$324)
  stalkholder loss:              0.050 WETH (~$101, 23%)
  attacker Bean profit:          475 Bean

[PASS] test_extremeManipulationDoesNotRevert()
  fair SOP output:  0.209 WETH (~$425)
  bad SOP output:   0.066 WETH (~$134)
  stalkholder loss: 68%
  swap reverted:    NO (minAmountOut=0 accepts anything)

[PASS] test_atomicExploitViaContract()
  Deploys AtomicFloodExploit contract on-chain.
  Contract front-runs pool, SOP executes at degraded rate, contract back-runs.
  23% extraction. No mempool needed.
```

### What the tests prove

**test_sunriseIsPermissionless**: Confirms `sunrise()` has no access control. Any address can call it. The revert is "Still current Season" — a timing check, not authorization.

**test_spotReservesManipulable**: A single 1 WETH swap ($2,036) changes Bean reserves by 18% in the same block. This is what `getWellsByDeltaB()` reads to decide how many sopBeans to mint.

**test_sopSandwichExtraction**: Full attack sequence. Attacker sells 15% of Bean reserve to drain WETH, SOP swap executes at degraded rate, attacker buys Bean back cheap. Stalkholders lose 23% of their WETH.

**test_extremeManipulationDoesNotRevert**: An 80% Bean dump drains 44% of WETH from the pool. The SOP swap still succeeds because `minAmountOut = 0`. With slippage protection this would correctly revert.

**test_atomicExploitViaContract**: Deploys a real smart contract (AtomicFloodExploit) that front-runs, triggers sunrise, and back-runs. Proves the attack is atomic — no mempool, no front-running of other users.

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
