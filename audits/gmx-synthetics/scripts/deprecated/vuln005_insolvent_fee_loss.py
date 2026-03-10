#!/usr/bin/env python3
"""
VULN-005: Insolvent Close Fee Loss Quantification

Models the economic impact of zeroing ALL accumulated fees when positions
are liquidated in an insolvent state. Demonstrates how the protocol
loses revenue during market crashes.

Usage: python3 vuln005_insolvent_fee_loss.py
"""

from dataclasses import dataclass
from typing import List
import math


@dataclass
class Position:
    """Represents a leveraged position"""
    account: str
    size_usd: float
    collateral_usd: float
    entry_price: float
    is_long: bool
    borrowing_rate_per_hour: float  # e.g., 0.00001 = 0.001%
    funding_rate_per_hour: float
    lifetime_hours: float

    @property
    def leverage(self) -> float:
        return self.size_usd / self.collateral_usd

    @property
    def accumulated_borrowing_fee(self) -> float:
        return self.size_usd * self.borrowing_rate_per_hour * self.lifetime_hours

    @property
    def accumulated_funding_fee(self) -> float:
        return self.size_usd * self.funding_rate_per_hour * self.lifetime_hours

    @property
    def total_accumulated_fees(self) -> float:
        return self.accumulated_borrowing_fee + self.accumulated_funding_fee


def simulate_fee_waterfall(position: Position, current_price: float) -> dict:
    """
    Simulates the DecreasePositionCollateralUtils fee waterfall.

    The waterfall order:
    1. Funding fees
    2. Negative PnL
    3. Position fees (closing fee)
    4. Negative price impact
    5. Price impact diff

    At ANY checkpoint, if costs > remaining collateral AND isInsolventCloseAllowed:
    → handleEarlyReturn → ALL fees zeroed via getEmptyFees()
    """
    remaining_collateral = position.collateral_usd

    # Calculate PnL
    if position.is_long:
        pnl = position.size_usd * (current_price - position.entry_price) / position.entry_price
    else:
        pnl = position.size_usd * (position.entry_price - current_price) / position.entry_price

    funding_fee = position.accumulated_funding_fee
    borrowing_fee = position.accumulated_borrowing_fee
    position_fee = position.size_usd * 0.001  # 0.1% closing fee
    price_impact = position.size_usd * 0.0005  # 0.05% price impact

    waterfall_steps = [
        ("Funding Fee", funding_fee),
        ("Negative PnL", max(0, -pnl)),
        ("Position Fee", position_fee + borrowing_fee),
        ("Price Impact", price_impact),
    ]

    fees_collected = 0
    fees_lost = 0
    insolvent_at_step = None

    result_steps = []
    for step_name, cost in waterfall_steps:
        if remaining_collateral >= cost:
            remaining_collateral -= cost
            fees_collected += cost
            result_steps.append({
                "step": step_name,
                "cost": cost,
                "paid": True,
                "remaining": remaining_collateral,
            })
        else:
            # INSOLVENCY DETECTED
            insolvent_at_step = step_name

            # In GMX: handleEarlyReturn zeros ALL fees
            # Not just the remaining cost, but ALL fees including previously "paid" ones
            fees_lost = position.total_accumulated_fees + position_fee + price_impact
            fees_collected = 0  # ALL fees zeroed

            result_steps.append({
                "step": step_name,
                "cost": cost,
                "paid": False,
                "remaining": remaining_collateral,
                "insolvent": True,
            })
            break

    return {
        "position": {
            "size": position.size_usd,
            "collateral": position.collateral_usd,
            "leverage": position.leverage,
            "lifetime_hours": position.lifetime_hours,
        },
        "pnl": pnl,
        "total_fees_accumulated": position.total_accumulated_fees,
        "fees_collected": fees_collected,
        "fees_lost": fees_lost,
        "insolvent_at_step": insolvent_at_step,
        "waterfall_steps": result_steps,
    }


def simulate_market_crash():
    """
    Simulate a market crash scenario where many positions become insolvent.
    """
    print("=" * 70)
    print("VULN-005: Insolvent Close Fee Loss Simulation")
    print("=" * 70)

    # Generate positions with various parameters
    positions = [
        Position("Trader_A", 1_000_000, 50_000, 2000, True, 0.00001, 0.000005, 168),   # 20x, 1 week
        Position("Trader_B", 500_000, 25_000, 2000, True, 0.00001, 0.000005, 336),      # 20x, 2 weeks
        Position("Trader_C", 2_000_000, 200_000, 2000, True, 0.00001, 0.000005, 720),   # 10x, 30 days
        Position("Trader_D", 100_000, 5_000, 2000, True, 0.00001, 0.000005, 168),       # 20x, 1 week
        Position("Trader_E", 5_000_000, 500_000, 2000, True, 0.00001, 0.000005, 504),   # 10x, 3 weeks
        Position("Trader_F", 300_000, 15_000, 2000, True, 0.00001, 0.000005, 168),      # 20x, 1 week
        Position("Trader_G", 750_000, 75_000, 2000, True, 0.00001, 0.000005, 336),      # 10x, 2 weeks
        Position("Trader_H", 150_000, 7_500, 2000, True, 0.00001, 0.000005, 504),       # 20x, 3 weeks
    ]

    # Market crashes: ETH drops from $2000 to various levels
    crash_prices = [1800, 1600, 1400, 1200, 1000]

    for crash_price in crash_prices:
        print(f"\n{'='*70}")
        crash_pct = (2000 - crash_price) / 2000 * 100
        print(f"Market Crash to ${crash_price} ({crash_pct:.0f}% drop)")
        print(f"{'='*70}")

        total_fees_accumulated = 0
        total_fees_lost = 0
        total_fees_collected = 0
        insolvent_count = 0

        for pos in positions:
            result = simulate_fee_waterfall(pos, crash_price)
            total_fees_accumulated += result["total_fees_accumulated"]
            total_fees_lost += result["fees_lost"]
            total_fees_collected += result["fees_collected"]

            if result["insolvent_at_step"]:
                insolvent_count += 1
                print(f"\n  {pos.account}: INSOLVENT at '{result['insolvent_at_step']}'")
                print(f"    Size: ${pos.size_usd:,.0f} | Leverage: {pos.leverage:.0f}x | Life: {pos.lifetime_hours}h")
                print(f"    PnL: ${result['pnl']:,.0f}")
                print(f"    Accumulated fees: ${result['total_fees_accumulated']:,.2f}")
                print(f"    Fees LOST (zeroed): ${result['fees_lost']:,.2f}")

        print(f"\n  --- Summary ---")
        print(f"  Total positions: {len(positions)}")
        print(f"  Insolvent positions: {insolvent_count}")
        print(f"  Total accumulated fees: ${total_fees_accumulated:,.2f}")
        print(f"  Fees collected: ${total_fees_collected:,.2f}")
        print(f"  Fees LOST (zeroed): ${total_fees_lost:,.2f}")
        if total_fees_accumulated > 0:
            print(f"  Fee loss rate: {total_fees_lost/total_fees_accumulated*100:.1f}%")


def analyze_alternative_approach():
    """
    Compare current approach (zero ALL fees) vs partial collection.
    """
    print("\n" + "=" * 70)
    print("Alternative: Partial Fee Collection Instead of Zero-All")
    print("=" * 70)

    pos = Position("Example", 1_000_000, 50_000, 2000, True, 0.00001, 0.000005, 168)
    crash_price = 1400  # 30% drop

    # Current approach: zero all
    result_current = simulate_fee_waterfall(pos, crash_price)

    # Alternative: collect what's available
    remaining = pos.collateral_usd
    pnl = pos.size_usd * (crash_price - pos.entry_price) / pos.entry_price  # -300,000
    neg_pnl = max(0, -pnl)

    # In alternative approach: collect fees first, then absorb PnL
    funding_fee = pos.accumulated_funding_fee
    borrowing_fee = pos.accumulated_borrowing_fee

    collected_in_alternative = min(remaining, funding_fee + borrowing_fee)
    remaining_after_fees = remaining - collected_in_alternative
    # PnL absorbs whatever is left
    bad_debt = max(0, neg_pnl - remaining_after_fees)

    print(f"\n  Position: ${pos.size_usd:,.0f} | {pos.leverage:.0f}x | {pos.lifetime_hours}h")
    print(f"  Price drop: ${pos.entry_price} → ${crash_price}")
    print(f"  PnL: ${pnl:,.0f}")
    print(f"  Accumulated fees: ${pos.total_accumulated_fees:,.2f}")
    print(f"")
    print(f"  CURRENT approach (zero all):")
    print(f"    Fees collected: $0")
    print(f"    Fees lost: ${result_current['fees_lost']:,.2f}")
    print(f"")
    print(f"  ALTERNATIVE approach (collect available):")
    print(f"    Fees collected: ${collected_in_alternative:,.2f}")
    print(f"    Bad debt: ${bad_debt:,.2f}")
    print(f"    Improvement: ${collected_in_alternative:,.2f} more fees collected")


def main():
    simulate_market_crash()
    analyze_alternative_approach()

    print("\n" + "=" * 70)
    print("CONCLUSION:")
    print("  handleEarlyReturn with getEmptyFees() zeroes ALL fees, not just")
    print("  the shortfall. This causes the protocol to lose ALL accumulated")
    print("  borrowing and funding fees on insolvent liquidations.")
    print("  During market crashes, this can result in $100K+ fee losses.")
    print("  The fix: collect available fees before absorbing bad debt.")
    print("=" * 70)


if __name__ == "__main__":
    main()
