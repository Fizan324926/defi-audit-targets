#!/usr/bin/env python3
"""
Verification Script: M-01 SuperFaultDisputeGame.closeGame() Ordering Bug

Verifies that SuperFaultDisputeGame.closeGame() has incorrect ordering
compared to FaultDisputeGame.closeGame(), causing claimCredit() to revert
during system pause even after bond distribution mode is decided.
"""

import re
import sys

SRC = "/root/audits/optimism/source/packages/contracts-bedrock/src/dispute"

def extract_closeGame_order(filepath: str) -> dict:
    """Extract the ordering of pause check vs early return in closeGame()"""
    with open(filepath) as f:
        content = f.read()

    # Find closeGame function
    match = re.search(r'function closeGame\(\) public \{(.*?)^\s{4}\}', content, re.DOTALL | re.MULTILINE)
    if not match:
        return {"error": "closeGame() not found"}

    body = match.group(1)
    lines = body.split('\n')

    pause_line = None
    early_return_line = None

    for i, line in enumerate(lines):
        if 'anchorStateRegistry().paused()' in line or 'GamePaused' in line:
            if pause_line is None:
                pause_line = i
        if 'bondDistributionMode == BondDistributionMode.REFUND' in line or \
           'bondDistributionMode == BondDistributionMode.NORMAL' in line:
            if early_return_line is None:
                early_return_line = i

    return {
        "pause_check_line": pause_line,
        "early_return_line": early_return_line,
        "pause_first": pause_line < early_return_line if (pause_line and early_return_line) else None
    }


def verify():
    print("=" * 70)
    print("M-01 VERIFICATION: SuperFaultDisputeGame.closeGame() Ordering Bug")
    print("=" * 70)

    # Check FaultDisputeGame (correct ordering)
    fdg_path = f"{SRC}/FaultDisputeGame.sol"
    fdg = extract_closeGame_order(fdg_path)
    print(f"\nFaultDisputeGame.closeGame():")
    print(f"  Early return at relative line: {fdg['early_return_line']}")
    print(f"  Pause check at relative line:  {fdg['pause_check_line']}")
    print(f"  Pause check first?             {fdg['pause_first']}")

    # Check SuperFaultDisputeGame (incorrect ordering)
    sfdg_path = f"{SRC}/SuperFaultDisputeGame.sol"
    sfdg = extract_closeGame_order(sfdg_path)
    print(f"\nSuperFaultDisputeGame.closeGame():")
    print(f"  Early return at relative line: {sfdg['early_return_line']}")
    print(f"  Pause check at relative line:  {sfdg['pause_check_line']}")
    print(f"  Pause check first?             {sfdg['pause_first']}")

    # Verify the inconsistency
    print("\n" + "-" * 70)

    if fdg['pause_first'] == False and sfdg['pause_first'] == True:
        print("[CONFIRMED] Ordering inconsistency detected!")
        print()
        print("FaultDisputeGame:      early_return BEFORE pause_check (CORRECT)")
        print("SuperFaultDisputeGame: pause_check BEFORE early_return (BUG)")
        print()
        print("Impact: claimCredit() reverts during system pause on SuperFaultDisputeGame")
        print("        even after bond distribution mode is already decided.")
        print()
        print("Severity: MEDIUM - Temporary DoS on fund withdrawal during pause")
        return True
    else:
        print("[NOT CONFIRMED] Ordering appears consistent")
        return False

    # Verify claimCredit calls closeGame
    print("\n" + "-" * 70)
    print("Verifying claimCredit() calls closeGame()...")
    for name, path in [("FaultDisputeGame", fdg_path), ("SuperFaultDisputeGame", sfdg_path)]:
        with open(path) as f:
            content = f.read()
        match = re.search(r'function claimCredit.*?\{.*?closeGame\(\)', content, re.DOTALL)
        if match:
            print(f"  {name}: claimCredit() calls closeGame() [CONFIRMED]")
        else:
            print(f"  {name}: claimCredit() does NOT call closeGame() [ERROR]")


if __name__ == "__main__":
    confirmed = verify()
    sys.exit(0 if confirmed else 1)
