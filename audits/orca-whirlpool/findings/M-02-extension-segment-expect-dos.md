# M-02: Extension Segment `.expect()` Calls — RETRACTED (FALSE POSITIVE)

**Severity:** ~~Medium~~ — **RETRACTED**
**File:** `programs/whirlpool/src/state/whirlpool.rs:109-117`
**Status:** FALSE POSITIVE — struct is designed to always be exactly 32 bytes

---

## Retraction

Initial assessment was incorrect. The structs are designed with explicit reserved padding to always fit exactly in the 32-byte extension field.

```rust
// whirlpool.rs (near line 396)
pub struct WhirlpoolExtensionSegmentPrimary {
    // total length must be 32 bytes
    pub control_flags: u16,   // 2 bytes
    pub reserved: [u8; 30],   // 30 bytes (intentional padding)
}

pub struct WhirlpoolExtensionSegmentSecondary {
    // total length must be 32 bytes
    pub reserved: [u8; 32],   // 32 bytes (fully reserved)
}
```

The `reserved` fields serve as explicit size padding. Additionally, `to_bytes()` asserts the serialized size is exactly 32 bytes at compile time. `[0u8; 32]` (all zeros) deserializes successfully as both structs:
- `WhirlpoolExtensionSegmentPrimary { control_flags: 0, reserved: [0; 30] }` ✓
- `WhirlpoolExtensionSegmentSecondary { reserved: [0; 32] }` ✓

The schema evolution risk is mitigated by the explicit reserved buffer: any future field addition would replace `reserved` bytes, keeping the total at 32 bytes. The `.expect()` is effectively unreachable for any currently valid pool state.

**DO NOT SUBMIT to Immunefi.**

---

## Original Finding (preserved for reference)

---

## Description

The `Whirlpool` account stores `WhirlpoolExtensionSegmentPrimary` and `WhirlpoolExtensionSegmentSecondary` in the `reward_infos[1].extension` and `reward_infos[2].extension` byte arrays (32 bytes each). These are deserialized using Borsh with `.expect()`:

```rust
// whirlpool.rs:111
pub fn extension_segment_primary(&self) -> WhirlpoolExtensionSegmentPrimary {
    WhirlpoolExtensionSegmentPrimary::try_from_slice(&self.reward_infos[1].extension)
        .expect("Failed to deserialize WhirlpoolExtensionSegmentPrimary")
}

// whirlpool.rs:116
pub fn extension_segment_secondary(&self) -> WhirlpoolExtensionSegmentSecondary {
    WhirlpoolExtensionSegmentSecondary::try_from_slice(&self.reward_infos[2].extension)
        .expect("Failed to deserialize WhirlpoolExtensionSegmentSecondary")
}
```

In Solana BPF programs, `.expect()` on a `Err` result causes an immediate `panic!`, which aborts the transaction with a non-descriptive error. Unlike `Result<>` errors, panics cannot be caught.

---

## Architecture Context

The extension segment data is written by the migration instruction `migrate_repurpose_reward_authority_space`, which zeroes out these fields, and by any instruction that initializes or modifies the extension data. The repurposing of `reward_infos[n].extension` fields for non-reward-info data is a non-obvious design choice.

```
Whirlpool.reward_infos[0].extension → reward_authority Pubkey (original use, preserved)
Whirlpool.reward_infos[1].extension → WhirlpoolExtensionSegmentPrimary (32 bytes, repurposed)
Whirlpool.reward_infos[2].extension → WhirlpoolExtensionSegmentSecondary (32 bytes, repurposed)
```

---

## Impact

Any instruction that calls `extension_segment_primary()` or `extension_segment_secondary()` on a pool with malformed extension data will **panic and permanently abort** all transactions involving that pool. Since these are called during swaps, the pool becomes permanently non-functional — a complete DoS.

**Affected instructions (any that read extension segments):**
- `swap` and `swap_v2`
- `two_hop_swap`
- Any future instruction that reads pool extension state

---

## Trigger Conditions

**Scenario 1: Migration corruption**
The `migrate_repurpose_reward_authority_space` instruction writes `[0u8; 32]` to both extension fields. If a migration is interrupted mid-execution, or if a future migration instruction writes data that doesn't deserialize correctly (wrong Borsh encoding), the `.expect()` panics on every subsequent swap.

**Scenario 2: Direct account manipulation**
While Solana programs cannot modify each other's accounts without authorization, any bug in the whirlpool program itself that writes malformed data to `reward_infos[1-2].extension` would trigger this.

**Scenario 3: Schema evolution**
If `WhirlpoolExtensionSegmentPrimary` or `Secondary` grows beyond 32 bytes in a future upgrade, existing pools with the old 32-byte format would fail to deserialize with the new schema, causing a permanent DoS on all previously-created pools.

---

## Proof of Concept

```python
# scripts/verify/verify_M02_extension_segment_dos.py
# Demonstrates that invalid Borsh data in extension fields causes panic behavior

import struct

# WhirlpoolExtensionSegmentPrimary expected Borsh layout (must fit in 32 bytes)
# If the struct is ever changed to require e.g. 33 bytes, any 32-byte stored value
# will fail to deserialize.

# Simulate old pool with [0u8; 32] in extension field
extension_data = bytes(32)  # all zeros

# If the struct now expects a different layout (e.g. a u64 field added):
# Borsh would try to read beyond the 32-byte boundary -> error -> panic

# This is a schema evolution problem: no versioning on extension fields.
print("Extension segment panic analysis:")
print(f"  Extension field size: 32 bytes (fixed)")
print(f"  Borsh deserialization: no error handling -> panic on failure")
print(f"  All swaps on affected pool: permanently DoS'd")
print(f"  Recovery: requires program upgrade + manual data repair")
```

---

## Fix

Replace `.expect()` with proper `Result` propagation:

```rust
// BEFORE (panics on bad data):
pub fn extension_segment_primary(&self) -> WhirlpoolExtensionSegmentPrimary {
    WhirlpoolExtensionSegmentPrimary::try_from_slice(&self.reward_infos[1].extension)
        .expect("Failed to deserialize WhirlpoolExtensionSegmentPrimary")
}

// AFTER (returns error instead):
pub fn extension_segment_primary(&self) -> Result<WhirlpoolExtensionSegmentPrimary> {
    WhirlpoolExtensionSegmentPrimary::try_from_slice(&self.reward_infos[1].extension)
        .map_err(|_| ErrorCode::InvalidExtensionSegment.into())
}
```

All callers of `extension_segment_primary()` and `extension_segment_secondary()` would need to handle the `Result<>` type, but this is the correct, panic-free approach.

---

## References

- Vulnerable code: `state/whirlpool.rs:111,116`
- Migration instruction: `instructions/migrate_repurpose_reward_authority_space.rs`
- Static scanner result: `expect_in_production` HIGH pattern — `whirlpool.rs:111,116`
