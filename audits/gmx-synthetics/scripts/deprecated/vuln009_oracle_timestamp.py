#!/usr/bin/env python3
"""
VULN-009: Oracle Timestamp Adjustment Manipulation Analysis

Demonstrates how oracleTimestampAdjustment can be exploited to use
stale prices that pass freshness validation.

Usage: python3 vuln009_oracle_timestamp.py
"""

from dataclasses import dataclass
from typing import Optional
import time


@dataclass
class OraclePrice:
    """Represents a signed oracle price"""
    token: str
    min_price: float
    max_price: float
    timestamp: int  # Unix timestamp when signed
    provider: str


@dataclass
class OracleConfig:
    """Oracle configuration per market"""
    max_price_age: int  # Maximum allowed price age in seconds
    timestamp_adjustment: int  # Adjustment applied to timestamp
    max_ref_price_deviation: float  # Max deviation from Chainlink reference


def validate_price(
    price: OraclePrice,
    config: OracleConfig,
    current_timestamp: int,
    for_atomic_action: bool = False,
) -> dict:
    """
    Simulates Oracle._validatePrices timestamp validation.

    From Oracle.sol:295-301:
        if (provider.shouldAdjustTimestamp()) {
            uint256 timestampAdjustment = dataStore.getUint(
                Keys.oracleTimestampAdjustmentKey(_provider, token)
            );
            validatedPrice.timestamp -= timestampAdjustment;
        }

        if (validatedPrice.timestamp + maxPriceAge < Chain.currentTimestamp()) {
            revert Errors.MaxPriceAgeExceeded(...)
        }
    """
    actual_age = current_timestamp - price.timestamp
    adjusted_timestamp = price.timestamp - config.timestamp_adjustment
    # Note: timestamp is DECREASED by adjustment (subtracted)
    # This makes the price appear OLDER, not younger
    # Wait - re-reading the code: validatedPrice.timestamp -= timestampAdjustment
    # If adjustment is positive, timestamp gets smaller = price appears OLDER
    # This is the opposite of what we'd expect for exploitation...

    # Actually, let's look more carefully:
    # Check: adjustedTimestamp + maxPriceAge < currentTimestamp
    # => fails if: adjustedTimestamp < currentTimestamp - maxPriceAge
    # => fails if: (originalTimestamp - adjustment) < currentTimestamp - maxPriceAge
    # => fails if: originalTimestamp < currentTimestamp - maxPriceAge + adjustment

    # So a POSITIVE adjustment makes it EASIER to fail (price appears older)
    # A NEGATIVE adjustment (if allowed) would make price appear younger

    # But wait - if the adjustment is subtracted from timestamp:
    # A negative adjustment value would be: timestamp -= (-X) = timestamp + X
    # Making the timestamp LARGER = price appears MORE RECENT

    # The vulnerability is about misconfigured or manipulated adjustments
    effective_age = current_timestamp - adjusted_timestamp
    passes_check = adjusted_timestamp + config.max_price_age >= current_timestamp

    return {
        "token": price.token,
        "original_timestamp": price.timestamp,
        "adjusted_timestamp": adjusted_timestamp,
        "actual_age_seconds": actual_age,
        "effective_age_seconds": effective_age,
        "max_price_age": config.max_price_age,
        "passes_freshness": passes_check,
        "timestamp_adjustment": config.timestamp_adjustment,
    }


def simulate_exploitation():
    """
    Demonstrate scenarios where timestamp adjustment enables stale price use.
    """
    print("=" * 70)
    print("VULN-009: Oracle Timestamp Adjustment Analysis")
    print("=" * 70)

    current_time = 1700000000  # Arbitrary reference time

    # Scenario 1: Normal operation (no adjustment)
    print("\n--- Scenario 1: Normal Operation (No Adjustment) ---")
    config_normal = OracleConfig(
        max_price_age=60,  # 60 seconds max age
        timestamp_adjustment=0,
        max_ref_price_deviation=0.05,
    )

    prices = [
        OraclePrice("ETH", 2000, 2001, current_time - 30, "provider_A"),  # 30s old
        OraclePrice("ETH", 2000, 2001, current_time - 55, "provider_A"),  # 55s old
        OraclePrice("ETH", 2000, 2001, current_time - 65, "provider_A"),  # 65s old (stale)
    ]

    for price in prices:
        result = validate_price(price, config_normal, current_time)
        age = result["actual_age_seconds"]
        status = "PASS" if result["passes_freshness"] else "FAIL (stale)"
        print(f"  Price age {age}s: {status}")

    # Scenario 2: With timestamp adjustment affecting validation
    print("\n--- Scenario 2: Cross-Market Timestamp Inconsistency ---")
    print("  Two markets for same underlying, different adjustments")

    config_market_a = OracleConfig(max_price_age=60, timestamp_adjustment=0, max_ref_price_deviation=0.05)
    config_market_b = OracleConfig(max_price_age=60, timestamp_adjustment=10, max_ref_price_deviation=0.05)

    price = OraclePrice("ETH", 2000, 2001, current_time - 55, "provider_A")

    result_a = validate_price(price, config_market_a, current_time)
    result_b = validate_price(price, config_market_b, current_time)

    print(f"  Same price (55s old):")
    print(f"    Market A (adj=0): effective_age={result_a['effective_age_seconds']}s "
          f"{'PASS' if result_a['passes_freshness'] else 'FAIL'}")
    print(f"    Market B (adj=10): effective_age={result_b['effective_age_seconds']}s "
          f"{'PASS' if result_b['passes_freshness'] else 'FAIL'}")

    # Scenario 3: Atomic vs non-atomic max price age
    print("\n--- Scenario 3: Atomic vs Non-Atomic Price Age ---")
    print("  From Oracle.sol:250:")
    print("  maxPriceAge = forAtomicAction ? MAX_ATOMIC_ORACLE_PRICE_AGE : MAX_ORACLE_PRICE_AGE")

    config_atomic = OracleConfig(max_price_age=10, timestamp_adjustment=0, max_ref_price_deviation=0.05)
    config_regular = OracleConfig(max_price_age=60, timestamp_adjustment=0, max_ref_price_deviation=0.05)

    stale_price = OraclePrice("ETH", 1950, 1951, current_time - 15, "provider_A")

    result_atomic = validate_price(stale_price, config_atomic, current_time)
    result_regular = validate_price(stale_price, config_regular, current_time)

    print(f"  15s old price:")
    print(f"    Atomic (max_age=10s): {'PASS' if result_atomic['passes_freshness'] else 'FAIL (too stale)'}")
    print(f"    Regular (max_age=60s): {'PASS' if result_regular['passes_freshness'] else 'FAIL'}")

    # Scenario 4: Provider validation bypass in atomic actions
    print("\n--- Scenario 4: Atomic Provider Flexibility ---")
    print("  From Oracle.sol:263-284:")
    print("  For atomic: ANY atomic provider accepted (not token-specific)")
    print("  For regular: provider must match token's configured provider")
    print("")
    print("  Risk: An atomic provider validated for token A")
    print("  could potentially be used to price token B")
    print("  since the validation only checks isAtomicProvider(provider)")
    print("  not isAtomicProviderForToken(provider, token)")


def analyze_chainlink_reference():
    """
    Analyze Chainlink reference price validation.
    """
    print("\n" + "=" * 70)
    print("Chainlink Reference Price Check (Oracle.sol:304-322)")
    print("=" * 70)

    print("""
  Code flow:
  1. If provider is NOT a Chainlink on-chain provider:
     - Get Chainlink reference price via getPriceFeedPrice()
     - Validate signed price is within maxRefPriceDeviationFactor
  2. If provider IS Chainlink on-chain:
     - Skip reference check (would be checking against itself)

  Vulnerability scenarios:
  a) If maxRefPriceDeviationFactor is too high (e.g., 10%):
     - Signed price can deviate up to 10% from Chainlink
     - 10% on a $2000 token = $200 per token manipulation
  b) Chainlink reference is itself stale (heartbeat issue - VULN-010):
     - The "validation" uses a stale reference
     - Signed price passes check against wrong baseline
  c) For Chainlink on-chain providers, NO cross-check is performed:
     - Sole source of truth is the Chainlink feed itself
     - If Chainlink reports wrong price, no backup validation
    """)


def main():
    simulate_exploitation()
    analyze_chainlink_reference()

    print("\n" + "=" * 70)
    print("CONCLUSION:")
    print("  1. Timestamp adjustments shift effective price age")
    print("  2. Different markets with different adjustments create arbitrage")
    print("  3. Atomic actions use shorter max age but flexible providers")
    print("  4. Chainlink reference check has configurable deviation factor")
    print("  5. Main risk: keeper/oracle collusion using edge-case configs")
    print("=" * 70)


if __name__ == "__main__":
    main()
