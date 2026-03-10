# JustLend DAO Security Audit Report

## Protocol Overview

**Protocol:** JustLend DAO
**Type:** Compound V2 Fork (Lending/Borrowing)
**Blockchain:** TRON (TVM, Solidity ^0.5.12)
**Repository:** https://github.com/justlend/justlend-protocol
**Bounty Program:** Immunefi — Max $50K Critical, $20K High, $10K Medium
**Audit Date:** 2026-03-03
**Scope:** 52 Solidity files, ~15,447 LOC

## Executive Summary

JustLend DAO is a Compound V2 fork deployed on TRON with custom modifications including a novel wrapped governance token (WJST), modified CEther with TRX excess refund, separated reserveAdmin role, and custom incremental voting in GovernorBravo. The core lending/borrowing logic (CToken, Comptroller, interest rate models) follows Compound V2 closely and is well-understood.

**Critical finding: The WJST governance token lacks the checkpoint mechanism required by GovernorBravo — `getPriorVotes()` returns the current balance instead of a historical snapshot, enabling post-proposal vote accumulation.**

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 0 |
| Medium | 1 |
| Low | 4 |
| Informational | 5 |
| **Total** | **10** |

## Methodology

1. **Differential analysis:** Systematic diff of all JustLend contracts against Compound V2 reference to identify novel/modified code
2. **Deployed contract verification:** ABI comparison of 6 deployed contracts (TronScan) against GitHub source
3. **Novel code deep-read:** Line-by-line review of WJST, GovernorBravo, CEther, CErc20 modifications
4. **Hypothesis-driven testing:** 40+ vulnerability hypotheses tested across governance, lending, oracle, and admin surfaces
5. **Cross-contract flow tracing:** Full voting lifecycle (deposit → vote → lock → withdraw), lending lifecycle (mint → borrow → repay → redeem → liquidate)

## Scope Analysis

### Novel Code (JustLend-specific, highest risk)
- `WJST.sol` — Wrapped JST governance token with vote-and-lock mechanism
- `GovernorBravoDelegate.sol` — Modified governance with incremental voting
- `GovernorAlpha.sol` — Legacy governance (superseded by Bravo)
- CEther modifications — Excess TRX refund, explicit amount parameter
- CErc20 modifications — USDT return value skip, reserveAdmin separation
- CToken modifications — reserveAdmin, JTokenStatus events, statusSnapShot

### Standard Compound V2 (lower risk, well-audited)
- Comptroller (core logic), Unitroller, CToken (core logic)
- Interest rate models (WhitePaper, JumpRate, BaseJumpRateV2)
- Timelock, Maximillion, Reservoir, PriceOracleProxy
- ErrorReporter, Exponential, CarefulMath, SafeMath

### Deployed vs GitHub Divergence
The deployed Comptroller (`TCtzg2CQsAuLkSxrGjFGbHVwKvv95W9C8e`) contains borrow cap and collateral factor guardian subsystems absent from the GitHub repository. All other verified contracts match GitHub source.

---

## Findings

### FINDING-01 [MEDIUM]: WJST.getPriorVotes Lacks Checkpoint Mechanism — Governance Manipulation via Post-Proposal Vote Buying

**File:** `contracts/Governance/WJST.sol:93-96`

**Description:**
The `getPriorVotes()` function completely ignores its `blockNumber` parameter and returns the caller's current `balanceOf_` instead of a historical snapshot:

```solidity
function getPriorVotes(address account, uint256 blockNumber) public view returns (uint256){
    blockNumber;                    // parameter silently discarded
    return balanceOf_[account];     // returns CURRENT balance, not historical
}
```

This function is called by GovernorBravo in three critical locations:
1. **`propose()`** (line 78): `wjst.getPriorVotes(msg.sender, sub256(block.number, 1))` — determines proposal eligibility
2. **`castVoteInternal()`** (line 278): `wjst.getPriorVotes(voter, proposal.startBlock)` — determines voting power
3. **`cancel()`** (lines 167, 170): `wjst.getPriorVotes(proposal.proposer, sub256(block.number, 1))` — determines if proposer is below threshold

In Compound's original design, `getPriorVotes()` uses a binary-search over checkpoints to return the balance at a specific past block number. This prevents post-proposal token acquisition from influencing governance outcomes. JustLend's implementation breaks this fundamental security property.

**Attack Scenario:**
1. A contentious governance proposal is created at block N
2. Attacker observes the proposal and purchases JST on TRON DEXes over subsequent blocks
3. Attacker deposits JST into WJST via `deposit()`
4. When voting begins (block N + votingDelay), attacker calls `castVote()` with their full WJST balance
5. `castVoteInternal` checks `votesAdded <= wjst.getPriorVotes(voter, proposal.startBlock)` — but this returns CURRENT balance (including post-proposal acquisitions)
6. `voteFresh()` locks the attacker's tokens for the voting duration
7. After the proposal resolves (state >= 2), attacker calls `withdrawVotes()` to unlock tokens
8. Attacker sells JST on market

**Mitigating Factors:**
- Token locking via `voteFresh()` prevents flash-loan attacks (tokens are deducted from `balanceOf_` during voting)
- Quorum is 600M JST (~6% of 9.9B supply) — reaching quorum alone requires massive capital
- Attacker is exposed to JST price risk for the entire voting period (24 hours to 2 weeks)
- Timelock delay provides additional window for community response

**Impact:** Governance manipulation that could lead to malicious parameter changes (oracle, collateral factors, reserve factors) or protocol drain via timelock-queued transactions. The capital requirements and price risk exposure reduce practical exploitability, but the fundamental security model is broken.

**Severity:** MEDIUM — The vulnerability enables post-proposal vote buying which breaks the governance snapshot model. The token locking mechanism prevents flash-loan exploitation but does not prevent multi-block accumulation attacks.

**Recommendation:** Implement a checkpoint-based voting power system similar to Compound's `Comp.sol` or OpenZeppelin's `ERC20Votes`:

```solidity
struct Checkpoint {
    uint32 fromBlock;
    uint256 votes;
}

mapping(address => mapping(uint32 => Checkpoint)) public checkpoints;
mapping(address => uint32) public numCheckpoints;

function getPriorVotes(address account, uint256 blockNumber) public view returns (uint256) {
    require(blockNumber < block.number, "not yet determined");
    // Binary search through checkpoints
    uint32 nCheckpoints = numCheckpoints[account];
    if (nCheckpoints == 0) return 0;
    // ... standard checkpoint binary search
}
```

---

### FINDING-02 [LOW]: CErc20.doTransferOut Silently Skips Return Value Check for USDT

**File:** `contracts/CErc20.sol:187-189`

**Description:**
The `doTransferOut` function has a special case for USDT that skips all return value checking:

```solidity
function doTransferOut(address payable to, uint amount) internal {
    EIP20NonStandardInterface token = EIP20NonStandardInterface(underlying);
    token.transfer(to, amount);             // transfer is called

    bool success;
    if(address(token) == USDTAddr){
        return;                             // SKIP return value check for USDT
    }
    assembly {
        switch returndatasize()
            case 0 { success := not(0) }
            case 32 { returndatacopy(0, 0, 32)
                       success := mload(0) }
            default { revert(0, 0) }
    }
    require(success, "TOKEN_TRANSFER_OUT_FAILED");
}
```

The USDT address is hardcoded: `0xa614f803B6FD780986A42c78Ec9c7f77e6DeD13C` (TRON mainnet).

**Impact:** If TRON USDT's `transfer()` ever returns `false` instead of reverting on failure, the protocol would record a successful transfer that didn't occur, causing accounting mismatches. However, TRON's USDT implementation reverts on failure (insufficient balance, etc.), making this largely theoretical.

For outbound transfers (borrow, redeem), a silent failure would hurt the user (debt recorded but no tokens received), not the protocol. The `doTransferIn` function correctly uses pre/post balance checks, so deposits are safe.

**Severity:** LOW — Defensive coding gap, practically mitigated by TRON USDT's revert-on-failure behavior.

**Recommendation:** Remove the USDT special case and use a universal approach like OpenZeppelin's `SafeERC20.safeTransfer()`.

---

### FINDING-03 [LOW]: GovernorBravo Unsafe uint96 Downcast for Vote Counts

**File:** `contracts/Governance/Bravo/GovernorBravoDelegate.sol:291,296`

**Description:**
Vote counts are silently truncated from `uint256` to `uint96` when stored:

```solidity
receipt.votes = uint96(votes);    // line 291 — silent truncation
return uint96(votes);             // line 296 — silent truncation
```

The `Receipt.votes` field is defined as `uint96` in `GovernorBravoInterfaces.sol:157`.

**Impact:** If `votes > 2^96 - 1` (≈ 7.9 × 10^28), the stored value silently wraps. However, JST total supply is 9.9B × 10^18 = 9.9 × 10^27, which is within `uint96` range. A single voter cannot have more tokens than total supply.

**Severity:** LOW — Practically bounded by JST total supply, but the unchecked downcast is a defensive coding gap.

**Recommendation:** Add an explicit bounds check: `require(votes <= uint96(-1), "votes overflow uint96");`

---

### FINDING-04 [LOW]: WJST.transferFrom Missing SafeMath on Balance Operations

**File:** `contracts/Governance/WJST.sol:174,177-178`

**Description:**
In Solidity ^0.5.12 (no built-in overflow protection), the `transferFrom` function uses raw arithmetic instead of SafeMath for balance updates:

```solidity
function transferFrom(address src, address dst, uint256 sad) public returns (bool) {
    require(balanceOf_[src] >= sad, "src balance not enough");
    if (src != msg.sender && allowance_[src][msg.sender] != uint256(- 1)) {
        require(allowance_[src][msg.sender] >= sad, "src allowance is not enough");
        allowance_[src][msg.sender] -= sad;     // line 174 — safe (require above)
    }
    balanceOf_[src] -= sad;                      // line 177 — safe (require above)
    balanceOf_[dst] += sad;                      // line 178 — NO overflow check
    ...
}
```

Similarly, `withdraw()` (lines 86-87) uses raw subtraction.

**Impact:** Line 178 could theoretically overflow if `balanceOf_[dst] + sad > 2^256 - 1`. This is practically impossible with JST supply of ~9.9B tokens (even at 18 decimals = ~9.9 × 10^27, far below 2^256 ≈ 1.16 × 10^77).

**Severity:** LOW — Theoretically unsound but practically unexploitable given finite token supply.

**Recommendation:** Use SafeMath consistently: `balanceOf_[dst] = balanceOf_[dst].add(sad);`

---

### FINDING-05 [LOW]: CEther.doTransferIn Excess TRX Refund May Fail for Contract Callers

**File:** `contracts/CEther.sol:158-164` (approximate)

**Description:**
JustLend modified Compound's `doTransferIn` from `require(msg.value == amount)` to `require(msg.value >= amount)` with an excess refund mechanism:

```solidity
function doTransferIn(address from, uint amount) internal returns (uint) {
    require(msg.sender == from, "sender mismatch");
    require(msg.value >= amount, "value mismatch");
    if (msg.value > amount) {
        uint256 repayAmount = sub(msg.value, amount, "calc surplus");
        address(uint160(from)).transfer(repayAmount);  // 2300 gas stipend
    }
    return amount;
}
```

The `.transfer()` call uses a 2300 gas stipend, which may be insufficient for contract callers that need to execute fallback logic.

**Impact:** Smart contracts interacting with jTRX (CEther) that send excess TRX will have their transaction revert if their fallback/receive function requires more than 2300 gas. This affects composability but not direct user interactions.

**Severity:** LOW — Composability issue for contract integrators, not exploitable.

**Recommendation:** Use `.call{value: repayAmount}("")` with success check, or document the 2300 gas requirement.

---

### FINDING-06 [INFORMATIONAL]: Deployed Comptroller Contains Features Absent from GitHub

The deployed Comptroller at `TCtzg2CQsAuLkSxrGjFGbHVwKvv95W9C8e` includes:
- **Borrow cap subsystem:** `_setBorrowCapGuardian`, `borrowCapGuardian`, `borrowCaps`, `_setMarketBorrowCaps`
- **Collateral factor guardian:** `_setCollateralFactorGuardian`, `collateralFactorGuardian`, `collateralFactorGuardianMarkets`, `_setCollateralFactorGuardianStateForMarket`
- **Modified `_become`:** Takes single `address` instead of `(Unitroller, address[])`

These features likely derive from Compound V2.8+ (borrow caps) and a JustLend-custom guardian system. The GitHub repository does not contain this code, so these paths cannot be audited from the repository.

---

### FINDING-07 [INFORMATIONAL]: CTokenERC777 is Misleadingly Named Dead Code

`contracts/CTokenERC777.sol` (~1,400 lines) contains zero ERC777-specific functions (no `tokensReceived`, `tokensToSend`, or ERC1820 registration). It is a near-identical copy of `CToken.sol` with the only material difference being reversed ordering in `redeemFresh` (proper CEI pattern). This appears to be an alternate implementation that was never deployed.

---

### FINDING-08 [INFORMATIONAL]: COMP Distribution Flywheel Absent

The Comptroller includes `ComptrollerV3Storage` variables (`compRate`, `compSpeeds`, `compSupplyState`, etc.) but contains zero distribution functions (`updateCompSupplyIndex`, `distributeSupplierComp`, `claimComp`). The token distribution mechanism exists only as storage declarations.

---

### FINDING-09 [INFORMATIONAL]: WJST Owner Can Arbitrarily Change Governor Contract

`WJST.sol:185-187`:
```solidity
function setGovernorAlpha(address governorAlpha_) public onlyOwner {
    governorAlpha = GovernorAlphaInterface(governorAlpha_);
}
```

The owner can point WJST to any address as the governor, potentially a malicious contract that calls `voteFresh()` to permanently lock users' tokens. This is a centralization risk inherent in the owner role.

---

### FINDING-10 [INFORMATIONAL]: GovernorAlpha Uses Hardcoded Chain ID = 1

`contracts/Governance/GovernorAlpha.sol:326-331`:
```solidity
function getChainId() internal pure returns (uint) {
    return uint(1);  // Hardcoded Ethereum mainnet chain ID
}
```

The legacy GovernorAlpha uses Ethereum mainnet's chain ID (1) for EIP-712 domain separator construction instead of TRON's chain ID (728126428). This is a cross-chain signature replay issue, but GovernorAlpha is now superseded by GovernorBravo (which uses `chainid()` opcode with masking), so this is inactive code.

---

## Hypotheses Tested (Not Exploitable)

| # | Hypothesis | Result | Reasoning |
|---|-----------|--------|-----------|
| 1 | Flash-loan governance attack via WJST | NOT EXPLOITABLE | `voteFresh()` locks tokens (deducts from balanceOf_), preventing same-tx flash loan repayment |
| 2 | WJST double-voting via incremental voting | NOT EXPLOITABLE | Each `voteFresh()` reduces `balanceOf_`, `getPriorVotes` returns current (reduced) balance — total votes bounded by initial balance |
| 3 | WJST withdraw locked tokens | NOT EXPLOITABLE | `require(balanceOf_[msg.sender] >= sad)` checks against balance AFTER voteFresh deduction |
| 4 | WJST withdrawVotes before proposal ends | NOT EXPLOITABLE | `require(governorAlpha.state(proposalId) >= 2)` — state 2+ = Canceled/Defeated/Succeeded/Queued/Expired/Executed |
| 5 | Comptroller reentrancy via CToken | NOT EXPLOITABLE | Standard Compound V2 checks-effects-interactions pattern maintained |
| 6 | CToken exchange rate manipulation | NOT EXPLOITABLE | Standard Compound V2 `exchangeRateStoredInternal()` uses internal accounting |
| 7 | First-depositor inflation attack on CToken | NOT EXPLOITABLE | Compound V2 initialExchangeRate prevents zero-share minting |
| 8 | Interest rate model manipulation | NOT EXPLOITABLE | Standard Compound V2 models, only blocksPerYear adjusted for TRON (10,512,000) |
| 9 | Timelock bypass | NOT EXPLOITABLE | Standard Compound timelock, admin checks maintained |
| 10 | PriceOracleProxy stale prices | NOT EXPLOITABLE | Standard Compound V2, relies on V1PriceOracle which is externally managed |
| 11 | CErc20 doTransferIn balance manipulation | NOT EXPLOITABLE | Pre/post balance check on lines 148-170 catches fee-on-transfer and rebasing tokens |
| 12 | Maximillion excess refund attack | NOT EXPLOITABLE | Standard Compound pattern, borrows is computed before value comparison |
| 13 | Unitroller storage collision | NOT EXPLOITABLE | Standard Compound delegatecall proxy with proper storage layout inheritance |
| 14 | GovernorBravo proposal spam | NOT EXPLOITABLE | One active/pending proposal per proposer, threshold check |
| 15 | GovernorBravo EIP-712 replay | NOT EXPLOITABLE | Uses `chainid()` opcode (with masking), bound to contract address |
| 16 | reserveAdmin address(0) locks reserves | DEPLOYMENT CONCERN | If reserveAdmin never set, `_reduceReserves` always reverts (msg.sender != address(0)) — but this is a deployment/config issue |
| 17 | CEther repayBorrow amount mismatch | NOT EXPLOITABLE | `require(msg.value >= amount)` with explicit amount parameter prevents underpayment |
| 18 | GovernorBravo whitelist bypass | NOT EXPLOITABLE | `isWhitelisted` checks `whitelistAccountExpirations[account] > now` — admin-only setting |
| 19 | CToken statusSnapShot reentrancy | NOT EXPLOITABLE | Called after state updates, reads only internal variables |
| 20 | WJST deposit reentrancy | NOT EXPLOITABLE | `transferFrom` to contract happens before balance update, but TRC20 standard doesn't support reentrancy hooks |

## Architecture Notes

### Key Deviations from Compound V2

1. **Governance (Novel):** WJST wrapper with vote-and-lock instead of Comp checkpoints+delegation. Incremental voting allows partial/multiple votes. GovernorBravo uses explicit `votes` parameter.

2. **CEther (Modified):** `repayBorrow(uint amount)` takes explicit amount (Compound uses implicit msg.value). `doTransferIn` allows excess TRX with refund.

3. **CToken (Modified):** `reserveAdmin` role separates reserve management from protocol admin. `_reduceReserves` sends to `reserveAdmin`. JTokenStatus/JTokenBalance events added for monitoring.

4. **CErc20 (Modified):** Hardcoded USDT address with return value skip. `initialize()` takes additional `newReserveFactorMantissa_` parameter.

5. **Comptroller (Modified):** `enterMarket(address)` singular convenience function. `getCompAddress()` returns from storage (not hardcoded). Missing COMP distribution flywheel.

6. **Block Timing:** All interest rate models use `blocksPerYear = 10,512,000` for TRON's 3-second blocks (vs Ethereum's ~2,102,400).

### Files Not Audited
- Deployed Comptroller borrow cap and collateral factor guardian subsystems (not in GitHub)
- `PriceOracle/PriceOracleV1.sol` — Centralized oracle, externally managed poster-based pricing
- Governance proposal contracts (ProposalAddNftMarket, ProposalAddUsdcMarket, etc.) — one-time deployment scripts
- `Governance/Comp.sol` — Compound's COMP token, appears unused in JustLend's governance

## Conclusion

JustLend DAO's core lending/borrowing logic closely follows Compound V2 and inherits its well-audited security properties. The primary risk area is the novel governance system: WJST's lack of checkpoint mechanism (FINDING-01) breaks the fundamental assumption that voting power is determined at proposal creation time. This enables post-proposal vote accumulation, though the vote-and-lock mechanism provides meaningful protection against flash-loan attacks.

The remaining findings are defensive coding gaps (missing SafeMath, unsafe downcasts, return value skip) that are practically bounded by TRON-specific behavior and token supply constraints.

**Immunefi Submission:** 1 report submitted for FINDING-01 (WJST governance manipulation).
