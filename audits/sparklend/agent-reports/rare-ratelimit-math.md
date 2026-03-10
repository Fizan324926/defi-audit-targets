# Rate Limit System Deep-Dive: Mathematical Edge Cases and State Machine Analysis

**Target**: `RateLimits.sol`, `RateLimitHelpers.sol`, `MainnetController.sol`, `ForeignController.sol`, and all library files that interact with rate limits.

**Compiler**: Solidity `^0.8.21` (built-in overflow/underflow protection via checked arithmetic)

---

## 1. Rate Limit Recharge Overflow Analysis

### Core Formula (Line 77 of RateLimits.sol)

```solidity
function getCurrentRateLimit(bytes32 key) public override view returns (uint256) {
    RateLimitData memory d = _data[key];

    // Unlimited rate limit case
    if (d.maxAmount == type(uint256).max) {
        return type(uint256).max;
    }

    return _min(
        d.slope * (block.timestamp - d.lastUpdated) + d.lastAmount,
        d.maxAmount
    );
}
```

### Can `slope * (block.timestamp - d.lastUpdated)` overflow uint256?

**Analysis**: With Solidity 0.8.21, multiplication uses checked arithmetic and would revert on overflow rather than wrapping. The question is whether realistic parameters can trigger this.

- `slope` is bounded in fuzz tests to `1e12 * 1e18 = 1e30`.
- Time delta bounded to `1000 * 365 days = 31,536,000,000 seconds ~= 3.15e10`.
- Maximum product: `1e30 * 3.15e10 = 3.15e40`.
- `uint256.max` = `1.15e77`.

So even at extreme bounds, `slope * timeDelta` is nowhere near overflowing uint256. However, the fuzz tests constrain `slope` to `1e12 * 1e18`. There is **no on-chain validation** in `setRateLimitData()` that restricts the magnitude of `slope`. An admin could set `slope = type(uint256).max / 2` and if `timeDelta >= 3`, the multiplication overflows, causing `getCurrentRateLimit()` to **revert permanently**.

**Finding: Admin-induced permanent DoS via overflow in recharge calculation.**

If `slope` is set to a very large value (even accidentally through a governance misconfiguration), `getCurrentRateLimit()` will revert, which means `triggerRateLimitDecrease()` and `triggerRateLimitIncrease()` will also revert, permanently bricking all operations that use that rate limit key until the admin reconfigures it. This is technically an admin trust assumption, but the contract provides no guard rails.

**Severity Assessment**: LOW/INFORMATIONAL. This requires a malicious or incompetent admin. The protocol's trust model already assumes a trusted admin. Not submittable as a bounty-worthy finding.

### Can `slope * timeDelta + d.lastAmount` overflow?

Same analysis -- both `slope * timeDelta` and `d.lastAmount` are individually within uint256 range for realistic params. The addition is also checked, so the worst case is a revert. The `_min()` cap against `maxAmount` provides an upper bound on the meaningful result, but the intermediate calculation can still overflow before `_min()` is applied.

**Verdict**: The overflow is mitigated by Solidity 0.8 checked arithmetic (reverts, doesn't wrap). No exploitable underflow/wrap-around. The revert is a DoS vector, not a fund-theft vector.

---

## 2. Rate Limit Reset on Reconfiguration -- Double-Spend Analysis

### The Key Question

When admin calls `setRateLimitData()` to change limits, does it reset `lastAmount`? Can an attacker time operations around limit changes to effectively double-spend?

### Two Overloads

**3-parameter overload** (line 52-54):
```solidity
function setRateLimitData(bytes32 key, uint256 maxAmount, uint256 slope) external override {
    setRateLimitData(key, maxAmount, slope, maxAmount, block.timestamp);
}
```

This **resets `lastAmount` to `maxAmount`** and **resets `lastUpdated` to now**. So the full new capacity is immediately available.

**5-parameter overload** (line 30-50):
```solidity
function setRateLimitData(
    bytes32 key, uint256 maxAmount, uint256 slope, uint256 lastAmount, uint256 lastUpdated
) public override onlyRole(DEFAULT_ADMIN_ROLE) {
    require(lastAmount  <= maxAmount,       "RateLimits/invalid-lastAmount");
    require(lastUpdated <= block.timestamp, "RateLimits/invalid-lastUpdated");
    _data[key] = RateLimitData({...});
}
```

This allows the admin to set arbitrary `lastAmount` and `lastUpdated` (within validation bounds).

### Attack Scenario

1. Rate limit: `maxAmount=100M, slope=X, lastAmount=1M, lastUpdated=now` (99M consumed).
2. Admin calls `setRateLimitData(key, 200M, newSlope)` (3-param overload).
3. New state: `maxAmount=200M, lastAmount=200M, lastUpdated=now`.
4. The attacker now has **200M** available, not just `200M - 99M = 101M`.

**Analysis**: This is by design. The 3-parameter overload explicitly resets the limit to full. The admin is expected to use the 5-parameter overload if they want to preserve the consumed state. There is no way for a non-admin to exploit this -- it requires the admin to cooperate (either intentionally or through a governance process that doesn't account for current usage).

**Verdict**: Design choice, not a vulnerability. The admin has full control over rate limit state through the 5-parameter overload. If governance proposals use the 3-parameter overload naively, that's a governance process issue, not a smart contract bug.

**However**: There IS a subtle timing issue. If a relayer/attacker can front-run the admin's `setRateLimitData` transaction:

1. Relayer uses remaining 1M capacity.
2. Admin's tx executes, sets `lastAmount=200M`.
3. Relayer immediately uses 200M more.

Total consumed: 201M when the intent was to allow 200M total. But since the admin explicitly set capacity to 200M using the 3-param overload, this is the expected behavior -- the admin intended to grant 200M fresh capacity. If the admin wanted to be careful, they should use the 5-param overload with a calculated `lastAmount`.

**Severity Assessment**: NOT A VULNERABILITY. Design choice with admin trust assumption.

---

## 3. Combined Rate Limits -- Key Collision Analysis

### How Keys Are Computed

**RateLimitHelpers.sol** uses `abi.encode` (NOT `abi.encodePacked`):

```solidity
function makeAddressKey(bytes32 key, address a) internal pure returns (bytes32) {
    return keccak256(abi.encode(key, a));
}

function makeAddressAddressKey(bytes32 key, address a, address b) internal pure returns (bytes32) {
    return keccak256(abi.encode(key, a, b));
}

function makeBytes32Key(bytes32 key, bytes32 a) internal pure returns (bytes32) {
    return keccak256(abi.encode(key, a));
}

function makeUint32Key(bytes32 key, uint32 a) internal pure returns (bytes32) {
    return keccak256(abi.encode(key, a));
}
```

`abi.encode` is collision-resistant because it pads each argument to 32 bytes. Unlike `abi.encodePacked`, there is no ambiguity in decoding. For example, `abi.encode(bytes32, address)` is always 64 bytes (32 + 32), and `abi.encode(bytes32, address, address)` is always 96 bytes (32 + 32 + 32). Different numbers of arguments produce different-length encodings, guaranteeing no collision between functions with different parameter counts.

### Cross-Function Key Collision?

Could `makeAddressKey(LIMIT_A, addr)` accidentally equal `makeUint32Key(LIMIT_B, val)`?

- `makeAddressKey` encodes: `bytes32 || address` (padded to 32 bytes) = 64 bytes input to keccak256.
- `makeUint32Key` encodes: `bytes32 || uint32` (padded to 32 bytes) = 64 bytes input to keccak256.

For these to collide, we'd need `keccak256(abi.encode(LIMIT_A, addr)) == keccak256(abi.encode(LIMIT_B, val))`. Since the keys (LIMIT_A, LIMIT_B) are different keccak256 hashes and the second arguments are in different ranges (addresses are 20 bytes, uint32 is 4 bytes, but both are padded to 32 bytes), a collision would require a keccak256 preimage collision, which is computationally infeasible.

### Special Case: MainnetController.depositToFarm uses inline keccak256

```solidity
function depositToFarm(address farm, uint256 usdsAmount) external nonReentrant {
    _checkRole(RELAYER);
    _rateLimited(
        keccak256(abi.encode(LIMIT_FARM_DEPOSIT, farm)),  // <-- NOT using RateLimitHelpers
        usdsAmount
    );
```

This is functionally equivalent to `RateLimitHelpers.makeAddressKey(LIMIT_FARM_DEPOSIT, farm)` since `abi.encode(bytes32, address)` produces the same encoding. But it's a code consistency issue -- if `RateLimitHelpers` were ever changed (e.g., adding a domain separator), this inline usage would diverge.

### LayerZeroLib uses a different pattern

```solidity
_rateLimited(
    rateLimits,
    keccak256(
        abi.encode(
            LIMIT_LAYERZERO_TRANSFER,
            oftAddress,
            destinationEndpointId
        )
    ),
    amount
);
```

This encodes 3 parameters: `(bytes32, address, uint32)`. This is NOT the same as any RateLimitHelpers function. There is no `makeAddressUint32Key` helper. But since `abi.encode` is used, and the encoding is 96 bytes (32+32+32), it cannot collide with any 64-byte key from the other helpers.

**Verdict**: NO KEY COLLISION POSSIBLE. The use of `abi.encode` (not `abi.encodePacked`) ensures collision resistance. All key derivation patterns produce distinct inputs to keccak256.

---

## 4. Rate Limit Decrease Below Zero

### Code (line 86-106)

```solidity
function triggerRateLimitDecrease(bytes32 key, uint256 amountToDecrease)
    external override onlyRole(CONTROLLER) returns (uint256 newLimit)
{
    RateLimitData storage d = _data[key];
    uint256 maxAmount = d.maxAmount;

    require(maxAmount > 0, "RateLimits/zero-maxAmount");
    if (maxAmount == type(uint256).max) return type(uint256).max;

    uint256 currentRateLimit = getCurrentRateLimit(key);

    require(amountToDecrease <= currentRateLimit, "RateLimits/rate-limit-exceeded");

    d.lastAmount = newLimit = currentRateLimit - amountToDecrease;
    d.lastUpdated = block.timestamp;
}
```

**Analysis**: The `require(amountToDecrease <= currentRateLimit)` on line 100 prevents any underflow. If `amountToDecrease > currentRateLimit`, the transaction reverts with `"RateLimits/rate-limit-exceeded"`. The subtraction on line 102 is therefore guaranteed to be safe.

**Verdict**: SAFE. No underflow possible.

---

## 5. Timestamp Manipulation on L2s

### Analysis

The ForeignController is designed for L2 deployments (Base, Arbitrum, etc.) where `block.timestamp` can be influenced by the sequencer.

Rate limits use `block.timestamp` in two ways:
1. `getCurrentRateLimit()`: `slope * (block.timestamp - d.lastUpdated) + d.lastAmount`
2. `triggerRateLimitDecrease/Increase()`: `d.lastUpdated = block.timestamp`

**Sequencer manipulation vectors**:
- A sequencer could set timestamps that advance faster than real time, causing rate limits to recharge faster than intended.
- A sequencer could set timestamps that advance slower (or stay constant), causing rate limits to not recharge at all.

**Practical assessment**: On the target L2s (Base, Arbitrum, Optimism), sequencers set `block.timestamp` close to real-world time. Ethereum's consensus rules require `block.timestamp` to be non-decreasing and close to real time. L2 sequencers typically follow similar constraints, though they have more latitude.

On Arbitrum specifically, the sequencer can set timestamps up to 24 hours in the future. If a malicious sequencer exploited this:
- Rate limit with `slope = 1M/day` and `maxAmount = 5M`.
- Sequencer pushes timestamp 24h ahead: rate limit gains 1M extra capacity.
- This is a 20% boost per day of manipulation.

**Severity Assessment**: MEDIUM theoretical concern, but the sequencer is a trusted entity in the L2's security model. If the sequencer is compromised, there are far worse attack vectors available. This is an accepted trust assumption for any L2-deployed protocol. Not specific to this rate limit implementation.

**Verdict**: KNOWN L2 TRUST ASSUMPTION. Not a novel finding.

---

## 6. Atomic Multi-Limit Bypass

### Operations that check multiple rate limits sequentially

**`transferUSDCToCCTP` in ForeignController** (lines 263-292):
```solidity
function transferUSDCToCCTP(uint256 usdcAmount, uint32 destinationDomain)
    external nonReentrant onlyRole(RELAYER)
    rateLimited(LIMIT_USDC_TO_CCTP, usdcAmount)           // First rate limit
    rateLimited(                                            // Second rate limit
        RateLimitHelpers.makeUint32Key(LIMIT_USDC_TO_DOMAIN, destinationDomain),
        usdcAmount
    )
{
```

Both modifiers execute before the function body. In Solidity, modifiers execute in order (left to right). Since both call `rateLimits.triggerRateLimitDecrease()` which is an external call to the same `RateLimits` contract, they execute atomically within the same transaction. There is no window between the two checks where external state can change.

**`CCTPLib.transferUSDCToCCTP`** in MainnetController:
```solidity
function transferUSDCToCCTP(TransferUSDCToCCTPParams calldata params) external {
    _rateLimited(params.rateLimits, params.cctpRateLimitId, params.usdcAmount);
    _rateLimited(
        params.rateLimits,
        RateLimitHelpers.makeUint32Key(params.domainRateLimitId, params.destinationDomain),
        params.usdcAmount
    );
```

Both rate limit decreases happen at the start of the function. Since `nonReentrant` is on the caller (MainnetController), and `RateLimits` doesn't have any callback hooks, there's no reentrancy window between the two calls.

**ERC4626 withdraw/redeem**: These call `triggerRateLimitDecrease` then `triggerRateLimitIncrease` on different keys. Since they operate on different keys, there's no state interference.

**CurveLib.addLiquidity**: This decreases two different rate limits (add_liquidity limit and swap limit) with potentially attacker-influenced values (from `curvePool.balances()` and `curvePool.totalSupply()`). But the `nonReentrant` modifier on MainnetController prevents reentrancy from the Curve pool callback, and the rate limit operations happen in sequence without external calls between them (the Curve pool call happens in between, but the rate limit state is consistent because `RateLimits` uses its own independent state).

**Verdict**: NO MULTI-LIMIT BYPASS. All multi-limit operations are protected by `nonReentrant` and execute atomically.

---

## 7. Rate Limit with Zero Slope

### `slope = 0` behavior in `getCurrentRateLimit()`

```solidity
return _min(
    d.slope * (block.timestamp - d.lastUpdated) + d.lastAmount,  // 0 * timeDelta + lastAmount = lastAmount
    d.maxAmount
);
```

With `slope = 0`, the rate limit never recharges. It remains at `lastAmount` forever (or until manually reset by admin). This effectively creates a "one-shot" limit that can only be consumed but never replenished through time.

**Is this useful for an attacker?** No. The attacker cannot set `slope = 0` (only admin can). The admin might intentionally set `slope = 0` to create a finite, non-recharging allowance.

**Edge case**: `setUnlimitedRateLimitData()` sets `slope = 0, maxAmount = type(uint256).max, lastAmount = type(uint256).max`. This is explicitly handled by the `if (d.maxAmount == type(uint256).max) return type(uint256).max` short-circuit.

**Verdict**: SAFE. Zero slope is a valid and expected configuration.

---

## 8. Rate Limit with maxAmount = 0

### `triggerRateLimitDecrease` with `maxAmount = 0`

```solidity
require(maxAmount > 0, "RateLimits/zero-maxAmount");
```

This reverts. Operations requiring this rate limit are blocked.

### `triggerRateLimitIncrease` with `maxAmount = 0`

Same check:
```solidity
require(maxAmount > 0, "RateLimits/zero-maxAmount");
```

Also reverts.

### Can admin set maxAmount = 0 with slope > 0?

```solidity
function setRateLimitData(bytes32 key, uint256 maxAmount, uint256 slope) external override {
    setRateLimitData(key, maxAmount, slope, maxAmount, block.timestamp);
    // lastAmount = 0, lastUpdated = now
}
```

With `maxAmount = 0`, `slope > 0`:
- `getCurrentRateLimit()`: `min(slope * timeDelta + 0, 0) = 0`. The `_min` caps at `maxAmount = 0`.
- But both `triggerRateLimitDecrease` and `triggerRateLimitIncrease` would revert due to the `maxAmount > 0` check.

**Edge case with 5-param overload**: `setRateLimitData(key, 0, 100, 0, now)` -- this passes validation (`0 <= 0` and `now <= now`), but any trigger call reverts.

**Verdict**: SAFE. `maxAmount = 0` effectively freezes operations, which is the intended behavior. Operations using `rateLimitExists` modifier check `maxAmount > 0`.

---

## 9. getCurrentRateLimit vs triggerRateLimitDecrease Discrepancy

### Analysis

Both use the exact same formula:

```solidity
// getCurrentRateLimit (view)
return _min(d.slope * (block.timestamp - d.lastUpdated) + d.lastAmount, d.maxAmount);

// triggerRateLimitDecrease (state-changing)
uint256 currentRateLimit = getCurrentRateLimit(key);  // <-- calls the same function
require(amountToDecrease <= currentRateLimit, "RateLimits/rate-limit-exceeded");
d.lastAmount = newLimit = currentRateLimit - amountToDecrease;
```

`triggerRateLimitDecrease` literally calls `getCurrentRateLimit(key)` to get the current limit, then uses that value for the check and the subtraction. There is no separate calculation path.

**Possible timing discrepancy**: If you call `getCurrentRateLimit()` in block N and then call `triggerRateLimitDecrease()` in block N+1, the result could differ because `block.timestamp` has advanced. But this is by design -- the rate limit recharges over time.

**Within the same block**: `getCurrentRateLimit()` and `triggerRateLimitDecrease()` will use the same `block.timestamp`, so they will agree perfectly.

**Verdict**: NO DISCREPANCY. They use the identical calculation.

---

## 10. Rate Limit Key for Unlimited Operations

### Unlimited sentinel value

```solidity
function setUnlimitedRateLimitData(bytes32 key) external override {
    setRateLimitData(key, type(uint256).max, 0, type(uint256).max, block.timestamp);
}
```

The unlimited check in `getCurrentRateLimit()`:
```solidity
if (d.maxAmount == type(uint256).max) {
    return type(uint256).max;
}
```

And in both trigger functions:
```solidity
if (maxAmount == type(uint256).max) return type(uint256).max;
```

**Can an attacker craft an operation that uses an "unlimited" key?**

The rate limit key is determined by the controller function being called. The attacker (relayer) cannot choose which key is used -- it's hardcoded per function. For example:

```solidity
function mintUSDS(uint256 usdsAmount) external nonReentrant {
    _checkRole(RELAYER);
    _rateLimited(LIMIT_USDS_MINT, usdsAmount);  // Key is fixed
```

The relayer cannot change `LIMIT_USDS_MINT` to some unlimited key. The only way an operation becomes unlimited is if the admin explicitly calls `setUnlimitedRateLimitData()` for that specific operation's key.

**Is there a "magic" key like bytes32(0) that is always unlimited?** No. An uninitialized key (never set) has `maxAmount = 0`, which causes `triggerRateLimitDecrease` to revert with `"RateLimits/zero-maxAmount"`. This is the opposite of unlimited -- it blocks all operations.

**Verdict**: NO UNLIMITED BYPASS. Uninitialized keys block operations, not permit them. Only admin-configured unlimited keys are unlimited.

---

## Additional Findings

### Finding A: triggerRateLimitIncrease Overflow in `currentRateLimit + amountToIncrease`

**Code (line 122)**:
```solidity
d.lastAmount = newLimit = _min(currentRateLimit + amountToIncrease, maxAmount);
```

If `currentRateLimit + amountToIncrease` overflows uint256, this will revert (Solidity 0.8 checked arithmetic).

**When could this happen?** `currentRateLimit` is at most `maxAmount` (capped by `getCurrentRateLimit`). `amountToIncrease` is passed by the controller. For the addition to overflow, we'd need `maxAmount + amountToIncrease > type(uint256).max`, which means `amountToIncrease > type(uint256).max - maxAmount`.

In practice, `amountToIncrease` comes from actual token amounts (e.g., amount withdrawn from Aave, amount redeemed from ERC4626). These are bounded by real token supplies, far below uint256 max.

However, if `maxAmount` is set to `type(uint256).max - 1` (just below the unlimited sentinel), then any `amountToIncrease >= 2` would cause an overflow revert. This is because `getCurrentRateLimit` would return `maxAmount` (the cap), and `maxAmount + 2 = type(uint256).max + 1` overflows.

**Practical impact**: This is an extremely unlikely admin configuration. The only reason to set `maxAmount` near `type(uint256).max` would be to approximate "unlimited", but the proper way is `setUnlimitedRateLimitData()` which uses the exact sentinel value and short-circuits all calculations.

**Severity**: INFORMATIONAL. Unrealistic configuration.

### Finding B: ForeignController.withdrawPSM -- Rate Limit After External Call

```solidity
function withdrawPSM(address asset, uint256 maxAmount)
    external nonReentrant onlyRole(RELAYER) returns (uint256 assetsWithdrawn)
{
    // Perform the external withdrawal FIRST
    assetsWithdrawn = abi.decode(
        proxy.doCall(address(psm), abi.encodeCall(psm.withdraw, (asset, address(proxy), maxAmount))),
        (uint256)
    );

    // Rate limit check AFTER
    rateLimits.triggerRateLimitDecrease(
        RateLimitHelpers.makeAddressKey(LIMIT_PSM_WITHDRAW, asset),
        assetsWithdrawn
    );
}
```

The rate limit is checked AFTER the external call. This is intentional (commented as "Rate limited at end of function") because the actual withdrawn amount may differ from `maxAmount`. The `nonReentrant` modifier prevents reentrancy exploitation. If the rate limit is exceeded, the entire transaction reverts, rolling back the withdrawal.

**Is this pattern safe?** Yes, because of `nonReentrant` and because the revert rolls back all state changes including the external call. No funds are permanently moved if the rate limit check fails.

### Finding C: Inconsistent Key Derivation Patterns Across MainnetController

MainnetController uses two different patterns for key derivation:

1. **Via RateLimitHelpers** (most functions):
   ```solidity
   _rateLimitedAddress(LIMIT_OTC_SWAP, exchange, sent18);
   // Equivalent to: RateLimitHelpers.makeAddressKey(LIMIT_OTC_SWAP, exchange)
   ```

2. **Inline keccak256** (depositToFarm, withdrawFromFarm):
   ```solidity
   _rateLimited(keccak256(abi.encode(LIMIT_FARM_DEPOSIT, farm)), usdsAmount);
   ```

Both are functionally equivalent (same `abi.encode` encoding). But if `RateLimitHelpers` were ever upgraded to include a domain separator or salt, the inline pattern would diverge.

**Severity**: INFORMATIONAL / code quality issue. No current exploit.

### Finding D: Mutable Rate Limit Keys in MainnetController vs Immutable in ForeignController

**MainnetController** declares rate limit key constants as `public` (not `constant` or `immutable`):
```solidity
bytes32 public FREEZER = keccak256("FREEZER");
bytes32 public RELAYER = keccak256("RELAYER");
bytes32 public LIMIT_4626_DEPOSIT = keccak256("LIMIT_4626_DEPOSIT");
// ... etc
```

These are **mutable storage variables**, not constants. They occupy storage slots and cost more gas to read. However, they cannot be changed by any function in the contract (there are no setters). The Solidity compiler would warn about this but it's not a vulnerability.

**ForeignController** declares them as `constant`:
```solidity
bytes32 public constant FREEZER = keccak256("FREEZER");
bytes32 public constant LIMIT_4626_DEPOSIT = keccak256("LIMIT_4626_DEPOSIT");
```

**Impact**: In MainnetController, since these are storage variables (not constants), they use SLOAD which costs 2100 gas (cold) or 100 gas (warm). As constants, they would be inlined at compile time for near-zero cost. This is a gas optimization issue, not a security issue.

However, there is a subtle concern: if MainnetController is used as a base contract and a derived contract accidentally shadows these variables, the derived contract could operate with wrong rate limit keys, effectively bypassing intended rate limits. This is purely theoretical since no inheritance is currently in play.

**Severity**: INFORMATIONAL / gas optimization.

---

## Summary Table

| # | Edge Case | Exploitable? | Severity | Notes |
|---|-----------|-------------|----------|-------|
| 1 | Recharge overflow | No | Info | Solidity 0.8 reverts; DoS only with malicious admin |
| 2 | Double-spend on reconfig | No | Design | Admin controls all params; 5-param overload available |
| 3 | Key collision | No | Safe | `abi.encode` prevents collisions |
| 4 | Decrease below zero | No | Safe | `require(amountToDecrease <= currentRateLimit)` |
| 5 | L2 timestamp manipulation | Theoretical | Known | L2 sequencer trust assumption |
| 6 | Atomic multi-limit bypass | No | Safe | `nonReentrant` + atomic execution |
| 7 | Zero slope | No | Safe | Valid "one-shot" config; works correctly |
| 8 | Zero maxAmount | No | Safe | Blocks operations as intended |
| 9 | View vs trigger discrepancy | No | Safe | Identical calculation |
| 10 | Unlimited key bypass | No | Safe | Uninitialized keys = blocked, not unlimited |
| A | Increase overflow | Theoretical | Info | Requires near-max `maxAmount` config |
| B | Rate limit after call | No | Safe | `nonReentrant` + revert atomicity |
| C | Inconsistent key derivation | No | Info | Code quality; functionally equivalent |
| D | Mutable vs constant keys | No | Info | Gas cost; no security impact |

---

## Conclusion

The RateLimits system is **well-designed and robust** against the investigated attack vectors. Key strengths:

1. **Solidity 0.8 checked arithmetic** eliminates all wrap-around overflow/underflow attacks.
2. **`abi.encode` (not `abi.encodePacked`)** in key derivation eliminates hash collision risks.
3. **Explicit unlimited sentinel** (`type(uint256).max`) with short-circuit returns avoids overflow in unlimited paths.
4. **Uninitialized keys default to blocked** (maxAmount=0 reverts), not unlimited.
5. **`nonReentrant` protection** on all controller functions prevents multi-limit manipulation.
6. **Consistent rate limit check in both view and state-changing paths** prevents discrepancies.

**No bounty-worthy vulnerabilities found in the rate limit system.** All identified edge cases are either handled correctly by design, mitigated by Solidity 0.8 safety features, or fall under accepted trust assumptions (admin trust, L2 sequencer trust).

The most interesting theoretical vector (Finding A: near-max `maxAmount` causing overflow in `triggerRateLimitIncrease`) requires an absurd admin configuration that no rational governance would deploy, and even then it results in a revert (DoS), not fund theft.
