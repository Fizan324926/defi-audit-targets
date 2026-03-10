// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../interfaces/IGNSMultiCollatDiamond.sol";

import "./StorageUtils.sol";
import "./ConstantsUtils.sol";
import "./ChainUtils.sol";
import "./TradingCommonUtils.sol";
import "./TradingStorageUtils.sol";

/**
 * @dev GNSPriceImpact facet external library
 *
 * This is a library to help manage a price impact decay algorithm .
 *
 * When a trade is placed, OI is added to the window corresponding to time of open.
 * When a trade is removed, OI is removed from the window corresponding to time of open.
 *
 * When calculating price impact, only the most recent X windows are taken into account.
 *
 */
library PriceImpactUtils {
    uint48 private constant MAX_WINDOWS_COUNT = 5;
    uint48 private constant MAX_WINDOWS_DURATION = 10 minutes;
    uint48 private constant MIN_WINDOWS_DURATION = 1 minutes;
    uint256 private constant MAX_PROTECTION_CLOSE_FACTOR_DURATION = 10 minutes;
    uint256 private constant MIN_NEG_PNL_CUMUL_VOL_MULTIPLIER = (20 * ConstantsUtils.P_10) / 100;
    uint16 private constant MAX_CUMUL_VOL_PRICE_IMPACT_MULTIPLIER = 3e3;
    uint16 private constant MAX_FIXED_SPREAD_P = 0.1e3;
    uint256 private constant MAX_SKEW_DEPTH_DIFF_P = 25 * 1e10;
    uint256 private constant DEPTH_BANDS_COUNT = 30;
    uint256 private constant DEPTH_BANDS_PER_SLOT1 = 14;
    uint256 private constant HUNDRED_P_BPS = 1e4;

    /**
     * @dev Validates new windowsDuration value
     */
    modifier validWindowsDuration(uint48 _windowsDuration) {
        if (_windowsDuration < MIN_WINDOWS_DURATION || _windowsDuration > MAX_WINDOWS_DURATION)
            revert IPriceImpactUtils.WrongWindowsDuration();
        _;
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function initializePriceImpact(
        uint48 _windowsDuration,
        uint48 _windowsCount
    ) external validWindowsDuration(_windowsDuration) {
        if (_windowsCount > MAX_WINDOWS_COUNT) revert IGeneralErrors.AboveMax();

        _getStorage().oiWindowsSettings = IPriceImpact.OiWindowsSettings({
            startTs: uint48(block.timestamp),
            windowsDuration: _windowsDuration,
            windowsCount: _windowsCount
        });

        emit IPriceImpactUtils.OiWindowsSettingsInitialized(_windowsDuration, _windowsCount);
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function initializeNegPnlCumulVolMultiplier(uint40 _negPnlCumulVolMultiplier) external {
        setNegPnlCumulVolMultiplier(_negPnlCumulVolMultiplier);
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function initializePairFactors(
        uint16[] calldata _pairIndices,
        uint40[] calldata _protectionCloseFactors,
        uint32[] calldata _protectionCloseFactorBlocks,
        uint40[] calldata _cumulativeFactors
    ) external {
        setProtectionCloseFactors(_pairIndices, _protectionCloseFactors);
        setProtectionCloseFactorBlocks(_pairIndices, _protectionCloseFactorBlocks);
        setCumulativeFactors(_pairIndices, _cumulativeFactors);
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function setPriceImpactWindowsCount(uint48 _newWindowsCount) external {
        IPriceImpact.OiWindowsSettings storage settings = _getStorage().oiWindowsSettings;

        if (_newWindowsCount > MAX_WINDOWS_COUNT) revert IGeneralErrors.AboveMax();

        settings.windowsCount = _newWindowsCount;

        emit IPriceImpactUtils.PriceImpactWindowsCountUpdated(_newWindowsCount);
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function setPriceImpactWindowsDuration(
        uint48 _newWindowsDuration,
        uint256 _pairsCount
    ) external validWindowsDuration(_newWindowsDuration) {
        IPriceImpact.PriceImpactStorage storage priceImpactStorage = _getStorage();
        IPriceImpact.OiWindowsSettings storage settings = priceImpactStorage.oiWindowsSettings;

        if (settings.windowsCount > 0) {
            _transferPriceImpactOiForPairs(
                _pairsCount,
                priceImpactStorage.windows[settings.windowsDuration],
                priceImpactStorage.windows[_newWindowsDuration],
                settings,
                _newWindowsDuration
            );
        }

        settings.windowsDuration = _newWindowsDuration;

        emit IPriceImpactUtils.PriceImpactWindowsDurationUpdated(_newWindowsDuration);
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function setNegPnlCumulVolMultiplier(uint40 _negPnlCumulVolMultiplier) public {
        if (_negPnlCumulVolMultiplier < MIN_NEG_PNL_CUMUL_VOL_MULTIPLIER) revert IGeneralErrors.BelowMin();
        if (_negPnlCumulVolMultiplier > ConstantsUtils.P_10) revert IGeneralErrors.AboveMax();

        _getStorage().negPnlCumulVolMultiplier = _negPnlCumulVolMultiplier;

        emit IPriceImpactUtils.NegPnlCumulVolMultiplierUpdated(_negPnlCumulVolMultiplier);
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function setProtectionCloseFactorWhitelist(address[] calldata _traders, bool[] calldata _whitelisted) external {
        if (_traders.length != _whitelisted.length) revert IGeneralErrors.WrongLength();

        IPriceImpact.PriceImpactStorage storage s = _getStorage();

        for (uint256 i = 0; i < _traders.length; ++i) {
            (address trader, bool whitelisted) = (_traders[i], _whitelisted[i]);

            if (trader == address(0)) revert IGeneralErrors.ZeroAddress();

            s.protectionCloseFactorWhitelist[trader] = whitelisted;

            emit IPriceImpactUtils.ProtectionCloseFactorWhitelistUpdated(trader, whitelisted);
        }
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function setUserPriceImpact(
        address[] calldata _traders,
        uint16[] calldata _pairIndices,
        uint16[] calldata _cumulVolPriceImpactMultipliers,
        uint16[] calldata _fixedSpreadPs
    ) external {
        if (
            _traders.length != _pairIndices.length ||
            _traders.length != _cumulVolPriceImpactMultipliers.length ||
            _traders.length != _fixedSpreadPs.length
        ) revert IGeneralErrors.WrongLength();

        IPriceImpact.PriceImpactStorage storage s = _getStorage();

        for (uint256 i = 0; i < _traders.length; ++i) {
            (address trader, uint16 pairIndex, uint16 cumulVolPriceImpactMultiplier, uint16 fixedSpreadP) = (
                _traders[i],
                _pairIndices[i],
                _cumulVolPriceImpactMultipliers[i],
                _fixedSpreadPs[i]
            );

            if (trader == address(0)) revert IGeneralErrors.ZeroAddress();
            if (cumulVolPriceImpactMultiplier > MAX_CUMUL_VOL_PRICE_IMPACT_MULTIPLIER) revert IGeneralErrors.AboveMax();
            if (fixedSpreadP > MAX_FIXED_SPREAD_P) revert IGeneralErrors.AboveMax();

            IPriceImpact.UserPriceImpact storage userPriceImpact = s.userPriceImpact[trader][pairIndex];

            userPriceImpact.cumulVolPriceImpactMultiplier = cumulVolPriceImpactMultiplier;
            userPriceImpact.fixedSpreadP = fixedSpreadP;

            emit IPriceImpactUtils.UserPriceImpactUpdated(
                trader,
                pairIndex,
                cumulVolPriceImpactMultiplier,
                fixedSpreadP
            );
        }
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function setPairDepthBands(
        uint256[] calldata _indices,
        IPriceImpact.PairDepthBands[] calldata _depthBands
    ) external {
        if (_indices.length != _depthBands.length) {
            revert IGeneralErrors.WrongLength();
        }

        IPriceImpact.PriceImpactStorage storage s = _getStorage();

        for (uint256 i; i < _indices.length; ++i) {
            uint256 prevLiquidityAboveBps;
            uint256 prevLiquidityBelowBps;
            uint256 maxLiquidityAboveBps;
            uint256 maxLiquidityBelowBps;

            IPriceImpact.PairDepthBands calldata band = _depthBands[i];

            for (uint256 j; j < DEPTH_BANDS_COUNT; j++) {
                uint256 currentLiquidityAboveBps = _getBandValue(band.aboveSlot1, band.aboveSlot2, j);
                uint256 currentLiquidityBelowBps = _getBandValue(band.belowSlot1, band.belowSlot2, j);

                // Ensure current liquidity percentage is >= previous liquidity percentage (non-decreasing)
                if (
                    currentLiquidityAboveBps < prevLiquidityAboveBps || currentLiquidityBelowBps < prevLiquidityBelowBps
                ) revert IPriceImpactUtils.WrongDepthBandsOrder();

                // Ensure no value exceeds 100%
                if (currentLiquidityAboveBps > HUNDRED_P_BPS || currentLiquidityBelowBps > HUNDRED_P_BPS) {
                    revert IPriceImpactUtils.DepthBandsAboveMax();
                }

                prevLiquidityAboveBps = currentLiquidityAboveBps;
                prevLiquidityBelowBps = currentLiquidityBelowBps;

                // Track maximum values
                if (currentLiquidityAboveBps > maxLiquidityAboveBps) maxLiquidityAboveBps = currentLiquidityAboveBps;
                if (currentLiquidityBelowBps > maxLiquidityBelowBps) maxLiquidityBelowBps = currentLiquidityBelowBps;
            }

            // Ensure that 100% is reached (last band should be 100%)
            if (maxLiquidityAboveBps != HUNDRED_P_BPS || maxLiquidityBelowBps != HUNDRED_P_BPS) {
                revert IPriceImpactUtils.DepthBandsIncomplete();
            }

            s.pairDepthBands[_indices[i]] = band;

            emit IPriceImpactUtils.PairDepthBandsUpdated(
                _indices[i],
                band.aboveSlot1,
                band.aboveSlot2,
                band.belowSlot1,
                band.belowSlot2
            );
        }
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function setDepthBandsMapping(uint256 _slot1, uint256 _slot2) external {
        uint256 prevOffsetPpm;

        for (uint256 i; i < DEPTH_BANDS_COUNT; i++) {
            uint256 currentOffsetPpm = _getBandValue(_slot1, _slot2, i);

            // Ensure current offset is >= previous offset (non-decreasing)
            if (currentOffsetPpm < prevOffsetPpm) revert IPriceImpactUtils.WrongDepthBandsOrder();

            prevOffsetPpm = currentOffsetPpm;
        }

        // Store the mapping after validation
        IPriceImpact.DepthBandsMapping storage mapping_ = _getStorage().depthBandsMapping;
        mapping_.slot1 = _slot1;
        mapping_.slot2 = _slot2;

        emit IPriceImpactUtils.DepthBandsMappingUpdated(_slot1, _slot2);
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function setPairSkewDepths(
        uint8[] calldata _collateralIndices,
        uint16[] calldata _pairIndices,
        uint256[] calldata _depths
    ) external {
        if (_collateralIndices.length != _pairIndices.length || _pairIndices.length != _depths.length)
            revert IGeneralErrors.WrongLength();

        IPriceImpact.PriceImpactStorage storage s = _getStorage();

        for (uint256 i = 0; i < _collateralIndices.length; ++i) {
            uint256 existingDepth = s.pairSkewDepths[_collateralIndices[i]][_pairIndices[i]];
            uint256 newDepth = _depths[i];

            uint256 depthDiffP = existingDepth > 0
                ? ((newDepth > existingDepth ? newDepth - existingDepth : existingDepth - newDepth) * 100 * 1e10) /
                    existingDepth
                : 0;

            if (newDepth > 0 && depthDiffP > MAX_SKEW_DEPTH_DIFF_P) revert IGeneralErrors.WrongParams();

            s.pairSkewDepths[_collateralIndices[i]][_pairIndices[i]] = newDepth;

            emit IPriceImpactUtils.OnePercentSkewDepthUpdated(_collateralIndices[i], _pairIndices[i], newDepth);
        }
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function setProtectionCloseFactors(
        uint16[] calldata _pairIndices,
        uint40[] calldata _protectionCloseFactors
    ) public {
        if (_pairIndices.length == 0 || _protectionCloseFactors.length != _pairIndices.length)
            revert IGeneralErrors.WrongLength();

        IPriceImpact.PriceImpactStorage storage s = _getStorage();

        for (uint256 i = 0; i < _protectionCloseFactors.length; ++i) {
            if (_protectionCloseFactors[i] < ConstantsUtils.P_10) revert IGeneralErrors.BelowMin();

            s.pairFactors[_pairIndices[i]].protectionCloseFactor = _protectionCloseFactors[i];

            emit IPriceImpactUtils.ProtectionCloseFactorUpdated(_pairIndices[i], _protectionCloseFactors[i]);
        }
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function setProtectionCloseFactorBlocks(
        uint16[] calldata _pairIndices,
        uint32[] calldata _protectionCloseFactorBlocks
    ) public {
        if (_pairIndices.length == 0 || _protectionCloseFactorBlocks.length != _pairIndices.length)
            revert IGeneralErrors.WrongLength();

        IPriceImpact.PriceImpactStorage storage s = _getStorage();

        for (uint256 i = 0; i < _protectionCloseFactorBlocks.length; ++i) {
            uint32 protectionCloseFactorBlocks = _protectionCloseFactorBlocks[i];

            if (
                ChainUtils.convertBlocksToSeconds(uint256(protectionCloseFactorBlocks)) >
                MAX_PROTECTION_CLOSE_FACTOR_DURATION
            ) revert IGeneralErrors.AboveMax();

            s.pairFactors[_pairIndices[i]].protectionCloseFactorBlocks = protectionCloseFactorBlocks;

            emit IPriceImpactUtils.ProtectionCloseFactorBlocksUpdated(_pairIndices[i], protectionCloseFactorBlocks);
        }
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function setCumulativeFactors(uint16[] calldata _pairIndices, uint40[] calldata _cumulativeFactors) public {
        if (_pairIndices.length == 0 || _cumulativeFactors.length != _pairIndices.length)
            revert IGeneralErrors.WrongLength();

        IPriceImpact.PriceImpactStorage storage s = _getStorage();

        for (uint256 i = 0; i < _cumulativeFactors.length; ++i) {
            if (_cumulativeFactors[i] == 0) revert IGeneralErrors.ZeroValue();

            s.pairFactors[_pairIndices[i]].cumulativeFactor = _cumulativeFactors[i];

            emit IPriceImpactUtils.CumulativeFactorUpdated(_pairIndices[i], _cumulativeFactors[i]);
        }
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function setExemptOnOpen(uint16[] calldata _pairIndices, bool[] calldata _exemptOnOpen) external {
        if (_pairIndices.length == 0 || _exemptOnOpen.length != _pairIndices.length)
            revert IGeneralErrors.WrongLength();

        IPriceImpact.PriceImpactStorage storage s = _getStorage();

        for (uint256 i = 0; i < _exemptOnOpen.length; ++i) {
            s.pairFactors[_pairIndices[i]].exemptOnOpen = _exemptOnOpen[i];

            emit IPriceImpactUtils.ExemptOnOpenUpdated(_pairIndices[i], _exemptOnOpen[i]);
        }
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function setExemptAfterProtectionCloseFactor(
        uint16[] calldata _pairIndices,
        bool[] calldata _exemptAfterProtectionCloseFactor
    ) external {
        if (_pairIndices.length == 0 || _exemptAfterProtectionCloseFactor.length != _pairIndices.length)
            revert IGeneralErrors.WrongLength();

        IPriceImpact.PriceImpactStorage storage s = _getStorage();

        for (uint256 i = 0; i < _exemptAfterProtectionCloseFactor.length; ++i) {
            s.pairFactors[_pairIndices[i]].exemptAfterProtectionCloseFactor = _exemptAfterProtectionCloseFactor[i];

            emit IPriceImpactUtils.ExemptAfterProtectionCloseFactorUpdated(
                _pairIndices[i],
                _exemptAfterProtectionCloseFactor[i]
            );
        }
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function addPriceImpactOpenInterest(
        address _trader,
        uint32 _index,
        uint256 _oiDeltaCollateral,
        bool _open,
        bool _isPnlPositive
    ) internal {
        // 1. Prepare variables
        IPriceImpact.OiWindowsSettings storage settings = _getStorage().oiWindowsSettings;
        ITradingStorage.Trade memory trade = TradingCommonUtils.getTrade(_trader, _index);
        ITradingStorage.TradeInfo storage tradeInfo = TradingStorageUtils._getStorage().tradeInfos[_trader][_index];

        uint256 currentWindowId = _getCurrentWindowId(settings);
        uint256 currentCollateralPriceUsd = _getMultiCollatDiamond().getCollateralPriceUsd(trade.collateralIndex);

        uint128 oiDeltaUsd = uint128(
            (TradingCommonUtils.convertCollateralToUsd(
                _oiDeltaCollateral,
                _getMultiCollatDiamond().getCollateral(trade.collateralIndex).precisionDelta,
                currentCollateralPriceUsd
            ) * (!_open && !_isPnlPositive ? _getStorage().negPnlCumulVolMultiplier : ConstantsUtils.P_10)) /
                ConstantsUtils.P_10
        );

        // 2. Add OI to current window
        IPriceImpact.PairOi storage currentWindow = _getStorage().windows[settings.windowsDuration][trade.pairIndex][
            currentWindowId
        ];
        bool long = (trade.long && _open) || (!trade.long && !_open);

        if (long) {
            currentWindow.oiLongUsd += oiDeltaUsd;
        } else {
            currentWindow.oiShortUsd += oiDeltaUsd;
        }

        // 3. Update trade info
        tradeInfo.lastOiUpdateTs = uint48(block.timestamp);
        tradeInfo.collateralPriceUsd = uint48(currentCollateralPriceUsd);

        emit IPriceImpactUtils.PriceImpactOpenInterestAdded(
            IPriceImpact.OiWindowUpdate(
                _trader,
                _index,
                settings.windowsDuration,
                trade.pairIndex,
                currentWindowId,
                long,
                _open,
                _isPnlPositive,
                oiDeltaUsd
            )
        );
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function updatePairOiAfterV10(
        uint8 _collateralIndex,
        uint16 _pairIndex,
        uint256 _oiDeltaCollateral,
        uint256 _oiDeltaToken,
        bool _open,
        bool _long
    ) internal {
        IPriceImpact.PairOiCollateral memory pairOiCollateral = _getStorage().pairOiAfterV10Collateral[
            _collateralIndex
        ][_pairIndex];
        IPriceImpact.PairOiToken memory pairOiToken = _getStorage().pairOiAfterV10Token[_collateralIndex][_pairIndex];

        uint128 oiDeltaCollateral = uint128(_oiDeltaCollateral);
        uint128 oiDeltaToken = uint128(_oiDeltaToken);

        // Doesn't revert if new OI < 0, might happen due to rounding
        if (_long) {
            int128 newOiLongCollateral = int128(pairOiCollateral.oiLongCollateral) +
                int128(oiDeltaCollateral) *
                (_open ? int128(1) : int128(-1));
            pairOiCollateral.oiLongCollateral = uint128(newOiLongCollateral > 0 ? newOiLongCollateral : int128(0));

            int128 newOiLongToken = int128(pairOiToken.oiLongToken) +
                int128(oiDeltaToken) *
                (_open ? int128(1) : int128(-1));
            pairOiToken.oiLongToken = uint128(newOiLongToken > 0 ? newOiLongToken : int128(0));
        } else {
            int128 newOiShortCollateral = int128(pairOiCollateral.oiShortCollateral) +
                int128(oiDeltaCollateral) *
                (_open ? int128(1) : int128(-1));
            pairOiCollateral.oiShortCollateral = uint128(newOiShortCollateral > 0 ? newOiShortCollateral : int128(0));

            int128 newOiShortToken = int128(pairOiToken.oiShortToken) +
                int128(oiDeltaToken) *
                (_open ? int128(1) : int128(-1));
            pairOiToken.oiShortToken = uint128(newOiShortToken > 0 ? newOiShortToken : int128(0));
        }

        _getStorage().pairOiAfterV10Collateral[_collateralIndex][_pairIndex] = pairOiCollateral;
        _getStorage().pairOiAfterV10Token[_collateralIndex][_pairIndex] = pairOiToken;

        emit IPriceImpactUtils.PairOiAfterV10Updated(
            _collateralIndex,
            _pairIndex,
            _oiDeltaCollateral,
            _oiDeltaToken,
            _open,
            _long,
            pairOiCollateral,
            pairOiToken
        );
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function getPriceImpactOi(uint256 _pairIndex, bool _long) internal view returns (uint256 activeOi) {
        IPriceImpact.PriceImpactStorage storage priceImpactStorage = _getStorage();
        IPriceImpact.OiWindowsSettings storage settings = priceImpactStorage.oiWindowsSettings;

        // Return 0 if windowsCount is 0 (no price impact OI)
        if (settings.windowsCount == 0) {
            return 0;
        }

        uint256 currentWindowId = _getCurrentWindowId(settings);
        uint256 earliestWindowId = _getEarliestActiveWindowId(currentWindowId, settings.windowsCount);

        for (uint256 i = earliestWindowId; i <= currentWindowId; ++i) {
            IPriceImpact.PairOi memory _pairOi = priceImpactStorage.windows[settings.windowsDuration][_pairIndex][i];
            activeOi += _long ? _pairOi.oiLongUsd : _pairOi.oiShortUsd;
        }
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function getTradeCumulVolPriceImpactP(
        address _trader,
        uint16 _pairIndex,
        bool _long,
        uint256 _tradeOpenInterestUsd, // 1e18 USD
        bool _isPnlPositive, // only relevant when _open = false
        bool _open,
        uint256 _lastPosIncreaseBlock // only relevant when _open = false
    )
        internal
        view
        returns (
            int256 priceImpactP // 1e10 (%)
        )
    {
        IPriceImpact.PriceImpactValues memory v;
        v.pairFactors = _getStorage().pairFactors[_pairIndex];
        v.protectionCloseFactorWhitelist = _getStorage().protectionCloseFactorWhitelist[_trader];
        v.userPriceImpact = _getStorage().userPriceImpact[_trader][_pairIndex];

        v.protectionCloseFactorActive =
            _isPnlPositive &&
            !_open &&
            v.pairFactors.protectionCloseFactor != 0 &&
            ChainUtils.getBlockNumber() <= _lastPosIncreaseBlock + v.pairFactors.protectionCloseFactorBlocks &&
            !v.protectionCloseFactorWhitelist;

        if (
            (_open && v.pairFactors.exemptOnOpen) ||
            (!_open && !v.protectionCloseFactorActive && v.pairFactors.exemptAfterProtectionCloseFactor)
        ) return 0;

        v.tradePositiveSkew = (_long && _open) || (!_long && !_open);

        IPriceImpact.PairDepthBands memory pairBands = _getStorage().pairDepthBands[_pairIndex];
        uint256 bandSlot1 = v.tradePositiveSkew ? pairBands.aboveSlot1 : pairBands.belowSlot1;
        uint256 bandSlot2 = v.tradePositiveSkew ? pairBands.aboveSlot2 : pairBands.belowSlot2;
        if (bandSlot1 == 0 && bandSlot2 == 0) {
            return 0;
        }

        v.tradeSkewMultiplier = v.tradePositiveSkew ? int256(1) : int256(-1);

        IPriceImpact.DepthBandsMapping memory mapping_ = _getStorage().depthBandsMapping;

        return
            _getDepthBandsPriceImpactP(
                int256(getPriceImpactOi(_pairIndex, _open ? _long : !_long)) * v.tradeSkewMultiplier,
                int256(_tradeOpenInterestUsd) * v.tradeSkewMultiplier,
                IPriceImpact.DepthBandParameters({
                    pairSlot1: bandSlot1,
                    pairSlot2: bandSlot2,
                    mappingSlot1: mapping_.slot1,
                    mappingSlot2: mapping_.slot2
                }),
                ((v.protectionCloseFactorActive ? v.pairFactors.protectionCloseFactor : ConstantsUtils.P_10) *
                    (
                        v.userPriceImpact.cumulVolPriceImpactMultiplier != 0
                            ? v.userPriceImpact.cumulVolPriceImpactMultiplier
                            : 1e3
                    )) / 1e3,
                v.pairFactors.cumulativeFactor != 0 ? v.pairFactors.cumulativeFactor : ConstantsUtils.P_10
            );
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function getTradeSkewPriceImpactP(
        uint8 _collateralIndex,
        uint16 _pairIndex,
        bool _long,
        uint256 _positionSizeToken,
        bool _open
    )
        internal
        view
        returns (
            int256 priceImpactP // 1e10 (%)
        )
    {
        IPriceImpact.PriceImpactValues memory v;

        v.tradePositiveSkew = (_long && _open) || (!_long && !_open);
        v.depth = _getStorage().pairSkewDepths[_collateralIndex][_pairIndex];
        v.tradeSkewMultiplier = v.tradePositiveSkew ? int256(1) : int256(-1);
        v.priceImpactDivider = int256(2); // so depth is on same scale as cumul vol price impact

        return
            _getTradePriceImpactP(
                TradingCommonUtils.getPairV10OiTokenSkewCollateral(_collateralIndex, _pairIndex),
                int256(_positionSizeToken) * v.tradeSkewMultiplier,
                v.depth,
                ConstantsUtils.P_10,
                ConstantsUtils.P_10
            ) / v.priceImpactDivider;
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function getPairDepthBands(uint256 _pairIndex) public view returns (IPriceImpact.PairDepthBands memory) {
        return _getStorage().pairDepthBands[_pairIndex];
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function getPairDepthBandsArray(
        uint256[] calldata _indices
    ) external view returns (IPriceImpact.PairDepthBands[] memory) {
        IPriceImpact.PairDepthBands[] memory depthBands = new IPriceImpact.PairDepthBands[](_indices.length);

        for (uint256 i; i < _indices.length; ++i) {
            depthBands[i] = getPairDepthBands(_indices[i]);
        }

        return depthBands;
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function getPairDepthBandsDecoded(
        uint256 _pairIndex
    )
        public
        view
        returns (
            uint256 totalDepthAboveUsd,
            uint256 totalDepthBelowUsd,
            uint16[] memory bandsAbove,
            uint16[] memory bandsBelow
        )
    {
        IPriceImpact.PairDepthBands memory depthBands = getPairDepthBands(_pairIndex);
        bandsAbove = new uint16[](DEPTH_BANDS_COUNT);
        bandsBelow = new uint16[](DEPTH_BANDS_COUNT);

        totalDepthAboveUsd = _getTotalDepthUsd(depthBands.aboveSlot1) / 1e18;
        totalDepthBelowUsd = _getTotalDepthUsd(depthBands.belowSlot1) / 1e18;

        for (uint256 i; i < DEPTH_BANDS_COUNT; ++i) {
            bandsAbove[i] = uint16(_getBandValue(depthBands.aboveSlot1, depthBands.aboveSlot2, i));
            bandsBelow[i] = uint16(_getBandValue(depthBands.belowSlot1, depthBands.belowSlot2, i));
        }
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function getPairDepthBandsDecodedArray(
        uint256[] calldata _indices
    )
        external
        view
        returns (
            uint256[] memory totalDepthAboveUsd,
            uint256[] memory totalDepthBelowUsd,
            uint16[][] memory bandsAbove,
            uint16[][] memory bandsBelow
        )
    {
        totalDepthAboveUsd = new uint256[](_indices.length);
        totalDepthBelowUsd = new uint256[](_indices.length);
        bandsAbove = new uint16[][](_indices.length);
        bandsBelow = new uint16[][](_indices.length);

        for (uint256 i; i < _indices.length; ++i) {
            (totalDepthAboveUsd[i], totalDepthBelowUsd[i], bandsAbove[i], bandsBelow[i]) = getPairDepthBandsDecoded(
                _indices[i]
            );
        }
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function getDepthBandsMapping() internal view returns (uint256 slot1, uint256 slot2) {
        IPriceImpact.DepthBandsMapping memory mapping_ = _getStorage().depthBandsMapping;
        return (mapping_.slot1, mapping_.slot2);
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function getDepthBandsMappingDecoded() external view returns (uint16[] memory bands) {
        (uint256 slot1, uint256 slot2) = getDepthBandsMapping();

        bands = new uint16[](DEPTH_BANDS_COUNT);
        for (uint256 i; i < DEPTH_BANDS_COUNT; ++i) {
            bands[i] = uint16(_getBandValue(slot1, slot2, i));
        }
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function getPairSkewDepth(uint8 _collateralIndex, uint16 _pairIndex) public view returns (uint256) {
        return _getStorage().pairSkewDepths[_collateralIndex][_pairIndex];
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function getOiWindowsSettings() public view returns (IPriceImpact.OiWindowsSettings memory) {
        return _getStorage().oiWindowsSettings;
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function getOiWindow(
        uint48 _windowsDuration,
        uint256 _pairIndex,
        uint256 _windowId
    ) internal view returns (IPriceImpact.PairOi memory) {
        return
            _getStorage().windows[_windowsDuration > 0 ? _windowsDuration : getOiWindowsSettings().windowsDuration][
                _pairIndex
            ][_windowId];
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function getOiWindows(
        uint48 _windowsDuration,
        uint256 _pairIndex,
        uint256[] calldata _windowIds
    ) external view returns (IPriceImpact.PairOi[] memory) {
        IPriceImpact.PairOi[] memory _pairOis = new IPriceImpact.PairOi[](_windowIds.length);

        for (uint256 i; i < _windowIds.length; ++i) {
            _pairOis[i] = getOiWindow(_windowsDuration, _pairIndex, _windowIds[i]);
        }

        return _pairOis;
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function getPairSkewDepths(
        uint8[] calldata _collateralIndices,
        uint16[] calldata _pairIndices
    ) external view returns (uint256[] memory) {
        uint256[] memory depths = new uint256[](_collateralIndices.length);

        for (uint256 i = 0; i < _collateralIndices.length; ++i) {
            depths[i] = getPairSkewDepth(_collateralIndices[i], _pairIndices[i]);
        }

        return depths;
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function getPairFactors(
        uint256[] calldata _indices
    ) external view returns (IPriceImpact.PairFactors[] memory pairFactors) {
        pairFactors = new IPriceImpact.PairFactors[](_indices.length);
        IPriceImpact.PriceImpactStorage storage s = _getStorage();

        for (uint256 i = 0; i < _indices.length; ++i) {
            pairFactors[i] = s.pairFactors[_indices[i]];
        }
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function getNegPnlCumulVolMultiplier() external view returns (uint40) {
        return _getStorage().negPnlCumulVolMultiplier;
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function getProtectionCloseFactorWhitelist(address _trader) external view returns (bool) {
        return _getStorage().protectionCloseFactorWhitelist[_trader];
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function getUserPriceImpact(
        address _trader,
        uint256 _pairIndex
    ) internal view returns (IPriceImpact.UserPriceImpact memory) {
        return _getStorage().userPriceImpact[_trader][_pairIndex];
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function getUserPriceImpactArray(
        address _trader,
        uint256[] calldata _pairIndices
    ) internal view returns (IPriceImpact.UserPriceImpact[] memory) {
        IPriceImpact.UserPriceImpact[] memory priceImpacts = new IPriceImpact.UserPriceImpact[](_pairIndices.length);
        IPriceImpact.PriceImpactStorage storage s = _getStorage();

        for (uint256 i; i < _pairIndices.length; ++i) {
            priceImpacts[i] = s.userPriceImpact[_trader][_pairIndices[i]];
        }

        return priceImpacts;
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function getPairOiAfterV10Collateral(
        uint8 _collateralIndex,
        uint16 _pairIndex
    ) internal view returns (IPriceImpact.PairOiCollateral memory) {
        return _getStorage().pairOiAfterV10Collateral[_collateralIndex][_pairIndex];
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function getPairOisAfterV10Collateral(
        uint8[] memory _collateralIndex,
        uint16[] memory _pairIndex
    ) external view returns (IPriceImpact.PairOiCollateral[] memory) {
        IPriceImpact.PairOiCollateral[] memory pairOis = new IPriceImpact.PairOiCollateral[](_collateralIndex.length);

        for (uint256 i = 0; i < _collateralIndex.length; ++i) {
            pairOis[i] = getPairOiAfterV10Collateral(_collateralIndex[i], _pairIndex[i]);
        }

        return pairOis;
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function getPairOiAfterV10Token(
        uint8 _collateralIndex,
        uint16 _pairIndex
    ) internal view returns (IPriceImpact.PairOiToken memory) {
        return _getStorage().pairOiAfterV10Token[_collateralIndex][_pairIndex];
    }

    /**
     * @dev Check IPriceImpactUtils interface for documentation
     */
    function getPairOisAfterV10Token(
        uint8[] memory _collateralIndex,
        uint16[] memory _pairIndex
    ) external view returns (IPriceImpact.PairOiToken[] memory) {
        IPriceImpact.PairOiToken[] memory pairOis = new IPriceImpact.PairOiToken[](_collateralIndex.length);

        for (uint256 i = 0; i < _collateralIndex.length; ++i) {
            pairOis[i] = getPairOiAfterV10Token(_collateralIndex[i], _pairIndex[i]);
        }

        return pairOis;
    }

    /**
     * @dev Returns storage slot to use when fetching storage relevant to library
     */
    function _getSlot() internal pure returns (uint256) {
        return StorageUtils.GLOBAL_PRICE_IMPACT_SLOT;
    }

    /**
     * @dev Returns storage pointer for storage struct in diamond contract, at defined slot
     */
    function _getStorage() internal pure returns (IPriceImpact.PriceImpactStorage storage s) {
        uint256 storageSlot = _getSlot();
        assembly {
            s.slot := storageSlot
        }
    }

    /**
     * @dev Returns current address as multi-collateral diamond interface to call other facets functions.
     */
    function _getMultiCollatDiamond() internal view returns (IGNSMultiCollatDiamond) {
        return IGNSMultiCollatDiamond(address(this));
    }

    /**
     * @dev Transfers total long / short OI from last '_settings.windowsCount' windows of `_prevPairOiWindows`
     * to current window of `_newPairOiWindows` for `_pairsCount` pairs.
     *
     * Emits a {PriceImpactOiTransferredPairs} event.
     *
     * @param _pairsCount number of pairs
     * @param _prevPairOiWindows previous pair OI windows (previous windowsDuration mapping)
     * @param _newPairOiWindows new pair OI windows (new windowsDuration mapping)
     * @param _settings current OI windows settings
     * @param _newWindowsDuration new windows duration
     */
    function _transferPriceImpactOiForPairs(
        uint256 _pairsCount,
        mapping(uint256 => mapping(uint256 => IPriceImpact.PairOi)) storage _prevPairOiWindows, // pairIndex => windowId => PairOi
        mapping(uint256 => mapping(uint256 => IPriceImpact.PairOi)) storage _newPairOiWindows, // pairIndex => windowId => PairOi
        IPriceImpact.OiWindowsSettings memory _settings,
        uint48 _newWindowsDuration
    ) internal {
        uint256 prevCurrentWindowId = _getCurrentWindowId(_settings);
        uint256 prevEarliestWindowId = _getEarliestActiveWindowId(prevCurrentWindowId, _settings.windowsCount);

        uint256 newCurrentWindowId = _getCurrentWindowId(
            IPriceImpact.OiWindowsSettings(_settings.startTs, _newWindowsDuration, _settings.windowsCount)
        );

        for (uint256 pairIndex; pairIndex < _pairsCount; ++pairIndex) {
            _transferPriceImpactOiForPair(
                pairIndex,
                prevCurrentWindowId,
                prevEarliestWindowId,
                _prevPairOiWindows[pairIndex],
                _newPairOiWindows[pairIndex][newCurrentWindowId]
            );
        }

        emit IPriceImpactUtils.PriceImpactOiTransferredPairs(
            _pairsCount,
            prevCurrentWindowId,
            prevEarliestWindowId,
            newCurrentWindowId
        );
    }

    /**
     * @dev Transfers total long / short OI from `prevEarliestWindowId` to `prevCurrentWindowId` windows of
     * `_prevPairOiWindows` to `_newPairOiWindow` window.
     *
     * Emits a {PriceImpactOiTransferredPair} event.
     *
     * @param _pairIndex index of the pair
     * @param _prevCurrentWindowId previous current window ID
     * @param _prevEarliestWindowId previous earliest active window ID
     * @param _prevPairOiWindows previous pair OI windows (previous windowsDuration mapping)
     * @param _newPairOiWindow new pair OI window (new windowsDuration mapping)
     */
    function _transferPriceImpactOiForPair(
        uint256 _pairIndex,
        uint256 _prevCurrentWindowId,
        uint256 _prevEarliestWindowId,
        mapping(uint256 => IPriceImpact.PairOi) storage _prevPairOiWindows,
        IPriceImpact.PairOi storage _newPairOiWindow
    ) internal {
        IPriceImpact.PairOi memory totalPairOi;

        // Aggregate sum of total long / short OI for past windows
        for (uint256 id = _prevEarliestWindowId; id <= _prevCurrentWindowId; ++id) {
            IPriceImpact.PairOi memory pairOi = _prevPairOiWindows[id];

            totalPairOi.oiLongUsd += pairOi.oiLongUsd;
            totalPairOi.oiShortUsd += pairOi.oiShortUsd;

            // Clean up previous map once added to the sum
            delete _prevPairOiWindows[id];
        }

        bool longOiTransfer = totalPairOi.oiLongUsd > 0;
        bool shortOiTransfer = totalPairOi.oiShortUsd > 0;

        if (longOiTransfer) {
            _newPairOiWindow.oiLongUsd += totalPairOi.oiLongUsd;
        }

        if (shortOiTransfer) {
            _newPairOiWindow.oiShortUsd += totalPairOi.oiShortUsd;
        }

        // Only emit IPriceImpactUtils.even if there was an actual OI transfer
        if (longOiTransfer || shortOiTransfer) {
            emit IPriceImpactUtils.PriceImpactOiTransferredPair(_pairIndex, totalPairOi);
        }
    }

    /**
     * @dev Returns window id at `_timestamp` given `_settings`.
     * @param _timestamp timestamp
     * @param _settings OI windows settings
     */
    function _getWindowId(
        uint48 _timestamp,
        IPriceImpact.OiWindowsSettings memory _settings
    ) internal pure returns (uint256) {
        return (_timestamp - _settings.startTs) / _settings.windowsDuration;
    }

    /**
     * @dev Returns window id at current timestamp given `_settings`.
     * @param _settings OI windows settings
     */
    function _getCurrentWindowId(IPriceImpact.OiWindowsSettings memory _settings) internal view returns (uint256) {
        return _getWindowId(uint48(block.timestamp), _settings);
    }

    /**
     * @dev Returns earliest active window id given `_currentWindowId` and `_windowsCount`.
     * @param _currentWindowId current window id
     * @param _windowsCount active windows count
     */
    function _getEarliestActiveWindowId(
        uint256 _currentWindowId,
        uint48 _windowsCount
    ) internal pure returns (uint256) {
        uint256 windowNegativeDelta = _windowsCount - 1; // -1 because we include current window
        return _currentWindowId > windowNegativeDelta ? _currentWindowId - windowNegativeDelta : 0;
    }

    /**
     * @dev Returns whether '_windowId' can be potentially active id given `_currentWindowId`
     * @param _windowId window id
     * @param _currentWindowId current window id
     */
    function _isWindowPotentiallyActive(uint256 _windowId, uint256 _currentWindowId) internal pure returns (bool) {
        return _currentWindowId - _windowId < MAX_WINDOWS_COUNT;
    }

    /**
     * @dev Returns trade price impact % and opening price after impact.
     * @param _startOpenInterest existing open interest of pair (1e18)
     * @param _tradeOpenInterest open interest of trade (1e18)
     * @param _onePercentDepth one percent depth of pair on trade side (1e18)
     * @param _priceImpactFactor price impact factor (1e10 precision)
     * @param _cumulativeFactor cumulative factor (1e10 precision)
     */
    function _getTradePriceImpactP(
        int256 _startOpenInterest,
        int256 _tradeOpenInterest,
        uint256 _onePercentDepth,
        uint256 _priceImpactFactor,
        uint256 _cumulativeFactor
    ) internal pure returns (int256 priceImpactP) {
        if (_onePercentDepth == 0) return 0;

        priceImpactP =
            (((_startOpenInterest * int256(_cumulativeFactor)) / int256(ConstantsUtils.P_10) + _tradeOpenInterest / 2) *
                int256(_priceImpactFactor)) /
            int256(_onePercentDepth);
    }

    /**
     * @dev Calculates trade price impact % using depth bands
     * @param _cumulativeVolumeUsd cumulative volume USD of pair (1e18)
     * @param _tradeSizeUsd position size USD of trade (1e18)
     * @param _depthBandParams depth bands parameters
     * @param _priceImpactFactor price impact factor (1e10 precision)
     * @param _cumulativeFactor cumulative factor (1e10 precision)
     * @return priceImpactP price impact in percentage (1e10)
     */
    function _getDepthBandsPriceImpactP(
        int256 _cumulativeVolumeUsd,
        int256 _tradeSizeUsd,
        IPriceImpact.DepthBandParameters memory _depthBandParams,
        uint256 _priceImpactFactor,
        uint256 _cumulativeFactor
    ) internal pure returns (int256 priceImpactP) {
        if ((_cumulativeVolumeUsd > 0 && _tradeSizeUsd < 0) || (_cumulativeVolumeUsd < 0 && _tradeSizeUsd > 0))
            revert IGeneralErrors.WrongParams();

        int256 effectiveCumulativeVolumeUsd = (_cumulativeVolumeUsd * int256(_cumulativeFactor)) /
            int256(ConstantsUtils.P_10);
        int256 totalSizeLookupUsd = effectiveCumulativeVolumeUsd + _tradeSizeUsd;

        bool isNegative = totalSizeLookupUsd < 0;

        uint256 effectiveCumulativeVolumeUsdUint = isNegative
            ? uint256(-effectiveCumulativeVolumeUsd)
            : uint256(effectiveCumulativeVolumeUsd); // 1e18
        uint256 totalSizeLookupUsdUint = isNegative ? uint256(-totalSizeLookupUsd) : uint256(totalSizeLookupUsd); // 1e18

        uint256 cumulativeVolPriceImpactP = _calculateDepthBandsPriceImpact(
            effectiveCumulativeVolumeUsdUint,
            _depthBandParams
        ); // 1e10 (%)
        uint256 totalSizePriceImpactP = _calculateDepthBandsPriceImpact(
            totalSizeLookupUsdUint, // pass total size to go through all bands
            _depthBandParams
        ); // 1e10 (%)

        uint256 unscaledPriceImpactP = cumulativeVolPriceImpactP +
            (totalSizePriceImpactP - cumulativeVolPriceImpactP) /
            2; // 1e10 (%) => cumulative vol price impact + trade size price impact / 2 (prevent trade splitting)

        uint256 scaledPriceImpactP = (unscaledPriceImpactP * _priceImpactFactor) / ConstantsUtils.P_10; // 1e10 (%)

        return isNegative ? -int256(scaledPriceImpactP) : int256(scaledPriceImpactP);
    }

    /**
     * @dev Extract the total depth USD value from slot1
     * @param _slot1 The first slot of depth bands containing totalDepthUsd as uint32
     * @return Depth USD value scaled to 1e18 precision
     */
    function _getTotalDepthUsd(uint256 _slot1) internal pure returns (uint256) {
        return uint256(uint32(_slot1)) * 1e18;
    }

    /**
     * @dev Get specific band value from slots
     * @param _slot1 The first slot of depth bands containing totalDepthUsd as uint32 and band values as uint16
     * @param _slot2 The second slot of depth bands containing band values as uint16 only
     * @param _bandIndex The index of the band to get the value for
     * @return The value of the band
     */
    function _getBandValue(uint256 _slot1, uint256 _slot2, uint256 _bandIndex) internal pure returns (uint256) {
        if (_bandIndex >= DEPTH_BANDS_COUNT) revert IGeneralErrors.WrongParams();

        if (_bandIndex < DEPTH_BANDS_PER_SLOT1) {
            // Get from slot1 (skip the first 32 bits which contain totalDepthUsd)
            return (_slot1 >> (32 + (_bandIndex * 16))) & 0xFFFF;
        } else {
            // Get from slot2
            return (_slot2 >> ((_bandIndex - DEPTH_BANDS_PER_SLOT1) * 16)) & 0xFFFF;
        }
    }

    /**
     * @dev Calculate price impact using average fill price
     * @param _tradeSizeUsd Trade size in USD (1e18)
     * @param _depthBandParams Depth band parameters
     * @return priceImpactP price impact in percentage (1e10)
     */
    function _calculateDepthBandsPriceImpact(
        uint256 _tradeSizeUsd,
        IPriceImpact.DepthBandParameters memory _depthBandParams
    ) internal pure returns (uint256 priceImpactP) {
        uint256 totalDepthUsd = _getTotalDepthUsd(_depthBandParams.pairSlot1); // 1e18

        if (totalDepthUsd == 0 || _tradeSizeUsd == 0) return 0;

        uint256 remainingSizeUsd = _tradeSizeUsd; // 1e18
        uint256 totalWeightedPriceImpactP; // 1e28 (%)
        uint256 prevBandDepthUsd; // 1e18
        uint256 topOfPrevBandOffsetPpm; // 1e4 (%)

        for (uint256 i; i < DEPTH_BANDS_COUNT && remainingSizeUsd != 0; i++) {
            uint256 bandLiquidityPercentageBps = _getBandValue(
                _depthBandParams.pairSlot1,
                _depthBandParams.pairSlot2,
                i
            ); // 1e2 (%)
            uint256 topOfBandOffsetPpm = _getBandValue(_depthBandParams.mappingSlot1, _depthBandParams.mappingSlot2, i); // 1e4 (%)
            uint256 bandDepthUsd = (bandLiquidityPercentageBps * totalDepthUsd) / HUNDRED_P_BPS; // 1e18

            // Skip if band has same depth as previous (would cause division by zero)
            if (bandDepthUsd <= prevBandDepthUsd) {
                prevBandDepthUsd = bandDepthUsd;
                topOfPrevBandOffsetPpm = topOfBandOffsetPpm;
                continue;
            }

            // Since bandDepthUsd represents liquidity from mid price to top of band, we need to subtract previous band depth
            uint256 bandAvailableDepthUsd = bandDepthUsd - prevBandDepthUsd; // 1e18
            uint256 depthConsumedUsd; // 1e18

            // At 100% band always consume all remaining size, even if more than band available depth
            if (bandLiquidityPercentageBps == HUNDRED_P_BPS || remainingSizeUsd <= bandAvailableDepthUsd) {
                depthConsumedUsd = remainingSizeUsd;
                remainingSizeUsd = 0;
            } else {
                // Normal case: consume entire band and continue to next
                depthConsumedUsd = bandAvailableDepthUsd;
                remainingSizeUsd -= bandAvailableDepthUsd;
            }

            // Calculate impact contribution from this band using trapezoidal rule
            // Low = previous band's price offset, High = current band's price offset
            uint256 lowOffsetP = topOfPrevBandOffsetPpm * 1e6; // 1e10 (%)
            uint256 offsetRangeP = (topOfBandOffsetPpm - topOfPrevBandOffsetPpm) * 1e6; // 1e10 (%)

            // Calculate average impact using trapezoidal rule: low + (range * fraction / 2)
            uint256 avgImpactP = lowOffsetP + ((offsetRangeP * depthConsumedUsd) / bandAvailableDepthUsd) / 2; // 1e10 (%)

            totalWeightedPriceImpactP += avgImpactP * depthConsumedUsd;

            // Update previous values for next iteration
            topOfPrevBandOffsetPpm = topOfBandOffsetPpm;
            prevBandDepthUsd = bandDepthUsd;
        }

        priceImpactP = totalWeightedPriceImpactP / _tradeSizeUsd; // 1e28 (%) / 1e18 = 1e10 (%)
    }
}
