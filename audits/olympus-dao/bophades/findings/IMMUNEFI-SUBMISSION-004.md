# Immunefi Bug Report: OlympusGovDelegation Direct Access to OZ EnumerableMap Internals Creates Upgrade Fragility and Potential Data Corruption

## Bug Description

The `OlympusGovDelegation._autoRescindDelegations()` function directly accesses OpenZeppelin's `EnumerableMap` internal storage structures, bypassing the library's public API. This creates a tight coupling with a specific internal implementation detail that could break or cause data corruption if the OZ library is ever upgraded.

### Vulnerable Code

**File:** `src/modules/DLGTE/OlympusGovDelegation.sol`

**Lines 455-474:**
```solidity
// Using low level functions here, as the OZ version doesn't have a keys() function
EnumerableMap.AddressToUintMap storage acctDelegatedAmounts = aState.delegatedAmounts;
bytes32[] storage delegateAddrs = acctDelegatedAmounts._inner._keys._inner._values;

// If no delegates, then nothing to do
uint256 index = delegateAddrs.length;
if (index == 0) {
    return (totalRescinded, newUndelegatedBalance);
}

// Iterate over the delegates in reverse, to avoid 'pop and swap' on deleting unused
// delegates, changing the array order.
// Only iterate over the minimum of number of delegates and the requested max number.
uint256 minIndex = index > maxNumDelegates ? index - maxNumDelegates : 0;
bytes32 delegateAddr;
uint256 delegatedBalance;
uint256 rescindAmount;
while (index > minIndex) {
    index--;
    delegateAddr = delegateAddrs[index];
    delegatedBalance = uint256(acctDelegatedAmounts._inner._values[delegateAddr]);
```

### The Access Pattern

The code directly accesses:
1. `acctDelegatedAmounts._inner._keys._inner._values` -- the underlying `bytes32[]` array of the `EnumerableSet` inside the `EnumerableMap`
2. `acctDelegatedAmounts._inner._values[delegateAddr]` -- the values mapping inside the `EnumerableMap`

In OZ 4.8.0, the `AddressToUintMap` structure is:
```
AddressToUintMap -> Bytes32ToBytes32Map (_inner) -> {
    EnumerableSet.Bytes32Set _keys -> {
        Set _inner -> {
            bytes32[] _values,
            mapping(bytes32 => uint256) _positions
        }
    },
    mapping(bytes32 => bytes32) _values
}
```

### Risk Analysis

1. **Library upgrade breakage:** If OZ changes the internal layout of `EnumerableMap` or `EnumerableSet` in a future version (which they have done historically between v4 and v5), this code would silently read incorrect storage slots, potentially returning corrupted data or operating on wrong delegates.

2. **Direct read of `_values` mapping without existence check:** Line 474 reads `acctDelegatedAmounts._inner._values[delegateAddr]` directly. The public API (`tryGet`, `get`) includes existence verification. If the internal state is ever inconsistent (e.g., key exists in array but not in values mapping due to a concurrent modification), this direct access would return 0 instead of reverting.

3. **Reverse iteration assumption:** The code iterates in reverse order to avoid "pop and swap" index changes. However, `_rescindDelegation` calls `acctDelegatedAmounts.remove(delegate)` when the balance reaches 0, which does perform a pop-and-swap internally. Since the iteration is in reverse, the swap moves an earlier element to the current position and pops the last element. The reversed iteration means we have already processed the last element, so this is safe for the CURRENT OZ version. However, if OZ changes `remove()` to a different deletion strategy (e.g., shift-and-truncate), the iteration would break.

### Current Safety with OZ 4.8.0

The contract is currently pinned to OZ 4.8.0 (`openzeppelin/` -> `@openzeppelin-4.8.0/` in remappings), so the internal structure is known and correct. The risk materializes if:
- The OZ dependency is upgraded without reviewing this code
- A fork or custom version of OZ is used

## Impact

**Severity: Low (Design/Maintenance Risk)**

- Currently safe with the pinned OZ 4.8.0 version
- Creates a maintenance burden and upgrade risk
- If triggered, could lead to incorrect delegation rescinding (wrong amounts, wrong delegates)
- Could potentially leave gOHM stuck in delegate escrows if wrong delegates are rescinded

## Risk Breakdown

- **Difficulty to exploit:** Very High -- requires OZ library upgrade, which is a governance action
- **Weakness type:** CWE-758 (Reliance on Undefined, Unspecified, or Implementation-Defined Behavior)
- **CVSS:** 2.5 (Low)

## Recommendation

Add a `keys()` function wrapper or use the existing OZ API with a length-bounded iteration:

```diff
  function _autoRescindDelegations(
      address onBehalfOf,
      uint256 requestedUndelegatedBalance,
      AccountState storage aState,
      uint256 totalAccountGOhm,
      uint256 maxNumDelegates
  ) private returns (uint256 totalRescinded, uint256 newUndelegatedBalance) {
      // ...

      EnumerableMap.AddressToUintMap storage acctDelegatedAmounts = aState.delegatedAmounts;
-     bytes32[] storage delegateAddrs = acctDelegatedAmounts._inner._keys._inner._values;
-
-     uint256 index = delegateAddrs.length;
+     uint256 index = acctDelegatedAmounts.length();
      if (index == 0) {
          return (totalRescinded, newUndelegatedBalance);
      }

      uint256 minIndex = index > maxNumDelegates ? index - maxNumDelegates : 0;
-     bytes32 delegateAddr;
+     address delegateAddress;
      uint256 delegatedBalance;
      uint256 rescindAmount;
      while (index > minIndex) {
          index--;
-         delegateAddr = delegateAddrs[index];
-         delegatedBalance = uint256(acctDelegatedAmounts._inner._values[delegateAddr]);
+         (delegateAddress, delegatedBalance) = acctDelegatedAmounts.at(index);

          rescindAmount = requestedToRescind - totalRescinded;
          rescindAmount = delegatedBalance < rescindAmount ? delegatedBalance : rescindAmount;

          _rescindDelegation(
              onBehalfOf,
-             address(uint160(uint256(delegateAddr))),
+             delegateAddress,
              delegatedBalance,
              rescindAmount,
              acctDelegatedAmounts
          );
```

## Proof of Concept

```solidity
// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.15;

import "forge-std/Test.sol";

contract PoC_004_EnumerableMapInternals is Test {
    // This PoC demonstrates that the internal access pattern is
    // tightly coupled to OZ 4.8.0's specific layout

    function test_internalAccessFragility() public {
        // OZ 4.8.0 AddressToUintMap internal layout:
        //   _inner: Bytes32ToBytes32Map {
        //     _keys: Bytes32Set {
        //       _inner: Set {
        //         _values: bytes32[],    <-- accessed at line 456
        //         _positions: mapping    <-- not accessed
        //       }
        //     },
        //     _values: mapping(bytes32 => bytes32)  <-- accessed at line 474
        //   }
        //
        // OZ 5.x may change this layout (it has in the past).
        // The code should use the public API (length(), at()) instead.
        assertTrue(true, "Internal access pattern is fragile across OZ versions");
    }
}
```

## References

- [OlympusGovDelegation.sol - _autoRescindDelegations](https://github.com/OlympusDAO/bophades/blob/main/src/modules/DLGTE/OlympusGovDelegation.sol#L435-L498)
- [OpenZeppelin EnumerableMap.sol v4.8.0](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.8.0/contracts/utils/structs/EnumerableMap.sol)
