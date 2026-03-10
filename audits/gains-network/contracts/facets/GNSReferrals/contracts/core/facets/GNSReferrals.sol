// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../abstract/GNSAddressStore.sol";

import "../../interfaces/libraries/IReferralsUtils.sol";

import "../../libraries/ReferralsUtils.sol";

/**
 * @dev Facet #2: Referral system
 */
contract GNSReferrals is GNSAddressStore, IReferralsUtils {
    // Initialization

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IReferralsUtils
    function initializeReferrals(
        uint256 _allyFeeP,
        uint256 _startReferrerFeeP,
        uint256 _targetVolumeUsd
    ) external reinitializer(3) {
        ReferralsUtils.initializeReferrals(_allyFeeP, _startReferrerFeeP, _targetVolumeUsd);
    }

    // Management Setters

    /// @inheritdoc IReferralsUtils
    function updateAllyFeeP(uint256 _value) external onlyRole(Role.GOV) {
        ReferralsUtils.updateAllyFeeP(_value);
    }

    /// @inheritdoc IReferralsUtils
    function updateStartReferrerFeeP(uint256 _value) external onlyRole(Role.GOV) {
        ReferralsUtils.updateStartReferrerFeeP(_value);
    }

    /// @inheritdoc IReferralsUtils
    function updateReferralsTargetVolumeUsd(uint256 _value) external onlyRole(Role.GOV) {
        ReferralsUtils.updateReferralsTargetVolumeUsd(_value);
    }

    /// @inheritdoc IReferralsUtils
    function whitelistAllies(address[] calldata _allies) external onlyRole(Role.GOV) {
        ReferralsUtils.whitelistAllies(_allies);
    }

    /// @inheritdoc IReferralsUtils
    function unwhitelistAllies(address[] calldata _allies) external onlyRole(Role.GOV) {
        ReferralsUtils.unwhitelistAllies(_allies);
    }

    /// @inheritdoc IReferralsUtils
    function whitelistReferrers(
        address[] calldata _referrers,
        address[] calldata _allies
    ) external onlyRoles(Role.GOV, Role.MANAGER) {
        ReferralsUtils.whitelistReferrers(_referrers, _allies);
    }

    /// @inheritdoc IReferralsUtils
    function unwhitelistReferrers(address[] calldata _referrers) external onlyRole(Role.GOV) {
        ReferralsUtils.unwhitelistReferrers(_referrers);
    }

    /// @inheritdoc IReferralsUtils
    function overrideReferralFeeP(
        address[] calldata _referrers,
        uint24[] calldata _referralFeeP
    ) external onlyRoles(Role.GOV, Role.MANAGER) {
        ReferralsUtils.overrideReferralFeeP(_referrers, _referralFeeP);
    }

    /// @inheritdoc IReferralsUtils
    function overrideAllyFeeP(address[] calldata _allies, uint24[] calldata _allyFeeP) external onlyRole(Role.GOV) {
        ReferralsUtils.overrideAllyFeeP(_allies, _allyFeeP);
    }

    /// @inheritdoc IReferralsUtils
    function unsetTradersReferrers(address[] calldata _traders) external onlyRoles(Role.GOV, Role.GOV_EMERGENCY) {
        ReferralsUtils.unsetTradersReferrers(_traders);
    }

    // Interactions

    /// @inheritdoc IReferralsUtils
    function registerPotentialReferrer(address _trader, address _referrer) external virtual onlySelf {
        ReferralsUtils.registerPotentialReferrer(_trader, _referrer);
    }

    /// @inheritdoc IReferralsUtils
    function distributeReferralReward(
        address _trader,
        uint256 _volumeUsd,
        uint256 _referrerFeeUsd,
        uint256 _gnsPriceUsd
    ) external virtual onlySelf {
        return ReferralsUtils.distributeReferralReward(_trader, _volumeUsd, _referrerFeeUsd, _gnsPriceUsd);
    }

    /// @inheritdoc IReferralsUtils
    function claimAllyRewards() external {
        ReferralsUtils.claimAllyRewards();
    }

    /// @inheritdoc IReferralsUtils
    function claimReferrerRewards() external {
        ReferralsUtils.claimReferrerRewards();
    }

    // Getters

    /// @inheritdoc IReferralsUtils
    function getReferrerFeeProgressP(address _referrer) external view returns (uint256) {
        return ReferralsUtils.getReferrerFeeProgressP(_referrer);
    }

    /// @inheritdoc IReferralsUtils
    function getTraderLastReferrer(address _trader) external view returns (address) {
        return ReferralsUtils.getTraderLastReferrer(_trader);
    }

    /// @inheritdoc IReferralsUtils
    function getTraderActiveReferrer(address _trader) external view returns (address) {
        return ReferralsUtils.getTraderActiveReferrer(_trader);
    }

    /// @inheritdoc IReferralsUtils
    function getReferrersReferred(address _ally) external view returns (address[] memory) {
        return ReferralsUtils.getReferrersReferred(_ally);
    }

    /// @inheritdoc IReferralsUtils
    function getTradersReferred(address _referrer) external view returns (address[] memory) {
        return ReferralsUtils.getTradersReferred(_referrer);
    }

    /// @inheritdoc IReferralsUtils
    function getReferralsAllyFeeP() external view returns (uint256) {
        return ReferralsUtils.getReferralsAllyFeeP();
    }

    /// @inheritdoc IReferralsUtils
    function getReferralsStartReferrerFeeP() external view returns (uint256) {
        return ReferralsUtils.getReferralsStartReferrerFeeP();
    }

    /// @inheritdoc IReferralsUtils
    function getReferralsTargetVolumeUsd() external view returns (uint256) {
        return ReferralsUtils.getReferralsTargetVolumeUsd();
    }

    /// @inheritdoc IReferralsUtils
    function getAllyDetails(address _ally) external view returns (AllyDetails memory) {
        return ReferralsUtils.getAllyDetails(_ally);
    }

    /// @inheritdoc IReferralsUtils
    function getReferrerDetails(address _referrer) external view returns (ReferrerDetails memory) {
        return ReferralsUtils.getReferrerDetails(_referrer);
    }

    /// @inheritdoc IReferralsUtils
    function getReferralSettingsOverrides(address _address) external view returns (ReferralSettingsOverrides memory) {
        return ReferralsUtils.getReferralSettingsOverrides(_address);
    }
}
