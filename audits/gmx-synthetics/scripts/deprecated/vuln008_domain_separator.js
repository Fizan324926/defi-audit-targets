#!/usr/bin/env node
/**
 * VULN-008: Domain Separator Cross-Chain Replay Analysis
 *
 * Demonstrates how using srcChainId instead of block.chainid in the
 * EIP-712 domain separator enables cross-chain signature replay.
 *
 * Usage: node vuln008_domain_separator.js
 */

const crypto = require("crypto");

// Simulate keccak256 (simplified - uses sha256 for demonstration)
function simKeccak256(...args) {
    const hash = crypto.createHash("sha256");
    for (const arg of args) {
        hash.update(Buffer.from(arg.toString()));
    }
    return hash.digest("hex");
}

function encodePacked(...args) {
    return args.map(a => a.toString()).join("|");
}

// Simulate EIP-712 domain separator computation
function getDomainSeparator(name, version, chainId, contractAddress) {
    const typeHash = simKeccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    const nameHash = simKeccak256(name);
    const versionHash = simKeccak256(version);

    return simKeccak256(
        encodePacked(typeHash, nameHash, versionHash, chainId, contractAddress)
    );
}

function analyzeReplay() {
    console.log("=".repeat(70));
    console.log("VULN-008: Domain Separator Cross-Chain Replay Analysis");
    console.log("=".repeat(70));

    // GMX domain separator parameters
    const name = "GMX";
    const version = "1";

    // Scenario 1: Standard EIP-712 (using block.chainid)
    console.log("\n--- Standard EIP-712 (block.chainid) ---");

    const arbitrumChainId = 42161;
    const avalancheChainId = 43114;
    const arbitrumAddress = "0x1234567890abcdef1234567890abcdef12345678";
    const avalancheAddress = "0xabcdef1234567890abcdef1234567890abcdef12";

    const domainArbitrum = getDomainSeparator(name, version, arbitrumChainId, arbitrumAddress);
    const domainAvalanche = getDomainSeparator(name, version, avalancheChainId, avalancheAddress);

    console.log(`  Arbitrum domain: ${domainArbitrum.slice(0, 16)}...`);
    console.log(`  Avalanche domain: ${domainAvalanche.slice(0, 16)}...`);
    console.log(`  Same? ${domainArbitrum === domainAvalanche ? "YES (VULNERABLE)" : "NO (protected by different chain/address)"}`);

    // Scenario 2: GMX's approach (using srcChainId parameter)
    console.log("\n--- GMX Approach (srcChainId parameter) ---");

    // On Arbitrum: srcChainId = 42161 (user submitting on Arbitrum)
    const gmxDomainArbitrum = getDomainSeparator(name, version, arbitrumChainId, arbitrumAddress);
    console.log(`  On Arbitrum (srcChainId=42161): ${gmxDomainArbitrum.slice(0, 16)}...`);

    // On Avalanche with srcChainId=42161 (cross-chain: user signed on Arbitrum)
    // This is the KEY: Avalanche contract accepts srcChainId=42161 for cross-chain ops
    const gmxDomainAvalancheWithArbitrumSrc = getDomainSeparator(name, version, arbitrumChainId, avalancheAddress);
    console.log(`  On Avalanche (srcChainId=42161): ${gmxDomainAvalancheWithArbitrumSrc.slice(0, 16)}...`);
    console.log(`  Same? ${gmxDomainArbitrum === gmxDomainAvalancheWithArbitrumSrc ? "YES (VULNERABLE)" : "NO (different contract address protects)"}`);

    // Scenario 3: CREATE2 deployment (same address on both chains)
    console.log("\n--- Scenario 3: CREATE2 (Same Address Both Chains) ---");
    const sameAddress = "0x5555555555555555555555555555555555555555";

    const domainArbitrumSame = getDomainSeparator(name, version, arbitrumChainId, sameAddress);
    const domainAvalancheSameWithArbitrumSrc = getDomainSeparator(name, version, arbitrumChainId, sameAddress);

    console.log(`  Arbitrum (srcChainId=42161, addr=${sameAddress.slice(0, 10)}...): ${domainArbitrumSame.slice(0, 16)}...`);
    console.log(`  Avalanche (srcChainId=42161, addr=${sameAddress.slice(0, 10)}...): ${domainAvalancheSameWithArbitrumSrc.slice(0, 16)}...`);
    console.log(`  Same? ${domainArbitrumSame === domainAvalancheSameWithArbitrumSrc ? "YES - SIGNATURE REPLAY POSSIBLE!" : "NO"}`);

    // Protection analysis
    console.log("\n--- Protection Layers ---");
    console.log(`
  1. address(this) in domain separator:
     - Different if deployed to different addresses ✓
     - Same if CREATE2/deterministic deployment ✗

  2. desChainId validation:
     From BaseGelatoRelayRouter._validateCallWithoutSignature():
       if (desChainId != block.chainid) revert InvalidDestinationChainId()
     This is the MAIN protection against cross-chain replay ✓

  3. Digest mapping (digestUsed):
     - Only prevents replay on the SAME chain ✓
     - Does NOT prevent replay on a DIFFERENT chain ✗

  4. srcChainId whitelist:
     - Checks: isSrcChainIdEnabled(srcChainId)
     - For multichain: Arbitrum's srcChainId IS enabled on Avalanche ✗
    `);

    // The desChainId check
    console.log("--- Critical: desChainId Protection ---");
    console.log(`
  The EIP-712 struct hash includes desChainId, which is validated:
    if (desChainId != block.chainid) revert InvalidDestinationChainId()

  This means:
  - User signs: {srcChainId: 42161, desChainId: 42161} (on Arbitrum for Arbitrum)
  - On Avalanche: desChainId=42161 != block.chainid=43114 → REVERTS

  BUT for cross-chain operations:
  - User signs: {srcChainId: 42161, desChainId: 43114} (on Arbitrum for Avalanche)
  - On Avalanche: desChainId=43114 == block.chainid=43114 → PASSES
  - On Arbitrum: desChainId=43114 != block.chainid=42161 → REVERTS

  So cross-chain signatures are inherently targeted to one destination.
  The replay risk is LIMITED to:
  1. Same address on multiple chains AND
  2. Attacker intercepts cross-chain message before execution AND
  3. Submits on destination chain before legitimate execution
    `);
}

function analyzeEIP712Compliance() {
    console.log("\n" + "=".repeat(70));
    console.log("EIP-712 Compliance Analysis");
    console.log("=".repeat(70));

    console.log(`
  EIP-712 specifies domain separator should use:
  - name: contract/protocol name
  - version: contract version
  - chainId: EIP-155 chain ID (i.e., block.chainid)
  - verifyingContract: address of the contract

  GMX DEVIATION:
  - Uses srcChainId (user-supplied) instead of block.chainid
  - This is intentional for cross-chain support
  - But breaks EIP-712's replay protection guarantee

  Standard wallets (MetaMask, etc.) compute domain separator with:
  - block.chainid of the connected network

  If user is on Arbitrum and signs with srcChainId=42161:
  - Wallet sees chainId=42161 ✓
  - Domain separator matches
  - Signature is valid

  If same signature is replayed on Avalanche with srcChainId=42161:
  - Avalanche contract computes domain with chainId=42161 (from param)
  - Domain separator matches the original
  - Signature validates (if same contract address)
  - ONLY desChainId check prevents execution
    `);
}

// Main
analyzeReplay();
analyzeEIP712Compliance();

console.log("\n" + "=".repeat(70));
console.log("VERDICT:");
console.log("  Primary risk: Domain separator doesn't bind to execution chain");
console.log("  Mitigating: desChainId check prevents most replay scenarios");
console.log("  Residual risk: CREATE2 + intercepted cross-chain messages");
console.log("  Severity: HIGH (conditional on deployment pattern)");
console.log("=".repeat(70));
