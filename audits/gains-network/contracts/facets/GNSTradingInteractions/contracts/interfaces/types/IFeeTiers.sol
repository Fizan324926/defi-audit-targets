// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/**
 * @dev Contains the types for the GNSFeeTiers facet
 */
interface IFeeTiers {
    struct FeeTiersStorage {
        // Volume Fee Tiers
        FeeTier[8] feeTiers;
        mapping(uint256 => uint256) groupVolumeMultipliers; // groupIndex (pairs storage) => multiplier (1e3)
        mapping(address => TraderInfo) traderInfos; // trader => TraderInfo
        mapping(address => mapping(uint32 => TraderDailyInfo)) traderDailyInfos; // trader => day => TraderDailyInfo
        mapping(address => TraderEnrollment) traderEnrollments; // trader => TraderEnrollment
        mapping(address => uint224) unclaimedPoints; // trader => points (1e18)
        // Staking Tiers
        FeeTier[8] gnsStakingTiers;
        mapping(address => GnsStakingInfo) gnsStakingInfos; // trader => staking info
        address gnsVaultAddress; // gGNS or any other GNS ERC4626 vault
        bool useGnsVaultBalance; // if true, gnsVaultAddress balance is used for tier calculation
        uint88 __placeholder;
        // Gap
        uint256[27] __gap;
    }

    enum TraderEnrollmentStatus {
        ENROLLED,
        EXCLUDED
    }

    enum CreditType {
        IMMEDIATE,
        CLAIMABLE
    }

    struct FeeTier {
        uint32 feeMultiplier; // 1e3
        uint32 pointsThreshold; // 0 precision; GNS amount or volume points
    }

    struct TraderInfo {
        uint32 lastDayUpdated;
        uint224 trailingPoints; // 1e18
    }

    struct TraderDailyInfo {
        uint32 feeMultiplierCache; // 1e3
        uint224 points; // 1e18
    }

    struct TraderEnrollment {
        TraderEnrollmentStatus status;
        uint248 __placeholder;
    }

    struct GnsStakingInfo {
        uint88 stakedGns; // 1e18
        uint88 stakedVaultGns; // 1e18
        uint24 bonusAmount; // 0 precision
        uint32 stakeTimestamp;
        uint32 feeMultiplierCache; // 1e3
    }
}
