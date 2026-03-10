# JustLend DAO: Deployed Contracts vs GitHub Source Code Analysis

**Date:** 2026-03-03
**Network:** TRON Mainnet
**GitHub Source:** justlend-protocol repository (Solidity ^0.5.12 / ^0.5.16)

## Methodology

Source code retrieval was attempted via multiple TronScan API endpoints:
- `https://apilist.tronscanapi.com/api/contract?contract={address}` -- metadata only
- `https://apilist.tronscanapi.com/api/contracts/code?contract={address}` -- bytecode + ABI
- `https://api.trongrid.io/wallet/getcontract` -- bytecode + full ABI (best data source)
- TronScan web UI (`tronscan.org/#/contract/{address}/code`) -- returns 403 (SPA, requires browser JS)

**TronScan does NOT expose verified source code via any public API.** The API returns bytecode and ABI, but not the original Solidity source code. This is a known limitation (confirmed by TRON DAO forum). Comparison was performed by matching deployed ABI signatures against GitHub source function/event declarations.

---

## Contract 1: Comptroller (Implementation)

| Field | Value |
|-------|-------|
| Address | `TCtzg2CQsAuLkSxrGjFGbHVwKvv95W9C8e` |
| Verify Status | 2 (verified) |
| Is Proxy | false (this IS the implementation) |
| Creator | `TH2h5NBfPz7hg9wF2cmXyCsYcmaVwo9xyS` |
| Created | 2023-01-11 |
| Active Days | 2 (deployed as upgrade impl) |
| Deployed ABI Entries | 88 |
| Bytecode Length | 33,816 hex chars (~16.9 KB) |
| Code Hash | `52a0b8f5e2dbd736cb13a9a6cf1ad3c5b474fdaa101cbcd80125e06c8aa1d403` |
| GitHub File | `contracts/Comptroller.sol` (Solidity ^0.5.12) |

### CRITICAL FINDING: Deployed Comptroller has 8 functions and 4 events NOT in GitHub

**Functions added in deployed contract (not in any GitHub .sol file):**

1. `_setBorrowCapGuardian(address newBorrowCapGuardian)` -- Sets the borrow cap guardian
2. `_setMarketBorrowCaps(address[] cTokens, uint256[] newBorrowCaps)` -- Sets borrow caps per market
3. `borrowCapGuardian() view` -- Returns borrow cap guardian address
4. `borrowCaps(address) view` -- Returns borrow cap for a market
5. `_setCollateralFactorGuardian(address newCollateralFactorGuardian)` -- Sets collateral factor guardian
6. `_setCollateralFactorGuardianStateForMarket(address cToken, bool state)` -- Enables/disables CF guardian per market
7. `collateralFactorGuardian() view` -- Returns collateral factor guardian address
8. `collateralFactorGuardianMarkets(address) view` -- Returns guardian state per market

**Events added in deployed contract:**

1. `NewBorrowCap(address cToken, uint256 newBorrowCap)`
2. `NewBorrowCapGuardian(address oldBorrowCapGuardian, address newBorrowCapGuardian)`
3. `NewCollateralFactorGuardian(address oldGuardian, address newGuardian)`
4. `ActionSupportedCollateralFactorGuardian(address cToken, bool state)`

**Function signature difference:**

- GitHub: `_become(Unitroller unitroller, address[] memory otherMarketsToAdd)` -- selector for `_become(address,address[])`
- Deployed: `_become(address unitroller)` -- selector `1d504dc6` for `_become(address)`
- The deployed version removed the `otherMarketsToAdd` parameter entirely.

### Assessment

The deployed Comptroller is a **significantly newer version** than what is on GitHub. It includes:
- **Borrow cap system** (from Compound's later upgrades) allowing per-market borrow limits
- **Collateral factor guardian system** (JustLend custom) allowing a guardian to manage collateral factors per market
- **Simplified `_become`** function

The GitHub repository represents an older version of the Comptroller (circa Compound v2.5), while the deployed contract (January 2023) includes features from Compound v2.8+ plus JustLend-specific additions.

**The ComptrollerStorage.sol on GitHub only goes up to V3Storage. The deployed contract must use V4+ or V5+ storage with additional state variables for borrow caps and collateral factor guardian.**

---

## Contract 2: Unitroller (Proxy)

| Field | Value |
|-------|-------|
| Address | `TGjYzgCyPobsNS9n6WcbdLVR9dH7mWqFx7` |
| Verify Status | 2 (verified) |
| Is Proxy | true (delegatecall proxy) |
| Blue Tag | JustLend DAO (justlend.org) |
| Creator | `TV3Wg2zNUBzGJsJNCEUZ2W9YVsFK2AAcLB` |
| Created | 2020-12-05 |
| Active Days | 1,914 |
| Balance | 1,000,085 TRX |
| Deployed ABI Entries | 15 |
| Bytecode Length | 3,582 hex chars |
| Code Hash | `4fbb642118d75daca3408a821c88aeca40815f8a0e63dcf8ed52ce5f58351f2f` |
| GitHub File | `contracts/Unitroller.sol` (Solidity ^0.5.12) |

### MATCH

The deployed Unitroller ABI exactly matches the GitHub source:

- `constructor()`
- `fallback() payable` (delegatecall to `comptrollerImplementation`)
- `_setPendingImplementation(address)` -- admin only
- `_acceptImplementation()` -- pending impl only
- `_setPendingAdmin(address)` -- admin only
- `_acceptAdmin()` -- pending admin only
- `admin() view`
- `pendingAdmin() view`
- `comptrollerImplementation() view`
- `pendingComptrollerImplementation() view`
- Events: `Failure`, `NewAdmin`, `NewImplementation`, `NewPendingAdmin`, `NewPendingImplementation`

**Pattern:** Standard Compound Unitroller proxy. All calls not matching the 4 admin functions are forwarded via `delegatecall` to the Comptroller implementation.

---

## Contract 3: PriceOracle (V1)

| Field | Value |
|-------|-------|
| Address | `TD8bq1aFY8yc9nsD2rfqqJGDtkh7aPpEpr` |
| Verify Status | 2 (verified) |
| Is Proxy | false |
| Creator | `TV3Wg2zNUBzGJsJNCEUZ2W9YVsFK2AAcLB` |
| Deployed ABI Entries | 29 |
| Bytecode Length | 13,308 hex chars |
| Code Hash | `91a6f4b203e51971fcf59fdf1fb9f24ccb28f074232989c50244950f1c41ff00` |
| GitHub File | `contracts/PriceOracle/PriceOracleV1.sol` (Solidity ^0.5.12) |

### MATCH

The deployed PriceOracle ABI exactly matches `PriceOracleV1.sol` on GitHub:

- `constructor(address _poster, address addr0, address reader0, address addr1, address reader1)`
- `fallback() payable` (reverts)
- `_acceptAnchorAdmin()`, `_setPaused(bool)`, `_setPendingAnchor(address,uint256)`, `_setPendingAnchorAdmin(address)`
- `setPrice(address,uint256)`, `setPrices(address[],uint256[])`
- `assetPrices(address)`, `getPrice(address)`
- All getters: `anchorAdmin`, `pendingAnchorAdmin`, `poster`, `paused`, `maxSwing`, `maxSwingMantissa`, `numBlocksPerPeriod`, `readers(address)`, `anchors(address)`, `pendingAnchors(address)`, `_assetPrices(address)`
- Events: `CappedPricePosted`, `Failure`, `NewAnchorAdmin`, `NewPendingAnchor`, `NewPendingAnchorAdmin`, `OracleFailure`, `PricePosted`, `SetPaused`

**Note:** This is the V1 oracle with poster-based pricing and anchor swing caps (max 10% deviation). NOT a Chainlink-based oracle.

---

## Contract 4: GovernorBravoDelegate

| Field | Value |
|-------|-------|
| Address | `TCiQTkxhzwSeXhRsNdHCvrxHRAvpjQn5Dt` |
| Verify Status | 2 (verified) |
| Is Proxy | true |
| Implementation | `T9yD14Nj9j7xAB4dbGeiX9h8unkKHxuWwb` |
| Creator | `TKX2r9eUNZbsCf7KBfPoqAej45csiXMkmA` |
| Created | October 2022 |
| Deployed ABI Entries | 59 |
| Bytecode Length | 41,970 hex chars |
| Code Hash | `34c1c960d482b5e5361ff861c8ef449728b43792364186506f2fba9f15e70f82` |
| GitHub File | `contracts/Governance/Bravo/GovernorBravoDelegate.sol` (Solidity ^0.5.16) |

### MATCH

The deployed GovernorBravoDelegate ABI exactly matches the GitHub source:

- All 8 constants (MIN/MAX_PROPOSAL_THRESHOLD, MIN/MAX_VOTING_DELAY, MIN/MAX_VOTING_PERIOD, BALLOT_TYPEHASH, DOMAIN_TYPEHASH)
- `initialize(address,address,uint256,uint256,uint256)` -- timelock, wjst, votingPeriod, votingDelay, proposalThreshold
- `propose`, `queue`, `execute`, `cancel`, `state`, `getActions`, `getReceipt`
- `castVote(uint256,uint256,uint8)` -- JustLend custom: takes explicit votes parameter
- `castVoteWithReason(uint256,uint256,uint8,string)` -- same votes parameter
- `castVoteBySig(uint256,uint256,uint8,uint8,bytes32,bytes32)` -- same votes parameter
- Admin: `_initiate`, `_setPendingAdmin`, `_acceptAdmin`, `_setVotingDelay`, `_setVotingPeriod`, `_setProposalThreshold`, `_setWhitelistAccountExpiration`, `_setWhitelistGuardian`

**JustLend customization:** The `castVote` function takes `(uint256 proposalId, uint256 votes, uint8 support)` -- the `votes` parameter is explicit, unlike standard Compound GovernorBravo which reads votes from the governance token. This integrates with `wjst.voteFresh()` for vote tracking.

---

## Contract 5: CEther (jTRX)

| Field | Value |
|-------|-------|
| Address | `TE2RzoSV3wFK99w6J9UnnZ4vLfXYoxvRwP` |
| Verify Status | 2 (verified) |
| Is Proxy | false |
| Token | jTRX (TRC20, 8 decimals) |
| Creator | `TV3Wg2zNUBzGJsJNCEUZ2W9YVsFK2AAcLB` |
| Created | 2020-12-05 |
| Active Days | 1,914 |
| Total Transactions | 477,434 |
| Deployed ABI Entries | 69 |
| Bytecode Length | 51,124 hex chars |
| Code Hash | `6186eb3e0b4a7f0fccabc36ae29fcab481cadc7f620e560cf75ef1e0aca62105` |
| GitHub File | `contracts/CEther.sol` + `contracts/CToken.sol` (Solidity ^0.5.12) |

### MATCH

The deployed CEther ABI matches the GitHub source exactly:

- Constructor: `(address comptroller_, address interestRateModel_, uint256 initialExchangeRateMantissa_, string name_, string symbol_, uint8 decimals_, address admin_, address reserveAdmin_, uint256 newReserveFactorMantissa_)` -- includes `reserveAdmin` (JustLend addition)
- `mint() payable`, `redeem(uint256)`, `redeemUnderlying(uint256)`, `borrow(uint256)`
- `repayBorrow(uint256) payable`, `repayBorrowBehalf(address) payable`
- `liquidateBorrow(address, address) payable`, `_addReserves() payable`
- `fallback() payable` (auto-mints)
- All CToken functions: `transfer`, `transferFrom`, `approve`, `allowance`, `balanceOf`, `balanceOfUnderlying`, `getAccountSnapshot`, `borrowRatePerBlock`, `supplyRatePerBlock`, `totalBorrowsCurrent`, `borrowBalanceCurrent`, `borrowBalanceStored`, `exchangeRateCurrent`, `exchangeRateStored`, `getCash`, `accrueInterest`, `seize`
- Admin: `_setPendingAdmin`, `_acceptAdmin`, `_setComptroller`, `_setReserveFactor`, `_reduceReserves`, `_setInterestRateModel`, `_setReserveAdmin`
- JustLend custom events: `JTokenBalance`, `JTokenStatus`

**JustLend customizations vs standard Compound:**
- `reserveAdmin` role for reserve management (separate from admin)
- `JTokenBalance` and `JTokenStatus` events for frontend tracking
- `repayBorrow(uint256 amount)` takes explicit amount with overpayment refund (msg.value >= amount)

---

## Contract 6: CErc20Delegate (USDT Implementation)

| Field | Value |
|-------|-------|
| Address | `TLjn59xNM7VEK6VZ3VQ8Y1ipxsdsFka5wZ` |
| Verify Status | 2 (appears verified) |
| Is Proxy | No (IS the delegate impl) |
| Creator | `TV3Wg2zNUBzGJsJNCEUZ2W9YVsFK2AAcLB` |
| Created | 2020-12-06 |
| Deployed ABI Entries | 73 |
| Bytecode Length | 43,848 hex chars |
| Code Hash | `8032e2ead8bbc02a69a95e4a6e9d034bc0adebcbd6704d9d1401ed5c5d6f63d8` |
| GitHub Files | `contracts/CErc20Delegate.sol` + `contracts/CErc20.sol` + `contracts/CToken.sol` |

### MATCH

The deployed CErc20Delegate ABI matches the GitHub source:

- `constructor()` (empty)
- `_becomeImplementation(bytes)`, `_resignImplementation()`
- Two `initialize` overloads:
  - 7-param: `(address comptroller_, address interestRateModel_, uint256 initialExchangeRateMantissa_, string name_, string symbol_, uint8 decimals_, uint256 newReserveFactorMantissa_)` -- from CToken
  - 8-param: `(address underlying_, address comptroller_, address interestRateModel_, uint256 initialExchangeRateMantissa_, string name_, string symbol_, uint8 decimals_, uint256 newReserveFactorMantissa_)` -- from CErc20
- All standard CErc20 functions: `mint(uint256)`, `redeem`, `borrow`, `repayBorrow(uint256)`, `repayBorrowBehalf(address,uint256)`, `liquidateBorrow(address,uint256,address)`, `_addReserves(uint256)`
- All CToken functions and admin functions
- `implementation() view`, `underlying() view`

---

## Summary Table

| Contract | Address | Proxy | Matches GitHub | Key Differences |
|----------|---------|-------|----------------|-----------------|
| Comptroller (impl) | `TCtzg...C8e` | No (is impl) | **NO** | 8 new functions, 4 new events, modified `_become` signature |
| Unitroller (proxy) | `TGjYz...Fx7` | Yes (delegatecall) | Yes | -- |
| PriceOracle V1 | `TD8bq...Apr` | No | Yes | -- |
| GovernorBravoDelegate | `TCiQT...5Dt` | Yes (delegator) | Yes | -- |
| CEther (jTRX) | `TE2Rz...RwP` | No | Yes | -- |
| CErc20Delegate (USDT) | `TLjn5...5wZ` | No (is impl) | Yes | -- |

## Critical Audit Implications

### 1. The deployed Comptroller contains unauditable code

The Comptroller implementation at `TCtzg2CQsAuLkSxrGjFGbHVwKvv95W9C8e` has **8 functions and 4 events that do not exist anywhere in the GitHub repository**. This means:

- **Borrow cap logic** (`_setMarketBorrowCaps`, `borrowCaps`, `borrowAllowed` enforcement) -- source unknown
- **Collateral factor guardian system** (`_setCollateralFactorGuardian`, `collateralFactorGuardianMarkets`) -- entirely JustLend custom, source unknown
- **The `_become` function was modified** -- old version took market array, new takes only address

Without the actual source code, we cannot audit:
- Whether borrow cap enforcement in `borrowAllowed()` has any bypass
- Whether the collateral factor guardian can manipulate factors without timelock
- Whether the storage layout is correctly extended (V4/V5 storage must not collide with V3)
- Whether the simplified `_become` has proper initialization

### 2. PriceOracle uses centralized poster model

The deployed PriceOracle is V1 (poster-based), not a decentralized oracle. A single `poster` address controls all asset prices, subject only to:
- 10% max swing cap per period
- Anchor price mechanism
- Admin can pause

### 3. Proxy architecture summary

```
User -> Unitroller (proxy, TGjYz...Fx7)
           |
           | delegatecall
           v
         Comptroller (impl, TCtzg...C8e) [DIVERGES FROM GITHUB]
```

```
User -> GovernorBravoDelegator (proxy, TCiQT...5Dt)
           |
           | delegatecall
           v
         GovernorBravoDelegate (impl, T9yD1...Wwb)
```

CEther and CErc20Delegate are NOT proxied (CErc20Delegate is used BY CErc20Delegator proxies for specific markets like USDT).
