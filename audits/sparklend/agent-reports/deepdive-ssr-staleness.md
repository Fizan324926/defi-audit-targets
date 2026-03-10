# Deep-Dive Verification: SSR Oracle Staleness -- Unbounded Rate Extrapolation

## Executive Summary

**VERDICT: NOT EXPLOITABLE -- Working as Designed, with Important Caveats**

After thorough code analysis, the SSR Oracle's unbounded rate extrapolation is an **intentional design choice** that does NOT constitute an exploitable vulnerability meeting Immunefi's impact threshold. Here is why, along with the important nuances.

---

## 1. Verification Question Answers

### Q-A: Can an attacker actually profit from stale oracle data?

**Theoretically yes, but practically infeasible under realistic conditions.**

The attack scenario requires:
1. SSR changes significantly on L1 (e.g., reduced from 5% to 0%)
2. The cross-chain forwarder fails to relay the update
3. The L2 oracle continues extrapolating at the old rate
4. An attacker exploits the price divergence via PSM3

**Why it fails in practice:**

**The forwarders are permissionless.** Anyone can call `refresh()` on any forwarder at any time:

```solidity
// SSROracleForwarderOptimism.sol:16
function refresh(uint32 gasLimit) public {  // <-- No access control
    OptimismForwarder.sendMessageL1toL2(
        l1CrossDomain, address(l2Oracle), _packMessage(), gasLimit
    );
}
```

This means the attacker themselves, or any MEV bot, arbitrageur, or Spark keeper, can trigger an oracle update at any time. An SSR governance change on L1 is a highly visible public event (MakerDAO/Sky governance votes are well-publicized). The moment SSR changes, any interested party can call `refresh()`.

**Bridge latency is the real constraint.** Even after `refresh()` is called, cross-chain messages have inherent delivery delays:
- Optimism/Base: ~7-day challenge period for finality, but messages typically execute within minutes via the sequencer
- Arbitrum: Similar, with force-inclusion after ~24 hours
- Gnosis AMB: Depends on validator set, typically minutes

During this bridge latency window, the L2 oracle would still extrapolate at the old rate. But the window is minutes to hours, not days or months.

**SSR changes are small and gradual.** Sky governance changes the SSR in small increments (e.g., from 5% to 6% APY, or from 5% to 3% APY). The per-second rate difference between SSR values is tiny:

```
5% APY SSR  = 1.000000001547125957863212448e27
6% APY SSR  = 1.000000001847694957439350562e27
Difference  = 0.000000000300569e27 per second
```

Over a 1-hour bridge delay with a 5% -> 0% SSR change (extreme case):
- Old extrapolated rate growth in 1 hour: ~0.000557%
- Actual rate growth (0% SSR): 0%
- Divergence: ~0.000557% of sUSDS value
- On $100M PSM: ~$557 mispricing

This is well below gas costs + slippage for a cross-chain attack, and ignores that the attacker needs sUSDS on L2 already positioned.

### Q-B: How does PSM3 use the SSR oracle rate?

The call chain is traced precisely:

**For swaps involving sUSDS (e.g., sUSDS -> USDC):**
```
swapExactIn(sUSDS, USDC, amount, ...)
  -> previewSwapExactIn(sUSDS, USDC, amount)
    -> _getSwapQuote(sUSDS, USDC, amount, false)
      -> _convertFromSUsds(amount, _usdcPrecision, false)  [PSM3.sol:370-375]
        -> rate = IRateProviderLike(rateProvider).getConversionRate()  [PSM3.sol:373]
        -> return amount * rate / 1e27 * assetPrecision / _susdsPrecision
```

**For deposits of sUSDS:**
```
deposit(sUSDS, receiver, amount)
  -> previewDeposit(sUSDS, amount)
    -> convertToShares(_getAssetValue(sUSDS, amount, false))
      -> _getSUsdsValue(amount, false)  [PSM3.sol:319-324]
        -> amount * IRateProviderLike(rateProvider).getConversionRate() / 1e9 / _susdsPrecision
```

**For withdrawals of sUSDS:**
```
withdraw(sUSDS, receiver, maxAmount)
  -> previewWithdraw(sUSDS, maxAmount)
    -> convertToAssets(sUSDS, numShares)  [PSM3.sol:251-266]
      -> assetValue * 1e9 * _susdsPrecision / IRateProviderLike(rateProvider).getConversionRate()
```

**For totalAssets():**
```
totalAssets()  [PSM3.sol:294-298]
  -> _getSUsdsValue(susds.balanceOf(address(this)), false)
    -> IRateProviderLike(rateProvider).getConversionRate()
```

The rate is used in every sUSDS-related operation. A stale, too-high rate would:
- **Overvalue sUSDS deposits** (depositor gets more shares than deserved)
- **Overvalue sUSDS in swaps** (swapping sUSDS -> USDC yields too much USDC)
- **Undervalue sUSDS withdrawals denominated in sUSDS** (fewer sUSDS tokens returned)

### Q-C: Is there any maxAge or staleness check anywhere in the consumption path?

**No. There is ZERO staleness checking in the entire consumption path.**

Verified locations checked:
1. `SSROracleBase.getConversionRate()` -- No staleness check. Only checks `timestamp > rho`.
2. `SSRAuthOracle.setSUSDSData()` -- No maxAge. Only checks monotonicity.
3. `SSRChainlinkRateProviderAdapter.latestRoundData()` -- Returns `block.timestamp` as `updatedAt`, actively masking staleness.
4. `SSRBalancerRateProviderAdapter.getRate()` -- No staleness check.
5. `PSM3._getSUsdsValue()` -- No staleness check. Blindly trusts `getConversionRate()`.
6. `PSM3._convertToSUsds()` -- No staleness check.
7. `PSM3._convertFromSUsds()` -- No staleness check.

The `IRateProviderLike` interface (`PSM3.sol` line 4-6) has only one function:
```solidity
interface IRateProviderLike {
    function getConversionRate() external view returns (uint256);
}
```
There is no way for PSM3 to check staleness even if it wanted to -- the interface has no `getRho()` or timestamp accessor.

### Q-D: What happens if SSR is reduced to 0 on L1 but L2 still extrapolates?

**SSR cannot be set to 0.** The `SSRAuthOracle` enforces `nextData.ssr >= RAY` (line 39). RAY = 1e27 represents 0% APY (no growth). So the minimum SSR is 1e27, which means chi grows at exactly 0%.

**Scenario: SSR reduced from 5% APY to 0% APY (SSR = RAY):**

At 5% APY, the per-second SSR = 1.000000001547125957863212448e27.

If the L2 oracle is not updated:
- After 1 day: L2 overestimates by ~0.0137% (5%/365)
- After 7 days: L2 overestimates by ~0.096%
- After 30 days: L2 overestimates by ~0.41%
- After 1 year: L2 overestimates by ~5%

For $100M in PSM3:
- 1 day stale: ~$13,700 mispricing
- 7 days stale: ~$96,000 mispricing
- 30 days stale: ~$410,000 mispricing

**But SSR changing from 5% to 0% is an extreme scenario.** Historically, DSR/SSR changes are in the range of 0.5-2 percentage points per governance cycle.

**More realistic scenario: SSR reduced from 6.5% to 4.5% APY:**
- Rate difference per second: ~6.3e-11 * RAY
- After 1 day: ~0.0055% mispricing
- After 7 days: ~0.038% mispricing
- On $100M: ~$38,000 after 7 days

### Q-E: Can anyone permissionlessly update the oracle?

**Yes.** All forwarders have permissionless `refresh()` functions:

```solidity
// SSROracleForwarderOptimism.sol
function refresh(uint32 gasLimit) public { ... }

// SSROracleForwarderArbitrum.sol
function refresh(uint256 gasLimit, uint256 maxFeePerGas, uint256 baseFee) public payable { ... }

// SSROracleForwarderGnosis.sol
function refresh(uint256 gasLimit) public { ... }
```

No access control, no role requirement. Anyone can call these to forward the current L1 SUSDS data to L2. The README explicitly confirms this:

> "Forwarders permissionlessly relay sUSDS data."

**This is the key mitigation.** The oracle does not need a centralized keeper -- anyone who notices an SSR change can trigger an update.

### Q-F: Has this been reported before?

**Yes, partially.** The existing `group5-ssr-oracle.md` audit report (Finding 1 and Finding 2) already identifies:
- The lack of staleness protection (Finding 1, rated Medium)
- The misleading Chainlink adapter `updatedAt` (Finding 2, rated Medium)

The report correctly identifies these as design choices. No on-chain mitigations have been deployed.

The README itself acknowledges the design:
> "Provided the three sUSDS values (ssr, chi and rho) are synced you can extrapolate an exact exchange rate to any point in the future **for as long as the ssr value does not get updated on mainnet**. Because this oracle **does not need to be synced unless the ssr changes**, it can use the chain's canonical bridge for maximum security."

This confirms the team is fully aware that the oracle only needs updating when SSR changes. The extrapolation is the explicit design intent -- not a bug.

### Q-G: Could SSR change significantly enough to create a profitable exploit?

**Unlikely under realistic conditions.**

**SSR change frequency and magnitude:**
- SSR changes require MakerDAO/Sky governance votes (executive spells)
- Changes are typically 0.5-2 percentage points
- Changes are announced days in advance through governance forums
- Multiple parties (Spark team, keepers, MEV bots) have incentive to call `refresh()` immediately

**The exploit requires ALL of these conditions simultaneously:**
1. Large SSR change (> 2 percentage points)
2. Nobody calls `refresh()` on L1 for the affected chain
3. Cross-chain bridge message fails or is censored
4. Attacker has positioned capital on L2 before the SSR change
5. Mispricing exceeds gas costs + bridge costs + capital costs

**The economic incentive runs against the attacker.** If the SSR drops on L1, any observer can profitably:
1. Call `refresh()` on the forwarder (costs: L1 gas + bridge gas, typically < $50)
2. Wait for message to land on L2 (minutes to hours)
3. The oracle updates, closing any mispricing

The "race" is between the attacker and every other observer/keeper/bot. The attacker has no advantage because the forwarder is permissionless.

---

## 2. Chainlink Adapter `updatedAt = block.timestamp` Analysis

### The Issue

```solidity
// SSRChainlinkRateProviderAdapter.sol:39-52
function latestRoundData() external view returns (...) {
    return (
        0,                                        // roundId
        int256(ssrOracle.getConversionRate()),     // answer
        0,                                        // startedAt
        block.timestamp,                          // updatedAt <-- ALWAYS "now"
        0                                         // answeredInRound
    );
}
```

### Can this deceive downstream protocols?

**Yes, but the actual impact depends on who consumes this adapter.**

**AaveOracle (SparkLend):** The `AaveOracle.getAssetPrice()` function (line 101-116) only checks `latestAnswer() > 0`. It does NOT check `updatedAt` or `roundId`. So the Chainlink adapter's misleading `updatedAt` has **no impact** on SparkLend's AaveOracle.

```solidity
// AaveOracle.sol:108-114
int256 price = source.latestAnswer();
if (price > 0) {
    return uint256(price);
} else {
    return _fallbackOracle.getAssetPrice(asset);
}
```

**Third-party protocols:** If an external protocol integrates the SSR Chainlink adapter and implements a standard staleness check like:
```solidity
(, int256 price,, uint256 updatedAt,) = feed.latestRoundData();
require(block.timestamp - updatedAt < MAX_STALE, "stale");
```
This check would always pass, even if the underlying SSR data is months old. This could deceive such a protocol.

**However**, this is a known design consideration. The README and code comments make clear that the rate is extrapolated, not periodically reported. The adapter is designed for use within the Spark ecosystem (PSM3, Balancer, SparkLend), where the consumption pattern does not include staleness checks.

### Severity Assessment for Chainlink Adapter

**Low/Informational.** The adapter is honest in what it does -- it returns the current extrapolated rate, which IS up-to-date given the current oracle parameters. The `updatedAt = block.timestamp` is arguably correct in the sense that the calculation was performed at the current block, even though the *inputs* to the calculation may be old. The real question is whether this semantic difference could cause harm to downstream consumers, and within the Spark ecosystem, it does not.

---

## 3. Comprehensive Severity Analysis

### Why this is NOT a Critical/High vulnerability:

1. **By Design:** The README explicitly states the oracle extrapolates indefinitely and only needs syncing when SSR changes. The team is aware of and has intentionally chosen this design.

2. **Permissionless Updates:** Anyone can call `refresh()` to trigger an oracle sync. There is no centralized dependency that could fail. The attack requires NO ONE to notice an SSR governance change for an extended period, which is unrealistic.

3. **SSR Changes Are Predictable:** SSR changes go through MakerDAO governance, which is a multi-day public process. There is ample warning before any SSR change takes effect.

4. **Small Divergence Window:** The realistic divergence window is minutes to hours (bridge latency after someone calls `refresh()`), during which the mispricing is negligible. Even at 5% APY, 1 hour of stale data = ~0.00057% mispricing.

5. **No Attacker Advantage:** The attacker cannot prevent others from updating the oracle. They cannot front-run the update because it goes through a cross-chain bridge. They cannot profit from minutes of mispricing because the amounts are too small relative to gas/bridge costs.

6. **SSR Minimum is RAY:** The `SSRAuthOracle` enforces `ssr >= RAY`, meaning the rate can never go negative. The worst case is that the oracle slightly overestimates growth (if SSR was reduced) or slightly underestimates growth (if SSR was increased), but the direction of error is predictable.

### Edge Cases That Could Increase Severity:

1. **Prolonged bridge failure:** If a canonical bridge is completely non-functional for weeks (unprecedented for Optimism/Arbitrum/Gnosis), the oracle would diverge. But bridge failure would likely halt all L2 operations, not just the oracle.

2. **Emergency SSR change:** If governance makes an emergency SSR reduction (e.g., a depegging event), the L2 oracle would lag. But emergency scenarios typically involve broader protocol pauses.

3. **Sequencer censorship:** An L2 sequencer could theoretically censor oracle update transactions. But this would be detectable and there are force-inclusion mechanisms on all supported chains.

---

## 4. Final Verdict

### Is this a real, exploitable vulnerability meeting Immunefi's in-scope impact threshold?

**NO.**

**Rationale:**

This is a known design trade-off, not a vulnerability. The oracle's README explicitly documents that it extrapolates indefinitely and only needs updating when the SSR changes. The forwarders are permissionless, ensuring anyone can trigger an update. The economic incentive structure means that any significant SSR change would be relayed to L2 within minutes by keepers, MEV bots, or concerned users.

For Immunefi's impact categories:
- **Direct theft of funds**: Not achievable. The mispricing during realistic bridge latency windows is too small to extract meaningful value.
- **Permanent freezing of funds**: Not applicable.
- **Protocol insolvency**: Not achievable through this vector alone.
- **Griefing**: No -- the attacker has no ability to delay oracle updates (since updates are permissionless).
- **Temporary freezing**: Not applicable.

**The Chainlink adapter's `updatedAt = block.timestamp` is the more defensible finding**, but its impact is limited to hypothetical third-party integrations that are not part of the Spark protocol. Within Spark's own consumption path (PSM3 and SparkLend), no staleness check is performed on the rate.

### Recommendation (Defensive Improvement, Not Bug Fix)

While not an exploitable vulnerability, the following defensive improvements would strengthen the system:

1. **Add an optional `maxAge` parameter** to `SSRAuthOracle` that reverts `getConversionRate()` if `block.timestamp - rho > maxAge`. This should be optional (defaulting to 0 = unlimited) to preserve the current behavior.

2. **Chainlink adapter should return `rho` as `updatedAt`**, not `block.timestamp`. This is more semantically honest and enables downstream consumers to implement their own staleness checks if desired.

3. **Consider emitting events on SSR changes** that off-chain monitoring can detect to trigger immediate `refresh()` calls across all chains.

These are hardening recommendations, not vulnerability fixes.

---

## Appendix: Key Code References

| File | Lines | Relevance |
|------|-------|-----------|
| `SSROracleBase.sol` | 44-58 | `getConversionRate()` -- the extrapolation logic with no staleness check |
| `SSRAuthOracle.sol` | 32-70 | `setSUSDSData()` -- data validation but no maxAge enforcement |
| `SSRAuthOracle.sol` | 39 | `require(nextData.ssr >= RAY)` -- SSR can never be below 1e27 |
| `SSRChainlinkRateProviderAdapter.sol` | 39-52 | `latestRoundData()` returning `block.timestamp` as `updatedAt` |
| `PSM3.sol` | 319-328 | `_getSUsdsValue()` -- blindly trusts `getConversionRate()` |
| `PSM3.sol` | 357-381 | `_convertToSUsds()` / `_convertFromSUsds()` -- rate-dependent swap pricing |
| `SSROracleForwarderOptimism.sol` | 16 | `refresh()` -- permissionless, public callable |
| `SSROracleForwarderArbitrum.sol` | 16-29 | `refresh()` -- permissionless, public payable |
| `SSROracleForwarderGnosis.sol` | 14-20 | `refresh()` -- permissionless, public callable |
| `README.md` | Line 3 | Explicit documentation that oracle extrapolates indefinitely by design |

## Appendix: Numerical Analysis

### SSR Values (from tests and mainnet):
```
0% APY SSR    = 1.000000000000000000000000000e27 (RAY, no growth)
5% APY SSR    = 1.000000001547125957863212448e27
100% APY SSR  = 1.000000021979553151239153020e27
```

### Divergence Over Time (5% APY oracle vs 0% actual):
```
1 hour:    0.000557%   ($557 on $100M)
1 day:     0.01337%    ($13,370 on $100M)
7 days:    0.0936%     ($93,600 on $100M)
30 days:   0.405%      ($405,000 on $100M)
365 days:  5.0%        ($5,000,000 on $100M)
```

### Divergence Over Time (6.5% -> 4.5% APY, more realistic):
```
1 hour:    0.000228%   ($228 on $100M)
1 day:     0.00548%    ($5,480 on $100M)
7 days:    0.0384%     ($38,400 on $100M)
```

### Cost of Attack:
```
L1 gas for forwarder refresh():  ~$5-50
L2 gas for PSM3 swap:            ~$0.01-0.50
Cross-chain bridge fee:           ~$0-10
Capital cost (opportunity):       Variable
```

Bottom line: The mispricing during realistic bridge latency windows (minutes to hours) is far too small to justify the attack complexity and capital requirements. The permissionless nature of the forwarders makes sustained oracle staleness practically impossible.
