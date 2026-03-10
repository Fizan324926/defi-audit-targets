# Xterio Protocol Security Audit Report

**Date:** 2026-03-03
**Auditor:** AI-assisted security review
**Scope:** TokenGateway (`0x7127f0FEaEF8143241A5FaC62aC5b7be02Ef26A9`), MarketplaceV2 (`0xFC1759E75180aeE982DC08D0d6D365ebFA0296a7`), + all supporting contracts
**Repository:** https://github.com/XterioTech/xt-contracts
**Bounty:** https://immunefi.com/bug-bounty/xterio/ (max $80K Critical)
**Chains:** Ethereum, BNB Chain, Polygon, opBNB, Xterio Chain (ETH/BNB), Base

---

## Executive Summary

**Result: CLEAN** — No exploitable Critical or High severity vulnerabilities found. The in-scope contracts (TokenGateway, MarketplaceV2) are well-designed with appropriate security patterns. 69 Solidity files reviewed across the full codebase. 20 findings identified (0 Critical, 0 High, 7 Medium, 7 Low, 6 Informational). All Medium findings are defense-in-depth issues or admin trust concerns, not directly exploitable for user fund loss.

---

## Findings Summary

| ID | Severity | Contract | Finding | Immunefi? |
|----|----------|----------|---------|-----------|
| F-01 | Medium | TokenGateway | Grace period allows previous manager to re-instate themselves via setManagerOf | No — admin trust |
| F-02 | Medium | TokenGateway | Ownable.transferOwnership bypasses gateway access control | No — admin trust |
| F-03 | Medium | TokenGateway | GATEWAY_MANAGER_ROLE can resetOwner on ANY token contract | No — admin trust |
| F-04 | Medium | MarketplaceV2 | Missing nonReentrant on atomicMatchAndDeposit | No — not exploitable |
| F-05 | Medium | OnchainIAP | No staleness/negative check on Chainlink oracle | No — not in scope |
| F-06 | Medium | FansCreateCore | Creator fee DoS — reverting creator address freezes all sells | No — self-grief + signer gate |
| F-07 | Medium | Launchpool | Owner can drain reward tokens via withdrawERC20Token | No — admin trust |
| F-08 | Low | TokenGateway | Missing storage gap (__gap) for upgradeable contract | — |
| F-09 | Low | MarketplaceV2 | Missing storage gap (__gap) for upgradeable contract | — |
| F-10 | Low | MarketplaceV2 | Fee validation gap: combined fees >= 100% causes revert on non-ERC2981 path | — |
| F-11 | Low | MarketplaceV2 | Native ETH DoS via reverting recipient | — |
| F-12 | Low | FansCreateCore | Missing reentrancy guard in non-upgradeable version (not exploitable for profit) | — |
| F-13 | Low | FansCreateCore | publishAndBuyKeys missing creator == msg.sender check (non-upgradeable) | — |
| F-14 | Low | TokenGateway | setGatewayOf does not clear minter sets | — |
| F-15 | Informational | MarketplaceV2 | abi.encodePacked with dynamic bytes (theoretical collision, not exploitable) | — |
| F-16 | Informational | MarketplaceV2 | Zero-price orders allow fee-free NFT transfers | — |
| F-17 | Informational | TokenGateway | Mixing upgradeable/non-upgradeable OZ contracts | — |
| F-18 | Informational | XterStaking | No duration validation allows zero-duration stakes | — |
| F-19 | Informational | Launchpool | Reward rate precision loss locks dust tokens | — |
| F-20 | Informational | Multiple | Missing zero-address checks in admin setters | — |

---

## Detailed Findings

### F-01: Grace Period Self-Reinstatement [Medium]

**File:** `contracts/basic-tokens/management/TokenGateway.sol:218-233, 378-392`

When a manager is replaced via `setManagerOf()`, the previous manager retains full management access for 24 hours via the grace period logic in `isInManagement()`. The `onlyManagerOrGateway` modifier uses `isInManagement()`, which means the previous manager can call `setManagerOf(token, self)` within the grace period to reinstall themselves as manager.

**Why not submittable:** The manager was already trusted. Replacing a malicious manager requires the GATEWAY_MANAGER_ROLE or DEFAULT_ADMIN_ROLE to intervene immediately via `setGatewayOf()` which clears all manager state and migrates the token to a new gateway. This is an admin response time issue, not an external exploit.

### F-02: Ownable.transferOwnership Bypasses Gateway [Medium]

**File:** `contracts/basic-tokens/management/GatewayGuardedOwnable.sol:10`

`GatewayGuardedOwnable` inherits `Ownable` without overriding `transferOwnership()`. The token contract owner can transfer ownership directly without going through the gateway. The new owner immediately gains management access via the `isInManagement()` Ownable fallback.

**Why not submittable:** The token owner is already a trusted role with equivalent or greater privileges than a gateway-assigned manager.

### F-03: resetOwner Overprivileged [Medium]

**File:** `contracts/basic-tokens/management/TokenGateway.sol:205-210`

Any `GATEWAY_MANAGER_ROLE` holder can call `resetOwner` on ANY token contract pointing to this gateway, regardless of whether they are the assigned manager for that specific token. This is broader than `setManagerOf` which uses `onlyManagerOrGateway`.

**Why not submittable:** GATEWAY_MANAGER_ROLE is a trusted admin role granted by DEFAULT_ADMIN_ROLE. Privilege separation within admin roles is a design concern, not an external exploit.

### F-04: Missing nonReentrant on atomicMatchAndDeposit [Medium]

**File:** `contracts/nft-marketplace/MarketplaceV2.sol:265-311`

`atomicMatchAndDeposit` calls `atomicMatch` (which has `nonReentrant`) then makes additional external calls via `_transferNFT` after the reentrancy guard is released. The `_transferNFT` triggers ERC721/ERC1155 callbacks that could re-enter.

**Why not submittable:** After `atomicMatch` completes, fills are updated and the order is consumed. Re-entry cannot replay the same order. Re-entry with a different order is just executing two legitimate trades. No fund loss vector identified.

### F-05: OnchainIAP Missing Oracle Staleness Check [Medium]

**File:** `contracts/onchain-iap/OnchainIAP.sol:293-306`

`getOracleLatestAnswer()` calls Chainlink `latestRoundData()` but ignores `updatedAt`, `roundId`, and `answeredInRound`. A stale or negative oracle price could cause users to purchase items at incorrect prices.

**Why not submittable:** OnchainIAP is not in the explicit scope. While Primacy of Impact applies, the impact is limited to in-app purchases (not direct fund loss from protocol), and pricing is bounded by admin-configured SKU parameters.

### F-06: Creator Fee DoS in FansCreate [Medium]

**File:** `contracts/fans-create/FansCreate.sol:41-43`, `contracts/fans-create/FansCreateCore.sol:303-360`

In the native ETH variant, `payOut()` uses `.call{value:}()` to send creator fees. If the `creator` address is a contract that reverts on receive, all `sellKeys()` calls for that work permanently fail, freezing user funds in the bonding curve.

**Why not submittable:** The `publishAndBuyKeys` function requires a backend SIGNER_ROLE signature that includes the creator address. The backend server controls which creator addresses are approved. Additionally, the attacker freezes their own keys alongside other users (self-grief component). The upgradeable version also requires `creator == msg.sender`.

### F-07: Launchpool Owner Can Drain Reward Tokens [Medium]

**File:** `contracts/launchpool/Launchpool.sol:256-269`

`withdrawERC20Token()` blocks withdrawal of `stakeToken` but NOT `rewardToken`. The owner can withdraw all reward tokens at any time.

**Why not submittable:** Admin trust issue. Most Immunefi programs exclude admin-triggered issues.

---

## Architecture Notes

### TokenGateway
- **Role hierarchy:** DEFAULT_ADMIN_ROLE > GATEWAY_MANAGER_ROLE > Token Manager > Minter
- **Access control:** Well-structured with appropriate separation
- **Grace period:** 24-hour transition window for manager changes (intentional design)
- **Proxy pattern:** Upgradeable via Initializable, constructor disables initializers

### MarketplaceV2
- **Signature scheme:** `keccak256(abi.encodePacked(transactionType, order, metadata, block.chainid))`
- **Reentrancy:** `nonReentrant` on `atomicMatch` (core function)
- **Fee model:** Basis points (BASE=10000), ERC2981 royalty support with signed-order cap
- **Fill tracking:** Per-user per-order fill counts, prevents replay and overfilling
- **ERC1271:** Contract wallet support for signature validation

### Security Patterns Observed
- ReentrancyGuard on critical functions
- Checked arithmetic (Solidity 0.8+)
- Signature includes chainId and contract address
- Proper CEI ordering in most functions
- Constructor disables initializers for proxy safety

---

## Methodology

1. Full codebase read (69 Solidity files)
2. Architecture mapping and dependency analysis
3. Multi-angle analysis (3 parallel deep-audit agents)
4. Manual verification of all reported findings
5. False positive elimination per AUDIT-AI-RULES.md Phase 5
6. Cross-contract interaction analysis
7. Bonding curve math verification (FansCreate)
8. Signature scheme collision analysis (MarketplaceV2)

---

## Conclusion

The Xterio protocol demonstrates solid security engineering. The in-scope contracts (TokenGateway, MarketplaceV2) use well-established patterns from OpenZeppelin and follow reasonable security practices. The most notable gaps are missing `__gap` storage variables for upgradeable contracts and the absence of `nonReentrant` on `atomicMatchAndDeposit` — both defense-in-depth improvements rather than exploitable vulnerabilities.

**No Immunefi submissions recommended.** All findings are either admin trust issues (excluded by most programs), defense-in-depth improvements, or theoretical concerns without practical exploitability.
