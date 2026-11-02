/// @title TxTraceReader
/// @notice Forwards calls to the EIP-7906 opcodes TXTRACE (0xb6) and EVENTDATACOPY (0xb7). ABI: ITxTraceReader.sol.
/// @dev solc cannot emit these opcodes, and `verbatim` only exists in standalone Yul, so they live here. Opcode
///      halts halt this call, which fails the calling assertion. Deployed via the CREATE2 factory with salt 0.
object "TxTraceReader" {
    code {
        datacopy(0, dataoffset("runtime"), datasize("runtime"))
        return(0, datasize("runtime"))
    }
    object "runtime" {
        code {
            if callvalue() { revert(0, 0) }

            switch shr(224, calldataload(0))
            // txtrace(uint256,uint256)
            case 0x55f6f8d7 {
                if iszero(eq(calldatasize(), 68)) { revert(0, 0) }
                mstore(0, txtrace(calldataload(4), calldataload(36)))
                return(0, 32)
            }
            // eventDataCopy(uint256,uint256,uint256)
            case 0x9666f50f {
                if iszero(eq(calldatasize(), 100)) { revert(0, 0) }
                let length := calldataload(68)
                // Event data is bounded by transaction gas; reject absurd lengths before computing memory bounds.
                if gt(length, 0xffffffff) { revert(0, 0) }
                // ABI-encode `bytes`: offset word, length word, then the payload copied straight into place.
                mstore(0x00, 0x20)
                mstore(0x20, length)
                // Stack: [top: eventIndex, memOffset, dataOffset, length].
                verbatim_4i_0o(hex"b7", calldataload(4), 0x40, calldataload(36), length)
                // Memory past the copied bytes was never written, so the right padding is already zero.
                return(0x00, add(0x40, and(add(length, 31), not(31))))
            }
            default { revert(0, 0) }

            // verbatim places its first argument on top of the stack: [param, in2].
            function txtrace(param, in2) -> value {
                value := verbatim_2i_1o(hex"b6", param, in2)
            }
        }
    }
}
