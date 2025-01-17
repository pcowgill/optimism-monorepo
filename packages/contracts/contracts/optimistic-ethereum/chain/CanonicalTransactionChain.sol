pragma solidity ^0.5.0;
pragma experimental ABIEncoderV2;

/* Internal Imports */
import { ContractResolver } from "../utils/resolvers/ContractResolver.sol";
import { DataTypes } from "../utils/libraries/DataTypes.sol";
import { RollupMerkleUtils } from "../utils/libraries/RollupMerkleUtils.sol";
import { L1ToL2TransactionQueue } from "../queue/L1ToL2TransactionQueue.sol";
import { SafetyTransactionQueue } from "../queue/SafetyTransactionQueue.sol";

contract CanonicalTransactionChain is ContractResolver {
    /*
     * Contract Variables
     */
    address public sequencer;
    uint public forceInclusionPeriod;
    uint public cumulativeNumElements;
    bytes32[] public batches;
    uint public lastOVMTimestamp;


    /*
     * Events
     */

    event L1ToL2BatchAppended( bytes32 _batchHeaderHash);
    event SafetyQueueBatchAppended( bytes32 _batchHeaderHash);
    event SequencerBatchAppended(bytes32 _batchHeaderHash);


    /*
     * Constructor
     */

    constructor(
        address _addressResolver,
        address _sequencer,
        address _l1ToL2TransactionPasserAddress,
        uint _forceInclusionPeriod
    )
        public
        ContractResolver(_addressResolver)
    {
        sequencer = _sequencer;
        forceInclusionPeriod = _forceInclusionPeriod;
        lastOVMTimestamp = 0;
    }

    /*
     * Public Functions
     */

    function getBatchesLength() public view returns (uint) {
       return batches.length;
    }

    function hashBatchHeader(
        DataTypes.TxChainBatchHeader memory _batchHeader
    ) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(
            _batchHeader.timestamp,
            _batchHeader.isL1ToL2Tx,
            _batchHeader.elementsMerkleRoot,
            _batchHeader.numElementsInBatch,
            _batchHeader.cumulativePrevElements
        ));
    }

    function authenticateAppend(
        address _sender
    ) public view returns (bool) {
        return _sender == sequencer;
    }

    function appendL1ToL2Batch() public {
        L1ToL2TransactionQueue l1ToL2Queue = resolveL1ToL2TransactionQueue();
        SafetyTransactionQueue safetyQueue = resolveSafetyTransactionQueue();

        DataTypes.TimestampedHash memory l1ToL2Header = l1ToL2Queue.peek();

        require(
            safetyQueue.isEmpty() || l1ToL2Header.timestamp <= safetyQueue.peekTimestamp(),
            "Must process older SafetyQueue batches first to enforce timestamp monotonicity"
        );

        _appendQueueBatch(l1ToL2Header, true);
        l1ToL2Queue.dequeue();
    }

    function appendSafetyBatch() public {
        L1ToL2TransactionQueue l1ToL2Queue = resolveL1ToL2TransactionQueue();
        SafetyTransactionQueue safetyQueue = resolveSafetyTransactionQueue();

        DataTypes.TimestampedHash memory safetyHeader = safetyQueue.peek();

        require(
            l1ToL2Queue.isEmpty() || safetyHeader.timestamp <= l1ToL2Queue.peekTimestamp(),
            "Must process older L1ToL2Queue batches first to enforce timestamp monotonicity"
        );

        _appendQueueBatch(safetyHeader, false);
        safetyQueue.dequeue();
    }

    function _appendQueueBatch(
        DataTypes.TimestampedHash memory timestampedHash,
        bool isL1ToL2Tx
    ) internal {
        uint timestamp = timestampedHash.timestamp;

        require(
            timestamp + forceInclusionPeriod <= now || authenticateAppend(msg.sender),
            "Message sender does not have permission to append this batch"
        );

        lastOVMTimestamp = timestamp;
        bytes32 elementsMerkleRoot = timestampedHash.txHash;
        uint numElementsInBatch = 1;

        bytes32 batchHeaderHash = keccak256(abi.encodePacked(
            timestamp,
            isL1ToL2Tx,
            elementsMerkleRoot,
            numElementsInBatch,
            cumulativeNumElements // cumulativePrevElements
        ));

        batches.push(batchHeaderHash);
        cumulativeNumElements += numElementsInBatch;

        if (isL1ToL2Tx) {
            emit L1ToL2BatchAppended(batchHeaderHash);
        } else {
            emit SafetyQueueBatchAppended(batchHeaderHash);
        }
    }

    function appendSequencerBatch(
        bytes[] memory _txBatch,
        uint _timestamp
    ) public {
        L1ToL2TransactionQueue l1ToL2Queue = resolveL1ToL2TransactionQueue();
        SafetyTransactionQueue safetyQueue = resolveSafetyTransactionQueue();

        require(
            authenticateAppend(msg.sender),
            "Message sender does not have permission to append a batch"
        );

        require(
            _txBatch.length > 0,
            "Cannot submit an empty batch"
        );

        require(
            _timestamp + forceInclusionPeriod > now,
            "Cannot submit a batch with a timestamp older than the sequencer inclusion period"
        );

        require(
            _timestamp <= now,
            "Cannot submit a batch with a timestamp in the future"
        );

        require(
            l1ToL2Queue.isEmpty() || _timestamp <= l1ToL2Queue.peekTimestamp(),
            "Must process older L1ToL2Queue batches first to enforce timestamp monotonicity"
        );

        require(
            safetyQueue.isEmpty() || _timestamp <= safetyQueue.peekTimestamp(),
            "Must process older SafetyQueue batches first to enforce timestamp monotonicity"
        );

        require(
            _timestamp >= lastOVMTimestamp,
            "Timestamps must monotonically increase"
        );

        lastOVMTimestamp = _timestamp;

        RollupMerkleUtils merkleUtils = resolveRollupMerkleUtils();
        bytes32 batchHeaderHash = keccak256(abi.encodePacked(
            _timestamp,
            false, // isL1ToL2Tx
            merkleUtils.getMerkleRoot(_txBatch), // elementsMerkleRoot
            _txBatch.length, // numElementsInBatch
            cumulativeNumElements // cumulativeNumElements
        ));

        batches.push(batchHeaderHash);
        cumulativeNumElements += _txBatch.length;

        emit SequencerBatchAppended(batchHeaderHash);
    }

    // verifies an element is in the current list at the given position
    function verifyElement(
        bytes memory _element, // the element of the list being proven
        uint _position, // the position in the list of the element being proven
        DataTypes.TxElementInclusionProof memory _inclusionProof  // inclusion proof in the rollup batch
    ) public view returns (bool) {
        // For convenience, store the batchHeader
        DataTypes.TxChainBatchHeader memory batchHeader = _inclusionProof.batchHeader;

        // make sure absolute position equivalent to relative positions
        if (_position != _inclusionProof.indexInBatch +
            batchHeader.cumulativePrevElements) {
            return false;
        }

        // verify elementsMerkleRoot
        RollupMerkleUtils merkleUtils = resolveRollupMerkleUtils();
        if (!merkleUtils.verify(
            batchHeader.elementsMerkleRoot,
            _element,
            _inclusionProof.indexInBatch,
            _inclusionProof.siblings
        )) {
            return false;
        }

        //compare computed batch header with the batch header in the list.
        return hashBatchHeader(batchHeader) == batches[_inclusionProof.batchIndex];
    }


    /*
     * Contract Resolution
     */

    function resolveL1ToL2TransactionQueue() internal view returns (L1ToL2TransactionQueue) {
        return L1ToL2TransactionQueue(resolveContract("L1ToL2TransactionQueue"));
    }

    function resolveSafetyTransactionQueue() internal view returns (SafetyTransactionQueue) {
        return SafetyTransactionQueue(resolveContract("SafetyTransactionQueue"));
    }

    function resolveRollupMerkleUtils() internal view returns (RollupMerkleUtils) {
        return RollupMerkleUtils(resolveContract("RollupMerkleUtils"));
    }
}
