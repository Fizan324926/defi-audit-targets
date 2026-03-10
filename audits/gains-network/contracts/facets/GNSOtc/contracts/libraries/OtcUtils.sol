// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../interfaces/IERC20.sol";
import "../interfaces/IGeneralErrors.sol";
import "../interfaces/types/IOtc.sol";
import "../interfaces/libraries/IOtcUtils.sol";

import "./ConstantsUtils.sol";
import "./StorageUtils.sol";
import "./TradingCommonUtils.sol";

/**
 * @dev OTC facet internal library
 */
library OtcUtils {
    uint64 private constant MAX_PREMIUM_P = uint64(5 * ConstantsUtils.P_10);
    uint256 private constant MIN_GNS_WEI_IN = 1e12; // 0.000001 GNS in wei

    /**
     * @dev Check IOtcUtils interface for documentation
     */
    function initializeOtc(IOtc.OtcConfig memory _config) internal {
        IAddressStore.Addresses storage addresses = AddressStoreUtils.getAddresses();
        IERC20(addresses.gns).approve(addresses.gnsStaking, type(uint256).max);

        updateOtcConfig(_config);
    }

    /**
     * @dev Check IOtcUtils interface for documentation
     */
    function updateOtcConfig(IOtc.OtcConfig memory _config) internal {
        // `OtcConfig.gnsTreasury` is deprecated, updated config must always have address(0)
        if (_config.gnsTreasury != address(0)) revert IGeneralErrors.WrongParams();

        if (_config.treasuryShareP + _config.stakingShareP + _config.burnShareP != 100 * ConstantsUtils.P_10)
            revert IOtcUtils.InvalidShareSum();

        if (_config.premiumP > MAX_PREMIUM_P) revert IGeneralErrors.AboveMax();

        _getStorage().otcConfig = _config;

        emit IOtcUtils.OtcConfigUpdated(_config);
    }

    /**
     * @dev Check IOtcUtils interface for documentation
     */
    function addOtcCollateralBalance(uint8 _collateralIndex, uint256 _collateralAmount) internal {
        IOtc.OtcStorage storage s = _getStorage();

        uint256 newBalanceCollateral = s.collateralBalances[_collateralIndex] + _collateralAmount;
        s.collateralBalances[_collateralIndex] = newBalanceCollateral;

        emit IOtcUtils.OtcBalanceUpdated(_collateralIndex, newBalanceCollateral);
    }

    /**
     * @dev Check IOtcUtils interface for documentation
     */
    function sellGnsForCollateral(uint8 _collateralIndex, uint256 _collateralAmount) internal {
        IOtc.OtcStorage storage s = _getStorage();
        bool isCollateralNotGns = !_getMultiCollatDiamond().isCollateralGns(_collateralIndex);

        uint256 availableCollateral = s.collateralBalances[_collateralIndex];
        uint256 gnsPriceCollateral = _getOtcRate(_collateralIndex, isCollateralNotGns);
        uint256 gnsAmount = _calculateGnsAmount(_collateralIndex, _collateralAmount, gnsPriceCollateral);

        // 1. Validation
        if (_collateralAmount == 0) revert IGeneralErrors.ZeroValue();
        if (_collateralAmount > availableCollateral) revert IGeneralErrors.InsufficientBalance();
        if (gnsAmount < MIN_GNS_WEI_IN) revert IGeneralErrors.BelowMin();

        // 2. Receive GNS from caller (if collateral is not GNS)
        if (isCollateralNotGns) TradingCommonUtils.transferGnsFrom(msg.sender, gnsAmount);

        // 3. Reduce available OTC balance for collateral
        uint256 newBalanceCollateral = availableCollateral - _collateralAmount;
        s.collateralBalances[_collateralIndex] = newBalanceCollateral;
        emit IOtcUtils.OtcBalanceUpdated(_collateralIndex, newBalanceCollateral);

        // 4. Distribute GNS
        (uint256 treasuryAmountGns, uint256 stakingAmountGns, uint256 burnAmountGns) = _calculateGnsDistribution(
            gnsAmount
        );

        if (treasuryAmountGns > 0) _distributeTreasuryGns(treasuryAmountGns);
        if (stakingAmountGns > 0) _distributeStakingGns(stakingAmountGns);
        if (burnAmountGns > 0) _burnGns(burnAmountGns);

        // 5. Transfer collateral to caller (if collateral is not GNS)
        if (isCollateralNotGns)
            TradingCommonUtils.transferCollateralTo(_collateralIndex, msg.sender, _collateralAmount, false);

        emit IOtcUtils.OtcExecuted(
            _collateralIndex,
            _collateralAmount,
            gnsPriceCollateral,
            treasuryAmountGns,
            stakingAmountGns,
            burnAmountGns
        );
    }

    /**
     * @dev Check IOtcUtils interface for documentation
     */
    function getOtcConfig() internal view returns (IOtcUtils.OtcConfig memory) {
        return _getStorage().otcConfig;
    }

    /**
     * @dev Check IOtcUtils interface for documentation
     */
    function getOtcBalance(uint8 _collateralIndex) internal view returns (uint256) {
        return _getStorage().collateralBalances[_collateralIndex];
    }

    /**
     * @dev Check IOtcUtils interface for documentation
     */
    function getOtcRate(uint8 _collateralIndex) internal view returns (uint256) {
        return _getOtcRate(_collateralIndex, !_getMultiCollatDiamond().isCollateralGns(_collateralIndex));
    }

    /**
     * @dev Returns storage slot to use when fetching storage relevant to library
     */
    function _getSlot() internal pure returns (uint256) {
        return StorageUtils.GLOBAL_OTC_SLOT;
    }

    /**
     * @dev Returns storage pointer for storage struct in diamond contract, at defined slot
     */
    function _getStorage() internal pure returns (IOtc.OtcStorage storage s) {
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
     * @dev Returns OTC rate (price + premium, when `applyPremium` is true) of GNS in collateral (1e10)
     * @param _collateralIndex collateral index
     * @param _applyPremium whether premium should be applied. At the moment, premium is only applied for non-GNS collaterals
     */
    function _getOtcRate(uint8 _collateralIndex, bool _applyPremium) internal view returns (uint256) {
        uint256 baseRate = _getMultiCollatDiamond().getGnsPriceCollateralIndex(_collateralIndex);
        uint64 premiumP = _applyPremium ? _getStorage().otcConfig.premiumP : 0;

        return premiumP > 0 ? (baseRate + ((baseRate * premiumP) / 100 / ConstantsUtils.P_10)) : baseRate;
    }

    /**
     * @dev Calculate GNS amount for given collateral amount
     * @param _collateralIndex index of the collateral
     * @param _collateralAmount amount of collateral (collateral precision)
     * @param _gnsPriceCollateral price of GNS in collateral (1e10)
     */
    function _calculateGnsAmount(
        uint8 _collateralIndex,
        uint256 _collateralAmount,
        uint256 _gnsPriceCollateral
    ) internal view returns (uint256) {
        return
            TradingCommonUtils.convertCollateralToGns(
                _collateralAmount,
                _getMultiCollatDiamond().getCollateral(_collateralIndex).precisionDelta,
                _gnsPriceCollateral
            );
    }

    /**
     * @dev Calculate GNS distribution for treasury, GNS staking and burn
     * @param _gnsAmount amount of GNS tokens to distribute (1e18)
     */
    function _calculateGnsDistribution(
        uint256 _gnsAmount
    ) internal view returns (uint256 treasuryAmountGns, uint256 stakingAmountGns, uint256 burnAmountGns) {
        IOtc.OtcConfig storage config = _getStorage().otcConfig;

        treasuryAmountGns = (_gnsAmount * config.treasuryShareP) / 100 / ConstantsUtils.P_10;
        stakingAmountGns = (_gnsAmount * config.stakingShareP) / 100 / ConstantsUtils.P_10;
        burnAmountGns = (_gnsAmount * config.burnShareP) / 100 / ConstantsUtils.P_10;
    }

    /**
     * @dev Distributes treasury rewards in GNS tokens
     * @param _gnsAmount amount of GNS tokens to distribute (1e18)
     */
    function _distributeTreasuryGns(uint256 _gnsAmount) internal {
        TradingCommonUtils.transferGnsTo(AddressStoreUtils.getAddresses().treasury, _gnsAmount);
    }

    /**
     * @dev Distributes staking rewards in GNS tokens
     * @param _gnsAmount amount of GNS tokens to distribute (1e18)
     */
    function _distributeStakingGns(uint256 _gnsAmount) internal {
        IAddressStore.Addresses storage addresses = AddressStoreUtils.getAddresses();
        IGNSStaking(addresses.gnsStaking).distributeReward(addresses.gns, _gnsAmount);
    }

    /**
     * @dev Burns GNS tokens
     * @param _gnsAmount amount of GNS tokens to burn (1e18)
     */
    function _burnGns(uint256 _gnsAmount) internal {
        IERC20(AddressStoreUtils.getAddresses().gns).burn(address(this), _gnsAmount);
    }
}
