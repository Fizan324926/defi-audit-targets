# Security Audit Report: Aave V3 Core (Spark Fork) + Governance

## Executive Summary

This report covers a comprehensive line-by-line security audit of the SparkLend protocol's fork of Aave V3, focusing on Spark-specific modifications, the SavingsDaiOracle, and the governance Executor contract. The audit examined all core protocol logic libraries, tokenization contracts, interest rate strategies, oracle implementations, and governance infrastructure.

**Scope:**
- Aave V3 Core (Spark fork): Pool.sol, all Logic libraries, token implementations, interest rate strategy
- Spark-specific contracts: SavingsDaiOracle.sol
- Governance: Executor.sol
- All Spark-specific diffs from upstream Aave V3

**Key Spark-Specific Changes Identified:**
1. [SC-342] Jan 10 Patch: Re-reads pool state from storage during flash-loan-into-borrow to fix stale parameter vulnerability
2. [SC-343] Complete removal of flash-loan-into-borrow feature (replaced with revert)
3. Added `getReservesCount()` view function to IPool
4. Added `pool` field to `FlashloanParams` struct

---

## Finding #1: SavingsDaiOracle Stale `chi` Value Can Lead to Incorrect sDAI Pricing

**Severity: Medium**

**File:** `/root/immunefi/audits/sparklend/src/sparklend/src/SavingsDaiOracle.sol`
**Lines:** 28-29

### Description

The `SavingsDaiOracle` computes the sDAI price by multiplying the DAI price feed's `latestAnswer()` by the MakerDAO Pot's `chi()` value divided by RAY. The critical issue is that `chi()` is only updated when `drip()` is called on the Pot contract. If `drip()` has not been called recently, `chi` will be stale (lower than its true accrued value), resulting in an **underpriced sDAI**.

```solidity
function latestAnswer() external view returns (int256) {
    return _daiPriceFeed.latestAnswer() * _pot.chi().toInt256() / RAY;
}
```

### Attack Scenario

1. No one calls `Pot.drip()` for an extended period (hours/days)
2. The `chi` value becomes stale and lower than the true accrued value
3. sDAI collateral is underpriced in the lending pool
4. A liquidator can trigger liquidations on positions that should be healthy
5. Users lose collateral to liquidators unfairly

Alternatively, a sophisticated attacker could:
1. Monitor for periods when `chi` is stale
2. Position themselves to liquidate sDAI-collateralized loans at a discount
3. Call `Pot.drip()` after acquiring the discounted collateral to realize profit

### Impact

- Unfair liquidations of sDAI-collateralized positions when `chi` is stale
- The degree of mispricing depends on the DSR rate and how long since the last `drip()` call
- At a 5% DSR, 24 hours of staleness results in ~0.0137% underpricing -- relatively small but could compound with high leverage positions
- In extreme scenarios (e.g., very high DSR periods or extended staleness), this could become material

### Recommendation

The oracle should compute the time-accrued `chi` value rather than reading the potentially stale stored value. This can be done by reading `pot.rho()` (last drip timestamp) and `pot.dsr()` (the per-second rate) and computing:

```solidity
function latestAnswer() external view returns (int256) {
    uint256 chi = _pot.chi();
    uint256 rho = _pot.rho();
    if (block.timestamp > rho) {
        // chi * dsr^(now - rho) -- applying time-accumulated rate
        chi = rmul(chi, rpow(_pot.dsr(), block.timestamp - rho));
    }
    return _daiPriceFeed.latestAnswer() * chi.toInt256() / RAY;
}
```

### Mitigating Factors

- MEV bots typically call `Pot.drip()` frequently for arbitrage reasons
- The underpricing is proportional to staleness duration and DSR, so at normal DSR levels the impact per block is tiny
- This is a known design tradeoff and may be intentional for gas savings

---

## Finding #2: Executor `executeDelegateCall` is Externally Callable via DEFAULT_ADMIN_ROLE

**Severity: Medium**

**File:** `/root/immunefi/audits/sparklend/src/spark-gov-relay/src/Executor.sol`
**Lines:** 154-162, 46-47

### Description

The `executeDelegateCall` function is `external` and protected by `onlyRole(DEFAULT_ADMIN_ROLE)`. The Executor grants `DEFAULT_ADMIN_ROLE` to both `msg.sender` (the deployer) and `address(this)` in the constructor:

```solidity
constructor(uint256 delay_, uint256 gracePeriod_) {
    _updateDelay(delay_);
    _updateGracePeriod(gracePeriod_);
    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    _grantRole(DEFAULT_ADMIN_ROLE, address(this));  // Necessary for self-referential calls
}
```

```solidity
function executeDelegateCall(address target, bytes calldata data)
    external payable override onlyRole(DEFAULT_ADMIN_ROLE)
    returns (bytes memory)
{
    return target.functionDelegateCall(data);
}
```

The function is also used internally by `_executeTransaction` when `withDelegatecall` is true:

```solidity
if (withDelegatecall) return this.executeDelegateCall{value: value}(target, callData);
```

### Security Concern

Any address with `DEFAULT_ADMIN_ROLE` can execute arbitrary delegate calls through the Executor, which means arbitrary code runs in the Executor's context (modifying its storage, draining its ETH, etc.). While this is by design for governance proposals, the risk is:

1. If the deployer's key is compromised and they still hold `DEFAULT_ADMIN_ROLE`, an attacker can bypass the timelock entirely
2. The `DEFAULT_ADMIN_ROLE` also controls `grantRole` (via OpenZeppelin's AccessControl), so a compromised admin can grant roles to arbitrary addresses
3. The deployer should renounce `DEFAULT_ADMIN_ROLE` after setup, but this is not enforced

### Impact

- If the deployer retains `DEFAULT_ADMIN_ROLE`: complete bypass of governance timelock
- Arbitrary code execution in Executor's context (storage manipulation, fund drainage)
- This is a governance-level trust assumption rather than a code bug

### Recommendation

- Verify that the deployer has renounced `DEFAULT_ADMIN_ROLE` after initial setup
- Consider adding a function that forces renunciation of the deployer's admin role
- Add a check in the constructor to ensure the deployer cannot retain admin role indefinitely

---

## Finding #3: Executor Allows Zero Delay -- Governance Actions Execute Immediately

**Severity: Low**

**File:** `/root/immunefi/audits/sparklend/src/spark-gov-relay/src/Executor.sol`
**Lines:** 219-221

### Description

The `_updateDelay` function has no minimum delay requirement:

```solidity
function _updateDelay(uint256 newDelay) internal {
    emit DelayUpdate(delay, newDelay);
    delay = newDelay;
}
```

This means `delay` can be set to 0, allowing governance proposals to be queued and executed in the same block, effectively bypassing the timelock protection.

### Attack Scenario

1. Governance (or an admin with `DEFAULT_ADMIN_ROLE`) sets delay to 0
2. A malicious proposal is queued and immediately executed
3. Users have no time to react or exit their positions

### Impact

- Undermines the purpose of the timelock
- Users lose the ability to exit before dangerous governance changes take effect

### Recommendation

Add a minimum delay requirement:
```solidity
function _updateDelay(uint256 newDelay) internal {
    require(newDelay >= MINIMUM_DELAY, "Delay too short");
    emit DelayUpdate(delay, newDelay);
    delay = newDelay;
}
```

---

## Finding #4: Flash Loan Into Borrow Deprecation -- Residual Dead Code and Gas Waste

**Severity: Info**

**File:** `/root/immunefi/audits/sparklend/src/aave-v3-core/contracts/protocol/libraries/logic/FlashLoanLogic.sol`
**Lines:** 93-98, 116-137

### Description

Spark's [SC-343] commit disabled flash-loan-into-borrow by replacing the borrow logic with `revert('FLASHLOAN_INTO_BORROW_DEPRECATED')`. However, several elements of the now-deprecated feature remain:

1. The `interestRateModes` parameter is still accepted in `executeFlashLoan`
2. The `FlashloanParams` struct still includes `maxStableRateBorrowSizePercent`, `reservesCount`, `userEModeCategory`, `pool` -- all unused after the deprecation
3. Premium calculation still checks `interestRateModes[i]` even though non-NONE values will always revert:

```solidity
vars.totalPremiums[vars.i] = DataTypes.InterestRateMode(params.interestRateModes[vars.i]) ==
    DataTypes.InterestRateMode.NONE
    ? vars.currentAmount.percentMul(vars.flashloanPremiumTotal)
    : 0;
```

4. The Pool.sol `flashLoan` function still passes all these deprecated parameters:

```solidity
pool: address(this),
userEModeCategory: _usersEModeCategory[onBehalfOf],
```

### Impact

- No security impact, but wasted gas from unused storage reads and parameter passing
- Code complexity that may confuse future auditors

### Recommendation

Clean up the deprecated parameters from `FlashloanParams`, `Pool.flashLoan()`, and simplify the premium calculation since `interestRateModes` should always be NONE.

---

## Finding #5: Pool.initialize() Missing Flash Loan Premium Initialization

**Severity: Info**

**File:** `/root/immunefi/audits/sparklend/src/aave-v3-core/contracts/protocol/pool/Pool.sol`
**Lines:** 109-112

### Description

The `Pool.initialize()` function only sets `_maxStableRateBorrowSizePercent` but does not initialize `_flashLoanPremiumTotal` or `_flashLoanPremiumToProtocol`:

```solidity
function initialize(IPoolAddressesProvider provider) external virtual initializer {
    require(provider == ADDRESSES_PROVIDER, Errors.INVALID_ADDRESSES_PROVIDER);
    _maxStableRateBorrowSizePercent = 0.25e4;
}
```

This was an intentional change from upstream Aave (commit `3bb960b9: fix: remove initial config of fee params in pool initialize function`). When premiums are 0, flash loans are free (no premium charged). The premiums must be set separately via `updateFlashloanPremiums()` by the PoolConfigurator.

### Impact

- Between deployment and configuration, flash loans have zero premium
- An attacker could front-run the premium configuration to take free flash loans
- The window is likely very small if deployment is done atomically

### Risk Assessment

Low risk -- deployment scripts typically configure all parameters atomically, but worth noting.

---

## Finding #6: E-Mode Price Source Applied Asymmetrically in Liquidation

**Severity: Low**

**File:** `/root/immunefi/audits/sparklend/src/aave-v3-core/contracts/protocol/libraries/logic/LiquidationLogic.sol`
**Lines:** 409-429

### Description

In `_getConfigurationData`, the eMode price source is applied differently for collateral vs debt:

```solidity
if (params.userEModeCategory != 0) {
    address eModePriceSource = eModeCategories[params.userEModeCategory].priceSource;

    if (
        EModeLogic.isInEModeCategory(
            params.userEModeCategory,
            collateralReserve.configuration.getEModeCategory()
        )
    ) {
        liquidationBonus = eModeCategories[params.userEModeCategory].liquidationBonus;

        if (eModePriceSource != address(0)) {
            collateralPriceSource = eModePriceSource;
        }
    }

    // when in eMode, debt will always be in the same eMode category, can skip matching category check
    if (eModePriceSource != address(0)) {
        debtPriceSource = eModePriceSource;
    }
}
```

The collateral price source is only overridden if the collateral asset's eMode category matches the user's eMode category. However, the debt price source is always overridden if eModePriceSource is non-zero, with a comment noting "debt will always be in the same eMode category."

This is **correct by design** because `validateBorrow` enforces that borrows in eMode must be for assets in the same eMode category. However, if:
- A user enters eMode
- Borrows in-category assets
- Governance later changes the eMode category of the debt asset
- The user is now in a state where their debt asset is not in their eMode category, but the eMode price source is still applied

### Impact

- Governance-induced edge case only
- Would result in incorrect pricing for liquidation calculations
- Extremely unlikely in practice

---

## Finding #7: StableDebtToken Average Rate Can Be Set to Zero Prematurely

**Severity: Low**

**File:** `/root/immunefi/audits/sparklend/src/aave-v3-core/contracts/protocol/tokenization/StableDebtToken.sol`
**Lines:** 193-211

### Description

In the `burn()` function, there's a defensive check that can zero out the average stable rate even when supply remains:

```solidity
if (previousSupply <= amount) {
    _avgStableRate = 0;
    _totalSupply = 0;
} else {
    nextSupply = _totalSupply = previousSupply - amount;
    uint256 firstTerm = uint256(_avgStableRate).rayMul(previousSupply.wadToRay());
    uint256 secondTerm = userStableRate.rayMul(amount.wadToRay());

    // For the same reason described above, when the last user is repaying it might
    // happen that user rate * user balance > avg rate * total supply. In that case,
    // we simply set the avg rate to 0
    if (secondTerm >= firstTerm) {
        nextAvgStableRate = _totalSupply = _avgStableRate = 0;
    }
```

When `secondTerm >= firstTerm` (which can happen due to rounding/compounding differences), **both** `_totalSupply` and `_avgStableRate` are zeroed out. This means:
- The total supply is set to 0 even if there's remaining debt
- The average rate becomes 0

The next interaction will recalculate correctly, but between the zeroing and the next update, queries to `totalSupply()` will return 0, which could affect interest rate calculations and protocol accounting.

### Impact

- Temporary accounting inconsistency in edge cases
- Interest rate strategy could compute incorrect rates during this window
- The impact is transient and self-correcting on the next state update

---

## Finding #8: Unchecked Division in Isolation Mode Debt Ceiling Calculation

**Severity: Low**

**File:** `/root/immunefi/audits/sparklend/src/aave-v3-core/contracts/protocol/libraries/logic/BorrowLogic.sol`
**Lines:** 134-138

### Description

```solidity
if (isolationModeActive) {
    uint256 nextIsolationModeTotalDebt = reservesData[isolationModeCollateralAddress]
        .isolationModeTotalDebt += (params.amount /
        10 **
            (reserveCache.reserveConfiguration.getDecimals() -
                ReserveConfiguration.DEBT_CEILING_DECIMALS)).toUint128();
```

If `reserveConfiguration.getDecimals()` is less than `DEBT_CEILING_DECIMALS` (which is 2), the subtraction would underflow. Since Solidity 0.8.x has built-in overflow checks, this would revert, effectively blocking borrowing for assets with fewer than 2 decimals.

### Impact

- Assets with fewer than 2 decimals cannot be borrowed in isolation mode
- This is a known limitation rather than a vulnerability, as virtually all ERC20 tokens have >= 2 decimals

---

## Finding #9: AaveOracle Does Not Validate Staleness of Chainlink Price

**Severity: Low**

**File:** `/root/immunefi/audits/sparklend/src/aave-v3-core/contracts/misc/AaveOracle.sol`
**Lines:** 101-116

### Description

```solidity
function getAssetPrice(address asset) public view override returns (uint256) {
    AggregatorInterface source = assetsSources[asset];

    if (asset == BASE_CURRENCY) {
        return BASE_CURRENCY_UNIT;
    } else if (address(source) == address(0)) {
        return _fallbackOracle.getAssetPrice(asset);
    } else {
        int256 price = source.latestAnswer();
        if (price > 0) {
            return uint256(price);
        } else {
            return _fallbackOracle.getAssetPrice(asset);
        }
    }
}
```

The oracle only checks if `price > 0` but does not:
1. Check the staleness of the price (e.g., using `latestRoundData().updatedAt`)
2. Verify the round is complete (`answeredInRound >= roundId`)
3. Check for sequencer uptime (relevant for L2 deployments)

The `AggregatorInterface` used is the legacy Chainlink interface that only provides `latestAnswer()` without round metadata, so staleness checks are structurally impossible with this interface.

### Impact

- Stale oracle prices could enable profitable liquidations or under-collateralized borrows
- Mitigated by the fallback oracle mechanism and PriceOracleSentinel
- This is a known Aave V3 design choice

---

## Finding #10: Liquidation Protocol Fee Can Exceed Available Scaled Balance Due to Rounding

**Severity: Info**

**File:** `/root/immunefi/audits/sparklend/src/aave-v3-core/contracts/protocol/libraries/logic/LiquidationLogic.sol`
**Lines:** 203-217

### Description

The liquidation fee transfer includes a defensive check for rounding:

```solidity
if (vars.liquidationProtocolFeeAmount != 0) {
    uint256 liquidityIndex = collateralReserve.getNormalizedIncome();
    uint256 scaledDownLiquidationProtocolFee = vars.liquidationProtocolFeeAmount.rayDiv(
        liquidityIndex
    );
    uint256 scaledDownUserBalance = vars.collateralAToken.scaledBalanceOf(params.user);
    // To avoid trying to send more aTokens than available on balance, due to 1 wei imprecision
    if (scaledDownLiquidationProtocolFee > scaledDownUserBalance) {
        vars.liquidationProtocolFeeAmount = scaledDownUserBalance.rayMul(liquidityIndex);
    }
    vars.collateralAToken.transferOnLiquidation(
        params.user,
        vars.collateralAToken.RESERVE_TREASURY_ADDRESS(),
        vars.liquidationProtocolFeeAmount
    );
}
```

This correctly handles the 1-wei rounding imprecision. However, the `liquidityIndex` used here is fetched via `getNormalizedIncome()` which computes a fresh value based on current timestamp, while the collateral reserve state may not have been updated if `receiveAToken` is true (the `_liquidateATokens` path does NOT call `collateralReserve.updateState()`).

There's a subtle inconsistency: when `receiveAToken` is true, the liquidation protocol fee calculation uses a `liquidityIndex` that hasn't been applied to the reserve state, while `_burnCollateralATokens` properly calls `updateState()` first. In practice, the rounding guard protects against this, and the difference is at most 1 wei.

### Impact

- At most 1 wei of imprecision in liquidation protocol fee
- No exploitable impact

---

## Finding #11: `repayWithATokens` Allows Self-Liquidation Pattern

**Severity: Info**

**File:** `/root/immunefi/audits/sparklend/src/aave-v3-core/contracts/protocol/pool/Pool.sol`
**Lines:** 305-323

### Description

`repayWithATokens` forces `onBehalfOf` to be `msg.sender`:

```solidity
function repayWithATokens(
    address asset,
    uint256 amount,
    uint256 interestRateMode
) public virtual override returns (uint256) {
    return BorrowLogic.executeRepay(
        _reserves,
        _reservesList,
        _usersConfig[msg.sender],
        DataTypes.ExecuteRepayParams({
            asset: asset,
            amount: amount,
            interestRateMode: DataTypes.InterestRateMode(interestRateMode),
            onBehalfOf: msg.sender,
            useATokens: true
        })
    );
}
```

This is correct -- users can only repay their own debt with aTokens. The aToken burning in `BorrowLogic.executeRepay` burns from `msg.sender`:

```solidity
if (params.useATokens) {
    IAToken(reserveCache.aTokenAddress).burn(
        msg.sender,
        reserveCache.aTokenAddress,
        paybackAmount,
        reserveCache.nextLiquidityIndex
    );
}
```

No vulnerability found here -- just documenting that the access control is correct.

---

## Finding #12: Bridge `executeBackUnbacked` Fee-to-LP Cumulation Could Inflate Liquidity Index

**Severity: Info**

**File:** `/root/immunefi/audits/sparklend/src/aave-v3-core/contracts/protocol/libraries/logic/BridgeLogic.sol`
**Lines:** 133-137

### Description

```solidity
reserveCache.nextLiquidityIndex = reserve.cumulateToLiquidityIndex(
    IERC20(reserveCache.aTokenAddress).totalSupply() +
        uint256(reserve.accruedToTreasury).rayMul(reserveCache.nextLiquidityIndex),
    feeToLP
);
```

The `feeToLP` is cumulated to the liquidity index distributed across all suppliers. The `totalSupply()` call here returns the aToken total supply (which is dynamic and includes accrued interest). If a bridge backs a large unbacked amount with a proportionally large fee while supply is very low, the liquidity index jump could be disproportionate.

### Impact

- Only callable by bridge role (trusted)
- The fee is determined by the backer, who has no incentive to overpay
- No exploitable vulnerability

---

## Observations on Spark-Specific Modifications

### SC-342 (Jan 10 Patch) -- The Original Vulnerability and Fix

The patch addressed a critical vulnerability in flash-loan-into-borrow where stale parameters were used:

**Original code** used cached values from Pool.sol for flash loan borrow:
- `params.maxStableRateBorrowSizePercent` (cached at flashloan entry)
- `params.reservesCount` (cached at flashloan entry)
- `params.userEModeCategory` (cached at flashloan entry)

**The fix** re-reads these from storage during the borrow:
```solidity
maxStableRateBorrowSizePercent: IPool(params.pool).MAX_STABLE_RATE_BORROW_SIZE_PERCENT(),
reservesCount: IPool(params.pool).getReservesCount(),
userEModeCategory: IPool(params.pool).getUserEMode(params.onBehalfOf).toUint8(),
```

**Why this mattered:** The flash loan callback executes arbitrary user code. Within that callback, the user could have changed their eMode category, new reserves could have been added, etc. Using cached values meant the borrow validation was checking against stale state.

### SC-343 (Disable Flash Loan Into Borrow)

This subsequent change completely removed the flash-loan-into-borrow feature, replacing it with a hard revert. This is the more conservative approach and eliminates the entire attack surface.

The removal is clean -- the revert is reached when any `interestRateMode` is not `NONE`, which covers all borrow-mode flash loans.

---

## Architecture Review Notes

### Reentrancy Protection

The protocol uses a cache-update-validate-change-updateRates pattern. For flash loans, this is intentionally reordered to validate-payload-cache-update to prevent reentrancy manipulation. With the flash-loan-into-borrow deprecation, reentrancy risk through flash loans is effectively eliminated since no state changes occur before the external callback returns.

### Interest Rate Model

The `DefaultReserveInterestRateStrategy` implements the standard two-slope model. The `calculateInterestRates` function reads the reserve token balance directly from the ERC20 contract:

```solidity
vars.availableLiquidity =
    IERC20(params.reserve).balanceOf(params.aToken) +
    params.liquidityAdded -
    params.liquidityTaken;
```

This is called AFTER the token transfer in supply/borrow flows, which ensures the balance reflects the new state. The interest rate cannot be manipulated within a single transaction because the reads are post-transfer.

### Health Factor Calculation

The health factor calculation in `GenericLogic.calculateUserAccountData` iterates through all user positions and computes weighted LTV/liquidation thresholds. The `unchecked` division at lines 163-170 is safe because:
- Division by zero is protected by the ternary check
- The values are always positive (asset prices, balances)

### Debt Token Authorization

Both `VariableDebtToken.mint()` and `StableDebtToken.mint()` correctly:
1. Check `onlyPool` modifier
2. Decrease borrow allowance when `user != onBehalfOf`

The `burn()` functions are also properly restricted to `onlyPool`.

---

## Summary Table

| # | Finding | Severity | File | Status |
|---|---------|----------|------|--------|
| 1 | SavingsDaiOracle stale `chi` value | Medium | SavingsDaiOracle.sol | Design tradeoff |
| 2 | Executor `executeDelegateCall` accessible to DEFAULT_ADMIN_ROLE | Medium | Executor.sol | Trust assumption |
| 3 | Executor allows zero delay | Low | Executor.sol | Missing validation |
| 4 | Flash loan into borrow residual dead code | Info | FlashLoanLogic.sol | Code hygiene |
| 5 | Pool.initialize() missing premium initialization | Info | Pool.sol | By design |
| 6 | E-Mode price source asymmetric application | Low | LiquidationLogic.sol | Edge case |
| 7 | StableDebtToken average rate premature zeroing | Low | StableDebtToken.sol | Known limitation |
| 8 | Isolation mode unchecked decimal subtraction | Low | BorrowLogic.sol | Known limitation |
| 9 | AaveOracle no staleness check | Low | AaveOracle.sol | Known design |
| 10 | Liquidation protocol fee rounding | Info | LiquidationLogic.sol | Handled |
| 11 | repayWithATokens access control | Info | Pool.sol | Correct |
| 12 | Bridge fee cumulation edge case | Info | BridgeLogic.sol | Trusted role only |

---

## Conclusion

The Spark fork of Aave V3 is well-maintained with targeted, conservative modifications. The most significant change -- the flash-loan-into-borrow deprecation -- effectively eliminates the primary Spark-specific attack surface. The codebase inherits Aave V3's extensively-audited architecture.

**No critical or high-severity exploitable vulnerabilities were found in the Spark-specific modifications.** The most notable finding is the SavingsDaiOracle's reliance on the potentially stale `chi` value (Finding #1), which is a design tradeoff rather than a bug, mitigated by MEV bot behavior and the small magnitude of potential mispricing.

The Executor contract's governance architecture is standard for timelock-based governance but relies on proper deployment hygiene (deployer renouncing admin role, setting appropriate delays).
