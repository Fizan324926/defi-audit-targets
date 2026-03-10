# Olympus V3 Audit Report: Market Operations (Group 4)

## Scope

| Contract | File |
|----------|------|
| Operator | `src/policies/Operator.sol` |
| YieldRepurchaseFacility | `src/policies/YieldRepurchaseFacility.sol` |
| EmissionManager | `src/policies/EmissionManager.sol` |
| OlympusHeart | `src/policies/Heart.sol` |
| BondCallback | `src/policies/BondCallback.sol` |
| BondManager | `src/policies/BondManager.sol` |
| Distributor | `src/policies/Distributor/Distributor.sol` |
| ZeroDistributor | `src/policies/Distributor/ZeroDistributor.sol` |
| BLVaultLido | `src/policies/BoostedLiquidity/BLVaultLido.sol` |
| BLVaultManagerLido | `src/policies/BoostedLiquidity/BLVaultManagerLido.sol` |
| BLVaultLusd | `src/policies/BoostedLiquidity/BLVaultLusd.sol` |
| BLVaultManagerLusd | `src/policies/BoostedLiquidity/BLVaultManagerLusd.sol` |
| OlympusRange | `src/modules/RANGE/OlympusRange.sol` |
| RANGEv2 | `src/modules/RANGE/RANGE.v2.sol` |
| RANGEv1 | `src/modules/RANGE/RANGE.v1.sol` |
| OlympusPrice | `src/modules/PRICE/OlympusPrice.sol` |
| PRICEv1 | `src/modules/PRICE/PRICE.v1.sol` |

**Audit Focus**: Loss of treasury funds, loss of user funds, loss of bond funds.

---

## Executive Summary

After a line-by-line review of all 18 contracts in scope, I identified several findings ranging from medium to informational severity. The codebase is generally well-structured with appropriate access controls, reentrancy protection, and mathematical safeguards. However, there are noteworthy issues in the YieldRepurchaseFacility's hardcoded backing assumption, potential frontrunning vectors in bond market creation, and an accounting edge case in the BLVault withdraw flow.

---

## Findings

### Finding 1: YieldRepurchaseFacility Hardcoded `backingPerToken` Creates Permanent Over/Under-Withdrawal from Treasury

**Severity**: Medium

**File**: `src/policies/YieldRepurchaseFacility.sol`, line 73

**Description**:

The `backingPerToken` constant is hardcoded to `1133 * 1e7` (representing $11.33 per OHM). This value is used in `getOhmBalanceAndBacking()` (line 349) to calculate how much reserve the contract should withdraw from the treasury when burning purchased OHM:

```solidity
uint256 public constant backingPerToken = 1133 * 1e7; // assume backing of $11.33
```

```solidity
function getOhmBalanceAndBacking()
    public view override returns (uint256 balance, uint256 backing)
{
    balance = ohm.balanceOf(address(this));
    backing = balance * backingPerToken;
}
```

This is called in `_getBackingForPurchased()` (line 272), which burns OHM and then withdraws `backing` worth of reserves from the treasury. If the actual backing price of OHM changes significantly from $11.33 (either up or down), the facility will systematically over- or under-withdraw reserves from the treasury each day.

**Attack Scenario**:

1. If OHM's actual backing rises to $15, the facility still only withdraws $11.33 per OHM burned -- the treasury retains more reserves than it should for the burned OHM, but the facility is underfunded relative to protocol-held backing.
2. If OHM's actual backing drops to $8, the facility still withdraws $11.33 per OHM burned -- the treasury is drained of reserves at an inflated rate relative to actual backing.
3. Over time (the facility runs continuously), the cumulative impact compounds. Each daily cycle calls `_getBackingForPurchased()`, withdrawing `ohmBalance * 11.33e9` DAI from the treasury regardless of actual backing.

**Impact**:

The facility could systematically over-withdraw reserves from the treasury if backing drops below $11.33, draining treasury reserves faster than warranted. With typical daily volumes and weekly yield budgets, the cumulative effect could be material over weeks/months. However, the `loop_daddy` role can `adjustNextYield()` and `shutdown()` to mitigate, limiting the window of exploitation.

**PoC Feasibility**: Medium. Requires OHM backing to diverge from the hardcoded value, which is a market condition rather than a direct exploit. The continuous operation of the facility makes the accumulated impact significant.

---

### Finding 2: YieldRepurchaseFacility Bond Market Created with `minPrice = 0` Allows Unlimited OHM Price

**Severity**: Medium

**File**: `src/policies/YieldRepurchaseFacility.sol`, line 228

**Description**:

When creating bond markets in `_createMarket()`, the minimum price is set to zero:

```solidity
uint256 minPrice = 0; // Min price of zero means max price of infinity -- no cap
```

This means the bond market's SDA algorithm has no floor price for the inverse OHM price (i.e., no ceiling on the OHM price in reserve terms). Combined with the initial price being set at 3% below the oracle price (line 229):

```solidity
uint256 initialPrice = 10 ** (_oracleDecimals * 2) / ((PRICE.getLastPrice() * 97) / 100);
```

The bond market will use SDA (Sequential Dutch Auction) dynamics to adjust the price. Without a minimum price, the market can drift to arbitrarily low inverse prices (arbitrarily high OHM prices), meaning the facility may buy OHM at prices far above market value.

**Attack Scenario**:

1. Attacker waits for a YRF bond market to be created.
2. As the SDA adjusts the price based on demand, the lack of a minimum price means the protocol could buy OHM at increasingly unfavorable prices.
3. An attacker repeatedly sells OHM into the market, and the SDA increases the effective OHM price (decreases the inverse price) with no floor.
4. The facility buys OHM at prices significantly above fair market value.

**Impact**:

Loss of treasury funds. The facility's daily budget is bounded (1/7th to 1/1th of the remaining weekly balance), so losses per market are bounded by that day's budget. But within each day's budget, the entire amount could be spent buying OHM at inflated prices.

**PoC Feasibility**: Medium-High. Requires monitoring for YRF bond market creation and selling OHM into it. The SDA dynamics need analysis to determine how quickly the price can be driven up within a single market's 1-day duration.

---

### Finding 3: Operator `bondPurchase` Double-Counts Capacity Reduction for Coincident Market IDs

**Severity**: Low

**File**: `src/policies/Operator.sol`, lines 416-424

**Description**:

The `bondPurchase` function uses two independent `if` statements (not `if-else`):

```solidity
function bondPurchase(uint256 id_, uint256 amountOut_) external onlyRole("operator_reporter") {
    _onlyWhileActive();

    if (id_ == RANGE.market(true)) {
        _updateCapacity(true, amountOut_);
        _checkCushion(true);
    }
    if (id_ == RANGE.market(false)) {
        _updateCapacity(false, amountOut_);
        _checkCushion(false);
    }
}
```

If `RANGE.market(true) == RANGE.market(false)`, the capacity would be reduced on both sides for a single bond purchase. In practice, the high and low market IDs are set independently and would differ, and when a market is deactivated it is set to `type(uint256).max`. The condition where both are active with the same market ID is not expected but is technically possible in an edge case.

**Attack Scenario**:

This would require both RANGE sides to have the same market ID, which would only happen through a misconfiguration or if the bond auctioneer returns the same ID for two different markets. If it occurred, a single bond purchase would double-decrement capacity, potentially taking down a wall prematurely.

**Impact**: Low. The condition is unlikely under normal operation. If triggered, it would cause premature wall deactivation -- a DoS on market operations rather than direct fund loss.

**PoC Feasibility**: Low. Would require specific misconfiguration of the RANGE module.

---

### Finding 4: EmissionManager `_updateBacking` Division Precision Loss on Small Purchases

**Severity**: Low

**File**: `src/policies/EmissionManager.sol`, lines 449-461

**Description**:

The backing update formula uses percentage-based math:

```solidity
function _updateBacking(uint256 supplyAdded, uint256 reservesAdded) internal {
    uint256 previousReserves = getReserves();
    uint256 previousSupply = getSupply();

    uint256 percentIncreaseReserves = ((previousReserves + reservesAdded) *
        10 ** _reserveDecimals) / previousReserves;
    uint256 percentIncreaseSupply = ((previousSupply + supplyAdded) * 10 ** _reserveDecimals) /
        previousSupply;

    backing =
        (backing * percentIncreaseReserves) /
        percentIncreaseSupply;
}
```

For very small purchases where `reservesAdded` or `supplyAdded` is much smaller than `previousReserves` or `previousSupply`, the percentage increase calculation truncates to exactly `10 ** _reserveDecimals` (i.e., 100%), meaning no backing change is recorded despite actual value change. Over many small transactions, this rounding consistently favors one direction.

Additionally, if `previousReserves` or `previousSupply` is zero (e.g., during early initialization or edge conditions), this function would revert with a division by zero.

**Impact**: Negligible per transaction, but systematic rounding in one direction over many bond purchases could cause backing to drift from its true value. The `setBacking()` admin function provides a correction mechanism.

**PoC Feasibility**: Low. The practical impact is minimal given typical order sizes relative to total reserves/supply.

---

### Finding 5: BLVault Withdraw Arb Capture May Under-Compensate Users During Oracle/Pool Price Divergence

**Severity**: Medium

**File**: `src/policies/BoostedLiquidity/BLVaultLido.sol`, lines 260-276 (same pattern in `BLVaultLusd.sol`, lines 263-278)

**Description**:

During withdrawal, the vault calculates how much pair token (wstETH/LUSD) to return to the user. It uses the oracle price to determine an "expected" amount, and any excess goes to the treasury:

```solidity
// Calculate oracle expected wstETH received amount
uint256 wstethOhmPrice = manager.getTknOhmPrice();
uint256 expectedWstethAmountOut = (ohmAmountOut * wstethOhmPrice) / _OHM_DECIMALS;

// Take any arbs relative to the oracle price for the Treasury
uint256 wstethToReturn = wstethAmountOut > expectedWstethAmountOut
    ? expectedWstethAmountOut
    : wstethAmountOut;
```

The `ohmAmountOut` here is the OHM received from the Balancer pool exit. The expected wstETH is computed by converting that OHM amount using the oracle price. This approach captures "arb profit" for the treasury if the pool price diverges from the oracle price.

However, when the pool's OHM/wstETH ratio is lower than the oracle price (meaning each OHM buys less wstETH in the pool than the oracle says it should), the user gets the smaller `wstethAmountOut` directly. But when the pool gives *more* wstETH per OHM than the oracle price suggests, the **user** receives only the oracle-price-equivalent, with the excess going to treasury. This is asymmetric: the user bears the downside of unfavorable pool prices but does not benefit from favorable pool prices.

**Attack Scenario**:

1. Attacker manipulates the Balancer pool to skew the OHM/wstETH ratio (e.g., adds OHM to the pool, making wstETH relatively more expensive).
2. An honest user withdraws. They get fewer wstETH because the pool ratio is unfavorable.
3. Attacker then rebalances the pool, profiting from the imbalance.
4. The user has no upside protection -- even if the pool ratio was in their favor, the excess would go to the treasury.

Note: The `minTokenAmountUser_` parameter provides slippage protection, but it does not address the asymmetric arb capture.

**Impact**: Users systematically lose pair token value on withdrawals when pool/oracle prices diverge. The magnitude depends on pool depth, but for large positions relative to pool size, the loss could be substantial. The `minWithdrawalDelay` provides some protection against same-block manipulation.

**PoC Feasibility**: Medium. Requires Balancer pool manipulation, but the asymmetric design means any natural divergence also disadvantages users.

---

### Finding 6: BLVault Deposit Uses `min(oraclePrice, poolPrice)` for OHM Minting, Creating Free OHM in Specific Conditions

**Severity**: Medium

**File**: `src/policies/BoostedLiquidity/BLVaultLido.sol`, lines 173-183 (same in `BLVaultLusd.sol`)

**Description**:

During deposit, the vault mints OHM based on the minimum of oracle and pool prices:

```solidity
uint256 ohmWstethPrice = ohmWstethOraclePrice < ohmWstethPoolPrice
    ? ohmWstethOraclePrice
    : ohmWstethPoolPrice;
ohmMintAmount = (amount_ * ohmWstethPrice) / _WSTETH_DECIMALS;
```

This means if the pool price of OHM (in terms of wstETH) is lower than the oracle price, the vault mints **fewer** OHM per wstETH. This is correct as a protective measure -- it prevents over-minting OHM when the pool is imbalanced.

However, an attacker can manipulate the Balancer pool price to make OHM cheaper in the pool (dump OHM into the pool), causing the vault to mint fewer OHM for the deposit. The deposited wstETH + fewer OHM enter the Balancer pool. Because fewer OHM were minted but the same wstETH went in, the LP tokens received represent a position that is wstETH-heavy. When the pool rebalances (post-manipulation), the LP position gains value.

The unused OHM is burned (lines 215-218), so the protocol does not lose OHM. But the depositor receives LP tokens representing a disproportionate share of wstETH in the pool.

**Attack Scenario**:

1. Attacker dumps OHM into the Balancer pool, making `ohmWstethPoolPrice` low.
2. Attacker deposits wstETH to their BLVault. Fewer OHM are minted (due to the lower pool price being used).
3. The Balancer pool receives the deposit with the full wstETH but reduced OHM.
4. The attacker (or arbitrageurs) rebalance the pool, and the LP position is now worth more wstETH per LP token.
5. On withdrawal, the arb capture mechanism caps wstETH returned, but the attacker's LP position has more underlying value.

**Impact**: The minting mechanism is protective for the protocol (less OHM minted), but it creates an opportunity for sophisticated pool manipulation that could extract value from the pool at the expense of other LPs or the protocol. The `minWithdrawalDelay` limits but doesn't eliminate this.

**PoC Feasibility**: Medium. Requires significant capital to manipulate the Balancer pool, and the arb capture on withdrawal limits profitability.

---

### Finding 7: Operator `swap()` Uses Stored `getLastPrice` for Wall Prices, Enabling Stale-Price Exploitation

**Severity**: Low-Medium

**File**: `src/policies/Operator.sol`, lines 326-404

**Description**:

The `swap()` function checks `_onlyWhileActive()` which validates that the PRICE observation is not stale (within 3 observation frequencies). The wall prices used for the swap are stored in the RANGE module and are updated via `_updateRangePrices()` during `operate()`.

Between heartbeats, the wall prices are static. If the oracle price moves significantly between heartbeats, a user can execute a swap at a stale wall price that is more favorable than the current market price.

Specifically:
- For the **low wall** (OHM -> Reserve): If OHM's real price drops below the stored wall price, a user can sell OHM at the stale (higher) wall price.
- For the **high wall** (Reserve -> OHM): If OHM's real price rises above the stored wall price, a user can buy OHM at the stale (lower) wall price.

The `_onlyWhileActive()` check allows up to `3 * observationFrequency` of staleness, which at typical 8-hour observation frequency means up to 24 hours of staleness.

**Attack Scenario**:

1. OHM price drops sharply in the real market (e.g., from $15 to $12) between heartbeats.
2. The low wall price is still set based on the old moving average (e.g., wall at $13.50).
3. Attacker buys OHM at $12 on the market and immediately sells it to the Operator at the $13.50 wall price, receiving $13.50 worth of reserves per OHM.
4. This drains treasury reserves at above-market prices until the wall's capacity is depleted.

**Impact**: Loss of treasury funds equal to the price difference multiplied by the wall capacity. The capacity is bounded by `reserveFactor` of treasury reserves, typically a small percentage. The wall also has a threshold that deactivates it when capacity drops below a percentage.

**PoC Feasibility**: Medium. Requires monitoring heartbeat timing and rapid market movements, but is feasible for sophisticated traders.

---

### Finding 8: ZeroDistributor `triggerRebase` Does Not Revert on Failed Rebase

**Severity**: Informational

**File**: `src/policies/Distributor/ZeroDistributor.sol`, lines 20-24

**Description**:

```solidity
function triggerRebase() external {
    unlockRebase = true;
    staking.unstake(address(this), 0, true, true);
    if (unlockRebase) unlockRebase = false;
}
```

Unlike the standard `Distributor.triggerRebase()` which reverts if no rebase occurred (`if (unlockRebase) revert Distributor_NoRebaseOccurred()`), the ZeroDistributor silently resets the flag. This means callers cannot reliably know whether a rebase actually occurred.

**Impact**: Informational only. No funds at risk, but the silent behavior could mask issues with the staking contract not performing rebases when expected.

**PoC Feasibility**: N/A -- informational.

---

### Finding 9: Distributor Requests `type(uint256).max` Mint Approval Each Distribution

**Severity**: Low

**File**: `src/policies/Distributor/Distributor.sol`, line 129

**Description**:

```solidity
MINTR.increaseMintApproval(address(this), type(uint256).max);
```

Each call to `distribute()` requests the maximum possible mint approval. While it is subsequently reduced to zero at line 151:

```solidity
MINTR.decreaseMintApproval(address(this), type(uint256).max);
```

Between these two calls, the Distributor has unlimited minting authority. If any of the intermediate calls (minting to staking, minting to pools, pool sync) cause a reentrant call, the unlimited approval could be exploited. However, the `distribute()` function is restricted to be called only by the staking contract (`msg.sender != address(staking)`), and the staking contract should not facilitate reentrancy.

**Impact**: Low. The window of unlimited approval exists only within a single transaction, and the caller restriction limits the attack surface. If the staking contract or any of the pools in the `pools` array were malicious, they could exploit the approval.

**PoC Feasibility**: Low. Requires a malicious/compromised staking contract or pool address.

---

### Finding 10: EmissionManager `callback()` Does Not Verify `reserve.balanceOf` Change, Only Minimum

**Severity**: Low

**File**: `src/policies/EmissionManager.sol`, lines 374-397

**Description**:

```solidity
function callback(uint256 id_, uint256 inputAmount_, uint256 outputAmount_) external {
    if (msg.sender != teller) revert OnlyTeller();
    if (id_ != activeMarketId) revert InvalidMarket();

    uint256 reserveBalance = reserve.balanceOf(address(this));
    if (reserveBalance < inputAmount_) revert InvalidCallback();

    _updateBacking(outputAmount_, inputAmount_);
    sReserve.deposit(reserveBalance, address(TRSRY));
    MINTR.mintOhm(teller, outputAmount_);
}
```

The check `reserveBalance < inputAmount_` only verifies that the contract holds at least `inputAmount_` of reserves. It deposits the **entire** reserve balance (`reserveBalance`) to the treasury, not just `inputAmount_`. The comment says "This will sweep any excess reserves into the TRSRY as well" -- this is intentional behavior for the `rescue()` pattern. However, if any tokens were sent to the EmissionManager independently (e.g., by mistake), they would be swept into the treasury on the next callback.

The `_updateBacking()` function is called with `inputAmount_`, not `reserveBalance`, so the backing calculation correctly reflects only the bond purchase amount. This is correct behavior.

**Impact**: Informational. The sweep behavior is by design and documented in code comments. No fund loss occurs; excess reserves end up in the treasury.

**PoC Feasibility**: N/A -- informational.

---

### Finding 11: BondCallback `priorBalances` Can Be Manipulated by Direct Token Transfers

**Severity**: Low

**File**: `src/policies/BondCallback.sol`, lines 188-247

**Description**:

The `callback()` function checks that the quote token balance increased by at least `inputAmount_`:

```solidity
if (quoteToken.balanceOf(address(this)) < priorBalances[quoteToken] + inputAmount_)
    revert Callback_TokensNotReceived();
```

After the callback, it updates:
```solidity
priorBalances[quoteToken] = quoteToken.balanceOf(address(this));
priorBalances[payoutToken] = payoutToken.balanceOf(address(this));
```

If someone directly transfers tokens to the BondCallback contract between callbacks, the `priorBalances` will not reflect this, and the next callback will have an inflated starting balance. This means the actual transfer check (`priorBalances[quoteToken] + inputAmount_`) will pass even if fewer tokens were actually sent in the current callback, since the prior balance already includes the directly transferred tokens.

However, this does not lead to additional minting beyond the market's approved capacity, because the payout amount is determined by the bond market (not by the input amount). The `whitelist()` function approves minting/withdrawal up to the market capacity.

**Impact**: Low. Direct transfers to BondCallback would be swept to treasury via `batchToTreasury()` or would inflate `priorBalances`. No excess OHM can be minted beyond market capacity.

**PoC Feasibility**: Low. No profit motive -- directly sent tokens end up in treasury.

---

### Finding 12: Operator `fullCapacity` High Side Calculation Includes Both Spreads as Additive Adjustment

**Severity**: Informational

**File**: `src/policies/Operator.sol`, lines 902-916

**Description**:

```solidity
function fullCapacity(bool high_) public view override returns (uint256) {
    uint256 capacity = ((sReserve.previewRedeem(TRSRY.getReserveBalance(sReserve)) +
        TRSRY.getReserveBalance(reserve) +
        TRSRY.getReserveBalance(oldReserve)) * _config.reserveFactor) / ONE_HUNDRED_PERCENT;
    if (high_) {
        capacity =
            (capacity.mulDiv(
                10 ** _ohmDecimals * 10 ** _oracleDecimals,
                10 ** _reserveDecimals * RANGE.price(true, true)
            ) * (ONE_HUNDRED_PERCENT + RANGE.spread(true, true) + RANGE.spread(false, true))) /
            ONE_HUNDRED_PERCENT;
    }
    return capacity;
}
```

For the high side, the capacity is first calculated in reserve terms, then converted to OHM using the high wall price, and then scaled up by `(100% + highWallSpread + lowWallSpread)`. The addition of both the high and low wall spreads creates a capacity buffer that accounts for the potential price range between both walls. This is intentional design to ensure sufficient OHM capacity to handle price movements, but it means the high side capacity is larger than a naive "reserves / price" calculation would suggest.

**Impact**: Informational. This is design intent, not a vulnerability.

---

### Finding 13: Heart `beat()` Linearly Increases Keeper Reward, Enabling MEV Timing Games

**Severity**: Informational

**File**: `src/policies/Heart.sol`, lines 142-172

**Description**:

The keeper reward increases linearly from 0 to `maxReward` over the `auctionDuration`:

```solidity
function currentReward() public view returns (uint256) {
    uint48 beatFrequency = frequency();
    uint48 nextBeat = lastBeat + beatFrequency;
    uint48 currentTime = uint48(block.timestamp);
    uint48 duration = auctionDuration > beatFrequency ? beatFrequency : auctionDuration;
    if (currentTime <= nextBeat) {
        return 0;
    } else {
        return
            currentTime - nextBeat >= duration
                ? maxReward
                : (uint256(currentTime - nextBeat) * maxReward) / duration;
    }
}
```

Keepers are incentivized to wait as long as possible (up to `auctionDuration`) to maximize their reward. This creates a tension between timely price updates and keeper profit maximization. During volatile markets, delayed heartbeats mean stale prices, which amplifies the impact of Finding 7 (stale wall prices).

**Impact**: Informational. This is standard auction mechanism design for keeper incentives. The protocol accepts the trade-off between reward efficiency and timeliness.

---

## Contracts Reviewed with No Actionable Findings

### BondManager (`src/policies/BondManager.sol`)

All functions are gated by `onlyRole("bondmanager_admin")`. The contract creates bond markets (OHM-OHM) through Bond Protocol and Gnosis Auction. No permissionless attack vectors identified. The `emergencySetApproval` and `emergencyWithdraw` functions are admin-only escape hatches.

### OlympusRange (`src/modules/RANGE/OlympusRange.sol`)

All state-changing functions are `permissioned` (module-level access control). The price and capacity calculations are straightforward. The threshold mechanism properly deactivates walls when capacity drops below the threshold.

### OlympusPrice (`src/modules/PRICE/OlympusPrice.sol`)

Price feed validation correctly checks for stale data, zero/negative prices, and round ID matching. The moving average implementation is standard ring buffer with cumulative sum. The `minimumTargetPrice` floor prevents the target price from dropping below protocol-defined backing.

---

## Summary Table

| # | Finding | Severity | Contract | Impact |
|---|---------|----------|----------|--------|
| 1 | Hardcoded `backingPerToken` causes systematic over/under-withdrawal | Medium | YieldRepurchaseFacility | Treasury fund drainage over time |
| 2 | Bond market with `minPrice = 0` enables unlimited OHM price | Medium | YieldRepurchaseFacility | Loss of treasury funds per daily budget |
| 3 | `bondPurchase` double-counts for coincident market IDs | Low | Operator | Premature wall deactivation |
| 4 | `_updateBacking` precision loss on small purchases | Low | EmissionManager | Backing drift over time |
| 5 | Asymmetric arb capture disadvantages BLVault users | Medium | BLVaultLido/Lusd | Loss of user funds on withdrawal |
| 6 | `min(oracle, pool)` mint enables deposit manipulation | Medium | BLVaultLido/Lusd | Value extraction from pool |
| 7 | Stale wall prices between heartbeats | Low-Medium | Operator | Treasury fund loss bounded by capacity |
| 8 | ZeroDistributor silent rebase failure | Informational | ZeroDistributor | No fund impact |
| 9 | Max mint approval window in Distributor | Low | Distributor | Limited by caller restriction |
| 10 | Callback sweeps entire reserve balance | Informational | EmissionManager | By design, no loss |
| 11 | `priorBalances` inflatable by direct transfers | Low | BondCallback | No excess minting possible |
| 12 | Dual-spread capacity adjustment | Informational | Operator | Design intent |
| 13 | Linear keeper reward enables timing games | Informational | Heart | Standard mechanism trade-off |

---

## Detailed Analysis by Attack Vector

### 1. Price Manipulation

**PRICE Module**: The PRICE module uses dual Chainlink feeds (OHM/ETH and Reserve/ETH) with proper staleness checks. Manipulation of Chainlink feeds is out of scope (third-party oracle). The moving average provides smoothing against short-term price spikes.

**RANGE Module**: Range prices are derived from the PRICE target price and configured spreads. No direct manipulation vector. Prices update on each heartbeat via `updatePrices()`.

**Conclusion**: No direct price manipulation vulnerability within scope. The staleness window between heartbeats is the primary concern (Finding 7).

### 2. Bond Exploitation

**BondCallback**: Properly validates teller address against aggregator, checks token receipt, and the `operator.bondPurchase()` call updates capacity. The approval mechanism in `whitelist()` correctly caps minting/withdrawal to market capacity.

**EmissionManager callback**: Validates teller and market ID. Deposits all received reserves to treasury and mints only the specified output amount.

**Conclusion**: Bond systems are well-protected. The Finding 3 double-count edge case is the only identified issue.

### 3. Emission Gaming

**EmissionManager**: The emission rate is based on `gOHM.totalSupply() * gOHM.index()` and the premium (`marketPrice / backing - 100%`). The premium check against `minimumPremium` prevents emissions when the market price is too close to backing. The SDA bond market uses the current oracle price as initial price and `(1 + minimumPremium) * backing` as minimum price, providing a reasonable floor.

**Conclusion**: The emission mechanism has appropriate safeguards. The `bondMarketCapacityScalar` (max 200%) limits how much unsold OHM can roll over into bond markets.

### 4. YRF Exploitation

**YieldRepurchaseFacility**: Findings 1 and 2 are the primary concerns. The daily budget allocation (1/7th to 1/1st of remaining weekly balance) provides bounded exposure per market. The `adjustNextYield` function (limited to 10% increase) and `shutdown` provide admin controls.

**Conclusion**: The hardcoded backing and zero minimum price are the main risk factors. MEV frontrunning of market creation is possible but bounded by daily budgets.

### 5. Heart Exploitation

**OlympusHeart**: The `beat()` function is permissionless with proper timing checks. The `nonReentrant` modifier prevents reentrancy. The `lastBeat` update formula (`currentTime - ((currentTime - lastBeat) % frequency())`) correctly handles skipped beats without allowing catch-up beats.

**Conclusion**: No exploitable vulnerabilities identified. The keeper reward mechanism (Finding 13) is an accepted design trade-off.

### 6. BLV Vault Attacks

**BLVaultLido/Lusd**: Findings 5 and 6 are the primary concerns. The withdrawal delay and oracle-based arb capture provide protection, but the asymmetric design disadvantages users. The OHM minting limit (`ohmLimit + circulatingOhmBurned`) properly caps protocol exposure.

**Conclusion**: The BLVault system is designed conservatively to protect protocol OHM, but at the cost of user pair token value during oracle/pool divergence.

### 7. Distributor Attacks

**Distributor**: The `unlockRebase` mechanism properly restricts `distribute()` to only be callable via `triggerRebase()`. The mint approval is bounded within a single transaction (Finding 9).

**Conclusion**: No exploitable vulnerabilities identified.

### 8. Flash Loan Attacks

Flash loans cannot directly exploit any of the reviewed contracts because:
- Operator `swap()` uses stored wall prices, not instantaneous prices
- BLVault deposits require `minWithdrawalDelay` between deposit and withdrawal
- Bond markets operate over time periods (not atomic)
- EmissionManager callback requires teller authorization

The BLVault pool manipulation (Finding 6) could theoretically use flash loans to manipulate the Balancer pool price, but the deposit would need to wait through the withdrawal delay before extracting value.

**Conclusion**: Flash loan attacks are mitigated by time-locked operations and stored prices.

### 9. Accounting

- Operator: OHM burn and reserve withdrawal/deposit correctly track capacity through RANGE module
- BondCallback: `_amountsPerMarket` tracks cumulative in/out correctly, `priorBalances` tracks token balances
- EmissionManager: `_updateBacking` has precision loss concerns (Finding 4) but is directionally correct
- BLVault: `deployedOhm` and `circulatingOhmBurned` correctly track OHM minting state
- YRF: The `backingPerToken` constant introduces systematic accounting error (Finding 1)

**Conclusion**: Accounting is generally correct with the exceptions noted in Findings 1 and 4.
