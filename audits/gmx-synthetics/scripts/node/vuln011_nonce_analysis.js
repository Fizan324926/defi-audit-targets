#!/usr/bin/env node
/**
 * VULN-011: Missing On-Chain Relay UserNonce Sequential Validation
 *
 * Demonstrates that userNonce is NOT validated on-chain as sequential,
 * allowing transaction reordering by keepers.
 *
 * Usage: node vuln011_nonce_analysis.js
 */

class DigestStore {
    constructor() {
        this.usedDigests = new Set();
    }

    validateDigest(digest) {
        if (this.usedDigests.has(digest)) {
            throw new Error(`Digest already used: ${digest}`);
        }
        this.usedDigests.add(digest);
        return true;
    }
}

class RelaySimulator {
    constructor() {
        this.digestStore = new DigestStore();
        this.executedOrders = [];
        this.expectedNonces = {}; // What sequential validation WOULD track
    }

    /**
     * Simulates the current GMX relay validation.
     * From BaseGelatoRelayRouter._validateCall:
     *   1. Compute domain separator from srcChainId
     *   2. Compute digest from struct hash
     *   3. Check digest not used (digestUsed mapping)
     *   4. Validate signature
     *   NO sequential nonce check
     */
    executeRelayOrder(account, userNonce, orderType, params) {
        // The struct hash includes userNonce, making each digest unique
        const structHash = `${account}:${userNonce}:${orderType}:${JSON.stringify(params)}`;
        const digest = `digest_${structHash}`;

        try {
            this.digestStore.validateDigest(digest);
        } catch (e) {
            return { success: false, error: e.message };
        }

        // Order executes
        this.executedOrders.push({
            account,
            userNonce,
            orderType,
            params,
            executionIndex: this.executedOrders.length,
        });

        return { success: true, orderType, nonce: userNonce };
    }

    /**
     * What GMX SHOULD do: validate sequential nonces
     */
    executeRelayOrderWithNonceCheck(account, userNonce, orderType, params) {
        // Initialize expected nonce for new accounts
        if (!(account in this.expectedNonces)) {
            this.expectedNonces[account] = 0;
        }

        // Sequential nonce validation
        if (userNonce !== this.expectedNonces[account]) {
            return {
                success: false,
                error: `Expected nonce ${this.expectedNonces[account]}, got ${userNonce}`,
            };
        }

        const result = this.executeRelayOrder(account, userNonce, orderType, params);
        if (result.success) {
            this.expectedNonces[account]++;
        }
        return result;
    }
}

function demonstrateReorderingAttack() {
    console.log("=".repeat(70));
    console.log("VULN-011: Relay Nonce Reordering Attack");
    console.log("=".repeat(70));

    // User's intended order sequence
    const userOrders = [
        { nonce: 0, type: "CreateOrder", params: { action: "open_long_ETH", size: 100000 } },
        { nonce: 1, type: "CreateOrder", params: { action: "set_stop_loss", triggerPrice: 1800 } },
        { nonce: 2, type: "CreateOrder", params: { action: "set_take_profit", triggerPrice: 2500 } },
    ];

    console.log("\n--- User's Intended Order ---");
    for (const order of userOrders) {
        console.log(`  Nonce ${order.nonce}: ${order.type} - ${order.params.action}`);
    }

    // Scenario 1: Keeper executes in correct order
    console.log("\n--- Scenario 1: Correct Order Execution ---");
    const sim1 = new RelaySimulator();
    for (const order of userOrders) {
        const result = sim1.executeRelayOrder("alice", order.nonce, order.type, order.params);
        console.log(`  Nonce ${order.nonce}: ${result.success ? "OK" : "FAILED"} - ${order.params.action}`);
    }
    console.log(`  Execution order: ${sim1.executedOrders.map(o => o.userNonce).join(" → ")}`);

    // Scenario 2: Malicious keeper reorders
    console.log("\n--- Scenario 2: Keeper Reorders (Cherry-Picks) ---");
    const sim2 = new RelaySimulator();
    const reorderedSequence = [
        userOrders[2], // Take-profit first (nonce 2)
        userOrders[0], // Then open position (nonce 0)
        // Skip nonce 1 (stop-loss) - keeper doesn't execute it
    ];

    for (const order of reorderedSequence) {
        const result = sim2.executeRelayOrder("alice", order.nonce, order.type, order.params);
        console.log(`  Nonce ${order.nonce}: ${result.success ? "OK" : "FAILED"} - ${order.params.action}`);
    }
    console.log(`  Execution order: ${sim2.executedOrders.map(o => o.userNonce).join(" → ")}`);
    console.log(`  MISSING: Stop-loss at $1,800 was NEVER executed!`);
    console.log(`  Risk: Position has take-profit but NO downside protection`);

    // Scenario 3: With sequential nonce validation (SAFE)
    console.log("\n--- Scenario 3: With Sequential Nonce Validation (Fixed) ---");
    const sim3 = new RelaySimulator();
    for (const order of reorderedSequence) {
        const result = sim3.executeRelayOrderWithNonceCheck("alice", order.nonce, order.type, order.params);
        console.log(`  Nonce ${order.nonce}: ${result.success ? "OK" : `BLOCKED: ${result.error}`}`);
    }
    console.log(`  Sequential validation prevents out-of-order execution ✓`);
}

function demonstrateSelectiveExecution() {
    console.log("\n" + "=".repeat(70));
    console.log("Selective Execution Attack");
    console.log("=".repeat(70));

    const sim = new RelaySimulator();

    // Trading bot signs a batch of related operations
    const botOrders = [
        { nonce: 100, type: "UpdateOrder", params: { action: "increase_collateral", amount: 50000 } },
        { nonce: 101, type: "CreateOrder", params: { action: "open_short_BTC", size: 500000 } },
        { nonce: 102, type: "UpdateOrder", params: { action: "set_stop_loss", triggerPrice: 45000 } },
        { nonce: 103, type: "CreateOrder", params: { action: "open_hedge_ETH", size: 200000 } },
    ];

    console.log("\n  Bot's intended sequence:");
    for (const order of botOrders) {
        console.log(`    ${order.nonce}: ${order.params.action}`);
    }

    // Keeper only executes the profitable-to-execute ones
    console.log("\n  Keeper cherry-picks (skips collateral increase and hedge):");
    const cherryPicked = [botOrders[1], botOrders[2]]; // Only short + stop-loss

    for (const order of cherryPicked) {
        const result = sim.executeRelayOrder("bot", order.nonce, order.type, order.params);
        console.log(`    ${order.nonce}: ${result.success ? "EXECUTED" : "FAILED"} - ${order.params.action}`);
    }

    console.log("\n  Result:");
    console.log("    - Short BTC position opened WITHOUT extra collateral");
    console.log("    - Hedge position NOT opened");
    console.log("    - Bot's risk management strategy is broken");
    console.log("    - All orders had valid signatures and pass digest check");
}

function analyzeCodeEvidence() {
    console.log("\n" + "=".repeat(70));
    console.log("Code Evidence");
    console.log("=".repeat(70));

    console.log(`
  From IRelayUtils.sol:65-81 (RelayParams struct):
    struct RelayParams {
        ...
        uint256 userNonce;     // "interface generates a random nonce"
        uint256 deadline;
        bytes signature;
        uint256 desChainId;
    }

  Key finding: userNonce is described as "random" not "sequential"
  This confirms it's NOT used as an incrementing counter.

  From RelayUtils.sol:282-295 (_getRelayParamsHash):
    The userNonce IS included in the hash (ensures unique digests)
    But it is NOT validated against any on-chain counter.

  From BaseGelatoRelayRouter.sol:411-416 (_validateDigest):
    function _validateDigest(bytes32 digest) internal {
        if (digests[digest]) revert InvalidUserDigest();
        digests[digest] = true;
    }

  This ONLY prevents EXACT replay of the same digest.
  Different nonces = different digests = all pass independently.
    `);
}

// Main
demonstrateReorderingAttack();
demonstrateSelectiveExecution();
analyzeCodeEvidence();

console.log("\n" + "=".repeat(70));
console.log("VERDICT:");
console.log("  userNonce is random, not sequential - no ordering guarantee");
console.log("  Keepers can reorder or skip operations freely");
console.log("  Users' multi-step trading strategies can be disrupted");
console.log("  Severity: CRITICAL for users relying on operation ordering");
console.log("=".repeat(70));
