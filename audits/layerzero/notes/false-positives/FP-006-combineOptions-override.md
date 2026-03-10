# FP-006: combineOptions() Enforced Option Override

## Classification: FALSE POSITIVE

## Location
- `/root/defi-audit-targets/audits/layerzero/LayerZero-v2/packages/layerzero-v2/evm/oapp/contracts/oapp/libs/OAppOptionsType3.sol` lines 63-85

## Hypothesis
A user could craft _extraOptions that override/nullify the enforced options, bypassing minimum gas limits or other security-critical settings set by the OApp owner.

## Why Not Exploitable

### Concatenation, Not Override
```solidity
function combineOptions(...) public view virtual returns (bytes memory) {
    bytes memory enforced = enforcedOptions[_eid][_msgType];
    if (enforced.length == 0) return _extraOptions;
    if (_extraOptions.length == 0) return enforced;
    if (_extraOptions.length >= 2) {
        _assertOptionsType3(_extraOptions);
        return bytes.concat(enforced, _extraOptions[2:]);
    }
    revert InvalidOptions(_extraOptions);
}
```

The combined result is: `[enforced_options][user_extra_options]`

### Executor Behavior
The LayerZero executor processes options sequentially and SUMS duplicate option types:
- If enforced = `{gas: 200k, value: 1 ether}` and user adds `{gas: 100k, value: 0.5 ether}`
- Result = `{gas: 300k, value: 1.5 ether}`

The user CANNOT reduce gas below 200k or value below 1 ether. They can only add more.

### Type Enforcement
Both enforced options and user options must be Type 3 (checked via `_assertOptionsType3`). Legacy types 1 and 2 cannot be combined.

### Conclusion
The concatenation + summation model ensures enforced options provide a minimum floor that users can only exceed, never reduce. This is secure by design.
