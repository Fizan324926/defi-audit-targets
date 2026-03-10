# Sky Protocol – Core DSS Security Audit Report

**Scope:**
- `/root/audits/sky-protocol/dss/src/` – all .sol files (vat, dai, join, jug, pot, spot, end, dog, clip, flap, flop, vow, cat, abaci, cure)
- `/root/audits/sky-protocol/dss-flash/src/flash.sol`
- `/root/audits/sky-protocol/dss-auto-line/src/DssAutoLine.sol`
- `/root/audits/sky-protocol/dss-blow2/src/DssBlow2.sol`
- `/root/audits/sky-protocol/dss-cdp-manager/src/DssCdpManager.sol`
- `/root/audits/sky-protocol/dss-cdp-manager/src/GetCdps.sol`
- `/root/audits/sky-protocol/dss-psm/src/` – all .sol files

**Auditor:** Independent security review for Immunefi bug bounty
**Date:** 2026-03-01

---

## Executive Summary

After exhaustive review of every function across all in-scope contracts, no Critical or High severity
exploitable vulnerabilities were found that are not already disqualified by the Sky Protocol Immunefi
scope rules (wards trusted, known issues excluded). Two Medium-severity design observations are
documented below, along with a comprehensive record of every potential finding that was investigated
and eliminated.

---

## Confirmed Findings

### FINDING-01 – Medium: DssAutoLine.exec() Reverts if Global Line Drops Below Ilk's Current Line

**File:** `/root/audits/sky-protocol/dss-auto-line/src/DssAutoLine.sol`, line 145
**Severity:** Medium (temporary DoS – contract unable to operate)

**Vulnerable Code:**
```solidity
// DssAutoLine.sol line 145
vat.file("Line", add(sub(vat.Line(), line), lineNew));
```

**Description:**
exec() computes the new global Line by subtracting the ilk's *current* `line` from `vat.Line()` and
then adding the new `lineNew`. If governance has manually reduced `vat.Line()` (the global ceiling)
to a value below the ilk's currently recorded `line`, `sub(vat.Line(), line)` will underflow and
revert.

**Exploit Path:**
1. Governance sets `vat.Line()` to some value lower than what was previously set for a given ilk
   (e.g., emergency ceiling reduction).
2. exec(_ilk) is now permanently blocked for that ilk because sub(vat.Line(), line) underflows.
3. The ilk's debt ceiling cannot be decreased automatically via DssAutoLine, even if the ilk is
   over its debt ceiling (debt > line). This prevents debt ceiling reductions from being processed.
4. The system is stuck until governance manually files the ilk line via vat.file() to a value at
   or below vat.Line(), or manually raises vat.Line() again.

**Defense Evaluation:**
- The underflow revert is the only protection. There is no guard checking if vat.Line() < line.
- The condition is triggered by a ward action (governance lowering vat.Line()), so the initial
  trigger requires a ward.
- However, the impact — prolonged DoS of DssAutoLine for the ilk — does not require any further
  ward actions. Any unprivileged user calling exec() will continue to get reverts until governance
  manually corrects the state.

**Classification:** Medium — contract unable to operate (DssAutoLine blocked for an ilk), temporary
until governance manually corrects the state. The trigger requires a prior ward action, but the
prolonged DoS persists independently and blocks the autonomous ceiling management that the module
exists to provide.

---

### FINDING-02 – Medium: End.cash() Allows a Single DAI Bag to Redeem from Multiple Ilks

**File:** `/root/audits/sky-protocol/dss/src/end.sol`, lines 442–448
**Severity:** Medium (unfair collateral distribution during global settlement)

**Vulnerable Code:**
```solidity
// end.sol lines 442-448
function cash(bytes32 ilk, uint256 wad) external {
    require(fix[ilk] != 0, "End/fix-ilk-not-defined");
    vat.flux(ilk, address(this), msg.sender, rmul(wad, fix[ilk]));
    out[ilk][msg.sender] = add(out[ilk][msg.sender], wad);
    require(out[ilk][msg.sender] <= bag[msg.sender], "End/insufficient-bag-balance");
    emit Cash(ilk, msg.sender, wad);
}
```

**Description:**
`out[ilk][msg.sender]` is tracked *per ilk*, not as a cumulative total across all ilks.
`bag[msg.sender]` is a single shared limit set by `pack()`. The invariant check
`out[ilk][user] <= bag[user]` is applied independently per ilk, meaning the same bag amount can
be used to claim collateral from every ilk simultaneously.

**Exploit Path:**
1. Global settlement executed; fix[ETH-A], fix[WBTC-A], fix[USDC-A] are all set.
2. Attacker calls pack(1000 WAD) — moves 1000 internal DAI to vow, sets bag[attacker] = 1000.
3. Attacker calls cash(ETH-A, 1000):
   - out[ETH-A][attacker] = 1000 <= bag = 1000 → receives rmul(1000, fix[ETH-A]) ETH collateral.
4. Attacker calls cash(WBTC-A, 1000):
   - out[WBTC-A][attacker] = 1000 <= bag = 1000 → receives WBTC collateral.
5. Attacker calls cash(USDC-A, 1000):
   - out[USDC-A][attacker] = 1000 <= bag = 1000 → receives USDC collateral.
6. For N ilks, the attacker claims N x their proportional share of collateral for 1x DAI packed.

**Defense Evaluation:**
- No per-ilk-aggregated total out tracking exists. The check is purely per-ilk.
- vat.flux will revert once End runs out of collateral for a specific ilk, bounding the total per
  ilk. However, first-movers can drain multiple ilks' collateral pools, leaving nothing for late
  redeemers who arrive after the collateral is exhausted.
- Late DAI holders may find all ilks drained, receiving zero collateral for their packed DAI even
  though the protocol's per-ilk fix values guaranteed them a proportional share.

**Note:** This behavior has been present in the deployed MakerDAO End module since its original
deployment. It appears to be a long-standing design limitation rather than a newly introduced bug.
It is documented here because it produces a real economic impact — theft of unclaimed collateral
from slower DAI holders — observable on-chain during a global settlement event.

---

## Investigated and Eliminated Findings

The following potential issues were identified, analyzed in depth, and determined to be not
exploitable given the actual code, the Immunefi scope rules, or the protocol's economic design.

---

### IE-01: DssFlash – Unchecked Return Value of dai.transferFrom() in flashLoan()

**File:** `dss-flash/src/flash.sol`, line 154
```solidity
dai.transferFrom(address(receiver), address(this), amount);
```
**Analysis:** The return value is not checked. If the transfer fails silently (returns false
without reverting), the subsequent `daiJoin.join(address(this), amount)` will call
`dai.burn(address(DssFlash), amount)`, which internally has
`require(balanceOf[DssFlash] >= amount)`. Since DssFlash did not receive DAI, this burn reverts,
making the entire transaction revert. For the deployed Dai.sol token, transferFrom always either
returns true or reverts; it never returns false silently. **Not exploitable** with the standard Dai
token.

---

### IE-02: DssFlash – vatDaiFlashLoan Repayment Enforcement

**File:** `dss-flash/src/flash.sol`, lines 170–179
**Analysis:** After `vat.suck(address(this), address(receiver), amount)` which sets
`sin[DssFlash] += amount` and `dai[receiver] += amount`, the code calls `vat.heal(amount)` which
requires `dai[DssFlash] >= amount`. Since the suck sent dai to the receiver (not DssFlash), the
receiver must call `vat.move(receiver, DssFlash, amount)` during the callback. If they do not,
heal() reverts with an underflow revert, reverting the entire transaction. Repayment is correctly
enforced via arithmetic revert, not a balance-check with >= that could be bypassed. **Safe.**

---

### IE-03: DssFlash – Unlimited dai.approve(daiJoin, type(uint256).max) Abuse

**File:** `dss-flash/src/flash.sol`, constructor line 91
```solidity
dai_.approve(daiJoin_, type(uint256).max);
```
**Analysis:** DssFlash gives DaiJoin unlimited ERC-20 approval. DaiJoin.join() calls
`dai.burn(msg.sender, wad)` where msg.sender is the caller of join, not DssFlash. For the
approval to be used to burn DssFlash's DAI, a transaction would need msg.sender == DssFlash at
the point of calling DaiJoin.join(). This only occurs when DssFlash itself calls
`daiJoin.join(address(this), amount)` during a flash loan — which is the intended mechanism.
External actors cannot cause DaiJoin to burn DssFlash's DAI. **Not exploitable.**

---

### IE-04: DssFlash – Transient Debt Ceiling Bypass via vat.suck()

**File:** `dss-flash/src/flash.sol`, lines 144, 170
**Analysis:** suck() does not check vat.Line() or ilk.line. A flash loan temporarily increases
debt and vice beyond ceiling limits. Because the loan is fully repaid (via heal()) within the same
transaction, the transient debt increase has zero persistent effect on protocol state. **Not
exploitable.**

---

### IE-05: Vat – _sub(uint, int) and _add(uint, int) with Negative Integers

**File:** `dss/src/vat.sol`, lines 74–83
**Analysis:** These functions use two's complement wrapping of negative int values cast to uint
in Solidity 0.6. The accompanying require checks correctly catch both overflow and underflow:
- _add: require(y >= 0 || z <= x) catches negative-int underflow.
- _sub: require(y <= 0 || z <= x) catches positive subtraction underflow;
        require(y >= 0 || z >= x) catches negative-int "addition" overflow.
**Correct by design.** Not a bug.

---

### IE-06: Vat – frob() Three-Party Consent Matrix

**File:** `dss/src/vat.sol`, lines 165–170
```solidity
require(either(both(dart <= 0, dink >= 0), wish(u, msg.sender)), "Vat/not-allowed-u");
require(either(dink <= 0, wish(v, msg.sender)), "Vat/not-allowed-v");
require(either(dart >= 0, wish(w, msg.sender)), "Vat/not-allowed-w");
```
**Analysis:** The three-party consent model is correctly implemented. u only needs to consent when
taking new risk (dart > 0 or dink < 0). v only needs to consent when contributing collateral
(dink > 0). w only needs to consent when absorbing debt (dart < 0). The logic correctly permits
benevolent actions (repaying someone's debt, adding collateral for someone) without requiring the
beneficiary's consent. **Correct.**

---

### IE-07: Vat – fork() Consent and Safety Checks

**File:** `dss/src/vat.sol`, lines 182–205
**Analysis:** fork() requires consent from both src and dst. Both sides must be safe after the
move, and neither can be left dusty. Negative dink/dart values move collateral/debt in the reverse
direction correctly. No cross-owner steal is possible. **Correct.**

---

### IE-08: DssCdpManager – quit() Destination Consent

**File:** `dss-cdp-manager/src/DssCdpManager.sol`, lines 230–242
```solidity
function quit(uint cdp, address dst) public cdpAllowed(cdp) urnAllowed(dst) {
    (uint ink, uint art) = VatLike(vat).urns(ilks[cdp], urns[cdp]);
    VatLike(vat).fork(ilks[cdp], urns[cdp], dst, toInt(ink), toInt(art));
}
```
**Analysis:** urnAllowed(dst) requires msg.sender == dst or urnCan[dst][msg.sender] == 1. The
destination URN must explicitly grant permission. UrnHandler contracts cannot call urnAllow()
(they only call vat.hope() in their constructor), so migration into another managed URN requires
explicit consent. The downstream vat.fork() enforces both sides' safety and non-dustiness. **No
bypass possible.**

---

### IE-09: DssCdpManager – shift() Cross-Owner Exploit

**File:** `dss-cdp-manager/src/DssCdpManager.sol`, lines 260–273
**Analysis:** shift() is guarded by cdpAllowed(cdpSrc) AND cdpAllowed(cdpDst). An attacker owning
cdpDst cannot access cdpSrc without the owner of cdpSrc granting explicit permission via cdpAllow.
**Correctly gated.**

---

### IE-10: DssCdpManager – give() Linked-List Corruption

**File:** `dss-cdp-manager/src/DssCdpManager.sol`, lines 146–181
**Analysis:** give() requires dst != address(0) and dst != owns[cdp]. The double-linked list
manipulation covers all edge cases: first CDP, last CDP, only CDP, and middle CDP.
count[src] is always >= 1 when give() is called because ownership of the CDP implies count >= 1.
sub(count, 1) will not underflow. **Correct.**

---

### IE-11: DssBlow2 – Permissionless blow() Function

**File:** `dss-blow2/src/DssBlow2.sol`, lines 76–88
**Analysis:** blow() has no access control, but it only moves tokens from DssBlow2 to the Vow's
surplus buffer. It cannot move tokens from any external address. No user funds are at risk. The
permissionless nature is intentional — any actor can trigger the buffer top-up. **No
vulnerability.**

---

### IE-12: PSM – Missing live Check in sellGem() / buyGem()

**File:** `dss-psm/src/psm.sol`, lines 109–132
**Analysis:** Neither function checks a PSM-level live flag. Both call vat.frob() which has
require(live == 1, "Vat/not-live"). PSM trades revert via the Vat when it is caged. **Effectively
protected by downstream checks.**

---

### IE-13: PSM – Fee Arithmetic Rounding

**File:** `dss-psm/src/psm.sol`, lines 111, 123
**Analysis:** Integer division truncates fee slightly downward (user-favorable). The internal vat
accounting (join, frob, move, exit) remains balanced because fee is derived from the same gemAmt18
that drives the frob. **No arithmetic exploit.**

---

### IE-14: Spotter – Oracle Staleness Freezes Borrowing

**File:** `dss/src/spot.sol`, lines 98–103
**Analysis:** If pip.has() == false, spot is set to 0, halting new borrowing and (due to
dog.bark() requiring spot > 0) halting liquidations. This is the intended safety behavior for a
stale oracle. poke() is permissionless but cannot produce worse outcomes than this designed safety
mode. **Not exploitable.**

---

### IE-15: Clipper – External Call to ClipperCallee Before DAI Payment

**File:** `dss/src/clip.sol`, lines 388–399
**Analysis:** Collateral is sent (vat.flux) before DAI is collected. This is the intentional flash
liquidation pattern. The lock modifier prevents reentrancy into take(), redo(), and kick(). The
vat and dog are explicitly excluded as callee targets. **Intended design, not a vulnerability.**

---

### IE-16: Pot – exit() Without Requiring now == rho

**File:** `dss/src/pot.sol`, lines 161–165
**Analysis:** If drip() has not been called, chi is stale (lower than it should be), meaning the
user receives fewer internal DAI units than accrued. This is the user's loss, not the protocol's.
The protocol never over-pays. join() correctly requires now == rho to prevent exploiting stale chi
on deposit. **No exploit; user self-harm only.**

---

### IE-17: Flopper – dent() Calls VowLike.Ash() and kiss() on External Address

**File:** `dss/src/flop.sol`, lines 152–153
**Analysis:** bids[id].guy is initialized to gal in kick(). kick() is auth-gated and in practice
called by vow.flop() with gal == address(vow). Only a compromised ward could register a different
gal. **Not exploitable under normal operation.**

---

### IE-18: Flapper – tick() Permissionless Auction Extension

**File:** `dss/src/flap.sol`, lines 133–137
**Analysis:** tick(id) can be called by anyone to extend an expired, unbid auction. This delays
fill reduction but new kicks are bounded by lid. The effect is minimal bounded grief rather than
fund loss. Low impact, likely known behavior.

---

### IE-19: GemJoin – Fee-on-Transfer Tokens Inflate Internal Accounting

**File:** `dss/src/join.sol`, lines 108–120
**Analysis:** For fee-on-transfer tokens, vat.gem credit is given for wad but only wad-fee tokens
are received, inflating accounting. This is a known limitation — GemJoin only supports well-behaved
ERC-20 tokens with exact-transfer semantics. **Out of scope per program rules.**

---

### IE-20: Cure – load() Allows Re-loading Sources

**File:** `dss/src/cure.sol`, lines 130–141
**Analysis:** load(src) can be called multiple times. The registered sources are governance-
controlled via lift() (auth-gated). A malicious source would require a ward to add it. **Not
exploitable without ward compromise.**

---

### IE-21: DssAutoLine – exec() on Uninitialized Vat Ilk

**File:** `dss-auto-line/src/DssAutoLine.sol`, lines 115–161
**Analysis:** If DssAutoLine ilk is configured but vat ilk not initialized, exec() could inflate
the global Line by ilkGap. Requires governance to call setIlk() for a non-existent vat ilk —
a governance configuration error, not a user-exploitable bug.

---

### IE-22: Vow – heal() and kiss() Permissionless Debt Settlement

**File:** `dss/src/vow.sol`, lines 128–138
**Analysis:** Both are permissionless but only cancel surplus against unbacked debt. Always
beneficial to the protocol. **No exploit.**

---

## Protocol Architecture Notes

### Vat Math Design
The _add(uint, int) / _sub(uint, int) / _mul(uint, int) functions use Solidity 0.6's non-reverting
unsigned arithmetic to simulate signed operations via two's complement. The require guards correctly
detect both overflow and underflow in all cases. This is an intentional, well-understood design
pattern established in MakerDAO.

### Flash Loan Repayment Invariants
- flashLoan(): Repayment enforced by the chain: dai.transferFrom(receiver, DssFlash, amount) ->
  daiJoin.join(DssFlash, amount) -> dai.burn(DssFlash, amount). If receiver does not return ERC-20
  DAI, the burn reverts.
- vatDaiFlashLoan(): Repayment enforced because vat.heal(amount) subtracts from dai[DssFlash],
  which equals zero if the receiver did not call vat.move(receiver, DssFlash, amount) during the
  callback. Underflow revert enforces repayment.

### DssCdpManager Permission Model
Two permission domains:
- cdpCan[owner][cdpId][operator] — governs frob, flux, move, give, shift, enter, quit (source)
- urnCan[urn][operator] — governs quit (destination) and enter (source urn)
The urnAllowed(dst) check in quit() requiring the destination URN's explicit consent is the
critical guard preventing unauthorized migration of collateral positions.

### DssAutoLine Execution Model
exec() enforces:
1. Only runs once per block per ilk (ilkLast == block.number guard).
2. Increases only allowed after TTL has passed since the last increase.
3. Decreases (if lineNew < line) are allowed immediately.
4. Global Line updated atomically with ilk line in same Vat storage write.
The one confirmed gap (FINDING-01) is that this atomic global Line update reverts if governance
has manually set the global ceiling below the current ilk ceiling.
