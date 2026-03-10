# Raw Investigation Notes

## Code Architecture

### Pinocchio Module (new low-level rewrite)
The `pinocchio/` module is a complete rewrite of liquidity management using pinocchio
(low-level Solana account manipulation, no Anchor runtime overhead).
Key ported files:
- `pinocchio/ported/manager_liquidity_manager.rs` — DIFF against `manager/liquidity_manager.rs`
- `pinocchio/ported/manager_tick_array_manager.rs` — DIFF against `manager/tick_array_manager.rs`

PRIORITY: Any rounding direction change between the two impls = critical.

### AdaptiveFeeInfo stored in Oracle PDA
- Oracle PDA = seeds: [b"oracle", whirlpool.key()]
- AdaptiveFeeInfo = { constants: AdaptiveFeeConstants, variables: AdaptiveFeeVariables }
- Stored inside the Oracle account, read via OracleAccessor
- SwapV2 passes oracle as UncheckedAccount — but seed check exists in anchor constraint

### Extension Segments in reward_infos
Whirlpool uses `reward_infos[0].extension` as `reward_authority` Pubkey.
`reward_infos[1].extension` and `reward_infos[2].extension` are used for
`WhirlpoolExtensionSegmentPrimary` and `WhirlpoolExtensionSegmentSecondary`.
This is repurposed space from the migration — very non-obvious.
Serialization uses `.expect()` calls (see whirlpool.rs:411-435).

### SparseSwapTickSequenceBuilder
- Tick arrays: tick_array_0/1/2 are fixed accounts + supplemental from remaining_accounts
- `try_build()` validates each array is the correct PDA for the whirlpool
- If wrong tick array passed, should error — VERIFY this validation is complete

## Key Questions for Further Research

1. Can `update_reference` set `volatility_reference > max_volatility_accumulator`?
   -> Read `state/oracle.rs` AdaptiveFeeVariables::update_reference impl
   -> If reduction_factor = 10000, volatility_reference = volatility_accumulator = max_acc
   -> Can be set exactly to max, not above — BUT admin can later reduce max

2. Does `reset_position_range` check position.liquidity == 0?
   -> Read `state/position.rs` Position::reset_position_range
   -> If not: critical — fee_growth_checkpoint becomes wrong for new range

3. Does OracleAccessor validate discriminator of oracle account?
   -> Read `state/oracle.rs` OracleAccessor::new
   -> If not: could pass uninitialized account, get zero adaptive_fee_info

4. Two-hop swap with transfer-fee intermediate token:
   -> Read `instructions/v2/two_hop_swap.rs`
   -> Intermediate token transferred user→vault→user between two swaps
   -> If transfer fee applied, amount_in of pool2 < amount_out of pool1
   -> Is this delta accounted for?

5. lock_position / transfer_locked_position:
   -> New feature: positions can be locked (cannot remove liquidity)
   -> What happens to locked position rewards? Can they still be collected?
   -> Is there a time lock or is locking permanent?

## Dangerous Patterns Found by Static Scanner

### wrapping_add in protocol fee (CONFIRMED H-02):
`swap_manager.rs:284`: `next_protocol_fee.wrapping_add(delta)`

### expect() in extension segment deserialization (NEW FINDING):
`whirlpool.rs:111`: `.expect("Failed to deserialize WhirlpoolExtensionSegmentPrimary")`
`whirlpool.rs:116`: `.expect("Failed to deserialize WhirlpoolExtensionSegmentSecondary")`
These panic if on-chain account data is malformed. If somehow the extension data
gets corrupted (e.g., via a migration bug), ALL swaps on that pool fail permanently.

### Multiple panic! in fee_rate_manager.rs (M-01 related):
Lines 626, 709, 789, 866, 946, 2091 — all "variant expected" panics in match arms.

## Numbers to Double-Check

- VOLATILITY_ACCUMULATOR_SCALE_FACTOR = 10_000 (need to confirm from state/oracle.rs)
- ADAPTIVE_FEE_CONTROL_FACTOR_DENOMINATOR = 1_000_000_000 (from state mod)
- MAX_FEE_RATE = u16::MAX in math/mod.rs? Or hardcoded? Affects fee rate cap logic.
- FEE_RATE_HARD_LIMIT = 100_000 in fee_rate_manager.rs — confirmed.

## Potential Zero-Day Angles

### 1. Extension Segment Panic on Corrupted Pool
If `reward_infos[1].extension` or `reward_infos[2].extension` is set to values that
fail BorshDeserialization as `WhirlpoolExtensionSegmentPrimary`, every instruction
that calls `whirlpool.extension_segment_primary()` will panic = permanent DoS on pool.
Can this be triggered? The migration instruction zeros out these fields, which is
what the "migrated already" check looks for.

### 2. Two-Hop Swap Intermediate Token Transfer Fee Bypass
See above. If pool1.token_b == pool2.token_a and that token has transfer_fee:
- Pool1 sends `amount_out_1` to user_account
- User_account receives `amount_out_1 * (1 - fee)` (transfer fee applied)
- Pool2 takes from user_account: sends `amount_in_2`
- If `amount_in_2 > user_balance_after_fee`, swap should fail
- But if two_hop_swap calculates `amount_in_2 = amount_out_1` (without accounting for fee),
  it could try to transfer more than the user received

### 3. Adaptive Fee Skip Logic Race Condition
`advance_tick_group_after_skip` uses `tick_index_from_sqrt_price(&sqrt_price)` to
recalculate the tick index. If the conversion is lossy (floor), the tick_group_index
could be off by one, causing the accumulator update to apply to the wrong group.
Over many swaps, this could systematically skew the volatility tracking.

## Files Not Yet Read

- [ ] state/oracle.rs  — HIGHEST PRIORITY (AdaptiveFeeVariables internals)
- [ ] state/position.rs — check reset_position_range impl
- [ ] instructions/v2/two_hop_swap.rs — check intermediate transfer fee handling
- [ ] instructions/lock_position.rs — new feature
- [ ] manager/liquidity_manager.rs — position fee checkpoint logic
- [ ] pinocchio/ported/manager_liquidity_manager.rs — diff against above
- [ ] math/token_math.rs — get_amount_delta_a/b rounding direction
- [ ] util/sparse_swap.rs — SparseSwapTickSequenceBuilder validation
