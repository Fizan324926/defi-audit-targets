# Origin Protocol Strategy Contracts - Security Audit Report

**Date:** 2026-03-02
**Auditor:** Independent Security Researcher
**Scope:** Origin Protocol Strategy Contracts (~21 strategy files, harvesters, drippers, utilities)
**Bounty Program:** Immunefi, max $1M Critical / $15K High

---

## Executive Summary

Comprehensive security audit of Origin Protocol's strategy contracts including the newly added Cross-Chain (CCTP) strategies, AMO strategies (Curve, Aerodrome, SwapX), Native Staking (legacy + Compounding/Pectra), ERC-4626 strategies, Drippers, and Harvesters. The codebase is well-engineered with strong defensive patterns. No critical or high-severity exploitable vulnerabilities were found. Several low and informational findings are documented below.

**Total Findings: 0 High, 0 Medium, 3 Low, 6 Informational**

---

## Table of Contents

1. [Findings](#findings)
2. [Clean Areas](#clean-areas)
3. [Architecture Analysis](#architecture-analysis)

---

## Findings

### FINDING-01 [Low]: BridgedWOETHStrategy uses raw transfer/transferFrom without SafeERC20

**File:** `/root/defi-audit-targets/audits/origin-protocol/origin-dollar/contracts/contracts/strategies/BridgedWOETHStrategy.sol`
**Lines:** 171, 175, 201, 205

**Description:**
The `depositBridgedWOETH` and `withdrawBridgedWOETH` functions use raw `.transfer()` and `.transferFrom()` calls on `oethb` and `bridgedWOETH` tokens instead of SafeERC20's `safeTransfer` and `safeTransferFrom`.

```solidity
// Line 171 - depositBridgedWOETH
oethb.transfer(msg.sender, oethToMint);

// Line 175
bridgedWOETH.transferFrom(msg.sender, address(this), woethAmount);

// Line 201 - withdrawBridgedWOETH
bridgedWOETH.transfer(msg.sender, woethAmount);

// Line 205
oethb.transferFrom(msg.sender, address(this), oethToBurn);
```

**Existing Defenses:**
- The Slither comment `// slither-disable-next-line unchecked-transfer unused-return` suggests the team is aware.
- Both `oethb` and `bridgedWOETH` are Origin Protocol's own tokens (OETHb and wOETH bridge token), which are expected to follow standard ERC20 behavior (returning true on success).
- The `transferToken` function in the same contract correctly uses `safeTransfer` for unknown rescue tokens.

**Impact:** Low. Since both tokens are Origin Protocol controlled and standard ERC20 compliant, the return value will always be checked by the compiler (Solidity 0.8+ reverts on false returns from `transfer`). However, tokens that return no data (USDT-style) would silently succeed even on failure. Since these are known tokens, practical risk is minimal.

**Recommendation:** Use `safeTransfer` and `safeTransferFrom` consistently for defense-in-depth.

---

### FINDING-02 [Low]: SonicStakingStrategy uses raw IERC20.transfer without SafeERC20

**File:** `/root/defi-audit-targets/audits/origin-protocol/origin-dollar/contracts/contracts/strategies/sonic/SonicStakingStrategy.sol`
**Line:** 84

**Description:**
The `_withdraw` function uses raw `.transfer()`:

```solidity
function _withdraw(
    address _recipient,
    address _asset,
    uint256 _amount
) internal override {
    require(_amount > 0, "Must withdraw something");
    require(_recipient != address(0), "Must specify recipient");

    // slither-disable-next-line unchecked-transfer unused-return
    IERC20(_asset).transfer(_recipient, _amount);

    emit Withdrawal(wrappedSonic, address(0), _amount);
}
```

**Existing Defenses:**
- The `_asset` parameter is always `wrappedSonic` (Wrapped Sonic token) per the `withdraw()` require check.
- Slither disable comment shows awareness.

**Impact:** Low. Wrapped Sonic (wS) is a standard ERC20 token. Same analysis as FINDING-01 applies -- Solidity 0.8+ will revert if the function returns false, but tokens with no return value (non-standard) would be silently accepted.

---

### FINDING-03 [Low]: SonicValidatorDelegator.restakeRewards is permissionless

**File:** `/root/defi-audit-targets/audits/origin-protocol/origin-dollar/contracts/contracts/strategies/sonic/SonicValidatorDelegator.sol`
**Lines:** 284-306

**Description:**
The `restakeRewards` function has `nonReentrant` but NO access control modifier. Any external address can call it to restake rewards for any supported validators.

```solidity
function restakeRewards(uint256[] calldata _validatorIds)
    external
    nonReentrant
{
    for (uint256 i = 0; i < _validatorIds.length; ++i) {
        require(
            isSupportedValidator(_validatorIds[i]),
            "Validator not supported"
        );
        uint256 rewards = sfc.pendingRewards(
            address(this),
            _validatorIds[i]
        );
        if (rewards > 0) {
            sfc.restakeRewards(_validatorIds[i]);
        }
    }
}
```

In contrast, `collectRewards` is restricted to `onlyRegistratorOrStrategist`.

**Existing Defenses:**
- Restaking rewards is generally a beneficial action (compounds returns).
- Only supported validators can be restaked.
- `nonReentrant` prevents reentrancy.
- The `checkBalance` function accounts for both staked amounts and pending rewards, so restaking doesn't change the reported balance.

**Impact:** Low. While permissionless, restaking rewards is a net-positive action for the protocol. An attacker could force-compound rewards when the protocol might prefer to collect them as liquid S tokens, but this has minimal economic impact since the balance accounting includes both staked and pending rewards. The main concern is that it removes the option to collect liquid rewards via `collectRewards` if restaked first.

---

### FINDING-04 [Informational]: Aerodrome AMO uses amount0Min=0, amount1Min=0 for all liquidity operations

**File:** `/root/defi-audit-targets/audits/origin-protocol/origin-dollar/contracts/contracts/strategies/aerodrome/AerodromeAMOStrategy.sol`
**Lines:** 496-497, 649-664, 673-681

**Description:**
All `decreaseLiquidity`, `mint`, and `increaseLiquidity` calls use `amount0Min: 0` and `amount1Min: 0`.

**Existing Defenses:**
- The code comments explicitly state: "amount0Min & amount1Min are left at 0 because slippage protection is ensured by the `_checkForExpectedPoolPrice` function" (line 649-651).
- `_checkForExpectedPoolPrice` validates the pool's current sqrtPriceX96 is within expected bounds.
- `SOLVENCY_THRESHOLD = 0.998 ether` provides additional protection.
- The `gaugeUnstakeAndRestake` modifier ensures consistent gauge state.
- Operations are gated behind `onlyGovernorOrStrategist` (trusted callers).

**Impact:** Informational. The pool price check provides equivalent slippage protection to explicit min amounts for a narrow tick range ([-1, 0]) concentrated liquidity position. Since the tick range is only 1 tick wide, the price check is actually more robust than amount minimums.

---

### FINDING-05 [Informational]: CrossChain relay() function lacks nonReentrant modifier

**File:** `/root/defi-audit-targets/audits/origin-protocol/origin-dollar/contracts/contracts/strategies/crosschain/AbstractCCTPIntegrator.sol`
**Lines:** 448-545

**Description:**
The `relay()` function on `AbstractCCTPIntegrator` does not have the `nonReentrant` modifier, while most other state-changing functions in the CrossChain strategies do.

```solidity
function relay(bytes memory message, bytes memory attestation)
    external
    onlyOperator
{
    // ... processes CCTP message, calls receiveMessage, then _onTokenReceived
}
```

**Existing Defenses:**
- `onlyOperator` restricts the caller to a single trusted address.
- The CCTP `receiveMessage` itself has replay protection (attestation + nonce).
- `_markNonceAsProcessed` prevents replay of the same nonce.
- The operator is a trusted off-chain component, not a permissionless caller.
- The `cctpMessageTransmitter.receiveMessage()` call is to a well-audited Circle contract.

**Impact:** Informational. Since `relay()` is restricted to the operator (trusted address), reentrancy from the operator is not a realistic attack vector. The CCTP message transmitter itself also has built-in replay protection. However, for defense-in-depth, adding `nonReentrant` would be prudent given the function calls external contracts (`receiveMessage`) that can trigger callbacks via `handleReceiveFinalizedMessage`.

---

### FINDING-06 [Informational]: CrossChainMasterStrategy._onTokenReceived transfers entire USDC balance

**File:** `/root/defi-audit-targets/audits/origin-protocol/origin-dollar/contracts/contracts/strategies/crosschain/CrossChainMasterStrategy.sol`
**Lines:** 226-231

**Description:**
When tokens are received from a withdrawal, `_onTokenReceived` transfers the ENTIRE USDC balance of the contract to the vault, not just the received `tokenAmount`:

```solidity
// Send any tokens in the contract to the Vault
uint256 usdcBalance = IERC20(usdcToken).balanceOf(address(this));
// Should always have enough tokens
require(usdcBalance >= tokenAmount, "Insufficient balance");
// Transfer all tokens to the Vault to not leave any dust
IERC20(usdcToken).safeTransfer(vaultAddress, usdcBalance);
```

**Existing Defenses:**
- The comment "Transfer all tokens to the Vault to not leave any dust" shows this is intentional behavior.
- `checkBalance()` includes `IERC20(usdcToken).balanceOf(address(this))` in its calculation, so transferring everything to the vault is actually the correct action to prevent double-counting.
- Only the CCTP message transmitter can trigger this path (via relay -> receiveMessage -> handleReceiveFinalizedMessage callback -> _onTokenReceived).
- `pendingAmount` is cleared in `_processBalanceCheckMessage` which is called first by `_onMessageReceived`.

**Impact:** Informational. This is intentional design. Any USDC that accidentally ends up on the master strategy (e.g., direct transfers) will be swept to the vault during the next withdrawal completion. This is actually a safety feature, not a bug.

---

### FINDING-07 [Informational]: CrossChainRemoteStrategy withdrawal failure sends full balance as confirmation

**File:** `/root/defi-audit-targets/audits/origin-protocol/origin-dollar/contracts/contracts/strategies/crosschain/CrossChainRemoteStrategy.sol`
**Lines:** 270-298

**Description:**
In `_processWithdrawMessage`, when the withdrawal from the 4626 vault fails (try/catch in `_withdraw`), the function falls into the else branch and sends a balance check with `strategyBalance` (full balance) and `transferConfirmation: true`:

```solidity
if (
    withdrawAmount >= MIN_TRANSFER_AMOUNT &&
    usdcBalance >= withdrawAmount
) {
    // Success path: sends tokens + balance check with strategyBalance - withdrawAmount
    bytes memory message = CrossChainStrategyHelper
        .encodeBalanceCheckMessage(
            lastTransferNonce,
            strategyBalance - withdrawAmount,
            true,
            block.timestamp
        );
    _sendTokens(withdrawAmount, message);
} else {
    // Failure path: sends balance check with full strategyBalance
    bytes memory message = CrossChainStrategyHelper
        .encodeBalanceCheckMessage(
            lastTransferNonce,
            strategyBalance,
            true,
            block.timestamp
        );
    _sendMessage(message);
    emit WithdrawalFailed(withdrawAmount, usdcBalance);
}
```

**Existing Defenses:**
- The `transferConfirmation: true` in the failure path is correct -- it must still confirm the nonce to unblock the master strategy from its pending state.
- The balance reported is the actual `checkBalance()` value, which accurately reflects the remote strategy's holdings.
- On the master side, `_processBalanceCheckMessage` will update `remoteStrategyBalance` and clear `pendingAmount`, correctly reflecting that no funds were withdrawn.
- The master strategy can then retry the withdrawal.

**Impact:** Informational. The design correctly handles withdrawal failures. The master strategy will update its cached remote balance and clear the pending state, allowing operations to resume. The key insight is that `transferConfirmation` means "this completes the nonce lifecycle" not "the withdrawal succeeded."

---

### FINDING-08 [Informational]: FixedRateDripper comment warns about uninitialized lastCollect on new proxy

**File:** `/root/defi-audit-targets/audits/origin-protocol/origin-dollar/contracts/contracts/harvest/FixedRateDripper.sol`
**Lines:** 63-71

**Description:**
The comment in `setDripRate` warns about a potential issue:

```solidity
/**
 * Note: It's important to call `_collect` before updating
 * the drip rate especially on a new proxy contract.
 * When `lastCollect` is not set/initialized, the elapsed
 * time would be calculated as `block.number` seconds,
 * resulting in a huge yield, if `collect` isn't called first.
 */
// Collect at existing rate
_collect();
```

**Existing Defenses:**
- `setDripRate` calls `_collect()` before updating, which properly handles this edge case.
- When `lastCollect` is 0 (uninitialized), the first `_collect()` will calculate a large elapsed time but `perSecond` will also be 0 (default), so `allowed = elapsed * 0 = 0`. No funds are sent.
- After `_collect()`, `lastCollect` is set to `block.timestamp`.

**Impact:** Informational. The self-defense mechanism (`_collect()` first) makes this safe. The comment is a maintenance note, not a vulnerability. The zero `perSecond` default means no funds can be drained even with an uninitialized `lastCollect`.

---

### FINDING-09 [Informational]: Generalized4626Strategy.merkleClaim has no access control

**File:** `/root/defi-audit-targets/audits/origin-protocol/origin-dollar/contracts/contracts/strategies/Generalized4626Strategy.sol`
**Lines:** 234-254

**Description:**
The `merkleClaim` function has no access control modifier. Anyone can call it to claim Merkle rewards on behalf of the strategy:

```solidity
function merkleClaim(
    address token,
    uint256 amount,
    bytes32[] calldata proof
) external {
    address[] memory users = new address[](1);
    users[0] = address(this);
    // ...
    merkleDistributor.claim(users, tokens, amounts, proofs);
    emit ClaimedRewards(token, amount);
}
```

**Existing Defenses:**
- The Merkle proof must be valid for the strategy's address (`address(this)`).
- The claimed tokens go to the strategy contract, not the caller.
- The Merkle distributor (Merkl by Angle) validates the proof against the root.
- Claimed tokens will be picked up by the harvester via `collectRewardTokens`.
- Front-running a claim has no economic benefit since tokens go to the strategy.

**Impact:** Informational. The permissionless nature is actually a convenience feature. Since tokens always land on the strategy contract and the proof must be valid, there is no economic attack vector. Anyone triggering the claim just helps the protocol collect its rewards faster.

---

## Clean Areas

### Cross-Chain Strategy (CCTP) -- Newly Added, Highest Priority

**Status: Well-engineered, no exploitable vulnerabilities found.**

Key defensive patterns verified:
- **Nonce-based sequential operations:** `_getNextNonce()` requires previous nonce to be processed before starting a new operation. This prevents parallel deposits/withdrawals and race conditions.
- **Source domain + sender validation:** Both `handleReceiveFinalizedMessage` and `handleReceiveUnfinalizedMessage` verify `sourceDomain == peerDomainID` and `sender == peerStrategy`.
- **Finality thresholds:** Finalized messages require threshold >= 2000, unfinalized require exactly 1000 (configurable).
- **Balance staleness protection:** `MAX_BALANCE_CHECK_AGE = 1 days` prevents outdated balance updates from being applied.
- **Out-of-order message handling:** The master strategy correctly ignores balance check messages with mismatched nonces and those that arrive during pending operations.
- **Transfer amount bounds:** `MAX_TRANSFER_AMOUNT = 10M USDC`, `MIN_TRANSFER_AMOUNT = 1 USDC`.
- **Deposit/withdrawal failure resilience:** The remote strategy uses try/catch for 4626 vault interactions, ensuring message flow continues even if the underlying platform fails.
- **Immutable peer strategy addresses:** Cannot be changed post-deployment, preventing address hijacking.
- **CCTP attestation replay protection:** Built into Circle's message transmitter.
- **Operator restriction:** `relay()` is restricted to a single trusted operator address.

Hypotheses tested and disproved:
1. *Can an attacker replay CCTP messages?* No -- CCTP has built-in replay protection, plus the nonce system provides additional protocol-level protection.
2. *Can balance updates be manipulated?* No -- balance checks include nonce matching, transfer-in-progress detection, and staleness checks.
3. *Can the master strategy double-count funds?* No -- `pendingAmount` is set on deposit and cleared on balance check confirmation. `checkBalance = local + pending + remote` correctly partitions funds.
4. *Can withdrawal failures leave funds stranded?* No -- failed withdrawals send balance checks to unblock the master strategy, which can retry.
5. *Can `sendBalanceUpdate` be abused?* No -- it is restricted to operator/strategist/governor and sends with `transferConfirmation: false`, which can only update balance when no operation is pending.

### AMO Strategies (Curve, Aerodrome, SwapX)

**Status: Robust, well-defended.**

Key defensive patterns verified:
- **SOLVENCY_THRESHOLD = 0.998 ether** (99.8% backing) -- consistently applied across all AMO strategies.
- **`improvePoolBalance` modifier** (Curve): Ensures every operation moves the pool toward better balance, preventing strategic manipulation.
- **`nearBalancedPool` modifier** (SwapX): Blocks operations when the pool is depegged beyond `maxDepeg`.
- **`_checkForExpectedPoolPrice`** (Aerodrome): Validates sqrtPriceX96 bounds before operations.
- **Virtual price for checkBalance** (Curve): Uses `get_virtual_price()` instead of spot balances, which is manipulation-resistant.
- **`skimPool` modifier** (SwapX): Calls `skim()` before operations to ensure consistent state.
- **OToken mint/burn accounting:** AMO strategies correctly mint OTokens to add to pools and burn them on removal, tracked through `mintForStrategy` and `burnForStrategy` vault calls.
- **Dead NFT LP position seed** (Aerodrome): Requires initial liquidity from an external account, preventing first-depositor issues.

### Native Staking (Compounding/Pectra)

**Status: Exceptionally well-engineered for a complex domain.**

Key defensive patterns verified:
- **1 ETH first deposit + verification:** Limits exposure to front-running attacks on validator deposits.
- **`firstDeposit` flag:** Only one unverified validator deposit at a time.
- **Beacon chain proof verification:** Uses EIP-4788 beacon block roots for trustless verification of validator state.
- **`SNAP_BALANCES_DELAY = 35 * 12 seconds`:** Ensures sufficient time for off-chain proof preparation.
- **Validator state machine:** NON_REGISTERED -> REGISTERED -> STAKED -> VERIFIED -> ACTIVE -> EXITING -> EXITED -> REMOVED. Invalid state for front-run detection.
- **`MAX_DEPOSITS = 32`, `MAX_VERIFIED_VALIDATORS = 48`:** Bounded arrays prevent unbounded gas consumption.
- **WETH accounting:** `depositedWethAccountedFor` prevents double-counting of WETH deposits.
- **`lastVerifiedEthBalance`:** Beacon-proof-verified balance prevents manipulation.

### Native Staking (Legacy)

**Status: Solid, well-tested.**

Key defensive patterns verified:
- **Fuse-based accounting** (ValidatorAccountant): Automatic detection of consensus rewards vs. slashing events.
- **`manuallyFixAccounting` bounds:** validatorsDelta limited to [-3, 3], consensusRewardsDelta to [-332 ETH, 332 ETH].
- **`MIN_FIX_ACCOUNTING_CADENCE = 7200 blocks`:** Rate-limits manual adjustments.
- **FeeAccumulator separation:** Clean separation of execution layer rewards from consensus layer accounting.
- **Donation protection:** `Math.min(address(this).balance, depositedWethAccountedFor)` in NativeStakingSSVStrategy prevents griefing via direct ETH/WETH sends.

### Generalized4626Strategy

**Status: Clean.**

Key defensive patterns verified:
- **`previewRedeem` for checkBalance:** Rounds down (conservative direction).
- **Max approval at initialization:** Single `approve(type(uint256).max)` to platform.
- **All deposit/withdraw functions:** Properly gated with `onlyVault` + `nonReentrant`.

### Dripper / FixedRateDripper

**Status: Clean, elegant design.**

Key defensive patterns verified:
- **Rate recalculation on collect:** `remaining / dripDuration` ensures natural decay curve.
- **`setDripRate` calls `_collect()` first:** Prevents huge first-drip on rate change.
- **Governor-only `transferToken`/`transferAllToken`:** Emergency escape hatches.
- **Permissionless `collect` and `collectAndRebase`:** Anyone can trigger yield distribution, which is beneficial.

### Harvesters

**Status: Clean.**

Key defensive patterns verified:
- **`onlyHarvester` modifier** on strategy-side `collectRewardTokens`.
- **SafeERC20 used** for reward token transfers.
- **Swap routing** properly delegated to strategist-configured parameters.

### Access Control

**Status: Consistent and well-layered.**

Access control hierarchy verified:
- **Governor:** Highest privilege, sets all configuration, can emergency withdraw.
- **Strategist:** Operational decisions (rebalancing, AMO operations).
- **Registrator:** Validator lifecycle management.
- **Operator:** Cross-chain message relaying.
- **Harvester:** Reward collection only.
- **Vault:** Deposit/withdraw trigger.
- **Two-step governance transfer:** `transferGovernance` + `claimGovernance` prevents accidental ownership loss.
- **Custom reentrancy guard:** Uses storage position slots in Governable.sol, shared across all inheriting contracts.

### Fund Flow Analysis

Verified complete fund flows:
1. **Deposit -> Strategy -> Yield -> Harvest -> Dripper -> Vault:** WETH/USDC deposits flow through vault to strategies. Yield accrues in strategies, harvested to dripper, dripped to vault over time, triggering rebase.
2. **Cross-Chain:** Vault deposit -> Master Strategy -> CCTP bridge -> Remote Strategy -> 4626 vault. Returns: Remote 4626 -> CCTP bridge -> Master -> Vault.
3. **AMO:** Vault deposit -> AMO Strategy -> mint OToken -> add liquidity to pool. Returns: remove liquidity -> burn OToken -> return asset to vault.
4. **Native Staking:** Vault deposit -> Strategy -> unwrap WETH -> stake to validator. Returns: validator exit -> sweep -> wrap to WETH -> strategy -> vault.

---

## Architecture Analysis

### Inheritance Structure

```
Governable (reentrancy guard + governance)
  |
  +-- Initializable (proxy initialization)
  |     |
  |     +-- InitializableAbstractStrategy (base strategy)
  |           |
  |           +-- Generalized4626Strategy
  |           |     +-- CrossChainRemoteStrategy (+ AbstractCCTPIntegrator)
  |           |
  |           +-- BaseCurveAMOStrategy
  |           |     +-- CurveAMOStrategy
  |           |
  |           +-- AerodromeAMOStrategy
  |           +-- BridgedWOETHStrategy
  |           +-- SonicValidatorDelegator
  |           |     +-- SonicStakingStrategy
  |           |     +-- SonicSwapXAMOStrategy
  |           |
  |           +-- CompoundingStakingSSVStrategy (+ CompoundingValidatorManager)
  |           +-- NativeStakingSSVStrategy (+ ValidatorAccountant + ValidatorRegistrator)
  |           +-- CrossChainMasterStrategy (+ AbstractCCTPIntegrator)
  |
  +-- Dripper
        +-- FixedRateDripper
```

### Storage Layout Notes

All strategy contracts use `__gap` arrays for upgrade safety:
- `InitializableAbstractStrategy`: `int256[98] _reserved`
- `SonicValidatorDelegator`: `uint256[44] __gap`
- `SonicStakingStrategy`: `uint256[50] __gap`
- `CompoundingValidatorManager`: `uint256[41] __gap`
- `AbstractCCTPIntegrator`: `uint256[48] __gap`
- `Generalized4626Strategy`: `uint256[50] __gap`
- `CrossChainRemoteStrategy`: Inherits gaps from both parents

### External Dependencies

- **Circle CCTP v2:** Message transmitter and token messenger for cross-chain USDC transfers.
- **Curve/Aerodrome/SwapX DEXes:** AMO pool interactions.
- **SSV Network:** Secret Shared Validator infrastructure.
- **Ethereum Beacon Chain:** Deposit contract (0x00000000219ab540356cBB839Cbe05303d7705Fa).
- **Sonic SFC:** Special Fee Contract for Sonic validator delegation.
- **OpenZeppelin:** SafeERC20, SafeCast, Math, Pausable.
- **Merkl (Angle):** Merkle distributor for reward claims.

---

## Conclusion

The Origin Protocol strategy contracts demonstrate mature security engineering practices. The newly added Cross-Chain (CCTP) strategies are well-designed with proper sequential operation control, replay protection, and failure resilience. The AMO strategies maintain consistent solvency thresholds and pool balance improvement checks. The Compounding Validator Manager implements thorough beacon chain proof verification with front-run protection.

The three low-severity findings relate to inconsistent use of SafeERC20 (FINDING-01, FINDING-02) and a permissionless restake function (FINDING-03). These do not pose significant economic risk given the controlled token environments and beneficial-action nature of the permissionless function.

No findings warrant Immunefi submission at the High or Critical tier.
