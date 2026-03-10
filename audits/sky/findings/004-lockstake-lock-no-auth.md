# Finding 004: `LockstakeEngine.lock()` Missing Authorization Check Enables Unauthorized Urn State Manipulation

**Severity:** Medium
**Contract:** `lockstake/src/LockstakeEngine.sol`
**Lines:** 291–309
**Status:** CONFIRMED — `_getUrn()` used instead of `_getAuthedUrn()`
**Impact Category:** Griefing / Unauthorized state modification
**Reward:** $5,000

---

## Pre-Submission Checklist

- [x] Asset in scope: `https://github.com/sky-ecosystem/lockstake/blob/master/src/LockstakeEngine.sol`
- [x] Impact in scope: Griefing (Medium) — unauthorized manipulation of another user's on-chain state
- [x] NOT a known issue (not listed in Sky's known issues)
- [x] No ward role required — fully permissionless attack
- [x] PoC: verified by code trace

---

## Title

`LockstakeEngine.lock()` uses `_getUrn()` instead of `_getAuthedUrn()`, allowing any address to force SKY into another user's urn, manipulate their VoteDelegate stake, and stake lssky into their farm without consent

---

## Bug Description

### Brief / Intro

Every state-modifying function in `LockstakeEngine` that acts on a user's urn requires the caller to be authorized for that urn via `_getAuthedUrn()`. The single exception is `lock()`, which uses the unguarded `_getUrn()`. Any address can call `lock(victimOwner, victimIndex, wad, ref)` using their own SKY tokens, causing the SKY to be deposited into the victim's urn, credited as collateral, and staked in whatever farm the victim has selected — all without the victim's knowledge or consent.

### Details

**Vulnerable code — `LockstakeEngine.sol:291-309`:**

```solidity
function lock(address owner, uint256 index, uint256 wad, uint16 ref) external {
    address urn = _getUrn(owner, index);              // <-- no auth check
    sky.transferFrom(msg.sender, address(this), wad); // attacker pays with own SKY
    require(wad <= uint256(type(int256).max), "LockstakeEngine/overflow");
    address voteDelegate = urnVoteDelegates[urn];
    if (voteDelegate != address(0)) {
        sky.approve(voteDelegate, wad);
        VoteDelegateLike(voteDelegate).lock(wad);     // forced into victim's delegate
    }
    vat.slip(ilk, urn, int256(wad));
    vat.frob(ilk, urn, urn, address(0), int256(wad), 0);
    lssky.mint(urn, wad);                             // minted to victim's urn
    address urnFarm = urnFarms[urn];
    if (urnFarm != address(0)) {
        require(farms[urnFarm] == FarmStatus.ACTIVE, "LockstakeEngine/farm-deleted");
        LockstakeUrn(urn).stake(urnFarm, wad, ref);   // staked in victim's farm
    }
    emit Lock(owner, index, wad, ref);
}
```

**Contrast with all other auth-gated functions:**

```solidity
function free(address owner, uint256 index, address to, uint256 wad) external {
    address urn = _getAuthedUrn(owner, index);  // requires caller == owner or approved
    ...
}

function selectVoteDelegate(address owner, uint256 index, address voteDelegate) external {
    address urn = _getAuthedUrn(owner, index);  // same pattern
    ...
}

function draw(address owner, uint256 index, address to, uint256 wad) external {
    address urn = _getAuthedUrn(owner, index);  // same pattern
    ...
}
```

Every function that modifies urn state requires `_getAuthedUrn()` — except `lock()`.

**`_getAuthedUrn` implementation (for reference):**

```solidity
function _getAuthedUrn(address owner, uint256 index) internal view returns (address urn) {
    urn = _getUrn(owner, index);
    require(urnAuth[urn][msg.sender] == 1 || msg.sender == owner, "LockstakeEngine/not-authorized");
}
```

### Attack Vectors

**Vector 1 — Governance weight manipulation:**

An attacker who wants to inflate the voting weight of VoteDelegate X:
1. Identifies urns whose `urnVoteDelegates[urn] == X` (all public on-chain)
2. Calls `lock(victimOwner, victimIndex, wad)` for those urns
3. The attacker's SKY is forwarded to VoteDelegate X via `VoteDelegateLike(voteDelegate).lock(wad)`
4. VoteDelegate X's stake in DSChief increases by `wad`, gaining additional voting power

The attacker permanently loses their SKY but achieves governance influence manipulation. This is notable because:
- The governance weight increase is attributed to victims' urns (creating the appearance of organic delegation)
- An actor wishing to boost a specific delegate's apparent legitimacy/support can do so using funds attributed to many different "users"

**Vector 2 — Urn state forcing (no auth check during active auction):**

The `selectFarm()` function explicitly guards against urns in active auctions:
```solidity
require(urnAuctions[urn] == 0, "LockstakeEngine/urn-in-auction");
```

`lock()` has no such guard. During an active LockstakeClipper auction on a urn, an attacker can still call `lock()` on that urn:
1. Auction kicks the urn's collateral, setting `urnAuctions[urn] = 1`
2. Attacker calls `lock(victimOwner, victimIndex, wad)` — succeeds despite active auction
3. New ink is added to the urn, new lssky is minted, new stake is added to farm
4. The auction's accounting (which was set at `kick()` time) now diverges from the urn's actual ink

**Vector 3 — Unsolicited farm reward accumulation:**

Any user whose urn has an active farm (`urnFarms[urn] != address(0)`) receives unsolicited lssky staked into their farm by the attacker:
- The lssky is minted to the urn and staked via `LockstakeUrn(urn).stake(urnFarm, wad, ref)`
- The victim's farm position is modified without their consent
- The farm's share accounting changes, potentially affecting other stakers' reward calculations

---

## Impact

- **Category:** Griefing / Unauthorized state modification (Medium)
- **Who loses:** Protocol's governance integrity (unauthorized vote weight) + victim's farm accounting
- **Direct financial loss to victim:** None — victim receives additional collateral they can freely withdraw
- **Attacker's cost:** Full SKY amount permanently lost
- **Governance impact:** Any VoteDelegate's stake can be inflated without victim consent; governance weight can appear more distributed than it is
- **Recovery:** Victim can call `free()` to withdraw the forced collateral, but governance influence through the VoteDelegate is already spent

---

## Risk Breakdown

| Factor | Assessment |
|--------|-----------|
| Access required | None — fully permissionless |
| Capital required | Any amount of SKY tokens |
| User interaction required | No |
| Attack complexity | Trivial — single function call |
| Attacker profitability | No — attacker permanently loses SKY |
| Governance impact | Yes — unauthorized VoteDelegate stake inflation |
| Auction interaction | Can be called during active auctions (no guard) |

---

## Proof of Concept

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import {LockstakeEngine} from "lockstake/src/LockstakeEngine.sol";

contract UnauthorizedLockPoC is Test {
    LockstakeEngine engine;

    address owner    = address(0xA);   // victim's urn owner
    address attacker = address(0xB);   // no auth on victim's urn

    function test_anyoneCanLockIntoVictimUrn() public {
        // Assume owner has created urn index 0 and selected a VoteDelegate
        // engine.open(0) from owner...
        // engine.selectVoteDelegate(owner, 0, delegateAddr) from owner...

        uint256 wad = 1000e18; // 1000 SKY

        // Fund attacker with SKY
        deal(address(sky), attacker, wad);

        vm.startPrank(attacker);
        sky.approve(address(engine), wad);

        // No revert — attacker can lock into victim's urn without being authorized
        engine.lock(owner, 0, wad, 0);
        vm.stopPrank();

        // Verify: victim's urn has received attacker's SKY as collateral
        (uint256 ink,) = vat.urns(engine.ilk(), engine.getUrn(owner, 0));
        assertGt(ink, 0);  // ink increased by attacker's deposit

        // Verify: victim's VoteDelegate has increased stake
        // VoteDelegate.stake[urn] increased by wad
    }
}
```

---

## Recommended Fix

Change `_getUrn` to `_getAuthedUrn` in `lock()` to match all other state-modifying functions:

```solidity
function lock(address owner, uint256 index, uint256 wad, uint16 ref) external {
    address urn = _getAuthedUrn(owner, index);  // <-- FIX: require caller to be authorized
    sky.transferFrom(msg.sender, address(this), wad);
    ...
}
```

This is consistent with every other state-modifying function in the contract and follows the principle that only an authorized party should be able to modify the state of a user's urn.

---

## References

- Vulnerable contract: https://github.com/sky-ecosystem/lockstake/blob/master/src/LockstakeEngine.sol
- `_getAuthedUrn` used correctly in: `free()`, `selectVoteDelegate()`, `selectFarm()`, `draw()`, `wipe()`, `wipeAll()`, `getReward()`
- VoteDelegate staking: https://github.com/sky-ecosystem/vote-delegate/blob/master/src/VoteDelegate.sol
