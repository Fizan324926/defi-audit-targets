// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.15;

import "forge-std/Test.sol";

/// @title PoC: EmissionManager _updateBacking precision loss
/// @notice Demonstrates the systematic downward bias in backing calculation
///         due to compounded integer division truncation
contract PoC_002_BackingPrecision is Test {
    uint256 constant RESERVE_DECIMALS = 18;

    function test_precisionLossInBacking() public {
        uint256 backing = 11_33e16; // $11.33
        uint256 previousReserves = 100_000_000e18; // $100M
        uint256 previousSupply = 8_000_000e9; // 8M OHM

        uint256 supplyAdded = 100e9;
        uint256 reservesAdded = 1200e18;

        // Current implementation (3 truncating divisions)
        uint256 percentIncreaseReserves = ((previousReserves + reservesAdded) *
            10 ** RESERVE_DECIMALS) / previousReserves;
        uint256 percentIncreaseSupply = ((previousSupply + supplyAdded) *
            10 ** RESERVE_DECIMALS) / previousSupply;
        uint256 backingCurrent = (backing * percentIncreaseReserves) / percentIncreaseSupply;

        // Better calculation with fewer truncations
        uint256 backingBetter = (backing * (previousReserves + reservesAdded) * previousSupply) /
            (previousReserves * (previousSupply + supplyAdded));

        emit log_named_uint("Backing (current impl)", backingCurrent);
        emit log_named_uint("Backing (better calc)", backingBetter);

        // Over 100 iterations
        uint256 backingA = backing;
        uint256 backingB = backing;
        for (uint256 i = 0; i < 100; i++) {
            uint256 pir = ((previousReserves + reservesAdded) * 10 ** RESERVE_DECIMALS) /
                previousReserves;
            uint256 pis = ((previousSupply + supplyAdded) * 10 ** RESERVE_DECIMALS) /
                previousSupply;
            backingA = (backingA * pir) / pis;

            backingB = (backingB * (previousReserves + reservesAdded) * previousSupply) /
                (previousReserves * (previousSupply + supplyAdded));

            previousReserves += reservesAdded;
            previousSupply += supplyAdded;
        }

        emit log_named_uint("After 100 callbacks (current)", backingA);
        emit log_named_uint("After 100 callbacks (better)", backingB);
        if (backingB > backingA) {
            emit log_named_uint("Accumulated drift (wei)", backingB - backingA);
        }
    }
}
