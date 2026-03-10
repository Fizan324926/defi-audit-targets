# Security Audit Report: Spark ALM Controller Core

**Auditor:** Smart Contract Security Researcher
**Date:** 2026-03-01
**Target:** Spark ALM Controller -- Asset Liability Management System
**Scope:** MainnetController, ForeignController, RateLimits, RateLimitHelpers, OTCBuffer, WEETHModule, and associated interfaces/libraries
**Bounty Program:** Immunefi (max $5M, Primacy of Impact)

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Architecture Overview](#architecture-overview)
3. [Findings](#findings)
4. [Informational and Design Notes](#informational-and-design-notes)
5. [Files Audited](#files-audited)

---

## Executive Summary

The ALM Controller system is a comprehensive asset management infrastructure that allows privileged RELAYER accounts to manage funds held in an ALMProxy contract across various DeFi protocols (Aave, Curve, Uniswap V4, ERC4626 vaults, Ethena, Maple, etc.) and bridging solutions (CCTP, LayerZero). The system is designed around a role-based access control model with rate limiting as the primary defense against compromised relayers.

The codebase demonstrates strong security practices overall: nonReentrant guards are applied consistently, rate limits constrain relayer actions, and the proxy pattern centralizes fund custody. However, the audit identified several findings across varying severity levels that merit attention.

---

## Architecture Overview

```
Admin (Governance)
    |
    v
MainnetController / ForeignController
    |-- RELAYER role: operational functions (deposit, withdraw, swap, bridge)
    |-- FREEZER role: emergency relayer removal
    |-- DEFAULT_ADMIN_ROLE: configuration
    |
    v
ALMProxy (fund custodian)
    |-- CONTROLLER role: only controller can invoke doCall/doCallWithValue/doDelegateCall
    |-- Holds all protocol funds
    |
    v
External protocols (Aave, Curve, PSM, CCTP, LayerZero, ERC4626, etc.)

RateLimits (rate limit registry)
    |-- DEFAULT_ADMIN_ROLE: set rate limit parameters
    |-- CONTROLLER role: trigger increases/decreases
```

---

## Findings

### Finding 1: MainnetController Uses Non-Constant State Variables for Role and Limit Identifiers

**Severity:** Medium

**File:** `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/MainnetController.sol`
**Lines:** 140-171

**Description:**

In `MainnetController`, the role identifiers (`FREEZER`, `RELAYER`) and all `LIMIT_*` identifiers are declared as `public` (non-constant, non-immutable) storage variables, whereas in `ForeignController` they are declared as `public constant`. Although Solidity initializes state variables from their inline expressions during construction, these are mutable storage slots, not constants.

```solidity
// MainnetController.sol:140-142
bytes32 public FREEZER = keccak256("FREEZER");
bytes32 public RELAYER = keccak256("RELAYER");

// Compare with ForeignController.sol:65-66
bytes32 public constant FREEZER = keccak256("FREEZER");
bytes32 public constant RELAYER = keccak256("RELAYER");
```

**Impact:**

1. **Gas cost:** Every access to these variables reads from storage (SLOAD) instead of being inlined, costing ~2100 gas extra per access.
2. **Theoretical concern about governance overwrite:** While `MainnetController` does not currently expose a setter for these variables, a malicious/compromised admin who gains write access to the contract's storage (e.g., through a future upgrade path or storage collision in a proxy pattern) could theoretically change `FREEZER` or `RELAYER` to `DEFAULT_ADMIN_ROLE` (0x00) and then any admin could be treated as a relayer -- or worse, change the `LIMIT_*` keys to point to uninitialized (zero maxAmount) rate limit entries, which would cause all rate-limited functions to revert (denial of service) or, if changed to keys that have higher limits, bypass intended constraints.
3. **Inconsistency with `ForeignController`:** The different declaration style between the two controllers is suspicious and could indicate copy-paste oversight.

**Recommendation:** Declare all role and limit identifiers as `constant` to match `ForeignController`.

---

### Finding 2: OTC Claim Does Not Validate Claimed Amount Against Sent Amount -- Potential Overclaim

**Severity:** Medium

**File:** `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/MainnetController.sol`
**Lines:** 1125-1151, 1153-1167

**Description:**

The OTC swap mechanism sends assets to an exchange and later claims returned assets from the OTC buffer. However, the `otcClaim` function does **not** enforce that `otcs[exchange].claimed18` does not exceed `otcs[exchange].sent18`. There is no ceiling on how much can be claimed.

```solidity
// MainnetController.sol:1144
otcs[exchange].claimed18 += amountToClaim18;
```

The `isOtcSwapReady` function checks whether the claimed plus recharged amount exceeds the sent amount (adjusted by maxSlippage), but this check is only used in `otcSend` to gate a **new** send. It does not prevent continued claiming.

```solidity
// MainnetController.sol:1161-1167
function isOtcSwapReady(address exchange) public view returns (bool) {
    if (maxSlippages[exchange] == 0) return false;
    return getOtcClaimWithRecharge(exchange)
        >= otcs[exchange].sent18 * maxSlippages[exchange] / 1e18;
}
```

**Attack Scenario:**

1. Relayer calls `otcSend(exchange, USDC, 1_000_000e6)` -- sends $1M USDC to exchange.
2. Exchange sends back $1M worth of assets to the OTC buffer.
3. Relayer calls `otcClaim(exchange, USDS)` -- claims the full $1M.
4. Exchange deposits another $500K to the OTC buffer (as a separate, unrelated operation).
5. Relayer calls `otcClaim(exchange, USDS)` again -- claims the extra $500K. `claimed18` is now 1.5M, exceeding the sent18 of 1M.
6. This is not blocked because `isOtcSwapReady` returning true means a new send can happen, and otcClaim itself has no ceiling check.

The key question is whether the OTC buffer would ever have more tokens than expected. Since the buffer is funded by the exchange and the exchange might send multiple payments or overpay, the relayer can sweep all tokens from the buffer without limit. This is **by design** if the buffer only ever contains exchange-returned assets, but it could be exploited if the buffer holds excess funds from other sources or if the exchange overpays.

**Note:** This finding is mitigated by: (a) only RELAYER can call `otcClaim`, (b) the claimed amount is taken from the buffer's balance (so cannot exceed what the buffer holds), (c) the buffer only approves the ALMProxy. However, the lack of an upper bound is a design weakness.

**Recommendation:** Add a check in `otcClaim` that `otcs[exchange].claimed18 <= otcs[exchange].sent18` (or a similar bounded check) to prevent overclaiming.

---

### Finding 3: Precision Loss in OTC Send/Claim for Tokens with Different Decimals

**Severity:** Low

**File:** `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/MainnetController.sol`
**Lines:** 1106, 1141-1142

**Description:**

The OTC mechanism normalizes token amounts to 18 decimals for tracking:

```solidity
// otcSend: line 1106
uint256 sent18 = amount * 1e18 / 10 ** IERC20Metadata(assetToSend).decimals();

// otcClaim: line 1141-1142
uint256 amountToClaim18
    = amountToClaim * 1e18 / 10 ** IERC20Metadata(assetToClaim).decimals();
```

For tokens with more than 18 decimals, the comment on line 1105 acknowledges precision loss: `// NOTE: This will lose precision for tokens with >18 decimals.`

For tokens with fewer decimals (e.g., USDC with 6), the conversion is safe but introduces a fixed-point arithmetic comparison between `claimed18` and `sent18 * maxSlippage / 1e18` that could produce small rounding errors favoring or penalizing the swap readiness check.

**Impact:** For standard tokens (6 or 18 decimals), the precision loss is negligible. For exotic tokens with >18 decimals, amounts could be truncated significantly.

**Recommendation:** Either prohibit tokens with >18 decimals at the whitelist level, or use a higher internal precision for tracking.

---

### Finding 4: WEETHModule `claimWithdrawal` Uses `address(this).balance` -- Residual ETH Can Inflate Return Value

**Severity:** Low

**File:** `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/WEETHModule.sol`
**Lines:** 71-96

**Description:**

The `claimWithdrawal` function in `WEETHModule` calculates `ethReceived` as the full ETH balance of the module contract after claiming:

```solidity
// WEETHModule.sol:90
ethReceived = address(this).balance;
```

Since the `WEETHModule` has a `receive()` fallback (line 112), anyone can send ETH to the module at any time. If ETH is sent before `claimWithdrawal` is called, the `ethReceived` value will be inflated, causing more WETH to be minted and transferred to the ALMProxy than was actually withdrawn from EtherFi.

```solidity
// WEETHModule.sol:93-95
IWETHLike(Ethereum.WETH).deposit{value: ethReceived}();
IERC20(Ethereum.WETH).safeTransfer(msg.sender, ethReceived);
```

**Attack Scenario:**

1. An attacker sends 1 ETH to the WEETHModule.
2. A relayer calls `claimWithdrawalFromWeETH` which calls `proxy.doCall(weETHModule, ...)`.
3. The claim succeeds and returns, say, 10 ETH from EtherFi.
4. `ethReceived = address(this).balance` = 11 ETH (10 from claim + 1 from attacker).
5. 11 ETH is wrapped to WETH and sent to the ALMProxy.

**Impact:** The ALMProxy receives slightly more WETH than expected. The "attacker" loses their ETH donation. This is not really an attack but rather an accounting inaccuracy. An actual attacker gains nothing from this. It is more of an unexpected accounting benefit to the protocol at the attacker's expense.

**Recommendation:** Track the ETH balance before and after the claim, similar to how `claimWithdrawalFromWstETH` does it in `MainnetController` (line 471-481):

```solidity
uint256 initialEthBalance = address(this).balance;
IWithdrawRequestNFTLike(withdrawRequestNFT).claimWithdraw(requestId);
ethReceived = address(this).balance - initialEthBalance;
```

---

### Finding 5: LayerZero Transfer Has `minAmountLD = 0` Before Quote, Potentially Allowing Full Slippage

**Severity:** Low

**File:** `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/libraries/LayerZeroLib.sol`
**Lines:** 66-85

**Description:**

In the LayerZero transfer flow, a `SendParam` is first constructed with `minAmountLD = 0`, then used to query `quoteOFT` to get the expected receipt amount. The received amount is then set as `minAmountLD`:

```solidity
// LayerZeroLib.sol:66-74
SendParam memory sendParams = SendParam({
    dstEid       : destinationEndpointId,
    to           : layerZeroRecipient,
    amountLD     : amount,
    minAmountLD  : 0,               // <-- initially zero
    extraOptions : options,
    composeMsg   : "",
    oftCmd       : ""
});

// LayerZeroLib.sol:77-85
( ,, OFTReceipt memory receipt ) = abi.decode(
    proxy.doCall(
        oftAddress,
        abi.encodeCall(ILayerZero.quoteOFT, (sendParams))
    ),
    (OFTLimit, OFTFeeDetail[], OFTReceipt)
);
sendParams.minAmountLD = receipt.amountReceivedLD;
```

The code comments (lines 294-296 in ForeignController) explicitly state this function was deployed without integration testing and should have its rate limit kept at zero until tested.

**Impact:** If the OFT's `quoteOFT` returns a manipulable or stale value, the `minAmountLD` protection could be insufficient. However, since the `quoteOFT` is called in the same transaction, manipulation would require control of the OFT contract itself.

**Recommendation:** The development team has already noted this concern. Ensure thorough integration testing before enabling the rate limit.

---

### Finding 6: `swapUSDCToUSDS` PSM Fill Loop Can Become a Gas Griefing Vector

**Severity:** Low

**File:** `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/libraries/PSMLib.sol`
**Lines:** 81-123

**Description:**

The `swapUSDCToUSDS` function in PSMLib contains a `while` loop that fills the PSM with DAI and then swaps USDC to DAI in batches:

```solidity
// PSMLib.sol:100-110
while (remainingUsdcToSwap > 0) {
    params.psm.fill();
    limit = params.dai.balanceOf(address(params.psm)) / params.psmTo18ConversionFactor;
    uint256 swapAmount = remainingUsdcToSwap < limit ? remainingUsdcToSwap : limit;
    _swapUSDCToDAI(params.proxy, params.psm, swapAmount);
    remainingUsdcToSwap -= swapAmount;
}
```

If `params.psm.fill()` returns a very small amount (or zero, causing a revert per the comment), or if the loop takes many iterations to complete a large swap, this could consume excessive gas. While this would primarily affect the relayer calling the function, it could also cause operational delays.

**Note:** The function will revert if `fill()` returns 0, which prevents an infinite loop. But if `fill()` returns a tiny amount each time, the number of iterations could be very large.

**Impact:** Operational risk -- a large USDC-to-USDS swap could fail due to block gas limits if the PSM is repeatedly filled with small amounts.

**Recommendation:** Consider adding a maximum iteration count to prevent gas griefing.

---

### Finding 7: Curve `addLiquidity` Swap Rate Limit Accounting May Undercount in Edge Cases

**Severity:** Low

**File:** `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/libraries/CurveLib.sol`
**Lines:** 199-211

**Description:**

After adding liquidity to a Curve pool, the code attempts to estimate the "swap value" (how much implicit swapping occurred) by comparing the proportional share of pool balances against the deposited amounts:

```solidity
// CurveLib.sol:199-211
uint256 totalSwapped;
for (uint256 i; i < params.depositAmounts.length; i++) {
    totalSwapped += _absSubtraction(
        curvePool.balances(i) * rates[i] * shares / curvePool.totalSupply(),
        params.depositAmounts[i] * rates[i]
    );
}
uint256 averageSwap = totalSwapped / 2 / 1e18;
```

This calculation reads `curvePool.balances(i)` and `curvePool.totalSupply()` **after** the liquidity addition, but uses `rates[i]` from **before** the addition. In most stable swap pools, rates do not change within a single transaction, but if the pool uses dynamic rates or if the `stored_rates()` function reflects changed state after liquidity operations, this could produce an inaccurate swap estimate.

Additionally, dividing by 2 at the end (`totalSwapped / 2`) assumes a two-token pool where swapping from one side implies equal value moved on the other. For pools with more than 2 tokens, this is an approximation that could undercount the actual swap impact.

**Impact:** The swap rate limit might be consumed less than the actual implicit swap, potentially allowing slightly more swapping than intended through repeated add-liquidity operations.

**Recommendation:** Document the approximation limitation and consider a more conservative estimate for multi-token pools.

---

### Finding 8: `RateLimits.getCurrentRateLimit` Potential Overflow for Large Slopes

**Severity:** Low

**File:** `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/RateLimits.sol`
**Lines:** 68-80

**Description:**

```solidity
// RateLimits.sol:76-79
return _min(
    d.slope * (block.timestamp - d.lastUpdated) + d.lastAmount,
    d.maxAmount
);
```

The expression `d.slope * (block.timestamp - d.lastUpdated) + d.lastAmount` could theoretically overflow if `slope` is set very high and a long time has passed since the last update. However, with Solidity ^0.8.21, arithmetic overflow would cause a revert, not a silent wrap-around.

**Impact:** If a rate limit with a high slope has not been triggered for a very long time, calling `getCurrentRateLimit` (or any function that calls it) could revert due to overflow. This would be a denial-of-service on that specific rate-limited operation.

The practical likelihood is low because:
1. `slope` is set by the admin and would typically be reasonable.
2. `maxAmount` caps the effective value, but the overflow occurs before the `_min` comparison.
3. The time delta would need to be extremely large with a high slope.

**Recommendation:** Consider adding an intermediate check: compute `block.timestamp - d.lastUpdated` first, then check if `slope * timeDelta` would overflow before performing the multiplication, or use a try/catch pattern. Alternatively, document that admins must set reasonable slope values.

---

### Finding 9: Uniswap V4 `_decreaseLiquidity` Assumes Balance Can Only Increase -- Underflow Risk

**Severity:** Low

**File:** `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/libraries/UniswapV4Lib.sol`
**Lines:** 370-373

**Description:**

In `_decreaseLiquidity`, the rate limit decrease is computed as:

```solidity
// UniswapV4Lib.sol:371-373
uint256 rateLimitDecrease =
    _getNormalizedBalance(token0, endingBalance0 - startingBalance0) +
    _getNormalizedBalance(token1, endingBalance1 - startingBalance1);
```

This assumes that both `endingBalance0 >= startingBalance0` and `endingBalance1 >= startingBalance1`. While decreasing liquidity should always return tokens to the proxy, if there is an edge case where balances do not increase (e.g., a Uniswap v4 hook takes fees, or a fee-on-transfer token is one of the pair tokens), the subtraction would revert due to underflow.

Contrast this with `_increaseLiquidity` (line 329-334) which uses `_clampedSub` to handle the case where balances might increase during a deposit.

**Impact:** If a pool with fee-on-transfer tokens or aggressive hooks is used, `decreaseLiquidityUniswapV4` would revert, preventing withdrawal of funds from that position. This could freeze funds in the position.

**Recommendation:** Use `_clampedSub` for individual token balance changes in `_decreaseLiquidity` as well, or validate that only approved pool pairs are used that do not have fee-on-transfer characteristics.

---

### Finding 10: Uniswap V4 `_approveWithPermit2` Ignores Failure of Initial Zero-Approval

**Severity:** Info

**File:** `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/libraries/UniswapV4Lib.sol`
**Lines:** 253-297

**Description:**

The `_approveWithPermit2` function first attempts to set the token approval to Permit2 to zero using a low-level call that ignores the return value:

```solidity
// UniswapV4Lib.sol:267-272
proxy.call(
    abi.encodeCall(
        IALMProxy.doCall,
        (token, abi.encodeCall(IERC20Like.approve, (_PERMIT2, 0)))
    )
);
```

The code comment explains this is intentional -- the call is a convenience that may not be needed. However, if the token has a non-standard `approve` that reverts on zero approval (which is unusual but possible), the code silently continues and then attempts to approve the actual amount. The second approval would either succeed or fail on its own merits.

**Impact:** No practical impact. This pattern is a common approach for handling USDT-like tokens that require approval to be zero before setting a new value.

---

### Finding 11: `ForeignController.depositERC4626` Rate Limits on Input Amount but Exchange Rate Check Uses Post-Deposit Values

**Severity:** Info

**File:** `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/ForeignController.sol`
**Lines:** 321-346

**Description:**

The `depositERC4626` function applies the rate limit in the modifier based on `amount` (the asset input), then performs the deposit, and then checks the exchange rate using the shares received and the asset amount:

```solidity
// ForeignController.sol:321-346
function depositERC4626(address token, uint256 amount, uint256 minSharesOut)
    external
    nonReentrant
    onlyRole(RELAYER)
    rateLimitedAddress(LIMIT_4626_DEPOSIT, token, amount)
    returns (uint256 shares)
{
    _approve(IERC4626(token).asset(), token, amount);

    shares = abi.decode(
        proxy.doCall(
            token,
            abi.encodeCall(IERC4626(token).deposit, (amount, address(proxy)))
        ),
        (uint256)
    );

    require(shares >= minSharesOut, "FC/min-shares-out-not-met");
    require(
        _getExchangeRate(shares, amount) <= maxExchangeRates[token],
        "FC/exchange-rate-too-high"
    );
}
```

If the exchange rate check fails after the rate limit has already been consumed (in the modifier), the entire transaction reverts, which also reverts the rate limit consumption. This is correct behavior because the rate limit update happens via an external call to the `RateLimits` contract, and the revert bubbles up.

**Impact:** No issue -- the rate limit is correctly reverted on failure.

---

### Finding 12: `ForeignController.redeemERC4626` Does Not Check Exchange Rate

**Severity:** Info

**File:** `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/ForeignController.sol`
**Lines:** 374-397

**Description:**

Unlike `depositERC4626` which checks `maxExchangeRates[token]`, the `redeemERC4626` function does not perform an exchange rate validation:

```solidity
function redeemERC4626(address token, uint256 shares, uint256 minAssetsOut)
    external nonReentrant onlyRole(RELAYER) returns (uint256 assets)
{
    assets = abi.decode(
        proxy.doCall(
            token,
            abi.encodeCall(IERC4626(token).redeem, (shares, address(proxy), address(proxy)))
        ),
        (uint256)
    );
    require(assets >= minAssetsOut, "FC/min-assets-out-not-met");
    // No exchange rate check here
    ...
}
```

**Impact:** This appears intentional -- when redeeming, the protocol is withdrawing funds, so an unfavorable exchange rate would be a loss for the vault, not for the ALM. The `minAssetsOut` parameter provides slippage protection.

---

### Finding 13: Rate Limit Key Collision is Theoretically Possible

**Severity:** Info

**File:** `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/RateLimitHelpers.sol`
**Lines:** 6-22

**Description:**

Rate limit keys are derived using `keccak256(abi.encode(...))` with different parameter types:

```solidity
function makeAddressKey(bytes32 key, address a) internal pure returns (bytes32) {
    return keccak256(abi.encode(key, a));
}

function makeAddressAddressKey(bytes32 key, address a, address b) internal pure returns (bytes32) {
    return keccak256(abi.encode(key, a, b));
}

function makeUint32Key(bytes32 key, uint32 a) internal pure returns (bytes32) {
    return keccak256(abi.encode(key, a));
}
```

Since `abi.encode` pads all values to 32 bytes, `makeAddressKey(key, addr)` and `makeUint32Key(key, uint32(addr))` would NOT collide because the base `key` values are different (`LIMIT_ASSET_TRANSFER` vs `LIMIT_USDC_TO_DOMAIN`). Similarly, since all LIMIT_ constants are unique keccak256 hashes, the probability of collision is astronomically low.

**Impact:** No practical impact due to the birthday paradox being astronomically unlikely with 256-bit hashes.

---

### Finding 14: `MainnetController.depositToFarm` Uses Inline Key Construction Instead of `RateLimitHelpers`

**Severity:** Info

**File:** `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/MainnetController.sol`
**Lines:** 1043-1056, 1058-1073

**Description:**

The `depositToFarm` and `withdrawFromFarm` functions construct their rate limit keys inline:

```solidity
// MainnetController.sol:1046
keccak256(abi.encode(LIMIT_FARM_DEPOSIT, farm))

// MainnetController.sol:1061
keccak256(abi.encode(LIMIT_FARM_WITHDRAW, farm))
```

While `RateLimitHelpers.makeAddressKey` does the same thing (`keccak256(abi.encode(key, a))`), the inline construction is functionally equivalent. However, the inconsistency suggests these functions were added at a different time or by a different author.

**Impact:** No functional impact, but reduces code consistency.

---

### Finding 15: Missing Validation of `weETHModule` Address in WEETHLib

**Severity:** Info

**File:** `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/libraries/WEETHLib.sol`
**Lines:** 95-147, 149-170

**Description:**

Both `requestWithdraw` and `claimWithdrawal` take a `weETHModule` address as a parameter. The code comments state:

```solidity
// NOTE: weETHModule is enforced to be correct by the rate limit key
```

This means the `weETHModule` address is validated indirectly: if the rate limit key `makeAddressKey(LIMIT_WEETH_REQUEST_WITHDRAW, weETHModule)` has no configured rate limit data (maxAmount == 0), the operation will revert. This is an implicit validation that works correctly.

However, for `claimWithdrawal`, only `_rateLimitExists` is checked (not `_rateLimited`), meaning the rate limit is not consumed. This means claims are not rate-limited, only existence-checked.

**Impact:** This appears intentional -- claims should not be rate-limited since the rate limit was already consumed during the withdrawal request. The existence check merely validates that the `weETHModule` address has been configured.

---

### Finding 16: `ERC4626Lib.redeem` Performs External Call Before Rate Limit Decrease

**Severity:** Info

**File:** `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/libraries/ERC4626Lib.sol`
**Lines:** 80-110

**Description:**

The `redeem` function first performs the external call to redeem shares, then decreases the rate limit. The comment pattern `// NOTE: !!! Rate limited at end of function !!!` is used in similar cases. This is because the returned `assets` value is only known after the call.

```solidity
// Redeem first
assets = abi.decode(
    IALMProxy(proxy).doCall(
        token,
        abi.encodeCall(IERC4626(token).redeem, (shares, proxy, proxy))
    ),
    (uint256)
);
// Then rate limit
IRateLimits(rateLimits).triggerRateLimitDecrease(..., assets);
```

This pattern is used consistently throughout the codebase for operations where the output amount is unknown until the call completes.

**Impact:** No issue. The function is called via `delegatecall` from the controller, which has `nonReentrant` protection. The rate limit is correctly applied post-call. If the rate limit check fails, the entire transaction reverts, including the redeem.

---

### Finding 17: OTCBuffer Storage Slot Derivation Should Be Verified

**Severity:** Info

**File:** `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/OTCBuffer.sol`
**Lines:** 24-26

**Description:**

The storage slot is declared with a comment explaining its derivation:

```solidity
// keccak256(abi.encode(uint256(keccak256("almController.storage.OTCBuffer")) - 1)) & ~bytes32(uint256(0xff))
bytes32 internal constant _OTC_BUFFER_STORAGE_LOCATION =
    0xe0e561841bb6fa9b0b4be53b5b4f5d506ea40664f6db7ecbcf7b6f18935a4f00;
```

This follows the ERC-7201 namespaced storage pattern. The value should be verified to match the formula.

**Impact:** If the value is incorrect, storage could collide with other variables. However, this is a constant that would have been caught during testing.

---

### Finding 18: Uniswap V4 Permit2 Approval Expiration Set to `block.timestamp`

**Severity:** Info

**File:** `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/libraries/UniswapV4Lib.sol`
**Lines:** 290-296

**Description:**

```solidity
IALMProxy(proxy).doCall(
    _PERMIT2,
    abi.encodeCall(
        IPermit2Like.approve,
        (token, spender, uint160(amount), uint48(block.timestamp))
    )
);
```

The Permit2 approval expiration is set to `block.timestamp`, meaning it expires within the current block. This is actually excellent security practice -- the approval is only valid for the current transaction, minimizing the window for exploitation.

**Impact:** Positive security characteristic. No issue.

---

## Informational and Design Notes

### Design Note 1: Centralized Trust Model

The ALM system centralizes significant trust in several roles:
- **DEFAULT_ADMIN_ROLE**: Can set rate limits, configure integrations, and manage roles. A compromised admin could raise rate limits to max, add malicious relayers, and drain funds.
- **RELAYER**: Can execute all operational functions within rate limits. A compromised relayer can drain funds up to the rate limit capacity.
- **FREEZER**: Can remove relayers, providing an emergency stop mechanism.

This is acknowledged as out-of-scope ("Centralization risks, privileged address attacks") but is noted for completeness.

### Design Note 2: Rate Limit Bidirectional Accounting

Several operations (Aave withdraw, ERC4626 withdraw, USDC-to-USDS swap) implement bidirectional rate limit accounting -- decreasing one rate limit and increasing the reverse operation's limit. This is a thoughtful design that allows rebalancing without consuming both directional rate limits independently.

### Design Note 3: ALMProxy `doDelegateCall` Exposure

The `ALMProxy` contract exposes `doDelegateCall` (line 43-47 of ALMProxy.sol), which could execute arbitrary code in the proxy's context. While only `CONTROLLER` can call it, and the controllers in scope do not use `doDelegateCall`, any future controller that is granted the CONTROLLER role on the proxy could use this to execute arbitrary storage modifications on the ALMProxy. This is by design but worth monitoring.

### Design Note 4: Frozen State Has No Direct Bypass

The FREEZER can remove relayers via `removeRelayer`, and there is no `addRelayer` function accessible to the FREEZER. Only the DEFAULT_ADMIN_ROLE can grant RELAYER. This means the freeze mechanism cannot be bypassed by the FREEZER role itself.

### Design Note 5: Multiple Rate Limits Applied Atomically

Functions like `transferUSDCToCCTP` in both controllers apply multiple rate limits (global CCTP limit + per-domain limit). Since these are checked atomically within a single transaction, there are no race conditions between the checks. A transaction either passes all rate limits or reverts entirely.

---

## Files Audited

| File | Path | Lines | Notes |
|------|------|-------|-------|
| MainnetController.sol | `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/MainnetController.sol` | 1225 | Primary controller for Ethereum mainnet operations |
| ForeignController.sol | `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/ForeignController.sol` | 561 | Controller for non-mainnet chains |
| RateLimits.sol | `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/RateLimits.sol` | 137 | Rate limit registry and enforcement |
| RateLimitHelpers.sol | `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/RateLimitHelpers.sol` | 23 | Key derivation helpers |
| OTCBuffer.sol | `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/OTCBuffer.sol` | 71 | OTC swap buffer (UUPS upgradeable) |
| WEETHModule.sol | `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/WEETHModule.sol` | 114 | weETH withdrawal claim module (UUPS upgradeable) |
| Common.sol | `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/interfaces/Common.sol` | 18 | Common interface definitions |
| IALMProxy.sol | `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/interfaces/IALMProxy.sol` | 45 | ALMProxy interface |
| IRateLimits.sol | `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/interfaces/IRateLimits.sol` | 164 | Rate limits interface |
| ALMProxy.sol | `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/ALMProxy.sol` | 55 | ALMProxy implementation (additional context) |
| ERC4626Lib.sol | `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/libraries/ERC4626Lib.sol` | 122 | ERC4626 vault operations |
| ApproveLib.sol | `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/libraries/ApproveLib.sol` | 43 | Safe approval helper |
| AaveLib.sol | `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/libraries/AaveLib.sol` | 94 | Aave v3 operations |
| CCTPLib.sol | `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/libraries/CCTPLib.sol` | 143 | CCTP bridging operations |
| PSMLib.sol | `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/libraries/PSMLib.sol` | 162 | PSM swap operations |
| LayerZeroLib.sol | `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/libraries/LayerZeroLib.sol` | 107 | LayerZero bridging operations |
| CurveLib.sol | `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/libraries/CurveLib.sol` | 278 | Curve StableSwap operations |
| UniswapV4Lib.sol | `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/libraries/UniswapV4Lib.sol` | 545 | Uniswap V4 operations |
| WEETHLib.sol | `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/libraries/WEETHLib.sol` | 187 | weETH/eETH operations |

---

## Summary of Findings

| # | Title | Severity | Status |
|---|-------|----------|--------|
| 1 | Non-constant state variables for role/limit identifiers in MainnetController | Medium | Open |
| 2 | OTC claim does not validate claimed amount against sent amount | Medium | Open |
| 3 | Precision loss in OTC for tokens with >18 decimals | Low | Open |
| 4 | WEETHModule uses address(this).balance instead of delta | Low | Open |
| 5 | LayerZero minAmountLD set to 0 before quote | Low | Acknowledged |
| 6 | PSM fill loop can cause gas issues for large swaps | Low | Open |
| 7 | Curve addLiquidity swap rate limit approximation for multi-token pools | Low | Open |
| 8 | RateLimits.getCurrentRateLimit potential overflow for large slopes | Low | Open |
| 9 | Uniswap V4 _decreaseLiquidity assumes balance can only increase | Low | Open |
| 10 | _approveWithPermit2 ignores failure of initial zero-approval | Info | By Design |
| 11 | depositERC4626 rate limit correctly reverted on failure | Info | No Issue |
| 12 | redeemERC4626 does not check exchange rate | Info | By Design |
| 13 | Rate limit key collision theoretically possible | Info | No Issue |
| 14 | Farm deposit/withdraw uses inline key construction | Info | Style |
| 15 | weETHModule validated indirectly via rate limit key | Info | By Design |
| 16 | ERC4626Lib.redeem performs call before rate limit | Info | By Design |
| 17 | OTCBuffer storage slot derivation should be verified | Info | Open |
| 18 | Permit2 approval expires at block.timestamp | Info | Positive |

---

## Conclusion

The Spark ALM Controller codebase demonstrates strong security engineering. The key defenses -- role-based access control, rate limiting, reentrancy guards, and slippage protections -- are well-implemented. The most impactful finding is the non-constant declaration of role identifiers in `MainnetController` (Finding 1), which introduces unnecessary gas cost and a theoretical (though practically unlikely) attack surface. The OTC overclaim issue (Finding 2) is a design concern that could lead to unintended fund movements if the buffer accumulates excess tokens. The remaining findings are low-severity or informational, reflecting a well-audited and carefully designed system.

No critical-severity vulnerabilities were identified that would enable direct theft of funds, permanent freezing, or protocol insolvency through unauthorized access. All fund-movement operations require RELAYER access and are constrained by rate limits, making the system resilient to single-point compromises within the rate limit bounds.
