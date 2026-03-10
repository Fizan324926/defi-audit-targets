# False Positive: D3M4626TypePool.exit() Division by Zero

**Claimed:** HIGH — `(end.Art(ilk) - exited_)` denominator reaches zero, permanently locking vault shares
**Verdict:** FALSE POSITIVE — not reachable due to vat.slip protection

## Why This Is Not Exploitable

`D3M4626TypePool.exit()` at line 120:
```solidity
uint256 amt = wad * vault.balanceOf(address(this)) / (D3mHubLike(hub).end().Art(ilk) - exited_);
```

For the denominator to reach zero requires `end.Art(ilk) == exited_` (all claims processed) or `end.Art(ilk) == 0` (D3M fully unwound before shutdown).

### The vat.slip Protection

`D3MHub.exit()` calls:
```solidity
vat.slip(ilk, msg.sender, -int256(wad));
ilks[ilk].pool.exit(usr, wad);
```

The `vat.slip` reduces the caller's gem balance. Gems for this ilk are only distributed to DAI holders via `End.skim(ilk, pool)` which sets the gem balance proportionally to their DAI debt share. If `end.Art(ilk) == 0`, then `End.skim()` distributed zero gems (no debt = no share). So nobody holds gems for this ilk, meaning nobody can call `D3MHub.exit()` with `wad > 0` — vat.slip would revert before reaching the division.

### Conclusion

The division-by-zero is unreachable: the only callers with non-zero wad must hold vat gems for this ilk, which are only distributed proportionally to the outstanding debt. If Art == 0, nobody has gems, so exit() can't be called. FALSE POSITIVE.
