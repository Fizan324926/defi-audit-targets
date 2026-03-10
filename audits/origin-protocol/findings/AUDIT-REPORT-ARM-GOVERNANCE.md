# Origin Protocol ARM & Governance/xOGN Security Audit Report

**Date:** 2026-03-02
**Auditor:** Senior Smart Contract Security Auditor
**Scope:** ARM contracts (arm-oeth) + Governance/xOGN contracts (ousd-governance)
**Immunefi Bounty:** Max $1M (Critical), $15K (High)

---

## Executive Summary

The Origin Protocol ARM (Automated Redemption Manager) and Governance/xOGN contracts are well-engineered
with strong defensive patterns. The ARM system uses a dual-pricing AMM with fixed spreads, an ERC-4626-like
LP interface with async withdrawals, and optional lending market integration. The xOGN staking uses
exponential voting power with proper checkpoint-based governance.

**Total Findings: 0 exploitable, 3 Low, 5 Informational**

No Critical or High severity vulnerabilities were found. The codebase demonstrates careful engineering
with proper dead-share initialization, cross-price bounds, fee accounting, and checkpoint-based voting.

---

## Findings

### FINDING-01 [Low] SonicHarvester: Swapped Assets Not Transferred When priceProvider Is Zero

**File:** `/root/defi-audit-targets/audits/origin-protocol/arm-oeth/src/contracts/SonicHarvester.sol`
**Lines:** 141-157

**Description:**
When `priceProvider == address(0)`, the `swap()` function returns early at line 142 without transferring
the swapped liquidity assets to `rewardRecipient`. The swap execution and balance validation complete
successfully, but the swapped tokens remain stranded in the SonicHarvester contract.

```solidity
// Line 121-157 (relevant excerpt)
function swap(
    SwapPlatform swapPlatform,
    address fromAsset,
    uint256 fromAssetAmount,
    uint256 fees,
    bytes calldata data
) external onlyOperatorOrOwner returns (uint256 toAssetAmount) {
    uint256 liquidityAssetsBefore = IERC20(liquidityAsset).balanceOf(address(this));

    // Validate the swap data and do the swap
    toAssetAmount = _doSwap(swapPlatform, fromAsset, fromAssetAmount, fees, data);

    // Check this Harvester got the reported amount of liquidity assets
    uint256 liquidityAssetsReceived = IERC20(liquidityAsset).balanceOf(address(this)) - liquidityAssetsBefore;
    if (liquidityAssetsReceived < toAssetAmount) {
        revert BalanceMismatchAfterSwap(liquidityAssetsReceived, toAssetAmount);
    }

    emit RewardTokenSwapped(fromAsset, liquidityAsset, swapPlatform, fromAssetAmount, toAssetAmount);

    // If there is no price provider, we exit early
    if (priceProvider == address(0)) return toAssetAmount;  // <-- returns WITHOUT transfer

    // ... slippage check ...

    // Transfer the liquidity assets to the reward recipient
    IERC20(liquidityAsset).safeTransfer(rewardRecipient, toAssetAmount);  // <-- never reached
}
```

The SonicHarvester does NOT inherit from Abstract4626MarketWrapper and has NO `transferTokens` rescue
function. The only way to recover stranded assets would be to set a non-zero `priceProvider` and
call `swap()` again (but the previous swap's output is already in the contract and could be
double-counted with the next swap's output).

**Impact:** Swapped reward tokens accumulate in the harvester when no price provider is configured.
Not permanently lost (setting `priceProvider` to non-zero then calling another swap would trigger
transfer of all liquidity assets), but the automatic reward flow is broken.

**Severity:** Low. The `priceProvider` is set during `initialize()` and is expected to be non-zero
for normal operation. The operator controls swaps, so they would notice the issue. However, the
`setPriceProvider` function accepts `address(0)` without warning.

**Recommendation:** Move the transfer before the price provider check:

```solidity
emit RewardTokenSwapped(fromAsset, liquidityAsset, swapPlatform, fromAssetAmount, toAssetAmount);

// Transfer the liquidity assets to the reward recipient
IERC20(liquidityAsset).safeTransfer(rewardRecipient, toAssetAmount);

// If there is no price provider, skip slippage check
if (priceProvider == address(0)) return toAssetAmount;

// ... slippage check ...
```

---

### FINDING-02 [Low] LidoARM/EtherFiARM: Withdrawal Request Mappings Not Cleared After Claim

**Files:**
- `/root/defi-audit-targets/audits/origin-protocol/arm-oeth/src/contracts/LidoARM.sol` lines 144-172
- `/root/defi-audit-targets/audits/origin-protocol/arm-oeth/src/contracts/EtherFiARM.sol` lines 110-138

**Description:**
When `claimLidoWithdrawals()` or `claimEtherFiWithdrawals()` processes withdrawal claims, the
per-request storage (`lidoWithdrawalRequests[requestId]` / `etherfiWithdrawalRequests[requestId]`)
is never zeroed out after the claim. The code relies entirely on the external protocol (Lido/EtherFi)
to prevent double-claims.

```solidity
// LidoARM.sol:144-171
function claimLidoWithdrawals(uint256[] calldata requestIds, uint256[] calldata hintIds) external {
    lidoWithdrawalQueue.claimWithdrawals(requestIds, hintIds);  // External revert prevents double-claim

    uint256 totalAmountRequested = 0;
    for (uint256 i = 0; i < requestIds.length; i++) {
        uint256 requestAmount = lidoWithdrawalRequests[requestIds[i]];
        require(requestAmount > 0, "LidoARM: invalid request");
        totalAmountRequested += requestAmount;
        // NOTE: lidoWithdrawalRequests[requestIds[i]] is never deleted
    }

    lidoWithdrawalQueueAmount -= totalAmountRequested;
    weth.deposit{value: address(this).balance}();
}
```

If the external protocol ever changed behavior or had a bug allowing re-claiming, the ARM's
`lidoWithdrawalQueueAmount` / `etherfiWithdrawalQueueAmount` would underflow (Solidity 0.8 revert),
or if it were unchecked, would corrupt the `_externalWithdrawQueue()` calculation and consequently
`totalAssets()`.

**Severity:** Low. Defense-in-depth gap. The external protocols (Lido, EtherFi) reliably prevent
double-claims. The underflow on `lidoWithdrawalQueueAmount` would actually provide a secondary
safety net (transaction reverts).

**Recommendation:** Add deletion after processing each claim:

```solidity
for (uint256 i = 0; i < requestIds.length; i++) {
    uint256 requestAmount = lidoWithdrawalRequests[requestIds[i]];
    require(requestAmount > 0, "LidoARM: invalid request");
    totalAmountRequested += requestAmount;
    delete lidoWithdrawalRequests[requestIds[i]];  // defense-in-depth
}
```

---

### FINDING-03 [Low] ZapperARM/ZapperLidoARM: Uses address(this).balance Instead of msg.value

**Files:**
- `/root/defi-audit-targets/audits/origin-protocol/arm-oeth/src/contracts/ZapperARM.sol` lines 30-41
- `/root/defi-audit-targets/audits/origin-protocol/arm-oeth/src/contracts/ZapperLidoARM.sol` lines 38-48

**Description:**
Both Zapper contracts use `address(this).balance` instead of `msg.value` when wrapping ETH and
depositing to the ARM. If any ETH is sent directly to the Zapper contract (via `selfdestruct` from
another contract, coinbase reward, or accidental transfer), the next legitimate depositor would
unknowingly include that stale ETH in their deposit and receive shares for the full amount.

```solidity
// ZapperARM.sol:30-37
function deposit(address arm) public payable returns (uint256 shares) {
    uint256 balance = address(this).balance;  // <-- includes any stale ETH
    wrappedCurrency.deposit{value: balance}();
    wrappedCurrency.approve(arm, balance);
    shares = ILiquidityProviderARM(arm).deposit(balance, msg.sender);
}
```

Note: `ZapperLidoARM` has a `receive()` function that calls `deposit()`, so accidental ETH sends
via regular transfers would trigger a deposit immediately. However, `selfdestruct` bypasses
`receive()` and would leave ETH stranded.

**Severity:** Low. The next depositor gets a windfall (more shares than expected). The sender of
stale ETH loses funds. No protocol loss. `selfdestruct` is the only reliable way to force-send
ETH to a contract without triggering `receive()`.

**Recommendation:** Use `msg.value` instead of `address(this).balance`:
```solidity
wrappedCurrency.deposit{value: msg.value}();
wrappedCurrency.approve(arm, msg.value);
shares = ILiquidityProviderARM(arm).deposit(msg.value, msg.sender);
```

---

### FINDING-04 [Informational] ExponentialStaking._collectRewards: Missing Explicit Return

**File:** `/root/defi-audit-targets/audits/origin-protocol/ousd-governance/contracts/ExponentialStaking.sol`
**Lines:** 200-223

**Description:**
The `_collectRewards` function has a code path where `shouldRetainRewards == false` and `netRewards > 0`
that falls through without an explicit `return` statement. Solidity returns 0 by default for the
`uint256` return type, which is the correct behavior (rewards were sent to user, 0 should be retained).

```solidity
function _collectRewards(address user, bool shouldRetainRewards) internal returns (uint256) {
    // ...
    if (netRewards == 0) {
        return 0;
    }
    emit Reward(user, netRewards);
    if (shouldRetainRewards) {
        return netRewards;
    } else {
        asset.transfer(user, netRewards);
        // <-- implicit return 0
    }
}
```

This is used at line 126: `newAmount += _collectRewards(to, stakeRewards)` where `stakeRewards=false`
means rewards are sent to the user and 0 is correctly added to `newAmount`.

**Severity:** Informational. Implicit return of 0 is correct but not explicit. Recommend adding
`return 0;` after the transfer for clarity.

---

### FINDING-05 [Informational] FixedRateRewardsSource: Rate Change Without Prior Collection Pays Past Time at New Rate

**File:** `/root/defi-audit-targets/audits/origin-protocol/ousd-governance/contracts/FixedRateRewardsSource.sol`
**Lines:** 127-142

**Description:**
When `setRewardsPerSecond` is called with a nonzero-to-nonzero rate change, the time since
`lastCollect` is paid at the NEW rate rather than the old rate. The code comments acknowledge
this (lines 137-138): "Other than transitions from zero, this contract will pay out past rewards
time at the new rate. Call collectRewards before changing rates if you care about precise reward
accuracy."

**Severity:** Informational. Documented and accepted behavior. The `collectRewards` call before
rate changes is the recommended mitigation.

---

### FINDING-06 [Informational] EthenaARM: nextUnstakerIndex Not Reset on setUnstakers

**File:** `/root/defi-audit-targets/audits/origin-protocol/arm-oeth/src/contracts/EthenaARM.sol`
**Lines:** 148-153

**Description:**
When `setUnstakers()` replaces the entire unstaker array, `nextUnstakerIndex` retains its previous
value. If the new array has fewer valid (non-zero) entries or a different layout, the round-robin
index could point to `address(0)` entries, causing `requestBaseWithdrawal` to revert until the
index wraps around to valid entries.

```solidity
function setUnstakers(address[MAX_UNSTAKERS] calldata _unstakers) external onlyOwner {
    require(_unstakers.length == MAX_UNSTAKERS, "EthenaARM: Invalid unstakers length");
    unstakers = _unstakers;
    // nextUnstakerIndex is NOT reset to 0
}
```

**Severity:** Informational. The `require(unstaker != address(0))` check in `requestBaseWithdrawal`
prevents any funds at risk. Operational inconvenience only.

---

### FINDING-07 [Informational] Abstract4626MarketWrapper: merkleClaim Has No Access Control

**File:** `/root/defi-audit-targets/audits/origin-protocol/arm-oeth/src/contracts/markets/Abstract4626MarketWrapper.sol`
**Lines:** 156-170

**Description:**
The `merkleClaim()` function can be called by anyone. It claims tokens from the Merkle Distributor
on behalf of the wrapper contract. Claimed tokens land in the wrapper contract, not with the caller.

**Severity:** Informational. Permissionless claiming is beneficial. The Merkle proof validates
the claim, and tokens go to the wrapper where they can be collected by the harvester.

---

### FINDING-08 [Informational] Proxy.sol: Standard but Notable Initialization Pattern

**File:** `/root/defi-audit-targets/audits/origin-protocol/arm-oeth/src/contracts/Proxy.sol`
**Lines:** 38-47

**Description:**
`Proxy.initialize()` executes a `delegatecall` to the logic contract before changing the owner
via `_setOwner(_initOwner)`. The `onlyOwner` modifier ensures only the deployer can call it, and
the `require(_implementation() == address(0))` prevents re-initialization. The delegatecall
occurs in a controlled context.

**Severity:** Informational. Standard proxy initialization pattern, no vulnerability.

---

## Clean Areas (Verified Secure)

### ARM Core (AbstractARM.sol) -- CLEAN

- **First-depositor attack:** Mitigated by 1e12 dead shares to `DEAD_ACCOUNT` at initialization.
  An attacker would need to donate >1e12 assets to move share price by 1 wei. Economically infeasible.
- **Share/asset conversion:** `convertToShares` and `convertToAssets` use `totalAssets()` which has a
  floor of `MIN_TOTAL_SUPPLY` (1e12), preventing division by near-zero.
- **Cross-price invariant:** `MAX_CROSS_PRICE_DEVIATION = 20e32` (0.2% = 20 bps) limits how much
  the cross price can deviate from 1.0. Buy prices must be below crossPrice; sell prices must be
  above. This prevents the ARM from accumulating a net trading loss.
- **Fee accounting:** `collectFees()` correctly updates `lastAvailableAssets` before checking for
  zero fees. Deposits and redeems properly adjust `lastAvailableAssets` by exact amounts, preventing
  fee double-counting or phantom fee accrual.
- **Withdrawal queue integrity:** The FIFO queue with `withdrawsQueued`/`withdrawsClaimed` correctly
  reserves liquidity for pending claims. `_requireLiquidityAvailable` protects against swaps
  draining reserved liquidity. The optimization (skip balance check when no outstanding withdrawals)
  is safe because without pending claims, all liquidity is available.
- **Claim loss protection:** `claimRedeem` uses `min(request.assets, convertToAssets(request.shares))`
  to protect against overpayment if the ARM suffered a loss (e.g., slashing) after the redeem request.
  Backwards-compatible with pre-upgrade requests where `shares == 0`.
- **Swap rounding:** `_swapTokensForExactTokens` adds +3 to `amountIn` (1 for integer truncation,
  2 for stETH transfer shortfall), always rounding in the ARM's favor.
- **No reentrancy risk:** All tokens used (WETH, stETH, eETH, USDe, sUSDe) are standard ERC-20
  without transfer hooks. Transfer pattern is pull-then-push, minimizing reentrancy surface. No
  reentrancy guard is needed given the token set.
- **Operator price bounds:** `setPrices` enforces `sellT1 >= crossPrice` and `buyT1 < crossPrice`,
  preventing the operator from setting prices that cause the ARM to trade at a loss relative to
  the anchor price.
- **setCrossPrice safety:** When lowering crossPrice, requires `baseAsset.balanceOf < MIN_TOTAL_SUPPLY`,
  preventing loss from selling base assets below their purchase price.

### ARM Lending Market Integration -- CLEAN

- **Market validation:** `addMarkets` verifies `IERC4626(market).asset() == liquidityAsset`.
- **Buffer allocation:** `armBuffer` percentage determines how much liquidity stays in the ARM vs.
  the lending market. `allocateThreshold` prevents deposit/withdraw flipping from rounding.
- **Active market switching:** `setActiveMarket` properly redeems all shares from the previous market
  before setting a new one. Acknowledged: can fail during high utilization.
- **Market wrapper authorization:** `Abstract4626MarketWrapper` enforces `msg.sender == arm` on
  deposit, withdraw, and redeem functions. Market shares cannot be extracted by unauthorized parties.
- **Reward collection:** Market wrapper `collectRewards` restricted to `harvester` address.
  `transferTokens` restricted to owner with additional receiver checks.

### LidoARM -- CLEAN

- **Withdrawal tracking:** `lidoWithdrawalQueueAmount` tracks total outstanding requests.
  Individual amounts stored in `lidoWithdrawalRequests` mapping for per-claim validation.
- **NFT transfer protection:** `require(requestAmount > 0)` prevents processing withdrawal NFTs
  that were transferred in from other accounts (would have no entry in the mapping).
- **ETH wrapping:** `weth.deposit{value: address(this).balance}()` wraps all received ETH after
  claims. The `receive()` function enables ETH reception from Lido.
- **registerLidoWithdrawalRequests:** One-time migration function (reinitializer(2)) that validates
  total requested matches `lidoWithdrawalQueueAmount`. Proper ownership and claim status checks.

### EtherFiARM -- CLEAN

- **ERC721 handling:** Implements `IERC721Receiver` for withdrawal NFTs from EtherFi.
- **Same defensive patterns as LidoARM** for withdrawal queue tracking and NFT transfer protection.

### EthenaARM -- CLEAN

- **Round-robin unstaking:** 42 helper contracts (`EthenaUnstaker`) allow parallel sUSDe cooldowns.
  `DELAY_REQUEST = 3 hours` rate-limits requests, preventing rapid-fire unstaking.
- **Cooldown validation:** Checks `cooldown.underlyingAmount == 0` before using an unstaker,
  ensuring it is not mid-cooldown.
- **ERC-4626 conversion:** Uses `convertToAssets`/`convertToShares` (not `preview*` variants) for
  price conversion, as documented in comments. These avoid potential paused/utilization discounts
  on the sUSDe contract.
- **EthenaUnstaker auth:** `require(msg.sender == arm)` on both `requestUnstake` and `claimUnstake`.

### OriginARM -- CLEAN

- **Vault withdrawal amount tracking:** `vaultWithdrawalAmount` tracks outstanding requests.
  `claimOriginWithdrawals` properly decrements by claimed amount (return value from vault).
- **Non-transferrable withdrawals:** Comment documents that Origin Vault withdrawals are not
  transferrable, making the amount subtraction safe.

### CapManager -- CLEAN

- **Post-deposit hook:** Called after deposit with `totalAssets()` already reflecting new assets.
- **LP cap decrement:** Caps decrease by exact deposit amount, preventing cap reuse.
- **Total assets cap:** Checked against current `totalAssets()` post-deposit.
- **Account cap toggle:** Owner-only `setAccountCapEnabled` with idempotency check.

### Governance/xOGN (ExponentialStaking.sol) -- CLEAN

- **Flash-loan governance immunity:** xOGN uses `ERC20Votes` with checkpoint-based voting power.
  Governance uses `votingDelay = 7200 blocks` (~1 day). Voting power is queried at historical
  block numbers via `proposalSnapshot`, preventing same-block manipulation.
- **Transfer disabled:** `transfer()` and `transferFrom()` both revert unconditionally, preventing
  voting power transfer without unstaking (which has early-withdrawal penalties).
- **Exponential decay on early unstake:** `previewWithdraw` reduces payout proportionally to
  remaining lockup time using the exponential formula, disincentivizing stake-and-dump.
- **Delegation safety:** Auto-delegates to self on first stake when `delegates(to) == address(0)`.
- **Points overflow protection:** `require(newPoints + totalSupply() <= type(uint192).max)` prevents
  overflow. Lockup amounts bounded by `uint128`.
- **Gift restrictions:** When staking to another address (`to != msg.sender`), `stakeRewards` must
  be false and `lockupId` must be `NEW_STAKE`, preventing control of others' rewards or lockups.
- **Lockup extension rules:** `require(newEnd >= oldEnd)` and `require(newPoints > oldPoints)`
  ensure lockup extensions genuinely increase commitment.
- **Reward accounting:** Standard MasterChef-style `accRewardPerShare` + `rewardDebtPerShare`
  pattern with 1e12 scaling. `try/catch` around `rewardsSource.collectRewards()` ensures staking
  continues even if the rewards source fails.

### FixedRateRewardsSource -- CLEAN

- **Caller validation:** `collectRewards()` can only be called by `rewardsTarget`.
- **Balance cap:** Rewards capped by actual token balance: `min(computed, balance)`.
- **Zero-rate transition:** Properly resets `lastCollect` when transitioning from 0 to nonzero rate,
  preventing retroactive reward distribution for the dormant period.

### Migrator -- CLEAN

- **Solvency invariant:** `isSolvent` modifier (post-condition) checks `ogn.balanceOf(this) >=
  (ogv.totalSupply() * CONVERSION_RATE) / 1 ether` after every migration. This guarantees enough
  OGN exists for all remaining OGV holders.
- **Fixed conversion rate:** `CONVERSION_RATE = 0.09137 ether` is immutable, preventing manipulation.
- **Burn-before-transfer:** `ogv.burnFrom(msg.sender, ogvAmount)` burns OGV before transferring OGN,
  preventing supply inflation via reentrancy.
- **Time-limited with decommission:** `endTime` enforced. `transferExcessTokens` returns all OGN
  to treasury after migration ends.
- **Stake migration safety:** The `migrate()` overload with lockup IDs correctly:
  1. Unstakes from OGV staking (OGV + rewards to user)
  2. Burns OGV from user (requires prior approval)
  3. Stakes OGN on behalf of user in xOGN staking
  4. Returns excess OGN to user

### MigrationZapper -- CLEAN

- **Governor-only rescue:** `transferTokens` restricted to immutable `governor` address.
- **Approval at initialize:** Max approvals to Migrator and xOGN staking.
- **Clean flow:** OGV in from user -> migrate through Migrator -> OGN out to user or staked.

### Governance.sol -- CLEAN

- **Standard OZ Governor stack:** GovernorSettings + GovernorVotesQuorumFraction +
  GovernorTimelockControl + GovernorPreventLateQuorum.
- **Conservative parameters:** votingDelay=7200 blocks (~1 day), votingPeriod=14416 blocks (~2 days),
  proposalThreshold=100K xOGN, quorum=20%.
- **Late quorum protection:** GovernorPreventLateQuorum(7208) extends deadline by ~1 day if quorum
  is reached late, preventing last-block vote manipulation.
- **Timelock execution:** All proposal execution goes through TimelockController, providing delay
  for community review.

### GovernorCompatibilityBravo -- CLEAN

- **Vote types:** Against (0), For (1), Abstain (2) properly implemented.
- **Double-vote prevention:** `require(!receipt.hasVoted)` in `_countVote`.
- **Quorum:** Only `forVotes` count toward quorum (`_quorumReached`).
- **Vote success:** `forVotes > againstVotes` (strict greater than).
- **Cancel protection:** Proposer OR anyone when proposer drops below threshold.
- **uint256 votes:** Modified from OZ's uint96 to uint256, handling larger vote weights from
  exponential staking.

### OgvStaking (Legacy) -- CLEAN

- **Staking disabled:** All `stake()` and `extend()` functions revert with `StakingDisabled()`,
  preventing new OGV stakes. Only unstake and reward collection remain active for migration.
- **Migrator integration:** `unstakeFrom` and `collectRewardsFrom` restricted to `migratorAddr`
  (immutable), enabling the Migrator to manage user positions during OGV->OGN migration.
- **accRewardPerShare NOT collected from rewardsSource:** Note that `OgvStaking._collectRewards`
  does NOT call `rewardsSource.collectRewards()` (unlike `ExponentialStaking`). It only distributes
  already-accumulated rewards. This is correct since OGV staking is being wound down.

### RewardsSource (Legacy) -- CLEAN

- **Inflation slope management:** Governor-only `setInflation` with max 48 knees and max 5M OGV/day.
- **Sequential slope computation:** Efficient linear scan with cached `currentSlopeIndex`.
- **Governor-only target:** `setRewardsTarget` properly restricted.

---

## Hypotheses Tested (50+)

### ARM Hypotheses
1. First-depositor inflation attack via donation -- CLEAN (dead shares at 1e12)
2. Share price manipulation via large swap -- CLEAN (prices are operator-set, not AMM-computed)
3. Withdrawal queue draining via swap front-running -- CLEAN (`_requireLiquidityAvailable`)
4. Fee manipulation by depositing before fee collection -- CLEAN (`lastAvailableAssets` tracks both)
5. Cross-price manipulation to extract value -- CLEAN (owner-only, deviation-bounded)
6. Double-claim of Lido/EtherFi withdrawal requests -- CLEAN (external protocol enforcement)
7. Reentrancy via stETH/eETH/sUSDe transfer hooks -- CLEAN (standard ERC-20, no hooks)
8. Sandwich attack on operator price changes -- CLEAN (cross-price bounds limit profit)
9. Lending market share inflation attack -- CLEAN (ERC-4626 standard, balanceOf-based)
10. Withdrawal claim exceeding available liquidity -- CLEAN (`claimable()` includes lending market)
11. Integer overflow in swap price calculation -- CLEAN (Solidity 0.8.23 + SafeCast)
12. Fee collector draining withdrawal queue -- CLEAN (`_requireLiquidityAvailable` check)
13. Operator setting traderate to zero -- CLEAN (zero rate = zero output, no exploit)
14. Active market redeem failure blocking switch -- Acknowledged (documented in comments)
15. ETH balance manipulation via Lido/EtherFi claim -- CLEAN (wraps full balance)
16. EthenaARM unstaker double-use -- CLEAN (cooldown amount check before use)
17. EthenaARM round-robin exhaustion -- CLEAN (42 unstakers, 3-hour delay)
18. SonicHarvester swap data manipulation -- CLEAN (assembly validates all parameters)
19. SonicHarvester fee bypass -- CLEAN (1% cap on fees)
20. Market wrapper unauthorized withdrawal -- CLEAN (`msg.sender == arm` check)
21. Pendle SY adapter exchange rate manipulation -- CLEAN (uses ARM's convertToAssets)
22. CapManager bypass via direct deposit to ARM -- CLEAN (postDepositHook in `_deposit`)
23. ZapperARM deposit to malicious ARM -- N/A (caller's choice)
24. Withdrawal request with zero shares -- CLEAN (SafeCast prevents issues)
25. Cross-price lowering with base assets present -- CLEAN (requires < MIN_TOTAL_SUPPLY)

### Governance Hypotheses
26. Flash-loan governance attack -- CLEAN (checkpoint voting + votingDelay + non-transferable)
27. Stake then immediate unstake for vote power -- CLEAN (exponential decay penalty)
28. Reward theft via re-entrant stake -- CLEAN (OGN is standard ERC-20, no callbacks)
29. Stake to another user to steal their rewards -- CLEAN (stakeRewards=false for gifts)
30. Migration conversion rate overflow -- CLEAN (0.09137 ether multiplier, bounded)
31. Double-migration via reentrancy -- CLEAN (burnFrom before OGN transfer)
32. Migrator insolvency by partial OGN drain -- CLEAN (`isSolvent` post-check)
33. Timelock bypass via proposal timing -- CLEAN (standard OZ TimelockController)
34. Quorum manipulation via late vote -- CLEAN (GovernorPreventLateQuorum extends deadline)
35. Reward accumulation precision loss -- CLEAN (1e12 scaling for accRewardPerShare)
36. Zero totalSupply in reward calculation -- CLEAN (early return when supply == 0)
37. Lockup array growth attack (gas griefing) -- CLEAN (bounded by type(int256).max, practical gas limit)
38. Delegation to zero address -- CLEAN (auto-delegates to self on first stake)
39. OgvStaking unstakeFrom by non-migrator -- CLEAN (`onlyMigrator` modifier)
40. FixedRateRewardsSource retroactive rewards -- CLEAN (`lastCollect` reset on 0->nonzero)
41. Lockup extension to compound points -- CLEAN (newEnd >= oldEnd, newPoints > oldPoints)
42. Governance proposal description hash collision -- CLEAN (standard OZ handling)
43. MigrationZapper stealing excess OGN -- CLEAN (governor-only `transferTokens`)
44. Staking epoch manipulation -- CLEAN (epoch is immutable)
45. previewWithdraw returning > amount -- CLEAN (currentPoints <= fullPoints mathematically)
46. accRewardPerShare overflow -- CLEAN (uint256, astronomical amounts needed)
47. rewardDebtPerShare underflow -- CLEAN (always set to accRewardPerShare, monotonic)
48. Cross-chain considerations for SonicHarvester -- CLEAN (single-chain operation)
49. Allocation flip-flop between deposit/withdraw -- CLEAN (`allocateThreshold` prevents)
50. Market shares dust preventing redeem -- Acknowledged (operator transfers dust in)

---

## Architecture Assessment

### ARM System Design: Strong

The ARM's dual-pricing model with `crossPrice` as the invariant anchor is well-designed:
- Buys at `traderate1` (below crossPrice) = buying base assets at a discount
- Sells at `1/traderate0` (above crossPrice) = selling base assets at a premium
- The spread between buy and sell generates profit for LPs
- The cross-price bound prevents the ARM from accumulating losses

The async withdrawal queue with claim delay (configurable, e.g., 10 minutes) provides ordered,
fair withdrawal processing. The lending market integration via ERC-4626 wrappers adds yield but
is properly bounded by the buffer mechanism and allocation threshold.

Key architectural strengths:
1. **Dead shares** prevent first-depositor attacks without virtual share offset
2. **Cross-price** creates an invariant floor for base asset valuation in `totalAssets()`
3. **Performance fee** accrual is continuous and correctly deducted from available assets
4. **Lending market integration** through standard ERC-4626 interface allows flexible market switching
5. **Claim delay** prevents atomic deposit-redeem sandwich attacks on the LP shares

### Governance System Design: Strong

The exponential staking model provides time-weighted voting power:
- Formula: `points = amount * 1.4^(years_from_epoch_to_end)`
- Maximum stake duration: 365 days
- Early withdrawal penalty proportional to remaining time

The checkpoint-based voting (ERC20Votes) with transfer restrictions makes flash-governance
attacks infeasible. The GovernorPreventLateQuorum extension adds robustness against last-minute
vote manipulation. The Timelock controller provides a final safety net for proposal review.

---

## Conclusion

The Origin Protocol ARM and Governance/xOGN contracts demonstrate mature security engineering.
The ARM system's fixed-spread pricing with cross-price bounds, dead-share initialization, and
async withdrawal queue provide robust protection for LPs. The governance system's exponential
staking with non-transferable tokens and checkpoint-based voting prevent governance manipulation.

The three Low findings (SonicHarvester transfer gap, unmapped withdrawal claim cleanup, zapper
balance handling) pose no immediate risk but warrant attention for defense-in-depth. The five
Informational findings are code quality observations with no security impact.

No findings warrant Immunefi submission at the High or Critical tier.
