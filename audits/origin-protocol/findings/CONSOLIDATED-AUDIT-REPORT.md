# Origin Protocol - Consolidated Security Audit Report

**Date:** 2026-03-02
**Auditor:** Independent Security Researcher
**Bounty Program:** Immunefi, max $1M Critical / $15K High, Primacy of Impact, No KYC
**Total LOC Audited:** ~27,800 across 3 repositories
**Hypotheses Tested:** 140+

---

## Executive Summary

Comprehensive security audit of Origin Protocol's full in-scope codebase across three repositories:

| Repository | Scope | LOC |
|---|---|---|
| **origin-dollar** | Vault, Token, Strategies, Oracle, Zapper, Bridge, Automation, Proxy | ~20,000 |
| **arm-oeth** | AbstractARM, LidoARM, EtherFiARM, EthenaARM, OriginARM, Markets, Zappers | ~5,800 |
| **ousd-governance** | ExponentialStaking (xOGN), RewardsSource, OGN governance | ~2,000 |

**Chains:** Ethereum, Base, Sonic (Plume in development)

### Finding Summary

| Severity | Count | Immunefi Submittable |
|---|---|---|
| Critical | 0 | - |
| High | 0 | - |
| Medium | 3 | 2 (IMMUNEFI-SUBMISSION-001, 002) |
| Low | 12 | 0 |
| Informational | 16 | 0 |

**Conclusion:** The codebase is well-engineered with mature security practices. No externally exploitable critical or high-severity vulnerabilities were found. The two Immunefi-submittable findings are a dead-code access control bypass (OETHPlumeVault) and an unsafe type cast (OETHOracleRouter). Both have mitigating factors that limit practical exploitability.

---

## Immunefi-Submittable Findings

### MEDIUM-01: OETHPlumeVault _mint Override is Dead Code — Access Control Bypass

**Immunefi Report:** `IMMUNEFI-SUBMISSION-001.md`
**PoC:** `scripts/verify/PoC_001_PlumeVaultMintBypass.sol`
**File:** `origin-dollar/contracts/contracts/vault/OETHPlumeVault.sol:14-28`
**Severity:** Medium (High if vault is operationalized with capitalPaused=false)

OETHPlumeVault defines `_mint(address, uint256, uint256)` to restrict minting to strategist/governor. However, VaultCore's external `mint()` functions call `_mint(uint256)` — a different function signature. OETHPlumeVault does NOT override `_mint(uint256)`, so the access control is completely dead code.

```solidity
// OETHPlumeVault.sol — DEAD CODE, never called
function _mint(address, uint256 _amount, uint256) internal virtual {
    require(msg.sender == strategistAddr || isGovernor(), "...");
    super._mint(_amount);
}

// VaultCore.sol — actually called, no access control
function _mint(uint256 _amount) internal virtual { ... }
```

**Mitigating factor:** Vault starts with `capitalPaused = true`. If never unpaused, minting is blocked.
**Fix:** Change to `function _mint(uint256 _amount) internal virtual override`.

---

### MEDIUM-02: OETHOracleRouter Unsafe int256→uint256 Cast (Missing SafeCast)

**Immunefi Report:** `IMMUNEFI-SUBMISSION-002.md`
**PoC:** `scripts/verify/PoC_002_OETHOracleNegativePrice.sol`
**File:** `origin-dollar/contracts/contracts/oracle/OETHOracleRouter.sol:44`
**Severity:** Medium

The mainnet OETHOracleRouter uses `uint256(_iprice)` instead of `_iprice.toUint256()` (SafeCast). All other oracle routers use SafeCast. If Chainlink returns a negative price, it wraps to near `type(uint256).max` instead of reverting.

```solidity
// OETHOracleRouter.sol:44 — UNSAFE
uint256 _price = uint256(_iprice).scaleBy(18, decimals);

// AbstractOracleRouter.sol:63 — SAFE (all other routers)
uint256 _price = _iprice.toUint256().scaleBy(18, decimals);
```

**Mitigating factor:** Chainlink circuit breakers prevent most negative price scenarios. OETHOracleRouter also lacks drift bounds (`shouldBePegged`), so no secondary validation.
**Fix:** Add `using SafeCast for int256;` and use `_iprice.toUint256()`.

---

## Other Medium Findings

### MEDIUM-03: PlumeBridgeHelperModule Missing require(success) on Approve

**File:** `origin-dollar/contracts/contracts/automation/PlumeBridgeHelperModule.sol:132-141`

The `_depositWOETH()` function's `execTransactionFromModule` call for wOETH approval doesn't check the return value. The equivalent `BaseBridgeHelperModule._depositWOETH()` correctly includes `require(success, "Failed to approve wOETH")`. The `success` variable is silently overwritten by the next exec call.

**Impact:** Silent approval failure; deposit proceeds without proper allowance.
**Fix:** Add `require(success, "Failed to approve wOETH");` after the approve exec.

---

## Low Findings

### LOW-01: SonicHarvester Swapped Assets Stranded When priceProvider=0

**File:** `arm-oeth/src/contracts/SonicHarvester.sol:141-157`

When `priceProvider == address(0)`, the `swap()` function returns early without transferring swapped liquidity assets to `rewardRecipient`. Assets accumulate in the harvester with no rescue function.

### LOW-02: LidoARM/EtherFiARM Withdrawal Request Mappings Not Cleared

**Files:** `arm-oeth/src/contracts/LidoARM.sol:144-172`, `EtherFiARM.sol:110-138`

`lidoWithdrawalRequests[requestId]` and `etherfiWithdrawalRequests[requestId]` are never deleted after claim. Relies on external protocol revert for double-claim prevention.

### LOW-03: ZapperARM Uses address(this).balance Instead of msg.value

**Files:** `arm-oeth/src/contracts/ZapperARM.sol:30-41`, `ZapperLidoARM.sol:38-48`

Both zappers wrap `address(this).balance` (includes stale ETH from selfdestruct) rather than `msg.value`. Next depositor would unknowingly include stale ETH.

### LOW-04: BridgedWOETHStrategy Uses Raw transfer Without SafeERC20

**File:** `origin-dollar/contracts/contracts/strategies/BridgedWOETHStrategy.sol:171,175,201,205`

Uses raw `.transfer()` and `.transferFrom()` on Origin-controlled tokens. Solidity 0.8+ reverts on false, but non-standard tokens (no return) would silently succeed.

### LOW-05: SonicStakingStrategy Uses Raw transfer Without SafeERC20

**File:** `origin-dollar/contracts/contracts/strategies/sonic/SonicStakingStrategy.sol:84`

Same pattern as LOW-04 with `IERC20(_asset).transfer(_recipient, _amount)`.

### LOW-06: SonicValidatorDelegator.restakeRewards is Permissionless

**File:** `origin-dollar/contracts/contracts/strategies/sonic/SonicValidatorDelegator.sol:284-306`

No access control (unlike `collectRewards` which requires `onlyRegistratorOrStrategist`). Anyone can force-compound rewards, removing the option to collect liquid tokens.

### LOW-07: EthereumBridgeHelperModule.wrapETH Ignores Exec Return Value

**File:** `origin-dollar/contracts/contracts/automation/EthereumBridgeHelperModule.sol:82-90`

`execTransactionFromModule` return value not checked for WETH deposit.

### LOW-08: CurvePoolBooster.closeCampaign Parameter/State Mismatch

**File:** `origin-dollar/contracts/contracts/poolBooster/curve/CurvePoolBooster.sol:229-247`

Uses state variable `campaignId` for close but emits parameter `_campaignId` in event. Misleading logs.

### LOW-09: PoolBoostCentralRegistry.removeFactory Emits Duplicate Event

**File:** `origin-dollar/contracts/contracts/poolBooster/PoolBoostCentralRegistry.sol:60,66`

`FactoryRemoved` emitted twice per removal — once inside loop, once after.

### LOW-10: mintForStrategy/burnForStrategy Lack nonReentrant

**File:** `origin-dollar/contracts/contracts/vault/VaultCore.sol:116-166`

Documented design choice for AMO strategy callbacks. Double access control (supported + whitelisted) mitigates.

### LOW-11: Yield Dilution During Rebase Pause

**File:** `origin-dollar/contracts/contracts/vault/VaultCore.sol:74-99`

New deposits mint at 1:1 even when undistributed yield exists during `rebasePaused`. Admin-controlled state.

### LOW-12: WOETH ERC4626 Base Lacks Virtual Share Offset

**File:** `origin-dollar/contracts/lib/openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol`

Outdated OZ ERC4626 without `_decimalsOffset()`. Fully mitigated by WOETH's `adjuster` mechanism.

---

## Informational Findings

| # | Title | File |
|---|---|---|
| INFO-01 | Aerodrome AMO uses amount0Min=0, amount1Min=0 (pool price check protects) | AerodromeAMOStrategy.sol |
| INFO-02 | CrossChain relay() lacks nonReentrant (onlyOperator mitigates) | AbstractCCTPIntegrator.sol |
| INFO-03 | CrossChainMasterStrategy._onTokenReceived transfers entire balance (intentional) | CrossChainMasterStrategy.sol |
| INFO-04 | CrossChainRemoteStrategy withdrawal failure sends full balance confirmation (correct) | CrossChainRemoteStrategy.sol |
| INFO-05 | FixedRateDripper uninitialized lastCollect (self-protected by _collect()) | FixedRateDripper.sol |
| INFO-06 | Generalized4626Strategy.merkleClaim permissionless (beneficial, tokens go to strategy) | Generalized4626Strategy.sol |
| INFO-07 | OSonicOracleRouter uses fixed 1:1 oracle on production Sonic (correct for wS-only) | OSonicOracleRouter.sol |
| INFO-08 | AbstractSafeModule.transferTokens uses unchecked transfer (onlySafe mitigates) | AbstractSafeModule.sol |
| INFO-09 | ClaimBribesSafeModule.fetchNFTIds is permissionless (reads only Safe-owned NFTs) | ClaimBribesSafeModule.sol |
| INFO-10 | Zapper contracts lack token rescue function | AbstractOTokenZapper.sol |
| INFO-11 | WOETHCCIPZapper fee estimation uses pre-deduction amount (conservative) | WOETHCCIPZapper.sol |
| INFO-12 | Proxy missing explicit receive() (delegated via fallback — standard) | InitializeGovernedUpgradeabilityProxy.sol |
| INFO-13 | BridgedWOETH burn without allowance check (BURNER_ROLE design) | BridgedWOETH.sol |
| INFO-14 | changeSupply allows decrease (unused — _rebase enforces upward-only) | OUSD.sol |
| INFO-15 | ExponentialStaking _collectRewards implicit return 0 in else branch | ExponentialStaking.sol |
| INFO-16 | EthenaARM nextUnstakerIndex not reset on setUnstakers() | EthenaARM.sol |

---

## Well-Defended Areas

### WOETH Adjuster Mechanism — Excellent
The `adjuster / rebasingCreditsPerTokenHighres()` ratio makes WOETH immune to donation-based manipulation. Direct OETH donations are ignored. Safe for lending markets and AMM integration.

### Rebasing Credit System — Excellent
Consistent protocol-favoring rounding: credits round UP, balances round DOWN, creditsPerToken rounds UP. Resolution increase of 1e9 for high-precision accounting.

### Triple-Capped Yield Drip — Excellent
1. `dripDuration` smoothing (default 7 days)
2. `rebasePerSecondMax` rate cap
3. `MAX_REBASE = 2%` hard per-rebase cap
Prevents flash-yield attacks, makes WOETH lending-safe.

### ARM Dead Shares — Solid
1e12 shares to `DEAD_ACCOUNT` on first deposit prevents first-depositor inflation attacks.

### ARM Cross-Price Bounds — Solid
`traderate0` and `traderate1` bounded by `crossPrice` with maximum 0.2% deviation prevents operator from setting loss-making swap prices.

### Cross-Chain CCTP Nonce System — Well-Engineered
Sequential nonce processing, source domain + sender validation, finality thresholds (2000 for finalized), replay protection, staleness guards.

### AMO Solvency Checks — Solid
`improvePoolBalance` modifier (Curve), `nearBalancedPool` (SwapX), `SOLVENCY_THRESHOLD = 0.998` consistently applied. `get_virtual_price()` for manipulation-resistant balance checking.

### Native Staking Beacon Proofs — Excellent
EIP-4788 beacon block root verification, 1 ETH first deposit limit, validator state machine with front-run detection, bounded arrays (MAX_DEPOSITS=32, MAX_VERIFIED_VALIDATORS=48).

### xOGN Flash Governance Prevention — Solid
Non-transferable tokens + checkpoint-based voting + 1-day voting delay eliminates flash loan governance attacks.

### Two-Step Governance — Consistent
`transferGovernance` + `claimGovernance` pattern applied across all governable contracts with custom keccak storage slots.

### Custom Reentrancy Guard — Solid
Storage slot `keccak256("OUSD.reentry.status")` compatible with proxy pattern. Applied consistently to all critical external functions.

---

## Methodology

### Phase 1: Scope Determination
Identified 30+ in-scope contracts across Ethereum, Base, and Sonic from Immunefi program page. Cloned 3 repositories. Total ~27,800 LOC.

### Phase 2: Full Codebase Exploration
Read every high-priority contract. Built architecture maps for each subsystem. Identified all external entry points, access control patterns, and trust boundaries.

### Phase 3-5: Multi-Angle Analysis & Verification
Launched 7 specialized background analysis agents covering:
- Strategy contracts (Cross-chain, AMO, NativeStaking, ERC-4626)
- Vault and Token core (VaultCore, OUSD, WOETH)
- Oracle, Zapper, Bridge, Automation, Governance, Proxy
- ARM and xOGN governance
- Cross-chain CCTP vulnerability analysis
- Withdrawal queue analysis

Tested 140+ hypotheses across all subsystems. Applied false positive elimination to every finding.

### Phase 6-7: Report Writing
Consolidated findings from all analysis agents. Verified each finding independently. Created Immunefi-ready submissions for the two submittable findings.

---

## Sub-Reports

Detailed findings for each subsystem are in separate reports:

| Report | Scope | Findings |
|---|---|---|
| `AUDIT-REPORT.md` | Strategy Contracts | 0H, 0M, 3L, 6I |
| `VAULT-TOKEN-AUDIT-REPORT.md` | Vault & Token Core | 0H, 1M, 3L, 5I |
| `AUDIT-REPORT-ORACLE-ZAPPER-BRIDGE.md` | Oracle, Zapper, Bridge, Automation, Governance, Proxy | 0H, 2M, 3L, 6I |
| `AUDIT-REPORT-ARM-GOVERNANCE.md` | ARM & xOGN Governance | 0H, 0M, 3L, 5I |

## Immunefi Submissions

| Submission | Finding | Severity |
|---|---|---|
| `IMMUNEFI-SUBMISSION-001.md` | OETHPlumeVault _mint dead code | Medium/High |
| `IMMUNEFI-SUBMISSION-002.md` | OETHOracleRouter unsafe cast | Medium |

## Proof of Concept Files

| PoC | Finding |
|---|---|
| `scripts/verify/PoC_001_PlumeVaultMintBypass.sol` | OETHPlumeVault access control bypass |
| `scripts/verify/PoC_002_OETHOracleNegativePrice.sol` | OETHOracleRouter negative price wrap |
