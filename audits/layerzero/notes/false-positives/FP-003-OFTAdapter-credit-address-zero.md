# FP-003: OFTAdapter._credit() Missing address(0) -> 0xdead Redirect

## Classification: FALSE POSITIVE

## Location
- `/root/defi-audit-targets/audits/layerzero/LayerZero-v2/packages/layerzero-v2/evm/oapp/contracts/oft/OFTAdapter.sol` lines 96-105
- `/root/defi-audit-targets/audits/layerzero/devtools/packages/oft-evm/contracts/OFTAdapter.sol` lines 96-105

## Observation
OFT._credit() has the protection:
```solidity
if (_to == address(0x0)) _to = address(0xdead);
```

OFTAdapter._credit() does NOT:
```solidity
function _credit(address _to, uint256 _amountLD, uint32) internal virtual override returns (uint256) {
    innerToken.safeTransfer(_to, _amountLD);
    return _amountLD;
}
```

## Why Not Exploitable
1. OFT._credit() redirects because `_mint(address(0), amount)` would revert in OZ's ERC20.
2. OFTAdapter._credit() calls `safeTransfer(address(0), amount)`.
3. OpenZeppelin's ERC20.transfer() already reverts for address(0):
   ```solidity
   require(to != address(0), "ERC20: transfer to the zero address");
   ```
4. Most standard ERC20 implementations follow this pattern.
5. If a non-standard token allows transfers to address(0), the tokens would be burned (sent to 0), which is a token design issue, not an OFTAdapter vulnerability.

## Conclusion
The missing redirect is not needed because `safeTransfer` to address(0) reverts on standard tokens. If a non-standard token allows it, the tokens are simply burned, which is the same effective outcome as sending to 0xdead (both make tokens unrecoverable).
