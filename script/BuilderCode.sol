// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Base Builder Code attribution (ERC-8021, Schema 0) for Mihenk AI.
/// On Base mainnet every transaction our scripts send carries Mihenk AI's Builder Code
/// (`bc_s415ugdv`) at the end of its calldata, so Base attributes the activity to Mihenk AI.
/// Contracts ignore the trailing bytes; on other chains the calldata is left unchanged.
/// Suffix layout: code (ASCII) || code length (1 byte) || schema id 0x00 || marker 0x8021 x 8.
/// Generated with ox/erc8021 `Attribution.toDataSuffix({ codes: ["bc_s415ugdv"] })`.
library BuilderCode {
    uint256 internal constant BASE_MAINNET = 8453;
    bytes internal constant SUFFIX = hex"62635f73343135756764760b0080218021802180218021802180218021";

    function tag(bytes memory data) internal view returns (bytes memory) {
        return block.chainid == BASE_MAINNET ? bytes.concat(data, SUFFIX) : data;
    }

    /// Low-level call with the tagged calldata; bubbles up the revert reason.
    function exec(address target, bytes memory data) internal returns (bytes memory ret) {
        bool ok;
        (ok, ret) = target.call(tag(data));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}
