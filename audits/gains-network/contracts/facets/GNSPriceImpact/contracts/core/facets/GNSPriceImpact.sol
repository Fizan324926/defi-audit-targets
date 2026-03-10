// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../abstract/GNSAddressStore.sol";

import "../../interfaces/libraries/IPriceImpactUtils.sol";

import "../../libraries/PriceImpactUtils.sol";
import "../../libraries/PairsStorageUtils.sol";

/**
 * @dev Facet #4: Price impact OI windows
 */
contract GNSPriceImpact is GNSAddressStore, IPriceImpactUtils {
    // Initialization

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IPriceImpactUtils
    function initializePriceImpact(uint48 _windowsDuration, uint48 _windowsCount) external reinitializer(5) {
        PriceImpactUtils.initializePriceImpact(_windowsDuration, _windowsCount);
    }

    /// @inheritdoc IPriceImpactUtils
    function initializeNegPnlCumulVolMultiplier(uint40 _negPnlCumulVolMultiplier) external reinitializer(17) {
        PriceImpactUtils.initializeNegPnlCumulVolMultiplier(_negPnlCumulVolMultiplier);
    }

    /// @inheritdoc IPriceImpactUtils
    function initializePairFactors(
        uint16[] calldata _pairIndices,
        uint40[] calldata _protectionCloseFactors,
        uint32[] calldata _protectionCloseFactorBlocks,
        uint40[] calldata _cumulativeFactors
    ) external reinitializer(13) {
        PriceImpactUtils.initializePairFactors(
            _pairIndices,
            _protectionCloseFactors,
            _protectionCloseFactorBlocks,
            _cumulativeFactors
        );
    }

    /// @inheritdoc IPriceImpactUtils
    function initializeDepthBandsMapping(uint256 _slot1, uint256 _slot2) external reinitializer(25) {
        PriceImpactUtils.setDepthBandsMapping(_slot1, _slot2);
    }

    // Management Setters

    /// @inheritdoc IPriceImpactUtils
    function setPriceImpactWindowsCount(uint48 _newWindowsCount) external onlyRoles(Role.GOV, Role.GOV_EMERGENCY) {
        PriceImpactUtils.setPriceImpactWindowsCount(_newWindowsCount);
    }

    /// @inheritdoc IPriceImpactUtils
    function setPriceImpactWindowsDuration(
        uint48 _newWindowsDuration
    ) external onlyRoles(Role.GOV, Role.GOV_EMERGENCY) {
        PriceImpactUtils.setPriceImpactWindowsDuration(_newWindowsDuration, PairsStorageUtils.pairsCount());
    }

    /// @inheritdoc IPriceImpactUtils
    function setNegPnlCumulVolMultiplier(
        uint40 _negPnlCumulVolMultiplier
    ) external onlyRoles(Role.GOV, Role.GOV_EMERGENCY) {
        PriceImpactUtils.setNegPnlCumulVolMultiplier(_negPnlCumulVolMultiplier);
    }

    /// @inheritdoc IPriceImpactUtils
    function setProtectionCloseFactorWhitelist(
        address[] calldata _traders,
        bool[] calldata _whitelisted
    ) external onlyRoles(Role.GOV, Role.MANAGER) {
        PriceImpactUtils.setProtectionCloseFactorWhitelist(_traders, _whitelisted);
    }

    /// @inheritdoc IPriceImpactUtils
    function setUserPriceImpact(
        address[] calldata _traders,
        uint16[] calldata _pairIndices,
        uint16[] calldata _cumulVolPriceImpactMultipliers,
        uint16[] calldata _fixedSpreadPs
    ) external onlyRoles(Role.GOV, Role.GOV_EMERGENCY) {
        PriceImpactUtils.setUserPriceImpact(_traders, _pairIndices, _cumulVolPriceImpactMultipliers, _fixedSpreadPs);
    }

    /// @inheritdoc IPriceImpactUtils
    function setPairDepthBands(
        uint256[] calldata _indices,
        IPriceImpact.PairDepthBands[] calldata _depthBands
    ) external onlyRole(Role.MANAGER) {
        PriceImpactUtils.setPairDepthBands(_indices, _depthBands);
    }

    /// @inheritdoc IPriceImpactUtils
    function setDepthBandsMapping(uint256 _slot1, uint256 _slot2) external onlyRoles(Role.GOV, Role.GOV_EMERGENCY) {
        PriceImpactUtils.setDepthBandsMapping(_slot1, _slot2);
    }

    /// @inheritdoc IPriceImpactUtils
    function setPairSkewDepths(
        uint8[] calldata _collateralIndices,
        uint16[] calldata _pairIndices,
        uint256[] calldata _depths
    ) external onlyRoles(Role.MANAGER, Role.GOV_EMERGENCY) {
        PriceImpactUtils.setPairSkewDepths(_collateralIndices, _pairIndices, _depths);
    }

    /// @inheritdoc IPriceImpactUtils
    function setProtectionCloseFactors(
        uint16[] calldata _pairIndices,
        uint40[] calldata _protectionCloseFactors
    ) external onlyRoles(Role.GOV, Role.GOV_EMERGENCY) {
        PriceImpactUtils.setProtectionCloseFactors(_pairIndices, _protectionCloseFactors);
    }

    /// @inheritdoc IPriceImpactUtils
    function setProtectionCloseFactorBlocks(
        uint16[] calldata _pairIndices,
        uint32[] calldata _protectionCloseFactorBlocks
    ) external onlyRoles(Role.GOV, Role.GOV_EMERGENCY) {
        PriceImpactUtils.setProtectionCloseFactorBlocks(_pairIndices, _protectionCloseFactorBlocks);
    }

    /// @inheritdoc IPriceImpactUtils
    function setCumulativeFactors(
        uint16[] calldata _pairIndices,
        uint40[] calldata _cumulativeFactors
    ) external onlyRoles(Role.GOV_TIMELOCK, Role.GOV_EMERGENCY) {
        PriceImpactUtils.setCumulativeFactors(_pairIndices, _cumulativeFactors);
    }

    /// @inheritdoc IPriceImpactUtils
    function setExemptOnOpen(
        uint16[] calldata _pairIndices,
        bool[] calldata _exemptOnOpen
    ) external onlyRoles(Role.GOV_TIMELOCK, Role.GOV_EMERGENCY) {
        PriceImpactUtils.setExemptOnOpen(_pairIndices, _exemptOnOpen);
    }

    /// @inheritdoc IPriceImpactUtils
    function setExemptAfterProtectionCloseFactor(
        uint16[] calldata _pairIndices,
        bool[] calldata _exemptAfterProtectionCloseFactor
    ) external onlyRoles(Role.GOV_TIMELOCK, Role.GOV_EMERGENCY) {
        PriceImpactUtils.setExemptAfterProtectionCloseFactor(_pairIndices, _exemptAfterProtectionCloseFactor);
    }

    // Interactions

    /// @inheritdoc IPriceImpactUtils
    function addPriceImpactOpenInterest(
        address _trader,
        uint32 _index,
        uint256 _oiDeltaCollateral,
        bool _open,
        bool _isPnlPositive
    ) external virtual onlySelf {
        PriceImpactUtils.addPriceImpactOpenInterest(_trader, _index, _oiDeltaCollateral, _open, _isPnlPositive);
    }

    /// @inheritdoc IPriceImpactUtils
    function updatePairOiAfterV10(
        uint8 _collateralIndex,
        uint16 _pairIndex,
        uint256 _oiDeltaCollateral,
        uint256 _oiDeltaToken,
        bool _open,
        bool _long
    ) external virtual onlySelf {
        PriceImpactUtils.updatePairOiAfterV10(
            _collateralIndex,
            _pairIndex,
            _oiDeltaCollateral,
            _oiDeltaToken,
            _open,
            _long
        );
    }

    // Getters

    /// @inheritdoc IPriceImpactUtils
    function getPriceImpactOi(uint256 _pairIndex, bool _long) external view returns (uint256 activeOi) {
        return PriceImpactUtils.getPriceImpactOi(_pairIndex, _long);
    }

    /// @inheritdoc IPriceImpactUtils
    function getTradeCumulVolPriceImpactP(
        address _trader,
        uint16 _pairIndex,
        bool _long,
        uint256 _tradeOpenInterestUsd,
        bool _isPnlPositive,
        bool _open,
        uint256 _lastPosIncreaseBlock
    ) external view returns (int256 priceImpactP) {
        return
            PriceImpactUtils.getTradeCumulVolPriceImpactP(
                _trader,
                _pairIndex,
                _long,
                _tradeOpenInterestUsd,
                _isPnlPositive,
                _open,
                _lastPosIncreaseBlock
            );
    }

    /// @inheritdoc IPriceImpactUtils
    function getTradeSkewPriceImpactP(
        uint8 _collateralIndex,
        uint16 _pairIndex,
        bool _long,
        uint256 _positionSizeToken,
        bool _open
    ) external view returns (int256 priceImpactP) {
        return
            PriceImpactUtils.getTradeSkewPriceImpactP(_collateralIndex, _pairIndex, _long, _positionSizeToken, _open);
    }

    /// @inheritdoc IPriceImpactUtils
    function getPairDepthBands(uint256 _pairIndex) external view returns (IPriceImpact.PairDepthBands memory) {
        return PriceImpactUtils.getPairDepthBands(_pairIndex);
    }

    /// @inheritdoc IPriceImpactUtils
    function getPairDepthBandsArray(
        uint256[] calldata _indices
    ) external view returns (IPriceImpact.PairDepthBands[] memory) {
        return PriceImpactUtils.getPairDepthBandsArray(_indices);
    }

    /// @inheritdoc IPriceImpactUtils
    function getPairDepthBandsDecoded(
        uint256 _pairIndex
    )
        external
        view
        returns (
            uint256 totalDepthAboveUsd,
            uint256 totalDepthBelowUsd,
            uint16[] memory bandsAbove,
            uint16[] memory bandsBelow
        )
    {
        return PriceImpactUtils.getPairDepthBandsDecoded(_pairIndex);
    }

    /// @inheritdoc IPriceImpactUtils
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
        return PriceImpactUtils.getPairDepthBandsDecodedArray(_indices);
    }

    /// @inheritdoc IPriceImpactUtils
    function getDepthBandsMapping() external view returns (uint256 slot1, uint256 slot2) {
        return PriceImpactUtils.getDepthBandsMapping();
    }

    /// @inheritdoc IPriceImpactUtils
    function getDepthBandsMappingDecoded() external view returns (uint16[] memory bands) {
        return PriceImpactUtils.getDepthBandsMappingDecoded();
    }

    /// @inheritdoc IPriceImpactUtils
    function getPairSkewDepth(uint8 _collateralIndex, uint16 _pairIndex) external view returns (uint256) {
        return PriceImpactUtils.getPairSkewDepth(_collateralIndex, _pairIndex);
    }

    /// @inheritdoc IPriceImpactUtils
    function getOiWindowsSettings() external view returns (OiWindowsSettings memory) {
        return PriceImpactUtils.getOiWindowsSettings();
    }

    /// @inheritdoc IPriceImpactUtils
    function getOiWindow(
        uint48 _windowsDuration,
        uint256 _pairIndex,
        uint256 _windowId
    ) external view returns (PairOi memory) {
        return PriceImpactUtils.getOiWindow(_windowsDuration, _pairIndex, _windowId);
    }

    /// @inheritdoc IPriceImpactUtils
    function getOiWindows(
        uint48 _windowsDuration,
        uint256 _pairIndex,
        uint256[] calldata _windowIds
    ) external view returns (PairOi[] memory) {
        return PriceImpactUtils.getOiWindows(_windowsDuration, _pairIndex, _windowIds);
    }

    /// @inheritdoc IPriceImpactUtils
    function getPairSkewDepths(
        uint8[] calldata _collateralIndices,
        uint16[] calldata _pairIndices
    ) external view returns (uint256[] memory) {
        return PriceImpactUtils.getPairSkewDepths(_collateralIndices, _pairIndices);
    }

    /// @inheritdoc IPriceImpactUtils
    function getPairFactors(uint256[] calldata _indices) external view returns (IPriceImpact.PairFactors[] memory) {
        return PriceImpactUtils.getPairFactors(_indices);
    }

    /// @inheritdoc IPriceImpactUtils
    function getNegPnlCumulVolMultiplier() external view returns (uint48) {
        return PriceImpactUtils.getNegPnlCumulVolMultiplier();
    }

    /// @inheritdoc IPriceImpactUtils
    function getProtectionCloseFactorWhitelist(address _trader) external view returns (bool) {
        return PriceImpactUtils.getProtectionCloseFactorWhitelist(_trader);
    }

    /// @inheritdoc IPriceImpactUtils
    function getUserPriceImpact(
        address _trader,
        uint256 _pairIndex
    ) external view returns (IPriceImpact.UserPriceImpact memory) {
        return PriceImpactUtils.getUserPriceImpact(_trader, _pairIndex);
    }

    /// @inheritdoc IPriceImpactUtils
    function getUserPriceImpactArray(
        address _trader,
        uint256[] calldata _pairIndices
    ) external view returns (IPriceImpact.UserPriceImpact[] memory) {
        return PriceImpactUtils.getUserPriceImpactArray(_trader, _pairIndices);
    }

    /// @inheritdoc IPriceImpactUtils
    function getPairOiAfterV10Collateral(
        uint8 _collateralIndex,
        uint16 _pairIndex
    ) external view returns (IPriceImpact.PairOiCollateral memory) {
        return PriceImpactUtils.getPairOiAfterV10Collateral(_collateralIndex, _pairIndex);
    }

    /// @inheritdoc IPriceImpactUtils
    function getPairOisAfterV10Collateral(
        uint8[] memory _collateralIndex,
        uint16[] memory _pairIndex
    ) external view returns (IPriceImpact.PairOiCollateral[] memory) {
        return PriceImpactUtils.getPairOisAfterV10Collateral(_collateralIndex, _pairIndex);
    }

    /// @inheritdoc IPriceImpactUtils
    function getPairOiAfterV10Token(
        uint8 _collateralIndex,
        uint16 _pairIndex
    ) external view returns (IPriceImpact.PairOiToken memory) {
        return PriceImpactUtils.getPairOiAfterV10Token(_collateralIndex, _pairIndex);
    }

    /// @inheritdoc IPriceImpactUtils
    function getPairOisAfterV10Token(
        uint8[] memory _collateralIndex,
        uint16[] memory _pairIndex
    ) external view returns (IPriceImpact.PairOiToken[] memory) {
        return PriceImpactUtils.getPairOisAfterV10Token(_collateralIndex, _pairIndex);
    }
}
