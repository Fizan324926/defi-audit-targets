# Deep-Dive Verification: SavingsDaiOracle Reads Stale chi Without Dripping

## Summary

**VERDICT: NOT EXPLOITABLE for meaningful profit. Does NOT meet Immunefi's in-scope impact threshold.**

The theoretical issue is real but the practical impact is negligible. The stale chi problem produces an underpricing of sDAI that is too small to overcome liquidation bonus margins, and an attacker has no mechanism to *prevent* drip() from being called by others. Furthermore, this is a well-known design pattern in MakerDAO's ecosystem and is arguably a "third-party oracle" limitation excluded from scope.

---

## 1. How SavingsDaiOracle Computes the sDAI Price

**File:** `/root/immunefi/audits/sparklend/src/sparklend/src/SavingsDaiOracle.sol` (lines 28-29)

```solidity
function latestAnswer() external view returns (int256) {
    return _daiPriceFeed.latestAnswer() * _pot.chi().toInt256() / RAY;
}
```

The price is computed as:

```
sDAI_price = DAI_price * Pot.chi() / RAY
```

Two inputs:
- **DAI price** from a Chainlink aggregator (`_daiPriceFeed.latestAnswer()`)
- **chi** from MakerDAO's Pot contract (`_pot.chi()`)

**chi is the only time-dependent component.** The DAI price feed updates via standard Chainlink oracle rounds. The chi value is the DSR rate accumulator, representing how much 1 normalized DAI of savings has grown since inception. It starts at 1 RAY (1e27) and grows continuously based on the DSR.

**Critical distinction:** `Pot.chi()` is a **storage variable**, not a computed value. It only updates when someone calls `Pot.drip()`. Between drip calls, chi reflects the value at the time of the last drip, NOT the current accrued value.

**Contrast with the sDAI ERC-4626 contract itself:** The SavingsDai.sol `convertToAssets()` function computes the correct current chi value in a view function:

```solidity
function convertToAssets(uint256 shares) public view returns (uint256) {
    uint256 rho = pot.rho();
    uint256 chi = (block.timestamp > rho)
        ? _rpow(pot.dsr(), block.timestamp - rho) * pot.chi() / RAY
        : pot.chi();
    return shares * chi / RAY;
}
```

This extrapolates from the stored chi/rho using `_rpow(dsr, elapsed)`, giving the correct current value. The SavingsDaiOracle does NOT do this -- it reads the raw stored chi.

**Also contrast with the SSR Oracle system** (`SSROracleBase.sol`), which stores `ssr`, `chi`, and `rho` and extrapolates via `_rpow(ssr, block.timestamp - rho) * chi / RAY`. This is the improved design for the USDS/sUSDS system.

---

## 2. How Stale Can chi Get?

### Pot.drip() Mechanics

The Pot contract's `drip()` function:
1. Computes `tmp = _rpow(dsr, now - rho) * chi`
2. Updates `chi = tmp / RAY`
3. Updates `rho = now`
4. Mints new DAI via `vat.suck()` proportional to `Pie * (new_chi - old_chi)`

**Who calls drip()?**

- The SavingsDai.sol contract itself calls `pot.drip()` on every `deposit()`, `withdraw()`, `mint()`, and `redeem()` operation (if `block.timestamp > pot.rho()`).
- Any user interacting with DSR through the DSRManager or directly.
- Keeper bots maintained by MakerDAO and others.
- The daidrip.tech service exists specifically for this purpose.
- MakerDAO governance spells call drip() when changing the DSR.

### Practical Drip Frequency

Given that sDAI has billions in TVL and the DSR is currently 11.25% APY (as of January 2025), there is significant economic activity -- deposits, withdrawals, and arbitrage -- that triggers drip() extremely frequently. At high DSR rates, the economic incentive to call drip() is stronger because more interest accrues per unit of time.

**In practice, drip() is called at least every few blocks during normal market conditions.** Prolonged staleness (hours) would be extremely unusual and would require either:
- Total cessation of all sDAI deposit/withdrawal activity
- Ethereum network congestion so severe that no transactions can be processed
- A coordinated decision by all keepers to stop calling drip()

None of these scenarios are realistic for a protocol with billions in TVL and an 11%+ savings rate.

---

## 3. Staleness Impact Calculation

### Formula

The underpricing of sDAI due to stale chi:

```
underpricing_factor = 1 - chi_stale / chi_current
                    = 1 - 1 / rpow(dsr, elapsed_seconds)
```

For small elapsed times, this approximates to:

```
underpricing ~ (dsr_annual_rate) * (elapsed_seconds / seconds_per_year)
```

### Calculations at DSR = 11.25% APY

| Staleness Period | Underpricing (%) | Per $1M sDAI |
|------------------|------------------|--------------|
| 1 minute         | 0.0000214%       | $0.21        |
| 10 minutes       | 0.000214%        | $2.14        |
| 1 hour           | 0.00128%         | $12.85       |
| 12 hours         | 0.01541%         | $154.06      |
| 24 hours         | 0.03082%         | $308.12      |
| 7 days           | 0.2148%          | $2,148.27    |

### Calculations at DSR = 5% APY (historical lower rate)

| Staleness Period | Underpricing (%) | Per $1M sDAI |
|------------------|------------------|--------------|
| 1 hour           | 0.000571%        | $5.71        |
| 12 hours         | 0.00685%         | $68.49       |
| 24 hours         | 0.01370%         | $136.99      |

### Key takeaway

Even at a very aggressive 11.25% DSR with a 24-hour staleness period (which is unrealistically long), sDAI would only be underpriced by ~0.03%. This is far below typical liquidation bonus margins (5-10%).

---

## 4. Can Stale chi Cause Incorrect Liquidations?

### How Health Factor Is Computed

From `GenericLogic.sol` (lines 172-176):

```solidity
vars.healthFactor = (vars.totalDebtInBaseCurrency == 0)
    ? type(uint256).max
    : (vars.totalCollateralInBaseCurrency.percentMul(vars.avgLiquidationThreshold)).wadDiv(
        vars.totalDebtInBaseCurrency
      );
```

A position is liquidatable when `healthFactor < 1e18` (i.e., < 1.0).

From `ValidationLogic.sol` (line 523):

```solidity
require(
    params.healthFactor < HEALTH_FACTOR_LIQUIDATION_THRESHOLD,
    Errors.HEALTH_FACTOR_NOT_BELOW_THRESHOLD
);
```

Where `HEALTH_FACTOR_LIQUIDATION_THRESHOLD = 1e18`.

### Impact on health factor

If sDAI is used as collateral, the oracle underpricing reduces `totalCollateralInBaseCurrency`, which reduces the health factor. A position that should be healthy could appear undercollateralized.

**However**, the magnitude matters:

For a position to be incorrectly liquidated, it would need to be in the narrow band where the stale price pushes it below HF=1.0 but the correct price keeps it above. Given the underpricing is ~0.03% at most (24h staleness at 11.25% DSR), only positions with health factors between 1.0000 and 1.0003 would be affected.

In practice:
- Users maintain health factors well above 1.0 (typically 1.5-3.0+)
- The liquidation threshold for sDAI is already conservative (around 77-80%)
- The 0.03% difference is within normal oracle price jitter from the DAI Chainlink feed

**Conclusion: Incorrect liquidations are theoretically possible but practically implausible.** They would only affect positions that are already teetering on the liquidation boundary, where even normal price fluctuations in DAI's Chainlink feed would have a much larger effect.

---

## 5. Can An Attacker Exploit This?

### Attack Scenario Analysis

The hypothetical attack would require:

1. **Prevent drip() from being called** -- The attacker would need to prevent ALL other participants from calling drip() for an extended period. This is **impossible** because:
   - drip() is a public function callable by anyone
   - sDAI deposit/withdraw operations automatically call drip()
   - Keeper bots continuously call drip()
   - The attacker cannot censor Ethereum transactions

2. **Find positions in the narrow HF band** -- Even if chi were stale, the attacker needs positions with HF in the 1.0000-1.0003 range (for 24h staleness). These are extremely rare.

3. **The liquidation bonus must exceed the profit** -- Liquidation bonuses on SparkLend are typically 5-10%. The 0.03% underpricing is dwarfed by the bonus the liquidator receives anyway. A position that is liquidatable at the stale price would also yield the same liquidation bonus at the correct price if the position is genuinely underwater.

4. **Front-running drip()** -- An attacker could theoretically try to call liquidation before someone calls drip() in the same block. But any rational actor (including the borrower) could front-run the liquidation with a drip() call, updating chi and restoring the correct price.

**The attack is not economically viable:**
- Cannot prevent drip() calls
- The underpricing window is too narrow
- Profit margin (0.03% max) is below gas costs for the attack
- Borrowers can defend by calling drip() themselves

---

## 6. Scope Analysis: Is Pot.chi() a "Third-Party Oracle"?

This is the most important question for Immunefi scope.

### Arguments that it IS a third-party oracle (OUT of scope):
- MakerDAO's Pot contract is a separate protocol from Spark
- chi() is a read from an external contract not controlled by Spark governance
- The Pot contract's behavior (requiring drip() for updates) is entirely MakerDAO's design
- SavingsDaiOracle is explicitly an adapter that bridges MakerDAO's price data into SparkLend
- This is analogous to reading a Chainlink price feed -- the oracle contract doesn't control the underlying data source

### Arguments that it is NOT a third-party oracle (IN scope):
- SavingsDaiOracle was purpose-built by the Spark team
- The design *choice* to read raw chi() instead of computing the current value (as SavingsDai.sol's convertToAssets() does) is a Spark implementation decision
- Spark could have included the rpow extrapolation logic (as they did in SSROracleBase for sUSDS)

### Assessment

This is most likely **classified as a third-party oracle issue** by Immunefi triagers. The root cause is MakerDAO's Pot.chi() requiring drip() to update -- this is inherent to MakerDAO's design, not a bug in Spark's code. Spark's oracle faithfully reads the data from its source; the "staleness" is a property of the source itself.

Furthermore, the Spark team clearly understands this pattern -- their newer SSR Oracle system (`SSROracleBase.sol`) extrapolates from chi/rho using `_rpow`, which is the mitigation for exactly this class of issue. The fact that the older SavingsDaiOracle uses the simpler (but slightly stale) approach suggests this was a deliberate design choice accepted for sDAI on mainnet (where drip frequency is high enough to be negligible).

---

## 7. Maximum Financial Impact

### Parameters
- sDAI supply cap on SparkLend: 60 million sDAI
- Assuming full utilization: ~$60M in sDAI collateral
- DSR: 11.25% APY
- Maximum realistic staleness: 1 hour (generous estimate)

### Calculation

```
Underpricing at 1h staleness = 0.00128%
Max undervaluation = $60M * 0.0000128 = $768
```

For 24h staleness (extremely unrealistic):
```
Max undervaluation = $60M * 0.000308 = $18,493
```

### Additional considerations
- Not all sDAI depositors would have positions near the liquidation threshold
- Liquidation bonus already compensates liquidators; the underpricing does not create *new* profit opportunities
- The ~$768 at realistic staleness is far below Immunefi's minimum threshold for meaningful impact

---

## 8. Comparison with SSR Oracle Design (Newer System)

The SSR Oracle system demonstrates that Spark is aware of this design pattern:

**SavingsDaiOracle (old, for sDAI):**
```solidity
// Reads raw chi -- stale between drip() calls
return _daiPriceFeed.latestAnswer() * _pot.chi().toInt256() / RAY;
```

**SSROracleBase (new, for sUSDS):**
```solidity
// Extrapolates from stored data -- always current
return _rpow(d.ssr, duration) * uint256(d.chi) / RAY;
```

The SSR Oracle stores `ssr`, `chi`, and `rho` and extrapolates the current conversion rate. This is the correct approach and eliminates the staleness issue entirely (at the cost of storing additional data).

However, the SSR Oracle system introduces its own risks (staleness when the SSR changes but the oracle is not updated -- see Finding 1 in the SSR Oracle audit report). Neither approach is perfect; they trade off different risk profiles.

---

## VERDICT

### Is this exploitable for profit?

**No.** The attack requires:
1. Preventing drip() calls (impossible on a permissionless network)
2. Finding positions in an extremely narrow HF band (~0.03% window)
3. Extracting profit that exceeds gas costs from that narrow window

### Does it meet Immunefi's in-scope impact threshold?

**No, for multiple reasons:**

1. **Third-party oracle exclusion:** The root cause is MakerDAO's Pot.chi() behavior -- a third-party oracle dependency. Spark's oracle faithfully reads the data available to it.

2. **Negligible financial impact:** Maximum realistic undervaluation is ~$768 per hour of staleness across the entire $60M supply cap. This is far below meaningful impact thresholds.

3. **No attacker control:** An attacker cannot control the staleness period because drip() is permissionless and called continuously by keepers and user interactions.

4. **Known design pattern:** This is an accepted characteristic of MakerDAO's Pot module, acknowledged by the entire DeFi ecosystem. Spark's newer oracle system (SSR Oracle) already uses the improved extrapolation approach for sUSDS.

5. **Self-correcting:** Any staleness is automatically corrected by the next drip() call, which happens frequently during normal operations.

### Severity Classification

If submitted to Immunefi, this would most likely be classified as:
- **Informational / Out of Scope** -- Third-party oracle behavior, negligible impact
- At best, **Low** -- Known design limitation with no practical exploit path

### Recommendation (for the protocol, not for Immunefi submission)

While not a vulnerability, the SavingsDaiOracle could be improved to match the SSR Oracle pattern:

```solidity
// Improved version (hypothetical)
function latestAnswer() external view returns (int256) {
    uint256 rho = _pot.rho();
    uint256 chi = (block.timestamp > rho)
        ? _rpow(_pot.dsr(), block.timestamp - rho) * _pot.chi() / RAY
        : _pot.chi();
    return _daiPriceFeed.latestAnswer() * chi.toInt256() / RAY;
}
```

This would eliminate the staleness entirely by extrapolating the current chi value, as the SavingsDai.sol contract itself does in its `convertToAssets()` function.

---

## References

- [SavingsDaiOracle.sol](https://github.com/marsfoundation/sparklend/blob/master/src/SavingsDaiOracle.sol)
- [MakerDAO Pot Documentation](https://docs.makerdao.com/smart-contract-modules/rates-module/pot-detailed-documentation)
- [MakerDAO Pot Source (dss/pot.sol)](https://github.com/makerdao/dss/blob/master/src/pot.sol)
- [SavingsDai.sol Source](https://github.com/makerdao/sdai)
- [SparkLend on DefiLlama](https://defillama.com/protocol/spark)
- [Spark Docs - sDAI Token](https://docs.spark.fi/dev/savings/sdai-token)
- [Spark Docs - Liquidations](https://docs.spark.fi/dev/sparklend/features/liquidations)
- [MakerDAO DSR Rate Changes (Jan 2025)](https://vote.makerdao.com/executive/template-executive-vote-stability-fee-change-dai-savings-rate-change-launch-project-funding-integration-boost-funding-aligned-delegate-compensation-atlas-core-developer-payments-new-suckable-usds-vest-contract-setup-new-transferrable-sky-vest-contract-setup-setting-facilitator-payment-streams-sparklend-aave-q4-2024-revenue-share-payment-taco-dao-resolution-approval-spark-proxy-spell-january-23-2025)
