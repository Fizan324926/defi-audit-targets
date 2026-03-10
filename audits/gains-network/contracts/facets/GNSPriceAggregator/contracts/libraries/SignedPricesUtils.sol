// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import "../interfaces/IChainlinkOracle.sol";
import "./PriceAggregatorUtils.sol";

/**
 * @dev External utils library to handle signed prices
 */
library SignedPricesUtils {
    using ECDSA for bytes32;

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function validateSignedPairPrices(
        IPriceAggregator.SignedPairPrices[] calldata _signedPairPrices,
        bool _isLookback
    ) external {
        // 1. Should pass exactly min answers signatures
        // 2. Each signer id has to be unique, in ascending order (same oracle can't send two signatures)
        // 3. Expiry timestamp can't be reached or be too far in the future
        // 4. isLookback and fromBlock have to match for all oracles (and isLookback has to be expected input value)
        // 5. Signature has to be valid (signed by fulfiller of oracle)
        // 6. Pair indices array and current prices array lengths have to match
        // 7. Pair indices array of each signature has to match exactly and be strictly ascending (no duplicates)
        // 8. Pair has to be listed
        // 9. Price candles are validated (depending on lookback or non-lookback)
        // 10. Median after outliers filtering is stored in temporary storage
        // 11. Pair indices array is stored in temporary storage (for cleanup)

        IPriceAggregator.PriceAggregatorStorage storage s = PriceAggregatorUtils._getStorage();

        if (_signedPairPrices.length != s.minAnswers) revert IPriceAggregatorUtils.WrongSignaturesCount();

        uint8 lastSignerId;
        uint32 fromBlock = _signedPairPrices[0].fromBlock;

        // Iterate over each signature (one per oracle, one signature contains all current pair prices)
        // Validate each signature, and store it in temporary pair storage
        for (uint256 i; i < _signedPairPrices.length; i++) {
            IPriceAggregator.SignedPairPrices memory signedData = _signedPairPrices[i];

            if (i > 0 && signedData.signerId <= lastSignerId) revert IPriceAggregatorUtils.WrongSignerIdOrder();
            lastSignerId = signedData.signerId;

            if (block.timestamp > signedData.expiryTs) revert IPriceAggregatorUtils.InvalidExpiryTimestamp();
            if (signedData.expiryTs > block.timestamp + 1 hours) revert IPriceAggregatorUtils.ExpiryTooFar();
            if (signedData.isLookback != _isLookback) revert IPriceAggregatorUtils.LookbackMismatch();
            if (signedData.fromBlock != fromBlock) revert IPriceAggregatorUtils.FromBlockMismatch();

            bytes32 messageHash = keccak256(
                abi.encode(
                    signedData.pairIndices,
                    signedData.prices,
                    signedData.expiryTs,
                    _isLookback,
                    signedData.fromBlock
                )
            ).toEthSignedMessageHash();
            address recoveredSigner = messageHash.recover(signedData.signature);

            if (!IChainlinkOracle(s.oracles[signedData.signerId]).getAuthorizationStatus(recoveredSigner))
                revert IPriceAggregatorUtils.InvalidSignature();

            if (signedData.pairIndices.length != signedData.prices.length)
                revert IPriceAggregatorUtils.PairAndCurrentPriceLengthMismatch();

            if (signedData.pairIndices.length != _signedPairPrices[0].pairIndices.length)
                revert IPriceAggregatorUtils.PairLengthMismatchBetweenSigners();

            // Iterate over each pair / pair price
            for (uint256 j; j < signedData.pairIndices.length; j++) {
                uint16 pairIndex = signedData.pairIndices[j];
                IPriceAggregator.OrderAnswer memory answer = signedData.prices[j];

                if (pairIndex != _signedPairPrices[0].pairIndices[j])
                    revert IPriceAggregatorUtils.PairIndexMismatchBetweenSigners();

                PriceAggregatorUtils._getMultiCollatDiamond().pairJob(pairIndex); // make sure pair is listed
                PriceAggregatorUtils._validateAggregatorAnswer(answer, _isLookback); // validate order answer

                s.signedOrderAnswersTemporary[pairIndex].push(answer);
            }
        }

        uint16[] memory pairIndices = _signedPairPrices[0].pairIndices; // validation above guarantees same pair indices array for all signers
        uint8 minAnswers = s.minAnswers;
        uint24 maxDeviationP = _isLookback ? s.maxLookbackDeviationP : s.maxMarketDeviationP;

        // Iterate over each pair once, calculate and store median price in temporary storage (after removing outliers)
        // + validate pair indices are unique and sorted
        uint16 lastPairIndex;
        for (uint256 i; i < pairIndices.length; i++) {
            uint16 pairIndex = pairIndices[i];

            // Validate pair indices are unique and sorted (except for first iteration)
            if (i > 0 && pairIndex <= lastPairIndex) revert IPriceAggregatorUtils.DuplicateOrUnsortedPairIndices();
            lastPairIndex = pairIndex;

            IPriceAggregator.OrderAnswer[] memory unfilteredAnswers = s.signedOrderAnswersTemporary[pairIndex];

            (
                IPriceAggregator.OrderAnswer[] memory filteredAnswers,
                bool minFilteredAnswersReached,
                ITradingCallbacks.AggregatorAnswer memory finalAnswer
            ) = PriceAggregatorUtils._filterOutliersAndReturnMedian(
                    unfilteredAnswers,
                    _isLookback,
                    minAnswers,
                    maxDeviationP
                );

            if (minFilteredAnswersReached) {
                s.signedMediansTemporary[pairIndex] = finalAnswer;
            }

            emit IPriceAggregatorUtils.SignedPricesReceived(
                pairIndex,
                _isLookback,
                fromBlock,
                minFilteredAnswersReached,
                unfilteredAnswers,
                filteredAnswers
            );
        }

        // Store temporary pair indices for easy cleanup
        s.signedPairIndicesTemporary = pairIndices;
    }

    /**
     * @dev Check IPriceAggregatorUtils interface for documentation
     */
    function cleanUpSignedPairPrices() external {
        IPriceAggregator.PriceAggregatorStorage storage s = PriceAggregatorUtils._getStorage();
        uint16[] memory pairIndices = s.signedPairIndicesTemporary;

        for (uint16 i; i < pairIndices.length; i++) {
            uint16 pairIndex = pairIndices[i];
            delete s.signedOrderAnswersTemporary[pairIndex];
            delete s.signedMediansTemporary[pairIndex];
        }

        delete s.signedPairIndicesTemporary;
    }
}
