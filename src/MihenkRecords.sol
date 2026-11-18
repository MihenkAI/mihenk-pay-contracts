// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title MihenkRecords
/// @author Mihenk AI (https://mihenkai.com)
/// @notice Append-only public records of Mihenk AI. Each record is the root hash of a file Mihenk publishes, such as the
///         daily 0G Storage archive of TEE-verified readings and x402 receipts, or the daily Merkle root of the evidence
///         archive (what KOLs posted and when). A record is written once per kind and day and can never be changed, so
///         anyone can later check that a file existed unchanged when it was recorded.
contract MihenkRecords {
    /// @notice The only address that can write records, fixed at deployment.
    address public immutable writer;

    /// @notice kind => UTC day (YYYYMMDD) => root hash. Zero means nothing recorded.
    mapping(bytes32 kind => mapping(uint32 day => bytes32 root)) public rootOf;

    /// @notice Number of records written.
    uint256 public count;

    event Recorded(bytes32 indexed kind, uint32 indexed day, bytes32 root, string uri);

    error NotWriter();
    error EmptyRoot();
    error AlreadyRecorded(bytes32 kind, uint32 day, bytes32 root);

    constructor() {
        writer = msg.sender;
    }

    /// @param kind what the root is about, as a short ASCII label (for example "0G_STORAGE_DAILY")
    /// @param day  UTC day the file covers, as YYYYMMDD
    /// @param root root hash of the file
    /// @param uri  where to find the file or how to check it
    function record(bytes32 kind, uint32 day, bytes32 root, string calldata uri) external {
        if (msg.sender != writer) revert NotWriter();
        if (root == bytes32(0)) revert EmptyRoot();
        bytes32 old = rootOf[kind][day];
        if (old != bytes32(0)) revert AlreadyRecorded(kind, day, old);
        rootOf[kind][day] = root;
        unchecked {
            ++count;
        }
        emit Recorded(kind, day, root, uri);
    }
}
