# Immunefi Bug Report: Clearinghouse `claimDefaulted` Keeper Reward Accounting Discrepancy

## Bug Description

In the `Clearinghouse.claimDefaulted()` function, the keeper reward is calculated as a percentage of the defaulted collateral (gOHM), and this reward is transferred to the keeper BEFORE the remaining collateral is burned. The issue is that the reward is paid from the same pool of gOHM that `burn()` attempts to burn. Meanwhile, `principalReceivables` and treasury debt are reduced by the FULL defaulted amounts, not accounting for the value diverted to keeper rewards.

### Vulnerable Code

**File:** `src/policies/Clearinghouse.sol`

**Lines 268-290:**
```solidity
    // Decrement loan receivables.
    interestReceivables = (interestReceivables > totalInterest)
        ? interestReceivables - totalInterest
        : 0;
    principalReceivables = (principalReceivables > totalPrincipal)
        ? principalReceivables - totalPrincipal
        : 0;

    // Update outstanding debt owed to the Treasury upon default.
    uint256 outstandingDebt = TRSRY.reserveDebt(reserve, address(this));

    // debt owed to TRSRY = user debt - user interest
    TRSRY.setDebt({
        debtor_: address(this),
        token_: reserve,
        amount_: (outstandingDebt > totalPrincipal) ? outstandingDebt - totalPrincipal : 0
    });

    // Reward keeper.
    gohm.transfer(msg.sender, keeperRewards);
    // Burn the outstanding collateral of defaulted loans.
    burn();
```

### Accounting Analysis

When a loan defaults with 1 gOHM collateral:
1. The clearinghouse receives 1 gOHM from the Cooler
2. `principalReceivables -= ~2892.92 DAI` (full principal)
3. Treasury debt is reduced by `~2892.92 DAI`
4. Keeper gets up to 0.1 gOHM (~$290 in reserve value)
5. `burn()` burns remaining ~0.9 gOHM

Net result: Treasury debt was reduced by the full principal amount, but only 90% of collateral value was recovered (burned). The 10% keeper reward value is unaccounted for in the debt adjustment.

## Impact

**Severity: Low**

- The keeper reward is capped at 0.1 gOHM per loan (MAX_REWARD) and 5% of collateral
- The accounting discrepancy is small per default but accumulates
- Affects `principalReceivables` accuracy used by EmissionManager and YieldRepurchaseFacility

## Risk Breakdown

- **Difficulty to exploit:** Low (happens automatically)
- **Weakness type:** CWE-682 (Incorrect Calculation)
- **CVSS:** 3.7 (Low)

## Recommendation

Account for keeper rewards when adjusting treasury debt. Reduce the debt adjustment by the reserve-equivalent value of keeper rewards.

## Proof of Concept

See `scripts/verify/PoC_006_KeeperRewardAccounting.sol`

## References

- [Clearinghouse.sol - claimDefaulted](https://github.com/OlympusDAO/bophades/blob/main/src/policies/Clearinghouse.sol#L229-L290)
- [Clearinghouse.sol - burn](https://github.com/OlympusDAO/bophades/blob/main/src/policies/Clearinghouse.sol#L395-L400)
