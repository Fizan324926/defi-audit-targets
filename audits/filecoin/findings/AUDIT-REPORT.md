# Filecoin Protocol Security Audit Report

**Date:** 2026-03-03
**Protocol:** Filecoin (go-f3, builtin-actors, ref-fvm, lotus)
**Bounty Program:** Immunefi — Max $150K Critical, $100K High
**Scope:** 4 core repositories (2,212+ source files)
**Result:** CLEAN — 0 exploitable vulnerabilities, 4 Informational findings

## Scope

| Repository | Language | Files | Focus Area |
|-----------|----------|-------|------------|
| builtin-actors | Rust | 354 | On-chain actors (market, miner, multisig, paych, reward, power, verifreg, EVM) |
| ref-fvm | Rust | 278 | Filecoin Virtual Machine (WASM execution, gas metering, memory safety) |
| go-f3 | Go | 206 | Fast Finality (GossiPBFT consensus protocol) |
| lotus | Go | 1,374 | Node implementation (mempool, P2P, chain sync, API) |

## Methodology

1. **Architecture mapping** — 4 parallel exploration agents mapped each repository's architecture, security boundaries, and trust model
2. **Hypothesis generation** — 26 specific vulnerability hypotheses across consensus, financial, VM, and network layers
3. **Deep audit** — 3 parallel deep audit agents + manual code review targeting each hypothesis with full code tracing
4. **Manual verification** — Key panic vectors, quorum math, read-only enforcement, and power scaling verified by hand

## Findings Summary

| ID | Title | Severity | Exploitable | Category |
|----|-------|----------|-------------|----------|
| F-01 | LOTUS_IGNORE_DRAND runtime environment variable | Informational | No (requires local access) | Configuration |
| F-02 | install_actor charge-after-use gas pattern | Informational | No (cached, limited) | Gas Metering |
| F-03 | Debug syscalls skip kernel-specific gas charge | Informational | No (disabled in production) | Gas Metering |
| F-04 | Stale comment in quorum arithmetic | Informational | N/A | Documentation |

## Detailed Findings

### F-01: LOTUS_IGNORE_DRAND Runtime Environment Variable [Informational]

**File:** `lotus/chain/consensus/filcns/filecoin.go:243`

Unlike `InsecurePoStValidation` which is properly gated behind Go build tags (`//go:build debug`), the `LOTUS_IGNORE_DRAND` environment variable can be set on any production binary. When set to `"_yes_"`, it completely bypasses beacon randomness verification for block validation.

**Impact:** An operator or attacker with environment access to a node could bypass a critical consensus check. Requires local access to set environment variables, limiting exploitability.

**Recommendation:** Gate behind a build tag like `InsecurePoStValidation`, or remove from production code entirely.

### F-02: install_actor Charge-After-Use Gas Pattern [Informational]

**File:** `ref-fvm/fvm/src/kernel/default.rs:887-905`

The `install_actor` syscall calls `preload_all` (which validates and compiles WASM) before charging gas. If gas runs out during the charge, the compilation work was already done. This is intentional (gas charge depends on code size) and the compiled module is cached, but creates a small window of unmetered computation.

### F-03: Debug Syscalls Skip Kernel-Specific Gas [Informational]

**File:** `ref-fvm/fvm/src/kernel/default.rs:960-1021`

The `debug::log`, `debug::store_artifact`, and `debug::enabled` syscalls do not charge kernel-specific gas. These are gated by `actor_debugging` which defaults to `false`, making them no-ops in production. The base `OnSyscall` charge still applies.

### F-04: Stale Comment in Quorum Arithmetic [Informational]

**File:** `go-f3/gpbft/gpbft.go:1490`

Comment says `// uint32 because 2 * whole exceeds int64` but `whole` is `ScaledTotal` (max ~65535), and `2 * 65535 = 131070` which is well within `int64` range. Harmless documentation artifact.

## Hypotheses Tested

### GossiPBFT Consensus (go-f3) — 7 hypotheses, 0 vulnerabilities

| # | Hypothesis | Result | Key Finding |
|---|-----------|--------|-------------|
| 1 | Power scaling rounding affects quorum | NO | Truncation floor preserves proportional accuracy; `divCeil` adds safety margin |
| 2 | Equivocation detection gaps | NO | `receiveSender()` first-message-wins design correct under BFT |
| 3 | Justification round validation (MaxUint64) | NO | Sentinel value; justification needs valid aggregate sig over the actual round |
| 4 | Panic vectors causing node crash | NO | All 16 panics unreachable from external input OR caught by `defer recover()` |
| 5 | Round skipping manipulation | NO | Requires valid justification (2/3 quorum) from prior round |
| 6 | Chain value manipulation | NO | Length limits (128), epoch ordering, base consistency checks |
| 7 | Ticket/VRF manipulation | NO | Domain separation, instance/round binding, power-weighted ranking |

### Builtin Actors — 8 hypotheses, 0 vulnerabilities

| # | Hypothesis | Result | Key Finding |
|---|-----------|--------|-------------|
| 1 | Market actor escrow fund theft | NO | `subtract_with_minimum` enforces `locked <= escrow` invariant |
| 2 | Miner actor monetary overflow (Q.128) | NO | BigInt (arbitrary precision) eliminates overflow/underflow |
| 3 | Payment channel fund theft | NO | Strict nonce monotonicity, settle delay, balance checks |
| 4 | Multisig transaction manipulation | NO | Threshold >= 1 enforced, approvals purged on signer removal |
| 5 | Reward distribution manipulation | NO | System-actor caller gating (`SYSTEM_ACTOR_ADDR`) |
| 6 | Power actor inflation | NO | `Type::Miner` caller check + proof verification |
| 7 | Verified registry datacap minting | NO | Verifier authorization + allowance deduction |
| 8 | EVM precompile attacks | NO | Input validation, delegatecall-only for `call_actor` |

### FVM (ref-fvm) — 5 hypotheses, 0 vulnerabilities

| # | Hypothesis | Result | Key Finding |
|---|-----------|--------|-------------|
| 1 | Gas metering bypass | NO | Dual-layer: WASM instruction injection + per-syscall charging |
| 2 | WASM memory safety | NO | 512 MiB/instance, 2 GiB total, wasmtime ResourceLimiter |
| 3 | Syscall input validation | NO | `try_slice` bounds checking, `check_bounds` overflow-safe |
| 4 | Read-only mode enforcement | NO | Checked on set_root, self_destruct, create_actor, emit_event, value transfer |
| 5 | Call stack depth attacks | NO | 1024 depth limit enforced in `with_stack_frame` |

### Lotus Node — 6 hypotheses, 0 vulnerabilities

| # | Hypothesis | Result | Key Finding |
|---|-----------|--------|-------------|
| 1 | Mempool DoS | NO | 10 msgs/actor untrusted, 64KB max, baseFee check, pruning |
| 2 | P2P message amplification | NO | LRU dedup cache, peer blacklisting, pubsub validation |
| 3 | Chain sync manipulation | NO | Fast checks first, parallel validation, MaxHeightDrift=5 |
| 4 | API authentication bypass | NO | JWT-based `PermissionedProxy`, `perm:admin` annotations |
| 5 | Environment variable overrides | PARTIAL | `LOTUS_IGNORE_DRAND` is runtime-settable (see F-01) |
| 6 | Block validation bypass | NO | 13-point comprehensive validation, all checks mandatory |

## Key Defensive Patterns Observed

1. **BigInt everywhere** — Filecoin uses arbitrary-precision integers (`BigInt`/`TokenAmount`) for ALL monetary math, eliminating overflow/underflow concerns that plague Solidity contracts

2. **Strict caller validation** — Every actor method validates its caller using `rt.validate_immediate_caller_is()` or `rt.validate_immediate_caller_type()`. System operations are locked to system actors

3. **Atomic state transactions** — The `rt.transaction()` pattern ensures state changes are atomic. External calls outside transactions cannot corrupt intermediate state

4. **Dual-layer gas metering** — WASM instruction-level injection + per-syscall charging with `OnSyscall` base cost

5. **Panic recovery** — GossiPBFT wraps all API methods in `defer recover()`, converting panics to error values

6. **Conservative quorum math** — `divCeil` rounds UP the threshold, preventing rounding-induced false quorums. The 16-bit scaling range (0xffff) is sufficient for Filecoin's participant count

7. **Escrow invariant enforcement** — Market actor's dual-table design (escrow + locked) with `subtract_with_minimum` guarantees `locked <= escrow`

8. **Read-only propagation** — FVM read-only flag uses OR logic (`self.read_only || flags.read_only()`), only becoming MORE restrictive through call chains

## Conclusion

The Filecoin protocol demonstrates exceptionally mature security engineering across all four audited components. The use of arbitrary-precision arithmetic, strict access control via caller type validation, atomic state transactions, dual-layer gas metering, and comprehensive input validation creates a defense-in-depth architecture with no exploitable attack surfaces found. The 4 informational findings are design-acknowledged properties that pose no risk to mainnet security.
