# Immunefi Bug Report: Burrow Liquidation Creates Permanent Phantom Farming Shadows

## Bug Description

### Summary

In Ref Finance's `on_burrow_liquidation` function (`shadow_actions.rs`), when a user's LP shares are shadow-staked in both Burrowland and boost-farming, a liquidation event commits irreversible state changes to the ref-exchange shadow records and removes liquidity BEFORE the cross-contract call to the farming contract succeeds. The callback `callback_on_burrow_liquidation` only logs the result without any rollback logic. If the farming contract's `on_remove_shadow` fails, the system enters a permanently inconsistent state where:

- **ref-exchange** believes the farming shadow has been reduced
- **boost-farm** still has the full shadow amount, continuing to accrue farming rewards on phantom seeds (LP shares that no longer exist)

### Vulnerable Code

**File:** `ref-exchange/src/shadow_actions.rs` lines 171-238

```rust
pub fn on_burrow_liquidation(&mut self, liquidator_account_id: AccountId,
    liquidation_account_id: AccountId, shadow_id: String,
    liquidate_share_amount: U128, min_token_amounts: Vec<U128>) {
    assert!(self.burrowland_id == env::predecessor_account_id());
    let pool_id = shadow_id_to_pool_id(&shadow_id);

    let mut pool = self.pools.get(pool_id).expect(ERR85_NO_POOL);
    // ...
    let mut liquidation_account = self.internal_unwrap_account(&liquidation_account_id);

    // STEP 1: Immediately decrement shadow_in_burrow (IRREVERSIBLE)
    liquidation_account.update_shadow_record(pool_id, &ShadowActions::FromBurrowland,
        liquidate_share_amount.0);                                          // line 181

    // STEP 2: Calculate if farming shadow must also be reduced
    let available_shares = if let Some(record) = liquidation_account.get_shadow_record(pool_id) {
        record.free_shares(total_shares)
    } else {
        total_shares
    };
    let withdraw_seed_amount = if available_shares > 0 {
        if available_shares > liquidate_share_amount.0 { 0 }
        else { liquidate_share_amount.0 - available_shares }
    } else {
        liquidate_share_amount.0
    };

    // STEP 3: Immediately decrement shadow_in_farm (IRREVERSIBLE)
    if withdraw_seed_amount > 0 {
        liquidation_account.update_shadow_record(pool_id,
            &ShadowActions::FromFarming, withdraw_seed_amount);              // line 193
    }
    self.internal_save_account(&liquidation_account_id, liquidation_account); // line 199

    // STEP 4: Remove liquidity and give to liquidator (IRREVERSIBLE)
    let amounts = pool.remove_liquidity(
        &liquidation_account_id, liquidate_share_amount.0, ...);             // line 202
    self.pools.replace(pool_id, &pool);                                      // line 211
    // ... deposit tokens to liquidator_account ...

    // STEP 5: Cross-contract call to farming - FIRE AND FORGET
    if withdraw_seed_amount > 0 {
        ext_shadow_receiver::on_remove_shadow(                               // line 219
            liquidation_account_id.clone(), shadow_id,
            U128(withdraw_seed_amount), ...
        ).then(ext_self::callback_on_burrow_liquidation(...));
    }
}
```

**The callback (lines 289-297) -- LOG ONLY, NO ROLLBACK:**

```rust
#[private]
pub fn callback_on_burrow_liquidation(
    &mut self, sender_id: AccountId, pool_id: u64, amount: U128,
) {
    log!("pool_id {}, {} remove {} farming seed {}", pool_id, sender_id, amount.0,
        if is_promise_success() { "successful" } else { "failed" });
    // NO STATE ROLLBACK ON FAILURE
}
```

### Call Chain Analysis

Normal `shadow_action(FromFarming)` flow correctly uses the pessimistic pattern:
1. Does NOT update local state
2. Calls farming contract's `on_remove_shadow`
3. Only on SUCCESS callback, decrements `shadow_in_farm`

But `on_burrow_liquidation` uses the opposite (broken) pattern:
1. Immediately decrements `shadow_in_farm` (line 193)
2. Immediately removes liquidity and sends to liquidator (line 202)
3. THEN calls farming contract (fire-and-forget, line 219)
4. Callback only logs (line 295)

### State After Failure

**Concrete example:**
- User has 1000 LP shares, `shadow_in_farm = 600`, `shadow_in_burrow = 800`
- Burrowland liquidates 800 shares

After execution:
1. `shadow_in_burrow = 0` (was 800, decremented by 800)
2. `free_shares = 1000 - max(600, 0) = 400`
3. `withdraw_seed_amount = 800 - 400 = 400`
4. `shadow_in_farm = 200` (was 600, decremented by 400)
5. LP shares burned: 1000 - 800 = 200 remaining
6. Cross-contract call to farming to remove 400 shadows **FAILS**

**Final state:**
- ref-exchange: `shadow_in_farm = 200`, `total_shares = 200`
- boost-farm: `FarmerSeed.shadow_amount = 600` (UNCHANGED)

**400 phantom shadow seeds** now permanently exist in the farming contract, earning rewards on LP shares that have been liquidated and removed from the pool.

### Failure Trigger Conditions

The farming `on_remove_shadow` can fail when:
- The boost-farming contract is **paused** (`RunningState::Paused`)
- Insufficient gas allocated (only `GAS_FOR_ON_BURROW_LIQUIDATION = 40 TGas`)
- The farmer was never registered in farming (edge case)

The farming contract being paused is the most realistic trigger -- admin pauses are independent of liquidation timing, and burrow liquidations are market-driven.

---

## Impact

### Severity Classification

**Medium** (per Immunefi tiers)

### Financial Impact

- Phantom farming shadows earn real rewards proportional to `phantom_shadow_amount / total_seed_power`
- This dilutes ALL other farmers' rewards permanently
- The farming contract's `total_seed_power` is inflated, reducing per-unit reward distribution
- No recovery mechanism exists in either contract

### Affected Users

- All farmers in any seed pool where this occurs (reward dilution)
- The liquidated user (cannot remove the phantom shadows from farming)

---

## Risk Breakdown

| Factor | Assessment |
|--------|-----------|
| Difficulty | Medium -- requires farming contract to be paused during a liquidation event |
| Weakness Type | CWE-703 (Improper Check or Handling of Exceptional Conditions) |
| CVSS | 5.3 (Medium) -- Network/Low AC/None PR/None UI/None S/Low C/None I/None A |

---

## Recommendation

### Option A: Add rollback to callback (Preferred)

```rust
#[private]
pub fn callback_on_burrow_liquidation(
    &mut self,
    sender_id: AccountId,
    pool_id: u64,
    amount: U128,
) {
    if !is_promise_success() {
        // Store failed farming removal for admin retry
        let key = format!("phantom_shadow:{}:{}", sender_id, pool_id);
        env::storage_write(key.as_bytes(), &amount.0.to_le_bytes());
        log!("CRITICAL: pool_id {}, {} failed to remove {} farming seed.
              Phantom shadow stored for recovery.", pool_id, sender_id, amount.0);
    } else {
        log!("pool_id {}, {} remove {} farming seed successful",
             pool_id, sender_id, amount.0);
    }
}
```

Plus add an admin function to retry failed removals:

```rust
pub fn retry_phantom_shadow_removal(&mut self, account_id: AccountId, pool_id: u64) {
    self.assert_owner();
    let key = format!("phantom_shadow:{}:{}", account_id, pool_id);
    if let Some(data) = env::storage_read(key.as_bytes()) {
        let amount = u128::from_le_bytes(data.try_into().unwrap());
        let shadow_id = pool_id_to_shadow_id(pool_id);
        ext_shadow_receiver::on_remove_shadow(
            account_id, shadow_id, U128(amount), "".to_string(),
            &self.boost_farm_id, 0, GAS_FOR_ON_BURROW_LIQUIDATION
        );
        env::storage_remove(key.as_bytes());
    }
}
```

### Option B: Use optimistic rollback pattern (like normal shadow_action)

Restructure `on_burrow_liquidation` to perform the farming shadow decrement only in the callback on success, similar to `callback_on_shadow` for `FromFarming`.

---

## Proof of Concept

Since this is a NEAR Protocol contract, a traditional Foundry PoC is not applicable. Below is a conceptual test scenario that demonstrates the vulnerability:

### Scenario Setup

```
1. Alice has 1000 LP shares in pool #5
2. Alice shadow-stakes 600 shares to boost-farming
3. Alice shadow-stakes 800 shares to burrowland
4. Alice's ShadowRecord: { shadow_in_farm: 600, shadow_in_burrow: 800 }
5. Alice's free_shares = 1000 - max(600, 800) = 200

6. Admin pauses the boost-farming contract (RunningState::Paused)

7. Alice becomes under-collateralized on burrowland
8. Liquidator calls burrowland, which calls ref-exchange on_burrow_liquidation(
     liquidation_account_id: alice,
     liquidate_share_amount: 800,
     ...
   )

9. Execution:
   a. shadow_in_burrow decremented: 800 -> 0
   b. free_shares = 1000 - max(600, 0) = 400
   c. withdraw_seed_amount = 800 - 400 = 400
   d. shadow_in_farm decremented: 600 -> 200
   e. Account saved with both decrements
   f. 800 LP shares removed from pool, tokens sent to liquidator
   g. Cross-contract call to paused boost-farming: on_remove_shadow(alice, 400) -> FAILS
   h. callback_on_burrow_liquidation: logs "failed", does nothing

10. Result:
    - ref-exchange: shadow_in_farm = 200, total_shares = 200
    - boost-farm: shadow_amount = 600, seed_power includes 600 phantom shadows
    - All other farmers' rewards are diluted by the 400 phantom shadows
    - No recovery path exists
```

### Verification Steps

1. Query boost-farm: `get_farmer(alice)` -> FarmerSeed shows `shadow_amount = 600`
2. Query ref-exchange: `get_shadow_records(alice)` -> ShadowRecord shows `shadow_in_farm = 200`
3. The 400-unit discrepancy is the permanent phantom shadow
4. Alice continues earning farming rewards on 600 shadow_amount worth of seed power
5. Alice cannot call `shadow_action(FromFarming, 400)` on ref-exchange because `max_amount = 200`

---

## References

- `ref-exchange/src/shadow_actions.rs`: https://github.com/ref-finance/ref-contracts/blob/main/ref-exchange/src/shadow_actions.rs
- `ref-exchange/src/account_deposit.rs` (ShadowRecord): https://github.com/ref-finance/ref-contracts/blob/main/ref-exchange/src/account_deposit.rs
- `boost-farm/src/shadow_actions.rs` (on_remove_shadow): https://github.com/ref-finance/boost-farm/blob/main/contracts/boost-farming/src/shadow_actions.rs
- Immunefi bounty page: https://immunefi.com/bounty/reffinance/
