// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * VULN-008: Domain Separator Cross-Chain Replay
 *
 * Proves that domain separator computed with srcChainId parameter
 * produces identical digests when the same srcChainId is used on
 * different chains (if contract address is the same).
 *
 * To run: forge test --match-contract VULN008Test -vvv
 */

contract DomainSeparatorChecker {
    bytes32 public constant DOMAIN_SEPARATOR_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 public constant NAME_HASH = keccak256("GMX");
    bytes32 public constant VERSION_HASH = keccak256("1");

    /// @dev GMX's approach: uses sourceChainId parameter
    function getDomainSeparatorGMX(uint256 sourceChainId) public view returns (bytes32) {
        return keccak256(abi.encode(
            DOMAIN_SEPARATOR_TYPEHASH,
            NAME_HASH,
            VERSION_HASH,
            sourceChainId,  // User-supplied, NOT block.chainid
            address(this)
        ));
    }

    /// @dev Standard EIP-712: uses block.chainid
    function getDomainSeparatorStandard() public view returns (bytes32) {
        return keccak256(abi.encode(
            DOMAIN_SEPARATOR_TYPEHASH,
            NAME_HASH,
            VERSION_HASH,
            block.chainid,  // Actual chain ID
            address(this)
        ));
    }

    /// @dev Compute a typed data hash (EIP-712 style)
    function getDigest(bytes32 domainSep, bytes32 structHash) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            "\x19\x01",
            domainSep,
            structHash
        ));
    }
}

contract VULN008Test {
    DomainSeparatorChecker public checker;

    function setUp() public {
        checker = new DomainSeparatorChecker();
    }

    function testDomainSeparatorWithSrcChainId() public view {
        // Compute domain separator with srcChainId = 42161 (Arbitrum)
        bytes32 domainArbitrum = checker.getDomainSeparatorGMX(42161);

        // On a different chain, if contract has same address and srcChainId=42161 is used:
        // The domain separator would be IDENTICAL
        // (we can't actually deploy on two chains in a test, but we prove the math)

        // Both calls with same srcChainId produce same result
        bytes32 domainAgain = checker.getDomainSeparatorGMX(42161);
        assert(domainArbitrum == domainAgain);

        // Different srcChainId produces different domain
        bytes32 domainAvalanche = checker.getDomainSeparatorGMX(43114);
        assert(domainArbitrum != domainAvalanche);
    }

    function testStandardVsGMXApproach() public view {
        // Standard approach uses block.chainid (test chain = 31337 typically)
        bytes32 standard = checker.getDomainSeparatorStandard();

        // GMX approach can produce domain for ANY chain
        bytes32 gmxForTestChain = checker.getDomainSeparatorGMX(block.chainid);
        assert(standard == gmxForTestChain); // Same when srcChainId == block.chainid

        // But GMX can ALSO produce domain for Arbitrum while running on test chain
        bytes32 gmxForArbitrum = checker.getDomainSeparatorGMX(42161);
        assert(standard != gmxForArbitrum); // Different chain = different domain

        // KEY INSIGHT: On Avalanche, if srcChainId=42161 is enabled,
        // the domain separator matches what was used on Arbitrum
        // This is by design for cross-chain, but enables replay
    }

    function testDigestReplayability() public view {
        // Simulate a user signing on Arbitrum
        bytes32 structHash = keccak256(abi.encode(
            "CreateOrder",
            address(0xBEEF),  // account
            uint256(100000),  // sizeDelta
            uint256(42161),   // desChainId (targeting Arbitrum)
            uint256(12345)    // nonce
        ));

        // Domain separator used on Arbitrum (srcChainId = 42161)
        bytes32 domainOnArbitrum = checker.getDomainSeparatorGMX(42161);
        bytes32 digestOnArbitrum = checker.getDigest(domainOnArbitrum, structHash);

        // If same contract address exists on Avalanche and srcChainId=42161 is enabled:
        // Domain separator would be IDENTICAL (same srcChainId + same address)
        bytes32 domainOnAvalanche = checker.getDomainSeparatorGMX(42161);
        bytes32 digestOnAvalanche = checker.getDigest(domainOnAvalanche, structHash);

        // The digest is THE SAME - signature validates on both chains
        assert(digestOnArbitrum == digestOnAvalanche);
        // ONLY desChainId != block.chainid check prevents execution on wrong chain
    }
}
