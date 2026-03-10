// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../abstract/GNSAddressStore.sol";

import "../../interfaces/libraries/ITriggerRewardsUtils.sol";

import "../../libraries/TriggerRewardsUtils.sol";
import "../../libraries/ChainUtils.sol";

/**
 * @dev Facet #6: Trigger rewards
 */
contract GNSTriggerRewards is GNSAddressStore, ITriggerRewardsUtils {
    // Initialization

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc ITriggerRewardsUtils
    function initializeTriggerRewards(uint16 _timeoutBlocks) external reinitializer(7) {
        TriggerRewardsUtils.initializeTriggerRewards(_timeoutBlocks);
    }

    // Management Setters

    /// @inheritdoc ITriggerRewardsUtils
    function updateTriggerTimeoutBlocks(uint16 _timeoutBlocks) external onlyRole(Role.GOV) {
        TriggerRewardsUtils.updateTriggerTimeoutBlocks(_timeoutBlocks);
    }

    // Interactions

    /// @inheritdoc ITriggerRewardsUtils
    function distributeTriggerReward(uint256 _rewardGns) external virtual onlySelf {
        TriggerRewardsUtils.distributeTriggerReward(_rewardGns);
    }

    /// @inheritdoc ITriggerRewardsUtils
    function claimPendingTriggerRewards(address _oracle) external {
        TriggerRewardsUtils.claimPendingTriggerRewards(_oracle); // access control in library
    }

    // Getters

    function getTriggerTimeoutBlocks() external view returns (uint16) {
        return TriggerRewardsUtils.getTriggerTimeoutBlocks();
    }

    /// @inheritdoc ITriggerRewardsUtils
    function hasActiveOrder(uint256 _orderBlock) external view returns (bool) {
        return TriggerRewardsUtils.hasActiveOrder(_orderBlock, ChainUtils.getBlockNumber());
    }

    /// @inheritdoc ITriggerRewardsUtils
    function getTriggerPendingRewardsGns(address _oracle) external view returns (uint256) {
        return TriggerRewardsUtils.getTriggerPendingRewardsGns(_oracle);
    }
}
