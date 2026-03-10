// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "./GNSAddressStore.sol";

import "../../interfaces/types/ITypes.sol";

/**
 * @dev Sets storage slot layout for diamond facets.
 */
abstract contract GNSDiamondStorage is GNSAddressStore, ITypes {
    PairsStorage private pairsStorage;
    ReferralsStorage private referralsStorage;
    FeeTiersStorage private feeTiersStorage;
    PriceImpactStorage private priceImpactStorage;
    DiamondStorage private diamondStorage;
    TradingStorage private tradingStorage;
    TriggerRewardsStorage private triggerRewardsStorage;
    TradingInteractionsStorage private tradingInteractionsStorage;
    TradingCallbacksStorage private tradingCallbacksStorage;
    BorrowingFeesStorage private borrowingFeesStorage;
    PriceAggregatorStorage private priceAggregatorStorage;
    OtcStorage private otcStorage;
    ChainConfigStorage private chainConfigStorage;
    FundingFeesStorage private fundingFeesStorage;

    // New storage goes at end of list
}
