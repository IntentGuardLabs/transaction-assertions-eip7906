// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ITxTraceReader
/// @notice ABI of `TxTraceReader.yul`, which forwards to the EIP-7906 opcodes. Calls inherit the opcodes'
///         exceptional halts, which callers treat as a failed assertion.
interface ITxTraceReader {
    /// @notice `TXTRACE(param, in2)`.
    function txtrace(uint256 param, uint256 in2) external view returns (uint256 value);

    /// @notice `EVENTDATACOPY`: `length` bytes of event `eventIndex`'s data, from `dataOffset`.
    function eventDataCopy(uint256 eventIndex, uint256 dataOffset, uint256 length)
        external
        view
        returns (bytes memory data);
}
