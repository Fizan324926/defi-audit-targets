// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../types/IFeeTiers.sol";

/**
 * @dev Interface for GNSFeeTiers facet (inherits types and also contains functions, events, and custom errors)
 */
interface IFeeTiersUtils is IFeeTiers {
    /**
     *
     * @param _groupIndices group indices (pairs storage fee index) to initialize
     * @param _groupVolumeMultipliers corresponding group volume multipliers (1e3)
     * @param _feeTiersIndices fee tiers indices to initialize
     * @param _feeTiers fee tiers values to initialize (feeMultiplier, pointsThreshold)
     */
    function initializeFeeTiers(
        uint256[] calldata _groupIndices,
        uint256[] calldata _groupVolumeMultipliers,
        uint256[] calldata _feeTiersIndices,
        IFeeTiersUtils.FeeTier[] calldata _feeTiers
    ) external;

    /**
     * @dev Updates groups volume multipliers
     * @param _groupIndices indices of groups to update
     * @param _groupVolumeMultipliers corresponding new volume multipliers (1e3)
     */
    function setGroupVolumeMultipliers(
        uint256[] calldata _groupIndices,
        uint256[] calldata _groupVolumeMultipliers
    ) external;

    /**
     * @dev Updates fee tiers
     * @param _feeTiersIndices indices of fee tiers to update
     * @param _feeTiers new fee tiers values (feeMultiplier, pointsThreshold)
     */
    function setFeeTiers(uint256[] calldata _feeTiersIndices, IFeeTiersUtils.FeeTier[] calldata _feeTiers) external;

    /**
     * @dev Updates traders enrollment status in fee tiers program, including staking tier discounts
     * @param _traders group of traders
     * @param _values corresponding enrollment values
     */
    function setTradersFeeTiersEnrollment(
        address[] calldata _traders,
        IFeeTiersUtils.TraderEnrollment[] calldata _values
    ) external;

    /**
     * @dev Credits points to traders
     * @param _traders traders addresses
     * @param _creditTypes types of credit (IMMEDIATE, CLAIMABLE)
     * @param _points points to credit (1e18)
     */
    function addTradersUnclaimedPoints(
        address[] calldata _traders,
        IFeeTiersUtils.CreditType[] calldata _creditTypes,
        uint224[] calldata _points
    ) external;

    /**
     * @dev Increases daily points from a new trade, re-calculate trailing points, and cache daily fee tier for a trader.
     * @param _trader trader address
     * @param _volumeUsd trading volume in USD (1e18)
     * @param _pairIndex pair index
     */
    function updateTraderPoints(address _trader, uint256 _volumeUsd, uint256 _pairIndex) external;

    /**
     * @dev Returns fee amount after applying the trader's active fee tier and staking tier multiplier
     * @param _trader address of trader
     * @param _normalFeeAmountCollateral base fee amount (collateral precision)
     */
    function calculateFeeAmount(address _trader, uint256 _normalFeeAmountCollateral) external view returns (uint256);

    /**
     * Returns the current number of active fee tiers
     */
    function getFeeTiersCount() external view returns (uint256);

    /**
     * @dev Returns a fee tier's details (feeMultiplier, pointsThreshold)
     * @param _feeTierIndex fee tier index
     */
    function getFeeTier(uint256 _feeTierIndex) external view returns (IFeeTiersUtils.FeeTier memory);

    /**
     * @dev Returns fee tier details (feeMultiplier, pointsThreshold) for all active tiers
     */
    function getFeeTiers() external view returns (IFeeTiers.FeeTier[] memory);

    /**
     * @dev Returns a group's volume multiplier
     * @param _groupIndex group index (pairs storage fee index)
     */
    function getGroupVolumeMultiplier(uint256 _groupIndex) external view returns (uint256);

    /**
     * @dev Returns a list of group volume multipliers
     * @param _groupIndices group indices
     */
    function getGroupVolumeMultipliers(uint256[] calldata _groupIndices) external view returns (uint256[] memory);

    /**
     * @dev Returns a trader's info (lastDayUpdated, trailingPoints)
     * @param _trader trader address
     */
    function getFeeTiersTraderInfo(address _trader) external view returns (IFeeTiersUtils.TraderInfo memory);

    /**
     * @dev Returns a trader's daily fee tier info (feeMultiplierCache, points)
     * @param _trader trader address
     * @param _day day
     */
    function getFeeTiersTraderDailyInfo(
        address _trader,
        uint32 _day
    ) external view returns (IFeeTiersUtils.TraderDailyInfo memory);

    /**
     * @dev Returns a trader's daily fee tier info (feeMultiplierCache, points) for an array of days
     * @param _trader trader address
     * @param _days array of days
     */
    function getFeeTiersTraderDailyInfoArray(
        address _trader,
        uint32[] calldata _days
    ) external view returns (IFeeTiersUtils.TraderDailyInfo[] memory);

    /**
     * @dev Returns a trader's fee tiers enrollment status
     * @param _trader trader address
     */
    function getTraderFeeTiersEnrollment(
        address _trader
    ) external view returns (IFeeTiersUtils.TraderEnrollment memory);

    /**
     * @dev Returns a trader's unclaimed points, credited by Governance
     * @param _trader trader address
     */
    function getTraderUnclaimedPoints(address _trader) external view returns (uint224);

    /**
     * @dev Initializes GNS staking with tier configuration
     * @param _tierIndices tier indices to initialize
     * @param _tiers tier configurations (discountP, gnsThreshold)
     * @param _gnsVaultAddress address for gGNS or another ERC4626 GNS vault
     * @param _useGnsVaultBalance if true, gnsVaultAddress balance is used for tier calculation
     */
    function initializeGnsStakingTiers(
        uint256[] calldata _tierIndices,
        IFeeTiers.FeeTier[] calldata _tiers,
        address _gnsVaultAddress,
        bool _useGnsVaultBalance
    ) external;

    /**
     * @dev Updates GNS staking tiers
     * @param _tierIndices indices of tiers to update
     * @param _tiers new tier configurations (discountP, gnsThreshold)
     */
    function setGnsStakingTiers(uint256[] calldata _tierIndices, IFeeTiers.FeeTier[] calldata _tiers) external;

    /**
     * @dev Updated whether to use gGNS balance for tier calculation
     * @param _useGnsVaultBalance new value
     */
    function setUseGnsVaultBalance(bool _useGnsVaultBalance) external;

    /**
     * @dev Sets bonus GNS amounts for traders. Counts towards staking tier calculation, but is not withdrawable.
     * @param _traders trader addresses
     * @param _bonusAmounts bonus GNS amounts (no precision)
     */
    function setGnsStakingBonusAmounts(address[] calldata _traders, uint24[] calldata _bonusAmounts) external;

    /**
     * @dev Syncs cached discount tiers for traders based on current tier configuration. Used to force a tier refresh in case of tier updates or gGNS repricing.
     * @param _traders trader addresses to sync
     */
    function syncGnsStakingTiers(address[] calldata _traders) external;

    /**
     * @dev Stakes GNS tokens for fee discounts
     * @param _amountGns GNS amount to stake (1e18)
     * @param _amountVaultGns gGNS amount to stake (1e18)
     */
    function stakeGns(uint88 _amountGns, uint88 _amountVaultGns) external;

    /**
     * @dev Unstakes GNS tokens
     * @param _amountGns GNS amount to unstake (1e18)
     * @param _amountVaultGns gGNS amount to unstake (1e18)
     */
    function unstakeGns(uint88 _amountGns, uint88 _amountVaultGns) external;

    /**
     * Returns the current number of active staking tiers
     */
    function getGnsStakingTiersCount() external view returns (uint256);

    /**
     * @dev Returns GNS staking tier configuration
     * @param _tierIndex tier index
     */
    function getGnsStakingTier(uint256 _tierIndex) external view returns (IFeeTiers.FeeTier memory);

    /**
     * @dev Returns GNS staking tier configuration for all active tiers
     */
    function getGnsStakingTiers() external view returns (IFeeTiers.FeeTier[] memory);

    /**
     * @dev Returns GNS vault address used for staking tiers
     */
    function getGnsVaultAddress() external view returns (address);

    /**
     * @dev Returns whether gGNS balance is used for tier calculation
     */
    function getUseGnsVaultBalance() external view returns (bool);

    /**
     * @dev Returns trader's GNS staking information
     * @param _trader trader address
     */
    function getGnsStakingInfo(address _trader) external view returns (IFeeTiers.GnsStakingInfo memory);

    /**
     * @dev Returns multiple traders' GNS staking information
     * @param _traders trader addresses
     */
    function getGnsStakingInfos(address[] calldata _traders) external view returns (IFeeTiers.GnsStakingInfo[] memory);

    /**
     * @dev Returns the GNS value of staked gGNS amount, based on the vault's current price per share. Returns 0 when `useGnsVaultBalance` is false
     * @param _stakedVaultGns staked gGNS amount (1e18)
     */
    function getStakedVaultGnsValue(uint88 _stakedVaultGns) external view returns (uint256);

    /**
     * @dev Emitted when group volume multipliers are updated
     * @param groupIndices indices of updated groups
     * @param groupVolumeMultipliers new corresponding volume multipliers (1e3)
     */
    event GroupVolumeMultipliersUpdated(uint256[] groupIndices, uint256[] groupVolumeMultipliers);

    /**
     * @dev Emitted when fee tiers are updated
     * @param feeTiersIndices indices of updated fee tiers
     * @param feeTiers new corresponding fee tiers values (feeMultiplier, pointsThreshold)
     */
    event FeeTiersUpdated(uint256[] feeTiersIndices, IFeeTiersUtils.FeeTier[] feeTiers);

    /**
     * @dev Emitted when a trader's daily points are updated
     * @param trader trader address
     * @param day day
     * @param points points added (1e18 precision)
     */
    event TraderDailyPointsIncreased(address indexed trader, uint32 indexed day, uint224 points);

    /**
     * @dev Emitted when a trader info is updated for the first time
     * @param trader address of trader
     * @param day day
     */
    event TraderInfoFirstUpdate(address indexed trader, uint32 day);

    /**
     * @dev Emitted when a trader's trailing points are updated
     * @param trader trader address
     * @param fromDay from day
     * @param toDay to day
     * @param expiredPoints expired points amount (1e18 precision)
     */
    event TraderTrailingPointsExpired(address indexed trader, uint32 fromDay, uint32 toDay, uint224 expiredPoints);

    /**
     * @dev Emitted when a trader's info is updated
     * @param trader address of trader
     * @param traderInfo new trader info value (lastDayUpdated, trailingPoints)
     */
    event TraderInfoUpdated(address indexed trader, IFeeTiersUtils.TraderInfo traderInfo);

    /**
     * @dev Emitted when a trader's cached fee multiplier is updated (this is the one used in fee calculations)
     * @param trader address of trader
     * @param day day
     * @param feeMultiplier new fee multiplier (1e3 precision)
     */
    event TraderFeeMultiplierCached(address indexed trader, uint32 indexed day, uint32 feeMultiplier);

    /**
     * @dev Emitted when a trader's enrollment status is updated
     * @param trader address of trader
     * @param enrollment trader's new enrollment status
     */
    event TraderEnrollmentUpdated(address indexed trader, IFeeTiersUtils.TraderEnrollment enrollment);

    /**
     * @dev Emitted when a trader is credited points by governance
     * @param trader trader address
     * @param day day the points were credited on, may be different from the day the points were claimed
     * @param creditType credit type (IMMEDIATE, CLAIMABLE)
     * @param points points added (1e18 precision)
     */
    event TraderPointsCredited(
        address indexed trader,
        uint32 indexed day,
        IFeeTiers.CreditType creditType,
        uint224 points
    );

    /**
     * @dev Emitted when a trader's unclaimed points are claimed
     * @param trader trader address
     * @param day day of claim
     * @param points points added (1e18 precision)
     */
    event TraderUnclaimedPointsClaimed(address indexed trader, uint32 indexed day, uint224 points);

    /**
     * @dev Emitted when GNS staking tiers are updated
     * @param indices tier indices updated
     * @param tiers new tier configurations
     */
    event GnsStakingTiersUpdated(uint256[] indices, IFeeTiers.FeeTier[] tiers);

    /**
     * @dev Emitted when the use of GNS vault balance for tier calculation is updated
     * @param newValue new value
     */
    event UseGnsVaultBalanceUpdated(bool newValue);

    /**
     * @dev Emitted when a trader stakes GNS tokens
     * @param trader trader address
     * @param amountGns GNS amount staked (1e18)
     * @param amountVaultGns gGNS amount staked (1e18)
     */
    event GnsStaked(address indexed trader, uint88 amountGns, uint88 amountVaultGns);

    /**
     * @dev Emitted when a trader unstakes GNS tokens
     * @param trader trader address
     * @param amountGns GNS amount unstaked (1e18)
     * @param amountVaultGns gGNS amount unstaked (1e18)
     */
    event GnsUnstaked(address indexed trader, uint88 amountGns, uint88 amountVaultGns);

    /**
     * @dev Emitted when a trader's gns staking fee multiplier is updated (used in fee calculations, in conjunction with volume fee tiers multiplier)
     * @param feeMultiplier new fee multiplier (1e3 precision)
     */
    event GnsStakingFeeMultiplierCached(address indexed trader, uint32 feeMultiplier);

    /**
     * @dev Emitted when traders' bonus GNS amount is updated
     * @param traders trader addresses
     * @param bonusAmounts bonus amounts (no precision)
     */
    event GnsStakingBonusUpdated(address[] traders, uint24[] bonusAmounts);

    error WrongFeeTier();
    error PointsOverflow();
    error StakingCooldownActive();
}
