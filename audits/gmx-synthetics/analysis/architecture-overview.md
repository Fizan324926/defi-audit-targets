# GMX V2 Synthetics - Architecture Overview

## Protocol Summary
GMX V2 is a decentralized perpetual exchange built on Arbitrum and Avalanche. It allows users to trade perpetual futures with up to 100x leverage, provide liquidity via GM tokens, and access multi-market vaults via GLV tokens.

## Key Architecture Patterns

### 1. Two-Step Execution Model
All user actions follow a request-then-execute pattern:
1. User submits request (deposit, withdrawal, order) via ExchangeRouter
2. Keeper executes the request with signed oracle prices
3. This prevents front-running and MEV on request creation

### 2. DataStore as Central State
All protocol state is stored in a central DataStore contract using key-value mappings. This means:
- No contract-level storage variables for positions, orders, etc.
- Cross-contract state sharing via common keys
- Global reentrancy guard stored in DataStore

### 3. Contract Hierarchy
```
ExchangeRouter (User Entry) → Handlers → Utils Libraries → DataStore
                                ↓
                            Oracle (Price Setting/Clearing)
```

### 4. Oracle System
Multiple oracle providers:
- ChainlinkPriceFeedProvider (on-chain feeds)
- ChainlinkDataStreamProvider (off-chain data streams with bid/ask)
- EdgeDataStreamProvider (alternative off-chain data)
- GmOracleProvider (GM token prices from pool values)

Prices stored as min/max (bid/ask) spread for each token.

### 5. Market Structure
Each market has:
- Index token (the asset being traded)
- Long token (collateral for longs)
- Short token (collateral for shorts)
- Market token (GM token for LPs)

### 6. Fee Structure
- Position fees (basis points of size delta)
- Borrowing fees (accumulated per second)
- Funding fees (per-side imbalance payments)
- Swap fees (for token exchanges)
- UI fees (optional, for frontend operators)

### 7. Price Impact
Price impact is calculated based on open interest imbalance:
- Actions that improve balance get positive impact (bonus)
- Actions that worsen balance get negative impact (penalty)
- Impact pools store accumulated impact amounts

### 8. Cross-Chain (Multichain)
New multichain system using LayerZero/Stargate:
- MultichainVault holds cross-chain user balances
- LayerZeroProvider receives bridged tokens
- Actions can be triggered from source chains
- Balance tracked per (account, token) in DataStore

### 9. Gasless Relay (Gelato)
EIP-712 signatures for meta-transactions:
- Users sign operations off-chain
- Gelato relayers submit transactions
- Fee paid from user's token balance (with optional swap)
- Subaccount system for delegated trading

## Critical Contract Sizes (Lines of Code)
| Contract | Lines | Role |
|----------|-------|------|
| MarketUtils.sol | 3,375 | Market state management |
| Keys.sol | 2,409 | DataStore key definitions |
| RelayUtils.sol | 902 | EIP-712 signature hashing |
| PositionUtils.sol | 806 | Position lifecycle |
| DecreasePositionCollateralUtils.sol | 759 | Collateral waterfall |
| GasUtils.sol | 695 | Fee estimation |
| PositionPricingUtils.sol | 652 | Position fee calculations |
| LayerZeroProvider.sol | 593 | Cross-chain bridge |
| OrderUtils.sol | 485 | Order lifecycle |
| BaseGelatoRelayRouter.sol | 444 | Relay infrastructure |

## Attack Surface Map
1. **Entry Points**: ExchangeRouter, GlvRouter, SubaccountRouter, MultichainRouter
2. **External Calls**: ExternalHandler (arbitrary calls), LayerZeroProvider (bridge), Callbacks
3. **Price Oracle**: Multiple providers with timestamp/staleness checks
4. **Token Transfers**: WNT wrapping, native token handling, cross-chain bridges
5. **Fee Calculations**: Complex waterfall with rounding in multiple divisions
6. **State Management**: DataStore key collisions, reentrancy guard in storage
