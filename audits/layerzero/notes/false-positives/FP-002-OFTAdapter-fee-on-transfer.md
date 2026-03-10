# FP-002: OFTAdapter Fee-On-Transfer Token Accounting Mismatch

## Classification: FALSE POSITIVE (Documented Design Limitation)

## Location
- `/root/defi-audit-targets/audits/layerzero/LayerZero-v2/packages/layerzero-v2/evm/oapp/contracts/oft/OFTAdapter.sol` lines 74-83
- `/root/defi-audit-targets/audits/layerzero/devtools/packages/oft-evm/contracts/OFTAdapter.sol` lines 74-83

## Description
If the underlying ERC20 token has a fee-on-transfer mechanism, the default OFTAdapter will:
1. Calculate `amountSentLD = _removeDust(amountLD)` (e.g., 100 tokens)
2. Call `safeTransferFrom(user, adapter, 100)` -- but only 95 arrive (5% fee)
3. Encode 100 in the cross-chain message
4. Destination mints/unlocks 100 tokens
5. Net inflation: 5 tokens per bridge

## Why Not A Vulnerability
The code explicitly documents this as a known limitation with warnings:
```
WARNING: The default OFTAdapter implementation assumes LOSSLESS transfers, ie. 1 token in, 1 token out.
IF the 'innerToken' applies something like a transfer fee, the default will NOT work...
a pre/post balance check will need to be done to calculate the amountSentLD/amountReceivedLD.
```

This warning appears in BOTH the `_debit()` and `_credit()` functions. It is a deployment-time responsibility, not an exploitable bug.

## Correct Implementation for Fee-On-Transfer Tokens
```solidity
function _debit(address _from, uint256 _amountLD, uint256 _minAmountLD, uint32 _dstEid)
    internal override returns (uint256 amountSentLD, uint256 amountReceivedLD)
{
    (amountSentLD, amountReceivedLD) = _debitView(_amountLD, _minAmountLD, _dstEid);
    uint256 balBefore = innerToken.balanceOf(address(this));
    innerToken.safeTransferFrom(_from, address(this), amountSentLD);
    uint256 actualReceived = innerToken.balanceOf(address(this)) - balBefore;
    amountReceivedLD = actualReceived;
}
```
