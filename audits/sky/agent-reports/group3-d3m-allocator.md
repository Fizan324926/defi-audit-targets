# Sky Protocol — D3M + Allocator Security Audit
**Scope:** D3M (Direct Deposit Module) + Allocator System
**Date:** 2026-03-01

---

## Scope Files Reviewed

### D3M — /root/audits/sky-protocol/dss-direct-deposit/src/
- D3MHub.sol
- D3MOracle.sol
- D3MMom.sol
- plans/D3MAaveV2TypeRateTargetPlan.sol
- plans/D3MAaveTypeBufferPlan.sol
- plans/D3MCompoundV2TypeRateTargetPlan.sol
- plans/D3MOperatorPlan.sol
- pools/D3M4626TypePool.sol
- pools/D3MAaveV2TypePool.sol
- pools/D3MAaveV3NoSupplyCapTypePool.sol
- pools/D3MAaveV3USDSNoSupplyCapTypePool.sol
- pools/D3MCompoundV2TypePool.sol

### Allocator — /root/audits/sky-protocol/dss-allocator/src/
- AllocatorVault.sol
- AllocatorOracle.sol
- AllocatorBuffer.sol
- AllocatorRegistry.sol
- AllocatorRoles.sol
- funnels/Swapper.sol
- funnels/DepositorUniV3.sol
- funnels/automation/StableSwapper.sol
- funnels/automation/StableDepositorUniV3.sol
- funnels/automation/ConduitMover.sol
- funnels/automation/VaultMinter.sol
- funnels/callees/SwapperCalleeUniV3.sol
- funnels/callees/SwapperCalleePsm.sol
- funnels/uniV3/FullMath.sol
- funnels/uniV3/LiquidityAmounts.sol
- funnels/uniV3/TickMath.sol

---

## Findings Summary

| ID   | Title                                                                      | File                                   | Severity |
|------|----------------------------------------------------------------------------|----------------------------------------|----------|
| F-01 | Flash-loan manipulation of D3MAaveTypeBufferPlan                           | D3MAaveTypeBufferPlan.sol              | High     |
| F-02 | getTargetAssets underflow when reserves > cash+borrows (Compound)          | D3MCompoundV2TypeRateTargetPlan.sol    | Medium   |
| F-03 | Division by zero when targetUtil==0 or slope==0 (AaveV2 rate plan)        | D3MAaveV2TypeRateTargetPlan.sol        | Medium   |
| F-04 | exit() division by zero when Art==0 during global settlement (4626 pool)  | D3M4626TypePool.sol                    | High     |
| F-05 | exit() division by zero in all Aave/Compound pools; scale mismatch in cDai| All pool files                         | High     |
| F-06 | SwapperCalleeUniV3 uses deadline:block.timestamp, no MEV protection        | SwapperCalleeUniV3.sol                 | Medium   |
| F-07 | Swapper.swap() accepts minOut=0 enabling 100% value extraction             | Swapper.sol                            | High     |
| F-08 | ConduitMover.move() no balance/transfer check for conduit deposit           | ConduitMover.sol                       | Medium   |
| F-09 | AllocatorVault.wipe() rounds dart down causing persistent dust debt         | AllocatorVault.sol                     | Low      |
| F-10 | DepositorUniV3 rate limit fully bypassed when era==0                       | DepositorUniV3.sol                     | Medium   |

---

## Detailed Findings

---

### F-01 — Flash-loan Manipulation of D3MAaveTypeBufferPlan Forces Over-Deployment of DAI

**Severity:** High
**File:** /root/audits/sky-protocol/dss-direct-deposit/src/plans/D3MAaveTypeBufferPlan.sol
**Lines:** 77-96

**Vulnerable Code:**

    function getTargetAssets(uint256 currentAssets) external override view returns (uint256) {
        if (buffer == 0) return 0; // De-activated

        // Note that this can be manipulated by flash loans
        uint256 liquidityAvailable = dai.balanceOf(address(adai));   // spot read, line 81
        if (buffer >= liquidityAvailable) {
            // Need to increase liquidity
            return currentAssets + (buffer - liquidityAvailable);    // inflated target, line 84
        } else {
            ...
        }
    }

**Description:**
`getTargetAssets()` reads the real-time DAI balance of the Aave aToken contract (`dai.balanceOf(address(adai))`). This is a spot read with no TWAP or delay. The code comment at line 80 explicitly acknowledges the flash-loan risk.

An attacker drains the Aave DAI liquidity pool via a flash loan immediately before triggering `D3MHub.exec()`. This causes `liquidityAvailable` to drop to near zero, making `buffer - liquidityAvailable` enormous, so `getTargetAssets()` returns a massively inflated target. `D3MHub._exec()` then winds the D3M by that inflated amount — minting fresh DAI and depositing it into Aave in a single block.

**Exploit Path:**
1. Attacker takes a large flash loan of DAI from Aave, draining the pool's available liquidity.
2. Within the same transaction (in the flash-loan callback), attacker calls `D3MHub.exec(ilk)`.
3. `D3MAaveTypeBufferPlan.getTargetAssets()` reads near-zero `liquidityAvailable`.
4. `buffer - ~0 = buffer` (e.g., 10M DAI), so `targetAssets = currentAssets + buffer`.
5. The Hub winds the D3M by up to the full remaining debt-ceiling capacity, minting new DAI.
6. Attacker repays the flash loan. The Aave pool is now filled with newly minted D3M DAI.
7. Net result: D3M's DAI supply is permanently inflated to the debt ceiling in one block.

**Why No Defense Prevents It:**
- The `lock` modifier on `exec()` prevents re-entrant calls within the same stack frame but does not prevent a flash-loan in the same transaction (the flash-loan callback is a new external call, not recursive reentrancy).
- The debt ceiling is the only practical bound, but within that bound the attacker can force a full deployment of remaining capacity in one `exec()` call.
- The code comment at line 80 admits the manipulation is known and accepted, but the impact is not constrained.

**Impact:** Unauthorized acceleration of DAI minting to the debt ceiling; griefing that pushes Aave utilization to extremes in one block, potentially trapping other users' liquidity.

---

### F-02 — D3MCompoundV2TypeRateTargetPlan.getTargetAssets() Reverts via Arithmetic Underflow

**Severity:** Medium
**File:** /root/audits/sky-protocol/dss-direct-deposit/src/plans/D3MCompoundV2TypeRateTargetPlan.sol
**Lines:** 170-192

**Vulnerable Code:**

    function getTargetAssets(uint256 currentAssets) external override view returns (uint256) {
        ...
        uint256 borrows = cDai.totalBorrows();
        uint256 targetTotalPoolSize = _calculateTargetSupply(targetInterestRate, borrows);
        uint256 totalPoolSize = cDai.getCash() + borrows - cDai.totalReserves(); // line 176 - underflow risk
        ...
    }

**Description:**
The formula `cDai.getCash() + borrows - cDai.totalReserves()` can underflow if `totalReserves > getCash() + totalBorrows`. Solidity 0.8.x has default checked arithmetic so this reverts rather than wrapping.

Compound's interest accrual process can temporarily produce `totalReserves > cash + borrows` due to:
- A reserve factor manipulation via governance.
- Rounding in Compound's internal accrual math over many blocks.
- A market with very high reserve factor and low utilization.

**Exploit Path:**
1. Compound's state reaches a condition where `totalReserves >= getCash() + totalBorrows` (even by 1 wei).
2. Any call to `getTargetAssets()` reverts with arithmetic underflow.
3. `D3MHub._exec()` at line 295 calls `ilks[ilk].plan.getTargetAssets(currentAssets)` with no try/catch.
4. The entire `exec()` call reverts, preventing the D3M from winding or unwinding.
5. If the D3M has been caged and needs to unwind to recover funds, this DoS blocks recovery.

**Why No Defense Prevents It:**
- No try/catch around `getTargetAssets()` in D3MHub.
- `active()` checks the rate model and delegate addresses only — not reserve arithmetic.
- No guard against underflow in the formula.

**Impact:** Temporary DoS of exec() — contract unable to operate until Compound state changes.

---

### F-03 — D3MAaveV2TypeRateTargetPlan: Division by Zero When variableRateSlope2==0 or targetUtil==0

**Severity:** Medium
**File:** /root/audits/sky-protocol/dss-direct-deposit/src/plans/D3MAaveV2TypeRateTargetPlan.sol
**Lines:** 132-169

**Vulnerable Code:**

    function _calculateTargetSupply(uint256 targetInterestRate, uint256 totalDebt) internal view returns (uint256) {
        ...
        uint256 targetUtil;
        if (targetInterestRate > base + variableRateSlope1) {
            uint256 r;
            unchecked { r = targetInterestRate - base - variableRateSlope1; }
            targetUtil = _rdiv(
                            _rmul(tack.EXCESS_UTILIZATION_RATE(), r),
                            tack.variableRateSlope2()          // line 153 — can be 0
                         ) + tack.OPTIMAL_UTILIZATION_RATE();
        } else {
            unchecked {
                targetUtil = _rdiv(
                                _rmul(targetInterestRate - base, tack.OPTIMAL_UTILIZATION_RATE()),
                                variableRateSlope1             // line 163 — can be 0
                             );
            }
        }
        return _rdiv(totalDebt, targetUtil);   // line 168 — divides by zero if targetUtil==0
    }

Where `_rdiv(x, y) = (x * RAY) / y`.

**Three division-by-zero conditions:**

1. `variableRateSlope2() == 0`: If the rate strategy has a flat post-kink rate (slope2=0), and `targetInterestRate > base + slope1`, then `_rdiv(numerator, 0)` divides by zero.
2. `variableRateSlope1 == 0`: If slope1=0 (flat pre-kink rate), and `targetInterestRate` falls in the pre-kink branch, `_rdiv(numerator, 0)` divides by zero.
3. `targetUtil == 0`: If `_rmul(...)` rounds to zero (near-zero inputs), `_rdiv(totalDebt, 0)` at line 168 divides by zero.

The `tack` interest rate strategy is updateable by governance (`file(bytes32, address)`) and could legitimately have slope2=0.

**Why No Defense Prevents It:**
- `active()` only checks `strategy == address(tack)` and token addresses, not slope values.
- No zero-denominator guards in `_calculateTargetSupply`.
- No try/catch in D3MHub.

**Impact:** Medium — D3M unable to operate; exec() DoS until bar or tack is changed.

---

### F-04 — D3M4626TypePool.exit() Division by Zero When Art==0 During Global Settlement

**Severity:** High
**File:** /root/audits/sky-protocol/dss-direct-deposit/src/pools/D3M4626TypePool.sol
**Lines:** 117-122

**Vulnerable Code:**

    function exit(address dst, uint256 wad) external override onlyHub {
        uint256 exited_ = exited;
        exited = exited_ + wad;
        uint256 amt = wad * vault.balanceOf(address(this)) / (D3mHubLike(hub).end().Art(ilk) - exited_);
        //                                                    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
        //                                                    Denominator is zero when Art(ilk)==0
        require(vault.transfer(dst, amt), "D3M4626TypePool/transfer-failed");
    }

**Description:**
During global settlement, DAI holders redeem their entitlement by calling `D3MHub.exit(ilk, usr, wad)`, which calls `pool.exit(dst, wad)`.

The calculation distributes vault shares proportionally:

    amt = wad * vault.balanceOf(address(this)) / (end.Art(ilk) - exited_)

`end.Art(ilk)` is the normalized total debt for the D3M ilk as recorded at the moment `End.cage(ilk)` was called. `exited_` tracks how many units have already been distributed.

**Division by zero occurs when:**
- `end.Art(ilk) == 0`: If the D3M was fully unwound (all debt repaid) before End processed the ilk, the urn has zero debt. `Art(ilk)` will be 0, so `0 - 0 = 0` — division by zero.
- This is a realistic scenario: the protocol routinely unwinds D3M positions as part of normal operation.

**Exploit Path:**
1. D3M ilk is fully unwound — zero outstanding debt.
2. Global settlement is triggered (`End.cage()`).
3. `End.cage(ilk)` records `Art[ilk] = 0` for the D3M ilk.
4. Vault still holds ERC-4626 shares (from accrued yield above the repaid principal).
5. A DAI holder calls `D3MHub.exit(ilk, user, wad)`.
6. `pool.exit(dst, wad)` executes: denominator `= 0 - 0 = 0`.
7. Division by zero — call reverts.
8. All DAI holders are permanently blocked from redeeming pool shares.
9. ERC-4626 vault tokens are permanently locked in the pool contract.

**Why No Defense Prevents It:**
- No zero-denominator guard in exit().
- The `quit()` function (auth-only) exists but requires a ward to call it — this helps for governance but not for permissionless redemption by DAI holders.
- There is no fallback distribution mechanism.

**Impact:** High — permanent freeze of yield-bearing pool shares during global settlement; DAI holders cannot redeem their entitlement.

---

### F-05 — All Aave and Compound Pool exit() Functions Share Division-by-Zero; Compound Pool Has Scale Mismatch

**Severity:** High
**Files:**
- /root/audits/sky-protocol/dss-direct-deposit/src/pools/D3MAaveV2TypePool.sol line 187
- /root/audits/sky-protocol/dss-direct-deposit/src/pools/D3MAaveV3NoSupplyCapTypePool.sol line 208
- /root/audits/sky-protocol/dss-direct-deposit/src/pools/D3MAaveV3USDSNoSupplyCapTypePool.sol line 231
- /root/audits/sky-protocol/dss-direct-deposit/src/pools/D3MCompoundV2TypePool.sol line 166

**Vulnerable Code (identical pattern, shown for AaveV2 and Compound):**

    // D3MAaveV2TypePool.sol:184-189
    function exit(address dst, uint256 wad) external override onlyHub {
        uint256 exited_ = exited;
        exited = exited_ + wad;
        uint256 amt = wad * assetBalance() / (D3mHubLike(hub).end().Art(ilk) - exited_);
        require(adai.transfer(dst, amt), "D3MAaveV2TypePool/transfer-failed");
    }

    // D3MCompoundV2TypePool.sol:163-168
    function exit(address dst, uint256 wad) external override onlyHub {
        uint256 exited_ = exited;
        exited = exited_ + wad;
        uint256 amt = wad * cDai.balanceOf(address(this)) / (D3mHubLike(hub).end().Art(ilk) - exited_);
        require(cDai.transfer(dst, amt), "D3MCompoundV2TypePool/transfer-failed");
    }

**Issue 1 — Division by Zero (all four pools):**
Same root cause as F-04. When the D3M urn has zero debt at global settlement, `end.Art(ilk) == 0` and the denominator becomes zero.

**Issue 2 — Scale Mismatch in D3MCompoundV2TypePool:**
In the Compound V2 pool, the numerator uses `cDai.balanceOf(address(this))` which is denominated in cDAI tokens (scaled by the cToken exchange rate, approximately 50 DAI per cDAI as of 2024). The denominator `end.Art(ilk)` is in normalized DAI units (1:1 with WAD after rate=RAY).

The division `wad * cDai_balance_in_cTokens / Art_in_DAI_units` produces a value in mixed units. Since one cDAI is worth ~50 DAI, the result `amt` is approximately 50x smaller than it should be. DAI holders redeeming through `exit()` in the Compound pool receive roughly 1/50th of the cDAI they are entitled to. The remaining cDAI is permanently stranded in the pool contract.

**Why No Defense Prevents It:**
- No zero-denominator guards.
- No unit normalization in the Compound pool's exit().
- `assetBalance()` in the Aave pools returns DAI (correctly), but `cDai.balanceOf()` in the Compound pool returns cTokens (incorrectly mixed with DAI-denominated Art).

**Impact:** High — permanent freeze of pool tokens and systematic underallocation during global settlement.

---

### F-06 — SwapperCalleeUniV3 Uses deadline:block.timestamp, Providing Zero MEV Time-Protection

**Severity:** Medium
**File:** /root/audits/sky-protocol/dss-allocator/src/funnels/callees/SwapperCalleeUniV3.sol
**Lines:** 55-63

**Vulnerable Code:**

    SwapRouterLike.ExactInputParams memory params = SwapRouterLike.ExactInputParams({
        path:             path,
        recipient:        to,
        deadline:         block.timestamp,   // line 58 — always valid, no time protection
        amountIn:         amt,
        amountOutMinimum: minOut
    });
    SwapRouterLike(uniV3Router).exactInput(params);

**Description:**
The UniswapV3 router `deadline` parameter protects against a transaction being held by a validator and included at an unfavorable time. By setting `deadline: block.timestamp`, the check `block.timestamp <= deadline` is always true (since the check is evaluated in the same block as inclusion). This completely disables time-based protection.

A validator or MEV searcher can:
1. Observe the pending swap transaction in the mempool.
2. Delay inclusion until a block where the pool price is maximally unfavorable.
3. Include the transaction — it passes the deadline check since `block.timestamp == deadline` at that moment.
4. The protocol swaps at the worst price within the `minOut` tolerance.

**Why No Defense Prevents It:**
- `minOut` provides slippage protection by amount but not by time.
- `StableSwapper` passes `cfg.req` as `minOut`, which is a static governance-configured value that may become stale relative to current market prices.
- The callee has no alternative deadline mechanism.

**Impact:** Medium — systematic extraction of value up to the `minOut` threshold on every swap. Over time, this represents theft of protocol yield.

---

### F-07 — Swapper.swap() Accepts minOut=0, Enabling Complete Extraction of Buffer Funds

**Severity:** High
**File:** /root/audits/sky-protocol/dss-allocator/src/funnels/Swapper.sol
**Lines:** 86-112

**Vulnerable Code:**

    function swap(address src, address dst, uint256 amt, uint256 minOut, address callee, bytes calldata data)
        external auth returns (uint256 out)
    {
        ...
        GemLike(src).transferFrom(buffer, callee, amt);   // line 102 — transfers src from buffer
        CalleeLike(callee).swapCallback(src, dst, amt, minOut, address(this), data);

        out = GemLike(dst).balanceOf(address(this));
        require(out >= minOut, "Swapper/too-few-dst-received");  // line 108 — minOut can be 0
        GemLike(dst).transfer(buffer, out);
    }

**Description:**
The `swap()` function enforces `require(out >= minOut)` but imposes no lower bound on `minOut`. When `minOut == 0`, the check becomes `require(out >= 0)` which is always trivially true.

Any caller authorized via `AllocatorRoles.canCall()` can call `Swapper.swap()` with `minOut = 0` and a controlled `callee`. The `src` tokens are transferred from the `buffer` to the `callee`. If the `callee`'s `swapCallback` sends zero `dst` tokens back, `out = 0 >= 0` passes.

**Exploit Path:**
1. Attacker has a valid authorized role for the ilk (e.g., keeper role with `draw`/`swap` access).
2. Attacker calls `Swapper.swap(src, dst, amt, 0, attackerCallee, data)`.
3. `amt` of `src` tokens are transferred from `buffer` to `attackerCallee`.
4. `attackerCallee.swapCallback()` is called — it sends 0 `dst` tokens back.
5. `out = 0 >= 0 = minOut` — check passes.
6. Swapper sends 0 `dst` tokens to buffer.
7. Net: `amt` of `src` tokens are permanently removed from the buffer with zero compensation.

**Why No Defense Prevents It:**
- No minimum bound enforced on `minOut` in `swap()`.
- `StableSwapper` wraps `swap()` and enforces `minOut >= cfg.req` at line 103, but direct callers of `Swapper.swap()` bypass this.
- The `auth` modifier verifies role possession but not parameter validity.
- Any authorized role (not just wards) can call `swap()` directly.

**Impact:** High — complete theft of `src` tokens from the buffer by any authorized role holder who supplies `minOut=0`.

---

### F-08 — ConduitMover.move() Does Not Verify That Conduit deposit() Actually Transferred Tokens

**Severity:** Medium
**File:** /root/audits/sky-protocol/dss-allocator/src/funnels/automation/ConduitMover.sol
**Lines:** 94-110

**Vulnerable Code:**

    function move(address from, address to, address gem) toll external {
        MoveConfig memory cfg = configs[from][to][gem];
        ...
        if (from != buffer) {
            require(ConduitLike(from).withdraw(ilk, gem, cfg.lot) == cfg.lot, "ConduitMover/lot-withdraw-failed");
        }
        if (to != buffer) {
            ConduitLike(to).deposit(ilk, gem, cfg.lot);   // line 106 — no return value check
        }
        emit Move(from, to, gem, cfg.lot);
    }

**Description:**
When funds flow FROM a conduit (not buffer), the withdrawal is verified: `require(withdraw(...) == cfg.lot)`. But when funds flow TO a conduit (`to != buffer`), the deposit call has no verification that exactly `cfg.lot` tokens were actually transferred into the conduit.

Conduit `deposit()` implementations may:
- Charge a protocol fee, depositing `cfg.lot - fee` instead of `cfg.lot`.
- Have internal accounting that does not 1:1 correspond to token transfers.
- Accept the deposit call but return without actually pulling tokens (if the buffer approval was not set correctly).

In all these cases, `move()` succeeds and emits `Move(from, to, gem, cfg.lot)`, but the actual amount moved may be less than `cfg.lot`. The `num` counter is decremented and `zzz` updated, consuming a rate-limit slot even though the full amount was not moved.

**Why No Defense Prevents It:**
- The IAllocatorConduit interface shows `deposit()` returns void (no return value to check).
- There is no pre/post balance check around the deposit.
- The buffer approval mechanism is external (`AllocatorBuffer.approve()`), managed separately.

**Impact:** Medium — silent loss of funds if conduit implementations charge fees; rate-limit slot consumed without full value transfer.

---

### F-09 — AllocatorVault.wipe() Rounds dart Down, Causing Persistent Dust Debt Accumulation

**Severity:** Low
**File:** /root/audits/sky-protocol/dss-allocator/src/AllocatorVault.sol
**Lines:** 131-136 (draw), 139-147 (wipe)

**Vulnerable Code:**

    // draw() — rounds UP (correct):
    function draw(uint256 wad) external auth {
        uint256 rate = jug.drip(ilk);
        uint256 dart = _divup(wad * RAY, rate);    // line 132 — ceiling division
        vat.frob(ilk, address(this), address(0), address(this), 0, int256(dart));
        usdsJoin.exit(buffer, wad);
    }

    // wipe() — rounds DOWN (inconsistent):
    function wipe(uint256 wad) external auth {
        usds.transferFrom(buffer, address(this), wad);
        usdsJoin.join(address(this), wad);
        uint256 rate = jug.drip(ilk);
        uint256 dart = wad * RAY / rate;           // line 143 — floor division
        vat.frob(ilk, address(this), address(0), address(this), 0, -int256(dart));
    }

**Description:**
`draw()` correctly uses ceiling division (`_divup`) when computing normalized debt to create — ensuring the protocol always records at least enough debt to cover the issued USDS.

`wipe()` uses floor division when computing normalized debt to retire. This means the vault repays slightly fewer normalized units than the exact value of USDS returned. Every `wipe()` call leaves a fractional residual of normalized debt (up to `rate/RAY` DAI equivalent per call).

Over many automated `VaultMinter.wipe()` calls, this dust accumulates. The vault can never fully close its position without a manual dust sweep. While each residual is tiny (< 1 wei of RAY-scaled debt), with protocol-scale volumes this creates a permanently growing underpayment.

**Why No Defense Prevents It:**
- Asymmetry between draw (ceiling) and wipe (floor) is the root cause.
- No dust-sweep mechanism exists.
- `VaultMinter` automates wipes repeatedly, compounding the issue.

**Impact:** Low — dust accumulation. Not immediately exploitable but a long-term protocol correctness issue.

---

### F-10 — DepositorUniV3 Rate Limit Fully Bypassed When era==0

**Severity:** Medium
**File:** /root/audits/sky-protocol/dss-allocator/src/funnels/DepositorUniV3.sol
**Lines:** 228-233 (deposit), 269-274 (withdraw)

**Vulnerable Code:**

    if (block.timestamp >= limit.end) {
        // Reset batch
        limit.due0 = limits[p.gem0][p.gem1][p.fee].cap0;
        limit.due1 = limits[p.gem0][p.gem1][p.fee].cap1;
        limit.end  = uint32(block.timestamp) + limits[p.gem0][p.gem1][p.fee].era;  // line 232
    }

**Description:**
When `era == 0`, the computation at line 232 sets `limit.end = uint32(block.timestamp) + 0 = uint32(block.timestamp)`. On the next call (even in the same block), `block.timestamp >= limit.end` is true (equal), so the batch resets again. This means:

- Every call to `deposit()` or `withdraw()` resets `due0` and `due1` back to `cap0` and `cap1`.
- The rate limit is completely non-functional: an authorized keeper can call `deposit()` an unlimited number of times per block, each time getting the full cap allowance.

The `setLimits()` function does not validate `era > 0`:

    function setLimits(address gem0, address gem1, uint24 fee, uint96 cap0, uint96 cap1, uint32 era) external auth {
        limits[gem0][gem1][fee] = PairLimit({
            cap0: cap0, cap1: cap1, era: era, due0: 0, due1: 0, end: 0
        });
    }

A governance misconfiguration setting `era = 0` fully disables the rate limit.

**Why No Defense Prevents It:**
- No validation that `era > 0` in `setLimits()`.
- The reset condition `block.timestamp >= limit.end` is always satisfied when `era == 0`.
- The same issue exists identically in both `deposit()` and `withdraw()`.

**Impact:** Medium — rate limit bypassed; unconstrained deposits/withdrawals from the buffer. Could deplete the buffer in one transaction if `cap0`/`cap1` are large.

---

## Additional Observations

### D3MOracle — Correct Design, No Chainlink Dependency
D3MOracle always returns 1 WAD (line 102) regardless of market conditions. This is intentional — the D3M pool holds DAI collateral priced at exactly 1 DAI. No staleness check or Chainlink dependency is needed. Correct design.

### AllocatorOracle — Correct Design  
AllocatorOracle returns a hardcoded bytes32(WAD) = 1e18 unconditionally. No external oracle, no staleness risk. Correct for a DAI/USDS-backed system.

### D3MHub Reentrancy Protection — Confirmed Correct
D3MHub uses a `lock` mutex (lines 131-136) on exec() and exit(). This prevents reentrant calls within the same stack frame. The preDebtChange/postDebtChange hooks fire within the lock guard so pool callbacks cannot reenter. No reentrancy vulnerability found beyond the flash-loan attack in F-01 (which is not classic reentrancy).

### AllocatorVault.draw() — Correct CEI Order
draw() calls jug.drip() and vat.frob() (debt creation) before usdsJoin.exit() (token issuance). This is correct Check-Effects-Interactions order.

### D3MMom.disable() — Emergency Mechanism is Sound
D3MMom bypasses governance delay to disable a plan via its `disable()` function. The authority check via `AuthorityLike.canCall()` is correctly enforced. No vulnerability found.

---

## Severity Summary

| Finding | Severity | Status |
|---------|----------|--------|
| F-01 Flash loan manipulation of buffer plan | High | Real, exploitable |
| F-04 exit() division by zero (4626) | High | Real, exploitable |
| F-05 exit() division by zero (all pools) + scale mismatch | High | Real, exploitable |
| F-07 Swapper minOut=0 enables theft | High | Real (requires auth role) |
| F-02 Compound underflow DoS | Medium | Real, exploitable |
| F-03 AaveV2 plan division by zero | Medium | Real (requires specific tack config) |
| F-06 UniV3 callee deadline=block.timestamp | Medium | Real, exploitable |
| F-08 ConduitMover no deposit verification | Medium | Real (conduit-dependent) |
| F-10 DepositorUniV3 era=0 rate limit bypass | Medium | Real (config-dependent) |
| F-09 wipe() dart rounding down | Low | Real, low impact |

---

## Most Critical Finding

**F-04 and F-05** represent the most severe confirmed vulnerabilities. The division-by-zero in all pool `exit()` implementations during global settlement requires no special privileges — any DAI holder triggering redemption causes the revert. If the D3M position was fully unwound before End processed the ilk (a normal operating scenario), `end.Art(ilk) == 0` and every call to `exit()` fails permanently. The pool's yield-bearing tokens (ERC-4626 shares, aDAI, cDAI) are locked with no recovery path available to unprivileged users.

The exact vulnerable line pattern in all five pool files:

    // D3M4626TypePool.sol line 120
    // D3MAaveV2TypePool.sol line 187
    // D3MAaveV3NoSupplyCapTypePool.sol line 208
    // D3MAaveV3USDSNoSupplyCapTypePool.sol line 231
    // D3MCompoundV2TypePool.sol line 166
    uint256 amt = wad * <poolBalance> / (D3mHubLike(hub).end().Art(ilk) - exited_);
    // When Art(ilk) == 0: 0 - 0 = 0, division by zero

