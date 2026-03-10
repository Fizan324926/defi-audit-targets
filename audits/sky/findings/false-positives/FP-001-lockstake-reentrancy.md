# False Positive: LockstakeEngine Reentrancy in lock() via VoteDelegate

**Claimed:** CRITICAL reentrancy — malicious VoteDelegate steals SKY during lock() callback
**Verdict:** FALSE POSITIVE

## Why This Is Not Exploitable

Agent 2 identified that `LockstakeEngine.lock()` calls `sky.approve(voteDelegate, wad)` followed by `VoteDelegateLike(voteDelegate).lock(wad)` BEFORE updating vat state. The claim was that a malicious VoteDelegate could call `sky.transferFrom(engine, attacker, wad)` using the approval.

### The Protection: VoteDelegateFactory.created()

`selectVoteDelegate()` validates:
```solidity
require(
    voteDelegate == address(0) || voteDelegateFactory.created(voteDelegate) == 1,
    "LockstakeEngine/not-valid-vote-delegate"
);
```

`VoteDelegateFactory.create()` deploys **standard VoteDelegate.sol code** using `new VoteDelegate(...)`:
```solidity
function create() external returns (address voteDelegate) {
    require(!isDelegate(msg.sender), "VoteDelegateFactory/sender-is-already-delegate");
    voteDelegate = address(new VoteDelegate(chief, polling, msg.sender));  // standard code only
    delegates[msg.sender] = voteDelegate;
    created[voteDelegate] = 1;
    ...
}
```

The factory ONLY deploys the canonical `VoteDelegate.sol`. No arbitrary code can be registered.

### Standard VoteDelegate.lock() Has No Malicious Callback

The standard VoteDelegate.lock() simply:
```solidity
function lock(uint256 wad) external {
    gov.transferFrom(msg.sender, address(this), wad);  // msg.sender = LockstakeEngine
    chief.lock(wad);
    stake[msg.sender] += wad;
    emit Lock(msg.sender, wad);
}
```

It calls `gov.transferFrom(engine, voteDelegate, wad)` — using the engine's approval to move SKY from engine to voteDelegate, then stakes it in Chief. This is the CORRECT, intended behavior. No theft occurs.

### Conclusion

The reentrancy attack requires a non-standard VoteDelegate with malicious code. Since only factory-deployed standard contracts are accepted, this attack vector is blocked. The approve-before-state-update pattern is a legitimate CEI-order concern but NOT exploitable in the deployed system.
