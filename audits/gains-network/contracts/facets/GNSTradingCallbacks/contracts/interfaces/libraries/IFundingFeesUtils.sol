// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../types/IFundingFees.sol";
import "../types/IPriceAggregator.sol";
import "../types/ITradingCallbacks.sol";

/**
 * @dev Interface for GNSFundingFees facet (inherits types and also contains functions, events, and custom errors)
 */
interface IFundingFeesUtils is IFundingFees {
    /**
     * @dev Updates max skew in collateral tokens for pairs
     * @param _collateralIndex index of the collateral
     * @param _pairIndex index of the pair
     * @param _maxSkewCollateral new value (1e10)
     */
    function setMaxSkewCollateral(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex,
        uint80[] calldata _maxSkewCollateral
    ) external;

    /**
     * @dev Updates funding skew coefficient per year for pairs
     * @param _collateralIndex index of the collateral
     * @param _pairIndex index of the pair
     * @param _skewCoefficientPerYear new value (1e26)
     * @param _signedPairPrices signed pair market prices
     */
    function setSkewCoefficientPerYear(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex,
        uint112[] calldata _skewCoefficientPerYear,
        IPriceAggregator.SignedPairPrices[] calldata _signedPairPrices
    ) external;

    /**
     * @dev Updates absolute funding velocity per year cap for pairs
     * @param _collateralIndex index of the collateral
     * @param _pairIndex index of the pair
     * @param _absoluteVelocityPerYearCap new value (1e7)
     * @param _signedPairPrices signed pair market prices
     */
    function setAbsoluteVelocityPerYearCap(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex,
        uint24[] calldata _absoluteVelocityPerYearCap,
        IPriceAggregator.SignedPairPrices[] calldata _signedPairPrices
    ) external;

    /**
     * @dev Updates funding rate % per second absolute cap for pairs
     * @param _collateralIndex index of the collateral
     * @param _pairIndex index of the pair
     * @param _absoluteRatePerSecondCap new value (1e10)
     * @param _signedPairPrices signed pair market prices
     */
    function setAbsoluteRatePerSecondCap(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex,
        uint24[] calldata _absoluteRatePerSecondCap,
        IPriceAggregator.SignedPairPrices[] calldata _signedPairPrices
    ) external;

    /**
     * @dev Updates funding theta threshold for pairs
     * @param _collateralIndex index of the collateral
     * @param _pairIndex index of the pair
     * @param _thetaThresholdUsd new value (USD)
     * @param _signedPairPrices signed pair market prices
     */
    function setThetaThresholdUsd(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex,
        uint32[] calldata _thetaThresholdUsd,
        IPriceAggregator.SignedPairPrices[] calldata _signedPairPrices
    ) external;

    /**
     * @dev Enables/disables funding fees for pairs
     * @param _collateralIndex index of the collateral
     * @param _pairIndex index of the pair
     * @param _fundingFeesEnabled new value
     * @param _signedPairPrices signed pair market prices
     */
    function setFundingFeesEnabled(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex,
        bool[] calldata _fundingFeesEnabled,
        IPriceAggregator.SignedPairPrices[] calldata _signedPairPrices
    ) external;

    /**
     * @dev Enables/disables APR multiplier for pairs
     * @param _collateralIndex index of the collateral
     * @param _pairIndex index of the pair
     * @param _aprMultiplierEnabled new value
     * @param _signedPairPrices signed pair market prices
     */
    function setAprMultiplierEnabled(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex,
        bool[] calldata _aprMultiplierEnabled,
        IPriceAggregator.SignedPairPrices[] calldata _signedPairPrices
    ) external;

    /**
     * @dev Updates a pair's borrowing rate % per second
     * @param _collateralIndex index of the collateral
     * @param _pairIndex index of the pair
     * @param _borrowingRatePerSecondP new value (1e10, %)
     * @param _signedPairPrices signed pair market prices
     */
    function setBorrowingRatePerSecondP(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex,
        uint24[] calldata _borrowingRatePerSecondP,
        IPriceAggregator.SignedPairPrices[] calldata _signedPairPrices
    ) external;

    /**
     * @dev Executes pending param update callback using signed prices stored in initial context call
     * @param _paramUpdate param update to execute
     */
    function paramUpdateCallbackWithSignedPrices(IFundingFees.PendingParamUpdate memory _paramUpdate) external;

    /**
     * @dev Stores initial acc funding / borrowing fees for a trade
     * @dev HAS TO BE CALLED when a new trade is opened or when a trade's position size changes (+ store pending holding fees until now separately)
     * @param _trader trader address
     * @param _index index of trade
     * @param _collateralIndex index of collateral
     * @param _pairIndex index of the pair
     * @param _long true if long, false if short
     * @param _currentPairPrice current pair price (1e10)
     */
    function storeTradeInitialAccFees(
        address _trader,
        uint32 _index,
        uint8 _collateralIndex,
        uint16 _pairIndex,
        bool _long,
        uint64 _currentPairPrice
    ) external;

    /**
     * @dev Realizes pending holding fees on an open trade
     * @param _trader trader address
     * @param _index index of trade
     * @param _currentPairPrice current pair price (1e10)
     */
    function realizeHoldingFeesOnOpenTrade(address _trader, uint32 _index, uint64 _currentPairPrice) external;

    /**
     * @dev Stores trade manually realized negative pnl in collateral tokens
     * @param _trader address of trader
     * @param _index index of trade
     * @param _amountCollateral new amount of realized negative pnl in collateral tokens (collateral precision)
     */
    function storeManuallyRealizedNegativePnlCollateral(
        address _trader,
        uint32 _index,
        uint256 _amountCollateral
    ) external;

    /**
     * @dev Realizes pnl on an open trade
     * @param _trader trader address
     * @param _index index of trade
     * @param _pnlCollateral pnl to realize in collateral tokens (collateral precision)
     */
    function realizePnlOnOpenTrade(address _trader, uint32 _index, int256 _pnlCollateral) external;

    /**
     * @dev Realizes trading fees on an open trade
     * @param _trader trader address
     * @param _index index of trade
     * @param _feesCollateral trading fees to charge in collateral tokens (collateral precision)
     * @param _currentPairPrice current pair price (1e10)
     * @return finalFeesCollateral trading fees charged in collateral tokens (collateral precision), same as input unless liquidated then 0
     */
    function realizeTradingFeesOnOpenTrade(
        address _trader,
        uint32 _index,
        uint256 _feesCollateral,
        uint64 _currentPairPrice
    ) external returns (uint256 finalFeesCollateral);

    /**
     * @dev Decreases a trade's realized pnl and available collateral in diamond proportionally to size delta ratio over full size (for partial closes with collateral delta > 0)
     * @param _trader trader address
     * @param _index index of trade
     * @param _positionSizeCollateralDelta position size collateral delta (collateral precision)
     * @param _existingPositionSizeCollateral existing position size collateral (collateral precision)
     * @param _newCollateralAmount new trade collateral amount after partial close (collateral precision)
     */
    function downscaleTradeFeesData(
        address _trader,
        uint32 _index,
        uint256 _positionSizeCollateralDelta,
        uint256 _existingPositionSizeCollateral,
        uint256 _newCollateralAmount
    ) external;

    /**
     * @dev Stores already transferred negative pnl for a trade (for partial closes with leverage delta > 0 and negative PnL)
     * @param _trader address of trader
     * @param _index index of trade
     * @param _deltaCollateral delta in collateral tokens to store (collateral precision)
     */
    function storeAlreadyTransferredNegativePnl(address _trader, uint32 _index, uint256 _deltaCollateral) external;

    /**
     * @dev Stores virtual available collateral in diamond to compensate if available in diamond would be < 0 without it (for collateral withdrawals)
     * @param _trader address of trader
     * @param _index index of trade
     * @param _newTradeCollateralAmount new trade collateral amount (collateral precision)
     */
    function storeVirtualAvailableCollateralInDiamond(
        address _trader,
        uint32 _index,
        uint256 _newTradeCollateralAmount
    ) external;

    /**
     * @dev Stores UI partial close realized pnl for a trade
     * @param _trader address of trader
     * @param _index index of trade
     * @param _deltaCollateral raw pnl realized in collateral tokens (collateral precision)
     */
    function storeUiRealizedPnlPartialCloseCollateral(address _trader, uint32 _index, int256 _deltaCollateral) external;

    /**
     * @dev Stores UI withdrawn pnl for a trade
     * @param _trader address of trader
     * @param _index index of trade
     * @param _deltaCollateral pnl withdrawn in collateral tokens (collateral precision)
     */
    function storeUiPnlWithdrawnCollateral(address _trader, uint32 _index, uint256 _deltaCollateral) external;

    /**
     * @dev Stores UI realized trading fees for a trade
     * @param _trader address of trader
     * @param _index index of trade
     * @param _deltaCollateral realized trading fees in collateral tokens (collateral precision)
     */
    function storeUiRealizedTradingFeesCollateral(address _trader, uint32 _index, uint256 _deltaCollateral) external;

    /**
     * @dev Returns pending funding fees in collateral tokens for an open trade (collateral precision)
     * @param _trader trader address
     * @param _index index of trade
     * @param _currentPairPrice current pair price (1e10)
     */
    function getTradeFundingFeesCollateral(
        address _trader,
        uint32 _index,
        uint64 _currentPairPrice
    ) external view returns (int256);

    /**
     * @dev Returns pending borrowing fees in collateral tokens for an open trade (collateral precision)
     * @param _trader trader address
     * @param _index index of trade
     * @param _currentPairPrice current pair price (1e10)
     */
    function getTradeBorrowingFeesCollateral(
        address _trader,
        uint32 _index,
        uint64 _currentPairPrice
    ) external view returns (uint256);

    /**
     * @dev Returns trade pending funding fees, borrowing fees, old borrowing fees, and total holding fees in collateral tokens (collateral precision)
     * @param _trader trader address
     * @param _index index of trade
     * @param _currentPairPrice current pair price (1e10)
     * @return tradeHoldingFees trade holding fees in collateral tokens (collateral precision)
     */
    function getTradePendingHoldingFeesCollateral(
        address _trader,
        uint32 _index,
        uint64 _currentPairPrice
    ) external view returns (IFundingFees.TradeHoldingFees memory tradeHoldingFees);

    /**
     * @dev Returns pending acc funding fees for a pair
     * @param _collateralIndex index of the collateral
     * @param _pairIndex index of the pair
     * @param _currentPairPrice current pair price (1e10)
     * @return accFundingFeeLongP pending acc funding fee % for longs (1e20)
     * @return accFundingFeeShortP pending acc funding fee % for shorts (1e20)
     * @return currentFundingRatePerSecondP current funding rate % per second (1e18)
     */
    function getPairPendingAccFundingFees(
        uint8 _collateralIndex,
        uint16 _pairIndex,
        uint64 _currentPairPrice
    ) external view returns (int128 accFundingFeeLongP, int128 accFundingFeeShortP, int56 currentFundingRatePerSecondP);

    /**
     * @dev Returns pending acc borrowing fees for a pair
     * @param _collateralIndex index of the collateral
     * @param _pairIndex index of the pair
     * @param _currentPairPrice current pair price (1e10)
     * @return accBorrowingFeeP pending acc borrowing fee % (1e20)
     */
    function getPairPendingAccBorrowingFees(
        uint8 _collateralIndex,
        uint16 _pairIndex,
        uint64 _currentPairPrice
    ) external view returns (uint128 accBorrowingFeeP);

    /**
     * @dev Returns max skew in collateral tokens for a pair (1e10)
     * @param _collateralIndex index of the collateral
     * @param _pairIndex index of the pair
     */
    function getMaxSkewCollateral(uint8 _collateralIndex, uint16 _pairIndex) external view returns (uint80);

    /**
     * @dev Returns max skew in collateral tokens for pairs (1e10)
     * @param _collateralIndex index of the collateral
     * @param _pairIndex index of the pair
     */
    function getPairGlobalParamsArray(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex
    ) external view returns (PairGlobalParams[] memory);

    /**
     * @dev Returns funding fee params for pairs
     * @param _collateralIndex index of the collateral
     * @param _pairIndex index of the pair
     */
    function getPairFundingFeeParams(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex
    ) external view returns (IFundingFees.FundingFeeParams[] memory);

    /**
     * @dev Returns borrowing fee params for pairs
     * @param _collateralIndex index of the collateral
     * @param _pairIndex index of the pair
     */
    function getPairBorrowingFeeParams(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex
    ) external view returns (IFundingFees.BorrowingFeeParams[] memory);

    /**
     * @dev Returns funding fee data for pairs
     * @param _collateralIndex index of the collateral
     * @param _pairIndex index of the pair
     */
    function getPairFundingFeeData(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex
    ) external view returns (IFundingFees.PairFundingFeeData[] memory);

    /**
     * @dev Returns borrowing fee data for pairs
     * @param _collateralIndex index of the collateral
     * @param _pairIndex index of the pair
     */
    function getPairBorrowingFeeData(
        uint8[] calldata _collateralIndex,
        uint16[] calldata _pairIndex
    ) external view returns (IFundingFees.PairBorrowingFeeData[] memory);

    /**
     * @dev Returns fees data for trade
     * @param _trader trader address
     * @param _index trade index
     */
    function getTradeFeesData(address _trader, uint32 _index) external view returns (IFundingFees.TradeFeesData memory);

    /**
     * @dev Returns fees data for trades
     * @param _trader trader address
     * @param _index trade index
     */
    function getTradeFeesDataArray(
        address[] calldata _trader,
        uint32[] calldata _index
    ) external view returns (IFundingFees.TradeFeesData[] memory);

    /**
     * @dev Returns UI realized pnl data for trades
     * @param _trader trader address
     * @param _index trade index
     */
    function getTradeUiRealizedPnlDataArray(
        address[] calldata _trader,
        uint32[] calldata _index
    ) external view returns (IFundingFees.UiRealizedPnlData[] memory);

    /**
     * @dev Returns trade manually realized negative pnl in collateral tokens (collateral precision)
     * @param _trader address of trader
     * @param _index index of trade
     */
    function getTradeManuallyRealizedNegativePnlCollateral(
        address _trader,
        uint32 _index
    ) external view returns (uint256);

    /**
     * @dev Returns pending param updates
     * @param _index update index
     */
    function getPendingParamUpdates(
        uint32[] calldata _index
    ) external view returns (IFundingFees.PendingParamUpdate[] memory);

    /**
     * @dev Returns realized pnl in collateral tokens for an open trade
     * @param _trader trader address
     * @param _index trade index
     * @return realizedPnlCollateral realized pnl in collateral tokens (collateral precision)
     * @return realizedTradingFeesCollateral realized trading fees in collateral tokens (collateral precision)
     * @return totalRealizedPnlCollateral total realized pnl in collateral tokens (collateral precision)
     */
    function getTradeRealizedPnlCollateral(
        address _trader,
        uint32 _index
    )
        external
        view
        returns (
            int256 realizedPnlCollateral,
            uint256 realizedTradingFeesCollateral,
            int256 totalRealizedPnlCollateral
        );

    /**
     * @dev Returns realized trading fees in collateral tokens for an open trade (collateral precision)
     * @param _trader trader address
     * @param _index trade index
     */
    function getTradeRealizedTradingFeesCollateral(address _trader, uint32 _index) external view returns (uint256);

    /**
     * @dev Emitted when a pair's max skew collateral is updated
     * @param collateralIndex index of the collateral
     * @param pairIndex index of the pair
     * @param maxSkewCollateral new value (1e10)
     */
    event MaxSkewCollateralUpdated(uint8 indexed collateralIndex, uint16 indexed pairIndex, uint80 maxSkewCollateral);

    /**
     * @dev Emitted when a pair's skew coefficient per year is updated
     * @param collateralIndex index of the collateral
     * @param pairIndex index of the pair
     * @param skewCoefficientPerYear new value (1e26)
     */
    event SkewCoefficientPerYearUpdated(
        uint8 indexed collateralIndex,
        uint16 indexed pairIndex,
        uint112 skewCoefficientPerYear
    );

    /**
     * @dev Emitted when a pair's absolute velocity per year cap is updated
     * @param collateralIndex index of the collateral
     * @param pairIndex index of the pair
     * @param absoluteVelocityPerYearCap new value (1e7)
     */
    event AbsoluteVelocityPerYearCapUpdated(
        uint8 indexed collateralIndex,
        uint16 indexed pairIndex,
        uint24 absoluteVelocityPerYearCap
    );

    /**
     * @dev Emitted when a pair's funding rate % per second absolute cap is updated
     * @param collateralIndex index of the collateral
     * @param pairIndex index of the pair
     * @param absoluteRatePerSecondCap new value (1e10)
     */
    event AbsoluteRatePerSecondCapUpdated(
        uint8 indexed collateralIndex,
        uint16 indexed pairIndex,
        uint24 absoluteRatePerSecondCap
    );

    /**
     * @dev Emitted when a pair's theta USD threshold is updated
     * @param collateralIndex index of the collateral
     * @param pairIndex index of the pair
     * @param thetaThresholdUsd new value (USD)
     */
    event ThetaThresholdUsdUpdated(uint8 indexed collateralIndex, uint16 indexed pairIndex, uint32 thetaThresholdUsd);

    /**
     * @dev Emitted when a pair's funding fees are enabled/disabled
     * @param collateralIndex index of the collateral
     * @param pairIndex index of the pair
     * @param fundingFeesEnabled new value
     */
    event FundingFeesEnabledUpdated(uint8 indexed collateralIndex, uint16 indexed pairIndex, bool fundingFeesEnabled);

    /**
     * @dev Emitted when a pair's APR multiplier is enabled/disabled
     * @param collateralIndex index of the collateral
     * @param pairIndex index of the pair
     * @param aprMultiplierEnabled new value
     */
    event AprMultiplierEnabledUpdated(
        uint8 indexed collateralIndex,
        uint16 indexed pairIndex,
        bool aprMultiplierEnabled
    );

    /**
     * @dev Emitted when a pair's borrowing rate % per second is updated
     * @param collateralIndex index of the collateral
     * @param pairIndex index of the pair
     * @param borrowingRatePerSecondP new value (1e10, %)
     */
    event BorrowingRatePerSecondPUpdated(
        uint8 indexed collateralIndex,
        uint16 indexed pairIndex,
        uint24 borrowingRatePerSecondP
    );

    /**
     * @dev Emitted when a pair's pending acc funding fees are stored
     * @param collateralIndex index of the collateral
     * @param pairIndex index of the pair
     * @param data pair funding fee data
     */
    event PendingAccFundingFeesStored(
        uint8 indexed collateralIndex,
        uint16 indexed pairIndex,
        IFundingFees.PairFundingFeeData data
    );

    /**
     * @dev Emitted when a pair's pending acc borrowing fees are stored
     * @param collateralIndex index of the collateral
     * @param pairIndex index of the pair
     * @param data pair borrowing fee data
     */
    event PendingAccBorrowingFeesStored(
        uint8 indexed collateralIndex,
        uint16 indexed pairIndex,
        IFundingFees.PairBorrowingFeeData data
    );

    /**
     * @dev Emitted when a trade's initial acc fees are stored or reset
     * @param trader trader address
     * @param index index of trade
     * @param collateralIndex index of collateral
     * @param pairIndex index of the pair
     * @param long true if long, false if short
     * @param currentPairPrice current pair price (1e10)
     * @param newInitialAccFundingFeeP new initial acc funding fee % (1e20)
     * @param newInitialAccBorrowingFeeP new initial acc borrowing fee % (1e20)
     */
    event TradeInitialAccFeesStored(
        address indexed trader,
        uint32 indexed index,
        uint8 collateralIndex,
        uint16 pairIndex,
        bool long,
        uint64 currentPairPrice,
        int128 newInitialAccFundingFeeP,
        uint128 newInitialAccBorrowingFeeP
    );

    /**
     * @dev Emitted when holding fees are realized (earned) on an open trade
     * @param collateralIndex index of the collateral
     * @param trader trader address
     * @param index index of trade
     * @param currentPairPrice current pair price (1e10)
     * @param tradeHoldingFees trade holding fees in collateral tokens (collateral precision)
     * @param newRealizedPnlCollateral new realized pnl value for trade in collateral tokens (collateral precision)
     */
    event HoldingFeesRealizedOnTrade(
        uint8 indexed collateralIndex,
        address indexed trader,
        uint32 indexed index,
        uint64 currentPairPrice,
        IFundingFees.TradeHoldingFees tradeHoldingFees,
        int256 newRealizedPnlCollateral
    );

    /**
     * @dev Emitted when holding fees are realized (charged) on an open trade
     * @param collateralIndex index of the collateral
     * @param trader trader address
     * @param index index of trade
     * @param currentPairPrice current pair price (1e10)
     * @param tradeHoldingFees trade holding fees in collateral tokens (collateral precision)
     * @param availableCollateralInDiamond trade available collateral in diamond contract (collateral precision)
     * @param amountSentToVaultCollateral amount sent to vault in collateral tokens (collateral precision)
     * @param newRealizedTradingFeesCollateral new realized trading fees in collateral tokens (collateral precision)
     * @param newRealizedPnlCollateral new realized pnl in collateral tokens (collateral precision)
     */
    event HoldingFeesChargedOnTrade(
        uint8 indexed collateralIndex,
        address indexed trader,
        uint32 indexed index,
        uint64 currentPairPrice,
        IFundingFees.TradeHoldingFees tradeHoldingFees,
        uint256 availableCollateralInDiamond,
        uint256 amountSentToVaultCollateral,
        uint256 newRealizedTradingFeesCollateral,
        int256 newRealizedPnlCollateral
    );

    /**
     * @dev Emitted when negative pnl is manually realized on an open trade
     * @param trader trader address
     * @param index trade index
     * @param newManuallyRealizedNegativePnlCollateral new manually realized negative pnl in collateral tokens (collateral precision)
     */
    event ManuallyRealizedNegativePnlCollateralStored(
        address indexed trader,
        uint32 indexed index,
        uint128 newManuallyRealizedNegativePnlCollateral
    );

    /**
     * @dev Emitted when pnl is realized on an open trade
     * @param trader trader address
     * @param index index of trade
     * @param pnlCollateral pnl realized in collateral tokens (collateral precision)
     * @param newRealizedPnlCollateral new realized pnl value for trade in collateral tokens (collateral precision)
     */
    event PnlRealizedOnOpenTrade(
        address indexed trader,
        uint32 indexed index,
        int256 pnlCollateral,
        int256 newRealizedPnlCollateral
    );

    /**
     * @dev Emitted when trading fees are realized on an open trade
     * @param collateralIndex index of the collateral
     * @param trader trader address
     * @param index index of trade
     * @param tradingFeesCollateral trading fees input in collateral tokens (collateral precision)
     * @param finalTradingFeesCollateral trading fees realized in collateral tokens (collateral precision)
     * @param newRealizedFeesCollateral new realized fees value for trade in collateral tokens (collateral precision)
     * @param newRealizedPnlCollateral new realized pnl value for trade in collateral tokens (collateral precision)
     * @param amountSentFromVaultCollateral amount sent from vault in collateral tokens (collateral precision)
     */
    event TradingFeesRealized(
        uint8 indexed collateralIndex,
        address indexed trader,
        uint32 indexed index,
        uint256 tradingFeesCollateral,
        uint256 finalTradingFeesCollateral,
        uint256 newRealizedFeesCollateral,
        int256 newRealizedPnlCollateral,
        uint256 amountSentFromVaultCollateral
    );

    /**
     * @dev Emitted when a trade's realized pnl and available in diamond is scaled down
     * @param trader trader address
     * @param index trade index
     * @param positionSizeCollateralDelta position size collateral delta (collateral precision)
     * @param existingPositionSizeCollateral existing position size collateral (collateral precision)
     * @param newCollateralAmount new trade collateral amount (collateral precision)
     * @param newTradeFeesData new trade fees data
     */
    event TradeFeesDataDownscaled(
        address indexed trader,
        uint32 indexed index,
        uint256 positionSizeCollateralDelta,
        uint256 existingPositionSizeCollateral,
        uint256 newCollateralAmount,
        IFundingFees.TradeFeesData newTradeFeesData
    );

    /**
     * @dev Emitted when a trade's already transferred negative pnl is stored
     * @param trader trader address
     * @param index trade index
     * @param deltaCollateral delta in collateral tokens to store (collateral precision)
     * @param newAlreadyTransferredNegativePnlCollateral new already transferred negative pnl in collateral tokens (collateral precision)
     */
    event AlreadyTransferredNegativePnlStored(
        address indexed trader,
        uint32 indexed index,
        uint256 deltaCollateral,
        uint128 newAlreadyTransferredNegativePnlCollateral
    );

    /**
     * @dev Emitted when a trade's virtual available collateral in diamond is stored
     * @param trader trader address
     * @param index trade index
     * @param newTradeCollateralAmount new trade collateral amount (collateral precision)
     * @param currentManuallyRealizedNegativePnlCollateral current manually realized negative pnl collateral value (collateral precision)
     * @param manuallyRealizedNegativePnlCollateralCapped whether manually realized negative pnl collateral value was capped (collateral precision)
     * @param virtualAvailableCollateralInDiamondDelta virtual available collateral in diamond delta to keep available collateral in diamond >= 0 (collateral precision)
     * @param newVirtualAvailableCollateralInDiamond new virtual available collateral in diamond (collateral precision)
     */
    event VirtualAvailableCollateralInDiamondStored(
        address indexed trader,
        uint32 indexed index,
        uint256 newTradeCollateralAmount,
        uint256 currentManuallyRealizedNegativePnlCollateral,
        bool manuallyRealizedNegativePnlCollateralCapped,
        uint256 virtualAvailableCollateralInDiamondDelta,
        uint256 newVirtualAvailableCollateralInDiamond
    );

    /**
     * @dev Emitted when a param update is requested
     * @param collateralIndex index of the collateral
     * @param pairIndex index of the pair
     * @param updateType type of update
     * @param newValue new value
     */
    event ParamUpdateRequested(
        uint8 indexed collateralIndex,
        uint16 indexed pairIndex,
        IFundingFees.ParamUpdateType updateType,
        uint224 newValue
    );
}
