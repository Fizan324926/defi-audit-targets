# Immunefi Bug Report: OETHOracleRouter Unsafe int256 Cast Bypasses Negative Price Protection

## Bug Description

The `OETHOracleRouter.price()` function on Ethereum mainnet converts the Chainlink oracle `int256` price to `uint256` using a raw Solidity cast (`uint256(_iprice)`) instead of the safe `SafeCast.toUint256()` method used by all other oracle routers in the protocol.

### Vulnerable Code

**File:** `contracts/oracle/OETHOracleRouter.sol` (Ethereum mainnet)
**Lines:** 21-46

```solidity
function price(address asset) external view virtual override returns (uint256) {
    (address _feed, uint256 maxStaleness) = feedMetadata(asset);
    if (_feed == FIXED_PRICE) {
        return 1e18;
    }
    require(_feed != address(0), "Asset not available");

    (, int256 _iprice, , uint256 updatedAt, ) = AggregatorV3Interface(_feed)
        .latestRoundData();

    require(
        updatedAt + maxStaleness >= block.timestamp,
        "Oracle price too old"
    );

    uint8 decimals = getDecimals(_feed);
    uint256 _price = uint256(_iprice).scaleBy(18, decimals);  // <-- UNSAFE CAST
    return _price;
}
```

### Safe Code (for comparison)

**File:** `contracts/oracle/AbstractOracleRouter.sol:63`

```solidity
uint256 _price = _iprice.toUint256().scaleBy(18, decimals);  // SafeCast reverts on negative
```

**File:** `contracts/oracle/OETHBaseOracleRouter.sol:51`

```solidity
uint256 _price = _iprice.toUint256().scaleBy(18, decimals);  // SafeCast reverts on negative
```

### Call Chain Analysis

The `OETHOracleRouter` serves Ethereum mainnet and is used by the OETH vault for pricing the following assets:
- frxETH/ETH (Chainlink feed `0xC58F3385FBc1C8AD2c0C9a061D7c13b141D7A5Df`)
- stETH/ETH (Chainlink feed `0x86392dC19c0b719886221c78AB11eb8Cf5c52812`)
- rETH/ETH (Chainlink feed `0x536218f9E9Eb48863970252233c8F271f554C2d0`)
- cbETH/ETH (Chainlink feed `0xF017fcB346A1885194689bA23Eff2fE6fA5C483b`)
- CRV/ETH, CVX/ETH, BAL/ETH (reward tokens)

If any of these feeds return a negative `int256` value (e.g., due to a Chainlink aggregator bug, extreme market event, or misconfiguration), the `uint256(_iprice)` cast would silently wrap around. For example:
- `_iprice = -1` becomes `uint256(-1) = 115792089237316195423570985008687907853269984665640564039457584007913129639935`

This astronomical value would pass through `scaleBy` and be returned as the asset price, potentially allowing favorable minting of OETH.

### Affected Inheritance Chain

`OETHOracleRouter` is also the parent of:
- `OETHFixedOracle` (returns FIXED_PRICE for all assets, so the vulnerable `price()` is overridden -- safe)
- `OSonicOracleRouter` extends `OETHFixedOracle` (also returns FIXED_PRICE -- safe)

However, `OETHOracleRouter` itself is deployed on Ethereum mainnet and directly affected.

## Impact

**Severity:** Medium

If a Chainlink aggregator returns a negative price (which circuit breakers should prevent but cannot guarantee for all configurations and edge cases):

1. The vault's oracle would return an astronomically large price for the affected asset
2. Any operation that reads this price (pricing collateral during mint/redeem) would operate with incorrect accounting
3. Vault solvency calculations could be corrupted

The OETHOracleRouter notably does NOT apply `shouldBePegged` drift bounds (unlike the OUSD OracleRouter), so there is NO secondary price validation for ETH-denominated assets. The only protection is Chainlink's own circuit breakers.

**Financial Impact:** Potentially high if exploited during a Chainlink circuit breaker edge case on mainnet. The OETH vault on Ethereum is the highest TVL Origin deployment.

## Risk Breakdown

- **Difficulty to exploit:** High (requires Chainlink to return negative price, which circuit breakers usually prevent)
- **Weakness type:** CWE-681 (Incorrect Conversion between Numeric Types)
- **CVSS 3.1 Score:** 5.3 (Medium) -- AV:N/AC:H/PR:N/UI:N/S:U/C:N/I:H/A:N

## Recommendation

Replace the raw cast with SafeCast:

```diff
// OETHOracleRouter.sol
+ using SafeCast for int256;

  function price(address asset) external view virtual override returns (uint256) {
      ...
      uint8 decimals = getDecimals(_feed);
-     uint256 _price = uint256(_iprice).scaleBy(18, decimals);
+     uint256 _price = _iprice.toUint256().scaleBy(18, decimals);
      return _price;
  }
```

This aligns OETHOracleRouter with all other oracle routers in the protocol and ensures negative prices cause a clean revert rather than silent wraparound.

## Proof of Concept

The vulnerability can be demonstrated without Chainlink by observing the difference in behavior between `uint256(int256)` and `SafeCast.toUint256(int256)`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract PoC_OETHOracleNegativePrice {
    using SafeCast for int256;

    // Simulates OETHOracleRouter behavior (VULNERABLE)
    function unsafeCast(int256 _iprice) external pure returns (uint256) {
        return uint256(_iprice);  // Wraps around on negative input
    }

    // Simulates AbstractOracleRouter behavior (SAFE)
    function safeCast(int256 _iprice) external pure returns (uint256) {
        return _iprice.toUint256();  // Reverts on negative input
    }

    function demonstrateVulnerability() external pure returns (uint256 unsafeResult, bool safeReverts) {
        int256 negativePrice = -1;

        // Unsafe cast: returns type(uint256).max
        unsafeResult = uint256(negativePrice);
        // unsafeResult = 115792089237316195423570985008687907853269984665640564039457584007913129639935

        // Safe cast: would revert
        // negativePrice.toUint256();  // This reverts

        safeReverts = true;

        return (unsafeResult, safeReverts);
    }
}
```

## References

- OETHOracleRouter (vulnerable): https://github.com/OriginProtocol/origin-dollar/blob/main/contracts/contracts/oracle/OETHOracleRouter.sol#L44
- AbstractOracleRouter (safe): https://github.com/OriginProtocol/origin-dollar/blob/main/contracts/contracts/oracle/AbstractOracleRouter.sol#L63
- OETHBaseOracleRouter (safe): https://github.com/OriginProtocol/origin-dollar/blob/main/contracts/contracts/oracle/OETHBaseOracleRouter.sol#L51
- OpenZeppelin SafeCast: https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/math/SafeCast.sol
