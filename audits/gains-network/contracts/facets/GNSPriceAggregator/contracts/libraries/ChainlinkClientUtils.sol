// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Chainlink} from "@chainlink/contracts/src/v0.8/Chainlink.sol";
import {LinkTokenInterface} from "@chainlink/contracts/src/v0.8/interfaces/LinkTokenInterface.sol";
import {ChainlinkRequestInterface} from "@chainlink/contracts/src/v0.8/interfaces/ChainlinkRequestInterface.sol";

import "../interfaces/libraries/IPriceAggregatorUtils.sol";
import "../interfaces/IGeneralErrors.sol";

import "./StorageUtils.sol";

/**
 *
 * @dev Chainlink client refactored into library and all unused functions removed
 * Uses price aggregator facet of multi collat diamond for storage.
 *
 * Copy of https://github.com/smartcontractkit/chainlink/blob/contracts-v0.5.1/contracts/src/v0.8/ChainlinkClient.sol
 * with only `requestCount` changed to unset so as to be inherited by a proxy implementation.
 */
library ChainlinkClientUtils {
    using Chainlink for Chainlink.Request;

    uint256 private constant AMOUNT_OVERRIDE = 0;
    address private constant SENDER_OVERRIDE = address(0);
    uint256 private constant ORACLE_ARGVERSION = 1;

    event ChainlinkRequested(bytes32 indexed id);
    event ChainlinkFulfilled(bytes32 indexed id);

    /**
     * @dev Returns storage slot to use when fetching storage relevant to library
     */
    function _getSlot() internal pure returns (uint256) {
        return StorageUtils.GLOBAL_PRICE_AGGREGATOR_SLOT;
    }

    /**
     * @dev Returns storage pointer for storage struct in diamond contract, at defined slot
     */
    function _getStorage() internal pure returns (IPriceAggregator.PriceAggregatorStorage storage s) {
        uint256 storageSlot = _getSlot();
        assembly {
            s.slot := storageSlot
        }
    }

    /**
     * @notice Creates a request that can hold additional parameters
     * @param specId The Job Specification ID that the request will be created for
     * @param callbackAddr address to operate the callback on
     * @param callbackFunctionSignature function signature to use for the callback
     * @return A Chainlink Request struct in memory
     */
    function buildChainlinkRequest(
        bytes32 specId,
        address callbackAddr,
        bytes4 callbackFunctionSignature
    ) internal pure returns (Chainlink.Request memory) {
        Chainlink.Request memory req;
        return req.initialize(specId, callbackAddr, callbackFunctionSignature);
    }

    /**
     * @notice Creates a Chainlink request to the specified oracle address
     * @dev Generates and stores a request ID, increments the local nonce, and uses `transferAndCall` to
     * send LINK which creates a request on the target oracle contract.
     * Emits ChainlinkRequested event.
     * @param oracleAddress The address of the oracle for the request
     * @param req The initialized Chainlink Request
     * @param payment The amount of LINK to send for the request
     * @return requestId The request ID
     */
    function sendChainlinkRequestTo(
        address oracleAddress,
        Chainlink.Request memory req,
        uint256 payment
    ) internal returns (bytes32 requestId) {
        IPriceAggregator.PriceAggregatorStorage storage s = _getStorage();
        uint256 nonce = s.requestCount;
        s.requestCount = nonce + 1;
        bytes memory encodedRequest = abi.encodeWithSelector(
            ChainlinkRequestInterface.oracleRequest.selector,
            SENDER_OVERRIDE, // Sender value - overridden by onTokenTransfer by the requesting contract's address
            AMOUNT_OVERRIDE, // Amount value - overridden by onTokenTransfer by the actual amount of LINK sent
            req.id,
            address(this),
            req.callbackFunctionId,
            nonce,
            ORACLE_ARGVERSION,
            req.buf.buf
        );
        return _rawRequest(oracleAddress, nonce, payment, encodedRequest);
    }

    /**
     * @notice Make a request to an oracle
     * @param oracleAddress The address of the oracle for the request
     * @param nonce used to generate the request ID
     * @param payment The amount of LINK to send for the request
     * @param encodedRequest data encoded for request type specific format
     * @return requestId The request ID
     */
    function _rawRequest(
        address oracleAddress,
        uint256 nonce,
        uint256 payment,
        bytes memory encodedRequest
    ) private returns (bytes32 requestId) {
        IPriceAggregator.PriceAggregatorStorage storage s = _getStorage();
        requestId = keccak256(abi.encodePacked(this, nonce));
        s.pendingRequests[requestId] = oracleAddress;
        emit ChainlinkRequested(requestId);
        if (!s.linkErc677.transferAndCall(oracleAddress, payment, encodedRequest))
            revert IPriceAggregatorUtils.TransferAndCallToOracleFailed();
    }

    /**
     * @notice Sets the LINK token address
     * @param _linkErc677 The address of the LINK token contract
     */
    function setChainlinkToken(address _linkErc677) internal {
        if (_linkErc677 == address(0)) revert IGeneralErrors.ZeroAddress();
        _getStorage().linkErc677 = LinkTokenInterface(_linkErc677);
    }

    /**
     * @notice Ensures that the fulfillment is valid for this contract
     * @dev Use if the contract developer prefers methods instead of modifiers for validation
     * @param requestId The request ID for fulfillment
     */
    function validateChainlinkCallback(
        bytes32 requestId
    )
        internal
        recordChainlinkFulfillment(requestId) // solhint-disable-next-line no-empty-blocks
    {}

    /**
     * @dev Reverts if the sender is not the oracle of the request.
     * Emits ChainlinkFulfilled event.
     * @param requestId The request ID for fulfillment
     */
    modifier recordChainlinkFulfillment(bytes32 requestId) {
        IPriceAggregator.PriceAggregatorStorage storage s = _getStorage();
        if (msg.sender != s.pendingRequests[requestId]) revert IPriceAggregatorUtils.SourceNotOracleOfRequest();
        delete s.pendingRequests[requestId];
        emit ChainlinkFulfilled(requestId);
        _;
    }
}
