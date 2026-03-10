// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/**
 * @dev Interface for GTokenOpenPnlFeed contract
 */
interface IGTokenOpenPnlFeed {
    struct Request {
        bool initiated;
        bool active;
        uint256 linkFeePerNode;
    }

    function nextEpochValuesRequestCount() external view returns (uint256);

    function newOpenPnlRequestOrEpoch() external;

    function fulfill(bytes32 requestId, int256 value) external;

    event NumberParamUpdated(string name, uint256 newValue);
    event OracleUpdated(uint256 index, address newValue);
    event OraclesUpdated(address[] newValues);
    event JobUpdated(bytes32 newValue);

    event NextEpochValuesReset(uint256 indexed currEpoch, uint256 requestsResetCount);

    event NewEpochForced(uint256 indexed newEpoch);

    event NextEpochValueRequested(
        uint256 indexed currEpoch,
        uint256 indexed requestId,
        bytes32 job,
        uint256 oraclesCount,
        uint256 linkFeePerNode
    );

    event NewEpoch(
        uint256 indexed newEpoch,
        uint256 indexed requestId,
        int256[] epochMedianValues,
        int256 epochAverageValue,
        uint256 newEpochPositiveOpenPnl
    );

    event RequestValueReceived(
        bool isLate,
        uint256 indexed currEpoch,
        uint256 indexed requestId,
        bytes32 oracleRequestId,
        address indexed oracle,
        int256 requestValue,
        uint256 linkFee
    );

    event RequestMedianValueSet(
        uint256 indexed currEpoch,
        uint256 indexed requestId,
        int256[] requestValues,
        int256 medianValue
    );
}
