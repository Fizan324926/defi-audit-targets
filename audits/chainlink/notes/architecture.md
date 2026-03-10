# Chainlink Architecture Notes

## CCIP Message Flow
1. Source: User → Router.ccipSend() → OnRamp.forwardFromRouter() → TokenPool.lockOrBurn()
2. DON: Commit plugin observes events → builds merkle root → RMN signs → Commit OCR report
3. Dest: OffRamp.commit() [OCR3 + RMN verify] → OffRamp.execute() [merkle proof + state machine]
4. Dest: TokenPool.releaseOrMint() → Router.routeMessage() → receiver.ccipReceive()

## Security Model
- OCR3: F+1 of 3F+1 signers (Byzantine fault tolerance)
- RMN: Independent f+1 of 2f+1 signer set
- Merkle: Domain-separated multi-proofs
- Execution: 2-bit state machine, atomic token+callback

## Key Trust Boundaries
- DON consensus (core assumption: <F+1 Byzantine)
- RMN (independent verification layer)
- Token admin registry (self-serve, token owners control pools)
- Owner/admin (config changes, fee parameters)
- Capabilities registry (CCIPHome config)

## Areas Analyzed (All Clean)
- CCIP EVM: Router, OnRamp, OffRamp, FeeQuoter, RMNRemote, RMNHome, RMNProxy
- CCIP EVM: MerkleMultiProof, MultiOCR3Base, RateLimiter, NonceManager
- CCIP EVM: TokenPool hierarchy, TokenAdminRegistry, CallWithExactGas
- CCIP EVM: FeeQuoter, CCIPHome, Internal, Client, USDPriceWith18Decimals
- CCIP Solana: ccip-router, ccip-offramp, fee-quoter, rmn-remote, token pools
- CCIP Go: commit plugin, execute plugin
- Chainlink EVM: VRF (V2, V2.5), LLO Feeds (v0.4, v0.5), DataFeedsCache
- Chainlink EVM: Automation v2.3, Functions v1.3.0
- Chainlink Solana: data-feeds-cache, keystone-forwarder, ocr_2
- CCIP Owner: ManyChainMultiSig, RBACTimelock, CallProxy
