# Deep-Dive Analysis: OTC Claim Unbounded Accumulation

## Finding Under Review

**Claim:** "OTC claim has no upper bound -- relayer can sweep any tokens in the buffer."

The hypothesis is that `otcClaim` in `MainnetController.sol` allows the RELAYER to accumulate `claimed18` without checking it against `sent18`, potentially draining any tokens in the OTCBuffer regardless of the original OTC send amount.

---

## 1. Detailed Code Trace

### 1a. `otcSend` (Lines 1094-1123 of MainnetController.sol)

```solidity
function otcSend(address exchange, address assetToSend, uint256 amount) external nonReentrant {
    _checkRole(RELAYER);

    require(assetToSend != address(0), "MC/asset-to-send-zero");
    require(amount > 0,                "MC/amount-to-send-zero");

    require(
        otcWhitelistedAssets[exchange][assetToSend],
        "MC/asset-not-whitelisted"
    );

    uint256 sent18 = amount * 1e18 / 10 ** IERC20Metadata(assetToSend).decimals();

    _rateLimitedAddress(LIMIT_OTC_SWAP, exchange, sent18);   // <-- RATE LIMITED

    OTC storage otc = otcs[exchange];

    require(isOtcSwapReady(exchange), "MC/last-swap-not-returned");  // <-- BLOCKS if previous swap not settled

    otc.sent18        = sent18;
    otc.sentTimestamp = block.timestamp;
    otc.claimed18     = 0;                                   // <-- RESETS claimed to 0

    _transfer(assetToSend, exchange, amount);                // <-- proxy.doCall(token.transfer(exchange, amount))
}
```

**Controls on otcSend:**
1. RELAYER role check
2. Asset must be whitelisted for this exchange
3. Rate limit on `LIMIT_OTC_SWAP` keyed by exchange address -- this is a **decreasing** rate limit (consumes capacity)
4. `isOtcSwapReady(exchange)` must return true -- blocks sending more if previous swap has not been returned
5. Resets `claimed18 = 0` for this exchange

### 1b. `otcClaim` (Lines 1125-1151 of MainnetController.sol)

```solidity
function otcClaim(address exchange, address assetToClaim) external nonReentrant {
    _checkRole(RELAYER);

    address otcBuffer = otcs[exchange].buffer;

    require(assetToClaim != address(0), "MC/asset-to-claim-zero");
    require(otcBuffer    != address(0), "MC/otc-buffer-not-set");

    require(
        otcWhitelistedAssets[exchange][assetToClaim],
        "MC/asset-not-whitelisted"
    );

    uint256 amountToClaim = IERC20(assetToClaim).balanceOf(otcBuffer);  // <-- ENTIRE buffer balance

    uint256 amountToClaim18
        = amountToClaim * 1e18 / 10 ** IERC20Metadata(assetToClaim).decimals();

    otcs[exchange].claimed18 += amountToClaim18;     // <-- ACCUMULATES, no upper bound check

    _transferFrom(assetToClaim, otcBuffer, address(proxy), amountToClaim);
}
```

**Controls on otcClaim:**
1. RELAYER role check
2. Asset must be whitelisted for this exchange
3. Buffer must be set
4. **NO rate limit check**
5. **NO check that `claimed18 <= sent18`**
6. Claims the ENTIRE balance of the buffer for that token

### 1c. `isOtcSwapReady` (Lines 1161-1167)

```solidity
function isOtcSwapReady(address exchange) public view returns (bool) {
    if (maxSlippages[exchange] == 0) return false;

    return getOtcClaimWithRecharge(exchange)
        >= otcs[exchange].sent18 * maxSlippages[exchange] / 1e18;
}
```

### 1d. `getOtcClaimWithRecharge` (Lines 1153-1159)

```solidity
function getOtcClaimWithRecharge(address exchange) public view returns (uint256) {
    OTC memory otc = otcs[exchange];
    if (otc.sentTimestamp == 0) return 0;
    return otc.claimed18 + (block.timestamp - otc.sentTimestamp) * otc.rechargeRate18;
}
```

### 1e. OTCBuffer Contract (OTCBuffer.sol)

The OTCBuffer is a minimal upgradeable contract:
- Has an `approve()` function (DEFAULT_ADMIN_ROLE only) to set allowances to the ALMProxy
- Stores the ALMProxy address
- **Has no logic to restrict what gets pulled** -- it is a passive container
- Relies on infinite allowance to ALMProxy (`type(uint256).max`)

---

## 2. Verification Answers

### 2a. Trace the exact flow: otcSend -> OTCBuffer -> otcClaim. What rate limits apply to each?

**otcSend flow:**
1. Relayer calls `otcSend(exchange, assetToSend, amount)`
2. Rate limit `LIMIT_OTC_SWAP` keyed by exchange is **decreased** by `sent18`
3. Requires `isOtcSwapReady(exchange)` to be true (previous swap settled)
4. Records `sent18`, `sentTimestamp`, resets `claimed18 = 0`
5. Transfers tokens from ALMProxy to the exchange address

**External step (off-chain):**
- The exchange/OTC desk sends the return tokens to the OTCBuffer address

**otcClaim flow:**
1. Relayer calls `otcClaim(exchange, assetToClaim)`
2. **NO rate limit is checked or consumed**
3. Reads the entire balance of `assetToClaim` in the OTCBuffer
4. Accumulates `claimed18 += amountToClaim18`
5. Transfers from OTCBuffer to ALMProxy

**Rate limits:**
- **otcSend**: YES -- `LIMIT_OTC_SWAP` keyed by exchange
- **otcClaim**: **NO** -- no rate limit whatsoever

### 2b. Can the relayer call otcClaim multiple times to drain more than what was sent via otcSend?

**Technically yes, but only if the OTCBuffer contains tokens.** The relayer can call `otcClaim` as many times as there are tokens in the buffer. The `claimed18` accumulator has no ceiling -- it simply adds up. However, the critical question is: **how do tokens get into the OTCBuffer in the first place?**

Tokens enter the OTCBuffer ONLY via:
1. The **external exchange** sending return tokens to the buffer address after receiving the otcSend
2. Someone **externally depositing** tokens to the buffer (donation/accident)

The relayer **cannot** independently put tokens into the OTCBuffer through the controller. The relayer can only:
- `otcSend`: sends FROM ALMProxy TO the exchange (not to the buffer)
- `otcClaim`: pulls FROM OTCBuffer TO ALMProxy

So `otcClaim` can only move tokens that are **already** in the buffer **back** to the ALMProxy. This is **not draining** in the adversarial sense -- it is moving assets from one protocol-owned address to another protocol-owned address (OTCBuffer -> ALMProxy). Both are within the system.

### 2c. Is there a rate limit on otcClaim separate from otcSend?

**No.** There is no rate limit on `otcClaim`. This is by design. The `otcClaim` function only moves tokens from the OTCBuffer (a protocol-owned contract) to the ALMProxy (another protocol-owned contract). It does not move value outside the system.

### 2d. What tokens are in the OTCBuffer and how much value could be at risk?

The OTCBuffer only contains tokens that the OTC exchange has deposited as the return side of a swap. In normal operation:
- Relayer sends 10M USDT to exchange via `otcSend`
- Exchange sends ~10M USDS back to the OTCBuffer
- Relayer calls `otcClaim` to pull USDS from buffer to ALMProxy

The buffer is a **transit point** -- tokens should not accumulate there for extended periods. The maximum value at risk in the buffer at any given time is approximately equal to one outstanding OTC swap's return value.

### 2e. Is the relayer a trusted role?

**No, the relayer is explicitly UNTRUSTED.** From THREAT_MODEL.md:

> | **Relayer** (`RELAYER`) | **Untrusted** | Assumed to be potentially compromised at any time |

From SECURITY.md:

> | `RELAYER` | **Assumed compromisable** | Logic must prevent unauthorized value movement. |

The system is designed to defend against a **fully compromised relayer**. This is the primary threat model.

**However**, the Immunefi program scope states it excludes "attacks requiring access to privileged addresses without additional modifications to the privileges attributed." The RELAYER is a privileged address (granted via `AccessControlEnumerable`). The question is whether the relayer role's existing privileges already encompass the behavior described in this finding, or whether this represents an unintended expansion of those privileges.

Given that the protocol **explicitly designs around compromised relayers** and considers relayer compromise an expected threat, the system's defenses against it (rate limits, maxSlippage, freezer) are the intended security boundary. The relayer is a **privileged but untrusted** role -- meaning attacks using relayer access are **in scope** for the protocol's threat model, and should be caught by the protocol's own defenses.

### 2f. Could a compromised relayer drain the OTCBuffer? What is the maximum damage?

**Analysis of the attack scenario:**

A compromised relayer could:
1. Call `otcClaim(exchange, assetToClaim)` at any time there are tokens in the OTCBuffer

But the tokens would go **to the ALMProxy** (the protocol's main vault), not to an attacker-controlled address. The relayer cannot redirect where the tokens go -- the destination is hardcoded as `address(proxy)`.

**Can the relayer extract value from the ALMProxy?** The relayer has many functions available, but ALL of them are rate-limited and/or constrained to move value only within the system:
- `otcSend`: rate limited, sends to whitelisted exchange
- `transferAsset`: rate limited, sends to whitelisted addresses
- All other operations (Aave, Curve, ERC4626, etc.): rate limited, move to protocol-approved destinations

**Maximum damage from OTC specifically:**
- The rate limit on `LIMIT_OTC_SWAP` per exchange bounds how much can be sent out via `otcSend`
- The `maxSlippage` parameter bounds the minimum return required
- If maxSlippage is 0.9995 (99.95%), then on a 10M swap, the loss is bounded to ~5,000 (0.05%)
- The freezer can remove a compromised relayer within the rate limit window

**The `claimed18` accumulator having no upper bound is intentional** -- it is an accounting variable used only for the `isOtcSwapReady` check. Over-claiming (more tokens in buffer than expected) is a good thing from the protocol's perspective -- it means the exchange returned more than expected. The value flows back to the ALMProxy regardless.

---

## 3. Other Paths for Value Extraction Beyond Rate Limits

Checked all relayer-callable functions for paths where value could leave the system:

| Function | Rate Limited? | Destination Constrained? | Risk |
|----------|--------------|--------------------------|------|
| `otcSend` | Yes (`LIMIT_OTC_SWAP`) | Whitelisted exchange only | Bounded by rate limit |
| `otcClaim` | No | ALMProxy only (hardcoded) | No risk -- value stays in system |
| `transferAsset` | Yes (`LIMIT_ASSET_TRANSFER`) | Whitelisted addresses | Bounded by rate limit |
| `swapUSDSToUSDC` | Yes | Within system (PSM) | Bounded |
| Curve/Uniswap/Aave/ERC4626 | Yes (various limits) | Within system | Bounded by limits + slippage |
| `setEthenaDelegateSigner` | No rate limit | Sets delegated signer | Ethena trusted to reject bad orders |

The `otcClaim` path does not allow value to leave the system. The tokens can only go from OTCBuffer -> ALMProxy. This is intra-system movement.

---

## 4. Verdict

### NOT A VALID VULNERABILITY -- Out of Scope / By Design

**Reasoning:**

1. **No value extraction:** `otcClaim` moves tokens from OTCBuffer to ALMProxy. Both are protocol-owned contracts. The relayer cannot redirect these tokens to an attacker-controlled address via `otcClaim`. The destination is hardcoded as `address(proxy)`.

2. **The lack of a `claimed18 <= sent18` check is intentional:** The `claimed18` accumulator serves only to determine when `isOtcSwapReady` returns true (allowing the next `otcSend`). Over-claiming is benign -- it just means the exchange returned more than expected, and the protocol benefits.

3. **The OTCBuffer is a transit contract:** It only holds tokens deposited by external exchanges. The relayer cannot independently fill it. `otcClaim` merely completes the inbound leg of a swap by pulling those tokens into the ALMProxy.

4. **Rate limits protect the outbound leg:** `otcSend` (which sends value OUT of the ALMProxy to an exchange) is rate-limited. This is the critical security boundary. The inbound leg (`otcClaim`) does not need rate limiting because it only moves value INTO the ALMProxy.

5. **Trusted role exclusion applies:** Even if this were considered an issue, the RELAYER is a privileged role. The Immunefi program excludes "attacks requiring access to privileged addresses without additional modifications to the privileges attributed." The `otcClaim` behavior is entirely within the RELAYER's attributed privileges -- the function is designed to be called by the relayer.

6. **The protocol explicitly designs for compromised relayers:** The threat model documents that the maximum loss from a compromised relayer is bounded by rate limits on outbound operations, and the FREEZER can halt attacks. The `otcClaim` function does not expand the relayer's ability to extract value beyond what rate limits already permit.

7. **Test suite confirms intended behavior:** The test `test_otcClaim_usdt` (line 525) explicitly tests claiming 10M from the buffer when `sent18 = 0` and `sentTimestamp = 0`, confirming this is expected behavior. The test passes and is not treated as an error.

### Classification

| Category | Assessment |
|----------|-----------|
| Severity | None (not a vulnerability) |
| Type | Design choice -- by design, `otcClaim` is a unidirectional inbound operation with no rate limit needed |
| Immunefi Impact | Does not meet threshold -- no value leaves the system |
| Recommendation | Do not submit. This would be rejected as "by design" or "trusted role" exclusion |

### Summary

The `otcClaim` function's lack of an upper bound on `claimed18` and absence of rate limiting is **intentional and safe**. The function can only move tokens from the protocol-owned OTCBuffer to the protocol-owned ALMProxy. The relayer cannot redirect funds, cannot fill the buffer independently, and cannot use `otcClaim` to extract value from the system. The security boundary is on `otcSend` (outbound), not `otcClaim` (inbound). This is a well-designed asymmetric trust model: rate-limit what goes out, freely accept what comes in.
