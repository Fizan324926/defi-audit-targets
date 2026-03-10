# Origin Protocol Vault & Token Security Audit Report

**Date:** 2026-03-02
**Scope:** Origin Protocol Vault (VaultCore, VaultAdmin, VaultStorage, VaultInitializer) and Token contracts (OUSD, OETH, WOETH, WrappedOusd, WOETHBase, WOSonic, WOETHPlume, BridgedWOETH, OETHPlumeVault, OSVault, OETHBaseVault, OUSDVault, OETHVault, OUSDResolutionUpgrade, StableMath, Helpers, Initializable, InitializableERC20Detailed)
**Bounty Program:** Immunefi, max $1M Critical / $15K High
**Hypotheses Tested:** 60+

---

## Executive Summary

Comprehensive security audit of Origin Protocol's Vault and Token contracts covering the rebasing OToken mechanism (OUSD/OETH), ERC4626 wrapped tokens (WOETH/WOSonic/WrappedOusd), vault operations (mint, rebase, withdrawal queue, strategy allocation), and access control. The codebase is well-engineered with strong defensive patterns across rounding, reentrancy, yield smoothing, and proxy safety. One medium-severity finding was identified in OETHPlumeVault where a function signature mismatch renders an access control restriction completely inert.

**Total Findings: 0 Critical, 0 High, 1 Medium, 3 Low, 5 Informational**

---

## Table of Contents

1. [Findings](#findings)
2. [Clean Areas and Defenses](#clean-areas-and-defenses)
3. [Architecture Analysis](#architecture-analysis)

---

## Findings

### FINDING-01 [Medium]: OETHPlumeVault _mint Override is Dead Code -- Access Control Bypass

**File:** `/root/defi-audit-targets/audits/origin-protocol/origin-dollar/contracts/contracts/vault/OETHPlumeVault.sol` (lines 14-28)

**Description:**
OETHPlumeVault defines a 3-parameter `_mint(address, uint256, uint256)` function intended to restrict minting to only the strategist or governor. However, this function signature does not match the parent's `_mint(uint256)` from VaultCore. The external `mint(address, uint256, uint256)` and `mint(uint256)` in VaultCore both call `_mint(_amount)` (the 1-parameter version), meaning OETHPlumeVault's access control check is never executed.

**Vulnerable Code:**
```solidity
// OETHPlumeVault.sol:14-28
function _mint(
    address,          // 3-param version - NEW function, not an override
    uint256 _amount,
    uint256
) internal virtual {
    require(
        msg.sender == strategistAddr || isGovernor(),
        "Caller is not the Strategist or Governor"
    );
    super._mint(_amount);
}
```

```solidity
// VaultCore.sol:53-58 - calls _mint(uint256), NOT _mint(address,uint256,uint256)
function mint(
    address,
    uint256 _amount,
    uint256
) external whenNotCapitalPaused nonReentrant {
    _mint(_amount);  // <-- calls VaultCore._mint(uint256), bypasses OETHPlumeVault
}
```

**Call chain analysis:**
1. User calls `OETHPlumeVault.mint(address, uint256, uint256)` (inherited from VaultCore)
2. VaultCore.mint resolves to `_mint(_amount)` -- this is `_mint(uint256)`
3. Solidity dispatches to `VaultCore._mint(uint256)` because OETHPlumeVault does NOT override `_mint(uint256)`
4. OETHPlumeVault's `_mint(address, uint256, uint256)` is a **new, separate function** that is never called

**Impact:** If the Plume vault's `capitalPaused` flag is set to false (normal operational state), any user can mint OTokens by depositing assets, completely bypassing the intended strategist/governor restriction. The code comment explicitly states: "Only Strategist or Governor can mint using the Vault for now."

**Existing Defenses (partial):** The vault starts with `capitalPaused = true` (VaultInitializer line 22). If capital is never unpaused on the Plume vault, minting is blocked through `whenNotCapitalPaused`. However, this is a blunt tool that also blocks ALL capital operations (withdrawals, allocations), not just minting.

**Severity:** Medium. The intended access restriction is completely non-functional. Whether this is exploitable depends on deployment configuration. If `capitalPaused` is ever set to `false` on Plume (the normal path for an operational vault), any user can mint.

**Recommendation:** Change the override to match the actual parent function signature:
```solidity
function _mint(uint256 _amount) internal virtual override {
    require(
        msg.sender == strategistAddr || isGovernor(),
        "Caller is not the Strategist or Governor"
    );
    super._mint(_amount);
}
```

---

### FINDING-02 [Low]: mintForStrategy/burnForStrategy Lack Reentrancy Guard

**File:** `/root/defi-audit-targets/audits/origin-protocol/origin-dollar/contracts/contracts/vault/VaultCore.sol` (lines 116-166)

**Description:**
`mintForStrategy()` and `burnForStrategy()` intentionally omit the `nonReentrant` modifier. The documented rationale is that AMO strategies may call back during `allocate` (triggered by `mint`), causing a reentrancy collision. However, this creates a potential reentrancy vector if a whitelisted strategy contract has a vulnerability.

```solidity
function mintForStrategy(uint256 _amount)
    external
    virtual
    whenNotCapitalPaused
    // NOTE: No nonReentrant modifier
{
    require(strategies[msg.sender].isSupported == true, "Unsupported strategy");
    require(isMintWhitelistedStrategy[msg.sender] == true, "Not whitelisted strategy");
    oToken.mint(msg.sender, _amount);
}
```

**Existing Defenses:**
- Double access control: must be BOTH `strategies[msg.sender].isSupported` AND `isMintWhitelistedStrategy[msg.sender]`
- Both flags must be explicitly set by governor
- The code comment notes "Production / mainnet contracts should never be configured in a way where mint/redeem functions that are moving funds between the Vault and end user wallets can influence strategies utilizing this function"

**Severity:** Low. The double access control check is a strong defense. A compromised whitelisted strategy could potentially re-enter these functions during a single transaction to mint unbounded OTokens, but this requires a strategy-level compromise which is outside the vault's trust boundary.

**Recommendation:** Document this as a critical deployment configuration requirement. Consider whether AMO strategies can be refactored to use a separate callback mechanism that avoids the reentrancy collision.

---

### FINDING-03 [Low]: Yield Dilution During Rebase Pause

**File:** `/root/defi-audit-targets/audits/origin-protocol/origin-dollar/contracts/contracts/vault/VaultCore.sol` (lines 74-99)

**Description:**
When `rebasePaused` is true, yield accrues in the vault (vaultValue increases) but is not distributed to OToken holders via `changeSupply`. New deposits still mint at 1:1 (asset:OToken), diluting existing holders' proportional claim on the unrealized yield.

**Scenario:**
1. Vault: 100 WETH backing 100 OETH, plus 10 WETH undistributed yield
2. `rebasePaused = true`
3. User deposits 10 WETH, receives 10 OETH at 1:1
4. Vault: 120 WETH backing 110 OETH
5. When rebase resumes: all 110 OETH holders share the 10 WETH yield
6. Original holders diluted: 10/110 vs 10/100 per-unit yield

**Existing Defenses:**
- `rebasePaused` is admin-controlled, typically used during emergencies
- The yield drip mechanism smooths distribution, limiting flash-yield
- `capitalPaused` could also be set to block deposits during rebase pause

**Severity:** Low. Requires admin action to create the vulnerable state. The dilution is proportional to new deposits during the pause window.

---

### FINDING-04 [Low]: WOETH ERC4626 Base Lacks Virtual Share Offset

**File:** `/root/defi-audit-targets/audits/origin-protocol/origin-dollar/contracts/lib/openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol`

**Description:**
The ERC4626 base contract is from an early OpenZeppelin draft (PR #3171, pre-release). It lacks the `_decimalsOffset()` / virtual shares mechanism that OpenZeppelin later added to prevent share inflation/deflation attacks. The base `convertToShares` computes `(assets * supply) / totalAssets()` without offset.

**Existing Defense (fully mitigating):**
WOETH overrides ALL conversion functions to use the `adjuster / rebasingCreditsPerTokenHighres()` ratio instead of balance-based math:
```solidity
function convertToShares(uint256 assets) public view virtual override returns (uint256) {
    return (assets * rebasingCreditsPerTokenHighres()) / adjuster;
}
function totalAssets() public view override returns (uint256) {
    return (totalSupply() * adjuster) / rebasingCreditsPerTokenHighres();
}
```
Direct OETH donations to the WOETH contract do NOT affect the exchange rate. The adjuster-based mechanism completely neutralizes the inflation attack class.

**Severity:** Low. The donation attack vector is fully mitigated by WOETH's custom conversion logic. The outdated base code has no functional impact.

---

### FINDING-05 [Informational]: BridgedWOETH burn(address, uint256) Burns Tokens Without Allowance Check

**File:** `/root/defi-audit-targets/audits/origin-protocol/origin-dollar/contracts/contracts/token/BridgedWOETH.sol` (lines 49-55)

**Description:**
`burn(address account, uint256 amount)` allows any BURNER_ROLE holder to burn tokens from ANY account without that account's approval:
```solidity
function burn(address account, uint256 amount) external onlyRole(BURNER_ROLE) nonReentrant {
    _burn(account, amount);  // No allowance check
}
```

**Existing Defense:** BURNER_ROLE is managed by the governor via DEFAULT_ADMIN_ROLE. This is an explicit design choice for bridge burn-and-mint operations.

**Severity:** Informational. Intentional design for cross-chain bridge operations. The trust assumption is documented.

---

### FINDING-06 [Informational]: changeSupply Allows Decreasing Supply (Unused Path)

**File:** `/root/defi-audit-targets/audits/origin-protocol/origin-dollar/contracts/contracts/token/OUSD.sol` (lines 597-626)

**Description:**
`changeSupply` sets `totalSupply` to `_newTotalSupply` without enforcing that it is greater than the current supply. A decrease would increase `rebasingCreditsPerToken_`, reducing rebasing holders' balances. However, the vault's `_rebase()` function (lines 446-468) only calls `changeSupply` when `newSupply > supply` AND `newSupply > oToken.totalSupply()`, so this path is unreachable in practice.

**Severity:** Informational. The function is technically permissive but its only caller enforces the upward-only constraint.

---

### FINDING-07 [Informational]: _autoMigrate May Misclassify Contracts During Constructor

**File:** `/root/defi-audit-targets/audits/origin-protocol/origin-dollar/contracts/contracts/token/OUSD.sol` (lines 477-491)

**Description:**
During a contract's constructor execution, `_account.code.length == 0`. If a deploying contract interacts with OUSD during its constructor with `rebaseState == NotSet` and `alternativeCreditsPerToken == 0`, `_autoMigrate` classifies it as an EOA and skips auto-opt-out. The contract would temporarily participate in rebasing.

**Existing Defense:** On the contract's next interaction (post-deployment), `_autoMigrate` detects the code and auto-opts it out. The EIP-7702 delegation designator check (`codeLen == 23 && bytes3(_account.code) == 0xef0100`) demonstrates awareness of edge cases.

**Severity:** Informational. Limited to one constructor-call window; self-corrects on next interaction.

---

### FINDING-08 [Informational]: Withdrawal Queue Truncation for Non-18-Decimal Assets

**File:** `/root/defi-audit-targets/audits/origin-protocol/origin-dollar/contracts/contracts/vault/VaultCore.sol` (lines 196-198, 336-341)

**Description:**
For vaults with non-18-decimal assets (e.g., USDC with 6 decimals), the `requestWithdrawal` function scales the OToken amount (18 decimals) down to asset decimals via `_amount.scaleBy(assetDecimals, 18)`. This truncates, meaning the user's burned OTokens may exceed the claimable asset value by up to 1 unit of the smallest asset denomination.

Example for USDC: requesting withdrawal of `1.000000000000000001` OUSD (1e18 + 1 wei) burns the full amount but only 1.000000 USDC (1e6) is claimable.

**Severity:** Informational. The truncation is at most 1 wei of the asset denomination (e.g., 0.000001 USDC). This is protocol-favoring truncation and is consistent between the `queued` and `claimed` counters.

---

### FINDING-09 [Informational]: Missing increaseAllowance/decreaseAllowance in OUSD

**File:** `/root/defi-audit-targets/audits/origin-protocol/origin-dollar/contracts/contracts/token/OUSD.sol` (lines 404-408)

**Description:**
OUSD implements only `approve()` without `increaseAllowance()`/`decreaseAllowance()`. Users changing allowances are subject to the classic ERC20 approve race condition.

**Severity:** Informational. Standard ERC20 design limitation. Users can mitigate by setting allowance to 0 before changing it.

---

## Clean Areas and Defenses

### 1. WOETH Adjuster Mechanism (WOETH.sol) -- Excellent

The `adjuster` pattern is the standout design element. By computing exchange rates from `adjuster / rebasingCreditsPerTokenHighres()` instead of actual OETH balances, the contract is immune to donation-based manipulation:

```solidity
function convertToShares(uint256 assets) public view virtual override returns (uint256) {
    return (assets * rebasingCreditsPerTokenHighres()) / adjuster;
}
function convertToAssets(uint256 shares) public view virtual override returns (uint256) {
    return (shares * adjuster) / rebasingCreditsPerTokenHighres();
}
function totalAssets() public view override returns (uint256) {
    return (totalSupply() * adjuster) / rebasingCreditsPerTokenHighres();
}
```

The adjuster is set once during initialization and the exchange rate naturally tracks OETH's rebasing rate. Direct OETH transfers to the contract are ignored. This makes WOETH safe for lending markets and AMM integration.

### 2. Rebasing Credit System (OUSD.sol) -- Excellent

Consistent protocol-favoring rounding throughout:
- `_balanceToRebasingCredits`: rounds UP (`+ 1e18 - 1`)
- `balanceOf`: truncates DOWN (`credits * 1e18 / creditsPerToken`)
- `changeSupply`: rounds `rebasingCreditsPerToken_` UP (`+ rebasingSupply - 1`)
- Total supply capped at `MAX_SUPPLY = type(uint128).max`
- Resolution increase of 1e9 for high-precision accounting

### 3. Yield Drip Mechanism (VaultCore._nextYield) -- Excellent

Triple-capped yield prevents flash-yield attacks and makes WOETH safe for lending:
1. **dripDuration:** Smooths yield over configurable period (default 7 days)
2. **rebasePerSecondMax:** Per-second rate cap (max 5% APR per day)
3. **MAX_REBASE (2%):** Hard per-rebase cap prevents accumulated yield from distributing at once
4. **Elapsed time check:** `elapsed == 0` prevents same-block rebasing

```solidity
yield = _min(yield, targetRate * elapsed);
yield = _min(yield, (rebasing * elapsed * rebasePerSecondMax) / 1e18);
yield = _min(yield, (rebasing * MAX_REBASE) / 1e18);
```

### 4. Reentrancy Protection (Governable.sol) -- Solid

Custom reentrancy guard using a dedicated keccak-hashed storage slot (`keccak256("OUSD.reentry.status")`), compatible with proxy patterns and avoiding storage collisions:

```solidity
bytes32 private constant reentryStatusPosition =
    0x53bf423e48ed90e97d02ab0ebab13b2a235a6bfbe9c321847d5c175333ac4535;
```

Applied consistently across all critical external functions: `mint`, `requestWithdrawal`, `claimWithdrawal`, `claimWithdrawals`, `allocate`, `rebase`, `depositToStrategy`, `withdrawFromStrategy`.

### 5. Withdrawal Queue (VaultCore.sol) -- Solid

Cumulative accounting prevents double-claims and ordering attacks:
- `queued`: cumulative total of all requests (only increases)
- `claimable`: cumulative total that can be claimed (only increases)
- `claimed`: cumulative total actually claimed (only increases)
- Invariant: `claimed <= claimable <= queued`
- `_addWithdrawalQueueLiquidity` correctly bridges the gap between `claimable` and `queued`
- `_assetAvailable` reserves for all outstanding withdrawals
- `_checkBalance` subtracts withdrawal obligations from total value
- `withdrawalClaimDelay` enforced on every claim

### 6. Access Control -- Well-layered

Clear hierarchy across all contracts:
- **Governor (onlyGovernor):** Strategy approval/removal, fee settings, initializers, pause controls
- **Strategist (onlyGovernorOrStrategist):** Operational allocation, vault buffer, rebase rate configuration
- **Vault (onlyVault):** Token mint/burn/changeSupply
- **Two-step governance:** `transferGovernance` + `claimGovernance` with pending governor pattern
- **Yield delegation:** `onlyGovernorOrStrategist` with comprehensive bidirectional link validation

### 7. Proxy Architecture -- Safe

- EIP-1967 compliant implementation slot
- All sensitive state (governor, pendingGovernor, reentrancy) in keccak-hashed slots
- `Address.isContract` validation on implementation
- `onlyGovernor` on all upgrade paths
- Storage gaps in VaultStorage (`uint256[42] __gap`) and OUSD (`uint256[34] __gap`)

### 8. Token Yield Delegation (OUSD.sol) -- Correct

The delegation system handles all 5 `RebaseOptions` states correctly:
- **NotSet:** Auto-migrated on first interaction
- **StdNonRebasing:** Fixed 1e18 creditsPerToken
- **StdRebasing:** Uses global rebasingCreditsPerToken_
- **YieldDelegationSource:** Balance stored directly, yield forwarded to target
- **YieldDelegationTarget:** Credits include delegated balance, excess above own balance is the target's

The `_adjustAccount` function correctly handles all state transitions:
- Source transfer: recalculates target credits for `targetOldBalance + sourceNewBalance`
- Target transfer: recalculates credits for `targetNewBalance + sourceBalance`
- `_adjustGlobals` atomically updates both `rebasingCredits_` and `nonRebasingSupply`

### 9. VaultCore `_postRedeem` Insolvency Protection -- Solid

```solidity
uint256 diff = oToken.totalSupply().divPrecisely(totalUnits);
require(
    (diff > 1e18 ? diff - 1e18 : 1e18 - diff) <= maxSupplyDiff,
    "Backing supply liquidity error"
);
```

This ensures `|totalSupply/totalValue - 1| <= maxSupplyDiff`, preventing the vault from becoming significantly over- or under-collateralized during redemptions.

### 10. Fee Collection in _rebase -- Correct

The sequence `mint fee -> then changeSupply` is correctly ordered:
1. Calculate `yield` and `newSupply = supply + yield`
2. Mint fee tokens to trustee (increases totalSupply by fee)
3. Check `newSupply > oToken.totalSupply()` (now `supply + fee`), which holds since `fee < yield` (enforced by `require(fee < yield)`)
4. `changeSupply(newSupply)` distributes remaining yield to rebasing holders

The trustee fee is bounded at 50% (`trusteeFeeBps <= 5000`), ensuring `fee < yield` always holds.

---

## Architecture Analysis

### Inheritance Chain

```
Governable (reentrancy guard + governance via keccak slots)
  |
  +-- Initializable (proxy init guard)
        |
        +-- VaultStorage (state variables, immutable asset)
              |
              +-- VaultInitializer (initialize function)
                    |
                    +-- VaultCore (mint, rebase, withdrawal queue, allocate)
                          |
                          +-- VaultAdmin (strategy management, fees, pause)
                                |
                                +-- OETHVault (WETH)
                                +-- OUSDVault (USDC)
                                +-- OETHBaseVault (WETH on Base)
                                +-- OSVault (wS on Sonic)
                                +-- OETHPlumeVault (WETH on Plume)

OUSD (rebasing token, all credit/rebase logic)
  +-- OETH
  +-- OETHBase
  +-- OETHPlume
  +-- OSonic

WOETH (ERC4626, adjuster-based, Governable, Initializable)
  +-- WOETHBase (wsuperOETHb)
  +-- WOETHPlume (wsuperOETHp)
  +-- WOSonic (wOS)
  +-- WrappedOusd (WOUSD)

BridgedWOETH (ERC20 + AccessControl, mint/burn for bridges)
```

### Key Design Decisions

1. **Single-asset vaults:** Each vault supports exactly one asset (immutable). Simplifies accounting, eliminates multi-asset oracle risks.

2. **No direct redeem:** Users exit only through the async withdrawal queue (`requestWithdrawal` + `claimWithdrawal`). Prevents bank runs and gives time for strategy unwinding.

3. **1:1 OToken minting:** OTokens are minted equal to the scaled asset amount. No share-price mechanism in the vault. Yield accrues through the rebasing mechanism.

4. **WOETH as DeFi-composable layer:** Wraps rebasing OETH into non-rebasing ERC4626 using the adjuster mechanism. Safe for lending markets, AMMs, and other integrations.

5. **Strategy mint/burn whitelist:** AMO strategies can mint/burn OTokens directly (for pool liquidity operations) with double access control (approved + whitelisted).

---

## Conclusion

The Origin Protocol vault and token contracts are well-engineered with mature security practices. The primary finding (FINDING-01, Medium) is a function signature mismatch in OETHPlumeVault that renders an access control restriction inert. The remaining findings are low/informational in severity.

The WOETH adjuster mechanism, yield drip system, and rebasing credit accounting demonstrate sophisticated design. The consistent protocol-favoring rounding, withdrawal queue with cumulative accounting, and multi-layered access control provide strong defenses against known DeFi attack vectors.

No findings warrant Immunefi submission at the Critical tier. FINDING-01 may warrant a High-tier submission if the Plume vault is deployed with `capitalPaused = false` in production, but this depends on the actual deployment configuration.
