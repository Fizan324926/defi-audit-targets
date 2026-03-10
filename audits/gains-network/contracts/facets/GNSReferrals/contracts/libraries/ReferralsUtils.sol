// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../interfaces/libraries/IReferralsUtils.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/IGeneralErrors.sol";

import "./AddressStoreUtils.sol";
import "./StorageUtils.sol";
import "./ConstantsUtils.sol";

/**
 * @dev GNSReferrals facet internal library
 */
library ReferralsUtils {
    using SafeERC20 for IERC20;

    uint256 private constant MAX_ALLY_FEE_P = 50;
    uint256 private constant MAX_START_REFERRER_FEE_P = 100;
    uint256 private constant MAX_OPEN_FEE_P = 50;

    /**
     * @dev Check IReferralsUtils interface for documentation
     */
    function initializeReferrals(uint256 _allyFeeP, uint256 _startReferrerFeeP, uint256 _targetVolumeUsd) internal {
        if (_allyFeeP > MAX_ALLY_FEE_P || _startReferrerFeeP > MAX_START_REFERRER_FEE_P || _targetVolumeUsd == 0)
            revert IGeneralErrors.WrongParams();

        IReferralsUtils.ReferralsStorage storage s = _getStorage();

        s.allyFeeP = _allyFeeP;
        s.startReferrerFeeP = _startReferrerFeeP;
        s.targetVolumeUsd = _targetVolumeUsd;
    }

    /**
     * @dev Check IReferralsUtils interface for documentation
     */
    function updateAllyFeeP(uint256 _value) internal {
        if (_value > MAX_ALLY_FEE_P) revert IGeneralErrors.AboveMax();

        _getStorage().allyFeeP = _value;

        emit IReferralsUtils.UpdatedAllyFeeP(_value);
    }

    /**
     * @dev Check IReferralsUtils interface for documentation
     */
    function updateStartReferrerFeeP(uint256 _value) internal {
        if (_value > MAX_START_REFERRER_FEE_P) revert IGeneralErrors.AboveMax();

        _getStorage().startReferrerFeeP = _value;

        emit IReferralsUtils.UpdatedStartReferrerFeeP(_value);
    }

    /**
     * @dev Check IReferralsUtils interface for documentation
     */
    function updateReferralsTargetVolumeUsd(uint256 _value) internal {
        if (_value == 0) revert IGeneralErrors.ZeroValue();

        _getStorage().targetVolumeUsd = _value;

        emit IReferralsUtils.UpdatedTargetVolumeUsd(_value);
    }

    /**
     * @dev Check IReferralsUtils interface for documentation
     */
    function whitelistAllies(address[] calldata _allies) internal {
        for (uint256 i = 0; i < _allies.length; ++i) {
            _whitelistAlly(_allies[i]);
        }
    }

    /**
     * @dev Check IReferralsUtils interface for documentation
     */
    function unwhitelistAllies(address[] calldata _allies) internal {
        for (uint256 i = 0; i < _allies.length; ++i) {
            _unwhitelistAlly(_allies[i]);
        }
    }

    /**
     * @dev Check IReferralsUtils interface for documentation
     */
    function whitelistReferrers(address[] calldata _referrers, address[] calldata _allies) internal {
        if (_referrers.length != _allies.length) revert IGeneralErrors.WrongLength();

        for (uint256 i = 0; i < _referrers.length; ++i) {
            _whitelistReferrer(_referrers[i], _allies[i]);
        }
    }

    /**
     * @dev Check IReferralsUtils interface for documentation
     */
    function unwhitelistReferrers(address[] calldata _referrers) internal {
        for (uint256 i = 0; i < _referrers.length; ++i) {
            _unwhitelistReferrer(_referrers[i]);
        }
    }

    /**
     * @dev Check IReferralsUtils interface for documentation
     */
    function overrideReferralFeeP(address[] calldata _referrers, uint24[] calldata _referralFeeP) internal {
        IReferrals.ReferralsStorage storage s = _getStorage();

        for (uint256 i = 0; i < _referrers.length; ++i) {
            address referrer = _referrers[i];
            if (!s.referrerDetails[referrer].active) continue;

            uint24 referralFeeP = _referralFeeP[i];
            if (referralFeeP > ConstantsUtils.MAX_REFERRAL_FEE_P) revert IGeneralErrors.AboveMax();

            s.referralSettingsOverrides[referrer].referralFeeOverrideP = referralFeeP;

            emit IReferralsUtils.OverrodeReferralFeeP(referrer, referralFeeP);
        }
    }

    /**
     * @dev Check IReferralsUtils interface for documentation
     */
    function overrideAllyFeeP(address[] calldata _allies, uint24[] calldata _allyFeeP) internal {
        IReferrals.ReferralsStorage storage s = _getStorage();

        for (uint256 i = 0; i < _allies.length; ++i) {
            address ally = _allies[i];
            if (!s.allyDetails[ally].active) continue;

            uint24 allyFeeP = _allyFeeP[i];
            if (allyFeeP > MAX_ALLY_FEE_P * 1e3) revert IGeneralErrors.AboveMax();

            s.referralSettingsOverrides[ally].allyFeeOverrideP = allyFeeP;

            emit IReferralsUtils.OverrodeAllyFeeP(ally, allyFeeP);
        }
    }

    /**
     * @dev Check IReferralsUtils interface for documentation
     */
    function unsetTradersReferrers(address[] calldata _traders) internal {
        IReferralsUtils.ReferralsStorage storage s = _getStorage();

        for (uint256 i = 0; i < _traders.length; ++i) {
            address trader = _traders[i];
            address previousReferrer = s.referrerByTrader[trader];

            if (previousReferrer != address(0)) {
                // Clear the referrer mapping
                delete s.referrerByTrader[trader];

                // Note: We don't remove trader from referrerDetails[previousReferrer].tradersReferred array
                // to maintain historical data and avoid expensive array operations
                emit IReferralsUtils.TraderReferrerUnset(trader, previousReferrer);
            }
        }
    }

    /**
     * @dev Check IReferralsUtils interface for documentation
     */
    function registerPotentialReferrer(address _trader, address _referrer) internal {
        IReferralsUtils.ReferralsStorage storage s = _getStorage();
        IReferralsUtils.ReferrerDetails storage r = s.referrerDetails[_referrer];

        if (s.referrerByTrader[_trader] != address(0) || _referrer == address(0) || !r.active) {
            return;
        }

        s.referrerByTrader[_trader] = _referrer;
        r.tradersReferred.push(_trader);

        emit IReferralsUtils.ReferrerRegistered(_trader, _referrer);
    }

    /**
     * @dev Check IReferralsUtils interface for documentation
     */
    function distributeReferralReward(
        address _trader,
        uint256 _volumeUsd,
        uint256 _referrerFeeUsd,
        uint256 _gnsPriceUsd
    ) internal {
        IReferralsUtils.ReferralsStorage storage s = _getStorage();

        address referrer = s.referrerByTrader[_trader];
        IReferralsUtils.ReferrerDetails storage r = s.referrerDetails[referrer];

        if (!r.active) {
            return;
        }

        uint256 referrerRewardGns = (_referrerFeeUsd * ConstantsUtils.P_10) / _gnsPriceUsd;

        IERC20(AddressStoreUtils.getAddresses().gns).mint(address(this), referrerRewardGns);

        IReferralsUtils.AllyDetails storage a = s.allyDetails[r.ally];

        uint256 allyRewardValueUsd;
        uint256 allyRewardGns;

        if (a.active) {
            uint24 allyFeeOverrideP = s.referralSettingsOverrides[r.ally].allyFeeOverrideP;
            uint256 allyFeeP = allyFeeOverrideP > 0 ? allyFeeOverrideP : s.allyFeeP * 1e3;

            allyRewardValueUsd = (_referrerFeeUsd * allyFeeP) / 100 / 1e3;
            allyRewardGns = (referrerRewardGns * allyFeeP) / 100 / 1e3;

            a.volumeReferredUsd += _volumeUsd;
            a.pendingRewardsGns += allyRewardGns;
            a.totalRewardsGns += allyRewardGns;
            a.totalRewardsValueUsd += allyRewardValueUsd;

            _referrerFeeUsd -= allyRewardValueUsd;
            referrerRewardGns -= allyRewardGns;

            emit IReferralsUtils.AllyRewardDistributed(r.ally, _trader, _volumeUsd, allyRewardGns, allyRewardValueUsd);
        }

        r.volumeReferredUsd += _volumeUsd;
        r.pendingRewardsGns += referrerRewardGns;
        r.totalRewardsGns += referrerRewardGns;
        r.totalRewardsValueUsd += _referrerFeeUsd;

        emit IReferralsUtils.ReferrerRewardDistributed(
            referrer,
            _trader,
            _volumeUsd,
            referrerRewardGns,
            _referrerFeeUsd
        );
    }

    /**
     * @dev Check IReferralsUtils interface for documentation
     */
    function claimAllyRewards() internal {
        IReferralsUtils.AllyDetails storage a = _getStorage().allyDetails[msg.sender];
        uint256 rewardsGns = a.pendingRewardsGns;

        if (rewardsGns == 0) revert IReferralsUtils.NoPendingRewards();

        a.pendingRewardsGns = 0;
        IERC20(AddressStoreUtils.getAddresses().gns).safeTransfer(msg.sender, rewardsGns);

        emit IReferralsUtils.AllyRewardsClaimed(msg.sender, rewardsGns);
    }

    /**
     * @dev Check IReferralsUtils interface for documentation
     */
    function claimReferrerRewards() internal {
        IReferralsUtils.ReferrerDetails storage r = _getStorage().referrerDetails[msg.sender];
        uint256 rewardsGns = r.pendingRewardsGns;

        if (rewardsGns == 0) revert IReferralsUtils.NoPendingRewards();

        r.pendingRewardsGns = 0;
        IERC20(AddressStoreUtils.getAddresses().gns).safeTransfer(msg.sender, rewardsGns);

        emit IReferralsUtils.ReferrerRewardsClaimed(msg.sender, rewardsGns);
    }

    /**
     * @dev Check IReferralsUtils interface for documentation
     */
    function getReferrerFeeProgressP(address _referrer) internal view returns (uint256 progressP) {
        IReferralsUtils.ReferralsStorage storage s = _getStorage();
        uint256 volumeReferredUsd = s.referrerDetails[_referrer].volumeReferredUsd;
        uint256 targetVolumeUsd1e18 = s.targetVolumeUsd * 1e18;

        progressP = s.startReferrerFeeP * ConstantsUtils.P_10;
        progressP +=
            ((100 * ConstantsUtils.P_10 - progressP) *
                (volumeReferredUsd > targetVolumeUsd1e18 ? targetVolumeUsd1e18 : volumeReferredUsd)) /
            targetVolumeUsd1e18;
    }

    /**
     * @dev Check IReferralsUtils interface for documentation
     */
    function getTraderLastReferrer(address _trader) internal view returns (address) {
        return _getStorage().referrerByTrader[_trader];
    }

    /**
     * @dev Check IReferralsUtils interface for documentation
     */
    function getTraderActiveReferrer(address _trader) internal view returns (address) {
        address referrer = getTraderLastReferrer(_trader);
        return getReferrerDetails(referrer).active ? referrer : address(0);
    }

    /**
     * @dev Check IReferralsUtils interface for documentation
     */
    function getReferrersReferred(address _ally) internal view returns (address[] memory) {
        return getAllyDetails(_ally).referrersReferred;
    }

    /**
     * @dev Check IReferralsUtils interface for documentation
     */
    function getTradersReferred(address _referrer) internal view returns (address[] memory) {
        return getReferrerDetails(_referrer).tradersReferred;
    }

    /**
     * @dev Check IReferralsUtils interface for documentation
     */
    function getReferralsAllyFeeP() internal view returns (uint256) {
        return _getStorage().allyFeeP;
    }

    /**
     * @dev Check IReferralsUtils interface for documentation
     */
    function getReferralsStartReferrerFeeP() internal view returns (uint256) {
        return _getStorage().startReferrerFeeP;
    }

    /**
     * @dev Check IReferralsUtils interface for documentation
     */
    function getReferralsTargetVolumeUsd() internal view returns (uint256) {
        return _getStorage().targetVolumeUsd;
    }

    /**
     * @dev Check IReferralsUtils interface for documentation
     */
    function getAllyDetails(address _ally) internal view returns (IReferralsUtils.AllyDetails memory) {
        return _getStorage().allyDetails[_ally];
    }

    /**
     * @dev Check IReferralsUtils interface for documentation
     */
    function getReferrerDetails(address _referrer) internal view returns (IReferralsUtils.ReferrerDetails storage) {
        return _getStorage().referrerDetails[_referrer];
    }

    function getReferralSettingsOverrides(
        address _address
    ) internal view returns (IReferralsUtils.ReferralSettingsOverrides memory) {
        return _getStorage().referralSettingsOverrides[_address];
    }

    /**
     * @dev Returns storage slot to use when fetching storage relevant to library
     */
    function _getSlot() internal pure returns (uint256) {
        return StorageUtils.GLOBAL_REFERRALS_SLOT;
    }

    /**
     * @dev Returns storage pointer for storage struct in diamond contract, at defined slot
     */
    function _getStorage() internal pure returns (IReferralsUtils.ReferralsStorage storage s) {
        uint256 storageSlot = _getSlot();
        assembly {
            s.slot := storageSlot
        }
    }

    /**
     * @dev Whitelists new ally
     * @param _ally address of ally
     */
    function _whitelistAlly(address _ally) internal {
        if (_ally == address(0)) revert IGeneralErrors.ZeroAddress();

        IReferralsUtils.AllyDetails storage a = _getStorage().allyDetails[_ally];
        if (a.active) revert IReferralsUtils.AlreadyActive();

        a.active = true;

        emit IReferralsUtils.AllyWhitelisted(_ally);
    }

    /**
     * @dev Unwhitelists ally
     * @param _ally address of ally
     */
    function _unwhitelistAlly(address _ally) internal {
        IReferralsUtils.AllyDetails storage a = _getStorage().allyDetails[_ally];
        if (!a.active) revert IReferralsUtils.AlreadyInactive();

        a.active = false;

        emit IReferralsUtils.AllyUnwhitelisted(_ally);
    }

    /**
     * @dev Whitelists new referrer
     * @param _referrer address of referrer
     * @param _ally address of ally
     */
    function _whitelistReferrer(address _referrer, address _ally) internal {
        if (_referrer == address(0)) revert IGeneralErrors.ZeroAddress();
        IReferralsUtils.ReferralsStorage storage s = _getStorage();

        IReferralsUtils.ReferrerDetails storage r = s.referrerDetails[_referrer];
        if (r.active) revert IReferralsUtils.AlreadyActive();

        r.active = true;

        if (_ally != address(0)) {
            IReferralsUtils.AllyDetails storage a = s.allyDetails[_ally];
            if (!a.active) revert IReferralsUtils.AllyNotActive();

            r.ally = _ally;
            a.referrersReferred.push(_referrer);
        }

        emit IReferralsUtils.ReferrerWhitelisted(_referrer, _ally);
    }

    /**
     * @dev Unwhitelists referrer
     * @param _referrer address of referrer
     */
    function _unwhitelistReferrer(address _referrer) internal {
        IReferralsUtils.ReferrerDetails storage r = _getStorage().referrerDetails[_referrer];
        if (!r.active) revert IReferralsUtils.AlreadyInactive();

        r.active = false;

        emit IReferralsUtils.ReferrerUnwhitelisted(_referrer);
    }
}
