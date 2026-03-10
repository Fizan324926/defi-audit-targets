# False Positive: DssLitePsm.cut() Potential Underflow

**Claimed:** MEDIUM - underflow in cut() when `cash + gemBal18 < art`
**Verdict:** FALSE POSITIVE — invariant maintained by design

## Why This Is Not Exploitable

The `cut()` function:
```solidity
function cut() public view returns (uint256 wad) {
    (, uint256 art) = vat.urns(ilk, address(this));
    uint256 cash = dai.balanceOf(address(this));
    wad = _min(cash, cash + gem.balanceOf(pocket) * to18ConversionFactor - art);
}
```

The `_min` call's second argument `cash + gemBal18 - art` would underflow if `cash + gemBal18 < art`. However:

### Invariant: art <= cash + gemBal18 Always Holds

Through normal operations:
- `sellGem`: user deposits gem, PSM mints DAI to user. `gemBal18 += amount`, `art += amount`. Ratio maintained.
- `buyGem`: user deposits DAI, PSM repays vat debt and returns gem. `cash += daiIn`, `art -= daiOut`, `gemBal18 -= gemOut`. Net: `art` decreases as `cash` increases.
- `fill()`: mints pre-buffered DAI into cash. `art += buffSize`, `cash += buffSize`. Ratio maintained.
- `trim()`: repays excess debt. `art -= excess`, `cash -= excess`. Ratio maintained.
- Fees (tin/tout): always added to cash or gemBal18, never subtracted from.

The invariant `art <= cash + gemBal18` is maintained through all normal operations. An underflow would require:
1. A bug in the fee accounting (not present)
2. Direct Vat.grab() by a ward (emergency shutdown scenario)
3. Malicious trusted-role manipulation (wards are trusted per scope rules)

### Conclusion

The underflow requires either a governance attack (trusted roles) or a pre-existing bug elsewhere. Under normal operation, the invariant holds and `cut()` is safe.
