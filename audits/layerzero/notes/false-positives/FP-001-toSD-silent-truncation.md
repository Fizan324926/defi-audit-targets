# FP-001: _toSD() Silent uint64 Truncation

## Classification: LOW Severity (not exploitable with default parameters)

## Location
- V2 Main: `/root/defi-audit-targets/audits/layerzero/LayerZero-v2/packages/layerzero-v2/evm/oapp/contracts/oft/OFTCore.sol` lines 335-337
- Devtools (fixed): `/root/defi-audit-targets/audits/layerzero/devtools/packages/oft-evm/contracts/OFTCore.sol` lines 364-368

## Vulnerable Code (V2 main)
```solidity
function _toSD(uint256 _amountLD) internal view virtual returns (uint64 amountSD) {
    return uint64(_amountLD / decimalConversionRate);
}
```

## Fixed Code (devtools)
```solidity
function _toSD(uint256 _amountLD) internal view virtual returns (uint64 amountSD) {
    uint256 _amountSD = _amountLD / decimalConversionRate;
    if (_amountSD > type(uint64).max) revert AmountSDOverflowed(_amountSD);
    return uint64(_amountSD);
}
```

## Why NOT Critical
With default sharedDecimals=6 and localDecimals=18, overflow requires sending >18.4 trillion tokens in a single transaction, exceeding all practical token supplies.

## Why Still Documented
The devtools team added the explicit check, confirming awareness. Custom implementations with sharedDecimals close to localDecimals could theoretically be vulnerable.

## Attack Path (Theoretical, Non-Default Config)
1. Deploy OFT with sharedDecimals=18, localDecimals=18 (decimalConversionRate=1)
2. Acquire >18.44 tokens (18446744073709551616 wei)
3. Call send() with amountLD = 19e18
4. _removeDust(19e18) = 19e18 (rate=1, no dust)
5. _debit burns 19e18 tokens from sender
6. _toSD(19e18) = uint64(19e18) wraps to 553255926290448384
7. Message encodes amountSD = 553255926290448384
8. Destination credits _toLD(553255926290448384) = 0.553 tokens
9. Net loss: 18.447 tokens burned, 0.553 credited = 17.89 tokens destroyed

This is a LOSS for the attacker, not a gain. Tokens are destroyed, not stolen.
