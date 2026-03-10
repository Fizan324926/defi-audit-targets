# Spark Protocol: Cross-Contract and Economic Deep-Dive

**Audit Scope:** Cross-system interactions and economic attacks across SparkLend, PSM3, ALM Controller, SSR Oracle, Spark Vaults V2, and Governance.

**Methodology:** Bottom-up analysis of all inter-contract data flows, rate dependencies, and trust boundaries, followed by top-down attack vector assessment.

---

## System Architecture Summary

### Key Trust Boundaries

1. **ALMProxy** (`ALMProxy.sol`): A universal proxy that executes arbitrary calls on behalf of `CONTROLLER`-role holders. Both `MainnetController` and `ForeignController` are expected CONTROLLER-role holders.
2. **RateLimits** (`RateLimits.sol`): Central rate-limiting engine shared across all controller operations. Uses a slope-based refill model with per-key tracking.
3. **PSM3** (`PSM3.sol`): L2 stablecoin PSM accepting USDC, USDS, and sUSDS. Uses an `IRateProviderLike` (which is the SSRAuthOracle on L2s) for sUSDS valuation.
4. **SSRAuthOracle** (`SSRAuthOracle.sol`): Receives L1 SSR data via permissioned `DATA_PROVIDER_ROLE`. Computes live conversion rates via `_rpow(ssr, block.timestamp - rho)`.
5. **SparkVault** (`SparkVault.sol`): ERC4626 vault with its own rate accumulator (`chi`, `vsr`, `rho`). Has `TAKER_ROLE` that can withdraw assets without burning shares.
6. **MainnetController** (`MainnetController.sol`): L1 controller with access to Maker Vault (mint/burn USDS), PSM (USDC<->USDS), CCTP bridge, LayerZero, Aave, Curve, UniV4, ERC4626, OTC swaps, Ethena, Maple, Superstate, wstETH, weETH, and SparkVault.
7. **ForeignController** (`ForeignController.sol`): L2 controller with access to PSM3, Aave, CCTP, LayerZero, ERC4626, and SparkVault.

### Critical Data Flow Chains

```
L1 SSR (MakerDAO sUSDS) --> SSRMainnetOracle.refresh() --> stored (ssr, chi, rho)
                                                              |
                                                         [Bridge: Offchain relay]
                                                              |
                                                         SSRAuthOracle.setSUSDSData() --> stored (ssr, chi, rho)
                                                              |
                                                         SSROracleBase.getConversionRate() = _rpow(ssr, block.timestamp - rho) * chi / RAY
                                                              |
                                                         PSM3._getSUsdsValue() uses getConversionRate()
                                                              |
                                                         PSM3.totalAssets(), deposit(), withdraw(), swap*()
```

```
MainnetController.mintUSDS() --> Maker Vault draw --> buffer --> proxy (USDS)
MainnetController.swapUSDSToUSDC() --> PSMLib --> USDS->DAI->USDC
MainnetController.transferUSDCToCCTP() --> CCTP --> [L2 bridge] --> L2 USDC
ForeignController.depositPSM() --> PSM3 (L2) --> shares
```

---

## Attack Vector Analysis

---

### 1. Cross-Chain Rate Arbitrage via SSR Oracle Delay

**Feasibility: 4/10**

**Attack Scenario:**
The SSRAuthOracle on L2 receives SSR updates from L1 via a permissioned `DATA_PROVIDER_ROLE` relay. If the L1 SSR changes (e.g., MakerDAO governance increases the rate), there is an inherent delay before L2 oracles are updated. During this window:

1. Attacker observes L1 SSR increase (e.g., from 5% to 8% APY).
2. On L2 (where the oracle still reflects old SSR), `getConversionRate()` uses `_rpow(old_ssr, block.timestamp - rho)`, computing a LOWER conversion rate for sUSDS than the true rate.
3. Attacker swaps USDC/USDS for sUSDS in PSM3 at the stale (cheaper) rate.
4. After oracle updates, sUSDS is now valued higher. Attacker swaps back for profit.

**Analysis of Profit:**
- The SSRAuthOracle uses **continuous compounding** from the last `rho` timestamp: `_rpow(ssr, block.timestamp - rho) * chi / RAY`.
- Critically, it uses the **stored** `ssr` value, not the L1 live value. So during the delay, the L2 oracle still accrues at the OLD rate.
- The arbitrage profit = difference in sUSDS value computed with old_ssr vs new_ssr over the delay period.
- For a 3% SSR increase (e.g., 5% -> 8%) and a 1-hour delay: the price difference on sUSDS is approximately `3% / (365.25 * 24) = 0.000342%`.
- On $10M: ~$34.20 profit. On $100M: ~$342.

**Maximum Potential Profit:** Low. Even with $100M capital and multi-hour delays, profit is in the hundreds of dollars range because SSR changes are small in per-second terms.

**What Blocks the Attack:**
- SSRAuthOracle sanity checks: `nextData.ssr >= RAY`, `nextData.chi >= previousData.chi`, `nextData.rho >= previousData.rho`, and optional maxSSR bound on chi accumulation.
- The oracle **continuously accrues** based on stored ssr, so the actual pricing gap is only the *differential* rate over the delay window, not a step function.
- PSM3 deposit/withdraw don't use flashloans (they pull from msg.sender).
- Capital requirements for meaningful profit are extremely high relative to gain.

---

### 2. ALM-PSM3 Interaction: Relayer Front-Running PSM3 Deposits

**Feasibility: 2/10**

**Attack Scenario:**
The RELAYER role on ForeignController can deposit into PSM3 (`depositPSM`) and withdraw from PSM3 (`withdrawPSM`). Could a malicious relayer or front-runner manipulate PSM3 state before/after deposits?

1. Relayer calls `depositPSM(USDC, 1M)`.
2. Before this tx, attacker front-runs by depositing a large amount of sUSDS into PSM3, inflating `totalAssets` relative to `totalShares`.
3. This causes the relayer's deposit to receive fewer shares (since `convertToShares = assetValue * totalShares / totalAssets`).
4. After relayer's deposit, attacker withdraws their sUSDS, deflating the pool.

**Analysis:**
- PSM3 share calculation: `newShares = convertToShares(_getAssetValue(asset, assetsToDeposit, false))`.
- `convertToShares(assetValue) = assetValue * totalShares / totalAssets()`.
- The attacker would need to deposit a massive amount to meaningfully skew the ratio.
- The attacker's own deposit creates shares proportionally, so they don't get "free" inflation.
- **Donation attack variant**: Direct token transfer to PSM3 address (not via deposit) would inflate `totalAssets()` without minting shares. For USDC, this would work only if the USDC is sent to the `pocket` address (since `totalAssets` reads `usdc.balanceOf(pocket)`). For USDS/sUSDS, sent to `address(this)`.
- However, this is a donation by the attacker -- they lose the donated tokens. The profit from share manipulation must exceed the donation.

**Maximum Potential Profit:** Negligible. The attacker must donate more value than they can extract from share ratio manipulation. Standard ERC4626 donation attack economics apply: the first depositor is most vulnerable, but PSM3 will already have significant TVL when the ALM deposits.

**What Blocks the Attack:**
- PSM3 uses proper share accounting with rounding protection (roundUp on withdrawals).
- The pool will have significant existing liquidity (not a fresh vault).
- Rate-limited deposits mean the relayer can only deposit bounded amounts per time window.
- The attacker has no way to extract value exceeding their donation.

---

### 3. Flash Loan + PSM3 Manipulation

**Feasibility: 2/10**

**Attack Scenario:**
An attacker uses a flash loan on L2 (e.g., from Aave on Arbitrum) to:
1. Borrow a massive amount of USDC.
2. Deposit into PSM3 to get shares, inflating totalAssets.
3. Execute some action that benefits from the inflated state.
4. Withdraw from PSM3.
5. Repay flash loan.

**Analysis:**
- PSM3.deposit() uses `safeTransferFrom` to pull assets from `msg.sender`. Flash-loaned tokens can be used.
- PSM3.withdraw() burns shares from `msg.sender` (the `shares[msg.sender]` mapping). The flash loan borrower would need to be the same address.
- In a single transaction: deposit(USDC) -> get shares -> withdraw(USDC) -> repay. Due to rounding (deposit rounds shares down, withdraw rounds shares up), the attacker would get back <= what they deposited. No profit.
- Could the attacker manipulate the conversion rate for OTHER users? Only if another user's tx is sandwiched. But PSM3 conversions are deterministic based on rateProvider, balances, and shares -- not AMM-style. Depositing USDC doesn't change the USDC/USDS/sUSDS conversion rates.
- The only price-sensitive asset is sUSDS, whose value comes from the rateProvider oracle, which is immutable within a transaction.

**Maximum Potential Profit:** Zero. PSM3 is not an AMM -- it uses oracle-based pricing. Flash-loan deposits/withdrawals don't create price impact for other users.

**What Blocks the Attack:**
- PSM3 is oracle-based, not AMM-based. No price impact from deposits.
- Rounding works against the attacker (deposit rounds down, withdraw rounds up for shares).
- The rateProvider is immutable and cannot be manipulated within a tx.

---

### 4. Supply-Side Attack via ALM: Cross-Venue Rate Manipulation

**Feasibility: 3/10**

**Attack Scenario:**
The ALM controller supplies USDC/USDS to multiple venues: Aave, PSM3, Curve, UniV4. Could manipulating one venue's rate affect another?

1. Attacker manipulates Aave interest rates by massive borrowing, raising utilization.
2. ALM relayer sees high Aave rates, moves funds from PSM3 to Aave (withdrawPSM -> depositAave).
3. PSM3 loses liquidity, potentially causing withdrawal issues for other users.
4. Attacker profits from the rate differential.

**Analysis:**
- Each venue has **independent rate limits** in the ALM controller. The relayer cannot move unlimited funds.
- Rate limits on PSM withdrawal: `LIMIT_PSM_WITHDRAW` is per-asset, bounded.
- Rate limits on Aave deposit: `LIMIT_AAVE_DEPOSIT` is per-aToken, bounded.
- The relayer is a trusted (permissioned) role, not a permissionless actor.
- Even if the relayer moves funds, PSM3 doesn't become insolvent -- it just has less of certain assets. Withdrawals are capped at available balance.
- The venues have no direct rate dependency on each other.

**Maximum Potential Profit:** Negligible for external attackers. The relayer is trusted and rate-limited.

**What Blocks the Attack:**
- All relayer operations are rate-limited with independent caps per venue.
- RELAYER is a permissioned role (not permissionless).
- No cross-venue oracle dependency.
- PSM3 gracefully handles low liquidity (withdrawals capped at balance).

---

### 5. Governance Relay Front-Running

**Feasibility: 3/10**

**Attack Scenario:**
L1 governance sends a message to L2 (e.g., via L1->L2 bridge) to change a PSM3 parameter (like pocket), update SSR oracle bounds, or change rate limits. An attacker sees this pending bridge message and front-runs it.

Example:
1. Governance votes to reduce the maxSSR bound on SSRAuthOracle.
2. Before the L2 governance execution, the attacker:
   - Checks current sUSDS conversion rate (which may be inflated if SSR is high).
   - Sells sUSDS on PSM3 at the current high rate.
3. After governance execution, the oracle rate is capped lower.
4. Attacker buys back sUSDS at the lower rate.

**Analysis:**
- SSRAuthOracle.setMaxSSR() is `onlyRole(DEFAULT_ADMIN_ROLE)`, not `DATA_PROVIDER_ROLE`. This would be a governance action.
- Reducing maxSSR does NOT retroactively change the stored chi or ssr. It only constrains FUTURE `setSUSDSData()` calls.
- The conversion rate `_rpow(ssr, block.timestamp - rho) * chi / RAY` would continue with the currently stored ssr until a new `setSUSDSData()` is called.
- So the attack would only work if a subsequent oracle update ALSO changes the ssr, AND the attacker can predict this.
- More direct: governance changing PSM3 pocket address. The `setPocket()` function transfers existing USDC balance to the new pocket. This is atomic and doesn't create arbitrage.

**Maximum Potential Profit:** Negligible. Governance parameter changes don't directly affect spot pricing in PSM3. Oracle rate changes are bound by continuous compounding.

**What Blocks the Attack:**
- Governance changes to SSRAuthOracle don't retroactively change conversion rates.
- PSM3 parameter changes (pocket) are atomic.
- L2 bridge message execution is typically privileged (timelock executor).

---

### 6. Cross-Chain Accounting Mismatch (CCTP/LayerZero Failures)

**Feasibility: 5/10**

**Attack Scenario:**
If CCTP or LayerZero message delivery fails or is delayed:

1. MainnetController calls `transferUSDCToCCTP(1M, domain)` -- USDC is burned on L1.
2. The CCTP attestation fails or is delayed.
3. L1 accounting (rate limits) has already been decremented.
4. L2 doesn't receive the USDC.
5. System has $1M less total assets but the same liabilities.

**Analysis:**
- CCTP: `depositForBurn()` burns USDC on the source chain. If the attestation is never claimed on the destination, the USDC is effectively stuck. Circle maintains the attestation and the USDC can always be minted on the destination once the attestation is available.
- The rate limit `LIMIT_USDC_TO_CCTP` and `LIMIT_USDC_TO_DOMAIN` are decremented at send time. These limits refill over time (slope-based). So even if delivery is delayed, the rate limit naturally recovers.
- **There is no reverse rate limit increase if CCTP fails.** This is by design -- CCTP is guaranteed delivery by Circle.
- LayerZero: The comment in ForeignController says "This function was deployed without integration testing!!! KEEP RATE LIMIT AT ZERO until LayerZero dependencies are live."
- If LayerZero message fails: tokens may be stuck in the OFT contract. The `minAmountLD` is set from `quoteOFT`, so the transfer should succeed or fully revert.

**Maximum Potential Profit:** This is more of a liveness/availability issue than a profit extraction. No attacker can directly extract value from delayed deliveries.

**What Blocks the Attack:**
- CCTP guarantees eventual delivery (Circle attestation service).
- LayerZero rate limits kept at zero until fully tested.
- Rate limits refill over time, preventing permanent accounting damage.
- No mechanism for an external attacker to cause CCTP/LZ failures.

---

### 7. Rate Limit Circumvention via Multiple Chains

**Feasibility: 1/10**

**Attack Scenario:**
Could an attacker bypass rate limits by splitting operations across chains? For example:
1. Deposit 50M USDC into PSM3 on Arbitrum (using up the Arbitrum rate limit).
2. Deposit 50M USDC into PSM3 on Base (using up the Base rate limit).
3. Total: 100M deposited across chains, bypassing per-chain 50M limits.

**Analysis:**
- Each chain has its own `ForeignController`, `RateLimits`, and `PSM3` instance.
- Rate limits are per-controller, per-chain. There is no global cross-chain rate limit.
- However, the RELAYER role is permissioned. Only authorized relayers can call deposit/withdraw.
- An external user cannot directly interact with the ForeignController -- they can only interact with PSM3 directly (which has no rate limits, by design -- it's a public PSM).
- The rate limits constrain the RELAYER (ALM operations), not end users.
- For the relayer to deposit across chains, they need USDC on each chain, which requires CCTP transfers that ARE rate-limited by `LIMIT_USDC_TO_CCTP` and `LIMIT_USDC_TO_DOMAIN`.

**Maximum Potential Profit:** N/A. This is a design consideration, not an exploit. The rate limits are intentionally per-chain.

**What Blocks the Attack:**
- RELAYER is permissioned (not permissionless).
- Cross-chain USDC transfers are rate-limited by CCTP limits.
- Each chain's rate limits are independent by design.
- End users interact with PSM3 directly (no rate limits, by design).

---

### 8. SparkVault + PSM3 Interaction: TAKER_ROLE Extraction

**Feasibility: 3/10**

**Attack Scenario:**
The SparkVault has a `TAKER_ROLE` that can call `take(value)` to withdraw assets without burning shares. The ForeignController has `takeFromSparkVault()`. Could this interact with PSM3?

1. ALMProxy has TAKER_ROLE on a SparkVault.
2. ForeignController calls `takeFromSparkVault(vault, amount)` -- assets flow from vault to proxy.
3. These assets are then deposited into PSM3 or bridged.
4. SparkVault depositors' shares are now backed by fewer assets.

**Analysis:**
- The `take()` function is designed for the ALM system to use deposited funds productively. The vault's share/asset ratio degrades, but this is expected to be compensated by yield (the VSR rate).
- Rate-limited by `LIMIT_SPARK_VAULT_TAKE`.
- This is by design: the ALM takes assets, deploys them, and the VSR compensates depositors.
- If the taken assets are lost (e.g., bad investment), depositors bear the loss. This is a trust assumption, not a bug.

**SparkVault as rate provider for PSM3?**
- PSM3 uses `IRateProviderLike` for sUSDS conversion. The SparkVault implements ERC4626 but is NOT the rateProvider for PSM3.
- The rateProvider for PSM3 on L2 is the SSRAuthOracle, not the SparkVault.
- So SparkVault state does not affect PSM3 pricing.

**Maximum Potential Profit:** N/A as exploit. The TAKER_ROLE is a design feature, not a vulnerability.

**What Blocks the Attack:**
- TAKER_ROLE is permissioned and granted only to the ALM proxy.
- `take()` is rate-limited.
- SparkVault depositors are compensated by VSR yield.
- SparkVault and PSM3 have no direct oracle dependency.

---

### 9. Donation + Oracle Timing Arbitrage

**Feasibility: 3/10**

**Attack Scenario:**
Combining direct token donations to PSM3 with oracle update timing:

1. Attacker donates sUSDS to PSM3 contract address.
2. This inflates `totalAssets()` because PSM3 counts `susds.balanceOf(address(this))`.
3. Existing shares are now worth more (share-to-asset ratio increases).
4. Attacker, if they had deposited shares before the donation, can now withdraw more.

**Analysis:**
- This is a classic donation attack. The attacker must:
  - Already hold PSM3 shares (from a prior deposit).
  - Donate tokens (losing them).
  - Withdraw more than they deposited + donated.
- The math: If attacker has S shares out of T total shares, and donates D value of tokens:
  - Their share of the donated value = D * S / T.
  - Their net loss from donation = D - D * S / T = D * (T - S) / T.
  - This is always a loss unless S = T (attacker is the only depositor).
- In practice, PSM3 will have many depositors, so S << T, and the attacker loses almost all of the donation.

**Oracle Timing Component:**
- If the attacker can time the donation to coincide with an SSR oracle update that changes sUSDS valuation:
  - Donate sUSDS right before an SSR increase -> sUSDS value jumps -> donated tokens are worth more -> shares appreciate faster.
  - But the attacker still loses the donation. The oracle update benefits ALL shareholders equally.

**Maximum Potential Profit:** Negative. Donation attacks on multi-depositor pools are always loss-making for the attacker.

**What Blocks the Attack:**
- Donation economics: attacker loses (T-S)/T of donation.
- PSM3 has rounding protections (roundUp on withdrawal share calculation).
- Oracle updates are external and not controllable by the attacker.
- PSM3 will have substantial TVL from multiple depositors.

---

### 10. MEV Extraction from ALM Controller Rebalancing Operations

**Feasibility: 6/10**

**Attack Scenario:**
The ALM relayer performs rebalancing operations that are observable in the mempool:

1. **Curve swap MEV**: `swapCurve()` swaps tokens via Curve pool. A MEV bot can sandwich this:
   - Front-run: buy the output token, raising its price.
   - Relayer swap executes at worse price.
   - Back-run: sell the output token at inflated price.

2. **Aave deposit/withdraw MEV**: Less impactful since Aave supply/withdraw doesn't have significant price impact.

3. **PSM (L1) MEV**: `swapUSDSToUSDC()` and `swapUSDCToUSDS()` use the Maker PSM with `buyGemNoFee`/`sellGemNoFee` (no fee, no slippage). No MEV opportunity here.

4. **UniswapV4 MEV**: `swapUniswapV4()` swaps via UniV4. Same sandwich opportunity as Curve.

5. **CCTP MEV**: No MEV opportunity on CCTP transfers (fixed rate, no price impact).

**Analysis:**
- CurveLib.swap() has a `maxSlippage` parameter and a `minAmountOut` parameter. The `minAmountOut` must be >= `minimumMinAmountOut` (which is derived from `maxSlippage` and oracle rates). This limits sandwich profit.
- UniswapV4Lib.swap() also has `amountOutMin` and `maxSlippage` checks.
- However, the slippage check is against stored oracle rates, not live market. If the oracle rate diverges from the market, there's room for extraction.
- The relayer transactions are public on L1/L2. MEV bots will see them.
- **Key insight**: The relayer uses `maxSlippage` (e.g., 0.999e18 = 0.1% slippage tolerance). The MEV bot can extract up to this slippage amount per transaction.

**Maximum Potential Profit:**
- Per Curve swap: up to `maxSlippage` fraction of the swap amount.
- If maxSlippage = 0.1% and swap = $10M: up to $10,000 per tx.
- This profit goes to MEV bots, not an "attacker" per se, but it represents value leakage from the protocol.
- Over time, with frequent rebalancing, this could be significant.

**What Blocks the Attack:**
- `maxSlippage` bounds limit per-tx extraction.
- `minAmountOut` params protect against extreme sandwich attacks.
- Private transactions (Flashbots, MEV-Share) could mitigate (operational, not code-level).
- L2 sequencers may have different MEV dynamics than L1.

---

## Summary Table

| # | Attack Vector | Feasibility (0-10) | Max Profit Estimate | Status |
|---|---|---|---|---|
| 1 | Cross-chain SSR rate arbitrage | 4 | ~$342 on $100M (1hr delay, 3% rate change) | Not viable for bounty |
| 2 | ALM-PSM3 front-running | 2 | Negligible (donation economics) | Not viable |
| 3 | Flash loan + PSM3 | 2 | Zero (oracle-based pricing) | Not viable |
| 4 | Cross-venue rate manipulation | 3 | Negligible (independent rate limits) | Not viable |
| 5 | Governance relay front-running | 3 | Negligible (no spot price impact) | Not viable |
| 6 | Cross-chain accounting mismatch | 5 | N/A (liveness issue, not extraction) | Design consideration |
| 7 | Rate limit circumvention multi-chain | 1 | N/A (by design) | Not viable |
| 8 | SparkVault + PSM3 extraction | 3 | N/A (design feature) | Not viable |
| 9 | Donation + oracle timing | 3 | Negative (attacker loses money) | Not viable |
| 10 | MEV on ALM rebalancing | 6 | ~$10K per large swap (bounded by maxSlippage) | MEV leakage, not bug |

---

## Deeper Findings and Observations

### Finding A: PSM3 Donation Attack on First Depositor

**Risk: Low-Medium (mitigated by expected deployment flow)**

If PSM3 is deployed with zero initial deposits, the classic ERC4626 first-depositor attack applies:

1. Attacker is the first depositor, deposits 1 wei of USDS.
2. Gets 1e18 shares (since when totalAssets == 0, shares = assetValue directly).
3. Donates 100e18 USDS directly to PSM3.
4. Now totalAssets = 100e18 + 1e18 = ~101e18, totalShares = 1e18.
5. Next depositor depositing 99e18 USDS gets: `99e18 * 1e18 / 101e18 = 0.98e18` shares.
6. Attacker has 1e18 shares worth `1e18 * (101e18 + 99e18) / (1e18 + 0.98e18) = 101.01e18`.
7. Attacker donated 100e18 but gained ~1e18. Net loss: 99e18.

Wait -- this is still a loss. The first-depositor attack works when the victim's deposit is MUCH larger than the donation and the shares round to zero. Let me recalculate:

1. Attacker deposits 1 wei of USDS -> gets 1 share (assetValue = 1).
2. Donates 1e18 USDS -> totalAssets = 1e18 + 1, totalShares = 1.
3. Victim deposits 1.5e18 USDS -> shares = 1.5e18 * 1 / (1e18 + 1) = 1 share (rounds down from 1.49...).
4. Pool: totalAssets = 2.5e18 + 1, totalShares = 2.
5. Attacker's 1 share = ~1.25e18. Attacker deposited 1 + donated 1e18, net loss = ~(1e18 - 1.25e18 + 1) = 0.25e18 profit? No. Deposited 1 wei + donated 1e18, got back 1.25e18. Profit = 1.25e18 - 1e18 - 1 = 0.25e18. The victim lost 0.25e18.

This works because `convertToShares` rounds DOWN in PSM3: `assetValue * totalShares / totalAssets_`. The rounding loss goes to existing shareholders.

However, PSM3 operates with 1e18 precision internally (`_getUsdcValue(amount) = amount * 1e18 / _usdcPrecision`). A 1-wei USDC deposit with 6 decimals becomes 1e12 in internal precision. The donation would need to be proportionally large.

**Mitigation**: Standard first-depositor protections (initial seed deposit by deployer). This is likely handled operationally.

### Finding B: PSM3 `pocket` Address USDC Accounting

The `pocket` pattern creates a subtle accounting surface:

```solidity
function totalAssets() public view returns (uint256) {
    return _getUsdcValue(usdc.balanceOf(pocket))
        +  _getUsdsValue(usds.balanceOf(address(this)))
        +  _getSUsdsValue(susds.balanceOf(address(this)), false);
}
```

If `pocket != address(this)`, USDC is held at the pocket address. The `pocket` can be changed by the owner via `setPocket()`, which transfers USDC from old to new pocket. If the pocket address is a smart contract that could reject the transfer or has a transfer fee, this could cause `totalAssets()` to miscount.

**Risk**: Low. The owner is governance and would only set valid pocket addresses.

### Finding C: OTC Swap Timing and Recharge Rate Manipulation

In MainnetController, the OTC swap mechanism has a notable design:

```solidity
function isOtcSwapReady(address exchange) public view returns (bool) {
    if (maxSlippages[exchange] == 0) return false;
    return getOtcClaimWithRecharge(exchange)
        >= otcs[exchange].sent18 * maxSlippages[exchange] / 1e18;
}
```

The `rechargeRate18` is a per-second rate that reduces the claim requirement over time. This means:
- If `rechargeRate18` is set too high, the OTC swap becomes "ready" too quickly, before the counterparty has actually returned assets.
- The relayer could then initiate another swap before the previous one is settled.

**Risk**: Low. The `rechargeRate18` is set by admin (governance), and the relayer is trusted.

### Finding D: MainnetController Non-Constant Role Hashes

**Observation**: In `MainnetController`, role hashes like `FREEZER` and `RELAYER` are declared as `public` (not `constant`), which means they occupy storage slots:

```solidity
bytes32 public FREEZER = keccak256("FREEZER");
bytes32 public RELAYER = keccak256("RELAYER");
```

Compare with `ForeignController`:
```solidity
bytes32 public constant FREEZER = keccak256("FREEZER");
bytes32 public constant RELAYER = keccak256("RELAYER");
```

In `MainnetController`, ALL limit identifiers are also `public` (non-constant), occupying ~30 storage slots. This:
1. Wastes gas (SLOAD vs stack constant).
2. More critically: these are NOT immutable. If MainnetController uses proxy/upgradeable patterns (it doesn't appear to), the storage could theoretically be overwritten.

**Risk**: Low (gas waste). The MainnetController is not upgradeable (no proxy pattern), so storage corruption is not possible via normal means. But it is a code quality issue.

### Finding E: LayerZero `minAmountLD = 0` Before Override

In `LayerZeroLib.transferTokenLayerZero()`:

```solidity
SendParam memory sendParams = SendParam({
    ...
    minAmountLD  : 0,      // Initially set to 0
    ...
});

// Then overridden:
( ,, OFTReceipt memory receipt ) = ... quoteOFT(sendParams) ...
sendParams.minAmountLD = receipt.amountReceivedLD;
```

The `quoteOFT` is called with `minAmountLD = 0`, and then the result's `amountReceivedLD` is used. This is correct as a two-step quote-then-send pattern. However, if the OFT contract's `quoteOFT` returns a different result than what actually executes in `send` (due to state changes between the two calls in the same tx), the transfer could lose value.

**Risk**: Very low. Both calls happen in the same transaction via the proxy. The OFT state should be consistent.

### Finding F: SparkVault Drip and Rate Accumulation

The SparkVault's `drip()` function calculates accumulated interest:

```solidity
function drip() public returns (uint256 nChi) {
    (uint256 chi_, uint256 rho_) = (chi, rho);
    if (block.timestamp > rho_) {
        nChi = _rpow(vsr, block.timestamp - rho_) * chi_ / RAY;
        uint256 totalSupply_ = totalSupply;
        diff = totalSupply_ * nChi / RAY - totalSupply_ * chi_ / RAY;
        chi = uint192(nChi);
        rho = uint64(block.timestamp);
    }
}
```

The `take()` function does NOT call `drip()`:
```solidity
function take(uint256 value) external onlyRole(TAKER_ROLE) {
    _pushAsset(msg.sender, value);
    emit Take(msg.sender, value);
}
```

This means the TAKER_ROLE can extract assets without first updating the rate accumulator. If `drip()` hasn't been called in a while, `totalAssets()` (which uses `nowChi()` for view purposes) would show a higher value than the contract's actual asset balance minus the taken amount.

However, this is by design -- `take()` is meant to deploy capital productively, and the VSR compensates depositors for the deployed capital. It doesn't create an exploitable inconsistency because share-based accounting via `chi` remains consistent.

---

## High-Priority Areas for Further Investigation

1. **PSM3 rounding behavior at extreme precision boundaries**: The interaction between 6-decimal USDC, 18-decimal USDS, and 18-decimal sUSDS with rate provider values close to precision boundaries may yield rounding exploits in repeated small swaps.

2. **SSRAuthOracle chi accumulation overflow**: The `_rpow` function in SSROracleBase handles large exponentiations. If `ssr` is set near the maximum (maxSSR) and `rho` is not updated for a very long time, `_rpow(ssr, very_large_duration) * chi` could overflow. The function does have overflow protection (reverts on overflow), but this would brick the oracle.

3. **ALMProxy `doDelegateCall` surface**: The `doDelegateCall` function allows the CONTROLLER to execute arbitrary code in the context of the ALMProxy. If a MainnetController or ForeignController function passes attacker-controlled data to `doDelegateCall`, it could compromise the proxy's storage. Current code does NOT use `doDelegateCall` in any of the analyzed controllers, but this surface should be monitored.

4. **Curve/UniV4 oracle rate vs market rate divergence**: The slippage checks in CurveLib and UniswapV4Lib use stored oracle rates (`stored_rates()`, `maxSlippage`). If these diverge significantly from market rates, the slippage bounds may be miscalibrated, allowing MEV extraction beyond intended limits.

---

## Conclusion

The Spark protocol's cross-system architecture is well-designed with defense-in-depth:

- **Rate limits** bound all relayer operations independently per venue and per chain.
- **Access control** restricts all sensitive operations to permissioned roles (RELAYER, TAKER, DATA_PROVIDER, ADMIN).
- **Oracle design** uses continuous compounding from stored parameters, minimizing the impact of update delays.
- **PSM3** uses oracle-based pricing (not AMM), eliminating most flash-loan and sandwich attack surfaces.

No critical or high-severity cross-system vulnerabilities were identified. The highest-risk area is **MEV extraction from Curve/UniV4 operations** (Feasibility 6/10), which represents value leakage bounded by slippage parameters rather than a discrete exploit. The most interesting theoretical attack is **cross-chain SSR arbitrage** (Feasibility 4/10), but the potential profit is too low to justify the capital and complexity required.
