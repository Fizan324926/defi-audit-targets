# Sky Protocol Security Audit — Group 4: Oracles, SP-BEAM, and Flappers

**Scope:**
- /root/audits/sky-protocol/univ2-lp-oracle/src/UNIV2LPOracle.sol
- /root/audits/sky-protocol/univ3-lp-oracle/src/GUniLPOracle.sol
- /root/audits/sky-protocol/median/src/median.sol
- /root/audits/sky-protocol/osm/src/osm.sol
- /root/audits/sky-protocol/sp-beam/src/SPBEAM.sol
- /root/audits/sky-protocol/sp-beam/src/SPBEAMMom.sol
- /root/audits/sky-protocol/dss-flappers/src/FlapperUniV2.sol
- /root/audits/sky-protocol/dss-flappers/src/FlapperUniV2SwapOnly.sol
- /root/audits/sky-protocol/dss-flappers/src/Splitter.sol
- /root/audits/sky-protocol/dss-flappers/src/Kicker.sol
- /root/audits/sky-protocol/dss-flappers/src/OracleWrapper.sol
- /root/audits/sky-protocol/dss-flappers/src/SplitterMom.sol

**Audit Date:** 2026-03-01

**Protocol Rules:**
- Wards are FULLY trusted
- MEV/sandwich on dss-flappers is a KNOWN ISSUE — not reported
- Critical: fund theft, governance manipulation, unauthorized minting
- High: theft/freeze of yield, temporary lock
- Medium: contract unable to operate, griefing

---

## Files Reviewed

```
univ2-lp-oracle/src/  ->  UNIV2LPOracle.sol
univ3-lp-oracle/src/  ->  GUniLPOracle.sol
median/src/           ->  median.sol
osm/src/              ->  osm.sol, value.sol
sp-beam/src/          ->  SPBEAM.sol, SPBEAMMom.sol
dss-flappers/src/     ->  Babylonian.sol, FlapperUniV2.sol, FlapperUniV2SwapOnly.sol,
                          Kicker.sol, OracleWrapper.sol, Splitter.sol, SplitterMom.sol
```

---

## FINDING 1 — Medium: Stale pip Oracle Causes Persistent DoS on exec()

**Files:**
- /root/audits/sky-protocol/dss-flappers/src/FlapperUniV2.sol — line 148
- /root/audits/sky-protocol/dss-flappers/src/FlapperUniV2SwapOnly.sol — line 123

**Severity:** Medium (contract unable to operate)

### Vulnerable Code

FlapperUniV2.sol, lines 141-148:
```solidity
function exec(uint256 lot) external auth {
    (uint256 _reserveUsds, uint256 _reserveGem) = _getReserves();
    uint256 _sell = _getUsdsToSell(lot, _reserveUsds);

    uint256 _buy = _getAmountOut(_sell, _reserveUsds, _reserveGem);
    require(_buy >= _sell * want / (uint256(pip.read()) * RAY / spotter.par()),
        "FlapperUniV2/insufficient-buy-amount");
```

FlapperUniV2SwapOnly.sol, lines 118-124:
```solidity
function exec(uint256 lot) external auth {
    (uint256 _reserveUsds, uint256 _reserveGem) = _getReserves();

    uint256 _buy = _getAmountOut(lot, _reserveUsds, _reserveGem);
    require(_buy >= lot * want / (uint256(pip.read()) * RAY / spotter.par()),
        "FlapperUniV2SwapOnly/insufficient-buy-amount");
```

### Description

Both flapper contracts compute a minimum acceptable gem output by dividing by `uint256(pip.read()) * RAY / spotter.par()`. The `pip` oracle is typically an OSM (Oracle Security Module) that maintains a current price with a one-hour update interval. There is no freshness check on the pip value anywhere in the exec() flow: no check of `OSM.zzz` (timestamp of last successful price update), no maximum staleness threshold, and no circuit-breaker that prevents execution when pip is outdated.

`pip.read()` in OSM (osm.sol, lines 150-152) simply returns `cur.val` with no timestamp validation:
```solidity
function read() external view toll returns (bytes32) {
    require(cur.has == 1, "OSM/no-current-value");
    return (bytes32(uint(cur.val)));
}
```

The only safety note in the flapper code (line 99 of FlapperUniV2.sol) reads:
`"Warning - low want values increase the susceptibility to oracle manipulation attacks"`
This comment documents active price manipulation risk but says nothing about natural staleness from keeper failure or network disruption.

### Exploit Path — Persistent DoS (gem price rises while pip stale-low)

1. Market state at T=0: gem trades at 2,000 USDS/gem. OSM cur.val = 2000e18.
2. Over 12 hours, gem appreciates to 4,000 USDS/gem. The keeper network fails to update the OSM (e.g., infrastructure outage, keeper under gas price attack, or Medianizer quorum not reached).
3. OSM cur.val remains stale at 2000e18 (stale-low relative to market).
4. Splitter calls exec(lot) on the flapper.
5. At actual market price of 4,000 USDS/gem, the pool returns approximately:
   _buy = lot * 0.997 / 4000  (gem per USDS, minus Uniswap fees)
6. The required minimum:
   _sell * want / (pip.read() * RAY / par) = _sell * 0.98 / 2000
   which equals approximately _sell * 4.9e-4 gem per USDS.
7. Actual _buy = _sell * 2.49e-4 gem per USDS (at 4000 market price).
8. Check: 2.49e-4 >= 4.9e-4? FALSE. exec() REVERTS with "insufficient-buy-amount".
9. The flapper cannot operate. Surplus accumulates in the Vow undeployed.
10. Recovery requires: Medianizer update, two full OSM poke cycles (minimum 2 hours for nxt->cur propagation), and keeper resumption.

### Harm Quantification

During a significant gem price appreciation event:
- The surplus auction mechanism is entirely frozen
- Protocol cannot deploy accumulated surplus for gem buybacks
- If the gem price appreciates 2x, the DoS persists until the OSM is updated
- During bear/stress scenarios when the flapper is most needed for peg defense, keeper reliability may be lowest — creating a dangerous correlation

### Confirmation — No Defense Exists

- pip.read() has zero freshness logic (OSM osm.sol lines 150-152)
- No OSM.zzz check anywhere in FlapperUniV2.sol or FlapperUniV2SwapOnly.sol
- want parameter (line 48) addresses real-time pool manipulation only, not oracle staleness
- OracleWrapper.read() (OracleWrapper.sol line 41) also adds no staleness check:
  `return bytes32(uint256(pip.read()) / divisor);`

---

## FINDING 2 — Low-Medium: FlapperUniV2SwapOnly _getReserves Omits Sync Guard Present in FlapperUniV2

**File:** /root/audits/sky-protocol/dss-flappers/src/FlapperUniV2SwapOnly.sol — lines 107-110

**Severity:** Low-Medium (griefing via protocol efficiency reduction)

### Vulnerable Code

FlapperUniV2SwapOnly._getReserves() — lines 107-110:
```solidity
function _getReserves() internal view returns (uint256 reserveUsds, uint256 reserveGem) {
    (uint256 _reserveA, uint256 _reserveB,) = pair.getReserves();
    (reserveUsds, reserveGem) = usdsFirst ? (_reserveA, _reserveB) : (_reserveB, _reserveA);
}
```

FlapperUniV2._getReserves() — lines 112-122 (the guarded version):
```solidity
function _getReserves() internal returns (uint256 reserveUsds, uint256 reserveGem) {
    (uint256 _reserveA, uint256 _reserveB,) = pair.getReserves();
    (reserveUsds, reserveGem) = usdsFirst ? (_reserveA, _reserveB) : (_reserveB, _reserveA);

    uint256 _usdsBalance = GemLike(usds).balanceOf(address(pair));
    uint256 _gemBalance  = GemLike(gem).balanceOf(address(pair));
    if (_usdsBalance > reserveUsds || _gemBalance > reserveGem) {
        pair.sync();
        (reserveUsds, reserveGem) = (_usdsBalance, _gemBalance);
    }
}
```

### Description

In Uniswap V2, `getReserves()` returns the stored reserves from the most recent swap, not current token balances. When tokens are transferred directly to the pair contract (without routing through `swap()`), the stored reserves are stale — actual balances exceed stored values.

`FlapperUniV2` explicitly guards against this by comparing token balances with stored reserves and calling `sync()` when a discrepancy exists. `FlapperUniV2SwapOnly` uses only the potentially stale stored reserves, creating an exploitable inconsistency.

### Exploit Path

1. Attacker monitors the mempool for a pending FlapperUniV2SwapOnly exec() transaction.
2. Attacker front-runs by calling `usds.transfer(address(pair), donationAmount)` directly (not via swap — bypasses reserve update).
3. pair.getReserves() now returns stale reserveUsds that is LOWER than actual USDS balance.
4. FlapperUniV2SwapOnly.exec() calls _getReserves() which reads the stale (understated) reserveUsds.
5. _getAmountOut(lot, reserveUsds, reserveGem) computes _buy with the stale low reserveUsds:
   amtOut = lot * 997 * reserveGem / (reserveUsds * 1000 + lot * 997)
   Lower reserveUsds in denominator -> _buy appears LARGER than actual market rate.
6. The oracle check passes easily because _buy is inflated by stale data.
7. pair.swap() executes against actual pool reserves (including the donated USDS).
8. The actual swap state has different k than the calculation assumed, causing inefficient price execution.
9. The donated USDS is absorbed into pool reserves permanently (benefiting LP holders, not the attacker).

### Impact

The attacker sacrifices donated USDS to weaken exec()'s slippage protection in a way that FlapperUniV2 would resist via its sync guard. The protocol's per-swap efficiency is degraded. This is a griefing attack where the attacker loses funds but reduces protocol effectiveness — meaningful in scenarios where exact gem buy amounts matter for tokenomics targets.

### Confirmation — No Defense Exists

The asymmetry between the two flapper variants is structural. FlapperUniV2SwapOnly._getReserves() is a pure view function with no sync path. There is no post-facto correction mechanism.

---

## FINDING 3 — Low: OSM poke() Skips Cooldown Enforcement on Source Failure

**File:** /root/audits/sky-protocol/osm/src/osm.sol — lines 131-139

**Severity:** Low (gas griefing / keeper exploitation)

### Vulnerable Code

```solidity
function poke() external note stoppable {
    require(pass(), "OSM/not-passed");
    (bytes32 wut, bool ok) = DSValue(src).peek();
    if (ok) {
        cur = nxt;
        nxt = Feed(uint128(uint(wut)), 1);
        zzz = prev(era());
        emit LogValue(bytes32(uint(cur.val)));
    }
}
```

### Description

When `DSValue(src).peek()` returns `ok = false`, the poke() function exits without updating `zzz`. Since `zzz` only advances on successful poke, the `pass()` check (`era() >= add(zzz, hop)`) remains true indefinitely. Any external caller can invoke `poke()` again immediately with no rate limiting enforced by the contract.

The `note` modifier emits a full anonymous event with 224 bytes of calldata per call, adding significant gas overhead per spam poke. Keeper bots that auto-call poke() when `pass()` returns true will wastefully retry every block during oracle outages.

### Exploit Path

1. Medianizer stops updating (quorum not reached, network partition, etc.)
2. DSValue src starts returning ok=false.
3. OSM poke() no longer updates zzz.
4. pass() permanently returns true.
5. An attacker or misconfigured bot calls poke() every block.
6. Each call: executes the stoppable check, pass() check, peek() call, and the full note modifier event emission.
7. Honest keepers can be griefed: if they race-condition check pass() and submit transactions, they lose gas to the repeated reverts from the note event (which does not revert on failure, but wastes gas).
8. No financial loss, but operational disruption to keeper networks during oracle outages — precisely when reliable keeper behavior is most critical.

### Confirmation — No Defense Exists

There is no zzz update in the failure branch. The explicit pattern `if (ok) { ... zzz = prev(era()); }` means every failure path leaves the cooldown unlocked.

---

## FINDING 4 — Informational: Median poke() Requires Exactly bar Signatures (Misleading Error for Excess Signatures)

**File:** /root/audits/sky-protocol/median/src/median.sol — line 103

**Severity:** Informational

### Vulnerable Code

```solidity
function poke(
    uint256[] calldata val_, uint256[] calldata age_,
    uint8[] calldata v, bytes32[] calldata r, bytes32[] calldata s) external
{
    require(val_.length == bar, "Median/bar-too-low");
```

### Description

The error message "Median/bar-too-low" fires both when `val_.length < bar` AND when `val_.length > bar`, because the check is strict equality. If `bar = 13` and a keeper has collected 15 valid oracle signatures (providing redundancy), the call reverts with "bar-too-low" even though the caller has MORE than enough signatures. The keeper must manually discard 2 signatures.

During time-critical price updates (e.g., rapid market moves), requiring keepers to exactly count and select signatures adds latency and operational complexity. A keeper that submits extra signatures as a safety margin will have all calls fail until they correct the signature count.

No financial exploit is possible since wards are trusted and oracle set is ward-controlled. This is strictly an operational/UX issue with a misleading error message.

---

## FINDING 5 — Informational: SPBEAM file() Allows step = 0 Without Preventing Future Rate Lockout

**File:** /root/audits/sky-protocol/sp-beam/src/SPBEAM.sol — lines 245-246

**Severity:** Informational

### Vulnerable Code

In file() for "step":
```solidity
} else if (what == "step") {
    cfgs[id].step = uint16(data);
```

In set():
```solidity
require(cfg.step > 0, "SPBEAM/rate-not-configured");
```

### Description

A ward can set `step = 0` for any rate identifier (ilk, DSR, or SSR) via `file(id, "step", 0)`. There is no lower-bound validation in `file()`. Once step is zero:

- All future `set()` calls including this identifier revert with "SPBEAM/rate-not-configured"
- The identifier's rate is frozen at its current value until a ward explicitly sets step > 0
- No facilitator can override this — only a ward can unlock it

While this is a ward-controlled action (wards are trusted per scope rules), the absence of a min > 0 check is a footgun. A misconfigured or compromised ward key could silently freeze specific stability fees. The recovery path requires another governance action through the GSM delay.

---

## Full Analysis Summary by Contract

### UNIV2LPOracle — No Critical Findings

The "Fair LP" price formula `2 * sqrt(r0*p0 * r1*p1) / supply` is correctly implemented. Oracle prices p0 and p1 are read from trusted Medianizers (not from pool spot reserves), making the formula manipulation-resistant against flash loans and short-term pool price distortion. The sync() before getReserves() is intentional: donated tokens genuinely increase pool value so the oracle correctly reflects elevated LP worth. The ABDK sqrt implementation is audited and correct. The two-hop delay (nxt -> cur) adds another layer of price manipulation resistance.

### GUniLPOracle — No Critical Findings

The sqrtPriceX96 is derived from oracle prices rather than pool tick state, preventing Uniswap V3 tick manipulation. The intermediate calculation `_mul(_mul(p0, UNIT_1), (1 << 96)) / _mul(p1, UNIT_0)` has a 2^96 scaling factor providing 96 bits of integer precision before the final sqrt — division rounding error is negligible. The `getUnderlyingBalancesAtPrice()` call correctly uses the oracle-derived sqrtPriceX96 to compute manipulation-resistant reserves. The `toUint160()` check prevents silent truncation of extreme sqrtPriceX96 values, reverting instead.

### Median — No Critical Findings

The bloom filter for duplicate-signer detection uses `uint8(uint256(signer) >> 152)` (top byte of address) as a bit index. `lift()` ensures at most one oracle per top-byte slot via the `slot` mapping, making bloom collisions structurally impossible for the authorized oracle set. Median selection `val_[val_.length >> 1]` is correct for odd-length arrays (enforced by `bar % 2 != 0`). Signature recovery correctly binds signatures to `wat` preventing cross-oracle replay.

### OSM — Finding 3 noted above; otherwise secure

The one-hour delay is correctly enforced via `prev(era())` rounding down to hop boundaries and `pass()` requiring `era() >= zzz + hop`. The two-phase cur/nxt buffer correctly enforces the delay. void() emergency zeroes both feeds atomically.

### SPBEAM — Finding 5 noted above; otherwise secure

set() correctly enforces: cooldown (block.timestamp >= tau + toc), bounds (min <= bps <= max), and step size as absolute delta. The clamping logic `if oldBps < min: oldBps = min` is intentional to allow rate corrections when rates are outside configured bounds. The bad circuit breaker and SPBEAMMom.halt() provide emergency shutdown. Solidity 0.8+ checked arithmetic prevents overflow in tau + toc.

### Kicker — No Critical Findings

flap() has no auth modifier intentionally — it is a public keeper function. The condition `int256(dai(vow)) >= int256(sin(vow)) + int256(kbump) + khump` correctly requires real net surplus (noting khump is ward-settable). vat.suck(vow, kicker, kbump) creates kbump of surplus DAI by adding commensurate SIN to vow — this is net-neutral to protocol accounting and backed by existing surplus.

### Splitter — No Critical Findings

kick() correctly computes lot = tot * burn / RAD (WAD-scaled USDS amount) and pay = tot / RAY - lot. Division rounding gives slightly more to the farm, which is the safer direction. The hop cooldown is enforced. FlapLike.exec() receives lot in WAD as expected.

---

## Non-Findings Table

| Area | Finding | Result |
|---|---|---|
| UNIV2LPOracle sync() donation attack | Donated tokens permanently increase k and LP value — oracle correctly reflects reality | Not exploitable |
| GUniLPOracle sqrtPriceX96 precision | 2^96 scaling provides ample integer precision; rounding error sub-unit | Not exploitable |
| GUniLPOracle toUint160 overflow | Reverts (not silently truncates) for extreme price ratios | Not exploitable |
| Median bloom filter collision | lift() enforces one oracle per top-byte slot structurally | Not exploitable |
| Median val_ uint128 truncation | Max uint128 >> any real-world WAD-scaled price | Not exploitable |
| SPBEAM tau+toc overflow | Solidity 0.8+ checked arithmetic; tau uint64 + toc uint128 in uint256 context | Not exploitable |
| SPBEAM cooldown bypass | tau = 0 requires trusted ward; facilitators cannot bypass without ward action | Not exploitable |
| FlapperUniV2 _getUsdsToSell overflow | Solidity 0.8 checked; UniV2 reserves uint112-bounded; no overflow path | Not exploitable |
| Kicker flap() khump negative bypass | vat.suck() creates commensurate sin; net surplus unchanged; wards trusted | Not exploitable |
| OSM hop = 0 | step() requires ts > 0; prev() also guards; safe | Not exploitable |
| Splitter lot+pay rounding | Rounding gives more to farm, not attacker | Not exploitable |
| OracleWrapper divisor = 0 | Ward-set immutable; division by zero reverts safely in exec() | Not exploitable |
| FlapperUniV2 gem donation to pool | Donation absorbed into LP; _buy computed with inflated reserveGem but oracle check consistent | Low impact griefing |

---

## Conclusion

The oracle and flapper contracts demonstrate solid security design: oracle-derived (not spot-reserve-derived) prices for LP tokens, two-phase OSM delay buffers, access-controlled parameter updates, and Solidity 0.8+ arithmetic safety. The most actionable finding is Finding 1 (Medium): both flapper contracts lack any staleness check on the pip oracle, creating a condition where the buyback mechanism is frozen during gem price appreciation — when it is operationally most needed. The fix is to add a maximum staleness check comparing `block.timestamp - OSM.zzz` against a configurable threshold in exec().

Finding 2 (Low-Medium) represents an inconsistency between the two flapper variants where FlapperUniV2SwapOnly is more susceptible to donation-based reserve manipulation than FlapperUniV2. Applying the same sync guard would harden it.

Finding 3 (Low) is a well-known class of OSM behavior that could be more gracefully handled to protect keeper gas costs during source oracle outages.
