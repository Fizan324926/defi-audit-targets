# M-01: Production `panic!` in Migration Instruction — OUT OF SCOPE

**Severity:** ~~Medium~~ — **OUT OF SCOPE for Immunefi**
**File:** `programs/whirlpool/src/instructions/migrate_repurpose_reward_authority_space.rs:19`
**Status:** OUT OF SCOPE — Orca's Immunefi rules explicitly exclude "best practice critiques"

---

## Scope Ruling

Orca's Immunefi bug bounty program uses **Primacy of Rules** and explicitly lists "best practice critiques or suggestions" as out of scope. Using `panic!` instead of `return Err(ErrorCode::...)` is a code quality/best practice issue with no direct exploitable financial impact:

- No user funds at risk
- No LP funds at risk
- Migration is a one-time admin operation
- The only consequence is integrators receiving an untyped error instead of a typed one

**DO NOT SUBMIT to Immunefi.**

---

## Original Finding (preserved for reference)

---

## Description

The `migrate_repurpose_reward_authority_space` instruction handler contains a raw `panic!` call in production code:

```rust
pub fn handler(ctx: Context<MigrateRepurposeRewardAuthoritySpace>) -> Result<()> {
    let whirlpool = &mut ctx.accounts.whirlpool;

    if whirlpool.reward_infos[2].extension == [0u8; 32] {
        panic!("Whirlpool has been migrated already");  // LINE 19 — PRODUCTION PANIC
    }

    whirlpool.reward_infos[1].extension = [0u8; 32];
    whirlpool.reward_infos[2].extension = [0u8; 32];
    Ok(())
}
```

In Solana BPF, `panic!` causes the program to abort with a non-recoverable error, immediately failing the transaction. This is distinct from returning an `Err(...)` from `Result`, which is the idiomatic Anchor error-handling approach.

---

## Impact

Any caller (including integrators or front-ends) that calls this instruction on an already-migrated pool receives an unstructured panic abort rather than a typed `ErrorCode`. This:

1. **Breaks error handling** in integrators — they cannot distinguish "already migrated" from other errors
2. **Causes unnecessary transaction failures** — the error message is not surfaced as a standard Anchor error
3. **May suppress logs** in some RPC configurations that handle BPF panics differently

The comment notes: "Whirlpool accounts with `reward_infos[2].authority == [0u8; 32]` do NOT exist on mainnet." If this assumption ever becomes wrong (e.g., future migration changes the extension format), this check could panic on valid pools.

---

## Fix

```rust
// Replace panic! with a proper error return
if whirlpool.reward_infos[2].extension == [0u8; 32] {
    return Err(ErrorCode::AlreadyMigrated.into());  // Add new error code
}
```

---

## Additional Context

The `fee_rate_manager.rs` also contains multiple production `panic!` calls:

```
fee_rate_manager.rs:626   _ => panic!("Adaptive variant expected."),
fee_rate_manager.rs:709   _ => panic!("Adaptive variant expected."),
fee_rate_manager.rs:789   _ => panic!("Adaptive variant expected."),
fee_rate_manager.rs:866   _ => panic!("Adaptive variant expected."),
fee_rate_manager.rs:946   _ => panic!("Adaptive variant expected."),
fee_rate_manager.rs:2091  _ => panic!("Some and Adaptive variant expected."),
```

These are in `match` arms that should be unreachable if the calling code is correct, but any future refactor that passes a `Static` variant where `Adaptive` is expected will cause a DoS on that swap path. These should use `unreachable!()` with a descriptive message, or better, be refactored to return `Result`.
