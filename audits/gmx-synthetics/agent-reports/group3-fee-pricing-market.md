# Agent Report: Fee Distribution + Pricing + Market Math + Claim

**Scope:** `fee/*`, `pricing/*`, `market/*`, `claim/*`

## Findings Summary

No new submittable vulnerabilities found.

### FeeSwapUtils vs VULN-003 (RelayUtils): DISTINCT
`FeeSwapUtils.swapFeesUsingV1/V2` both accept CALLER-SUPPLIED `minOut` parameters — NOT hardcoded to 0. This is architecturally different from VULN-003's hardcoded `minOutputAmount: 0` in RelayUtils. The fee keeper is trusted to supply reasonable slippage tolerance. NOT a zero-slippage vulnerability.

### Fee Double-Claiming: SAFE
`FeeUtils.claimFees` and `MarketUtils.claimFundingFees` both zero the stored amount BEFORE transferring (read → zero → transfer pattern). Second claim on same key returns 0 and transfers 0. GlobalReentrancyGuard prevents reentrancy.

### Collateral Double-Claiming: SAFE
`MarketUtils.claimCollateral` uses `claimedCollateralAmountKey` tracking. Sets claimed amount to `adjustedClaimableAmount` after each claim. Re-calling with same parameters yields `adjustedClaimableAmount <= adjustedClaimableAmount` → reverts.

### Fee Distribution Sandwich: SAFE
FeeDistributor uses cross-chain snapshot-based distribution (not in-block proportional distribution). New stakers joining after the snapshot do not benefit retroactively. Not sandwichable.

### MarketToken Inflation Attack: SAFE
`ExecuteDepositUtils._validateFirstDeposit` explicitly guards first deposits: requires receiver to be `RECEIVER_FOR_FIRST_DEPOSIT` with a minimum token threshold. `usdToMarketTokenAmount` handles `supply == 0 && poolValue > 0` case correctly (proportional to existing pool value). Not ERC-4626, so standard inflation attack does not apply.

### Market Token Price Manipulation: SAFE
`getPoolValueInfo` reads `poolAmount` from DataStore (protocol-tracked mapping), not from `IERC20.balanceOf()`. Direct token transfers to market token contract do not affect the price calculation. Flash loans cannot manipulate GM token prices.

### Position Impact Pool Drain: SAFE
Positive price impact is capped by `maxPositionImpactFactor` and impact pool size. `getAdjustedPositionImpactFactors` enforces `positiveImpactFactor <= negativeImpactFactor`. Position fees make systematic drain uneconomical.

### ClaimHandler Terms Signature Bypass: COMPLIANCE CONCERN ONLY (LOW)
`ClaimHandler.sol:301` — `StringUtils.compareStrings(terms, acceptedTerms)` allows skipping ECDSA signature check if the user echoes the exact terms text. Since `terms` is publicly readable on-chain, any on-chain actor can claim without a cryptographic signature. However, claimable amounts are keyed to `msg.sender` — no financial theft is possible beyond what the user was already assigned. This is a legal/compliance concern (no proof of informed consent), not a financial exploit.

### Claim Receiver Injection: SAFE
`ClaimHandler.acceptTermsAndClaim` uses `msg.sender`-gated claimable amounts. Users can only claim their own allocations to any receiver they choose. No cross-user theft.

### MarketFactory Access Control: SAFE
`createMarket` is `onlyMarketKeeper`. Duplicate markets revert with `MarketAlreadyExists`.

### Fee Arithmetic Rounding: SAFE
Rounding directions consistently favor the protocol (roundUpDivision for costs charged to users). No systematic fee drainage via truncation.

## Conclusion

Fee, pricing, and market math are correctly implemented with appropriate safety measures. No new submittable findings.
