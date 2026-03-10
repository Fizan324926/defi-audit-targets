# Sky Protocol Security Audit Report
## Scope: VoteDelegate + DssVest + DssEmergencySpells + DssLitePSM

**Date:** 2026-03-01
**Auditor:** Immunefi Bug Bounty Security Research
**Status:** Complete

---

## Files Audited

| Contract | Path |
|---|---|
| VoteDelegate.sol | `/root/audits/sky-protocol/vote-delegate/src/VoteDelegate.sol` |
| VoteDelegateFactory.sol | `/root/audits/sky-protocol/vote-delegate/src/VoteDelegateFactory.sol` |
| DssVest.sol | `/root/audits/sky-protocol/dss-vest/src/DssVest.sol` |
| DssEmergencySpell.sol | `/root/audits/sky-protocol/dss-emergency-spells/src/DssEmergencySpell.sol` |
| DssGroupedEmergencySpell.sol | `/root/audits/sky-protocol/dss-emergency-spells/src/DssGroupedEmergencySpell.sol` |
| SingleClipBreakerSpell.sol | `/root/audits/sky-protocol/dss-emergency-spells/src/clip-breaker/SingleClipBreakerSpell.sol` |
| MultiClipBreakerSpell.sol | `/root/audits/sky-protocol/dss-emergency-spells/src/clip-breaker/MultiClipBreakerSpell.sol` |
| GroupedClipBreakerSpell.sol | `/root/audits/sky-protocol/dss-emergency-spells/src/clip-breaker/GroupedClipBreakerSpell.sol` |
| SingleDdmDisableSpell.sol | `/root/audits/sky-protocol/dss-emergency-spells/src/ddm-disable/SingleDdmDisableSpell.sol` |
| SingleLineWipeSpell.sol | `/root/audits/sky-protocol/dss-emergency-spells/src/line-wipe/SingleLineWipeSpell.sol` |
| MultiLineWipeSpell.sol | `/root/audits/sky-protocol/dss-emergency-spells/src/line-wipe/MultiLineWipeSpell.sol` |
| GroupedLineWipeSpell.sol | `/root/audits/sky-protocol/dss-emergency-spells/src/line-wipe/GroupedLineWipeSpell.sol` |
| SingleLitePsmHaltSpell.sol | `/root/audits/sky-protocol/dss-emergency-spells/src/lite-psm-halt/SingleLitePsmHaltSpell.sol` |
| SingleOsmStopSpell.sol | `/root/audits/sky-protocol/dss-emergency-spells/src/osm-stop/SingleOsmStopSpell.sol` |
| MultiOsmStopSpell.sol | `/root/audits/sky-protocol/dss-emergency-spells/src/osm-stop/MultiOsmStopSpell.sol` |
| SPBEAMHaltSpell.sol | `/root/audits/sky-protocol/dss-emergency-spells/src/spbeam-halt/SPBEAMHaltSpell.sol` |
| SplitterStopSpell.sol | `/root/audits/sky-protocol/dss-emergency-spells/src/splitter-stop/SplitterStopSpell.sol` |
| StUsdsRateSetterHaltSpell.sol | `/root/audits/sky-protocol/dss-emergency-spells/src/stusds/StUsdsRateSetterHaltSpell.sol` |
| StUsdsRateSetterDissBudSpell.sol | `/root/audits/sky-protocol/dss-emergency-spells/src/stusds/StUsdsRateSetterDissBudSpell.sol` |
| StUsdsWipeParamSpell.sol | `/root/audits/sky-protocol/dss-emergency-spells/src/stusds/StUsdsWipeParamSpell.sol` |
| DssLitePsm.sol | `/root/audits/sky-protocol/dss-lite-psm/src/DssLitePsm.sol` |
| DssLitePsmMom.sol | `/root/audits/sky-protocol/dss-lite-psm/src/DssLitePsmMom.sol` |

---

## Executive Summary

After a thorough review of all contracts in scope, **no Critical or High severity exploitable vulnerabilities were identified**. The codebase is well-structured and largely follows best practices. Two Low-severity findings were confirmed with clear exploit paths, and several design observations are documented for completeness.

The most important genuine findings are:

1. **LOW: VoteDelegate.lock() violates Checks-Effects-Interactions** — External calls precede state updates. Low risk with standard ERC20 tokens, but becomes a real reentrancy vector if the governance token is ever upgraded to an ERC777 or ERC223 that has send hooks.
2. **LOW: DssVest rate cap check allows fractional bypass via integer truncation** — The require `_tot / _tau <= cap` truncates before comparison, allowing up to `(_tau - 1)` additional base token units per vest. Sub-token level impact only.
3. **INFORMATIONAL: DssEmergencySpell.schedule() has no caller restriction** — Intentional by design; the access control is correctly enforced at the Mom contract layer via the DSChief hat system.
4. **INFORMATIONAL: DssVest global reentrancy lock is shared across all vest IDs** — No persistent DoS possible since the lock clears at transaction end, but noted for completeness.

---

## Detailed Findings

---

### FINDING-1 (Low): VoteDelegate.lock() Violates Checks-Effects-Interactions

**File:** `/root/audits/sky-protocol/vote-delegate/src/VoteDelegate.sol`
**Lines:** 75–81

#### Vulnerable Code

```solidity
function lock(uint256 wad) external {
    gov.transferFrom(msg.sender, address(this), wad);  // external call FIRST
    chief.lock(wad);                                    // external call SECOND
    stake[msg.sender] += wad;                          // state update LAST
    emit Lock(msg.sender, wad);
}
```

#### Description

The `lock()` function performs two external calls (`gov.transferFrom` and `chief.lock`) **before** updating the internal state variable `stake[msg.sender]`. This is a violation of the Checks-Effects-Interactions (CEI) pattern.

Compare with `free()`, which correctly decrements `stake[msg.sender]` BEFORE making external calls:

```solidity
function free(uint256 wad) external {
    require(stake[msg.sender] >= wad, "VoteDelegate/insufficient-stake");
    unchecked { stake[msg.sender] -= wad; }  // state update FIRST
    chief.free(wad);                          // external call after
    gov.transfer(msg.sender, wad);            // external call after
    emit Free(msg.sender, wad);
}
```

#### Exploit Path

1. The governance token `gov` is currently MKR or SKY — both standard ERC-20 tokens with no send/receive hooks. Under these conditions, `gov.transferFrom` cannot trigger a reentrancy callback, and the vulnerability is not directly exploitable.

2. However, if the protocol ever upgrades or migrates the governance token to an ERC-777 compatible token (which includes `tokensToSend` hooks), the attack becomes live:
   - Attacker deploys a malicious `tokensToSend` hook in their wallet contract.
   - Attacker calls `lock(wad)`.
   - `gov.transferFrom` fires; the attacker's `tokensToSend` hook is triggered before the transfer completes.
   - Inside the hook, attacker calls `lock(wad)` again. Because `stake[msg.sender]` has not yet been updated, `free()` would still see the old value of stake — **but** more critically, `chief.lock(wad)` is called again inside the reentrancy, adding voting weight a second time without a corresponding token transfer.
   - After the reentrant `chief.lock(wad)` completes, the outer call finishes and `stake[msg.sender] += wad` is written — but with only the outer wad amount, not the inner.

3. Net effect of a successful exploit: attacker accrues double (or more) voting weight in the Chief contract (`chief.lock` called N times) while only transferring 1x tokens and only having `stake` = 1x wad. When they call `free()`, they can only withdraw 1x wad, but they had N×wad voting power during the attack window — enough to lift a malicious spell to the hat.

#### Defense Assessment

Currently defended by the standard nature of MKR/SKY (no callbacks). **No defense exists in the contract code itself.** The `free()` function correctly decrements `stake` before external calls, making a reentrancy via `free()` not viable. The vulnerability is entirely in `lock()`.

**Severity:** Low (not exploitable with current gov token; becomes High if gov token gains hooks)

---

### FINDING-2 (Low): DssVest Rate Cap Check Allows Sub-Token-Level Bypass via Integer Truncation

**File:** `/root/audits/sky-protocol/dss-vest/src/DssVest.sol`
**Line:** 192

#### Vulnerable Code

```solidity
require(_tot / _tau <= cap, "DssVest/rate-too-high");
```

#### Description

The rate cap validation performs integer division `_tot / _tau` (which truncates downward) and compares the result to `cap`. Because of truncation, a vest with a rate slightly above `cap` may pass the check.

#### Arithmetic Example

```
cap = 1,000,000  (tokens per second in base units)
_tau = 3         (seconds, simplified)

Maximum allowed _tot by the cap: 3 * 1,000,000 = 3,000,000
But consider _tot = 3,000,002:
  _tot / _tau = 3,000,002 / 3 = 1,000,000  (truncation discards remainder)
  1,000,000 <= 1,000,000  → PASSES CHECK
  Actual rate = 3,000,002 / 3 = 1,000,000.666... tokens/sec > cap
```

#### Maximum Overshoot

The maximum extra tokens that can be approved beyond the cap for a single vest:

```
max_extra = _tau - 1  base token units (wei)
```

For the maximum vest duration of 20 years (`_tau` = 630,720,000 seconds):
- `max_extra` = 630,719,999 token base units
- For an 18-decimal token: 630,719,999 × 10^-18 ≈ 6.3×10^-10 tokens
- This is **less than one full token** total

#### Exploit Path

1. Ward (governance) creates a vest with `_tot = cap * _tau + (_tau - 1)`.
2. The rate check passes due to truncation.
3. The vest allows distribution of `_tau - 1` additional base units over its lifetime.
4. For any realistic vest, this is sub-token level and economically immaterial.

#### Defense Assessment

The amount bypassed is bounded by `_tau - 1` wei of the token, never exceeding 1 full token regardless of vest parameters. For any realistic token with 18 decimals and reasonable supply, this is economically negligible. However, it is a technical inaccuracy in the cap enforcement.

**Severity:** Low (sub-token impact; effectively informational)

---

### FINDING-3 (Informational): DssEmergencySpell.schedule() Has No Caller Access Control

**File:** `/root/audits/sky-protocol/dss-emergency-spells/src/DssEmergencySpell.sol`
**Lines:** 89–91

#### Code

```solidity
/// @notice Triggers the emergency actions of the spell.
function schedule() external {
    _emergencyActions();
}
```

#### Description

The `schedule()` function is callable by **any address** with no restriction. For example, in `SingleClipBreakerSpell`:

```solidity
function _emergencyActions() internal override {
    address clip = ilkReg.xlip(ilk);
    clipperMom.setBreaker(clip, BREAKER_LEVEL, BREAKER_DELAY);
    emit SetBreaker(clip);
}
```

`ClipperMom.setBreaker()` internally checks that the caller (the spell contract) is authorized via the DSChief `authority`. The spell must have been lifted to the "hat" (highest-approval address in the Chief) through a governance vote for this to succeed.

#### Analysis: Why This Is By Design

In the standard MakerDAO spell lifecycle:
1. A spell is deployed.
2. Governance votes to lift the spell to the hat.
3. Anyone calls `schedule()`, which plots it into the Pause with a time-delay.
4. After the delay, anyone calls `cast()`.

Emergency spells deliberately skip step 3's time-delay mechanism. They still require step 2 (getting the hat via governance). Once the hat is obtained, the intent is that **any actor can trigger the emergency immediately** — this is the point of emergency spells (they must be executable instantly by keepers, bots, or anyone who notices the emergency).

The authorization is enforced at the Mom layer:
- `ClipperMom.setBreaker()` requires the caller to be authorized (has the hat)
- `OsmMom.stop()` same
- `LineMom.wipe()` same
- `LitePsmMom.halt()` checks `isAuthorized()` using DSAuthority

#### Residual Risk

If a spell loses the hat between when it is expected to be triggered and the actual `schedule()` call (e.g., another spell is lifted in between), `schedule()` will revert inside the Mom contract with an authorization error. In a true emergency, this could delay response. This is a governance coordination risk, not a contract vulnerability.

**Severity:** Informational (by design; minor governance coordination risk)

---

### FINDING-4 (Informational): DssVest Global Reentrancy Lock Shared Across All Vest IDs

**File:** `/root/audits/sky-protocol/dss-vest/src/DssVest.sol`
**Lines:** 124–129

#### Code

```solidity
uint256 internal locked;

modifier lock {
    require(locked == 0, "DssVest/system-locked");
    locked = 1;
    _;
    locked = 0;
}
```

#### Description

The `locked` variable is a single global flag shared across the entire `DssVest` contract — it covers **all** vest IDs simultaneously. The following functions are all guarded by this lock:

- `file()` (admin: set cap)
- `_vest()` (claim tokens)
- `restrict()` / `unrestrict()` (admin/user: toggle claim restriction)
- `_yank()` (admin/mgr: terminate vest)
- `move()` (user: transfer vest to new address)

#### Implication

If any one of these functions is executing in a transaction (e.g., a governance call to `file()` setting a new cap), **all other** lock-guarded operations revert for the duration of that transaction. A recipient trying to `vest()` at that exact block would receive `"DssVest/system-locked"`.

#### Why This Is Not a Persistent DoS

The `locked` variable resets to 0 at the end of every transaction (`locked = 0` in the modifier's cleanup). No actor can hold the lock across blocks. In the worst case, a recipient who attempts to vest in the same block as a governance parameter update will simply retry in the next block.

The reciprocal is also true: no external actor can cause persistent denial of vesting for a specific recipient, because the `restrict()` function (which only the ward or the `usr` themselves can call) also uses the lock, preventing a scenario where it gets wedged.

**Severity:** Informational (no persistent impact; at most 1-block retry needed)

---

## Systematic Checklist Results

### VoteDelegate

| Check | Result |
|---|---|
| `lock()` reentrancy (CEI order) | FINDING-1: External calls before state update |
| `free()` reentrancy (CEI order) | Safe: state decremented before external calls |
| `vote()` access control | Safe: `delegate_auth` modifier restricts to delegate address only |
| `votePoll()` access control | Safe: `delegate_auth` modifier |
| Stake accounting correctness | Safe: `stake[msg.sender] += wad` and `stake[msg.sender] -= wad` are correctly paired |
| Token grief (permanent lock) | Not possible: `stake[msg.sender]` tracks each staker independently; delegator always calls `free()` themselves |
| `reserveHatch()` function | Not present in this version of the code |

**VoteDelegate.free() CEI Verification:**
```solidity
// Line 83-89: CORRECT CEI order in free()
function free(uint256 wad) external {
    require(stake[msg.sender] >= wad, "VoteDelegate/insufficient-stake"); // CHECK
    unchecked { stake[msg.sender] -= wad; }  // EFFECT (state update before externals)
    chief.free(wad);                          // INTERACTION
    gov.transfer(msg.sender, wad);            // INTERACTION
    emit Free(msg.sender, wad);
}
```

### VoteDelegateFactory

| Check | Result |
|---|---|
| Same address creating multiple delegates | Safe: `require(!isDelegate(msg.sender), ...)` enforces uniqueness |
| Race condition in creation | Not possible: each address creates only for themselves (`msg.sender`) |
| Arbitrary code injection via `create()` | Not possible: deploys fixed `VoteDelegate` bytecode with `new` keyword |

**Key code at line 48:**
```solidity
function create() external returns (address voteDelegate) {
    require(!isDelegate(msg.sender), "VoteDelegateFactory/sender-is-already-delegate");
    voteDelegate = address(new VoteDelegate(chief, polling, msg.sender));
    delegates[msg.sender] = voteDelegate;
    created[voteDelegate] = 1;
    emit CreateVoteDelegate(msg.sender, voteDelegate);
}
```

No mechanism exists to revoke a delegate mapping. This is a permanence design decision — the delegate mapping is write-once per address. Stakers retain full ability to `free()` their own tokens regardless of delegate state.

### DssVest

| Check | Result |
|---|---|
| `vest()` cliff/schedule calculation | Safe: `unpaid()` correctly returns 0 before cliff |
| Integer overflow in time arithmetic | Safe: custom `add()`/`sub()`/`mul()` in Solidity 0.6 prevent overflow; max product ~2.1×10^47 << uint256 max |
| Division before multiplication | Safe: `mul(_tot, sub(_time, _bgn)) / sub(_fin, _bgn)` multiplies before dividing |
| Rate cap check | FINDING-2: `_tot / _tau` truncation allows sub-token overshoot |
| `yank()` tot calculation correctness | Safe: `tot = accrued(end) = unpaid(end) + rxd` correctly limits future claims |
| `yank()` double-yank safety | Safe: idempotent when called repeatedly |
| `unpaid()` over-payment | Safe: capped at `tot - rxd`; `accrued()` capped at `tot`; no path returns more than `tot` |
| `move()` correctness | Safe: only `usr` can call; `mgr` unchanged (correct) |
| Double-claim via `accrued` vs `claimed` | Not possible: `rxd` monotonically increases; `unpaid = accrued - rxd` never negative |
| Yank front-running | No exploit: user can at most claim currently accrued amount they were entitled to |

**accrued() arithmetic bounds:**
```solidity
// Line 269: Multiplication before division - correct
amt = mul(_tot, sub(_time, _bgn)) / sub(_fin, _bgn);
// _tot max = 2^128 ≈ 3.4*10^38
// sub(_time, _bgn) max = 20 years = 630,720,000 s ≈ 6.3*10^8
// Product max = 3.4*10^38 * 6.3*10^8 = 2.1*10^47
// uint256.max = 1.15*10^77, so NO OVERFLOW
```

**DssVestTransferrable trust assumption:**
```solidity
// Line 498: pay() depends on czar maintaining approval
function pay(address _guy, uint256 _amt) override internal {
    require(gem.transferFrom(czar, _guy, _amt), "DssVestTransferrable/failed-transfer");
}
```
If `czar` revokes the spending approval, all vests funded by that czar's address become permanently unclaimable. This is a stated design constraint ("This contract must be approved for transfer of the gem on the czar") and requires trusting the czar operator. No contract-level mitigation exists or is expected.

### DssEmergencySpells

| Check | Result |
|---|---|
| `schedule()` access control | FINDING-3 (by design): No restriction; access enforced at Mom contracts |
| `cast()` delay bypass | By design: emergency spells are instantaneous; `cast()` is a no-op |
| GSM delay bypass | By design: documented in comments; emergency spells skip pause.plot() |
| `DssGroupedEmergencySpell.schedule()` correctness | Safe: iterates all ilks via `_emergencyActions(ilk)` |
| `emergencyActionsInBatch()` bounds safety | Safe: constructor requires `len >= 1`; `ilkList.length - 1 >= 0` always |
| `clipBreaker` halting Clipper | Safe: calls ClipperMom.setBreaker with level=3, delay=0 |
| `done()` false positive safety | Safe: uses `try/catch` to handle non-Clip/non-OSM contracts gracefully |
| Flash loan exploitation of emergency state | Not possible: emergency spell actions are one-shot state changes with no value at stake |

**GroupedEmergencySpell emergencyActionsInBatch bounds check (line 106):**
```solidity
function emergencyActionsInBatch(uint256 start, uint256 end) external {
    end = end > ilkList.length - 1 ? ilkList.length - 1 : end;
    require(start <= end, "DssGroupedEmergencySpell/bad-iteration");
    for (uint256 i = start; i <= end; i++) {
        _emergencyActions(ilkList[i]);
    }
}
```
The `ilkList.length - 1` expression is safe because the constructor guarantees `ilkList.length >= MIN_ILKS == 1`, so this never underflows. Note this function also has no access control, which is intentional for the gas-limit escape-hatch use case.

### DssLitePSM

| Check | Result |
|---|---|
| `sellGem()` CEI order | Safe: no contract storage changes in `_sellGem`; token transfers only |
| `buyGem()` CEI order | Safe: no contract storage changes in `_buyGem`; token transfers only |
| `fill()` arithmetic safety | Safe: `rush()` correctly computes available headroom with proper truncation |
| `trim()` arithmetic safety | Safe: `gush()` correctly identifies excess via `_max(_subcap(Art,tArt), _subcap(Art,line/RAY))` |
| `rush()` access control | None needed: permissionless; only mints Dai within governance-approved limits |
| `gush()` access control | None needed: permissionless; only burns excess Dai |
| `cut()` invariant `art <= cash + gemBal18` | Holds with positive fees; sellGem/buyGem maintain or increase (cash + gemBal18 - art) |
| `cut()` underflow safety | Safe under normal conditions: fees ensure (cash + gemBal18) >= art after fill() |
| Fee calculation direction rounding | Low-impact: fees round DOWN (via `/`), user gets ~1 wei extra per tx; not exploitable |
| `pocket` validation | `pocket` is immutable, set at construction. No contract-level validation, but trust assumption from governance |
| Flash loan attack (deposit + withdraw same tx) | Not profitable: tin + tout fees make round-trips cost-positive for protocol |
| Reentrancy via USDC | Safe: USDC has no send/receive hooks; no callback pathway in `_sellGem` or `_buyGem` |
| `gush()` Art vs urn.art assumption | Documented design assumption: "There are no other urns for the same ilk" (contract comment line 50) |

**DssLitePsm _sellGem full control-flow (no storage state changes):**
```solidity
// Lines 336-352: No contract storage is read-modify-written
function _sellGem(address usr, uint256 gemAmt, uint256 tin_) internal returns (uint256 daiOutWad) {
    daiOutWad = gemAmt * to18ConversionFactor;        // pure computation
    uint256 fee;
    if (tin_ > 0) {
        fee = daiOutWad * tin_ / WAD;                 // pure computation
        unchecked { daiOutWad -= fee; }
    }
    gem.transferFrom(msg.sender, pocket, gemAmt);     // token transfer only
    dai.transfer(usr, daiOutWad);                     // token transfer only
    emit SellGem(usr, gemAmt, fee);
}
```

**cut() invariant analysis:**
```solidity
// Line 510
wad = _min(cash, cash + gem.balanceOf(pocket) * to18ConversionFactor - art);
```
- `fill()`: art += wad, cash += wad (balanced)
- `sellGem()` with tin > 0: cash -= (gemAmt18 - fee), pocket gems += gemAmt18 → net (cash + gemBal18) increases by `fee`
- `buyGem()` with tout > 0: cash += (gemAmt18 + fee), pocket gems -= gemAmt18 → net (cash + gemBal18) increases by `fee`
- With zero fees (tin=tout=0): invariant maintained exactly
- `cut()` represents accumulated fees; never negative in normal operation

**Fee rounding direction (informational):**
```solidity
// sellGem fee: rounds DOWN (user receives ~1 wei more Dai than exact)
fee = daiOutWad * tin_ / WAD;

// buyGem fee: rounds DOWN (user pays ~1 wei less Dai than exact)
fee = daiInWad * tout_ / WAD;
```
Both round in favor of users by at most 1 wei per transaction. This results in the protocol collecting marginally less fees than the theoretical maximum. The cumulative effect over millions of transactions is economically negligible relative to PSM TVL.

---

## Conclusions

### Confirmed Real Findings

| ID | Severity | Contract | Summary |
|---|---|---|---|
| FINDING-1 | Low | VoteDelegate.sol | `lock()` makes external calls before updating `stake[msg.sender]`; reentrancy risk if gov token gains hooks |
| FINDING-2 | Low | DssVest.sol | Rate cap check `_tot / _tau <= cap` truncates; allows up to `(_tau - 1)` base unit overshoot (< 1 token) |

### Design Observations (Not Vulnerabilities)

| ID | Severity | Contract | Summary |
|---|---|---|---|
| OBS-1 | Informational | DssEmergencySpell.sol | `schedule()` has no caller guard by design; authorization at Mom layer via DSChief hat |
| OBS-2 | Informational | DssVest.sol | Global reentrancy lock shared across all vest IDs; only 1-block retry delay when governance functions execute |
| OBS-3 | Informational | DssVestTransferrable.sol | If czar revokes approval, all vests from that czar become permanently unclaimable; stated design trust assumption |
| OBS-4 | Informational | DssLitePsm.sol | Fee rounding (integer division) slightly favors users; sub-wei impact per swap, not exploitable |
| OBS-5 | Informational | VoteDelegateFactory.sol | Delegate mapping is permanent; no mechanism to retire a delegate address; stakers retain full `free()` capability |

### Non-Findings (Explicitly Verified Safe)

The following were explicitly checked and confirmed safe:

- **VoteDelegate.free()**: Correct CEI — state updated before external calls
- **VoteDelegate double-claim**: Impossible — `stake` mapping tracks each user's own deposits independently
- **DssVest integer overflow**: Impossible — max product (~2.1×10^47) is well within uint256 range
- **DssVest accrued() > tot**: Impossible — `accrued()` is always capped at `_tot`
- **DssVest double-claim**: Impossible — `rxd` monotonically increases; `unpaid = accrued - rxd >= 0` always
- **DssVest yank front-running**: Not exploitable — user can only claim what was already accrued to them
- **DssEmergencySpell GSM delay bypass**: By design — emergency spells are explicitly meant to bypass the GSM delay
- **DssLitePsm flash loan**: Not profitable — round-trip costs tin+tout fees
- **DssLitePsm reentrancy**: No storage state changes in swap functions; USDC has no callbacks
- **DssLitePsm cut() underflow**: Does not occur under normal operation; fees grow (cash+gemBal18-art) over time
- **GroupedEmergencySpell emergencyActionsInBatch underflow**: Constructor enforces `len >= 1`; safe
- **VoteDelegateFactory race condition**: Each user creates for themselves (`msg.sender`); no race possible
