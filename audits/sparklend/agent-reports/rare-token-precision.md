# Token-Specific Quirks, Decimal Mismatches & Precision Edge Cases -- PSM3 + ALM Controller

## Executive Summary

Deep line-by-line analysis of PSM3.sol, ApproveLib.sol, MainnetController.sol, ForeignController.sol, PSMLib.sol, CCTPLib.sol, and all associated test files. Investigated USDT approve quirks, 6-vs-18 decimal precision loss, fee-on-transfer tokens, USDC blacklisting, sUSDS conversion rate edge cases, rounding direction inconsistencies, zero-amount edge cases, and max uint256 edge cases.

**Verdict: No novel Critical/High severity exploitable bugs found.** The PSM3 code is well-designed with consistent rounding-against-user semantics, comprehensive fuzz testing, and careful decimal handling. The ALM Controller correctly implements forceApprove patterns. Several known design limitations (documented by the team in their own tests) and lower-severity observations are detailed below.

---

## 1. USDT Non-Standard approve() Analysis

### PSM3 Contract

PSM3.sol does **not** call `approve()` at all. It uses:
- `safeTransferFrom()` on line 417 (`_pullAsset`) -- pulls from user
- `safeTransfer()` on line 424 (`_pushAsset`) -- pushes to user
- `safeTransferFrom()` on line 98 and 422 (`setPocket`, `_pushAsset` when pocket != PSM) -- transfers USDC

The PSM3 contract never needs to approve anything because it only holds and transfers tokens it already possesses. Users must approve the PSM before depositing. **No USDT approve issue in PSM3.**

### ApproveLib.sol (ALM Controller)

File: `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/libraries/ApproveLib.sol`

```solidity
function approve(address token, address proxy, address spender, uint256 amount) internal {
    bytes memory approveData = abi.encodeCall(IERC20.approve, (spender, amount));
    ( bool success, bytes memory data )
        = proxy.call(abi.encodeCall(IALMProxy.doCall, (token, approveData)));
    // ... if approve succeeds, return
    // If call was unsuccessful, set to zero and try again.
    IALMProxy(proxy).doCall(token, abi.encodeCall(IERC20.approve, (spender, 0)));
    returnData = IALMProxy(proxy).doCall(token, approveData);
}
```

This correctly implements the forceApprove pattern: attempt approve, if it fails, set to 0 first, then retry. **Handles USDT correctly.**

### ForeignController._approve()

File: `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/ForeignController.sol` lines 485-519

Same pattern as ApproveLib -- tries approve, on failure sets to 0 then retries. **Handles USDT correctly.**

### PSMLib._approve()

File: `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/libraries/PSMLib.sol` lines 131-139

```solidity
// NOTE: As swaps are only done between USDC and USDS and vice versa, using `_forceApprove`
//       is unnecessary.
function _approve(IALMProxy proxy, address token, address spender, uint256 amount) internal {
    proxy.doCall(token, abi.encodeCall(IERC20.approve, (spender, amount)));
}
```

This uses a simple approve without the forceApprove pattern. The code comment explicitly acknowledges this, noting that only USDC and USDS are used here, neither of which requires the approve-to-zero pattern. **Not a bug -- USDT is not used in this path.**

### CCTPLib._approve()

File: `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/libraries/CCTPLib.sol` lines 94-104

```solidity
// NOTE: As USDC is the only asset transferred using CCTP, _forceApprove logic is unnecessary.
function _approve(IALMProxy proxy, address token, address spender, uint256 amount) internal {
    proxy.doCall(token, abi.encodeCall(IERC20.approve, (spender, amount)));
}
```

Same pattern, same rationale -- only USDC, which doesn't need forceApprove. **Not a bug.**

### MainnetController.sol

Uses `ApproveLib.approve()` which has the forceApprove pattern. **Handles USDT correctly.**

**VERDICT: NOT EXPLOITABLE.** All approve paths either use forceApprove or are explicitly limited to USDC/USDS which don't need it.

---

## 2. 6-Decimal vs 18-Decimal Precision Loss Analysis

### Core Conversion Functions

PSM3 normalizes all values to 18-decimal "asset value" using these functions:

```solidity
function _getUsdcValue(uint256 amount) internal view returns (uint256) {
    return amount * 1e18 / _usdcPrecision;  // amount * 1e18 / 1e6 = amount * 1e12
}

function _getUsdsValue(uint256 amount) internal view returns (uint256) {
    return amount * 1e18 / _usdsPrecision;  // amount * 1e18 / 1e18 = amount (no change)
}
```

Converting back (in `convertToAssets`):
```solidity
if (asset == address(usdc)) return assetValue * _usdcPrecision / 1e18;
    // = assetValue * 1e6 / 1e18 = assetValue / 1e12
```

### Precision Loss Scenario: USDC Deposit -> USDS Withdraw

1. Deposit 1 USDC (1e6) -> value = 1e6 * 1e12 = 1e18 -> shares = 1e18
2. Withdraw as USDS: convertToAssets(usds, 1e18) = 1e18 * 1e18 / 1e18 = 1e18
3. Result: 1e18 USDS = $1 exactly. **No loss.**

### Precision Loss Scenario: Small USDS Deposit -> USDC Withdraw

1. Deposit 1 wei USDS (value = 1) -> shares = 1
2. Withdraw as USDC: convertToAssets(usdc, 1) = 1 * 1e6 / 1e18 = 0
3. **User gets 0 USDC back!** 1 wei of value is lost.

But this is intentional: the test `test_convertToAssets` at line 63 explicitly verifies:
```solidity
assertEq(psm.convertToAssets(address(usdc), 1), 0);
assertEq(psm.convertToAssets(address(usdc), 2), 0);
assertEq(psm.convertToAssets(address(usdc), 3), 0);
```

The minimum deposit to get any USDC back is 1e12 value (=1e12 shares), which is $0.000001. **Not economically exploitable.**

### Precision Loss in Swap Paths: USDC -> sUSDS -> USDC Round Trip

At rate = 1.25e27:
1. Swap 1 USDC (1e6) to sUSDS via `_convertToSUsds`:
   - `amount * 1e27 / rate * _susdsPrecision / assetPrecision`
   - `= 1e6 * 1e27 / 1.25e27 * 1e18 / 1e6`
   - `= 0.8e6 * 1e18 / 1e6 = 0.8e18` sUSDS

2. Swap 0.8e18 sUSDS back to USDC via `_convertFromSUsds`:
   - `amount * rate / 1e27 * assetPrecision / _susdsPrecision`
   - `= 0.8e18 * 1.25e27 / 1e27 * 1e6 / 1e18`
   - `= 1e18 * 1e6 / 1e18 = 1e6` USDC

**Exact round trip with clean rates.** No loss.

### Precision Loss with Non-Clean Rates

At rate = 1.25e27 * 100 / 99 (the "rounding rate" from Rounding.t.sol):

The `_convertToSUsds` function uses sequential division:
```solidity
amount * 1e27 / rate * _susdsPrecision / assetPrecision
```

This introduces intermediate truncation at `amount * 1e27 / rate`. Each division truncates, and the truncation can compound. However:

- SwapExactIn rounds **down** the output (user gets less)
- SwapExactOut rounds **up** the input (user pays more)
- Deposit rounds **down** shares (user gets less shares)
- Withdraw rounds **up** shares to burn (user loses more shares)

The fuzz tests in SwapExactIn.t.sol (lines 447-457) verify that after 1000 swaps, each LP's value only ever increases, by at most 2e12 per swap. The invariant tests confirm `assertGe(valueSwappedIn, valueSwappedOut)` (line 155 of Invariants.t.sol).

### Dust Accumulation

Dust from rounding always goes TO the pool (benefits LPs). Over millions of transactions, LPs accumulate dust. No user can extract dust that isn't theirs. The fuzz test `testFuzz_swapExactIn` runs 1000 iterations and confirms rounding errors are bounded at 2e12 per swap and always favor LPs.

**VERDICT: NOT EXPLOITABLE.** Rounding is consistently in favor of the protocol/LPs. Dust accumulates in the pool, benefiting existing depositors. The maximum rounding error per operation is ~2e12 wei (~$0.000002), making any attack economically infeasible even across millions of iterations.

---

## 3. Fee-on-Transfer Token Analysis

PSM3 uses `safeTransferFrom` and `safeTransfer` from the erc20-helpers library. It does **NOT** check `balanceOf` before/after transfers. It trusts the `amount` parameter:

```solidity
function _pullAsset(address asset, uint256 amount) internal {
    IERC20(asset).safeTransferFrom(msg.sender, _getAssetCustodian(asset), amount);
}
```

If a fee-on-transfer token were used as USDC, USDS, or sUSDS:
- User deposits 100 tokens, but PSM receives only 98 (2% fee)
- PSM credits user for 100 tokens worth of shares
- User withdraws 100 tokens, draining the PSM

**However:** PSM3 is deployed with specific, immutable token addresses set at construction. The tokens are:
- USDC: Standard Circle USDC -- no transfer fees
- USDS: MakerDAO's stablecoin -- no transfer fees
- sUSDS: MakerDAO's savings token -- no transfer fees

The immutable addresses prevent swapping to a fee-on-transfer token after deployment.

**Could bridged USDC variants have fees?** On L2s where PSM3 may be deployed, the token addresses are set at construction. If a chain used a fee-on-transfer USDC variant, the PSM would be vulnerable. But:
1. The PSM3 constructor doesn't check for fee-on-transfer behavior (no before/after balance check)
2. However, no major USDC variant has transfer fees
3. The deployment process would need to verify token behavior

**VERDICT: DESIGN LIMITATION, NOT CURRENTLY EXPLOITABLE.** The code trusts token transfer amounts, but the actual tokens used don't have fees. If deployed with a fee-on-transfer token, it would be Critical. This is a known pattern that is acceptable given the specific, immutable token configuration.

---

## 4. USDC Blacklisting Analysis

### The Scenario

If Circle blacklists the PSM3 contract address (or the `pocket` address for USDC), all USDC transfers to/from that address would revert. This would:

1. **Freeze all USDC in the PSM/pocket**: `safeTransfer` and `safeTransferFrom` would revert
2. **Block all USDC deposits**: `_pullAsset` would revert for USDC
3. **Block all USDC withdrawals**: `_pushAsset` would revert for USDC
4. **Block all swaps involving USDC**: Both in and out
5. **Block `setPocket`**: Line 96-98 transfers USDC balance, which would revert

### Recovery Mechanisms

Looking at PSM3:
- `setPocket()` (line 86): Transfers ALL USDC from old pocket to new pocket. If either is blacklisted, this reverts. **No recovery possible through setPocket.**
- There is **no** emergency withdrawal function
- There is **no** admin rescue function
- There is **no** multi-custodian setup for USDC
- The `pocket` pattern provides some mitigation: if `pocket` is an external address, and only `pocket` (not PSM3) is blacklisted, then USDS and sUSDS operations still work on PSM3. But USDC is stuck.

### Impact Assessment

If the PSM3 contract or pocket is blacklisted:
- All USDC in the pocket is permanently frozen
- LP depositors who deposited USDC can only withdraw USDS or sUSDS (if available)
- The `totalAssets()` function still counts the frozen USDC balance, meaning share valuations are inflated
- Users can still deposit/withdraw USDS and sUSDS, but the share price is artificially high because it includes frozen USDC value

### Is This a Valid Bug?

This is a **known limitation** of any contract that holds USDC. Circle's blacklisting authority is a well-understood risk in DeFi. The question is whether Spark's architecture should have mitigations.

The `pocket` design pattern actually provides partial mitigation -- by moving USDC to an external custodian, the PSM3 contract itself is less likely to be blacklisted (it doesn't hold USDC directly). However, if the pocket is blacklisted, the same problem occurs.

**VERDICT: KNOWN DESIGN LIMITATION.** This is not a novel vulnerability. USDC blacklisting risk is inherent to any protocol holding USDC. The pocket pattern provides partial mitigation. Most bounty programs explicitly exclude "admin key" and "centralized oracle" risks, and USDC blacklisting falls into the "trusted centralized entity" category. Immunefi would likely classify this as out of scope unless the program explicitly includes centralized dependency risks.

---

## 5. sUSDS Conversion Rate Edge Cases

### Rate = 1e27 (RAY, exactly 1:1)

```solidity
_getSUsdsValue(amount, false):
    amount * 1e27 / 1e9 / 1e18 = amount * 1e18 / 1e18 = amount
```
**Works correctly.** 1 sUSDS = $1.

### Rate = 2e27 (2:1)

```solidity
_getSUsdsValue(amount, false):
    amount * 2e27 / 1e9 / 1e18 = amount * 2e18 / 1e18 = 2 * amount
```
**Works correctly.** 1 sUSDS = $2.

### Rate = type(uint256).max / 2

The concern is overflow in `amount * rate`:

```solidity
_getSUsdsValue(amount, false):
    amount * rate / 1e9 / _susdsPrecision
```

If rate = type(uint256).max / 2 ~= 5.78e76:
- Even amount = 1 gives: 1 * 5.78e76 = 5.78e76, which fits in uint256
- For amount = 1e18: 1e18 * 5.78e76 = 5.78e94, which still fits (uint256 max is ~1.15e77)

Wait -- 1e18 * 5.78e76 = 5.78e94 > 1.15e77. **This overflows!**

But the test bounds show the rate is bounded in practice:
- Fuzz tests use `conversionRate = _bound(conversionRate, 0.0001e27, 1000e27)`
- The invariant tests use realistic rates (1x to 200x)
- The constructor requires `getConversionRate() != 0` but has no upper bound check

However, the `_convertToSUsds` function uses `amount * 1e27`:
```solidity
function _convertToSUsds(uint256 amount, uint256 assetPrecision, bool roundUp) {
    uint256 rate = IRateProviderLike(rateProvider).getConversionRate();
    if (!roundUp) return amount * 1e27 / rate * _susdsPrecision / assetPrecision;
}
```

For `amount = 1e30` (USDS_TOKEN_MAX) and rate = 1e27:
- `1e30 * 1e27 = 1e57` -- fits in uint256
- But if amount = type(uint256).max: `type(uint256).max * 1e27` overflows

The constructor checks:
```solidity
require(_usdcPrecision <= 1e18, "PSM3/usdc-precision-too-high");
require(_usdsPrecision <= 1e18, "PSM3/usds-precision-too-high");
```

But there's **no upper bound on the rate**. A malicious or compromised rate provider could return an extremely high rate, causing overflow. However:
1. The rate provider is immutable (set at construction)
2. Rate providers are trusted, audited contracts (SSRAuthOracle)
3. The rate would need to be astronomically high to cause overflow with realistic token amounts

**VERDICT: NOT PRACTICALLY EXPLOITABLE.** The rate provider is immutable and trusted. Overflow requires unrealistic rates (>1e40) combined with large amounts. The test suite bounds rates to [0.0001e27, 1000e27] which is safe.

---

## 6. Rounding Direction Consistency Analysis

### Deposit Path (should round DOWN shares -- user gets fewer shares)

```
previewDeposit -> _getAssetValue(asset, amount, false) -> convertToShares(value)
```
- `_getAssetValue` with `roundUp=false`: rounds DOWN value
- `convertToShares`: `assetValue * totalShares / totalAssets_` -- rounds DOWN (Solidity integer division)
- **CORRECT: Both round down, user gets fewer shares.**

### Withdraw Path (should round UP shares to burn -- user burns more shares)

```
previewWithdraw:
    sharesToBurn = _convertToSharesRoundUp(_getAssetValue(asset, assetsWithdrawn, true))
```
- `_getAssetValue` with `roundUp=true`: rounds UP value (uses `Math.ceilDiv`)
- `_convertToSharesRoundUp`: `Math.ceilDiv(assetValue * totalShares, totalValue)` -- rounds UP
- **CORRECT: Both round up, user burns more shares.**

Fallback path (when sharesToBurn > userShares):
```
assetsWithdrawn = convertToAssets(asset, userShares)
```
- `convertToAssets`: `numShares * totalAssets() / totalShares_` -- rounds DOWN (Solidity division)
- For USDC: `assetValue * _usdcPrecision / 1e18` -- rounds DOWN
- For sUSDS: `assetValue * 1e9 * _susdsPrecision / rate` -- rounds DOWN
- Then `sharesToBurn = userShares` (exact, no rounding)
- **CORRECT: User gets fewer assets, burns all their shares.**

### SwapExactIn Path (should round DOWN output -- user gets less)

```
previewSwapExactIn -> _getSwapQuote(assetIn, assetOut, amountIn, false)
```
- All conversion functions with `roundUp=false` use plain integer division, which rounds DOWN
- **CORRECT: User receives fewer output tokens.**

### SwapExactOut Path (should round UP input -- user pays more)

```
previewSwapExactOut -> _getSwapQuote(assetOut, assetIn, amountOut, true)
```
Note the parameter reversal: `asset=assetOut, quoteAsset=assetIn, amount=amountOut, roundUp=true`

- `_convertToSUsds` with roundUp: uses `Math.ceilDiv` twice
- `_convertFromSUsds` with roundUp: uses `Math.ceilDiv` twice
- `_convertOneToOne` with roundUp: uses `Math.ceilDiv`
- **CORRECT: User pays more input tokens.**

### Potential Rounding Inconsistency in `_convertToSUsds`

```solidity
function _convertToSUsds(uint256 amount, uint256 assetPrecision, bool roundUp) {
    if (!roundUp) return amount * 1e27 / rate * _susdsPrecision / assetPrecision;
    return Math.ceilDiv(
        Math.ceilDiv(amount * 1e27, rate) * _susdsPrecision,
        assetPrecision
    );
}
```

The non-roundUp path performs TWO sequential divisions: first by `rate`, then by `assetPrecision`. Each division truncates. This means the result is rounded down TWICE, which could lose more precision than a single combined operation.

Compare: `amount * 1e27 / rate * _susdsPrecision / assetPrecision`
vs: `amount * 1e27 * _susdsPrecision / (rate * assetPrecision)`

The sequential version truncates at two points. However, since this is the round-DOWN path (user gets less), rounding down MORE is actually MORE favorable to the protocol. This is intentional -- rounding errors in swaps always favor the pool.

The fuzz tests confirm this: `assertGe(valueSwappedIn, valueSwappedOut)` -- the value coming in always >= value going out.

**VERDICT: NOT EXPLOITABLE.** Rounding direction is consistently against the user in ALL paths. Where multiple truncations occur, they compound in the protocol's favor. The test suite (especially the 1000-iteration fuzz tests with `assertGe` checks) provides strong evidence that rounding never favors the user.

---

## 7. Zero Amount Edge Cases

### deposit(asset, receiver, 0)

```solidity
function deposit(address asset, address receiver, uint256 assetsToDeposit) {
    require(assetsToDeposit != 0, "PSM3/invalid-amount");
```
**Reverts.** Cannot deposit 0.

### withdraw(asset, receiver, 0)

```solidity
function withdraw(address asset, address receiver, uint256 maxAssetsToWithdraw) {
    require(maxAssetsToWithdraw != 0, "PSM3/invalid-amount");
```
**Reverts.** Cannot withdraw 0.

### swapExactIn with amountIn = 0

```solidity
function swapExactIn(..., uint256 amountIn, ...) {
    require(amountIn != 0, "PSM3/invalid-amountIn");
```
**Reverts.** Cannot swap 0 in.

### swapExactOut with amountOut = 0

```solidity
function swapExactOut(..., uint256 amountOut, ...) {
    require(amountOut != 0, "PSM3/invalid-amountOut");
```
**Reverts.** Cannot swap 0 out.

**VERDICT: SAFE.** All zero-amount inputs are explicitly rejected.

---

## 8. Max uint256 Edge Cases

### deposit with type(uint256).max

This would attempt `safeTransferFrom(msg.sender, custodian, type(uint256).max)`. Unless the user has approved and holds type(uint256).max tokens, this reverts at the token level. If somehow it succeeded:

- `previewDeposit` calls `_getAssetValue(asset, type(uint256).max, false)`
- For USDC: `type(uint256).max * 1e18 / 1e6` -- **OVERFLOW** (type(uint256).max * 1e18 > uint256 max)
- For sUSDS: `type(uint256).max * rate / 1e9 / 1e18` -- **OVERFLOW** (type(uint256).max * rate > uint256 max for any rate > 1)

These overflows would revert the transaction. **Safe via natural revert.**

### withdraw with type(uint256).max

```solidity
function previewWithdraw(address asset, uint256 maxAssetsToWithdraw) {
    uint256 assetBalance = IERC20(asset).balanceOf(_getAssetCustodian(asset));
    assetsWithdrawn = assetBalance < maxAssetsToWithdraw ? assetBalance : maxAssetsToWithdraw;
```

type(uint256).max is handled gracefully -- `assetsWithdrawn` is capped to `assetBalance`. The test `test_withdraw_amountHigherThanBalanceOfAsset` explicitly tests this pattern, and `test_withdraw_changeConversionRate` uses `type(uint256).max` as the withdraw amount.

**VERDICT: SAFE.** Max amounts either revert via overflow (deposits/swaps) or are gracefully capped (withdrawals).

---

## 9. DoS via Pre-First-Deposit Transfer (KNOWN -- Documented in Tests)

File: `/root/immunefi/audits/sparklend/src/spark-psm/test/unit/DoSAttack.t.sol`

The team has documented and tested a scenario where sending tokens directly to the PSM (or pocket) before the first deposit creates a permanent DoS:

```solidity
function test_dos_sendFundsBeforeFirstDeposit() public {
    usdc.transfer(pocket, 100e6);
    _deposit(address(usdc), address(user1), 1_000_000e6);
    assertEq(psm.totalShares(), 0);  // No shares minted!
}
```

This happens because:
1. `totalAssets()` returns the USDC balance (100e6 * 1e12 = 100e18)
2. `convertToShares` enters the `if (totalAssets_ != 0)` branch: `assetValue * totalShares / totalAssets_`
3. Since `totalShares = 0`, this returns 0 regardless of `assetValue`
4. All subsequent deposits also get 0 shares
5. Funds are irrecoverable

**Mitigation:** The invariant tests seed the PSM with a 1e18 share deposit to the burn address. The comment explicitly states: "All invariant tests are operating under the assumption that the initial seed deposit of 1e18 shares has been made."

**VERDICT: KNOWN ISSUE, MITIGATED BY DEPLOYMENT PROCEDURE.** The team is aware and requires seed deposits at deployment. This is explicitly documented in test code. Not submittable as a new finding.

---

## 10. Inflation Attack (KNOWN -- Documented in Tests)

File: `/root/immunefi/audits/sparklend/src/spark-psm/test/unit/InflationAttack.t.sol`

The classic ERC4626-style inflation attack is tested and documented:
- Without initial deposit: attacker can front-run and steal 50% of first depositor's funds
- With initial deposit (seed): attack fails, attacker loses funds to the seed depositor

**VERDICT: KNOWN ISSUE, MITIGATED BY SEED DEPOSIT.** Standard ERC4626 attack, standard mitigation.

---

## 11. Precision Loss in Sequential Division (Swap Conversion Functions)

### The Pattern

In `_convertToSUsds` (line 362):
```solidity
return amount * 1e27 / rate * _susdsPrecision / assetPrecision;
```

And `_convertFromSUsds` (line 375):
```solidity
return amount * rate / 1e27 * assetPrecision / _susdsPrecision;
```

Both use sequential division which causes intermediate truncation. Consider `_convertToSUsds` for USDC (assetPrecision = 1e6):

```
amount * 1e27 / rate * 1e18 / 1e6
= (amount * 1e27 / rate) * 1e12
```

The first division `amount * 1e27 / rate` truncates. Then multiplying by 1e12 amplifies the truncation error by 1e12.

For USDC amount = 1:
- `1 * 1e27 / 1.25e27 = 0` (truncated!) then `0 * 1e12 = 0`
- User gets 0 sUSDS for 1 USDC unit ($0.000001)

This is the behavior shown in test line 181:
```solidity
assertEq(psm.previewSwapExactIn(address(usdc), address(susds), 1e6 + 1), 0.8e18);
// 1e6 + 1 USDC = 0.8e18 sUSDS (the +1 is lost)
```

The maximum rounding error per swap is bounded. For USDC <-> sUSDS swaps, the error is up to 1e12 (as confirmed by the fuzz test tolerance). This corresponds to $0.000001 per swap.

### Could This Be Exploited?

An attacker would need to find a path where rounding favors them. But:
- `swapExactIn` rounds DOWN output (user gets less)
- `swapExactOut` rounds UP input (user pays more)
- Both directions are unfavorable to the user

Round trip analysis:
1. Swap USDC -> sUSDS via swapExactIn: user gets LESS sUSDS (rounded down)
2. Swap sUSDS -> USDC via swapExactIn: user gets LESS USDC (rounded down)
3. Net: user lost value in both directions

The invariant test `_checkInvariant_F()` confirms: `assertGe(totalValueSwappedIn, totalValueSwappedOut)` with tolerance of `swapCount * 3e12`.

**VERDICT: NOT EXPLOITABLE.** The sequential division pattern causes precision loss, but it consistently rounds against the user. The maximum loss per operation (~$0.000001) makes this economically irrelevant for attack purposes and beneficial to LPs.

---

## 12. PSMLib Simple Approve in ALM Controller (Investigated)

File: `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/libraries/PSMLib.sol`

```solidity
function _approve(IALMProxy proxy, address token, address spender, uint256 amount) internal {
    proxy.doCall(token, abi.encodeCall(IERC20.approve, (spender, amount)));
}
```

This does not use forceApprove. If the proxy already has a non-zero allowance for USDC to the PSM, and then `swapUSDSToUSDC` is called, the approve could fail for tokens requiring approve-to-zero.

However:
1. The comment says "only USDC and USDS" are used here
2. USDC and USDS do not require approve-to-zero (USDT does)
3. If the previous swap consumed the exact approved amount, allowance is back to 0

There is a subtle scenario: if a previous swap reverts AFTER the approve but BEFORE the actual swap, the allowance remains non-zero. Then the next call to `_approve` would try to approve again. For USDC, this works fine (USDC allows re-approving). For USDT, this would fail -- but USDT is not used here.

**VERDICT: NOT EXPLOITABLE.** Simple approve is safe for the specific tokens (USDC, USDS, DAI) used in PSMLib.

---

## Summary Table

| Investigation Area | Severity | Exploitable? | Details |
|---|---|---|---|
| USDT approve() | N/A | No | ApproveLib uses forceApprove; PSMLib only uses USDC/USDS |
| 6 vs 18 decimal precision | Informational | No | Rounding always against user; max error ~$0.000001 |
| Fee-on-transfer tokens | Low (Design) | No (current tokens) | Not checked, but immutable USDC/USDS/sUSDS don't have fees |
| USDC blacklisting | Low (Design) | N/A | Known centralized dependency; pocket provides partial mitigation |
| sUSDS rate edge cases | Informational | No | Overflow reverts naturally; practical rates are safe |
| Rounding direction | Informational | No | Consistently rounds against user in ALL paths |
| Zero amounts | N/A | No | All explicitly rejected with require checks |
| Max uint256 | N/A | No | Either overflow-reverts or gracefully caps |
| Pre-deposit DoS | Known | Known | Mitigated by seed deposit at deployment |
| Inflation attack | Known | Known | Standard ERC4626 attack, mitigated by seed deposit |
| Sequential division | Informational | No | Amplifies rounding but always against user |

## Conclusion

The PSM3 contract demonstrates strong security engineering:

1. **Rounding is consistently defensive** -- every single conversion path rounds against the user (down for deposits/swapIn outputs, up for withdrawals/swapOut inputs)
2. **The fuzz testing is extensive** -- 1000-iteration fuzz tests with tight tolerance bounds and inequality assertions prove rounding correctness
3. **The invariant testing is thorough** -- 6 invariants tested across 5 different configurations
4. **Known issues are documented** -- DoS and inflation attacks are explicitly tested and mitigated
5. **Token-specific quirks are handled** -- forceApprove in ApproveLib/ForeignController, simple approve only where safe

No novel Critical or High severity vulnerabilities were found. The codebase shows evidence of prior professional auditing and careful defensive programming.
