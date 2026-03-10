// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {FixedPoint96} from "@uniswap/v3-core/contracts/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";

import "../interfaces/IGNSMultiCollatDiamond.sol";

import "./AddressStoreUtils.sol";
import "./ConstantsUtils.sol";

/**
 * @custom:version 8.0.1
 * @dev Library to abstract liquidity pool operations such as fetching observations, calculating TWAP, etc.
 * Currently supports Uniswap V3 and Algebra V1.9 liquidity pools
 */
library LiquidityPoolUtils {
    /**
     * @dev Returns a `LiquidityPoolInfo` struct for LiquidityPoolInput `_input`
     * @param _input LiquidityPoolInput struct with pool address and type
     */
    function getLiquidityPoolInfo(
        IPriceAggregator.LiquidityPoolInput calldata _input
    ) internal view returns (IPriceAggregator.LiquidityPoolInfo memory) {
        return
            IPriceAggregator.LiquidityPoolInfo({
                poolType: _input.poolType,
                pool: _input.pool,
                isGnsToken0InLp: _input.poolType == IPriceAggregator.PoolType.CONSTANT_VALUE ||
                    _input.pool.token0() == AddressStoreUtils.getAddresses().gns,
                __placeholder: 0
            });
    }

    /**
     * @dev Calculates the time-weighted average price of a liquidity pool over a given interval
     * @param _poolInfo Liquidity pool info
     * @param _twapInterval TWAP interval in seconds
     * @param _precisionDelta precision delta of collateral
     */
    function getTimeWeightedAveragePrice(
        IPriceAggregator.LiquidityPoolInfo memory _poolInfo,
        uint32 _twapInterval,
        uint256 _precisionDelta
    ) internal view returns (uint256) {
        // When pool is `CONSTANT_VALUE`, return early with 1e10 (ie 1:1 price); Currently only used for GNS as collateral
        if (_poolInfo.poolType == IPriceAggregator.PoolType.CONSTANT_VALUE) {
            return ConstantsUtils.P_10;
        }

        int56[] memory tickCumulatives = _getPoolTickCumulatives(_poolInfo, _twapInterval);
        return _tickCumulativesToTokenPrice(tickCumulatives, _twapInterval, _precisionDelta, _poolInfo.isGnsToken0InLp);
    }

    /**
     * @dev Fetches tickCumulatives data from the pool. Calls the appropriate oracle function based on the pool type
     * @param _poolInfo Liquidity pool info
     * @param _twapInterval TWAP interval
     */
    function _getPoolTickCumulatives(
        IPriceAggregator.LiquidityPoolInfo memory _poolInfo,
        uint32 _twapInterval
    ) internal view returns (int56[] memory) {
        int56[] memory tickCumulatives;
        uint32[] memory secondsAgos = new uint32[](2);

        secondsAgos[0] = _twapInterval;
        secondsAgos[1] = 0;

        // If pool is Uniswap V3 call `observe` function
        if (_poolInfo.poolType == IPriceAggregator.PoolType.UNISWAP_V3) {
            (tickCumulatives, ) = _poolInfo.pool.observe(secondsAgos);
        }
        // If pool is Algebra V1.9 call `getTimepoints` function
        else if (_poolInfo.poolType == IPriceAggregator.PoolType.ALGEBRA_v1_9) {
            (tickCumulatives, , , ) = _poolInfo.pool.getTimepoints(secondsAgos);
        }
        // If pool is anything else, revert with InvalidPoolType error (this should never happen)
        else {
            revert IPriceAggregatorUtils.InvalidPoolType();
        }

        return tickCumulatives;
    }

    /**
     * @dev Returns TWAP price (1e10 precision) from tickCumulatives data
     * @param _tickCumulatives array of tickCumulatives
     * @param _twapInterval TWAP interval
     * @param _precisionDelta precision delta of collateral
     * @param _isGnsToken0InLp true if GNS is token0 in LP
     *
     * Inspired from https://github.com/Uniswap/v3-periphery/blob/main/contracts/libraries/OracleLibrary.sol
     */
    function _tickCumulativesToTokenPrice(
        int56[] memory _tickCumulatives,
        uint32 _twapInterval,
        uint256 _precisionDelta,
        bool _isGnsToken0InLp
    ) internal pure returns (uint256) {
        if (_tickCumulatives.length != 2) revert IGeneralErrors.WrongLength();

        int56 tickCumulativesDelta = _tickCumulatives[1] - _tickCumulatives[0];
        int56 twapIntervalInt = int56(int32(_twapInterval));

        int24 arithmeticMeanTick = int24(tickCumulativesDelta / twapIntervalInt);
        // Always round to negative infinity
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % twapIntervalInt != 0)) arithmeticMeanTick--;

        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(arithmeticMeanTick); // sqrt(token1/token0*2^96)
        uint256 priceX96 = (FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96) * ConstantsUtils.P_10); // token1/token0*2^96*1e10

        return
            _isGnsToken0InLp
                ? (priceX96 * _precisionDelta) / 2 ** 96 // 1e6/1e18*2^96*1e10 * 1e12 / 2^96 = 1e18/1e18*1e10
                : (ConstantsUtils.P_10 ** 2) / (priceX96 / _precisionDelta / 2 ** 96); // 1e10^2 / (1e18/1e6*2^96*1e10 / 1e12 / 2^96) = 1e10^2 / (1e18/1e18*1e10) = 1e18/1e18*1e10
    }
}
