# Immunefi Bug Report: ConvertibleDepositAuctioneer Tick Price Decay Can Be Exploited via Time-Based Capacity Accumulation

## Bug Description

The `ConvertibleDepositAuctioneer._getCurrentTick()` function calculates tick capacity decay based on time passed since the last update. When no bids occur for a long period, the capacity accumulates, and the while loop decays the price by `tickStep` for each full tick of accumulated capacity. An attacker can wait for a long period of low activity, then bid at an artificially low price that has decayed far below the intended minimum price.

### Vulnerable Code

**File:** `src/policies/deposits/ConvertibleDepositAuctioneer.sol`

**Lines 535-581 (`_getCurrentTick`):**
```solidity
function _getCurrentTick(uint8 depositPeriod_) internal view returns (Tick memory tick) {
    Tick memory previousTick = _depositPeriodPreviousTicks[depositPeriod_];

    if (_auctionParameters.target == 0) {
        return previousTick;
    }

    uint256 newCapacity;
    {
        uint256 timePassed = block.timestamp - previousTick.lastUpdate;
        uint256 capacityToAdd = (_auctionParameters.target * timePassed) /
            SECONDS_IN_DAY /
            _depositPeriods.length();

        tick = previousTick;
        newCapacity = tick.capacity + capacityToAdd;
    }

    uint256 tickSize = _auctionParameters.tickSize;
    while (newCapacity > tickSize) {
        newCapacity -= tickSize;

        // Adjust the tick price by the tick step, in the opposite direction
        tick.price = tick.price.mulDivUp(ONE_HUNDRED_PERCENT, _tickStep);

        // Tick price does not go below the minimum
        if (tick.price < _auctionParameters.minPrice) {
            tick.price = _auctionParameters.minPrice;
            break;
        }
    }

    tick.capacity = newCapacity > _currentTickSize ? _currentTickSize : newCapacity;

    return tick;
}
```

### Analysis

The price floor (`_auctionParameters.minPrice`) prevents the price from going below the configured minimum. The `break` statement exits the loop when the floor is hit. This means the decay IS bounded.

However, the `minPrice` is set by the EmissionManager based on the current oracle price multiplied by `minPriceScalar` (line 765 of EmissionManager):
```solidity
return price.mulDivUp(minPriceScalar, ONE_HUNDRED_PERCENT);
```

If the `setAuctionParameters` call is delayed (e.g., heartbeat down for hours), the stored `minPrice` could be stale relative to the actual market price. An attacker could bid at the stale minimum price, which may be below the current market price, obtaining a discount on OHM conversion.

Additionally, the while loop can iterate many times if `timePassed` is large. With `target = 1000e9` (1000 OHM), `tickSize = 100e9`, and 1 deposit period, after 1 day of inactivity: `capacityToAdd = 1000e9 * 86400 / 86400 / 1 = 1000e9`. This results in `1000e9 / 100e9 = 10` iterations, each multiplying price by `ONE_HUNDRED_PERCENT / _tickStep`. This is bounded by the minPrice floor and is designed behavior.

## Impact

**Severity: Informational**

After thorough analysis, the tick decay mechanism is functioning as designed:
1. The price floor prevents unbounded decay
2. The minPrice is updated by the EmissionManager on each heartbeat
3. The capacity is capped to the current tick size

The potential stale price issue during heartbeat downtime is a general concern but is mitigated by the 3% buffer in the EmissionManager's `_getCurrentPrice()` and the `minPriceScalar` (which is >= 100%).

## Risk Breakdown

- **Difficulty to exploit:** High
- **Weakness type:** N/A
- **CVSS:** Informational

## Recommendation

Consider adding a maximum time cap on the decay calculation to limit the number of while loop iterations:

```diff
  uint256 timePassed = block.timestamp - previousTick.lastUpdate;
+ // Cap time passed to 1 day to prevent excessive iterations
+ if (timePassed > SECONDS_IN_DAY) timePassed = SECONDS_IN_DAY;
  uint256 capacityToAdd = (_auctionParameters.target * timePassed) /
      SECONDS_IN_DAY /
      _depositPeriods.length();
```

## References

- [ConvertibleDepositAuctioneer.sol - _getCurrentTick](https://github.com/OlympusDAO/bophades/blob/main/src/policies/deposits/ConvertibleDepositAuctioneer.sol#L535-L581)
- [EmissionManager.sol - getMinPriceFor](https://github.com/OlympusDAO/bophades/blob/main/src/policies/EmissionManager.sol#L763-L766)
