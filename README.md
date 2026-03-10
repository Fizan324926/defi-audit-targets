# defi-audit-targets

Research repository for identifying and prioritizing Immunefi bug bounty programs best suited for code-audit-style vulnerability research, and publishing findings from active audits.

---

## Reference Guides

| Guide | Purpose |
|-------|---------|
| [`AUDIT-AI-RULES.md`](AUDIT-AI-RULES.md) | **AI audit methodology** — full process: scope determination, codebase exploration, multi-angle analysis, exploit development, reporting, repo organization, and complete vulnerability catalog |
| [`IMMUNEFI-REPORT-GUIDE.md`](IMMUNEFI-REPORT-GUIDE.md) | Report format, PoC requirements, severity classification, submission rules, and negotiation guide |

---

## All Audits

| Program | Max Bounty | Language | Findings | Audit Folder | Status |
|---------|-----------|----------|----------|--------------|--------|
| [LayerZero](https://immunefi.com/bug-bounty/layerzero/) | $15,000,000 | Solidity + Rust | 0 (clean audit) | [`audits/layerzero/`](audits/layerzero/AUDIT-REPORT.md) | Complete |
| [Sky (MakerDAO)](https://immunefi.com/bug-bounty/sky/) | $10,000,000 | Solidity | 1 High, 2 Medium | [`audits/sky/`](audits/sky/README.md) | Complete |
| [GMX V2 Synthetics](https://immunefi.com/bug-bounty/gmx/) | $5,000,000 | Solidity | 2 High | [`audits/gmx-synthetics/`](audits/gmx-synthetics/README.md) | Complete |
| [Optimism](https://immunefi.com/bug-bounty/optimism/) | $2,000,042 | Solidity + Go | 1 Medium | [`audits/optimism/`](audits/optimism/README.md) | Complete |
| [Olympus DAO](https://immunefi.com/bug-bounty/olympus/) | $3,333,333 | Solidity | 1 Medium-High, 5 Medium | [`audits/olympus-dao/`](audits/olympus-dao/bophades/findings/AUDIT-REPORT.md) | Complete |
| [Orca Whirlpool](https://immunefi.com/bug-bounty/orca/) | $500,000 | Rust / Solana | 1 Medium (borderline) | [`audits/orca-whirlpool/`](audits/orca-whirlpool/README.md) | Complete |
| [Beanstalk](https://immunefi.com/bug-bounty/beanstalk/) | $1,100,000 | Solidity | 1 Medium-High | [`audits/beanstalk/`](audits/beanstalk/findings/AUDIT-REPORT.md) | Complete |
| [Gearbox V3](https://immunefi.com/bug-bounty/gearbox/) | $200,000 | Solidity | 0 (clean audit) | [`audits/gearbox/`](audits/gearbox/AUDIT-REPORT.md) | Complete |
| [Reserve Protocol](https://immunefi.com/bug-bounty/reserve/) | $500,000 | Solidity | 0 (clean audit) | [`audits/reserve-protocol/`](audits/reserve-protocol/findings/AUDIT-REPORT.md) | Complete |
| [Gains Network](https://immunefi.com/bug-bounty/gains-network/) | $200,000 | Solidity | 0 (clean audit) | [`audits/gains-network/`](audits/gains-network/findings/AUDIT-REPORT.md) | Complete |
| [Kamino Finance](https://immunefi.com/bug-bounty/kamino/) | $100,000 | Rust / Solana | 1 High, 2 Low-Medium, 2 Low | [`audits/kamino/`](audits/kamino/findings/AUDIT-REPORT.md) | Complete |
| [Chainlink](https://immunefi.com/bug-bounty/chainlink/) | $3,000,000 | Solidity + Rust + Go | 0 (clean audit) | [`audits/chainlink/`](audits/chainlink/findings/AUDIT-REPORT.md) | Complete |
| [Origin Protocol](https://immunefi.com/bug-bounty/originprotocol/) | $1,000,000 | Solidity | 2 Medium (Immunefi) | [`audits/origin-protocol/`](audits/origin-protocol/findings/CONSOLIDATED-AUDIT-REPORT.md) | Complete |
| [Yearn Finance](https://immunefi.com/bug-bounty/yearnfinance/) | $200,000 | Solidity + Vyper | 5 Medium | [`audits/yearn-finance/`](audits/yearn-finance/findings/CONSOLIDATED-AUDIT-REPORT.md) | Complete |
| [Spark (SparkLend)](https://immunefi.com/bug-bounty/spark/) | $5,000,000 | Solidity | 0 (clean audit) | [`audits/spark/`](audits/spark/findings/AUDIT-REPORT.md) | Complete |
| [Merchant Moe (LFJ)](https://immunefi.com/bug-bounty/merchantmoe/) | $100,000 | Solidity | 0 (clean audit) | [`audits/merchant-moe/`](audits/merchant-moe/findings/AUDIT-REPORT.md) | Complete |
| [OpenZeppelin](https://immunefi.com/bug-bounty/openzeppelin/) | $500,000 | Solidity | 2 High, 4 Medium | [`audits/openzeppelin/`](audits/openzeppelin/findings/AUDIT-REPORT.md) | Complete |
| [Flamingo Finance](https://immunefi.com/bug-bounty/flamingo-finance/) | $1,000,000 | C# (Neo N3) | 2 Medium | [`audits/flamingo-finance/`](audits/flamingo-finance/findings/AUDIT-REPORT.md) | Complete |
| [Ref Finance](https://immunefi.com/bug-bounty/reffinance/) | $250,000 | Rust (NEAR) | 2 Medium | [`audits/ref-finance/`](audits/ref-finance/findings/AUDIT-REPORT.md) | Complete |
| [Hathor Network](https://immunefi.com/bug-bounty/hathornetwork/) | $30,000 | Python + JS | 1 Critical, 2 High, 1 Medium | [`audits/hathor-network/`](audits/hathor-network/findings/AUDIT-REPORT.md) | Complete |
| [Stellar](https://immunefi.com/bug-bounty/stellar/) | $250,000 | Rust + C++ | 0 (clean audit) | [`audits/stellar/`](audits/stellar/findings/AUDIT-REPORT.md) | Complete |
| [Xterio](https://immunefi.com/bug-bounty/xterio/) | $80,000 | Solidity | 0 (clean audit) | [`audits/xterio/`](audits/xterio/findings/AUDIT-REPORT.md) | Complete |
| [Filecoin](https://immunefi.com/bug-bounty/filecoin/) | $150,000 | Go + Rust | 0 (clean audit) | [`audits/filecoin/`](audits/filecoin/findings/AUDIT-REPORT.md) | Complete |

---

## All Confirmed Findings (Quick Reference)

| # | Program | ID | Severity | Title | Report |
|---|---------|-----|----------|-------|--------|
| 1 | Sky | 001 | **HIGH** | `setRewardsDuration` mid-period truncation destroys staker yield | [Report](audits/sky/findings/001-staking-rewards-duration-yield-loss.md) |
| 2 | Sky | 002 | **MEDIUM** | `kick()` reverts when `farm==address(0)` + `burn<WAD` | [Report](audits/sky/findings/002-splitter-farm-zero-dos.md) |
| 3 | Sky | 003 | **MEDIUM** | `setRewardsDuration(0)` bricks reward distribution | [Report](audits/sky/findings/003-staking-rewards-zero-duration.md) |
| 4 | GMX | VULN-003 | **HIGH** | Relay fee swap hardcodes `minOutputAmount=0` (zero slippage) | [Report](audits/gmx-synthetics/exploits/VULN-003-relay-fee-swap-zero-slippage.md) |
| 5 | GMX | VULN-011 | **HIGH** | Missing sequential nonce — keeper reorders/skips relay txns | [Report](audits/gmx-synthetics/exploits/VULN-011-missing-relay-nonce-validation.md) |
| 6 | Optimism | M-01 | **MEDIUM** | `SuperFaultDisputeGame.closeGame()` blocks credit claims during pause | [Report](audits/optimism/findings/IMMUNEFI-SUBMISSION-M01.md) |
| 7 | Orca | H-02 | **MEDIUM** | Protocol fee counter wrapping overflow — silent revenue loss | [Report](audits/orca-whirlpool/findings/H-02-protocol-fee-wrapping-overflow.md) |
| 8 | Olympus | 011 | **MED-HIGH** | CCIP Bridge missing ERC20 rescue — OHM permanently stuck | [Report](audits/olympus-dao/bophades/findings/IMMUNEFI-SUBMISSION-011.md) |
| 9 | Olympus | 012 | **MEDIUM** | LZ Bridge incomplete shutdown — `bridgeActive` doesn't block mints | [Report](audits/olympus-dao/bophades/findings/IMMUNEFI-SUBMISSION-012.md) |
| 10 | Olympus | 005 | **MEDIUM** | Clearinghouse `rebalance()` fund-time accumulation | [Report](audits/olympus-dao/bophades/findings/IMMUNEFI-SUBMISSION-005.md) |
| 11 | Olympus | 008 | **MEDIUM** | Stale price oracle wall swap arbitrage (24h window) | [Report](audits/olympus-dao/bophades/findings/IMMUNEFI-SUBMISSION-008.md) |
| 12 | Olympus | 010 | **MEDIUM** | Heart beat front-running via predictable price updates | [Report](audits/olympus-dao/bophades/findings/IMMUNEFI-SUBMISSION-010.md) |
| 13 | Olympus | 001 | **MEDIUM** | YieldRepo hardcoded `backingPerToken` ($11.33) | [Report](audits/olympus-dao/bophades/findings/IMMUNEFI-SUBMISSION-001.md) |
| 14 | Beanstalk | 001 | **MED-HIGH** | SOP/Flood zero-slippage swap + manipulable spot deltaB | [Report](audits/beanstalk/findings/IMMUNEFI-SUBMISSION-001.md) |
| 15 | Kamino | 002 | **HIGH** | Permissionless crank exploits missing multiplier validation to corrupt xStocks prices | [Report](audits/kamino/findings/IMMUNEFI-SUBMISSION-002.md) |
| 16 | Kamino | 001 | **LOW-MED** | ChainlinkX v10 ignores `tokenized_price` — manual `price * multiplier` may diverge | [Report](audits/kamino/findings/IMMUNEFI-SUBMISSION-001.md) |
| 17 | Origin | 001 | **MEDIUM** | OETHPlumeVault `_mint` override dead code — access control bypass | [Report](audits/origin-protocol/findings/IMMUNEFI-SUBMISSION-001.md) |
| 18 | Origin | 002 | **MEDIUM** | OETHOracleRouter unsafe int256→uint256 cast (missing SafeCast) | [Report](audits/origin-protocol/findings/IMMUNEFI-SUBMISSION-002.md) |
| 19 | Yearn | 001 | **MEDIUM** | CombinedChainlinkOracle missing zero/negative price validation — redemption DoS | [Report](audits/yearn-finance/findings/IMMUNEFI-SUBMISSION-001.md) |
| 20 | Yearn | 002 | **MEDIUM** | Gauge.sol residual approval accumulation to VE_YFI_POOL | [Report](audits/yearn-finance/findings/IMMUNEFI-SUBMISSION-002.md) |
| 21 | Yearn | 003 | **MEDIUM** | RewardPool/dYFIRewardPool division by zero when ve_supply is zero | [Report](audits/yearn-finance/findings/IMMUNEFI-SUBMISSION-003.md) |
| 22 | Yearn | 004 | **MEDIUM** | Zap.sol zero slippage on intermediate Curve pool operations — MEV | [Report](audits/yearn-finance/findings/IMMUNEFI-SUBMISSION-004.md) |
| 23 | Yearn | 005 | **MEDIUM** | StakingRewardDistributor division by zero when total_weight is zero | [Report](audits/yearn-finance/findings/IMMUNEFI-SUBMISSION-005.md) |

| 24 | OpenZeppelin | 001 | **HIGH** | LimitOrderHook withdrawal underflow — permanent fund lock for later withdrawers | [Report](audits/openzeppelin/findings/IMMUNEFI-SUBMISSION-001.md) |
| 25 | OpenZeppelin | 002 | **HIGH** | VotesConfidential FHE.sub underflow — voting power wrap-around via modular arithmetic | [Report](audits/openzeppelin/findings/IMMUNEFI-SUBMISSION-002.md) |
| 26 | Flamingo | 001 | **MEDIUM** | ProxySwapTokenInForTokenOut checks LP balance instead of input token — swap DoS | [Report](audits/flamingo-finance/findings/IMMUNEFI-SUBMISSION-001.md) |
| 27 | Flamingo | 002 | **MEDIUM** | Staking profit rate integer division truncation — permanent reward loss | [Report](audits/flamingo-finance/findings/IMMUNEFI-SUBMISSION-002.md) |
| 28 | Ref Finance | 001 | **MEDIUM** | Burrow liquidation creates permanent phantom farming shadows | [Report](audits/ref-finance/findings/IMMUNEFI-SUBMISSION-001.md) |
| 29 | Hathor Network | 001 | **CRITICAL** | SystemExit/KeyboardInterrupt sandbox escape — permanent node crash via nano contract | [Report](audits/hathor-network/findings/IMMUNEFI-SUBMISSION-001.md) |
| 30 | Hathor Network | 002 | **HIGH** | Fuel metering + memory limits completely unimplemented — infinite loop/OOM DoS | [Report](audits/hathor-network/findings/IMMUNEFI-SUBMISSION-002.md) |

**Total: 1 Critical, 6 High, 2 Medium-High, 19 Medium, 1 Low-Medium across 22 protocols** (LayerZero + Gearbox V3 + Reserve Protocol + Gains Network + Chainlink + Spark + Merchant Moe + Stellar + Xterio: clean audits — 0 findings)

---

## Audits

### Orca Whirlpool — [`audits/orca-whirlpool/`](audits/orca-whirlpool/README.md)

Concentrated liquidity AMM on Solana (Uniswap V3-style). Covers the adaptive fee system, Pinocchio hot-path rewrite, lock position feature, extension segment storage, and Token-2022 integrations.

**Findings:**

| ID | Severity | Description |
|----|----------|-------------|
| [H-01](audits/orca-whirlpool/findings/H-01-adaptive-fee-u32-underflow.md) | Low | Unsafe u32 subtraction in adaptive fee range calc — invariant maintained |
| [H-02](audits/orca-whirlpool/findings/H-02-protocol-fee-wrapping-overflow.md) | Medium | `wrapping_add` on protocol fee counter — silent revenue loss |
| [M-01](audits/orca-whirlpool/findings/M-01-migrate-production-panic.md) | Medium | Production `panic!` in migrate instruction — untyped error |
| [M-02](audits/orca-whirlpool/findings/M-02-extension-segment-expect-dos.md) | Medium | `.expect()` on Borsh deserialize — permanent pool DoS risk |

**Exploit writeups:**
- [H-02 exploit](audits/orca-whirlpool/findings/exploits/H-02-exploit.md)
- [M-01 exploit](audits/orca-whirlpool/findings/exploits/M-01-exploit.md)
- [M-02 exploit](audits/orca-whirlpool/findings/exploits/M-02-exploit.md)

**Verification scripts:** `audits/orca-whirlpool/scripts/verify/`

---

### Sky Protocol — [`audits/sky/`](audits/sky/README.md)

One of the largest DeFi protocols ($8B+ TVL). CDP stablecoin (DAI/USDS), savings vaults, lockstake governance staking, surplus buyback engine, cross-chain bridges.

**Findings:**

| ID | Severity | Contract | Description |
|----|----------|----------|-------------|
| [001](audits/sky/findings/001-staking-rewards-duration-yield-loss.md) | High | StakingRewards.sol | `setRewardsDuration` mid-period integer truncation destroys staker yield |
| [002](audits/sky/findings/002-splitter-farm-zero-dos.md) | Medium | Splitter.sol | `kick()` reverts when `farm==address(0)` + `burn<WAD`, DoSing SBE |
| [003](audits/sky/findings/003-staking-rewards-zero-duration.md) | Medium | StakingRewards.sol | `setRewardsDuration(0)` permanently bricks reward distribution |
| [004](audits/sky/findings/004-lockstake-lock-no-auth.md) | Medium | LockstakeEngine.sol | `lock()` uses `_getUrn` instead of `_getAuthedUrn` — unauthorized urn manipulation |

---

### Optimism — [`audits/optimism/`](audits/optimism/README.md)

L2 rollup with fault proof system. 162 Solidity files + Go op-node code covering bridges, dispute games, Cannon MIPS64 VM, and superchain interop. Two full audit passes: 120+ vectors investigated.

**Confirmed Findings (1 of 120+):**

| ID | Severity | Contract | Description |
|----|----------|----------|-------------|
| [M-01](audits/optimism/findings/IMMUNEFI-SUBMISSION-M01.md) | Medium | SuperFaultDisputeGame.sol | `closeGame()` pause check before early return blocks `claimCredit()` during system pause |

**Immunefi submission:** [`IMMUNEFI-SUBMISSION-M01.md`](audits/optimism/findings/IMMUNEFI-SUBMISSION-M01.md) (copy-paste ready)
**PoC:** [`PoC_M01_CloseGameOrdering.sol`](audits/optimism/scripts/verify/PoC_M01_CloseGameOrdering.sol) (Foundry test)
**Full audit report:** [`AUDIT-REPORT.md`](audits/optimism/findings/AUDIT-REPORT.md)

---

### Olympus DAO (Bophades) — [`audits/olympus-dao/`](audits/olympus-dao/bophades/findings/AUDIT-REPORT.md)

Kernel-Module-Policy architecture DeFi protocol. OHM token with Range Bound Stability, MonoCooler lending, cross-chain bridges (LayerZero + Chainlink CCIP), yield repurchase, emission management. 50+ contracts, 15,000+ LOC.

**Findings (13 total — 6 Immunefi-submittable):**

| ID | Severity | Contract | Description |
|----|----------|----------|-------------|
| [011](audits/olympus-dao/bophades/findings/IMMUNEFI-SUBMISSION-011.md) | Medium-High | CCIPCrossChainBridge | `withdraw()` only rescues ETH — OHM permanently stuck after failed messages |
| [012](audits/olympus-dao/bophades/findings/IMMUNEFI-SUBMISSION-012.md) | Medium | CrossChainBridge | `bridgeActive` not checked on receive — incomplete emergency shutdown |
| [005](audits/olympus-dao/bophades/findings/IMMUNEFI-SUBMISSION-005.md) | Medium | Clearinghouse | `rebalance()` fund-time accumulation — borrow 54M+ in one block |
| [008](audits/olympus-dao/bophades/findings/IMMUNEFI-SUBMISSION-008.md) | Medium | Operator | Stale price oracle enables wall swap arbitrage within 24h window |
| [010](audits/olympus-dao/bophades/findings/IMMUNEFI-SUBMISSION-010.md) | Medium | Heart/PRICE | Predictable MA updates enable heart beat front-running |
| [001](audits/olympus-dao/bophades/findings/IMMUNEFI-SUBMISSION-001.md) | Medium | YieldRepurchaseFacility | Hardcoded `backingPerToken` ($11.33) diverges from actual backing |

**Additional low-severity findings:** EmissionManager precision loss, Kernel migration stale state, DLGTE OZ internals, Clearinghouse keeper reward accounting, Operator regenerate desync, fullCapacity over-estimation, ConvertibleDepositAuctioneer tick decay.

**Notable safe areas:** MonoCooler (0 findings — exceptionally well-engineered), CoolerLtvOracle, SafeCast, FullMath.

**Full audit report:** [`AUDIT-REPORT.md`](audits/olympus-dao/bophades/findings/AUDIT-REPORT.md)
**Immunefi submissions:** `audits/olympus-dao/bophades/findings/IMMUNEFI-SUBMISSION-001.md` through `013.md`
**PoC files:** `audits/olympus-dao/bophades/scripts/verify/`

---

### Beanstalk Protocol — [`audits/beanstalk/`](audits/beanstalk/findings/AUDIT-REPORT.md)

Credit-based stablecoin protocol on Arbitrum. EIP-2535 Diamond proxy with 37+ facets, Basin DEX (Wells, Pumps), Pipeline, and Tractor automation. 226 Beanstalk + 120 Basin Solidity files covering Silo (deposits/stalk/seeds), Field (pods/soil), Barn (fertilizer), Convert, Season/Sunrise, Flood/SOP, Gauge, and cross-cutting systems.

**Findings (1 confirmed — 60+ hypotheses tested):**

| ID | Severity | Contract | Description |
|----|----------|----------|-------------|
| [001](audits/beanstalk/findings/IMMUNEFI-SUBMISSION-001.md) | Medium-High | LibFlood.sol | SOP/Flood zero-slippage swap + manipulable spot deltaB |

**Basin observations (2):** Pump silent update failure (Medium), Stable2 Newton oscillation (Low).

**Notable safe areas:** Tractor EIP-712 (bounds checking verified), Farm multicall (dual reentrancy guard), Convert capacity (TWAP-protected), BDV calculation (EMA-protected), Diamond admin, Germination system.

**Key false positive eliminated:** `calculateSopPerWell` division by zero — mathematically proved unreachable (shaveToLevel bounded by guard condition).

**Full audit report:** [`AUDIT-REPORT.md`](audits/beanstalk/findings/AUDIT-REPORT.md)
**Season/Sun sub-report:** [`SEASON-SUN-AUDIT-REPORT.md`](audits/beanstalk/findings/SEASON-SUN-AUDIT-REPORT.md)
**Immunefi submission:** [`IMMUNEFI-SUBMISSION-001.md`](audits/beanstalk/findings/IMMUNEFI-SUBMISSION-001.md)
**PoC:** [`PoC_001_SopFloodZeroSlippage.sol`](audits/beanstalk/scripts/verify/PoC_001_SopFloodZeroSlippage.sol)

---

### GMX V2 Synthetics — [`audits/gmx-synthetics/`](audits/gmx-synthetics/README.md)

Decentralized perpetual exchange on Arbitrum/Avalanche ($265-400M TVL, ~$270M daily volume). Covers the Gelato relay system ("GMX Express") for gasless transactions, LayerZero cross-chain bridging, oracle price validation, and position management.

**Both vulnerabilities confirmed LIVE on Arbitrum mainnet** — 230,062+ relay transactions processed since November 2025, ~2,212 txns/day.

**Confirmed Findings (2 of 20 initial — 18 eliminated as false positives):**

| ID | Severity | Description | Estimated Annual Impact |
|----|----------|-------------|------------------------|
| [VULN-003](audits/gmx-synthetics/exploits/VULN-003-relay-fee-swap-zero-slippage.md) | High | `minOutputAmount: 0` hardcoded in relay fee swap — unprotected slippage | $74K-$297K (volatility) |
| [VULN-011](audits/gmx-synthetics/exploits/VULN-011-missing-relay-nonce-validation.md) | High | Random (not sequential) relay nonce — keeper can reorder/skip transactions | $26M+ risk exposure |

**Exploit writeups (with verification script output and on-chain data):**
- [VULN-003 exploit](audits/gmx-synthetics/exploits/VULN-003-relay-fee-swap-zero-slippage.md) — loss tables from price volatility, MEV sandwich model, on-chain deployment proof
- [VULN-011 exploit](audits/gmx-synthetics/exploits/VULN-011-missing-relay-nonce-validation.md) — reordering/skipping demo, cancellation impossibility, real-world damage scenarios

**Verification scripts:** `audits/gmx-synthetics/scripts/`

**False positive analysis:** `audits/gmx-synthetics/exploits/false-positives/` (18 findings with detailed elimination rationale)

### Gearbox Protocol V3 — [`audits/gearbox/`](audits/gearbox/AUDIT-REPORT.md)

Generalized leverage protocol for DeFi. 552 Solidity files across 5 repos: core-v3 (credit accounts, pools, oracles), integrations-v3 (19 protocol adapters), oracles-v3 (LP/composite/updatable price feeds), governance (Governor + timelock), periphery-v3 (zappers, routers, liquidators).

**Result: Clean audit — 0 exploitable vulnerabilities found across ~59 hypotheses.**

The codebase demonstrates exceptional defense-in-depth: accounting-based ERC4626 (immune to donation attacks), same-block debt change protection, dual reentrancy guards, epoch-locked GEAR staking for governance, bounded LP price feeds, safe pricing with reserve feeds, and granular bot permissions.

**Low/Informational observations only:**

| Area | Severity | Description |
|------|----------|-------------|
| PythPriceFeed | Low | Negative price passes confidence check (caught by consumer-level validation) |
| CurveTWAPPriceFeed | Informational | Division-by-zero if Curve pool oracle returns 0 (practically impossible) |

**Full audit report:** [`AUDIT-REPORT.md`](audits/gearbox/AUDIT-REPORT.md)

---

### LayerZero Protocol — [`audits/layerzero/`](audits/layerzero/AUDIT-REPORT.md)

Cross-chain messaging protocol with $15M max Immunefi bounty. V1 (EVM) + V2 (EVM + Solana) covering EndpointV2, DVN verification, OFT token bridges, Executor delivery, and 50+ chain deployments. 60+ Solidity contracts + 20+ Solana Rust programs, ~15,000+ LOC.

**Result: Clean audit — 0 exploitable vulnerabilities found across 107+ hypotheses.**

The protocol demonstrates exceptionally mature defense-in-depth: multi-DVN verification model (required + optional threshold), DVN address binding via msg.sender, lazy inbound nonces with payload hash verification, two-phase compose (store-then-execute), immutable endpoint/token references, role-based ACL with denylist priority, and lossless OFT decimal conversion.

**Low/Informational observations only:**

| Area | Severity | Description |
|------|----------|-------------|
| PriceFeed `_estimateFeeByEid()` | Low | Double-computation for L2 eids (mitigated by explicit config) |
| OFTCore `_toSD()` | Low | Silent uint64 truncation (already fixed in devtools version) |

**Full audit report:** [`AUDIT-REPORT.md`](audits/layerzero/AUDIT-REPORT.md)
**Sub-reports:** [`DVN/Executor/Worker`](audits/layerzero/findings/AUDIT-REPORT-DVN-EXECUTOR-WORKER-2026-03-02.md) | [`OFT/OApp`](audits/layerzero/findings/AUDIT-REPORT-OFT-OAPP-2026-03-02.md)
**False positive documentation:** `audits/layerzero/notes/false-positives/` (7 detailed writeups)

### Kamino Finance — [`audits/kamino/`](audits/kamino/findings/AUDIT-REPORT.md)

Solana DeFi protocol suite: lending (klend), yield vaults (kvault), oracle aggregation (scope), and farming/staking (kfarms). 4 Anchor programs, ~43,700 LOC Rust. Covers reserves, obligations, elevation groups, flash loans, withdrawal queues, ERC4626-like vaults, 40+ oracle types with TWAP/chain pricing, and delegated farming with warmup/cooldown. Two audit passes: 80+ hypotheses, per-instruction access control matrix, cross-adapter comparison, external data field tracing, exploit pattern matching.

**Result: 1 High, 2 Low-Medium, 2 Low, 8+ Informational findings. 2 Immunefi submissions.**

The klend, kvault, and kfarms programs demonstrate exceptional defense-in-depth. The Scope oracle program has critical gaps in the ChainlinkX (v10) adapter — missing multiplier validation, missing CPI protection, and ignored cross-reference fields create a compound vulnerability exploitable during corporate action windows.

**Findings:**

| ID | Severity | Program | Description |
|----|----------|---------|-------------|
| [002](audits/kamino/findings/IMMUNEFI-SUBMISSION-002.md) | **High** | scope | Permissionless crank exploits missing multiplier validation in v10 to corrupt xStocks prices — 3 entries with zero protection, `activation_date_time=0` bypass, $5-20M TVL at risk |
| [001](audits/kamino/findings/IMMUNEFI-SUBMISSION-001.md) | Low-Medium | scope | ChainlinkX v10 ignores `tokenized_price` field — manual `price * current_multiplier` may diverge from Chainlink's pre-computed "24/7 tokenized equity price" |
| FINDING-02 | Low-Medium | scope | Missing `check_execution_ctx` CPI protection on `refresh_chainlink_price` (asymmetric with `refresh_price_list`) |
| FINDING-03 | Low | scope | Missing `check_execution_ctx` CPI protection on `refresh_pyth_lazer_price` |
| FINDING-04 | Low | scope | Chainlink refresh path bypasses zero-price guard — v10 `current_multiplier = 0` would store zero price |

**Full audit report:** [`AUDIT-REPORT.md`](audits/kamino/findings/AUDIT-REPORT.md)
**Immunefi submissions:** [`IMMUNEFI-SUBMISSION-001.md`](audits/kamino/findings/IMMUNEFI-SUBMISSION-001.md), [`IMMUNEFI-SUBMISSION-002.md`](audits/kamino/findings/IMMUNEFI-SUBMISSION-002.md)
**Analysis files:** [`klend`](audits/kamino/notes/klend-analysis.md) | [`kvault/scope/kfarms`](audits/kamino/notes/secondary-analysis.md) | [`Cross-program`](audits/kamino/notes/cross-program-analysis.md) | [`Re-audit notes`](audits/kamino/notes/reaudit-instruction-matrix.md)

---

### Reserve Protocol — [`audits/reserve-protocol/`](audits/reserve-protocol/findings/AUDIT-REPORT.md)

Two-repo protocol: core RToken system (BackingManager, StRSR, Dutch/Batch auctions, 15+ collateral plugins, governance) + Index DTF/Folio extension (index token, StakingVault, rebalancing auctions, trusted filler/CowSwap integration, fee distribution). 1000+ Solidity files across `protocol/` and `reserve-index-dtf/`.

**Result: Clean audit — 0 exploitable vulnerabilities found across 24+ hypotheses.**

The protocol demonstrates exceptional defense-in-depth: global reentrancy guard (shared `_guardCounter` in Main), conservative fixed-point rounding universally favoring the protocol (CEIL received, FLOOR sent), 5-check Chainlink oracle validation with graceful price decay, flash-loan resistance by design (snapshot voting, delayed balance tracking, `startTime = block.timestamp + 1`), era-based governance invalidation, and Folio's `sync` modifier ensuring consistent NAV.

**Informational observations only:**

| Area | Severity | Description |
|------|----------|-------------|
| Folio trusted fill | Informational | Residual token approval after trusted fill closure (defense-in-depth improvement) |
| FolioLib fees | Informational | First fee period undercharges by up to ~24 hours (non-exploitable) |

**Full audit report:** [`AUDIT-REPORT.md`](audits/reserve-protocol/findings/AUDIT-REPORT.md)

---

### Gains Network (gTrade) — [`audits/gains-network/`](audits/gains-network/findings/AUDIT-REPORT.md)

Leveraged perpetual trading platform on Arbitrum + Polygon. EIP-2535 Diamond proxy (GNSMultiCollatDiamond) with 15 facets, GToken ERC4626 vaults (gDAI, gUSDC, gETH) as trade counterparty, velocity-based funding fees, depth-band price impact, multi-reward staking, LayerZero bridge, and Chainlink oracle PnL feed. 12,000+ LOC across core trading, fee, and peripheral systems.

**Result: Clean audit — 0 exploitable vulnerabilities found across 50+ hypotheses.**

The protocol demonstrates strong defense-in-depth: global diamond reentrancy guard, Solidity 0.8.23 overflow protection, SafeERC20 universally, OpenZeppelin Math.mulDiv for rounding control, bounded PnL (-100% floor), anti-trade-splitting price impact (mathematically sound), protection close factor blocking same-block profits, epoch-based vault withdrawals, outlier-filtered median oracle, and consistent multi-collateral precision handling.

**Low/Informational observations only:**

| Area | Severity | Description |
|------|----------|-------------|
| PriceAggregatorUtils | Low | Chainlink `latestRoundData()` missing staleness/negative price check (defense-in-depth) |
| FundingFeesUtils | Low | Sign-change + cap interaction undercharges ~50% for one sub-period (rare edge case) |
| ERC20BridgeRateLimiter | Low | `executePendingClaim` zero-mint advances claim timestamp (griefing, no fund loss) |
| GNSStaking | Low | `debtToken` advanced on zero-amount harvest (sub-penny precision loss) |

**Full audit report:** [`AUDIT-REPORT.md`](audits/gains-network/findings/AUDIT-REPORT.md)

---

### Chainlink — [`audits/chainlink/`](audits/chainlink/findings/AUDIT-REPORT.md)

Comprehensive security audit of the Chainlink ecosystem across 6 repositories: CCIP cross-chain bridge (EVM + Solana + Go plugins), VRF (V2, V2.5), LLO Feeds (v0.4, v0.5), Automation v2.3, Functions v1.3.0, DataFeedsCache, and CCIP Owner contracts (ManyChainMultiSig, RBACTimelock). ~270K+ LOC across Solidity, Rust, and Go. 100+ hypotheses tested across 15 deep analysis areas.

**Result: Clean audit — 0 exploitable vulnerabilities found across 100+ hypotheses.**

The protocol demonstrates exceptional defense-in-depth: multi-layer verification (OCR3 F+1 consensus + independent RMN f+1 signer set + Merkle proofs with domain separators + balance pre/post checks), atomic execution state machine (2-bit bitmap with IN_PROGRESS reentrancy guard), CallWithExactGas library preventing gas bombs (return data capping + EIP-150 accounting), rate limiting on all token operations, fork protection via cached chain ID in digest construction, and self-serve TokenAdminRegistry with 2-step admin transfer.

**Low/Informational observations only:**

| Area | Severity | Description |
|------|----------|-------------|
| VRF V2 Wrapper | Low | `_getFeedData` allows weiPerUnitLink=0 (circuit breakers prevent) |
| VRF V2 Coordinator | Low | `pendingRequestExists` only checks latest nonce (V2.5 fixes) |
| FeeQuoter | Low | `onReport` same-timestamp price overwrite (requires trusted forwarder) |
| CCIPHome | Low | Missing p2pId/signerKey uniqueness validation (admin-gated) |
| DataFeedsCache | Low | Report type detection via length heuristic (ABI mismatch prevents) |
| Automation | Low | Paused upkeeps not checked on-chain in transmit (requires DON collusion) |
| Automation | Low | Report gasLimits not validated against performGas (requires DON collusion) |
| Automation | Low | `addFunds` missing nonReentrant (standard ERC20s unaffected) |

**Full audit report:** [`AUDIT-REPORT.md`](audits/chainlink/findings/AUDIT-REPORT.md)
**Architecture notes:** [`architecture.md`](audits/chainlink/notes/architecture.md)

---

### Origin Protocol — [`audits/origin-protocol/`](audits/origin-protocol/findings/CONSOLIDATED-AUDIT-REPORT.md)

Multichain yield engine with rebasing tokens (OUSD, OETH, superOETHb, OS) backed by strategies. Three repositories: origin-dollar (vault/token/strategies/oracle/automation), arm-oeth (Automated Redemption Manager AMM), ousd-governance (xOGN staking). Deployed on Ethereum, Base, and Sonic. ~27,800 LOC across 100+ Solidity contracts. 140+ hypotheses tested.

**Findings (3 Medium, 12 Low, 16 Informational — 2 Immunefi-submittable):**

| ID | Severity | Contract | Description |
|----|----------|----------|-------------|
| [001](audits/origin-protocol/findings/IMMUNEFI-SUBMISSION-001.md) | Medium | OETHPlumeVault | `_mint(address,uint256,uint256)` dead code — access control bypass via function signature mismatch |
| [002](audits/origin-protocol/findings/IMMUNEFI-SUBMISSION-002.md) | Medium | OETHOracleRouter | Unsafe `uint256(_iprice)` cast — negative Chainlink price wraps to `type(uint256).max` |
| 003 | Medium | PlumeBridgeHelperModule | Missing `require(success)` on approve exec call |

**Well-defended areas:** WOETH adjuster mechanism (immune to donation attacks), triple-capped yield drip, ARM dead shares + cross-price bounds, cross-chain CCTP nonce system, AMO solvency thresholds, beacon chain proof verification, xOGN non-transferable + checkpoint voting.

**Full consolidated report:** [`CONSOLIDATED-AUDIT-REPORT.md`](audits/origin-protocol/findings/CONSOLIDATED-AUDIT-REPORT.md)
**Sub-reports:** [`Strategy`](audits/origin-protocol/findings/AUDIT-REPORT.md) | [`Vault/Token`](audits/origin-protocol/findings/VAULT-TOKEN-AUDIT-REPORT.md) | [`Oracle/Zapper/Bridge`](audits/origin-protocol/findings/AUDIT-REPORT-ORACLE-ZAPPER-BRIDGE.md) | [`ARM/Governance`](audits/origin-protocol/findings/AUDIT-REPORT-ARM-GOVERNANCE.md)
**Immunefi submissions:** [`IMMUNEFI-SUBMISSION-001.md`](audits/origin-protocol/findings/IMMUNEFI-SUBMISSION-001.md), [`IMMUNEFI-SUBMISSION-002.md`](audits/origin-protocol/findings/IMMUNEFI-SUBMISSION-002.md)
**PoC files:** [`scripts/verify/`](audits/origin-protocol/scripts/verify/)

### Yearn Finance — [`audits/yearn-finance/`](audits/yearn-finance/findings/CONSOLIDATED-AUDIT-REPORT.md)

Full-stack DeFi yield protocol. 8 repositories: V3 Vault (VaultV3.vy, Vyper 0.3.7), TokenizedStrategy (Solidity delegatecall proxy), veYFI governance (vote-escrow, gauges, rewards), stYFI staking (14-day streams, integral accounting), vault-periphery (Accountant, DebtAllocator, Auction), yearn-boosted-staker (bitmap weights), and yearn-yb (Locker, YToken, Zap). ~60,911 LOC across Solidity + Vyper. 60+ hypotheses tested.

**Findings (5 Medium, 6 Low, 13 Informational — 5 Immunefi submissions):**

| ID | Severity | Contract | Description |
|----|----------|----------|-------------|
| [001](audits/yearn-finance/findings/IMMUNEFI-SUBMISSION-001.md) | Medium | CombinedChainlinkOracle.vy | Missing zero/negative price validation — dYFI redemption DoS |
| [002](audits/yearn-finance/findings/IMMUNEFI-SUBMISSION-002.md) | Medium | Gauge.sol | Residual `approve()` accumulation to VE_YFI_POOL |
| [003](audits/yearn-finance/findings/IMMUNEFI-SUBMISSION-003.md) | Medium | RewardPool.vy | Division by zero when `ve_supply` is zero — permanent claim lockout |
| [004](audits/yearn-finance/findings/IMMUNEFI-SUBMISSION-004.md) | Medium | Zap.sol | Zero slippage on intermediate Curve operations — compound MEV sandwich |
| [005](audits/yearn-finance/findings/IMMUNEFI-SUBMISSION-005.md) | Medium | StakingRewardDistributor.vy | Division by zero when `total_weight` is zero — distributor bricks |

**Core protocol (VaultV3 + TokenizedStrategy): CLEAN** — 0 exploitable vulnerabilities. Internal accounting neutralizes all ERC4626 donation/inflation attacks. All 24 unsafe operations mathematically proven safe. Profit locking prevents front-running. Shared reentrancy guard blocks all re-entry.

**False positives eliminated (7):** VaultV3 `_process_report` div-by-zero (proved unreachable), Auction callback reentrancy (`kick()` has nonReentrant), YToken unbacked minting (cache tracking correct), StakingRewardDistributor stale weight (constant during catch-up), VaultV3/TokenizedStrategy first-depositor (internal accounting), Gauge stale boost (known Curve pattern).

**Full consolidated report:** [`CONSOLIDATED-AUDIT-REPORT.md`](audits/yearn-finance/findings/CONSOLIDATED-AUDIT-REPORT.md)
**Sub-reports:** [`VaultV3 Deep Analysis`](audits/yearn-finance/findings/VAULTV3-AUDIT-REPORT.md) | [`Vyper 0.3.7 Compiler`](audits/yearn-finance/findings/VYPER-0.3.7-COMPILER-BUGS.md) | [`Per-Repo Report`](audits/yearn-finance/findings/AUDIT-REPORT.md)
**Immunefi submissions:** `IMMUNEFI-SUBMISSION-001.md` through `005.md`
**PoC files:** [`scripts/verify/`](audits/yearn-finance/scripts/verify/)

### Spark Protocol (SparkLend) — [`audits/spark/`](audits/spark/findings/AUDIT-REPORT.md)

Comprehensive DeFi lending and asset management protocol. 11 repositories: SparkLend V1 Core (Aave V3 fork with BridgeLogic), ALM Controller system (ALMProxy + MainnetController + ForeignController + RateLimits + 10 libraries), PSM3 (L2 peg stability module for USDC/USDS/sUSDS), SparkVault (ERC4626 with MakerDAO-style chi/rho/vsr rate accumulator), 13 oracles + 3 rate strategies, SparkLend Conduit, SparkRewards, governance executor, user actions, automations, and address registry. ~29,315 LOC across Solidity.

**Result: Clean audit — 0 exploitable vulnerabilities found across 60+ hypotheses.**

The protocol demonstrates exceptional defense-in-depth: chi-based ERC4626 accounting (SparkVault) eliminates inflation/donation/flash-loan attack classes entirely, dual-layer access control (RELAYER + rate limits) on all ALM operations, share-based PSM with seed deposit mitigating first-depositor inflation, cumulative merkle claims preventing double-claim, CappedFallbackRateSource wrapper with OOG protection, bidirectional rate limits for PSM swaps, and FREEZER role for emergency revocation.

**Low/Informational observations only:**

| Area | Severity | Description |
|------|----------|-------------|
| CappedOracle | Informational | Negative prices pass through uncapped (by design — AaveOracle validates downstream) |
| EZETHExchangeRateOracle | Informational | Theoretical div-by-zero if totalSupply=0 (unreachable in practice) |
| MorphoUpgradableOracle | Informational | Returns stale metadata (by design for Morpho Blue) |
| RateLimits | Informational | Theoretical overflow with extreme admin slope values |
| SparkLendConduit | Informational | ≤1 wei precision loss per operation (conservative rounding) |
| SparkVault | Low | Deposit cap bypassable with ERC777 (asset is always standard ERC20) |
| MainnetController | Low | Maple cancel doesn't restore rate limit (by design) |

**Full audit report:** [`AUDIT-REPORT.md`](audits/spark/findings/AUDIT-REPORT.md)

---

### Merchant Moe (LFJ) — [`audits/merchant-moe/`](audits/merchant-moe/findings/AUDIT-REPORT.md)

Cornerstone DEX for Mantle Network by the Trader Joe (LFJ) team. Dual-AMM architecture: classic AMM (UniV2 fork with non-standard token-extraction fee in MoePair) + Liquidity Book concentrated liquidity (discrete price bins, 128.128 binary fixed-point pricing, 3-level TreeMath O(log64) bin traversal). 4 repositories: moe-core (classic AMM, MasterChef, VeMoe, StableMoe, rewarders), joe-v2 (LB pairs, factory, router, hooks, math libraries), lb-rewarder (hooks-based reward distribution, MCRewarder ERC20 wrapper), autopools (vault-strategy separation, dead-share protection, 1inch swap integration). ~21,268 LOC across 119 Solidity files. Prior audits by Paladin (March 2024) and Bailsec (November 2024). 53 hypotheses tested.

**Result: Clean audit — 0 exploitable vulnerabilities found across 53 hypotheses.**

The protocol demonstrates strong security engineering: dual-precision rewarder system (V1 64-bit for legacy, V2 128-bit for new contracts) with correct accDebtPerShare mechanics, comprehensive hooks architecture in LB v2.1 with proper reentrancy considerations (after-hooks execute outside guard but CEI ensures consistent state), dead-share (1e6) first-depositor protection in autopools, balance-derived reward distribution in StableMoe with zero-supply guards, PackedUint128Math dual overflow checks, consistent rounding discipline (RoundDown for outputs, RoundUp for inputs/fees), and emergency escape hatches bypassing external calls.

**Informational observations only:**

| Area | Severity | Description |
|------|----------|-------------|
| MoeStaking | Informational | No reentrancy guard despite sequential external calls (safe due to CEI pattern) |
| Rewarder V1 | Informational | 64-bit precision vs V2 128-bit (negligible ~54 wei loss per update) |
| MoePair._sendFee() | Informational | Non-standard token extraction instead of LP minting (mathematically equivalent) |
| LBToken | Informational | No ERC1155 safe transfer callbacks (documented, prevents reentrancy) |
| LBPair hooks | Informational | After-hooks outside reentrancy guard (safe, all state finalized) |
| Strategy operator | Informational | Unrestricted 1inch swap control (trusted role by design) |
| VeMoe cap | Informational | Uses oldBalance for cap (conservative delay, not exploitable) |

**Full audit report:** [`AUDIT-REPORT.md`](audits/merchant-moe/findings/AUDIT-REPORT.md)

---

### OpenZeppelin — [`audits/openzeppelin/`](audits/openzeppelin/findings/AUDIT-REPORT.md)

Multi-repository audit of OpenZeppelin's Solidity libraries. 4 repositories: openzeppelin-contracts (v5.6 — core library including crosschain bridges, ERC-4337, ERC-7579 modular accounts, RLP/TrieProof), openzeppelin-contracts-upgradeable (upgradeable variants), openzeppelin-confidential-contracts (FHE/ERC7984 confidential tokens using Zama fhEVM — encrypted balances, ACL, governance), and uniswap-hooks (v1.2.0 — Uniswap V4 hook library with LimitOrderHook, AntiSandwichHook, ReHypothecationHook, LiquidityPenaltyHook, custom curves, oracles, fee hooks). 100+ hypotheses tested.

**Findings (2 High, 4 Medium, 4 Low, 4 Informational — 2 Immunefi submissions):**

| ID | Severity | Contract | Description |
|----|----------|----------|-------------|
| [001](audits/openzeppelin/findings/IMMUNEFI-SUBMISSION-001.md) | **High** | LimitOrderHook.sol | Withdrawal underflow — proportional checkpoint formula breaks with multi-user orders, permanently locking late withdrawer funds |
| [002](audits/openzeppelin/findings/IMMUNEFI-SUBMISSION-002.md) | **High** | VotesConfidential.sol | FHE.sub modular arithmetic wraps voting power near uint64.max (FHESafeMath.tryDecrease exists but unused) |
| M-01 | Medium | BridgeFungible.sol | `address(bytes20(toEvm))` silently truncates non-20-byte addresses — token loss |
| M-02 | Medium | ReHypothecationHook.sol | First deposit uses spot pool price — flash-loan manipulation of initial share value |
| M-03 | Medium | draft-ERC4337Utils.sol | BLOCK_RANGE_FLAG requires BOTH fields flagged (AND logic) — silently corrupts mixed inputs |
| M-04 | Medium | AntiSandwichHook.sol | Incomplete checkpoint tick range — ticks outside last price movement not captured |

**Well-defended areas:** BaseHook (onlyPoolManager + address validation), BaseCustomAccounting (position salt derivation), BaseCustomCurve (ERC-6909 management), CurrencySettler (zero-amount early return), OracleHook (Panoptic TWAP), openzeppelin-contracts-upgradeable (faithful mirror with storage gaps).

**False positives eliminated:** LiquidityPenaltyHook double-penalty (delta accounting mathematically verified), AntiSandwichHook lpFeeOverride divergence (Pool.swap uses slot0.lpFee when not flagged), Oracle binary search infinite loop (convergence guaranteed by getSurroundingObservations bounds).

**Full audit report:** [`AUDIT-REPORT.md`](audits/openzeppelin/findings/AUDIT-REPORT.md)
**Immunefi submissions:** [`IMMUNEFI-SUBMISSION-001.md`](audits/openzeppelin/findings/IMMUNEFI-SUBMISSION-001.md), [`IMMUNEFI-SUBMISSION-002.md`](audits/openzeppelin/findings/IMMUNEFI-SUBMISSION-002.md)

### Ref Finance — [`audits/ref-finance/`](audits/ref-finance/findings/AUDIT-REPORT.md)

NEAR Protocol DEX with multi-pool architecture. 2 repositories: ref-exchange (SimplePool xy=k, StableSwap, RatedSwap with oracle rates, DegenSwap) and boost-farm (shadow farming, boosted rewards, booster staking). ~18,600 LOC across 38 Rust source files. Shadow staking system allows LP tokens to be virtually staked in both farming and burrow (lending) simultaneously via ShadowRecord tracking. 80+ hypotheses tested.

**Findings (2 Medium, 3 Low, 8 Informational — 1 Immunefi submission):**

| ID | Severity | Contract | Description |
|----|----------|----------|-------------|
| [001](audits/ref-finance/findings/IMMUNEFI-SUBMISSION-001.md) | Medium | shadow_actions.rs | Burrow liquidation creates permanent phantom farming shadows — fire-and-forget callback with no rollback |
| M-02 | Medium | actions_of_farmer_reward.rs | Boost-farm reward tokens permanently lost on withdraw+unregister race (self-harm) |
| L-01 | Low | stnear/linear/nearx_rate.rs | Rate modules accept zero oracle values causing temporary pool DoS |
| L-02 | Low | booster.rs, farmer_seed.rs | f64 floating-point precision loss in boost ratio calculations |
| L-03 | Low | degen_swap/price_oracle.rs | Degen price oracle `decimals` subtraction can underflow |

**Well-defended areas:** Internal accounting (never reads ft_balance_of), U256/U384 precision for all math, conservative rounding (DOWN for receives, UP for pays), debit-first credit-on-callback pattern, virtual account isolation, INIT_SHARES_SUPPLY proportional dilution, frozen token checks, assert_one_yocto on admin ops, StableSwap Newton convergence (256 iterations).

**Key rejected hypotheses:** First-depositor inflation (internal accounting), degen oracle manipulation (NEAR async prevents atomic attacks), token theft via swap_out_recipient (virtual account isolation), total_seed_power desync (update-on-claim correct), shadow record underflow via MFT transfer (free_shares check), reentrancy (NEAR single-threaded).

**Full audit report:** [`AUDIT-REPORT.md`](audits/ref-finance/findings/AUDIT-REPORT.md)
**Immunefi submission:** [`IMMUNEFI-SUBMISSION-001.md`](audits/ref-finance/findings/IMMUNEFI-SUBMISSION-001.md)

---

### Flamingo Finance — [`audits/flamingo-finance/`](audits/flamingo-finance/findings/AUDIT-REPORT.md)

Uniswap V2-style AMM DEX and staking/reward protocol on the Neo N3 blockchain. C# smart contracts targeting NeoVM. 3 repositories: flamingo-contract-swap (FlamingoSwapFactory, FlamingoSwapPair, FlamingoSwapRouter, ProxyTemplate, FlamingoSwapPairWhiteList), flamingo-contract-staking-n3 (FLM Token, Staking Vault), flamingo-audits (prior audit PDFs for FUSD/OrderBook/Flocks — NOT covering in-scope contracts). ~3,500 LOC across 38 C# contract files. 55+ hypotheses tested.

**Findings (2 Medium, 2 Low, 2 Informational — 2 Immunefi submissions):**

| ID | Severity | Contract | Description |
|----|----------|----------|-------------|
| [001](audits/flamingo-finance/findings/IMMUNEFI-SUBMISSION-001.md) | Medium | ProxyTemplateContract.cs | `ProxySwapTokenInForTokenOut` checks LP token balance (Pair01) instead of input token (path[0]) — swap DoS |
| [002](audits/flamingo-finance/findings/IMMUNEFI-SUBMISSION-002.md) | Medium | Staking.Record.cs | Integer division truncation in profit rate (`shareAmount / totalStaked = 0`) — permanent reward loss, amplified by 10^30 ConvertDecimal |
| L-01 | Low | Staking.cs | `CheckFLM` public function has unguarded write side effects (storage mutation without reentrancy guard) |
| L-02 | Low | FlamingoSwapPairContract.Nep17.cs | `OnNEP17Payment` validation commented out — pair accepts any NEP-17 token |
| I-01 | Informational | FlamingoSwapPairContract.cs | Fund fee (0.05%) truncates to zero for swaps < 2000 base units |
| I-02 | Informational | FlamingoSwapPairContract.Admin.cs | GASAdmin uninitialized — `ClaimGASFrombNEO` permanently DoS'd |

**Well-defended areas:** Constant product K-invariant (mathematically sound, fee ensures surplus), MINIMUM_LIQUIDITY=1000 (first-depositor protection), EnteredStorage reentrancy guard on Swap/Mint/Burn, whitelist-based router access control, Neo N3 transaction atomicity (full ACID), BigInteger arbitrary precision (no overflow), upgrade timelock (24h delay).

**Prior audit gap:** The `flamingo-audits` repo contains audits for FUSD, OrderBook v2, Flocks, and LP-Staking — but NOT for the core swap (Pair/Router/Factory) or FLM/Staking contracts in the Immunefi scope.

**Full audit report:** [`AUDIT-REPORT.md`](audits/flamingo-finance/findings/AUDIT-REPORT.md)
**Immunefi submissions:** [`IMMUNEFI-SUBMISSION-001.md`](audits/flamingo-finance/findings/IMMUNEFI-SUBMISSION-001.md), [`IMMUNEFI-SUBMISSION-002.md`](audits/flamingo-finance/findings/IMMUNEFI-SUBMISSION-002.md)

### Hathor Network — [`audits/hathor-network/`](audits/hathor-network/findings/AUDIT-REPORT.md)

DAG-based blockchain with Python nano contracts sandbox. 3 repositories: hathor-core (Python full node with nano contracts system — custom builtins sandbox, AST validation, metered execution, P2P sync_v2, DAG consensus), hathor-wallet-lib (JavaScript wallet library), hathor-wallet-headless (headless wallet service). ~100K+ LOC Python. 100+ hypotheses tested.

**Findings (1 Critical, 2 High, 1 Medium, 3 Low, 4 Informational — 2 Immunefi submissions):**

| ID | Severity | Component | Description |
|----|----------|-----------|-------------|
| [001](audits/hathor-network/findings/IMMUNEFI-SUBMISSION-001.md) | **Critical** | Nano Contract Sandbox | SystemExit/KeyboardInterrupt escape `except Exception` handlers, trigger `crash_and_exit()` — permanent node crash + boot loop |
| [002](audits/hathor-network/findings/IMMUNEFI-SUBMISSION-002.md) | **High** | MeteredExecutor | Fuel metering (`sys.settrace`) completely unimplemented — `FUEL_COST_MAP` dead code, infinite loops unmitigated |
| F-03 | **High** | MeteredExecutor | Memory limit stored but never checked — `bytearray(10**9)` OOM-kills node |
| F-04 | Medium | Custom Builtins | C-level builtins (`sorted`, `list`, `dict`) bypass Python opcode tracing |
| F-05 | Low | Vertex Verifier | Wrong `parent_hash` in grandparent timestamp loop — `min_timestamp` never set (dead code) |
| F-06 | Low | Consensus | `assert bool(meta.conflict_with)` stripped by `python -O` (developer FIXME exists) |
| F-07 | Low | Sync v2 | DFS `popleft()` loses root context when stack exceeds limit |

**Compensating control:** `NC_ON_CHAIN_BLUEPRINT_RESTRICTED=True` limits blueprint deployment to whitelisted addresses (mitigates immediate exploitability, code comment states restriction will be lifted).

**Well-defended areas:** Import whitelist (well-curated), AST name blacklist (blocks dunders), custom `range` reimplementation, cross-contract call limits (MAX_RECURSION_DEPTH=100, MAX_CALL_COUNTER=250), restricted `__import__` function.

**Full audit report:** [`AUDIT-REPORT.md`](audits/hathor-network/findings/AUDIT-REPORT.md)
**Immunefi submissions:** [`IMMUNEFI-SUBMISSION-001.md`](audits/hathor-network/findings/IMMUNEFI-SUBMISSION-001.md), [`IMMUNEFI-SUBMISSION-002.md`](audits/hathor-network/findings/IMMUNEFI-SUBMISSION-002.md)
**PoC files:** [`scripts/verify/`](audits/hathor-network/scripts/verify/)

### Stellar Protocol — [`audits/stellar/`](audits/stellar/findings/AUDIT-REPORT.md)

Comprehensive smart contract platform audit. 5 repositories: stellar-core (C++ consensus node, DEX engine, Soroban FFI bridge), rs-soroban-env (Rust host environment — WASM sandbox, auth, budget/metering, SAC, storage, crypto), rs-soroban-sdk (Rust developer SDK), wasmi (WASM interpreter fork), rs-stellar-xdr (XDR types). ~417K LOC across Rust and C++. 50+ hypotheses tested across auth bypass, WASM sandbox escape, budget evasion, DEX manipulation, token operations, crypto verification, and PRNG prediction.

**Result: Clean audit — 0 exploitable vulnerabilities found across 50+ hypotheses.**

The protocol demonstrates exceptional defense-in-depth: 5-layer WASM-to-host validation chain (type marshalling + relative/absolute object handles + integrity checks + budget charging + protocol gating), tree-structured authorization with exhausted-once matching and nonce-based replay prevention, RefCell borrow-based reentrancy protection, storage footprint enforcement (pre-declared read/write sets), ChaCha20 CSPRNG with HMAC-SHA256 seed unbiasing and per-frame isolation, 128-bit intermediate arithmetic in DEX engine (bigDivide/hugeDivide), formal mathematical proofs for exchange invariants, verify_strict ed25519 and low-S ECDSA enforcement, and comprehensive budget metering on all operations.

**Low/Informational observations only:**

| Area | Severity | Description |
|------|----------|-------------|
| Budget | Low | Fuel rounding loses tiny residual per host boundary crossing |
| VM | Low | wasmparser re-parse iterates without per-instruction budget check (pre-charged) |
| VM | Low | Conservative const expression allowlist (correct security approach) |
| Conversion | Informational | `storage_key_conversion_active` flag not reset on error (no RAII guard) |
| Host | Informational | Unmetered `can_represent_scval_recursive` walk (acknowledged, scheduled fix) |
| Budget | Informational | Saturating arithmetic could theoretically undercharge (limit check catches) |
| VM | Informational | Module cache BTreeMap operations unmetered (bounded by design) |
| Lifecycle | Informational | Double parsing cost during WASM upload (conservative over-charge) |
| Budget | Informational | Table growth not budget-charged (hard cap of 1000 entries) |
| Core | Informational | No explicit constant product post-check (invariant preserved by formula) |

**Full audit report:** [`AUDIT-REPORT.md`](audits/stellar/findings/AUDIT-REPORT.md)

---

---

## Target Research

| File | Description |
|------|-------------|
| [`scraper.py`](scraper.py) | Fetches all Immunefi programs into a structured text file |
| [`all_programs.txt`](all_programs.txt) | Full data dump: 257 programs with rewards, assets, impacts, scope, and resource links |
| [`ANALYSIS.md`](ANALYSIS.md) | Prioritization analysis — Tier 1/2/3 programs, scoring methodology, vulnerability class focus |

```bash
# Re-scrape all programs
python3 scraper.py
```

Requirements: Python 3.8+, standard library only.

## Focus

- Smart contract programs only (code review, not web/app testing)
- Scoring: max bounty, response time, payment history, Primacy of Impact, in-scope impact count
- Vulnerability classes: arithmetic overflow, access control, oracle manipulation, reentrancy, cross-contract state
