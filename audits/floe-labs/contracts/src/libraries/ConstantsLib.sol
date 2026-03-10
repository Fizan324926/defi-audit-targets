// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

// ============ Basis Points ============
uint256 constant BASIS_POINTS = 100_00;

// ============ EIP-712 Typehashes ============
bytes32 constant EIP712_DOMAIN_TYPEHASH =
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

bytes32 constant LENDER_INTENT_TYPEHASH = keccak256(
    "LendIntent(address lender,address onBehalfOf,uint256 amount,uint256 minFillAmount,uint256 filledAmount,uint256 minInterestRateBps,uint256 maxLtvBps,uint256 minDuration,uint256 maxDuration,bool allowPartialFill,uint256 validFromTimestamp,uint256 expiry,bytes32 marketId,bytes32 salt,uint256 chainId,bytes32 conditionsHash,bytes32 preHooksHash,bytes32 postHooksHash)"
);

bytes32 constant BORROWER_INTENT_TYPEHASH = keccak256(
    "BorrowIntent(address borrower,address onBehalfOf,uint256 borrowAmount,uint256 collateralAmount,uint256 minFillAmount,uint256 maxInterestRateBps,uint256 minLtvBps,uint256 minDuration,uint256 maxDuration,bool allowPartialFill,uint256 validFromTimestamp,uint256 matcherCommissionBps,uint256 expiry,bytes32 marketId,bytes32 salt,uint256 chainId,bytes32 conditionsHash,bytes32 preHooksHash,bytes32 postHooksHash)"
);

bytes32 constant CONDITION_TYPEHASH = keccak256("Condition(address target,bytes callData,bool applyToAllPartialFills)");

bytes32 constant HOOK_TYPEHASH = keccak256(
    "Hook(address target,bytes callData,uint256 gasLimit,uint256 expiry,bool allowFailure,bool applyToAllPartialFills)"
);

// ============ Protocol Constants ============
uint256 constant ORACLE_PRICE_SCALE = 1e18 * 1e18; // 1e36
uint256 constant MAX_LIQUIDATION_INCENTIVE_BPS = 105_00; // Maximum 105% liquidator bonus (typical market uses 5%)
uint256 constant MAX_PROTOCOL_FEE_BPS = 25_00; // 25% maximum fee
uint256 constant MAX_INTEREST_RATE_BPS = 800_00; // 800% maximum interest rate
uint256 constant MAX_LTV_BPS = 90_00; // 90% maximum LTV
uint256 constant CHAINLINK_STALENESS_TIMEOUT = 3600; // 1 hour in seconds
uint256 constant DEFAULT_FLASHLOAN_FEE_BPS = 5; // 0.05% flashloan fee
uint256 constant DEFAULT_MAX_PRICE_DEVIATION_BPS = 10_00; // 10% maximum price deviation
uint256 constant DEFAULT_WITHDRAWAL_BUFFER_BPS = 8_00; // 8% buffer from liquidation threshold
uint256 constant MAX_WITHDRAWAL_BUFFER_BPS = 20_00; // 20% maximum buffer
uint256 constant DEFAULT_MIN_LTV_GAP_BPS = 8_00; // 8% default minimum gap between initial LTV and liquidation threshold
uint256 constant MAX_MIN_LTV_GAP_BPS = 20_00; // 20% maximum configurable gap

// ============ L2 Sequencer Constants ============
/// @dev Default grace period after L2 sequencer comes back up (1 hour)
/// @dev During this period, Chainlink feeds may still be stale
uint256 constant DEFAULT_SEQUENCER_GRACE_PERIOD = 3600; // 1 hour in seconds

// ============ Protocol Metadata ============
string constant PROTOCOL_NAME = "LendingIntentMatcher";
string constant PROTOCOL_VERSION = "1";
