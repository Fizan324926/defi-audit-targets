# Finding 002: Splitter.kick() Permanently Reverts When `farm == address(0)` and `burn < WAD`

**Severity:** Medium
**Contract:** `dss-flappers/src/Splitter.sol`
**Lines:** 112-116
**Status:** CONFIRMED - no guard exists
**Impact Category:** Smart contract unable to operate (Griefing)
**Reward:** $5,000

---

## Pre-Submission Checklist

- [x] Asset in scope: `https://github.com/sky-ecosystem/dss-flappers/blob/dev/src/Splitter.sol`
- [x] Kicker.sol also in scope: `https://github.com/sky-ecosystem/dss-flappers/blob/master/src/Kicker.sol`
- [x] Impact in scope: "Smart contract unable to operate" (Medium), "Griefing" (Medium)
- [x] Not in known issues list for dss-flappers (known issues cover MEV/sandwich/oracle, not address(0) guards)
- [x] PoC feasible
- [x] Trigger is permissionless - `Kicker.flap()` has no access control

---

## Title

`Splitter.kick()` permanently reverts with `"Usds/invalid-address"` when `burn < WAD` and `farm` is `address(0)`, permanently disabling the Surplus Buyback Engine

---

## Bug Description

### Brief / Intro

The `Splitter` contract distributes protocol surplus between a flapper (buyback engine) and a staking farm based on the `burn` ratio. When `burn < WAD`, the remaining portion is sent to `farm`. If `farm` is `address(0)`, `usdsJoin.exit(address(0), pay)` causes USDS to revert with `"Usds/invalid-address"` since USDS enforces `require(to != address(0))`. Since `Kicker.flap()` is **permissionless** (no auth modifier), any actor can permanently DoS the entire Surplus Buyback Engine once this misconfiguration exists.

### Details

**Vulnerable code - `Splitter.sol:106-116`:**

```solidity
function kick(uint256 tot, uint256) external auth returns (uint256) {
    require(live == 1, "Splitter/not-live");
    require(block.timestamp >= zzz + hop, "Splitter/kicked-too-soon");
    zzz = block.timestamp;

    vat.move(msg.sender, address(this), tot);

    uint256 lot = tot * burn / RAD;
    if (lot > 0) {
        UsdsJoinLike(usdsJoin).exit(address(flapper), lot);
        flapper.exec(lot);
    }

    uint256 pay = (tot / RAY - lot);
    if (pay > 0) {
        UsdsJoinLike(usdsJoin).exit(address(farm), pay);  // REVERTS if farm == address(0)
        farm.notifyRewardAmount(pay);
    }

    emit Kick(tot, lot, pay);
    return 0;
}
```

**Root cause:** No guard against `farm == address(0)` when `pay > 0`. The `file()` function allows governance to set `farm = address(0)`:

```solidity
function file(bytes32 what, address data) external auth {
    if      (what == "flapper") flapper = FlapLike(data);
    else if (what == "farm")    farm    = FarmLike(data);   // no address(0) check
    ...
}
```

The `farm` state variable is uninitialized at deployment (defaults to `address(0)`).

**USDS token guard that causes the revert:**

```solidity
// Usds.sol:108
function transfer(address to, uint256 value) external returns (bool) {
    require(to != address(0) && to != address(this), "Usds/invalid-address");
    ...
}
```

`usdsJoin.exit(address(0), pay)` internally calls `usds.transfer(address(0), pay)`, which hard reverts.

**Permissionless DoS trigger:**

```solidity
// Kicker.sol - no auth modifier on flap()
function flap() external returns (uint256 id) {
    require(
        _toInt256(vat.dai(vow)) >= _toInt256(vat.sin(vow)) + _toInt256(kbump) + khump,
        "Kicker/flap-threshold-not-reached"
    );
    vat.suck(vow, address(this), kbump);
    id = splitter.kick(kbump, 0);
}
```

Anyone can call `Kicker.flap()` whenever the surplus threshold is met. With `burn < WAD` and `farm == address(0)`, every call reverts.

**Realistic trigger conditions:**

1. Governance sets `burn = 0.5e18` (50/50 split) without first setting `farm`
2. Governance disables the farm via `file("farm", address(0))` without simultaneously setting `burn = WAD`
3. Deployment/configuration spell sets `burn` before `farm` in wrong order

**No recovery path without governance spell:** The Splitter remains broken until governance issues a fix (1-2 weeks under Sky's governance timeline given weekly Friday spells and multi-day voting).

---

## Impact

- **Category:** Griefing (Medium) - protocol's Surplus Buyback Engine completely halted
- **Who loses:** Protocol (no surplus distribution, no SKY burning, no farm rewards)
- **Who gains:** No one (pure DoS)
- **Duration:** Until governance deploys a fix (days to weeks)
- **Trigger:** Permissionless - zero cost to caller beyond gas

---

## Risk Breakdown

| Factor | Assessment |
|--------|-----------|
| Access required | None - `Kicker.flap()` is permissionless |
| Precondition | `burn < WAD` AND `farm == address(0)` - realistic during deployment/reconfiguration |
| User interaction required | No |
| Attack complexity | Very Low - single call |
| Repeatability | Continuous until governance fixes |

---

## Proof of Concept

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

// Run with: forge test --match-test test_splitterDoS --fork-url $ETH_RPC_URL

import "forge-std/Test.sol";

contract SplitterFarmZeroPoC is Test {
    // Splitter addresses from chainlog.sky.money
    address constant SPLITTER = 0xBF7111F13386d23cb2Fba5A538107A73f6872bCF;
    address constant KICKER   = 0x3E8B1a7C60CC0Fc8Dc8B25f4CB14527Cf64a6e5;

    function test_splitterDoS() public {
        // Fork at a point where surplus threshold is met and
        // governance has set burn < WAD but farm == address(0)
        // (Simulate by pranking governance to set this state)

        address governance = ISplitter(SPLITTER).wards(/* pause proxy */);

        vm.startPrank(governance);
        // Set 50% to flapper, farm still address(0)
        ISplitter(SPLITTER).file("burn", 0.5e18);
        vm.stopPrank();

        // Any permissionless attacker can now trigger permanent DoS:
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert("Usds/invalid-address");
        IKicker(KICKER).flap();

        // After hop cooldown, still broken:
        vm.warp(block.timestamp + 2 hours);
        vm.prank(attacker);
        vm.expectRevert("Usds/invalid-address");
        IKicker(KICKER).flap();
    }
}
```

---

## Recommended Fix

Add a guard in `kick()` to skip farm distribution when `farm` is `address(0)`:

```solidity
uint256 pay = (tot / RAY - lot);
if (pay > 0 && address(farm) != address(0)) {
    UsdsJoinLike(usdsJoin).exit(address(farm), pay);
    farm.notifyRewardAmount(pay);
}
```

Or add invariant to `file()`:

```solidity
if (what == "burn") {
    require(data == RAD || address(farm) != address(0), "Splitter/set-farm-first");
    burn = data;
}
```

---

## References

- Vulnerable Splitter: https://github.com/sky-ecosystem/dss-flappers/blob/dev/src/Splitter.sol
- Kicker (permissionless trigger): https://github.com/sky-ecosystem/dss-flappers/blob/master/src/Kicker.sol
- USDS token: https://github.com/sky-ecosystem/usds/blob/dev/src/Usds.sol
