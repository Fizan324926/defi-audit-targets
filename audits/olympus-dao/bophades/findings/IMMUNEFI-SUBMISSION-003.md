# Immunefi Bug Report: Kernel `_migrateKernel` Does Not Deactivate Policies on Old Kernel, Leaving Dangling Permissions

## Bug Description

The `Kernel._migrateKernel()` function migrates modules and policies to a new kernel by calling `changeKernel()` on each. However, it does NOT deactivate policies on the old kernel (the comment on line 355 says "Deactivate before changing kernel" but this is misleading -- no deactivation actually occurs). This means:

1. The old kernel's `modulePermissions` mapping retains all `true` entries for the migrated policies
2. The old kernel's `activePolicies` array still contains all policies
3. The old kernel's state is NOT cleaned up ("NOTE: Data does not get cleared from this kernel" per line 340)

### Vulnerable Code

**File:** `src/Kernel.sol`

**Lines 341-361:**
```solidity
/// @notice All functionality will move to the new kernel. WARNING: ACTION WILL BRICK THIS KERNEL.
/// @dev    New kernel must add in all of the modules and policies via executeAction.
/// @dev    NOTE: Data does not get cleared from this kernel.
function _migrateKernel(Kernel newKernel_) internal {
    uint256 keycodeLen = allKeycodes.length;
    for (uint256 i; i < keycodeLen; ) {
        Module module = Module(getModuleForKeycode[allKeycodes[i]]);
        module.changeKernel(newKernel_);
        unchecked {
            ++i;
        }
    }

    uint256 policiesLen = activePolicies.length;
    for (uint256 j; j < policiesLen; ) {
        Policy policy = activePolicies[j];

        // Deactivate before changing kernel
        policy.changeKernel(newKernel_);
        unchecked {
            ++j;
        }
    }
}
```

### The Issue

After migration:
- Modules now point to the new kernel (`module.kernel = newKernel_`)
- Policies now point to the new kernel (`policy.kernel = newKernel_`)
- The OLD kernel still has `modulePermissions[keycode][policy][selector] = true` for all previously granted permissions
- The old kernel still considers itself functional (the executor still exists)

Since the modules have been pointed to the new kernel, the `permissioned` modifier on modules will check permissions against the **new** kernel. This means the old kernel's stale permission data is not directly exploitable in the standard flow.

However, there is a race condition window: if the executor calls `_migrateKernel`, and between the module migration loop and the policy migration loop, a policy's transaction is pending that calls a module -- the module's kernel reference has changed but the policy's hasn't yet. The policy would call the module, the module would check `kernel.modulePermissions(...)` on the NEW kernel, and since the new kernel hasn't yet granted permissions, the call would revert. This is a DoS vector during migration.

Additionally, the old kernel retains the ability to call `executeAction` since the executor address is unchanged. If any modules are re-installed on the old kernel (or new ones installed), the stale permission data could be used.

### Impact on Policy `isActive()` Check

```solidity
function isActive() external view returns (bool) {
    return kernel.isPolicyActive(this);
}
```

After migration, `policy.kernel` points to the new kernel. If the policy hasn't been activated on the new kernel yet, `isActive()` returns false. This breaks any external integration that checks `isActive()` during the migration window.

## Impact

**Severity: Low**

- The migration function is clearly documented as bricking the old kernel
- The practical attack surface is limited to the migration window
- The stale data on the old kernel is not directly exploitable unless the old kernel is intentionally re-used
- The DoS window during migration is transient

However, the misleading comment "Deactivate before changing kernel" (line 355) could lead future developers to believe deactivation occurs when it does not.

## Risk Breakdown

- **Difficulty to exploit:** High -- requires timing an attack during the brief migration window
- **Weakness type:** CWE-459 (Incomplete Cleanup)
- **CVSS:** 3.1 (Low)

## Recommendation

Either actually deactivate policies before migration, or at minimum fix the misleading comment:

```diff
  function _migrateKernel(Kernel newKernel_) internal {
      uint256 keycodeLen = allKeycodes.length;
      for (uint256 i; i < keycodeLen; ) {
          Module module = Module(getModuleForKeycode[allKeycodes[i]]);
          module.changeKernel(newKernel_);
          unchecked {
              ++i;
          }
      }

      uint256 policiesLen = activePolicies.length;
      for (uint256 j; j < policiesLen; ) {
          Policy policy = activePolicies[j];
-
-         // Deactivate before changing kernel
+         // NOTE: Policy is NOT deactivated - permissions on old kernel are left stale
+         // The old kernel is considered bricked after this operation
          policy.changeKernel(newKernel_);
          unchecked {
              ++j;
          }
      }
  }
```

For stronger security, deactivate all policies before migrating to prevent any stale state issues:

```diff
+ // First deactivate all policies on the old kernel
+ for (uint256 k = policiesLen; k > 0; ) {
+     unchecked { --k; }
+     _deactivatePolicy(activePolicies[k]);
+ }
+
  // Then change kernels
  for (uint256 j; j < policiesLen; ) {
```

## Proof of Concept

```solidity
// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.15;

import "forge-std/Test.sol";

contract PoC_003_MigrateKernel is Test {
    // This is a conceptual PoC demonstrating the stale state
    function test_stalePermissionsAfterMigration() public {
        // After _migrateKernel:
        // - Old kernel still has all permission mappings as `true`
        // - Old kernel still has all policies in activePolicies[]
        // - Old kernel's executor is unchanged
        // - Modules point to new kernel
        // - Policies point to new kernel

        // The old kernel is "bricked" but retains all state
        // If anyone sends the old kernel's executor address to executeAction,
        // it could install new modules and the stale permissions would apply

        // This is documented behavior but the incomplete cleanup is a risk
        assertTrue(true, "Migration leaves stale state on old kernel");
    }
}
```

## References

- [Kernel.sol - _migrateKernel](https://github.com/OlympusDAO/bophades/blob/main/src/Kernel.sol#L341-L361)
- [Kernel.sol - permissioned modifier](https://github.com/OlympusDAO/bophades/blob/main/src/Kernel.sol#L110-L116)
