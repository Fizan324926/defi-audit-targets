# DeFi Bug Bounty Target Analysis

> **Goal:** Identify the highest-ROI Immunefi programs for code-audit-style vulnerability research —
> smart contract focus, active programs, broad impact scope, lower researcher competition, and proven payout history.

---

## Methodology & Scoring Criteria

Each program is scored across six dimensions that matter for code-audit workflows:

| Dimension | Why It Matters |
|---|---|
| **Max bounty** | Sets the reward ceiling; log-scaled to balance large vs. mid-tier programs |
| **Response time** | Fast response = active triagers = lower chance of report rot; sub-24h gets full weight |
| **Total paid history** | Proves the program actually pays; programs that have never paid are higher risk |
| **Primacy of Impact (PoI)** | Accepts vulnerabilities even if the exact asset isn't in the formal scope list — dramatically expands the hunt surface |
| **Number of in-scope impacts** | More accepted impact categories = more vulnerability classes worth auditing |
| **Smart contract assets** | Larger codebase surface = more attack vectors per hour of audit time |

**Excluded automatically:**
- Invite-only programs
- Web/app-only programs (require manual request testing, not code audit)
- Programs with no smart contract scope

---

## Tier 1 — Start Here (Highest Priority)

These 10 programs combine large bounty ceilings, proven payment history, responsive teams, and broad in-scope impact categories. All are pure smart-contract audit targets.

### 1. Origin Protocol
- **Max Bounty:** $1,000,000
- **Total Paid:** $75,700
- **Response Time:** 8 hours
- **Primacy of Impact:** Yes
- **In-Scope Impacts:** 15 (all Smart Contract)
- **Ecosystem:** ETH | Language: Solidity
- **KYC:** No
- **URL:** https://immunefi.com/bug-bounty/originprotocol/

**Why:** Sub-10h response time is exceptionally fast, proving an engaged team. PoI means any owned contract is fair game beyond the declared list. DeFi yield protocol with complex rebasing and vault logic — historically fertile ground for arithmetic and access-control bugs. No KYC removes friction from smaller payouts.

---

### 2. Sky (formerly MakerDAO)
- **Max Bounty:** $10,000,000
- **Total Paid:** $603,250
- **Response Time:** 16 hours
- **Primacy of Impact:** No
- **In-Scope Impacts:** 26 (Smart Contract + Websites)
- **Ecosystem:** ETH | Language: Solidity
- **KYC:** No
- **URL:** https://immunefi.com/bug-bounty/sky/

**Why:** Largest proven payment history in Tier 1. The $10M ceiling and 26 in-scope impacts cover stablecoin minting, liquidation, governance, and oracle logic. MakerDAO's upgrade cycle (DAI → USDS, MCD → Sky) introduced new code paths that haven't been battle-tested as long as the original contracts. Primacy of Rules means scope is explicit, which keeps competition lower — researchers don't speculatively hunt out-of-scope assets.

---

### 3. Optimism
- **Max Bounty:** $2,000,042
- **Total Paid:** $2,669,465
- **Response Time:** ~54 hours
- **Primacy of Impact:** Yes
- **In-Scope Impacts:** 24 (Smart Contract + Blockchain)
- **Ecosystem:** ETH, OP Stack | Language: Solidity, Go, Rust
- **KYC:** Yes
- **URL:** https://immunefi.com/bug-bounty/optimism/

**Why:** $2.7M paid out is the clearest signal on this list that the team finds, validates, and pays. PoI + 24 impacts including L2 bridge logic, sequencer, and fault proof contracts. The OP Stack's modular architecture (Bedrock, Fault Proof) introduced many new component boundaries — high complexity = high audit value. Multi-language codebase (Go/Rust for node, Solidity for contracts) means fewer researchers cover the full stack.

---

### 4. Olympus DAO
- **Max Bounty:** $3,333,333
- **Total Paid:** $260,533
- **Response Time:** 15 hours
- **Primacy of Impact:** No
- **In-Scope Impacts:** 6
- **Ecosystem:** ETH | Language: Solidity
- **KYC:** No
- **URL:** https://immunefi.com/bug-bounty/olympus/

**Why:** $3.3M ceiling with a 15h response time is rare. Despite only 6 formal impact categories, the OHM bonding mechanism and treasury management contracts are architecturally unique — bonding curves, range-bound stability, and cross-protocol integrations create complex state transitions not present in standard AMMs or lending pools. Fewer researchers work on non-standard protocol mechanics.

---

### 5. Reserve Protocol
- **Max Bounty:** $10,000,000
- **Total Paid:** $5,500
- **Response Time:** 18 hours
- **Primacy of Impact:** No
- **In-Scope Impacts:** 21
- **Ecosystem:** ETH | Language: Solidity
- **KYC:** Yes
- **URL:** https://immunefi.com/bug-bounty/reserve/

**Why:** $10M ceiling with only $5,500 paid to date is a strong signal of low researcher penetration. The basket-based stablecoin architecture (RToken, BasketHandler, BackingManager) involves intricate collateral rebalancing logic that differs significantly from Aave/Compound-style lending. 21 in-scope impacts cover governance, liquidation, and economic manipulation — all code-audit friendly categories.

---

### 6. Yearn Finance
- **Max Bounty:** $200,000
- **Total Paid:** $238,500
- **Response Time:** 17 hours
- **Primacy of Impact:** No
- **In-Scope Impacts:** 15
- **Ecosystem:** ETH | Language: Solidity, Vyper
- **KYC:** No
- **URL:** https://immunefi.com/bug-bounty/yearnfinance/

**Why:** Proven track record of paying ($238K) with fast response. Vyper codebase reduces researcher pool significantly — most hunters focus on Solidity. Vault V3's modular strategy architecture introduces novel composability risks that don't exist in V2. The yield aggregation logic across dozens of strategy implementations is high-complexity, low-coverage territory.

---

### 7. Gains Network
- **Max Bounty:** $200,000
- **Total Paid:** $364,280
- **Response Time:** N/A (response time not published)
- **Primacy of Impact:** Yes
- **In-Scope Impacts:** 33
- **Ecosystem:** ETH, Polygon, Arbitrum | Language: Solidity
- **KYC:** No
- **URL:** https://immunefi.com/bug-bounty/gainsnetwork/

**Why:** 33 in-scope impacts is the highest on this list — broadest accepted vulnerability set. $364K paid and PoI means the team is receptive. Perpetuals DEX with leverage trading, dynamic funding rates, liquidation engine, and oracle integration. Multi-chain deployment (Polygon + Arbitrum) creates cross-chain state synchronization risks. No KYC removes friction.

---

### 8. Beanstalk
- **Max Bounty:** $1,100,000
- **Total Paid:** $1,425,188
- **Response Time:** ~33 hours
- **Primacy of Impact:** No
- **In-Scope Impacts:** 18
- **Ecosystem:** ETH | Language: Solidity
- **KYC:** No
- **URL:** https://immunefi.com/bug-bounty/beanstalk/

**Why:** Highest total paid in Tier 1 at $1.4M, proving consistent, large payouts. Beanstalk's credit-based stablecoin mechanism (Pods, Silo, Field) is unlike any standard DeFi protocol — bespoke economics create vulnerability classes that standard audit tooling misses. The post-hack rebuild also means the team takes security extremely seriously. No KYC, $1.1M ceiling.

---

### 9. Spark (SparkLend)
- **Max Bounty:** $5,000,000
- **Total Paid:** N/A (not published)
- **Response Time:** N/A
- **Primacy of Impact:** Yes
- **In-Scope Impacts:** ~20+
- **Ecosystem:** ETH, Gnosis | Language: Solidity
- **KYC:** Yes
- **URL:** https://immunefi.com/bug-bounty/sparklend/

**Why:** $5M ceiling with PoI and Aave V3 fork architecture. SparkLend diverges meaningfully from vanilla Aave V3 with DAI/USDS integration, cross-chain liquidity, and custom interest rate models. Fork-based protocols often inherit the audit coverage of the original but diverge enough that original audit findings don't translate — new code paths = fresh vulnerabilities. Large ceiling with likely low paid history = uncrowded.

---

### 10. Chainlink
- **Max Bounty:** $3,000,000
- **Total Paid:** N/A (not published)
- **Response Time:** N/A
- **Primacy of Impact:** Yes
- **In-Scope Impacts:** ~18+
- **Ecosystem:** ETH, multi-chain | Language: Solidity, Go
- **KYC:** No
- **URL:** https://immunefi.com/bug-bounty/chainlink/

**Why:** $3M ceiling with PoI and infrastructure-level scope (CCIP, OCR, Automation, VRF, Data Feeds). Oracle manipulation and cross-chain message integrity are the highest-impact classes in DeFi. Chainlink's newer products (CCIP, Functions, Data Streams) have had less independent scrutiny than their core price feed contracts — these are the hunting grounds. No KYC.

---

## Tier 2 — High Value Secondary Targets

Work these in parallel or after establishing a methodology on Tier 1.

| # | Program | Max Bounty | Paid | Response | PoI | Impacts | Notes |
|---|---|---|---|---|---|---|---|
| 11 | **ZKsync Era** | $1,100,000 | N/A | N/A | Yes | 20+ | ZK proof system + EVM equivalence gaps; Rust + Solidity |
| 12 | **LayerZero** | $15,000,000 | N/A | N/A | Yes | 15+ | Highest ceiling on Immunefi; cross-chain messaging; ultra-complex |
| 13 | **Stader for ETH** | $1,000,000 | N/A | N/A | Yes | 18+ | Liquid staking; DVT integration; PoI |
| 14 | **Ether.fi** | $300,000 | N/A | N/A | Yes | 20+ | Restaking via EigenLayer; novel architecture |
| 15 | **Silo Finance V2** | $350,000 | N/A | N/A | Yes | 18+ | Isolated lending markets; fresh V2 codebase |
| 16 | **Gearbox Protocol** | $200,000 | $420,500 | 16h | No | 20+ | Credit accounts; proxy pattern; high complexity |
| 17 | **Polygon** | $1,000,000 | $7,107,876 | N/A | Yes | 18+ | Largest paid on platform; PoS + zkEVM scope |
| 18 | **Gnosis Chain** | $2,000,000 | $25,000 | 51h | No | 20+ | Low paid vs. high ceiling; bridge + validator logic |
| 19 | **0x Protocol** | $1,000,000 | N/A | N/A | Yes | 15+ | DEX aggregation; settlement contracts; PoI |
| 20 | **Alchemix** | $300,000 | $205,537 | 97h | No | 15+ | Self-repaying loans; novel vault mechanics |

---

## Tier 3 — Specialized / Niche Opportunities

These programs have specific characteristics that make them worth targeting for specialized researchers.

| # | Program | Max Bounty | Paid | Angle |
|---|---|---|---|---|
| 21 | **Threshold Network** | $150,000 | $636,956 | tBTC bridge; threshold cryptography; multi-sig |
| 22 | **Tranchess** | $200,000 | $336,680 | Structured products; tranche mechanics; less researched |
| 23 | **Stacks** | $250,000 | $1,491,773 | Bitcoin L2; Clarity language (very few researchers) |
| 24 | **Flamingo Finance** | $1,000,000 | $13,850 | Neo blockchain; N3 VM; tiny researcher pool |
| 25 | **XION** | $250,000 | $170,486 | Cosmos ecosystem; account abstraction; new chain |
| 26 | **Boba Network** | $100,000 | $328,750 | Optimistic rollup; hybrid compute; paid history |
| 27 | **Merchant Moe** | $100,000 | N/A | Liquidity Book DEX; Trader Joe fork; PoI |
| 28 | **Enzyme Blue / Onyx** | $200,000 | $634,600 | On-chain fund management; complex permissioned roles |
| 29 | **Ankr** | $500,000 | $17,699 | Liquid staking; multi-chain; low paid vs. ceiling |
| 30 | **Polymarket** | $1,000,000 | N/A | Prediction markets; UMA oracle integration; PoI |

---

## Programs to Deprioritize

### Skip (Web/App only — not code audit friendly):
Decentraland, The Sandbox, Galagames, Xterio (web portion), Exodus Wallet — vulnerability class is XSS/CSRF/IDOR, not smart contract logic.

### Skip (Invite-only):
Several high-value programs are invite-only and not accessible without an established reputation on the platform.

### Skip (Extremely well-audited, low surface area):
- **Aave V3** — audited by 10+ firms; near-zero low-hanging fruit; massive competition
- **Uniswap V4** — hooks architecture is new but extremely heavily scrutinized
- **Compound V3** — small in-scope surface, well-understood codebase

### Skip (Non-Solidity, high learning curve, tiny community):
- BSV-based programs — niche VM, almost no public tooling
- Move-based programs (Aptos, Sui) — unless you have Move experience

---

## Vulnerability Classes to Focus On (Code Audit Priority)

These are the vulnerability categories most likely to yield findings via code review alone, without needing to send live transactions:

### 1. Arithmetic & Precision Errors
- Integer overflow/underflow in reward calculations
- Rounding in favor of protocol over users (or vice versa)
- Incorrect decimals handling across tokens with non-standard decimals
- Price manipulation via flash loans when oracle is a spot price

### 2. Access Control & Authorization
- Missing `onlyOwner` / role checks on privileged functions
- Incorrect modifier ordering
- Unprotected initializers in upgradeable contracts
- Proxy admin slot collisions

### 3. Reentrancy & State Manipulation
- Cross-function reentrancy (checks-effects-interactions violation)
- Read-only reentrancy exploiting view functions called mid-execution
- ERC777 / ERC1155 callback abuse
- Reentrancy via `transfer()` to contracts with fallback logic

### 4. Logic Errors in Core Protocol Mechanics
- Liquidation threshold miscalculation
- Incorrect health factor computation
- Interest accrual timing bugs (block-based vs. timestamp-based)
- Governance timelock bypass

### 5. Cross-Chain & Bridge Vulnerabilities
- Message replay across chains with identical chain IDs
- Missing nonce validation in cross-chain message handlers
- Incorrect assumptions about finality on source chain
- Token amount mismatch between lock and mint

### 6. Oracle Manipulation
- Single-source price oracle with no TWAP
- Stale price not checked (heartbeat deviation)
- Oracle return value not validated (returns 0 or negative)
- Sequencer uptime not verified on L2 (Arbitrum, Optimism)

### 7. Upgradeable Contract Issues
- Storage layout collision in proxy upgrades
- Uninitialized implementation contract
- `selfdestruct` in implementation affecting proxy state
- Missing gap variables in inherited upgradeable contracts

---

## Audit Tooling Stack

For systematic code-audit style hunting:

| Tool | Use Case |
|---|---|
| **Slither** | Static analysis; detects reentrancy, access control, arithmetic |
| **Foundry (forge)** | PoC development; fuzzing with `forge fuzz` |
| **Echidna / Medusa** | Property-based fuzzing for invariant violations |
| **Semgrep** | Custom pattern matching across large codebases |
| **4naly3er** | Quick Solidity report generation |
| **Surya** | Call graph and inheritance visualization |
| **Tenderly** | Transaction simulation and fork debugging |

---

## Prioritized Attack Order

Based on the scoring matrix, this is the recommended order to begin audits:

```
Phase 1 (Weeks 1–4):   Origin Protocol, Olympus, Yearn Finance, Gains Network
Phase 2 (Weeks 5–8):   Beanstalk, Reserve Protocol, Sky
Phase 3 (Weeks 9–12):  Optimism, Chainlink, Spark
Phase 4 (Ongoing):     Tier 2 targets in parallel
```

**Rationale for Phase 1 selection:**
- Origin, Olympus, and Yearn have fast response times (<20h) — reports get actioned quickly
- All three have proven payment history
- Gains Network's 33 in-scope impacts provides the widest surface for initial familiarization
- All are Solidity-only, reducing context-switching overhead

---

## Key Metrics Summary

| Metric | Value |
|---|---|
| Total programs analyzed | 257 |
| Smart contract programs | 224 |
| Programs with Primacy of Impact | 72 |
| Programs with proven payment history | 46 |
| Programs with published response time | 45 |
| Highest single ceiling | $15,000,000 (LayerZero) |
| Highest total paid (single program) | $7,107,876 (Polygon) |
| Fastest response time | <1h (Enzyme Blue) |
| Programs with Solidity codebase | ~180+ |

---

*Data sourced from Immunefi bug bounty explore page. Scraped and analyzed via `scraper.py`. All scoring is heuristic — adapt weights based on your expertise and available tooling.*
