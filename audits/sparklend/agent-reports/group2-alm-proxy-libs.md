# Security Audit Report: ALM Proxy + Integration Libraries

**Scope:** ALMProxy, ALMProxyFreezable, and all integration libraries (Aave, Approve, CCTP, Curve, ERC4626, LayerZero, PSM, UniswapV4, WEETH) plus related interfaces.

**Auditor:** Smart Contract Security Auditor
**Date:** 2026-03-01
**Protocol:** Spark (SparkLend) ALM Controller
**Bounty Program:** Immunefi ($5M max, Primacy of Impact)

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Architecture Overview](#architecture-overview)
3. [Detailed Findings](#detailed-findings)
4. [File-by-File Analysis](#file-by-file-analysis)
5. [Conclusion](#conclusion)

---

## Executive Summary

The ALM Proxy and integration libraries implement a multi-protocol treasury management system. The `ALMProxy` acts as a smart-contract wallet controlled by designated CONTROLLER roles. The various library contracts (AaveLib, CurveLib, PSMLib, etc.) are called via `delegatecall` from the MainnetController/ForeignController, meaning they execute in the controller's storage context and interact with the proxy through external `doCall` invocations.

The codebase demonstrates strong defensive design patterns:
- All controller functions are gated by `onlyRole(RELAYER)` + `nonReentrant`
- Rate limiting is applied to virtually all fund movements
- Slippage protections are enforced with admin-configurable `maxSlippage` parameters
- Approvals follow safe patterns (forceApprove-style for non-standard tokens)
- The proxy itself restricts callers to CONTROLLER role holders

After comprehensive line-by-line analysis, I identified several observations ranging from informational design notes to medium-severity concerns. No critical "direct theft of funds" vulnerability was found that would bypass the existing access control + rate limit architecture under normal operating conditions.

---

## Architecture Overview

```
Admin (Governance)
  |
  v
MainnetController / ForeignController  [AccessControl + ReentrancyGuard]
  |  (has CONTROLLER role on ALMProxy)
  |  (uses library functions via internal Solidity library calls)
  |
  v
ALMProxy  [AccessControl]
  |  (doCall / doCallWithValue / doDelegateCall)
  |
  v
External Protocols: Aave, Curve, PSM, ERC4626, UniswapV4, CCTP, LayerZero, WEETH
```

Key design: Libraries are called as Solidity library functions (not via delegatecall at the EVM level) from the controllers. They interact with external protocols by calling `proxy.doCall(target, data)` which makes the proxy execute the call to the external protocol.

---

## Detailed Findings

### Finding 1: ALMProxy `doDelegateCall` Exposes Arbitrary Storage Manipulation

**Severity:** Medium (mitigated by access control, but design risk remains)

**File:** `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/ALMProxy.sol`, lines 43-47

**Code:**
```solidity
function doDelegateCall(address target, bytes memory data)
    external override onlyRole(CONTROLLER) returns (bytes memory result)
{
    result = target.functionDelegateCall(data);
}
```

**Description:**
The `doDelegateCall` function allows any CONTROLLER to execute arbitrary code in the context of the ALMProxy's storage. This means a CONTROLLER can:
1. Overwrite the proxy's AccessControl storage slots (e.g., grant themselves DEFAULT_ADMIN_ROLE)
2. Modify any storage slot in the proxy
3. Self-destruct the proxy (though this is less of a concern post-Dencun)

While `doDelegateCall` is never called from the current MainnetController or ForeignController code, any address with the CONTROLLER role can invoke it directly on the proxy. If a CONTROLLER key is compromised or a malicious upgrade occurs that grants CONTROLLER to an unintended address, this function could be exploited to bypass all access controls.

**Impact Assessment:**
- If a CONTROLLER account is compromised, the attacker could use `doDelegateCall` to overwrite the proxy's role mappings, grant themselves admin, and drain all funds held by the proxy.
- Under the current design where CONTROLLER is only held by trusted, governance-deployed controller contracts, the risk is significantly mitigated.
- However, the existence of this function means the security of ALL proxy funds depends entirely on the integrity of every CONTROLLER role holder.

**Recommendation:**
Consider removing `doDelegateCall` if it is not needed. If it is needed for future upgrades, consider adding an additional admin-only allowlist of targets that can be delegate-called.

---

### Finding 2: PSMLib `swapUSDCToUSDS` Potential Infinite Loop / DoS

**Severity:** Low

**File:** `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/libraries/PSMLib.sol`, lines 92-110

**Code:**
```solidity
while (remainingUsdcToSwap > 0) {
    params.psm.fill();

    limit = params.dai.balanceOf(address(params.psm)) / params.psmTo18ConversionFactor;

    uint256 swapAmount = remainingUsdcToSwap < limit ? remainingUsdcToSwap : limit;

    _swapUSDCToDAI(params.proxy, params.psm, swapAmount);

    remainingUsdcToSwap -= swapAmount;
}
```

**Description:**
If `params.psm.fill()` is called but produces zero or very little DAI (e.g., the PSM's DAI cap is reached), `limit` could be 0, making `swapAmount` also 0. The loop condition `remainingUsdcToSwap > 0` would still be true, but `remainingUsdcToSwap -= 0` makes no progress, creating an infinite loop that consumes all gas.

The code comment states: "If the PSM cannot be filled with the full amount, psm.fill() will revert with `DssLitePsm/nothing-to-fill`." This relies on the PSM's specific behavior to revert -- if the PSM's `fill()` succeeds but returns very little DAI (e.g., dust amounts), the loop could iterate many times, hitting the gas limit.

**Impact Assessment:**
- DoS of the `swapUSDCToUSDS` function under edge-case PSM conditions
- No direct fund loss, but could prevent timely rebalancing operations

**Recommendation:**
Add a check that `swapAmount > 0` or that `limit > 0` after `fill()`, with an explicit revert if not:
```solidity
require(limit > 0, "MC/psm-fill-insufficient");
```

---

### Finding 3: UniswapV4Lib Permit2 Approval Expiration Set to `block.timestamp`

**Severity:** Low

**File:** `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/libraries/UniswapV4Lib.sol`, lines 289-296

**Code:**
```solidity
IALMProxy(proxy).doCall(
    _PERMIT2,
    abi.encodeCall(
        IPermit2Like.approve,
        (token, spender, uint160(amount), uint48(block.timestamp))
    )
);
```

**Description:**
The Permit2 approval expiration is set to `uint48(block.timestamp)`. This means the approval expires at the exact current block timestamp. In Uniswap V4's Permit2, the check is typically `block.timestamp <= expiration`, so this should work for the current transaction. However, this is a very tight window:
- If the approval is done in a prior call and the actual spend happens in a later call within the same function, it works because `block.timestamp` is constant within a transaction.
- The current code properly approves and uses within the same transaction, so this is safe.

**Impact Assessment:**
- No immediate impact as approvals are used and revoked within the same transaction.
- However, if the code flow ever changes to use approvals across transactions, the tight expiration would break.

**Recommendation:**
This is acceptable for the current design. No change needed, but document that approvals must be consumed in the same transaction.

---

### Finding 4: UniswapV4Lib `_approveWithPermit2` Ignores Return Value of Reset Call

**Severity:** Informational

**File:** `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/libraries/UniswapV4Lib.sol`, lines 267-272

**Code:**
```solidity
// Approve the Permit2 contract to spend none of the token (success is optional).
proxy.call(
    abi.encodeCall(
        IALMProxy.doCall,
        (token, abi.encodeCall(IERC20Like.approve, (_PERMIT2, 0)))
    )
);
```

**Description:**
The low-level `proxy.call(...)` is used (instead of `IALMProxy(proxy).doCall(...)`) to reset the Permit2 allowance. The return value is intentionally ignored. The code comment explains this is intentional -- it is a convenience reset that may not be needed. This is safe because:
1. If the approval reset fails, the subsequent approval to a non-zero amount will still work for standard ERC20 tokens.
2. For tokens like USDT that require approving to 0 first, this approach correctly handles the case by attempting the zero-approval first.

**Impact Assessment:**
- No impact. The pattern is intentionally defensive and correctly handles both standard and non-standard ERC20 tokens.

---

### Finding 5: CurveLib `addLiquidity` Post-Swap Rate Limit Calculation Relies on Stale `balances` and `totalSupply`

**Severity:** Low

**File:** `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/libraries/CurveLib.sol`, lines 199-211

**Code:**
```solidity
uint256 totalSwapped;
for (uint256 i; i < params.depositAmounts.length; i++) {
    totalSwapped += _absSubtraction(
        curvePool.balances(i) * rates[i] * shares / curvePool.totalSupply(),
        params.depositAmounts[i] * rates[i]
    );
}
uint256 averageSwap = totalSwapped / 2 / 1e18;

params.rateLimits.triggerRateLimitDecrease(
    RateLimitHelpers.makeAddressKey(params.swapRateLimitId, params.pool),
    averageSwap
);
```

**Description:**
After the `add_liquidity` call, the code reads `curvePool.balances(i)` and `curvePool.totalSupply()` to calculate how much implicit swapping occurred. These values reflect the post-deposit state. The `rates` array, however, was fetched before the deposit via `curvePool.stored_rates()`. If the deposit significantly changes pool composition, the `stored_rates` might be slightly stale. For stable pools, this difference is negligible, but for pools with rebasing tokens, there could be a discrepancy.

**Impact Assessment:**
- The rate limit accounting for implicit swaps may be slightly inaccurate.
- The relayer is trusted, and this is purely a rate limit accounting issue, not a fund-loss vector.
- Exploiting this to bypass rate limits would require a carefully crafted deposit that maximizes the discrepancy, but the overall rate limit framework provides additional bounds.

**Recommendation:**
Consider re-fetching `stored_rates()` after the deposit for the swap calculation, or document this known imprecision.

---

### Finding 6: AaveLib Slippage Check Could Overflow for Very Large Amounts

**Severity:** Informational

**File:** `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/libraries/AaveLib.sol`, lines 53-56

**Code:**
```solidity
require(
    newATokens >= amount * maxSlippage / 1e18,
    "MC/slippage-too-high"
);
```

**Description:**
The multiplication `amount * maxSlippage` could theoretically overflow for very large `amount` values if `maxSlippage` is close to `1e18`. However, since Solidity 0.8.x uses checked arithmetic, this would revert with a panic rather than silently overflowing. Additionally, `amount` is rate-limited, making extreme values impractical.

**Impact Assessment:**
- No practical impact due to rate limits and Solidity 0.8 checked arithmetic.
- If `amount` were close to `type(uint256).max / 1e18`, the call would revert with a panic error, which is different from the expected error message but functionally equivalent (still reverts).

---

### Finding 7: ALMProxyFreezable `removeController` Only Removes -- Cannot Re-Add Without Admin

**Severity:** Informational

**File:** `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/ALMProxyFreezable.sol`, lines 18-21

**Code:**
```solidity
function removeController(address controller) external onlyRole(FREEZER) {
    _revokeRole(CONTROLLER, controller);
    emit ControllerRemoved(controller);
}
```

**Description:**
The FREEZER role can remove controllers but cannot add them back. Re-adding a controller requires the DEFAULT_ADMIN_ROLE (governance). This is an intentional security design -- the freezer is a fast-response emergency mechanism, while governance is required for recovery.

The freeze mechanism is one-directional: FREEZER can only remove, not add. This is correct from a security perspective -- a compromised FREEZER cannot escalate privileges.

**Impact Assessment:**
- No vulnerability. This is a correct and intentional design pattern for emergency response.
- After a freeze, governance must intervene to restore operations.

---

### Finding 8: CCTP Approval Uses Simple `approve` Instead of `forceApprove`

**Severity:** Informational

**File:** `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/libraries/CCTPLib.sol`, lines 95-104

**Code:**
```solidity
// NOTE: As USDC is the only asset transferred using CCTP, _forceApprove logic is unnecessary.
function _approve(
    IALMProxy proxy,
    address   token,
    address   spender,
    uint256   amount
)
    internal
{
    proxy.doCall(token, abi.encodeCall(IERC20.approve, (spender, amount)));
}
```

**Description:**
The CCTP approval uses a simple `approve` instead of the `forceApprove` pattern used in `ApproveLib`. The comment correctly notes that USDC is the only asset used with CCTP, and USDC's `approve` returns `true` and does not require the zero-first pattern. This is safe.

However, if the CCTP approve is called when there is already a non-zero allowance remaining from a previous partial transfer (e.g., if the `depositForBurn` call consumed less than the approved amount), the new `approve` call will simply overwrite it. For USDC, this is safe behavior.

**Impact Assessment:**
- No impact. USDC does not have the USDT-style approve race condition.

---

### Finding 9: LayerZeroLib `minAmountLD` Is Queried but Could Be Manipulated by Malicious OFT

**Severity:** Low (requires malicious OFT, which is admin-configured)

**File:** `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/libraries/LayerZeroLib.sol`, lines 77-85

**Code:**
```solidity
( ,, OFTReceipt memory receipt ) = abi.decode(
    proxy.doCall(
        oftAddress,
        abi.encodeCall(ILayerZero.quoteOFT, (sendParams))
    ),
    (OFTLimit, OFTFeeDetail[], OFTReceipt)
);

sendParams.minAmountLD = receipt.amountReceivedLD;
```

**Description:**
The `minAmountLD` (minimum amount to receive on the destination chain) is set by querying the OFT contract itself via `quoteOFT`. If the `oftAddress` is a malicious contract, it could return a very low `amountReceivedLD`, causing the sender to accept receiving far less than expected. However, the `oftAddress` is passed from the controller, which restricts calls to RELAYER role holders, and the rate limit key includes the `oftAddress`, meaning only admin-configured OFT addresses with rate limits can be used.

**Impact Assessment:**
- The relayer is trusted and the OFT address must have a configured rate limit.
- A malicious relayer could set a bad OFT address, but the relayer is already trusted with fund movements.
- The code comment explicitly warns: "This function was deployed without integration testing. KEEP RATE LIMIT AT ZERO."

---

### Finding 10: CurveLib `coins()` Interface Declared as Non-View

**Severity:** Informational

**File:** `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/libraries/CurveLib.sol`, line 20

**Code:**
```solidity
function coins(uint256 index) external returns (address);
```

**Description:**
The `coins` function in the `ICurvePoolLike` interface is declared without `view` modifier, despite being a read-only function in Curve pools. This means calling `coins()` could theoretically trigger state changes if the target contract has a non-view `coins()` function. In practice, Curve pool contracts implement `coins()` as a pure storage read, so this is harmless but technically imprecise.

More importantly, since `coins()` is called before the actual swap/deposit in CurveLib, and the return value is used to determine which token to approve, a malicious "Curve pool" contract could return different addresses on different calls. However, the pool address is admin-configured, and the controller restricts pools via rate limits.

**Impact Assessment:**
- No practical impact since pool addresses are admin-configured.

---

### Finding 11: WEETHLib `claimWithdrawal` Only Checks Rate Limit Existence, Not Amount

**Severity:** Informational

**File:** `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/libraries/WEETHLib.sol`, lines 149-170

**Code:**
```solidity
function claimWithdrawal(
    IALMProxy   proxy,
    IRateLimits rateLimits,
    address     weETHModule,
    uint256     requestId
)
    external returns (uint256 ethReceived)
{
    // NOTE: weETHModule is enforced to be correct by the rate limit key
    _rateLimitExists(
        rateLimits,
        RateLimitHelpers.makeAddressKey(LIMIT_WEETH_REQUEST_WITHDRAW, weETHModule)
    );

    ethReceived =  abi.decode(
        proxy.doCall(
            weETHModule,
            abi.encodeCall(IWeEthModuleLike(weETHModule).claimWithdrawal, (requestId))
        ),
        (uint256)
    );
}
```

**Description:**
`claimWithdrawal` only checks that a rate limit exists for the `weETHModule` address, not that the claim amount fits within rate limits. This is intentional -- the withdrawal was already rate-limited at request time. Claiming simply finalizes a previously approved withdrawal. The `_rateLimitExists` check serves as validation that the `weETHModule` address is legitimate (admin-configured), not as a fund-movement rate limit.

**Impact Assessment:**
- No vulnerability. The design correctly rate-limits at request time and validates the module address at claim time.

---

### Finding 12: UniswapV4Lib `decreasePosition` Does Not Check Position Ownership

**Severity:** Low (mitigated by design)

**File:** `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/libraries/UniswapV4Lib.sol`, lines 129-164

**Code:**
```solidity
function decreasePosition(
    address proxy,
    address rateLimits,
    bytes32 poolId,
    uint256 tokenId,
    uint128 liquidityDecrease,
    uint128 amount0Min,
    uint128 amount1Min
)
    external
{
    PoolKey memory poolKey = _getPoolKeyFromTokenId(tokenId);

    // NOTE: No need to check the token ownership here, as the proxy will be defined as the
    //       recipient of the tokens, so the worst case is that another account's position is
    //       decreased or closed by the proxy.
    _requirePoolIdMatch(poolId, poolKey);
    ...
```

**Description:**
Unlike `increasePosition` which checks `ownerOf(tokenId) == proxy`, `decreasePosition` intentionally skips ownership validation. The code comment explains the rationale: the proxy is the recipient, so even if it decreases another account's position, the proxy receives the tokens.

However, this means a relayer could trigger the proxy to decrease someone else's Uniswap V4 position if:
1. That position's tokenId is known
2. The poolId matches a configured pool
3. The position manager allows non-owners to decrease (which in standard Uniswap V4, it does NOT -- only the owner or approved operator can decrease liquidity)

Since Uniswap V4's PositionManager enforces that only the owner or approved operator can modify a position, the proxy would need to be an approved operator on the target position for this to work. This makes exploitation practically impossible unless someone explicitly approves the proxy as an operator.

**Impact Assessment:**
- No practical impact due to Uniswap V4's own access control on position modifications.
- The comment is accurate: the worst case (decreasing another approved position) results in the proxy receiving the tokens, which is rate-limited.

---

### Finding 13: ERC4626Lib `redeem` Does Not Check `maxExchangeRate`

**Severity:** Informational

**File:** `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/libraries/ERC4626Lib.sol`, lines 80-110

**Code:**
```solidity
function redeem(
    address proxy,
    address token,
    uint256 shares,
    uint256 minAssetsOut,
    address rateLimits,
    bytes32 withdrawRateLimitId,
    bytes32 depositRateLimitId
) external returns (uint256 assets) {
    assets = abi.decode(
        IALMProxy(proxy).doCall(
            token,
            abi.encodeCall(IERC4626(token).redeem, (shares, proxy, proxy))
        ),
        (uint256)
    );

    require(assets >= minAssetsOut, "MC/min-assets-out-not-met");
    // NOTE: No maxExchangeRate check here, unlike deposit()
    ...
```

**Description:**
The `deposit` function in ERC4626Lib checks `maxExchangeRate`, but `redeem` does not. This is by design -- when redeeming, you are exiting the vault, so an inflated exchange rate actually benefits the redeemer (more assets per share). The `maxExchangeRate` check on deposit prevents buying shares at an inflated price (e.g., donation attack). On redemption, the `minAssetsOut` parameter provides sufficient slippage protection.

**Impact Assessment:**
- No vulnerability. The asymmetric exchange rate check is intentionally correct.

---

### Finding 14: CurveLib Slippage Validation Performs Division Before Multiplication

**Severity:** Informational

**File:** `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/libraries/CurveLib.sol`, lines 102-106

**Code:**
```solidity
uint256 minimumMinAmountOut = params.amountIn
    * rates[params.inputIndex]
    * params.maxSlippage
    / rates[params.outputIndex]
    / 1e18;
```

**Description:**
The code multiplies first (`amountIn * rates[inputIndex] * maxSlippage`) and then divides. This ordering is correct for precision -- multiplying first avoids precision loss from early division. The code comment on lines 97-101 explains the mathematical derivation. The two sequential divisions (`/ rates[outputIndex] / 1e18`) are equivalent to `/ (rates[outputIndex] * 1e18)` but avoid a potential intermediate overflow.

**Impact Assessment:**
- No issue. The math is correct and precision-preserving.

---

### Finding 15: MainnetController State Variables Are Not Immutable

**Severity:** Informational

**File:** `/root/immunefi/audits/sparklend/src/spark-alm-controller/src/MainnetController.sol`, lines 140-191

**Code:**
```solidity
bytes32 public FREEZER = keccak256("FREEZER");
bytes32 public RELAYER = keccak256("RELAYER");
// ... many more public (not constant/immutable) state variables
address public buffer;
IALMProxy public proxy;
// etc.
```

**Description:**
Unlike ForeignController which uses `immutable` for `proxy`, `rateLimits`, etc., MainnetController declares them as regular `public` state variables. These are set in the constructor and never modified, but they occupy storage slots and cost more gas to read than `immutable` variables. More importantly, since they are not `immutable` or `constant`, they are technically mutable by any function that has access to storage -- but since there are no setter functions and the contract has no upgrade mechanism, they cannot be changed post-deployment.

Similarly, role identifiers like `FREEZER` and `RELAYER` are declared as `public` (not `constant`), consuming storage instead of being inlined at compile time. In ForeignController, they are declared as `constant`.

**Impact Assessment:**
- No security impact. This is a gas optimization issue.
- The lack of `immutable`/`constant` means higher gas costs but no vulnerability.

---

## File-by-File Analysis

### ALMProxy.sol (Lines 1-55)
- **Access Control:** Properly uses OpenZeppelin's `AccessControl` with `onlyRole(CONTROLLER)` on all three call functions.
- **Constructor:** Grants `DEFAULT_ADMIN_ROLE` to the admin parameter. Only admin can manage roles.
- **doCall (line 31-35):** Safe. Uses OZ's `Address.functionCall` which reverts on failure.
- **doCallWithValue (line 37-41):** Safe. Uses OZ's `Address.functionCallWithValue` which reverts on failure. The `payable` modifier is necessary for ETH forwarding.
- **doDelegateCall (line 43-47):** See Finding 1. Functional but powerful -- any CONTROLLER can execute arbitrary code in proxy's context.
- **receive() (line 53):** Necessary for receiving ETH from unwrapping WETH or claiming withdrawals.
- **No selfdestruct, no fallback, no assembly.** Clean contract.

### ALMProxyFreezable.sol (Lines 1-23)
- **Inheritance:** Extends ALMProxy correctly.
- **FREEZER role (line 10):** Correctly defined as a separate role from CONTROLLER.
- **removeController (line 18-21):** See Finding 7. One-directional freeze is intentional.
- **No way for FREEZER to add controllers or modify admin.** Correct privilege separation.

### AaveLib.sol (Lines 1-94)
- **deposit (lines 22-57):**
  - Rate limit checked BEFORE the action (line 30-33). Correct.
  - `maxSlippage != 0` check (line 35). Prevents unprotected deposits.
  - Slippage check (lines 53-56) validates aToken balance change against expected minimum.
  - Uses `ApproveLib.approve` for safe approval handling.
- **withdraw (lines 60-92):**
  - Rate limit checked AFTER the action (lines 83-91). Comment warns about this. This is safe because the withdraw amount is determined by the actual withdrawal.
  - Correctly increases the deposit rate limit to allow re-depositing withdrawn funds.
  - No slippage check on withdraw -- this is acceptable because the Aave `withdraw` function returns the actual amount, and the full specified amount or available balance is withdrawn.

### ApproveLib.sol (Lines 1-43)
- **approve (lines 11-41):** Implements a forceApprove pattern.
  - First attempts direct approve (line 16).
  - If successful and returns true (or no return), exits early (line 28).
  - If fails (USDT-style), resets to 0 (line 32) then approves to desired amount (line 34).
  - Final validation (lines 37-39) ensures the approve succeeded.
  - **Note on line 16:** Uses low-level `proxy.call()` for the initial attempt, which won't revert on failure. This is intentional to handle tokens that revert on non-zero-to-non-zero approve.
  - Pattern is sound and handles USDT, USDC, DAI, and standard ERC20 tokens correctly.

### CCTPLib.sol (Lines 1-143)
- **transferUSDCToCCTP (lines 46-88):**
  - Dual rate limiting (CCTP global + per-domain) on lines 47-52. Correct.
  - `mintRecipient != 0` check (line 54) prevents sending to zero address.
  - Burn limit splitting (lines 60-87): Correctly handles CCTP's per-message burn limit by splitting into multiple transfers.
  - **Potential issue:** The full `usdcAmount` is approved on line 57, but if the transfer is split into multiple burns, the approval covers all of them. This is safe because the loop consumes the approval incrementally.
- **_initiateCCTPTransfer (lines 106-133):** Correctly decodes the nonce and emits the event for offchain processing.
- **No replay attack concern:** CCTP itself handles message authentication via attestation. The library only initiates burns.

### CurveLib.sol (Lines 1-278)
- **swap (lines 81-141):**
  - Input validation: `inputIndex != outputIndex` (line 82), `maxSlippage != 0` (line 84), indices within bounds (lines 89-91).
  - Slippage calculation (lines 102-106): Uses `stored_rates` for cross-token value comparison. Math is correct.
  - Rate limit uses normalized value (line 115): `amountIn * rates[inputIndex] / 1e18`. Correct normalization.
  - Safe int128 cast (line 131): Comment notes safety due to 8 token max. Correct -- N_COINS is bounded.
- **addLiquidity (lines 143-212):**
  - Approves each coin individually (lines 158-164). Correct.
  - Virtual price division-by-zero protection (line 170-171): Comment notes intentional revert for unseeded pools.
  - Post-deposit swap calculation (lines 199-206): See Finding 5. Approximation is reasonable for stable pools.
- **removeLiquidity (lines 214-268):**
  - Slippage check (lines 238-244): Validates minimum withdraw value against LP token value. Correct.
  - Rate limit uses actual withdrawn amounts (lines 257-267). Correct.
- **_absSubtraction (lines 274-276):** Pure helper, correct implementation.

### ERC4626Lib.sol (Lines 1-122)
- **deposit (lines 17-46):**
  - Rate limit first (lines 26-29). Correct.
  - Slippage via `minSharesOut` (line 43). Correct.
  - Exchange rate check (line 45): Prevents donation attack exploitation. Correct.
- **withdraw (lines 48-78):**
  - Rate limit first (lines 57-60). Correct.
  - `maxSharesIn` check (line 72): Prevents burning too many shares. Correct.
  - Deposit rate limit increase (lines 74-77): Allows re-depositing. Correct.
- **redeem (lines 80-110):**
  - See Finding 13. No exchange rate check is intentional.
  - `minAssetsOut` (line 99): Provides slippage protection. Correct.
  - Both rate limits updated (lines 101-109). Correct.
- **getExchangeRate (lines 112-120):**
  - Handles edge cases: 0/0 returns 0, 0 shares with non-zero assets reverts. Correct.

### LayerZeroLib.sol (Lines 1-107)
- **transferTokenLayerZero (lines 30-97):**
  - Rate limit by OFT + destination (lines 38-48). Correct.
  - Recipient validation (line 50). Correct.
  - Conditional approval for OFTs that require it (lines 55-62). Correct.
  - Hard-coded gas limit `200_000` (line 64): This is a reasonable default for simple OFT transfers. If a destination chain requires more gas, this could cause failed deliveries, but no fund loss (LayerZero provides retry mechanisms).
  - `minAmountLD` set from `quoteOFT` (lines 77-85): See Finding 9.
  - Fee handling (lines 87-96): Correctly queries fee and passes native fee with the call.
  - **Warning comment** (lines 52-54): The team acknowledges this lacks integration testing. Rate limit should be zero until tested.

### PSMLib.sol (Lines 1-162)
- **swapUSDSToUSDC (lines 57-79):**
  - Rate limit on USDC amount (line 58). Correct.
  - USDS -> DAI -> USDC path. Correct for MakerDAO PSM architecture.
  - Approval amounts match expected amounts (usdsAmount = usdcAmount * conversionFactor). Correct.
- **swapUSDCToUSDS (lines 81-123):**
  - Rate limit INCREASE (line 82): This is a reverse swap, so it increases the rate limit (allows more USDS->USDC swaps). Correct.
  - See Finding 2 for the potential infinite loop.
  - USDC -> DAI -> USDS path. Correct.
- **_approve (lines 131-140):** Simple approve without forceApprove. Comment (lines 129-130) explains this is safe for USDC/USDS/DAI. Correct.

### UniswapV4Lib.sol (Lines 1-545)
- **Hardcoded addresses (lines 33-35):** Permit2, PositionManager, and Router addresses are hardcoded for Ethereum mainnet. This means the library cannot be used on other chains without modification. This is acceptable for a mainnet-specific deployment.
- **mintPosition (lines 41-80):** Checks tick limits, validates pool key match, then performs the mint. Correct.
- **increasePosition (lines 82-127):** Checks ownership (line 95-98), checks tick limits, validates pool key. Correct.
- **decreasePosition (lines 129-164):** See Finding 12. No ownership check is intentional.
- **swap (lines 166-247):**
  - `maxSlippage != 0` check (line 177). Correct.
  - Pool key validation (lines 179-186). Correct.
  - Rate limit on normalized input amount (lines 191-194). Correct.
  - Slippage check uses normalized balances (lines 208-212). Correct.
  - Approval reset after swap (line 246). Good security hygiene.
- **_approveWithPermit2 (lines 253-297):** See Findings 3 and 4.
- **_increaseLiquidity (lines 299-346):**
  - Balance-based accounting (lines 315-334). Robust against unexpected token flows.
  - Uses `_clampedSub` to handle edge case of receiving tokens during liquidity addition.
  - Approvals reset after action (lines 344-345). Correct.
- **_decreaseLiquidity (lines 348-381):**
  - Simple subtraction `endingBalance - startingBalance` (lines 372-373). This will revert if balances decreased, which is correct -- you should always receive tokens when decreasing liquidity.
- **_checkTickLimits (lines 387-399):** Comprehensive validation. Correct.
- **_getNormalizedBalance (lines 519-523):** Normalizes to 18 decimals. Potential issue: `10 ** decimals()` could overflow for tokens with decimals > 77, but no real tokens have such decimals.

### WEETHLib.sol (Lines 1-187)
- **deposit (lines 52-93):**
  - Rate limit on ETH amount (line 58). Correct.
  - Multi-step: WETH -> ETH -> eETH -> weETH. Each step is correctly implemented.
  - `minSharesOut` slippage check (line 92). Correct.
- **requestWithdraw (lines 95-147):**
  - Multi-step: weETH -> eETH, then request withdrawal from EtherFi.
  - Slippage check on eETH shares (lines 122-125). Protects against rate manipulation.
  - Rate limit on eETH amount (lines 128-132). Correct.
  - `weETHModule` validated via rate limit key (line 127 comment, lines 128-132). Correct.
- **claimWithdrawal (lines 149-170):**
  - See Finding 11. Rate limit existence check only. Intentional design.
  - Returns raw ETH received. The MainnetController does NOT wrap this to WETH. The caller must use `wrapAllProxyETH()` separately.

### Interface Files (CCTPInterfaces.sol, ILayerZero.sol, UniswapV4.sol)
- All interface files are clean declarations with no implementation logic.
- CCTPInterfaces.sol: Minimal interface for CCTP `depositForBurn` and minter queries. Correct.
- ILayerZero.sol: Complete OFT interface with all necessary types. Correct.
- UniswapV4.sol: Minimal interface for PositionManager and UniversalRouter. Correct.

---

## Summary of Access Control Model

The security model relies on multiple layers:

1. **ALMProxy Access Control:** Only CONTROLLER role can call `doCall`, `doCallWithValue`, `doDelegateCall`.
2. **Controller Access Control:** Only RELAYER role can call fund-moving functions. Only DEFAULT_ADMIN_ROLE can configure parameters.
3. **Reentrancy Guard:** All controller functions are `nonReentrant`.
4. **Rate Limits:** Every fund movement is rate-limited with configurable per-action, per-asset, and per-destination limits.
5. **Slippage Protection:** Admin-configured `maxSlippage` values enforced on swaps and deposits.
6. **Emergency Freeze:** FREEZER role can remove relayers (on controllers) or controllers (on proxy).

This layered approach means that even a compromised relayer is bounded by rate limits and slippage parameters set by governance.

---

## Conclusion

The ALM Proxy and integration libraries demonstrate a well-engineered, defense-in-depth approach to multi-protocol treasury management. The codebase is clean, well-commented, and handles edge cases (non-standard ERC20s, multi-step swaps, cross-chain bridging) with appropriate care.

**No critical or high-severity vulnerabilities were found** that would enable direct theft of funds, permanent freezing, or protocol insolvency under normal operating conditions.

The primary systemic risk is the `doDelegateCall` function on ALMProxy (Finding 1), which provides a powerful escape hatch that could be exploited if a CONTROLLER account is compromised. However, this is mitigated by the fact that CONTROLLER roles are only held by governance-deployed controller contracts, and the admin role required to grant CONTROLLER is held by governance.

### Risk Summary

| # | Finding | Severity | Status |
|---|---------|----------|--------|
| 1 | ALMProxy `doDelegateCall` arbitrary storage risk | Medium | Design risk, mitigated by access control |
| 2 | PSMLib `swapUSDCToUSDS` potential infinite loop | Low | Edge case DoS |
| 3 | UniswapV4Lib Permit2 expiration at `block.timestamp` | Low | Safe in current design |
| 4 | UniswapV4Lib ignored return on Permit2 reset | Informational | Intentional design |
| 5 | CurveLib post-deposit swap rate uses pre-deposit rates | Low | Minor accounting imprecision |
| 6 | AaveLib overflow potential on slippage check | Informational | Mitigated by Solidity 0.8 |
| 7 | ALMProxyFreezable one-directional freeze | Informational | Intentional design |
| 8 | CCTPLib simple approve (not forceApprove) | Informational | Safe for USDC |
| 9 | LayerZeroLib minAmountLD from potentially untrusted OFT | Low | Mitigated by rate limit key |
| 10 | CurveLib `coins()` non-view interface | Informational | Safe with admin-configured pools |
| 11 | WEETHLib `claimWithdrawal` existence-only check | Informational | Intentional design |
| 12 | UniswapV4Lib `decreasePosition` no ownership check | Low | Mitigated by Uniswap V4 access control |
| 13 | ERC4626Lib `redeem` no `maxExchangeRate` check | Informational | Intentional design |
| 14 | CurveLib slippage math ordering | Informational | Correct |
| 15 | MainnetController non-immutable state variables | Informational | Gas optimization only |

**Overall Assessment:** The codebase is production-ready with strong security properties. No findings meet the threshold for a critical Immunefi submission (direct theft of funds, permanent freezing, or protocol insolvency).
