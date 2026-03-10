# Kamino Finance Cross-Program Security Analysis

## Architecture Overview

The Kamino Finance protocol suite consists of four programs that interact:

- **klend** (`KLend2g3cP87fffoy8q1mQqGKjrxjC8boSyAYavgmjD`): Lending/borrowing protocol with reserves, obligations, elevation groups, flash loans, and withdrawal queues.
- **kvault** (`kamino_vault`): Yield-optimizing vault that deposits into klend reserves. Issues share tokens against underlying liquidity.
- **scope** (`scope`): Oracle aggregator that reads from Pyth, Switchboard, Chainlink, and computes derived prices (kTokens, TWAPs, scope chains).
- **kfarms** (`FarmsPZpWu9i7Kky8tPN37rs2TpmMrAZrC7S7vJa91Hr`): Farming/staking program for reward distribution. klend creates delegated farms for reserve collateral and debt.

### Integration Map

```
scope --> klend (price feeds via ScopeConfiguration per reserve)
scope --> kfarms (deposit cap price validation)
scope --> ktokens oracle pricing (yvaults strategy holdings)
kvault --> klend (CPI: deposit/redeem reserve liquidity, refresh reserves batch)
klend --> kfarms (CPI: initialize/set_stake_delegated for obligation farming)
```

---

## 1. Oracle Manipulation Chain (Scope -> klend)

### 1.1 Scope Price Refresh Security

**Finding: No exploitable vector.**

The scope `refresh_price_list` handler has a strict `check_execution_ctx` function (lines 176-201 of `handler_refresh_prices.rs`) that:

1. Verifies the instruction is NOT called via CPI (`get_stack_height() > TRANSACTION_LEVEL_STACK_HEIGHT` check).
2. Verifies ALL preceding instructions in the transaction are Compute Budget instructions.

This means an attacker cannot:
- Refresh a scope price and then immediately exploit klend in the same transaction.
- Call scope refresh via CPI from a malicious program.

The only permitted transaction shape is: `[ComputeBudget...] -> scope::refresh_price_list`.

### 1.2 klend Price Validation

klend uses a multi-layer price validation system in `utils/prices/checks.rs`:

1. **Staleness check**: `max_age_price_seconds` configurable per token.
2. **TWAP divergence check**: `max_twap_divergence_bps` - price must be within X bps of TWAP.
3. **Heuristic bounds**: Upper/lower price bounds per token.
4. **Price status flags**: All checks produce status flags stored in `LastUpdate`. Operations requiring fresh prices (borrow, withdraw, liquidate) check `PriceStatusFlags::ALL_CHECKS`.
5. **Most-recent selection**: klend picks the most recently updated price from Pyth/Switchboard/Scope, not exclusively Scope.

**Assessment**: A compromised or stale scope oracle feed cannot be used to manipulate klend because:
- TWAP divergence check catches spot-price manipulation.
- Staleness check rejects old prices.
- Heuristic bounds provide hard floors/ceilings.
- klend can fall back to Pyth/Switchboard if scope is stale.

### 1.3 kToken Pricing in Scope (for Kamino Vaults/LP tokens)

The `ktokens.rs` oracle in scope computes kToken (yvault strategy share) prices using:
- Scope oracle prices for token_a and token_b (NOT pool spot price).
- A sqrt_price derived from oracle prices, not the pool's AMM price.
- Excludes reward tokens from holdings calculation.
- Uses the oldest timestamp from the component price chains as the kToken price timestamp.

**Assessment**: This is sound. The key defense is using oracle-derived sqrt_price instead of pool sqrt_price. The kToken price inherits the staleness of its most-stale component, so klend's staleness checks naturally propagate.

---

## 2. Flash Loan + Vault Interaction

### 2.1 klend Flash Loan -> kvault Share Manipulation

**Finding: No exploitable vector.**

klend flash loans have the following protections:

1. **CPI ban**: `is_flash_forbidden_cpi_call()` checks stack height -- flash borrow/repay cannot be called via CPI (except from whitelisted programs like FlexLend, Squads, etc.).
2. **Same-tx repay enforcement**: Flash borrow checks that a matching flash repay exists later in the same transaction.
3. **Single borrow**: Only one flash borrow per transaction.
4. **Account matching**: All accounts in the repay instruction must match the borrow instruction.

Can flash-borrowed tokens manipulate kvault share prices?

kvault share price = `(token_available + sum(ctoken_allocation * exchange_rate)) - pending_fees) / shares_issued`

The exchange rate comes from klend reserve state: `total_liquidity / total_collateral`. A flash borrow does NOT change the exchange rate because:
- `flash_borrow_reserve_liquidity` in `lending_operations.rs` only decrements `available_amount` -- it does not change `total_supply()` or the collateral exchange rate.
- The reserve's `total_supply()` accounts for borrowed amounts, so the exchange rate is unaffected by flash borrows.

Additionally, kvault calls `cpi_refresh_reserves(..., skip_price_updates: true)` before every deposit/withdraw, ensuring reserves are current-slot fresh. The `skip_price_updates: true` means it only accrues interest, not re-fetches prices.

### 2.2 Flash-Borrowed Tokens Staked in kfarms

**Finding: Not a viable attack.**

kfarms `stake` handler requires `!farm_state.is_delegated()` -- user-facing farms must be non-delegated. However, klend obligation farms ARE delegated (created via `initialize_farm_delegated`). A user cannot directly stake into a klend obligation farm.

For non-delegated farms: a user could flash borrow tokens, stake them, and earn rewards. But:
- kfarms has `deposit_warmup_period` -- staked tokens go to `pending` status first.
- kfarms has `withdrawal_cooldown_period` -- unstaked tokens require a cooldown before withdrawal.
- Rewards accrue to `active_stake`, not `pending_stake`.
- The flash loan must be repaid in the same transaction, so the user would need to unstake + withdraw in the same tx, but pending warmup prevents immediate active status.

If both `deposit_warmup_period` and `withdrawal_cooldown_period` are 0, a user could theoretically stake, immediately harvest accrued rewards (if any), and unstake. But with 0 warmup, the reward accrual would be based on a single slot of staking, which yields negligible rewards.

---

## 3. Collateral Token Composition

### 3.1 kvault Shares as klend Collateral

**Finding: Architecture analysis -- no direct composability vulnerability found.**

kvault shares are SPL tokens (the `shares_mint` from VaultState). These COULD be listed as a klend reserve's liquidity mint if Kamino governance chose to do so. However:

- kvault share price is NOT directly accessible on-chain as a standard oracle feed. It would need to be priced through scope via a dedicated oracle type.
- The scope codebase has `ktokens.rs` for yvault strategy shares, but this is for the Kamino LP (concentrated liquidity) tokens, not kvault lending vault shares.
- There is no scope oracle type for kvault shares in the current codebase.

If kvault shares were listed as klend collateral:
- The share price depends on klend reserve exchange rates (circular dependency).
- A flash loan on the underlying token could temporarily inflate available liquidity in the vault.

**Assessment**: This is a hypothetical risk that depends on governance action. The current codebase does not support kvault shares as klend collateral because there is no scope oracle for them. This is safe by design.

### 3.2 kfarms LP Tokens as klend Collateral

kfarms accepts arbitrary SPL tokens for staking. The staked tokens sit in `farm_vault`. kfarms does not issue receipt tokens that could be used as klend collateral. The `UserState` is a program account, not a transferable token.

**Assessment**: No composability surface here.

---

## 4. Reward Token Interaction

### 4.1 kfarms Rewards and klend Debt Repayment

**Finding: No direct interaction.**

kfarms rewards are harvested via `harvest_reward` which transfers tokens from `reward_vault` to the user's ATA. These are standard SPL token transfers. The user could then use those tokens to repay klend debt if the reward token matches a klend reserve's liquidity mint. This is normal DeFi composability, not an exploit.

### 4.2 Arbitrage Between kfarms Rewards and klend Interest

kfarms reward rates are set by the farm admin via `reward_per_second` curves. klend interest rates are market-determined via the borrow rate curve. There is no protocol-level arbitrage concern because:
- kfarms rewards are external incentives, not protocol liabilities.
- klend interest is paid by borrowers to depositors.
- The two systems have independent accounting.

**Assessment**: No vulnerability.

---

## 5. Admin/Governance Risks

### 5.1 Admin Structure

| Program | Admin Key | Stored In |
|---------|-----------|-----------|
| klend | `lending_market_owner` | `LendingMarket` |
| klend | `global_admin` | klend `GlobalConfig` |
| kvault | `vault_admin_authority` | `VaultState` per vault |
| kvault | `global_admin` | kvault `GlobalConfig` |
| scope | admin | `Configuration` (per feed) |
| kfarms | `farm_admin` (per farm) | `FarmState` |
| kfarms | `global_admin` | kfarms `GlobalConfig` |

**Finding: Admins are independent per program.**

Each program has its own admin hierarchy. klend's `lending_market_owner` controls reserve configuration, elevation groups, and can set emergency mode. kvault's admin controls vault allocations, fees, and reserve whitelists. scope's admin controls oracle mappings. kfarms' global admin controls treasury fees.

### 5.2 Cross-Program Admin Impact

**Compromised scope admin**: Could remap oracle sources to attacker-controlled accounts. This would affect ALL consumers (klend, kfarms, yvaults/ktokens pricing). However:
- klend's TWAP divergence check provides defense-in-depth.
- klend's heuristic bounds provide hard price limits.
- Scope's `check_execution_ctx` prevents same-tx oracle + exploit combos.

**Compromised klend admin**: Could modify reserve configs (LTV, borrow factor, elevation groups), potentially enabling undercollateralized borrowing. This is a standard admin trust assumption. kvault would be affected indirectly because its AUM depends on klend reserve exchange rates.

**Compromised kvault admin**: Could redirect vault allocations to malicious reserves. But:
- The reserve whitelist feature (`allow_allocations_in_whitelisted_reserves_only`, `allow_invest_in_whitelisted_reserves_only`) limits which reserves can be used.
- Reserves must be valid klend `Reserve` accounts (discriminator checked on CPI).

**Compromised kfarms admin**: Could modify reward schedules, freeze farms, or slash deposits. For klend obligation farms, the farm admin is the klend `lending_market_authority` PDA, not an external key. So kfarms admin compromise does not affect klend obligation farming directly, but the kfarms `global_admin` could affect treasury fee extraction.

**Assessment**: Admin compromise is standard trust assumption. The per-program admin separation limits blast radius. The most dangerous compromise would be the scope admin, as it affects pricing across all programs.

---

## 6. Elevation Groups in klend

### 6.1 Elevation Group Mechanics

Elevation groups allow obligations to get higher LTV/liquidation thresholds for specific asset pairs. Key constraints:

- Each elevation group has a specific `debt_reserve` (the only reserve that can be borrowed).
- `max_reserves_as_collateral` limits the number of collateral reserves.
- Each reserve declares which elevation groups it belongs to via `config.elevation_groups[]`.
- The debt reserve cannot be used as collateral in the same elevation group.
- Changing elevation group requires the obligation to be healthy under the new group's parameters.

### 6.2 Elevation Group with kvault/kfarms Assets

**Finding: No specific vulnerability found.**

If a kvault share token were listed as a klend reserve and placed in an elevation group:
- The standard elevation group constraints would apply.
- The share price oracle would need to exist in scope.
- Circular pricing (vault holds klend cTokens, klend prices vault shares) would be a risk, but as noted in section 3.1, this is currently not supported.

For kfarms: obligation farming is orthogonal to elevation groups. The `RefreshObligationFarmsForReserve` handler reads the obligation's deposit/borrow amounts and updates the kfarms `UserState` via `set_stake_delegated`. The farming amounts are denominated in cTokens (collateral) or borrowed amounts (debt), not in market value. Elevation group changes that affect LTV do not directly affect farming amounts.

**Assessment**: Elevation groups are well-constrained. The interaction surface with kvault/kfarms is limited to:
1. Whether a given asset is in the elevation group's allowed set (admin-configured).
2. Farming rewards continuing to accrue based on raw deposit/borrow amounts regardless of elevation group LTV changes (this is by design, not a bug).

---

## 7. kvault Refresh Reserves with skip_price_updates

### 7.1 kvault's CPI Pattern

When kvault calls klend's `refresh_reserves_batch` with `skip_price_updates: true` (see `klend_operations.rs` line 51), it only accrues interest without re-fetching oracle prices. This means:

- kvault deposit/withdraw operations use whatever price was last written to the reserve.
- If a reserve's price is stale, the reserve's `last_update` will reflect that staleness.
- kvault checks `reserve.last_update.is_stale(slot, PriceStatusFlags::NONE)` -- it only checks slot freshness, NOT price status flags.

**Critical observation**: kvault calls `is_stale(slot, PriceStatusFlags::NONE)` which means it only checks if the reserve was updated in the current slot (STALE_AFTER_SLOTS_ELAPSED = 1). It does NOT check if the price was loaded, age-checked, TWAP-checked, or heuristic-checked. The `PriceStatusFlags::NONE` parameter means "require no flags."

This means kvault will accept a reserve that was refreshed in the current slot with `skip_price_updates: true`, even if:
- The underlying oracle price is very old.
- The TWAP divergence check failed.
- The heuristic bounds check failed.

However, this is mitigated by the fact that kvault itself calls the batch refresh, so the refresh happens in the same transaction. The price data was already in the reserve from a prior refresh (potentially from an earlier slot). kvault's share price is computed from exchange rates (ctoken-to-liquidity), not from market prices. The exchange rate depends on total deposits and total borrows, not on the oracle price.

**Assessment**: This is by design. kvault cares about the exchange rate (how many underlying tokens per cToken), not about the USD market price. The exchange rate is updated via interest accrual, which `skip_price_updates: true` does handle. The oracle price in klend reserves is used for obligation health checks, not for exchange rate calculations.

---

## 8. First-Depositor / Inflation Attack on kvault

### 8.1 Analysis

kvault's share minting formula (in `vault_operations.rs`):
```
if shares_issued == 0:
    shares_to_mint = user_token_amount
else:
    shares_to_mint = floor(shares_issued * user_token_amount / ceil(holdings_aum))
```

The first deposit gets shares 1:1 with tokens. There is no virtual shares offset (unlike OZ's ERC4626 mitigation).

An attacker could:
1. Deposit 1 token, get 1 share.
2. Donate tokens directly to `token_vault` to inflate `token_available`.
3. Next depositor gets fewer shares.

However, `token_available` is tracked in `VaultState`, not derived from the actual token account balance. Donations to `token_vault` do NOT increase `vault.token_available`. The only way to increase `token_available` is through the `deposit` handler which also mints shares proportionally.

But what about invested amounts? If the attacker deposits 1 token, then the vault admin invests it into a klend reserve, and then someone donates liquidity to that klend reserve, the exchange rate increases. This increases the vault's AUM without minting new shares.

This is mitigated by:
- klend reserves have their own exchange rates that increase monotonically with interest accrual.
- Direct donation to a klend reserve supply vault would increase available liquidity but this is tracked by klend's internal accounting, not by the actual token balance.
- klend's `deposit_reserve_liquidity` uses `reserve.liquidity.available_amount` which is tracked internally.

**Assessment**: The kvault accounting is internal (not derived from token balances), which prevents the classic first-depositor donation attack. The `shares_issued == 0 => shares_to_mint = user_token_amount` formula means the first depositor gets exactly as many shares as tokens deposited, with no virtual offset needed because the share price is derived from internal accounting.

---

## Summary of Findings

After thorough analysis of all four programs and their cross-program interactions:

**No exploitable cross-program vulnerabilities were identified.**

Key defensive patterns observed:
1. **Scope CPI + tx ordering checks**: Prevents same-tx oracle manipulation + exploit.
2. **klend multi-oracle with TWAP/heuristic validation**: Defense-in-depth against price manipulation.
3. **kvault internal accounting**: Share prices derived from internal state, not token balances.
4. **kfarms warmup/cooldown periods**: Prevent flash-loan-based reward extraction.
5. **Per-program admin separation**: Limits blast radius of admin compromise.
6. **klend flash loan CPI ban + single-borrow constraint**: Prevents flash loan abuse.
7. **kvault -> klend CPI with skip_price_updates**: Correctly uses exchange rates (not oracle prices) for share calculations.
8. **Elevation group constraints**: Properly enforced across deposit/borrow/liquidation paths.

The architecture is well-designed with proper trust boundaries between programs. The Scope oracle acts as a shared dependency, and its compromise would be the highest-impact scenario, but this is mitigated by klend's multi-oracle fallback and validation layers.
