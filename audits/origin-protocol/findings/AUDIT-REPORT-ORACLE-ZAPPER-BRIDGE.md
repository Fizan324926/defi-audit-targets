# Origin Protocol Security Audit Report
## Oracle, Zapper, Bridge, PoolBooster, Automation, Governance & Proxy Contracts

**Date:** 2026-03-02
**Auditor:** Senior Smart Contract Security Researcher
**Scope:** 50+ Solidity contracts across 7 subsystems
**Bounty:** Immunefi, max $1M (Critical), $15K (High)

---

## Executive Summary

The Origin Protocol codebase covering Oracle, Zapper, Bridge, PoolBooster, Automation, Governance, and Proxy contracts is **well-engineered** with strong defensive patterns. The governor/strategist access control model is consistently applied. The proxy pattern uses EIP-1967 storage slots correctly. The bridge adapters properly delegate to LayerZero and CCIP frameworks.

**Total Findings:** 2 Medium, 3 Low, 6 Informational
**Exploitable vulnerabilities:** 0 Critical, 0 High

The most significant finding is the **unsafe int256-to-uint256 cast** in `OETHOracleRouter.price()` which lacks the SafeCast protection present in all other oracle routers. While Chainlink circuit breakers make exploitation via a genuinely negative oracle price unlikely, this is a code defect that should be fixed.

---

## FINDING-01: OETHOracleRouter Uses Unsafe int256 Cast (Missing SafeCast) [Medium]

**File:** `/root/defi-audit-targets/audits/origin-protocol/origin-dollar/contracts/contracts/oracle/OETHOracleRouter.sol:44`
**Also affects:** Any contract inheriting OETHOracleRouter where `price()` is not overridden (OETHFixedOracle, OSonicOracleRouter)

### Description

`OETHOracleRouter.price()` converts the Chainlink price from `int256` to `uint256` using a raw Solidity cast:

```solidity
// OETHOracleRouter.sol:44
uint256 _price = uint256(_iprice).scaleBy(18, decimals);
```

This is inconsistent with `AbstractOracleRouter.price()` (line 63) and `OETHBaseOracleRouter.price()` (line 51), which both use OpenZeppelin `SafeCast`:

```solidity
// AbstractOracleRouter.sol:63
uint256 _price = _iprice.toUint256().scaleBy(18, decimals);

// OETHBaseOracleRouter.sol:51
uint256 _price = _iprice.toUint256().scaleBy(18, decimals);
```

If `_iprice` is negative (which Chainlink can theoretically return for certain feed types or during extreme market conditions), `SafeCast.toUint256()` correctly reverts, while `uint256(_iprice)` silently wraps around to a massive number close to `type(uint256).max`. This would bypass the staleness check and return an astronomically inflated price.

Note: `OETHOracleRouter` imports `SafeCast` and `using SafeCast for int256` is declared in child contracts (`OETHBaseOracleRouter`, `OETHPlumeOracleRouter`), but the base `OETHOracleRouter` itself does NOT use `SafeCast` and does NOT declare `using SafeCast for int256`.

### Impact

If a Chainlink oracle feed returns a negative price, it would be interpreted as an enormous positive price (close to `type(uint256).max`). This could allow minting OETH at an absurdly favorable rate. In practice, Chainlink circuit breakers prevent most feeds from reporting negative values, making exploitation unlikely but not impossible for all feed configurations. The OETHOracleRouter serves the Ethereum mainnet OETH vault -- the highest TVL deployment.

### Existing Defenses

- Chainlink aggregators have `minAnswer`/`maxAnswer` bounds (circuit breakers)
- The `OETHOracleRouter` does NOT apply drift bounds (no `shouldBePegged` check), so there is no secondary price validation for OETH assets
- The `FIXED_PRICE` path returns early before the cast (WETH returns 1e18 directly)

### Recommendation

Replace the raw cast with `SafeCast.toUint256()`:

```diff
+ using SafeCast for int256;
  ...
- uint256 _price = uint256(_iprice).scaleBy(18, decimals);
+ uint256 _price = _iprice.toUint256().scaleBy(18, decimals);
```

---

## FINDING-02: PlumeBridgeHelperModule Missing Require on Approve Call [Medium]

**File:** `/root/defi-audit-targets/audits/origin-protocol/origin-dollar/contracts/contracts/automation/PlumeBridgeHelperModule.sol:132-141`

### Description

In `PlumeBridgeHelperModule._depositWOETH()`, the `execTransactionFromModule` call to approve wOETH for the bridgedWOETHStrategy does NOT check the return value:

```solidity
// PlumeBridgeHelperModule.sol:132-141
bool success = safeContract.execTransactionFromModule(
    address(bridgedWOETH),
    0,
    abi.encodeWithSelector(
        bridgedWOETH.approve.selector,
        address(bridgedWOETHStrategy),
        woethAmount
    ),
    0
);
// <-- NO require(success, ...) HERE

// Deposit to bridgedWOETH strategy
success = safeContract.execTransactionFromModule(  // <-- success overwritten
```

The equivalent function in `BaseBridgeHelperModule._depositWOETH()` correctly includes:

```solidity
// BaseBridgeHelperModule.sol:146
require(success, "Failed to approve wOETH");
```

If the Safe module is disabled or if the approve call fails for any reason, the code silently continues to the deposit call. The `success` variable is overwritten by the next `execTransactionFromModule` call, so the approval failure is completely lost.

### Impact

Silent failure of the approve step. The deposit will still attempt without proper approval, potentially reverting with a less descriptive error. If a residual approval exists from a prior operation, the deposit could succeed with stale approval amount. Practically limited because the operator role is trusted and the Safe executes calls sequentially.

### Recommendation

Add the missing require check:

```diff
  bool success = safeContract.execTransactionFromModule(
      address(bridgedWOETH),
      0,
      abi.encodeWithSelector(
          bridgedWOETH.approve.selector,
          address(bridgedWOETHStrategy),
          woethAmount
      ),
      0
  );
+ require(success, "Failed to approve wOETH");
```

---

## FINDING-03: EthereumBridgeHelperModule.wrapETH Missing Success Check [Low]

**File:** `/root/defi-audit-targets/audits/origin-protocol/origin-dollar/contracts/contracts/automation/EthereumBridgeHelperModule.sol:82-90`

### Description

The `wrapETH()` function calls `execTransactionFromModule` to deposit ETH into WETH but does not check the return value:

```solidity
function wrapETH(uint256 ethAmount) public payable onlyOperator {
    safeContract.execTransactionFromModule(
        address(weth),
        ethAmount,
        abi.encodeWithSelector(weth.deposit.selector),
        0
    );
    // <-- return value ignored
}
```

Compare with `_mintAndWrap()` in the same contract where every `execTransactionFromModule` call is checked with `require(success, ...)`.

### Impact

If the module is not enabled on the Safe (or some other failure), the wrap silently fails. Subsequent operations in `mintAndWrap` that call `_mintAndWrap` after `wrapETH` would then operate with zero WETH balance, causing a confusing downstream revert. Limited impact since the operator is trusted and WETH deposit is a simple operation.

### Recommendation

```diff
- safeContract.execTransactionFromModule(
+ bool success = safeContract.execTransactionFromModule(
      address(weth),
      ethAmount,
      abi.encodeWithSelector(weth.deposit.selector),
      0
  );
+ require(success, "Failed to wrap ETH");
```

---

## FINDING-04: CurvePoolBooster.closeCampaign Parameter Mismatch [Low]

**File:** `/root/defi-audit-targets/audits/origin-protocol/origin-dollar/contracts/contracts/poolBooster/curve/CurvePoolBooster.sol:229-247`

### Description

`closeCampaign` accepts `_campaignId` as a parameter but uses the state variable `campaignId` for the actual close operation:

```solidity
function closeCampaign(uint256 _campaignId, uint256 additionalGasLimit) external payable ... {
    ICampaignRemoteManager(campaignRemoteManager).closeCampaign{value: msg.value}(
        ICampaignRemoteManager.CampaignClosingParams({
            campaignId: campaignId  // <-- uses STATE variable, NOT parameter _campaignId
        }),
        ...
    );
    campaignId = 0;
    emit CampaignClosed(_campaignId);  // <-- emits the PARAMETER
}
```

The NatSpec states: "The _campaignId parameter is not related to the campaignId of this contract, allowing greater flexibility." Yet the function always closes the stored `campaignId`, making the `_campaignId` parameter completely unused for the actual operation. The event emission uses the parameter, creating a misleading log that doesn't match the actual campaign that was closed.

### Impact

Confusing event emissions. An off-chain monitor reading `CampaignClosed` events would see the parameter value, not the actual campaign that was closed. If the caller provides a different `_campaignId` than the stored `campaignId`, the event would be misleading.

### Recommendation

Either use the parameter for the actual close operation, or emit the state variable:

```diff
+ uint256 closedId = campaignId;
  ICampaignRemoteManager(campaignRemoteManager).closeCampaign{value: msg.value}(
      ICampaignRemoteManager.CampaignClosingParams({
-         campaignId: campaignId
+         campaignId: closedId
      }),
      ...
  );
  campaignId = 0;
- emit CampaignClosed(_campaignId);
+ emit CampaignClosed(closedId);
```

---

## FINDING-05: PoolBoostCentralRegistry.removeFactory Emits Duplicate Event [Low]

**File:** `/root/defi-audit-targets/audits/origin-protocol/origin-dollar/contracts/contracts/poolBooster/PoolBoostCentralRegistry.sol:48-67`

### Description

`removeFactory` emits `FactoryRemoved` twice -- once inside the loop and once after:

```solidity
function removeFactory(address _factoryAddress) external onlyGovernor {
    ...
    for (uint256 i = 0; i < length; i++) {
        if (factories[i] != _factoryAddress) {
            continue;
        }
        factories[i] = factories[length - 1];
        factories.pop();
        emit FactoryRemoved(_factoryAddress);  // <-- FIRST emission (line 60)
        factoryRemoved = true;
        break;
    }
    require(factoryRemoved, "Not an approved factory");
    emit FactoryRemoved(_factoryAddress);  // <-- SECOND emission (line 66)
}
```

### Impact

Off-chain event indexers would see two `FactoryRemoved` events for a single removal, potentially causing double-processing in monitoring systems or dashboards.

### Recommendation

Remove the duplicate event emission (the one after the loop at line 66):

```diff
  require(factoryRemoved, "Not an approved factory");
- emit FactoryRemoved(_factoryAddress);
```

---

## FINDING-06: OSonicOracleRouter Uses Fixed 1:1 Oracle on Production Sonic Chain [Informational]

**File:** `/root/defi-audit-targets/audits/origin-protocol/origin-dollar/contracts/contracts/oracle/OSonicOracleRouter.sol`
**Deployed:** Sonic chain at `0xE68e0C66950a7e02335fc9f44daa05D115c4E88B`

### Description

`OSonicOracleRouter` inherits from `OETHFixedOracle`, which returns `1e18` for ALL asset prices. The code comment says "used solely for deployment to testnets," but the contract IS deployed to the production Sonic chain.

For the current Sonic vault that only accepts wS (Wrapped Sonic), a 1:1 fixed price is appropriate since wS is the native asset denomination. However, if any non-pegged assets are ever added to the Sonic vault, this oracle would not validate their price, potentially enabling arbitrage.

### Existing Defenses

The vault only accepts a single asset (wS), so the 1:1 assumption is currently correct.

### Recommendation

Update the comment to accurately describe the intended use, or implement proper Chainlink-based oracle routing for the Sonic chain when feeds become available.

---

## FINDING-07: AbstractSafeModule.transferTokens Uses Unchecked ERC20 Transfer [Informational]

**File:** `/root/defi-audit-targets/audits/origin-protocol/origin-dollar/contracts/contracts/automation/AbstractSafeModule.sol:53`

### Description

```solidity
// slither-disable-next-line unchecked-transfer unused-return
IERC20(token).transfer(address(safeContract), amount);
```

Uses bare `transfer()` without SafeERC20. Non-standard ERC20 tokens that return `false` instead of reverting on failure would silently fail. The slither disable comment acknowledges this.

### Existing Defenses

Only callable by `onlySafe` modifier (the Safe multisig itself). The Safe would typically only recover known tokens.

### Recommendation

Use `SafeERC20.safeTransfer()` for maximum token compatibility.

---

## FINDING-08: ClaimBribesSafeModule.fetchNFTIds is Permissionless [Informational]

**File:** `/root/defi-audit-targets/audits/origin-protocol/origin-dollar/contracts/contracts/automation/ClaimBribesSafeModule.sol:209-227`

### Description

`fetchNFTIds()` has no access control modifier and can be called by anyone. It deletes the existing `nftIds` array and repopulates it from the veNFT contract. While the code comment acknowledges this design ("This function is public, anyone can call it, since it only fetches the NFT IDs owned by the Safe"), it creates a griefing vector where:

1. An attacker calls `fetchNFTIds()` repeatedly, forcing gas expenditure on the veNFT reads
2. The function uses `delete nftIds` which does NOT clean the `nftIdIndex` mapping for previously stored IDs (stale mapping entries remain)

Additionally, the `delete nftIds` is not preceded by `removeAllNFTIds`-style mapping cleanup. If called between `removeNFTIds` and a subsequent `addNFTIds`, the mappings for removed-then-re-added NFTs could be inconsistent. However, `nftIdExists()` validates both `index < length` and `_nftIds[index] == nftId`, preventing false positives from stale mappings.

### Impact

Minimal. The function only reads NFTs owned by the Safe, so it cannot add unauthorized NFTs. The permissionless nature is acknowledged and intentional.

---

## FINDING-09: Zapper Contracts Lack Token Rescue Function [Informational]

**File:** `/root/defi-audit-targets/audits/origin-protocol/origin-dollar/contracts/contracts/zapper/AbstractOTokenZapper.sol`

### Description

The `AbstractOTokenZapper` and `OSonicZapper` contracts have no mechanism to rescue tokens accidentally sent directly to the contract. The zappers hold maximum approvals for WETH and oToken, and the `_mint` function uses `weth.balanceOf(address(this))` to determine mint amounts, meaning stray WETH sent to the contract would be included in the next zap operation. However, stray oTokens or other ERC20s would be permanently stuck.

### Existing Defenses

The `_mint` function using the full balance as mint amount means stray WETH benefits the next zapper user rather than being stuck. But this is a gift to the next user, not a recovery mechanism.

### Recommendation

Consider adding a governor-only rescue function, or document the no-rescue design decision.

---

## FINDING-10: WOETHCCIPZapper Fee Estimation Uses Input Amount Not Post-Fee Amount [Informational]

**File:** `/root/defi-audit-targets/audits/origin-protocol/origin-dollar/contracts/contracts/zapper/WOETHCCIPZapper.sol:105-129`

### Description

In `_zap()`, the fee is estimated using the full `amount` for the token amount in `getFee()`:

```solidity
uint256 feeAmount = getFee(amount, receiver);  // estimates fee based on full amount
amount -= feeAmount;                            // actual bridge uses reduced amount
```

But `getFee()` constructs the CCIP message with `amount` (pre-deduction) as the token amount. The actual bridge then uses `woethReceived` (a different, smaller amount after OETH->wOETH conversion). Since CCIP fees are primarily based on message complexity rather than token amounts, the discrepancy is negligible and conservative.

### Impact

Negligible. The fee overestimation is conservative (user-friendly).

---

## FINDING-11: Proxy Missing receive() Function [Informational]

**File:** `/root/defi-audit-targets/audits/origin-protocol/origin-dollar/contracts/contracts/proxies/InitializeGovernedUpgradeabilityProxy.sol`

### Description

The proxy contract has a `fallback() external payable` function but no explicit `receive()` function. Plain ETH transfers (empty calldata) will trigger the `fallback()` and be delegated to the implementation. This is standard proxy behavior but worth noting: if the implementation doesn't have a `receive()` either, ETH transfers will revert.

### Impact

None under normal operation. This is the expected proxy pattern.

---

## Clean Areas (No Findings)

### Oracle System
- **AbstractOracleRouter**: Correctly uses SafeCast (`_iprice.toUint256()`), staleness checks (`updatedAt + maxStaleness >= block.timestamp`), and drift bounds for pegged assets (0.7-1.3 range). The `cacheDecimals` pattern avoids external calls during price reads. The `STALENESS_BUFFER = 1 days` provides generous fallback. The `getDecimals` function requires cached decimals, preventing use of assets before explicit setup.
- **OETHBaseOracleRouter**: Properly uses `SafeCast.toUint256()` for int-to-uint conversion. WETH correctly mapped to FIXED_PRICE. wOETH/OETH exchange rate from Chainlink with 2-day staleness window.
- **OETHPlumeOracleRouter**: Properly uses `SafeCast.toUint256()`. Uses eo.app oracle feed for wOETH price. Same structure as Base router.
- **OracleRouter (OUSD)**: Uses parent AbstractOracleRouter's SafeCast-protected `price()` method. Applies drift bounds to DAI/USDC/USDT via `shouldBePegged()`. Appropriate staleness windows (1 hour for DAI/USDS/COMP/AAVE, 1 day for USDC/USDT/CRV/CVX plus buffer).

### Zapper System
- **AbstractOTokenZapper**: The `_mint` function correctly validates `mintedAmount >= minOToken`. The 1:1 mint model for single-asset vaults means the input amount IS the minimum. The `deposit()` function correctly uses the full ETH balance, preventing stuck ETH. Constructor sets max approvals to vault and wOToken, eliminating per-tx approval overhead.
- **OETHBaseZapper, OETHZapper**: Simple wrappers with no additional attack surface.
- **OSonicZapper**: Clean implementation following the same pattern as AbstractOTokenZapper, properly adapted for Sonic chain (wS instead of WETH).
- **WOETHCCIPZapper**: Correctly handles the ETH -> OETH -> wOETH -> CCIP pipeline. The fee deduction from msg.value is done before minting, so the user always receives tokens proportional to their net deposit. The `AmountLessThanFee` error prevents dust amounts from reverting deep in the stack. The constructor sets max approvals for wrapping and bridging.

### Bridge Adapters
- **OmnichainL2Adapter**: Correctly implements mint/burn pattern for LayerZero OFT. The `_debit` function burns from the sender, and `_credit` mints to the recipient. The `address(0x0)` to `address(0xdead)` redirect prevents minting to zero address. Owner correctly set to governor.
- **OmnichainMainnetAdapter**: Minimal wrapper around OFTAdapter (lock/unlock pattern). Ownership correctly transferred to governor via `_transferOwnership`. No additional attack surface beyond LayerZero's own framework.

### PoolBooster System
- **AbstractPoolBoosterFactory**: Governor-only creation with proper create2 deployment. The `bribeAll` function is permissionless but only calls `bribe()` on already-deployed boosters with their own token balances. The swap-and-pop removal pattern is correctly implemented. The `_deployContract` checks `_address.code.length > 0`.
- **PoolBoosterMerkl**: IERC1271 implementation correctly restricts `isValidSignature` to only the Merkl distributor (`msg.sender == address(merklDistributor)`). Duration validation (`> 1 hours`). Minimum bribe amount (`MIN_BRIBE_AMOUNT = 1e10`) prevents dust operations. The `getNextPeriodStartTime()` calculation correctly rounds up to next period boundary.
- **PoolBoosterMetropolis**: Creates rewarder per bribe call via factory. Properly checks whitelist status and min amounts. Bribes the next voting period (`getCurrentVotingPeriod() + 1`).
- **PoolBoosterSwapxDouble**: Split validation (1%-99% range, `_split > 1e16 && _split < 99e16`). Clean split calculation using `mulTruncate`. No loss of precision since `balance - osBribeAmount` captures remainder.
- **PoolBoosterSwapxSingle**: Minimal, clean implementation. Correct approval-then-notify pattern.
- **PoolBoostCentralRegistry**: Governor-only factory management. The `isApprovedFactory` linear search is bounded by the practical number of factories. Only approved factories can emit events.
- **CurvePoolBooster**: Proper `nonReentrant` guards on all mutative functions. Fee capped at 50% (`FEE_BASE / 2`). The `_handleFee` function re-reads balance after fee transfer to avoid rounding issues. `rescueToken` is governor-only while `rescueETH` is governor-or-strategist.
- **CurvePoolBoosterFactory**: CreateX front-running protection via salt-encoded sender address. Initialize-in-same-tx pattern correctly protects uninitialized contracts. The `_computeGuardedSalt` properly hashes the factory address into the salt for CreateX's protection mechanism.
- **CurvePoolBoosterPlain**: `initializer` modifier ensures one-time initialization. Factory deploys and initializes atomically. Governor set via `_setGovernor` in initialize (not constructor, for cross-chain address determinism).

### Automation Modules
- **AbstractSafeModule**: DEFAULT_ADMIN_ROLE correctly granted to Safe contract only. OPERATOR_ROLE for automation bots. Two-tier access control (Safe for admin, Operator for routine operations). ETH receive for bridge fee funding.
- **AutoWithdrawalModule**: Soft failure model (events instead of reverts) is correct for automated operations. The shortfall calculation (`meta.queued - meta.claimable`) is safe because the vault maintains the invariant `queued >= claimable`. Strategy-only parameter changeable by Safe.
- **BaseBridgeHelperModule**: All Safe exec calls properly checked for success. Clean depositWOETH/claimWithdrawal/bridgeWETH workflow. Oracle price updated and rebase called before deposit to ensure accurate accounting.
- **AbstractCCIPBridgeHelperModule**: Correctly constructs CCIP messages and checks both approve and send success. Receiver always `address(safeContract)` preventing fund misdirection.
- **AbstractLZBridgeHelperModule**: Proper slippage calculation (`amount * (10000 - slippageBps) / 10000`). Gas limit hardcoded at 400k which is reasonable for OFT receives. Receiver is `bytes32(uint256(uint160(address(safeContract))))` - proper address encoding.
- **ClaimStrategyRewardsSafeModule**: Clean strategy whitelist pattern. Silent mode for automated retry. Admin-only strategy add/remove.
- **ClaimBribesSafeModule**: Paginated NFT claiming (`nftIndexStart` to `nftIndexEnd`). Silent mode option. Safe-only bribe pool management.
- **CurvePoolBoosterBribesModule**: Bridge fee bounded at 0.01 ETH (`require(newFee <= 0.01 ether)`). Gas limit bounded at 10M. Proper balance check before iteration. Default parameters are safe (use all rewards, extend 1 period).
- **CollectXOGNRewardsModule**: Clean implementation with proper success checks on both collect and transfer steps. Zero-balance short-circuit.
- **EthereumBridgeHelperModule**: Complete mint-wrap-bridge pipeline with proper success checks (except wrapETH per FINDING-03).
- **PlumeBridgeHelperModule**: Uses LZ bridge instead of CCIP. Proper slippage parameter passthrough. Vault redeem path with hardcoded selector for removed interface method.

### Governance System
- **Governable**: Two-step governance transfer (`transferGovernance` -> `claimGovernance`) prevents accidental ownership loss. Custom storage slots (`keccak256("OUSD.governor")`) prevent collision with proxy storage. Built-in reentrancy guard using custom storage slot (`keccak256("OUSD.reentry.status")`). The `_changeGovernor` rejects `address(0)`.
- **InitializableGovernable**: Combines `Governable` with `Initializable` for proxy usage. Clean `_initialize` function.
- **Strategizable**: 50-slot storage gap for future upgrades. Governor-only strategist setting. Virtual `onlyGovernorOrStrategist` modifier allows override.

### Proxy System
- **InitializeGovernedUpgradeabilityProxy**: Standard EIP-1967 implementation slot. Governor-only upgrades via `upgradeTo` and `upgradeToAndCall`. `Address.isContract()` check on new implementations prevents setting EOA as implementation. One-time initialization with governor enforcement (`require(_implementation() == address(0))`). The implementation slot is validated against `keccak256("eip1967.proxy.implementation") - 1` via assert.
- **InitializeGovernedUpgradeabilityProxy2**: Correctly handles CreateX deployment where msg.sender cannot be governor at construction time. Constructor overrides parent's `_setGovernor(msg.sender)` with the provided governor address.
- **CrossChainStrategyProxy**: Clean, minimal proxy with DO-NOT-MODIFY warning for create2 address stability. No custom logic beyond parent.
- **All named proxies** (Proxies.sol, BaseProxies.sol, SonicProxies.sol, PlumeProxies.sol): Empty contracts inheriting from `InitializeGovernedUpgradeabilityProxy`. No additional storage or functions that could cause collisions.

---

## Architecture Observations

### Strengths
1. **Consistent access control**: Governor/Strategist/Operator three-tier model is uniformly applied across all subsystems
2. **Custom storage slots**: Governable uses `keccak256("OUSD.governor")` to avoid proxy storage collisions -- a mature pattern
3. **CreateX front-running protection**: CurvePoolBoosterFactory properly encodes the factory address in the salt
4. **Soft-failure automation**: AutoWithdrawalModule and ClaimBribes use events instead of reverts for bot-friendly operation
5. **Conservative oracle staleness**: The 1-day STALENESS_BUFFER provides generous fallback without sacrificing security
6. **Immutable pattern**: All critical addresses (tokens, vaults, Safe contracts) are immutable where possible, reducing governance risk
7. **Two-step governance**: Prevents accidental ownership loss across all governable contracts
8. **Atomic deploy-and-initialize**: CurvePoolBoosterPlain is deployed and initialized in the same transaction, preventing initialization front-running

### Potential Improvements
1. Consider adding `roundId` validation to oracle calls (checking `roundId > 0` and `answeredInRound >= roundId`) for additional Chainlink data quality checking
2. The oracle routers could benefit from an abstract `_validatePrice(int256)` hook to ensure consistent negative-price handling across all routers
3. The zapper contracts would benefit from a minimal rescue function for non-WETH/non-oToken assets
4. Consider adding `nonReentrant` to `AbstractSafeModule.transferTokens()` as defense-in-depth

---

## Hypotheses Tested and Disproved

1. **Can oracle prices be manipulated via stale data?** No -- all oracle routers enforce staleness checks with appropriate windows (1h to 2d including buffer). The FIXED_PRICE path for native-denominated assets returns early without reading any feed.

2. **Can zappers be sandwich-attacked?** Minimally -- the single-asset vault mints 1:1, so there is no oracle-dependent exchange rate. The `mintedAmount >= minOToken` check uses the deposit amount itself as minimum. The wrapped token functions (`depositETHForWrappedTokens`, etc.) have explicit `minReceived` parameters for the wOToken conversion step.

3. **Can bridge message replay occur?** No -- LayerZero OFT framework and CCIP both have built-in replay protection at the messaging layer. The adapters add no custom message handling that could introduce replay vectors.

4. **Can pool booster funds be drained?** No -- pool boosters only spend their own token balance. The `bribe()` function reads `rewardToken.balanceOf(address(this))` and can only send tokens TO the bribe/distributor contract. There is no withdrawal mechanism for arbitrary amounts. The minimum bribe check (`MIN_BRIBE_AMOUNT = 1e10`) prevents dust griefing.

5. **Can automation operators be tricked into harmful operations?** No -- the Safe module pattern restricts operators to pre-defined operations (collect rewards, bridge, claim). The operators can only call specific functions on specific target contracts via `execTransactionFromModule`. They cannot execute arbitrary calls.

6. **Can proxy initialization be front-run?** No -- `InitializeGovernedUpgradeabilityProxy.initialize` requires `onlyGovernor` (which is `msg.sender` from the constructor). `CurvePoolBoosterPlain.initialize` uses `initializer` modifier and is called in the same transaction as `create2` deployment, protected by CreateX salt guards.

7. **Can governance be hijacked via proxy storage collision?** No -- Governable uses a computed storage slot (`keccak256("OUSD.governor")`) that doesn't collide with EIP-1967 implementation slot. The implementation slot is at `keccak256("eip1967.proxy.implementation") - 1`.

8. **Can CurvePoolBooster fees be manipulated?** No -- fee is set by governor only, capped at 50% (`FEE_BASE / 2 = 5000`). The `_handleFee` re-reads balance after fee transfer to use actual remaining balance (not calculated), preventing rounding exploits.

9. **Can the PoolBoostCentralRegistry be used to emit fake events?** No -- only approved factories (governor-controlled) can emit events via `onlyApprovedFactories` modifier.

10. **Can the AutoWithdrawalModule be used to drain the vault?** No -- it only calls `vault.withdrawFromStrategy` via the Safe, which requires the Safe to have the Strategist role on the vault. The amount is bounded by `min(shortfall, strategyBalance)`, and only withdraws to the vault itself (not to an external address).
