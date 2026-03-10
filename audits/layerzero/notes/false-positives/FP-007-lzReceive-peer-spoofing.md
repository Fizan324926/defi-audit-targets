# FP-007: lzReceive() Peer Address Spoofing

## Classification: FALSE POSITIVE

## Location
- `/root/defi-audit-targets/audits/layerzero/LayerZero-v2/packages/layerzero-v2/evm/oapp/contracts/oapp/OAppReceiver.sol` lines 95-110
- `/root/defi-audit-targets/audits/layerzero/LayerZero-v2/packages/layerzero-v2/evm/protocol/contracts/EndpointV2.sol` lines 172-183

## Hypothesis
An attacker could craft a call to `lzReceive()` with a spoofed `_origin.sender` to bypass peer checks and deliver malicious messages.

## Multi-Layer Defense Chain

### Layer 1: Endpoint-only access
```solidity
if (address(endpoint) != msg.sender) revert OnlyEndpoint(msg.sender);
```
Only the immutable endpoint contract can call lzReceive. Direct external calls are rejected.

### Layer 2: Peer verification
```solidity
if (_getPeerOrRevert(_origin.srcEid) != _origin.sender) revert OnlyPeer(...);
```
The origin.sender from the message must match the pre-configured peer for that source chain.

### Layer 3: Endpoint's payload verification
Before calling `lzReceive()`, the endpoint calls `_clearPayload()`:
```solidity
_clearPayload(_receiver, _origin.srcEid, _origin.sender, _origin.nonce,
              abi.encodePacked(_guid, _message));
```
This verifies:
- The payload hash matches what was stored during `verify()` by the DVN
- The nonce is valid and in order
- The payload hasn't been consumed already

### Layer 4: DVN verification
The `verify()` function that stores the payload hash requires:
```solidity
if (!isValidReceiveLibrary(_receiver, _origin.srcEid, msg.sender))
    revert Errors.LZ_InvalidReceiveLibrary();
```
Only registered receive libraries (configured by the OApp) can submit verified payloads. The receive library is backed by DVN(s) that cryptographically verify messages from the source chain.

### Layer 5: Path initialization
```solidity
if (!_initializable(_origin, _receiver, lazyNonce)) revert Errors.LZ_PathNotInitializable();
```
The OApp must have explicitly allowed the path via `allowInitializePath()`, which checks peers.

### Conclusion
Spoofing a peer would require compromising: the endpoint contract (immutable), the DVN verification system, AND the receive library -- all of which are independent security layers. This is the core security model of LayerZero V2 and is robust against single-point-of-failure attacks.
