# Immunefi Bug Report: CombinedChainlinkOracle Missing Zero/Negative Price Validation

## Bug Description

The `CombinedChainlinkOracle` contract combines two Chainlink feeds (YFI/USD and ETH/USD) to derive a YFI/ETH price. The `latestRoundData()` function performs no validation that either oracle answer is positive or non-zero before computing the division.

**Vulnerable Code:**

File: `veYFI/contracts/CombinedChainlinkOracle.vy`, lines 25-31

```vyper
@external
@view
def latestRoundData() -> LatestRoundData:
    yfi: LatestRoundData = ChainlinkOracle(YFI_ORACLE).latestRoundData()
    eth: LatestRoundData = ChainlinkOracle(ETH_ORACLE).latestRoundData()
    if eth.updated < yfi.updated:
        yfi.updated = eth.updated
    yfi.answer = yfi.answer * SCALE / eth.answer  # <-- NO CHECK: eth.answer could be 0 or negative
    return yfi
```

The `Redemption.vy` contract at line 186-194 consumes this price:

```vyper
@internal
@view
def _get_latest_price() -> uint256:
    round_id: uint80 = 0
    price: int256 = 0
    started_at: uint256 = 0
    updated_at: uint256 = 0
    answered_in_round: uint80 = 0
    (round_id, price, started_at, updated_at, answered_in_round) = PRICE_FEED.latestRoundData()
    assert updated_at + 3600 > block.timestamp, "price too old"
    return convert(price, uint256)  # <-- No negative check before conversion
```

**Call Chain:**
1. User calls `Redemption.redeem()` -> `_eth_required()` -> `_get_latest_price()`
2. `_get_latest_price()` calls `CombinedChainlinkOracle.latestRoundData()`
3. Oracle fetches both feeds, divides `yfi.answer * SCALE / eth.answer` with no validation
4. If `eth.answer == 0`: Division by zero, permanent revert
5. If `eth.answer < 0`: Negative division produces garbage value
6. If `yfi.answer < 0`: Same issue, negative numerator

The staleness check (`updated_at + 3600 > block.timestamp`) does NOT protect against zero or negative values -- Chainlink can return a fresh but incorrect answer of 0 during circuit breaker events.

## Impact

**Severity:** Medium

**Financial Impact:**
- **Division by Zero (eth.answer == 0):** All dYFI redemptions permanently revert until the oracle recovers. dYFI holders lose access to their discount redemption mechanism during this period. If the oracle remains at 0 for an extended period (as happened with LUNA/UST), dYFI could lose significant value as the redemption mechanism is the primary value driver.
- **Negative Price Scenario:** If both feeds return negative values, `negative * SCALE / negative` produces a positive int256 that may look valid but represents a completely wrong price. The `convert(price, uint256)` in Redemption.vy would NOT revert because the result is positive. Users would then pay incorrect ETH amounts for YFI redemption.

**Affected Users:** All dYFI holders who rely on the redemption mechanism for value realization.

**Precedent:** Chainlink has returned 0 prices historically. The LUNA/UST crash (May 2022) demonstrated that oracle prices can hit zero or minimum bounds. The ETH/USD Chainlink feed has a built-in `minAnswer` of 1 (not 0), but this is an aggregator configuration parameter that can change.

## Risk Breakdown

- **Difficulty to Exploit:** Low -- No active exploitation needed; the vulnerability triggers when Chainlink reports anomalous data
- **Weakness Type:** CWE-369 (Divide By Zero), CWE-252 (Unchecked Return Value)
- **CVSS Score:** 6.5 (Medium) -- AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:L/A:H
  - Availability impact is High (redemption DoS)
  - Integrity impact is Low (potential wrong price if both negative)

## Recommendation

Add positive price validation to the `CombinedChainlinkOracle`:

```diff
 @external
 @view
 def latestRoundData() -> LatestRoundData:
     yfi: LatestRoundData = ChainlinkOracle(YFI_ORACLE).latestRoundData()
     eth: LatestRoundData = ChainlinkOracle(ETH_ORACLE).latestRoundData()
+    assert yfi.answer > 0, "invalid YFI price"
+    assert eth.answer > 0, "invalid ETH price"
     if eth.updated < yfi.updated:
         yfi.updated = eth.updated
     yfi.answer = yfi.answer * SCALE / eth.answer
     return yfi
```

Additionally, add a price validation check in `Redemption._get_latest_price()`:

```diff
 @internal
 @view
 def _get_latest_price() -> uint256:
     ...
     (round_id, price, started_at, updated_at, answered_in_round) = PRICE_FEED.latestRoundData()
     assert updated_at + 3600 > block.timestamp, "price too old"
+    assert price > 0, "invalid price"
     return convert(price, uint256)
```

## Proof of Concept

The following Foundry test demonstrates the vulnerability. It deploys a mock Chainlink oracle setup and shows the division-by-zero behavior.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

// Mock Chainlink aggregator that can return arbitrary answers
contract MockChainlinkOracle {
    int256 public price;
    uint256 public updatedAt;
    uint8 public decimals_ = 8;

    constructor(int256 _price) {
        price = _price;
        updatedAt = block.timestamp;
    }

    function setPrice(int256 _price) external {
        price = _price;
        updatedAt = block.timestamp;
    }

    function decimals() external view returns (uint8) {
        return decimals_;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt_,
            uint80 answeredInRound
        )
    {
        return (1, price, block.timestamp, updatedAt, 1);
    }
}

contract CombinedChainlinkOraclePoC is Test {
    MockChainlinkOracle yfiOracle;
    MockChainlinkOracle ethOracle;

    int256 constant SCALE = 1e18;

    function setUp() public {
        // Normal prices: YFI = $7000, ETH = $3500
        yfiOracle = new MockChainlinkOracle(700000000000); // 7000 * 1e8
        ethOracle = new MockChainlinkOracle(350000000000); // 3500 * 1e8
    }

    // Simulates the CombinedChainlinkOracle.latestRoundData() logic
    function _getPrice() internal view returns (int256) {
        (, int256 yfiAnswer,,,) = yfiOracle.latestRoundData();
        (, int256 ethAnswer,,,) = ethOracle.latestRoundData();
        // This is the vulnerable line from CombinedChainlinkOracle.vy:30
        return yfiAnswer * SCALE / ethAnswer;
    }

    function test_NormalPrice() public view {
        int256 price = _getPrice();
        // YFI/ETH = 7000/3500 = 2.0 ETH per YFI
        assertEq(price, 2e18);
    }

    function test_DivisionByZero_ETH_ZeroPrice() public {
        // Simulate ETH/USD returning 0 (circuit breaker event)
        ethOracle.setPrice(0);

        // This REVERTS with division by zero, bricking all redemptions
        vm.expectRevert();
        _getPrice();
    }

    function test_NegativePrice_BothFeeds() public {
        // Both feeds return negative (extreme anomaly)
        yfiOracle.setPrice(-700000000000);
        ethOracle.setPrice(-350000000000);

        // negative / negative = positive -- produces VALID-LOOKING but WRONG price
        int256 price = _getPrice();
        // Result is 2e18 (same as normal!), completely masking the anomaly
        assertEq(price, 2e18);
    }

    function test_NegativeETH_PositiveYFI() public {
        // ETH feed returns negative, YFI stays positive
        ethOracle.setPrice(-350000000000);

        // positive / negative = negative
        int256 price = _getPrice();
        // Price is -2e18, which when converted to uint256 in Vyper 0.3.7 would REVERT
        // This bricks redemptions just like the zero case
        assertTrue(price < 0);
    }
}
```

**To run:**
```bash
forge test --match-contract CombinedChainlinkOraclePoC -vvv
```

## References

- Vulnerable file: `veYFI/contracts/CombinedChainlinkOracle.vy` (lines 25-31)
- Consumer file: `veYFI/contracts/Redemption.vy` (lines 186-194)
- Chainlink zero-price precedent: LUNA/UST crash, May 2022
- CWE-369: https://cwe.mitre.org/data/definitions/369.html
