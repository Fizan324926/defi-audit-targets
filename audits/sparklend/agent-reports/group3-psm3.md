# PSM3 (Peg Stability Module 3) Security Audit Report

## Target Files
- `/root/immunefi/audits/sparklend/src/spark-psm/src/PSM3.sol` (428 lines)
- `/root/immunefi/audits/sparklend/src/spark-psm/src/interfaces/IPSM3.sol` (326 lines)
- `/root/immunefi/audits/sparklend/src/spark-psm/src/interfaces/IRateProviderLike.sol` (6 lines)

## Architecture Overview

PSM3 is a multi-asset Peg Stability Module holding three stablecoin-type assets:
- **USDC** (6 decimals) -- stored in a configurable `pocket` address
- **USDS** (18 decimals) -- stored in the PSM contract itself
- **sUSDS** (18 decimals) -- yield-bearing, stored in the PSM contract itself

The module provides:
1. **Swaps**: Direct 1:1 swaps between USDC/USDS, and rate-adjusted swaps involving sUSDS
2. **Liquidity provision**: Deposit any of the 3 assets, receive shares; withdraw against shares
3. **Share accounting**: An ERC-4626-like shares system tracking proportional ownership of pooled assets

Key design:
- All internal accounting is done in 18-decimal USD-equivalent "asset value"
- sUSDS value is derived from an external `rateProvider.getConversionRate()` (SSR oracle, returns 1e27-scaled rate)
- Rounding is intentionally biased against depositors/withdrawers and in favor of the protocol/LPs
- USDC is held in a separate `pocket` address (settable by owner) for capital efficiency

---

## Finding 1: Donation-Based DoS -- Permanent Fund Lockout via Pre-First-Deposit Donation

**Severity**: Medium (potential High depending on deployment process)

**File**: `/root/immunefi/audits/sparklend/src/spark-psm/src/PSM3.sol`
**Lines**: 160-173, 277-283, 294-298

### Description

If tokens are transferred directly to the PSM's custodian addresses (the `pocket` for USDC, or the PSM contract for USDS/sUSDS) **before** the first deposit, all subsequent depositors will receive **zero shares** permanently. This is because `totalAssets()` returns a non-zero value while `totalShares` remains zero, causing `convertToShares()` to return 0 for any deposit:

```solidity
// Line 277-283
function convertToShares(uint256 assetValue) public view override returns (uint256) {
    uint256 totalAssets_ = totalAssets();
    if (totalAssets_ != 0) {
        return assetValue * totalShares / totalAssets_;  // totalShares = 0 => returns 0
    }
    return assetValue;
}
```

### Attack Scenario

1. PSM is deployed with `pocket = address(this)` (the PSM itself)
2. Attacker transfers 1 USDC directly to the PSM contract
3. `totalAssets()` = 1e18 (from 1 USDC), `totalShares` = 0
4. Any depositor calling `deposit()` receives 0 shares: `assetValue * 0 / 1e18 = 0`
5. Depositor's funds are permanently locked -- they have 0 shares and cannot withdraw

The test file `DoSAttack.t.sol` explicitly demonstrates this:
```solidity
// test_dos_sendFundsBeforeFirstDeposit
usdc.transfer(pocket, 100e6);       // Donate before first deposit
_deposit(address(usdc), user1, 1_000_000e6);  // User deposits 1M USDC
assertEq(psm.shares(user1), 0);     // Gets 0 shares!
```

### Mitigation Assessment

The development team is **aware of this** (they created a test for it). The invariant tests always perform a seed deposit of `1e18 USDS` to `address(0)` as a burn before fuzzing. The comment states:

> NOTE [CRITICAL]: All invariant tests are operating under the assumption that the initial seed deposit of 1e18 shares has been made.

However, this is a **deployment-time assumption** that is not enforced in the constructor. If the deployment script fails to perform the seed deposit, or if the seed deposit is front-run, all subsequent funds can be permanently locked.

### Impact

- Permanent freezing of user funds deposited after the donation
- Funds cannot be recovered (no admin rescue function)
- Requires attacking before the first deposit (narrow window but possible via front-running)

### Recommendation

Add a mandatory seed deposit in the constructor, or add a check in `deposit()` that reverts when `newShares == 0`.

---

## Finding 2: Classic Inflation Attack (First Depositor / Share Price Manipulation)

**Severity**: Medium (mitigated by seed deposit assumption, but still applies to 1-wei-share deposits)

**File**: `/root/immunefi/audits/sparklend/src/spark-psm/src/PSM3.sol`
**Lines**: 160-173, 277-283

### Description

Without the seed deposit protection, the classic ERC-4626 inflation attack is fully possible:

1. Attacker deposits 1 wei of sUSDS or USDS to get 1 share
2. Attacker donates a large amount of USDC to the pocket, inflating the share price
3. Victim deposits, but rounding truncates their shares to 0 or 1
4. Attacker withdraws, stealing a portion of the victim's deposit

### Attack Scenario with Numbers

From the test `test_inflationAttack_noInitialDeposit_susds`:

1. Front-runner deposits 1 wei sUSDS -> gets 1 share
2. Front-runner donates 10M USDC to pocket
3. Share price = 10,000,000e18 + 1 per share
4. Victim deposits 20M USDC -> gets `20M * 1e18 / (10M * 1e18 + 1)` = 1 share (rounds down from ~2)
5. Each share now worth 15M USD
6. Front-runner withdraws 15M, victim gets 15M (lost 5M)

### Mitigation Status

The team's approach is to require a seed deposit to `address(0)` of `1e18` shares at deployment time. The second test `test_inflationAttack_useInitialDeposit_*` demonstrates that with this seed, the attacker loses their donation to existing shareholders.

However, this protection is NOT enforced on-chain. It is purely an operational assumption.

### Impact

With seed deposit: Inflation attack is economically infeasible (attacker loses all donated funds to burn address).
Without seed deposit: Critical theft of depositor funds.

---

## Finding 3: Rounding Favors Protocol Consistently -- Dust Accumulation Over Time

**Severity**: Low (by design, but notable)

**File**: `/root/immunefi/audits/sparklend/src/spark-psm/src/PSM3.sol`
**Lines**: 199-226, 319-330, 357-394

### Description

All rounding in the PSM is systematically biased against users and in favor of the protocol:

1. **Deposits**: `previewDeposit` rounds DOWN (fewer shares minted)
2. **Withdrawals**: `previewWithdraw` rounds UP shares-to-burn via `_convertToSharesRoundUp`, and rounds DOWN assets-to-withdraw when `sharesToBurn > userShares`
3. **Swaps**: `swapExactIn` rounds DOWN the output; `swapExactOut` rounds UP the input
4. **sUSDS conversion**: `_getSUsdsValue` uses `Math.ceilDiv` when `roundUp=true`

This is **correct and intentional** per the invariant tests which assert:
```solidity
assertGe(valueIn, valueOut, "value-out-greater-than-in"); // Swaps always favor protocol
assertGe(psm.convertToAssetValue(1e18), startingConversion); // Share value never decreases from rounding
```

### Numerical Analysis

Per the invariant tests, the maximum rounding error per operation:
- Per swap: up to `2e12` (0.000002 USD) of value accrues to the protocol
- Per 1000 swaps: up to `2000e12` (0.002 USD) cumulative
- Per withdrawal: up to 1 unit of the asset (1 wei USDS, 1 wei USDC = 0.000001 USD)

Over extremely high volumes (millions of transactions), dust accumulates as extra value in the protocol, benefiting remaining LPs. This is not exploitable for profit -- it is a standard and sound practice.

### Impact

Negligible. Users lose at most a few wei per transaction. This is industry standard for share-based vaults.

---

## Finding 4: No Rate Provider Output Validation Beyond Constructor

**Severity**: Low/Info

**File**: `/root/immunefi/audits/sparklend/src/spark-psm/src/PSM3.sol`
**Lines**: 68-71, 260-266, 319-330, 357-381

### Description

The constructor validates that `rateProvider.getConversionRate() != 0` at deployment:

```solidity
require(
    IRateProviderLike(rateProvider_).getConversionRate() != 0,
    "PSM3/rate-provider-returns-zero"
);
```

However, after deployment, there are NO ongoing checks on the rate. If the rate provider were to:
- Return 0 (division by zero in `convertToAssets` for sUSDS)
- Return an extremely large value (overflow potential in multiplications)
- Return a decreasing value (sUSDS "depegging")

The contract would process operations at the reported rate without any sanity checks.

### Analysis

Looking at the actual oracle used (SSRAuthOracle from `xchain-ssr-oracle`), the rate represents the savings rate accumulation and should only increase monotonically. The rate is set by authorized DATA_PROVIDER_ROLE addresses, typically cross-chain message relayers.

A compromised or malfunctioning rate provider returning 0 would cause:
- `_getSUsdsValue` with `roundUp=false`: Returns 0 (loss of sUSDS valuation)
- `_getSUsdsValue` with `roundUp=true`: `Math.ceilDiv(amount * 0, 1e9)` = 0
- `convertToAssets` for sUSDS: Division by zero (revert)
- `_convertToSUsds`: Division by zero (revert)

A rate of 0 would effectively freeze all sUSDS-related operations (swaps involving sUSDS and withdrawals of sUSDS would revert). Deposits of sUSDS would value them at 0, giving 0 shares.

### Impact

This is limited because:
1. The rate provider is a trusted oracle set at construction time (immutable)
2. The oracle has its own access controls (DATA_PROVIDER_ROLE)
3. Rate manipulation would require compromising the oracle governance
4. A zero rate would cause reverts rather than fund theft

---

## Finding 5: Swap Functions Lack Balance Checks -- Revert on Insufficient Liquidity

**Severity**: Info (correct behavior, not a vulnerability)

**File**: `/root/immunefi/audits/sparklend/src/spark-psm/src/PSM3.sol`
**Lines**: 110-154

### Description

The swap functions (`swapExactIn`, `swapExactOut`) calculate amounts via `previewSwapExactIn`/`previewSwapExactOut` and then attempt the transfer. If the PSM does not have sufficient balance of the output asset, the `safeTransfer` / `safeTransferFrom` will revert.

There is no explicit balance check before the transfer. This is by design -- the revert from the ERC20 transfer serves as the balance check, and any explicit check would just add gas cost.

### Impact

None. Failed swaps revert cleanly with `SafeERC20/transfer-failed`.

---

## Finding 6: unchecked Block in Withdrawal -- Relies on previewWithdraw Invariant

**Severity**: Info (safe by design)

**File**: `/root/immunefi/audits/sparklend/src/spark-psm/src/PSM3.sol`
**Lines**: 185-188

### Description

The withdrawal function uses `unchecked` arithmetic:

```solidity
// `previewWithdraw` ensures that `sharesToBurn` <= `shares[msg.sender]`
unchecked {
    shares[msg.sender] -= sharesToBurn;
    totalShares        -= sharesToBurn;
}
```

This is safe because `previewWithdraw` (lines 207-227) caps `sharesToBurn` at `userShares`:

```solidity
uint256 userShares = shares[msg.sender];
if (sharesToBurn > userShares) {
    assetsWithdrawn = convertToAssets(asset, userShares);
    sharesToBurn    = userShares;
}
```

If `sharesToBurn > userShares`, the function recalculates to withdraw only what the user can afford, setting `sharesToBurn = userShares`. This guarantees the unchecked subtraction cannot underflow.

Additionally, `sharesToBurn <= totalShares` is guaranteed because a user's shares are a subset of total shares, and `previewWithdraw` caps at the user's shares.

### Impact

None. The invariant is correctly maintained.

---

## Finding 7: Precision Loss in _convertToSUsds and _convertFromSUsds -- Sequential Division

**Severity**: Low/Info

**File**: `/root/immunefi/audits/sparklend/src/spark-psm/src/PSM3.sol`
**Lines**: 357-381

### Description

The sUSDS conversion functions perform sequential division, which introduces precision loss:

```solidity
// _convertToSUsds (roundUp=false):
return amount * 1e27 / rate * _susdsPrecision / assetPrecision;
//                    ^--- first division truncates, then second division truncates again

// _convertFromSUsds (roundUp=false):
return amount * rate / 1e27 * assetPrecision / _susdsPrecision;
//                  ^--- first division truncates, then second division truncates again
```

For the `roundUp` case, `Math.ceilDiv` is used to round each step up, which is correct for the "round against protocol" intent:

```solidity
// _convertToSUsds (roundUp=true):
return Math.ceilDiv(
    Math.ceilDiv(amount * 1e27, rate) * _susdsPrecision,
    assetPrecision
);
```

### Numerical Example

Consider converting 1 USDC to sUSDS with rate = 1.25e27:
- Non-round: `1e6 * 1e27 / 1.25e27 * 1e18 / 1e6` = `800000 * 1e18 / 1e6` = `800000e12` = `0.8e18` (exact)

Consider converting 3 USDC to sUSDS with rate = 1.33333e27 (1/0.75):
- Step 1: `3e6 * 1e27 / 1.33333e27` = `2250002250002` (truncated)
- Step 2: `2250002250002 * 1e18 / 1e6` = `2250002250002e12` = `2.250002250002e18`
- Combined: `3e6 * 1e27 / 1.33333e27 * 1e18 / 1e6`

The maximum error per conversion is bounded by the invariant tests at `2e12` (~0.000002 USD). This is a fundamental tradeoff of integer arithmetic and is handled correctly.

### Impact

Negligible. Per the invariant assertions: `assertApproxEqAbs(valueIn, valueOut, 1e12 + rateIntroducedRounding * 1e12)` -- up to ~2e12 per swap.

---

## Finding 8: Deposit to Zero Address / Arbitrary Receiver

**Severity**: Info

**File**: `/root/immunefi/audits/sparklend/src/spark-psm/src/PSM3.sol`
**Lines**: 160-173

### Description

The `deposit` function does not validate the `receiver` address:

```solidity
function deposit(address asset, address receiver, uint256 assetsToDeposit)
    external override returns (uint256 newShares)
{
    require(assetsToDeposit != 0, "PSM3/invalid-amount");
    newShares = previewDeposit(asset, assetsToDeposit);
    shares[receiver] += newShares;  // No check for receiver != address(0)
    totalShares      += newShares;
    _pullAsset(asset, assetsToDeposit);
    emit Deposit(asset, msg.sender, receiver, assetsToDeposit, newShares);
}
```

This is actually **used as a feature** -- the invariant tests intentionally deposit to `address(0)` as a burn mechanism for the seed deposit:

```solidity
_deposit(address(usds), BURN_ADDRESS, 1e18); // BURN_ADDRESS = address(0)
```

### Impact

None. This is an intentional design choice. Shares at address(0) are permanently inaccessible, functioning as a burn mechanism.

---

## Finding 9: setPocket Transfers Full USDC Balance -- No Partial Transfer Option

**Severity**: Info

**File**: `/root/immunefi/audits/sparklend/src/spark-psm/src/PSM3.sol`
**Lines**: 86-104

### Description

`setPocket` transfers the **entire USDC balance** from the old pocket to the new pocket:

```solidity
uint256 amountToTransfer = usdc.balanceOf(pocket_);
if (pocket_ == address(this)) {
    usdc.safeTransfer(newPocket, amountToTransfer);
} else {
    usdc.safeTransferFrom(pocket_, newPocket, amountToTransfer);
}
```

If the old pocket holds additional USDC unrelated to the PSM (e.g., USDC from other protocols), all of it gets transferred. However, the `pocket` is expected to be a dedicated address that only holds PSM-related USDC, so this is not a realistic concern.

For the `safeTransferFrom` path, the old pocket must have approved the PSM for the full balance amount. If the allowance is less than the balance, the entire `setPocket` call reverts (demonstrated in `test_setPocket_insufficientAllowanceBoundary`).

### Impact

None in practice. The pocket is a dedicated address controlled by the PSM owner.

---

## Finding 10: No Reentrancy Guard

**Severity**: Info

**File**: `/root/immunefi/audits/sparklend/src/spark-psm/src/PSM3.sol`

### Description

PSM3 does not use a reentrancy guard. The functions that transfer tokens (deposit, withdraw, swap) follow a pattern where state changes happen before external calls in some cases and after in others:

**Deposit** (Lines 160-173): State update (`shares[receiver] += newShares`) happens BEFORE `_pullAsset` (external call). This follows CEI but the shares are already credited before tokens arrive. However, `_pullAsset` uses `safeTransferFrom` which will revert if the token transfer fails, reverting the share update too.

**Withdraw** (Lines 175-193): State update (`shares[msg.sender] -= sharesToBurn`) happens BEFORE `_pushAsset` (external call). This is safe -- even with reentrancy, the user's shares are already decremented.

**Swap** (Lines 110-154): The pull happens before the push, which is correct. `_pullAsset` then `_pushAsset`.

### Analysis

For standard ERC20 tokens (USDC, USDS, sUSDS), there are no reentrancy vectors because:
1. USDC, USDS, and sUSDS do not have callback mechanisms (no ERC-777 hooks)
2. The assets are hardcoded at construction and cannot be changed
3. Even if reentrancy occurred on `_pushAsset`, the state has already been updated

### Impact

None. The supported tokens do not have callback mechanisms, and the state update ordering is safe.

---

## Finding 11: Flash Loan Attack Vector Analysis

**Severity**: Info (not exploitable)

**File**: `/root/immunefi/audits/sparklend/src/spark-psm/src/PSM3.sol`

### Description

Flash loan attack vectors were analyzed:

1. **Flash borrow USDC -> swap USDC to sUSDS -> manipulate rate -> swap back**: The rate provider is immutable and returns the current SSR rate. A flash loan cannot change the rate within a single transaction unless the rate provider itself is vulnerable. The SSRAuthOracle requires governance-level access to modify.

2. **Flash borrow -> deposit -> manipulate totalAssets -> withdraw more**: `totalAssets()` depends on actual balances and the rate. Without manipulating the rate or depositing extra tokens (which would increase your own share count proportionally), this yields no profit.

3. **Flash borrow -> donate to inflate share price -> front-run deposit**: This is the inflation attack (Finding 2), mitigated by the seed deposit assumption.

### Impact

None, assuming the seed deposit is performed and the rate provider is honest.

---

## Finding 12: Cross-Asset Deposit/Withdrawal Asymmetry Analysis

**Severity**: Info (no vulnerability found)

**File**: `/root/immunefi/audits/sparklend/src/spark-psm/src/PSM3.sol`

### Description

Analyzed whether depositing asset X and withdrawing asset Y can extract value:

**Scenario**: Deposit 100 USDC (get 100e18 shares at 1:1), then withdraw as USDS.
- `convertToAssets(usds, 100e18)` = `100e18 * 1e18 / 1e18` = `100e18` USDS = $100
- Net: deposited $100 USDC, withdrew $100 USDS. Zero profit.

**Scenario**: Deposit 100 USDC, rate changes from 1.25 to 1.5, withdraw as sUSDS.
- Shares: 100e18
- `convertToAssetValue(100e18)` = `100e18 * totalAssets / totalShares` (increased due to sUSDS appreciation)
- The sUSDS in the pool appreciated, benefiting all shareholders proportionally
- Withdrawal is capped by the user's proportional share -- no excess extraction possible

**Scenario**: Multiple rapid swaps to exploit rounding.
- Per the invariant tests, each swap's rounding error accrues to the protocol (never to the swapper)
- The invariant `assertGe(valueIn, valueOut)` is maintained for every swap
- Cumulative rounding is bounded at `2e12` per swap (~$0.000002)

### Impact

No asymmetry vulnerability found. The share-based accounting correctly distributes value proportionally.

---

## Summary Table

| # | Finding | Severity | Status |
|---|---------|----------|--------|
| 1 | Donation-based DoS before first deposit | Medium | Known, mitigated by operational seed deposit |
| 2 | Classic inflation attack without seed | Medium | Known, mitigated by operational seed deposit |
| 3 | Rounding dust accumulation | Low | By design, favors protocol |
| 4 | No runtime rate provider validation | Low/Info | Trust assumption on immutable oracle |
| 5 | No explicit balance check in swaps | Info | Correct behavior, reverts on insufficient balance |
| 6 | unchecked block in withdraw | Info | Safe, guarded by previewWithdraw caps |
| 7 | Sequential division precision loss | Low/Info | Bounded, ~2e12 per operation |
| 8 | No receiver validation in deposit | Info | Intentional, used for burn mechanism |
| 9 | setPocket transfers full balance | Info | Expected behavior for dedicated pocket |
| 10 | No reentrancy guard | Info | Safe with supported token types |
| 11 | Flash loan vectors | Info | Not exploitable with seed deposit |
| 12 | Cross-asset deposit/withdrawal asymmetry | Info | No vulnerability found |

---

## Overall Assessment

PSM3 is a well-designed and thoroughly tested contract. The codebase demonstrates strong security awareness:

1. **Rounding discipline**: All rounding consistently favors the protocol/LPs over individual users. This is verified by extensive fuzz testing and invariant testing.

2. **Comprehensive test suite**: The test suite includes unit tests, fuzz tests, invariant tests, and explicit attack scenario tests (inflation attack, DoS attack, rounding tests).

3. **Known risks acknowledged**: The development team has created explicit tests for the donation-based DoS and inflation attacks, documenting the seed deposit requirement as a critical assumption.

4. **Correct CEI pattern**: State changes occur before external calls where security-relevant.

5. **Immutable architecture**: Core configuration (tokens, rate provider) is immutable, reducing governance attack surface.

**Primary risk**: The seed deposit requirement is a deployment-time assumption not enforced in the constructor. If PSM3 is deployed on a new chain without the seed deposit, or if the seed deposit transaction is front-run, all depositor funds could be permanently frozen (Finding 1) or stolen via inflation attack (Finding 2).

**No critical or high severity vulnerabilities were found** that would bypass the documented operational assumptions. The Findings 1 and 2 are rated Medium because they represent real risks if the deployment process is not followed correctly, but they are well-documented and tested by the development team.

---

## Methodology

This audit was performed through:
1. Line-by-line manual review of all 428 lines of PSM3.sol
2. Full review of the IPSM3.sol interface (326 lines) and IRateProviderLike.sol (6 lines)
3. Analysis of all 26 test files including:
   - 8 unit test suites (Constructor, Conversions, Deposit, Withdraw, SwapExactIn, SwapExactOut, Rounding, DoSAttack, InflationAttack, SetPocket, PreviewDeposit, PreviewWithdraw)
   - 6 invariant test configurations
   - 6 handler contracts (LpHandler, SwapperHandler, RateSetterHandler, TimeBasedRateHandler, TransferHandler, OwnerHandler)
   - 1 harness contract
   - 1 mock contract
4. Systematic analysis of all 12 audit angles specified in the audit brief
5. Numerical examples and attack scenario walkthroughs for each potential vulnerability
