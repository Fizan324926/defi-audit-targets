// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/**
 * @dev External library used to pack and unpack values
 */
library PackingUtils {
    /**
     * @dev Packs values array into a single uint256
     * @param _values values to pack
     * @param _bitLengths corresponding bit lengths for each value
     */
    function pack(uint256[] memory _values, uint256[] memory _bitLengths) external pure returns (uint256 packed) {
        require(_values.length == _bitLengths.length, "Mismatch in the lengths of values and bitLengths arrays");

        uint256 currentShift;

        for (uint256 i; i < _values.length; ++i) {
            require(currentShift + _bitLengths[i] <= 256, "Packed value exceeds 256 bits");

            uint256 maxValue = (1 << _bitLengths[i]) - 1;
            require(_values[i] <= maxValue, "Value too large for specified bit length");

            uint256 maskedValue = _values[i] & maxValue;
            packed |= maskedValue << currentShift;
            currentShift += _bitLengths[i];
        }
    }

    /**
     * @dev Unpacks a single uint256 into an array of values
     * @param _packed packed value
     * @param _bitLengths corresponding bit lengths for each value
     */
    function unpack(uint256 _packed, uint256[] memory _bitLengths) external pure returns (uint256[] memory values) {
        values = new uint256[](_bitLengths.length);

        uint256 currentShift;
        for (uint256 i; i < _bitLengths.length; ++i) {
            require(currentShift + _bitLengths[i] <= 256, "Unpacked value exceeds 256 bits");

            uint256 maxValue = (1 << _bitLengths[i]) - 1;
            uint256 mask = maxValue << currentShift;
            values[i] = (_packed & mask) >> currentShift;

            currentShift += _bitLengths[i];
        }
    }

    /**
     * @dev Unpacks aggregator answer
     * @param _packed packed value
     * @return current current price (1e10)
     * @return open open price (1e10)
     * @return high high price (1e10)
     * @return low low price (1e10)
     * @return ts timestamp
     */
    function unpackAggregatorAnswer(
        uint256 _packed
    ) external pure returns (uint56 current, uint56 open, uint56 high, uint56 low, uint32 ts) {
        current = uint56(_packed);
        open = uint56(_packed >> 56);
        high = uint56(_packed >> 112);
        low = uint56(_packed >> 168);
        ts = uint32(_packed >> 224);
    }

    /**
     * @dev Unpacks trigger order calldata into 3 values
     * @param _packed packed value
     * @return orderType order type
     * @return trader trader address
     * @return index trade index
     */
    function unpackTriggerOrder(uint256 _packed) external pure returns (uint8 orderType, address trader, uint32 index) {
        orderType = uint8(_packed & 0xFF); // 8 bits
        trader = address(uint160(_packed >> 8)); // 160 bits
        index = uint32((_packed >> 168)); // 32 bits
    }
}
