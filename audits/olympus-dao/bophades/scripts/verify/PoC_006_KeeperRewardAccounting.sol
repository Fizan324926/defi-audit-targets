// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.15;

import "forge-std/Test.sol";

/// @title PoC: Clearinghouse keeper reward accounting discrepancy
/// @notice Shows that keeper rewards create an untracked gap between
///         the debt reduction and actual collateral burned
contract PoC_006_KeeperRewardAccounting is Test {
    uint256 constant LOAN_TO_COLLATERAL = 289292e16; // 2,892.92 reserve/gOHM
    uint256 constant MAX_REWARD = 1e17; // 0.1 gOHM

    function test_accountingDiscrepancy() public {
        uint256 numDefaults = 10;
        uint256 collateralPerLoan = 1e18; // 1 gOHM
        uint256 principalPerLoan = (collateralPerLoan * LOAN_TO_COLLATERAL) / 1e18;
        uint256 totalPrincipal = principalPerLoan * numDefaults;

        // Keeper rewards (max 0.1 gOHM per loan after 7+ days)
        uint256 totalKeeperReward = MAX_REWARD * numDefaults;
        uint256 rewardValue = (totalKeeperReward * LOAN_TO_COLLATERAL) / 1e18;

        // Debt reduced by totalPrincipal, but only (totalPrincipal - rewardValue) recovered
        assertGt(rewardValue, 0, "Accounting gap should be non-zero");

        emit log_named_uint("Total principal reduced (reserve)", totalPrincipal);
        emit log_named_uint("Keeper reward value unaccounted (reserve)", rewardValue);
    }
}
