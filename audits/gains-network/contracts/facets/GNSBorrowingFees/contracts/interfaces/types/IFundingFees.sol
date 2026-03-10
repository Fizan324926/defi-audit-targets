// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./ITradingStorage.sol";
import "./IPriceImpact.sol";

/**
 * @dev Contains the types for the GNSFundingFees facet
 */
interface IFundingFees {
    struct FundingFeesStorage {
        mapping(uint8 => mapping(uint16 => PairGlobalParams)) pairGlobalParams;
        mapping(uint8 => mapping(uint16 => FundingFeeParams)) pairFundingFeeParams;
        mapping(uint8 => mapping(uint16 => BorrowingFeeParams)) pairBorrowingFeeParams;
        mapping(uint8 => mapping(uint16 => PairFundingFeeData)) pairFundingFeeData;
        mapping(uint8 => mapping(uint16 => PairBorrowingFeeData)) pairBorrowingFeeData;
        mapping(address => mapping(uint32 => TradeFeesData)) tradeFeesData;
        mapping(address => mapping(uint32 => UiRealizedPnlData)) tradeUiRealizedPnlData;
        mapping(uint32 => PendingParamUpdate) pendingParamUpdates;
        uint256[42] __gap;
    }

    enum ParamUpdateType {
        SKEW_COEFFICIENT_PER_YEAR,
        ABSOLUTE_VELOCITY_PER_YEAR_CAP,
        ABSOLUTE_RATE_PER_SECOND_CAP,
        THETA_THRESHOLD_USD,
        FUNDING_FEES_ENABLED,
        APR_MULTIPLIER_ENABLED,
        BORROWING_RATE_PER_SECOND_P,
        BORROWING_PAIR
    }

    struct PairGlobalParams {
        /**
         * @dev Max skew in collateral tokens allowed when opening a trade / partial adding
         * @dev Min: 0 (= disabled)
         * @dev Precision: 1e-10
         * @dev Max: 120,892,581,961,462 (= 120m USD if collateral/usd = 1e-6)
         * @dev If left uninitialized (0), max skew is disabled
         */
        uint80 maxSkewCollateral;
        uint176 __placeholder;
    }

    struct FundingFeeParams {
        /**
         * @dev Yearly velocity coefficient of the funding rate % / second, it is multiplied by the net exposure in tokens.
         * @dev Precision: 1e-26 => 10^20 token exposure (= 100m USD, 1 collateral = 1e-6 USD, current pair price = 1e-6), funding APR += 31.536% each year (+= 0.0864% each day)
         * @dev Max: 5.19e7 => 1e-8 collateral exposure (= 10k USD, 1 collateral = 1e6 USD, current pair price = 1e6), funding APR += 16,374,427% each year (+= 44,861% each day, += 1,869% each hour)
         * @dev If left uninitialized (0), the funding rate velocity will stay at 0
         */
        uint112 skewCoefficientPerYear;
        /**
         * @dev Absolute cap on the yearly velocity of the funding rate % / second (same when funding positive or negative).
         * @dev Precision: 1e-7 => 3.15% APR absolute increase per year (+= 0.00864% each day)
         * @dev Theoretical max: 1.67 => max 52,908,625% APR absolute increase per year (+= 144,955% each day, += 6,039% each hour)
         * @dev If left uninitialized (0), the funding rate velocity will stay at 0
         */
        uint24 absoluteVelocityPerYearCap;
        /**
         * @dev Cap on the absolute value of the funding rate % / second.
         * @dev Precision: 1e-10 => 0.0031536% APR
         * @dev Theoretical max: 0.0016 => 52,908% APR
         * @dev True cap: 0.0003170979 => 10,000% APR
         * @dev If left uninitialized (0), the funding rate will stay at 0
         */
        uint24 absoluteRatePerSecondCap;
        /**
         * @dev Minimum net exposure in USD required for funding rate velocity to be != 0.
         * @dev Precision: 1 USD (no decimals)
         * @dev Max: 4,294,967,295 USD
         * @dev If left uninitialized (0), there will be no minimum exposure threshold
         */
        uint32 thetaThresholdUsd;
        /**
         * @dev When set to true, enables funding fees on the pair (funding rate always resumes from last rate after funding fees were disabled)
         * @dev When set to false, disables funding fees on the pair
         * @dev If left uninitialized (false), funding fees are disabled by default on the pair
         */
        bool fundingFeesEnabled;
        /**
         * @dev When set to true, enables earning side APR multiplier (earning APR = paying APR * paying OI / earning OI)
         * @dev When set to false, disables earning side APR multiplier (paying APR = earning APR)
         * @dev If left uninitialized (false), earning side APR multiplier is disabled by default on the pair
         */
        bool aprMultiplierEnabled;
        uint48 __placeholder;
    }

    struct BorrowingFeeParams {
        /**
         * @dev Borrowing rate % / second for a given pair.
         * @dev Precision: 1e-10 => 0.0031536% APR
         * @dev Theoretical max: 0.0016 => 52,908% APR
         * @dev True cap: 0.0000317097 => 1,000% APR
         * @dev If left uninitialized (0), the borrowing rate is 0
         */
        uint24 borrowingRatePerSecondP;
        uint232 __placeholder;
    }

    struct PairFundingFeeData {
        /**
         * @dev Accumulated funding fees % weighted by pair price (unit: fee collateral per 100 units of OI in pair amount)
         * @dev To know the funding fee in collateral tokens for a trade, do (current acc fee - initial acc fee) * position size collateral / entry price / 1e10 / 100.
         * @dev Step: 1e-20%; min step = lowest funding rate % per second * 1 second * lowest pair price = 1e-20% (no issues with rounding down)
         * @dev Max: 1.7e18; max possible value = max funding % / second * max timestamp * max pair price * 100 (smaller side cap) = 0.0016 * 4,294,967,295 * 1e6 * 100 = 6.87e14
         * @dev Acc funding fees use funding rate % / second precision of 1e-10 => min/step APR = 0.0031536%
         */
        int128 accFundingFeeLongP;
        int128 accFundingFeeShortP;
        /**
         * @dev Funding rate % / second when the net exposure or funding fee parameters last changed.
         * @dev The true current rate is different depending on the current funding rate velocity and the timestamp of the last update.
         * @dev Precision: 1e-18% => 3.15e-11% APR; min step = lowest velocity per year * 1 second / 1 year = 1e-10 * 1 / (86400*365) = 3.17e-18 (no issues with rounding down)
         * @dev Theoretical max: 0.036 => 1,136,204% APR
         * @dev True cap: 0.0003171 => 10,000% APR
         */
        int56 lastFundingRatePerSecondP;
        /**
         * @dev Timestamp of last accumulated funding fees update
         * @dev Max: 4,294,967,295 (Feb 07 2106)
         */
        uint32 lastFundingUpdateTs;
        uint168 __placeholder;
    }

    struct PairBorrowingFeeData {
        /**
         * @dev Accumulated borrowing fees % weighted by pair price (unit: fee collateral per 100 units of OI in pair amount)
         * @dev To know the borrowing fee in collateral tokens for a trade, do (current acc fee - initial acc fee) * position size collateral / entry price / 1e10 / 100.
         * @dev Precision: 1e-20%; min step = lowest borrowing rate % per second * 1 second * lowest pair price = 1e-20% (no issues with rounding down)
         * @dev Max: 3.4e18; max possible value = max borrowing % / second * max timestamp * max pair price = 0.0016 * 4,294,967,295 * 1e6 = 6.87e12
         */
        uint128 accBorrowingFeeP;
        /**
         * @dev Timestamp of last accumulated borrowing fees update
         * @dev Max: 4,294,967,295 (Feb 07 2106)
         */
        uint32 lastBorrowingUpdateTs;
        uint96 __placeholder;
    }

    struct TradeFeesData {
        /**
         * @dev Realized trading fees impact trade value and collateral in diamond (already sent) and realized pnl only impacts trade value.
         * @dev Trading fees/Holding fees/Realized negative/positive pnl don't impact trade collateral/position size, they are stored separately here.
         * @dev They bring the liquidation price closer or further away depending on the sign.
         * @dev Precision: collateral precision
         */
        uint128 realizedTradingFeesCollateral;
        int128 realizedPnlCollateral;
        /**
         * @dev The following variables reduce the collateral available in diamond without impacting the trade value.
         * @dev It's cleaner than to increase realized trading fees and compensate by realizing positive pnl.
         * @dev Precision: collateral precision
         */
        uint128 manuallyRealizedNegativePnlCollateral;
        uint128 alreadyTransferredNegativePnlCollateral;
        /**
         * @dev The following variable increases the collateral available in diamond without impacting the trade value.
         * @dev Virtual available collateral in diamond (collateral precision) is important for leverage increases (= collateral withdrawals)
         * @dev It allows maintaining the same trade value and having no impact on other vars used to calculate available in diamond
         * @dev While never allowing a trade's available collateral in diamond to go below zero.
         * @dev If the user deposits collateral, available in diamond should always increase instead of going from negative to zero.
         * @dev Precision: collateral precision
         */
        uint128 virtualAvailableCollateralInDiamond;
        uint128 __placeholder;
        /**
         * @dev Used to know how much pending funding/borrowing fees a trade has to pay.
         * @dev When trade position size changes, updated to new acc funding/borrowing fees, and pending existing holding fees are stored separately.
         * @dev Precision: same as PairFundingFeeData.accFundingFeeLongP/accFundingFeeShortP and PairBorrowingFeeData.accBorrowingFeeP
         */
        int128 initialAccFundingFeeP;
        uint128 initialAccBorrowingFeeP;
    }

    struct UiRealizedPnlData {
        /**
         * @dev Trading action fees charged on the open trade (open, partial add, partial close, etc.)
         * @dev Precision: collateral precision
         */
        uint128 realizedTradingFeesCollateral;
        /**
         * @dev Old borrowing fees realized on the open trade
         * @dev Precision: collateral precision
         */
        uint128 realizedOldBorrowingFeesCollateral;
        /**
         * @dev New borrowing fees realized on the open trade
         * @dev Precision: collateral precision
         */
        uint128 realizedNewBorrowingFeesCollateral;
        /**
         * @dev Funding fees realized on the open trade
         * @dev Precision: collateral precision
         */
        int128 realizedFundingFeesCollateral;
        /**
         * @dev Realized pnl of all previous partial closes on the open trade
         * @dev Precision: collateral precision
         */
        int128 realizedPnlPartialCloseCollateral;
        /**
         * @dev All pnl withdrawn on the open trade
         * @dev Precision: collateral precision
         */
        uint128 pnlWithdrawnCollateral;
    }

    struct PendingParamUpdate {
        uint8 collateralIndex;
        uint16 pairIndex;
        ParamUpdateType updateType;
        uint224 newValue; /// @custom:dev uint224 is bigger than any of the funding/borrowing fee params, so no overflow possible
    }

    struct FundingFeeValues {
        IPriceImpact.PairOiToken pairOiToken; // 1e18
        int256 netExposureToken; // 1e18
        int256 netExposureUsd; // 1e10
        uint256 secondsSinceLastUpdate;
        int40 currentVelocityPerYear; // 1e10
        int256 avgFundingRatePerSecondP; // 1e18 (%)
        int256 currentPairPriceInt; // 1e10
        uint256 secondsToReachZeroRate;
        int256 fundingFeesDeltaP; // 1e20 (%)
        uint256 longAprMultiplier; // 1e20
        uint256 shortAprMultiplier; // 1e20
    }

    struct FundingParamCallbackInput {
        uint8 collateralIndex;
        uint16 pairIndex;
        uint224 newValue; // precision depends on parameter
    }

    struct TradeHoldingFees {
        int256 fundingFeeCollateral; // collateral precision
        uint256 borrowingFeeCollateral; // collateral precision
        uint256 borrowingFeeCollateral_old; // collateral precision
        int256 totalFeeCollateral; // collateral precision
    }

    struct RealizeTradingFeesValues {
        ITradingStorage.Trade trade;
        uint256 liqPrice; // 1e10
        uint128 newRealizedFeesCollateral; // collateral precision
        int128 newRealizedPnlCollateral; // collateral precision
        uint256 amountSentFromVaultCollateral; // collateral precision
    }
}
