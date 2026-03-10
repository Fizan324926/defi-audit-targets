// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8;

/// @title IPriceOracle
/// @notice Interface that price oracles for markets used must implement.
interface IPriceOracle {
    /// @notice Returns the price of 1 asset of collateral token quoted in
    /// 1 asset of loan token, scaled by 1e36.
    /// @dev It corresponds to the price of 10**(collateral token decimals)
    /// assets of collateral token quoted in
    /// 10**(loan token decimals) assets of loan token
    /// with `36 + loan token decimals - collateral token decimals`
    /// decimals of precision.
    function getPrice(address collateralToken, address loanToken) external view returns (uint256);

    /// @notice Returns the price with deviation check against last stored price
    /// @dev Non-view function that validates prices and updates storage
    /// @dev Reverts if price deviation exceeds configured threshold
    /// @param collateralToken The collateral token address
    /// @param loanToken The loan token address
    /// @return The price scaled by 1e36
    function getPriceChecked(address collateralToken, address loanToken) external returns (uint256);

    /// @notice Returns whether circuit breaker is active
    function isCircuitBreakerActive() external view returns (bool);

    /// @notice Returns the circuit breaker reason code
    function getCircuitBreakerReason() external view returns (uint8);
}
