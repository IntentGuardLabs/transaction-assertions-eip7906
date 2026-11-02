// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {ITxTraceReader} from "../contracts/shared/ITxTraceReader.sol";

/// @notice Verifies the opcode bridge `TxTraceReader.yul` without an EIP-7906 EVM.
/// @dev Foundry's EVM does not implement TXTRACE (0xb6) or EVENTDATACOPY (0xb7). These tests check that each
///      opcode appears exactly once, that reads fail without EIP-7906, and the operand order (by patching each
///      opcode into a standard opcode with the same stack arity: TXTRACE -> SUB, EVENTDATACOPY -> LOG2). They do NOT show that a real client returns the
///      expected values.
contract TxTraceReaderTest is Test {
    bytes internal initCode;
    bytes internal runtime;

    function setUp() public {
        // Yul artifacts carry no ABI, so read the bytecode straight from the JSON.
        string memory artifact = vm.readFile("out/TxTraceReader.yul/TxTraceReader.json");
        initCode = vm.parseJsonBytes(artifact, ".bytecode.object");
        runtime = vm.parseJsonBytes(artifact, ".deployedBytecode.object");
    }

    function _deploy(bytes memory code) internal returns (address target) {
        target = makeAddr(vm.toString(keccak256(code)));
        vm.etch(target, code);
    }

    /// @dev Replaces opcode `from` with `to` at instruction boundaries only (PUSH data is skipped).
    function _patch(bytes memory code, uint8 from, uint8 to) internal pure returns (bytes memory patched, uint256 n) {
        patched = bytes.concat(code);
        for (uint256 pc; pc < patched.length; ++pc) {
            uint8 op = uint8(patched[pc]);
            if (op == from) {
                patched[pc] = bytes1(to);
                ++n;
            } else if (op >= 0x60 && op <= 0x7f) {
                pc += op - 0x5f;
            }
        }
    }

    function test_eachOpcodeExactlyOnceAndNoStateAccess() public view {
        (, uint256 txtrace) = _patch(runtime, 0xb6, 0xb6);
        (, uint256 copy) = _patch(runtime, 0xb7, 0xb7);
        assertEq(txtrace, 1, "TXTRACE");
        assertEq(copy, 1, "EVENTDATACOPY");
        uint8[10] memory forbidden = [0x54, 0x55, 0x5c, 0x5d, 0xf1, 0xf2, 0xf4, 0xf0, 0xf5, 0xff];
        for (uint256 i; i < forbidden.length; ++i) {
            (, uint256 n) = _patch(runtime, forbidden[i], forbidden[i]);
            assertEq(n, 0, "state-accessing opcode present");
        }
    }

    function test_readsFailWithoutEip7906() public {
        address reader = _deploy(runtime);
        (bool ok,) = reader.staticcall(abi.encodeCall(ITxTraceReader.txtrace, (0x11, 0)));
        assertFalse(ok);
        (ok,) = reader.staticcall(abi.encodeCall(ITxTraceReader.eventDataCopy, (0, 0, 32)));
        assertFalse(ok);
    }

    function test_rejectsBadCalls() public {
        (bytes memory patched,) = _patch(runtime, 0xb6, 0x03);
        address reader = _deploy(patched);
        (bool ok,) = reader.staticcall(abi.encodeWithSignature("foo()"));
        assertFalse(ok, "unknown selector");
        (ok,) = reader.staticcall(abi.encodePacked(ITxTraceReader.txtrace.selector, uint256(1)));
        assertFalse(ok, "short calldata");
        vm.deal(address(this), 1);
        (ok,) = reader.call{value: 1}(abi.encodeCall(ITxTraceReader.txtrace, (1, 2)));
        assertFalse(ok, "call value");
    }

    /// @dev SUB computes `top - second`; returning `param - in2` proves `param` is on top of the stack.
    function testFuzz_txtraceOperandOrder(uint256 param, uint256 in2) public {
        (bytes memory patched,) = _patch(runtime, 0xb6, 0x03);
        ITxTraceReader reader = ITxTraceReader(_deploy(patched));
        uint256 expected;
        unchecked {
            expected = param - in2;
        }
        assertEq(reader.txtrace(param, in2), expected);
    }

    /// @dev LOG2 consumes [offset, size, topic1, topic2]. EVENTDATACOPY's stack is
    ///      [eventIndex, memOffset, dataOffset, length], so topics are (dataOffset, length) and the data is
    ///      memory[eventIndex, eventIndex + memOffset). With eventIndex = 0x20 that is the ABI length word plus one
    ///      zero word, which also shows memOffset = 0x40.
    function testFuzz_eventDataCopyOperandOrder(uint256 dataOffset, uint16 length) public {
        (bytes memory patched,) = _patch(runtime, 0xb7, 0xa2);
        address reader = _deploy(patched);
        vm.recordLogs();
        (bool ok, bytes memory ret) =
            reader.call(abi.encodeCall(ITxTraceReader.eventDataCopy, (0x20, dataOffset, length)));
        assertTrue(ok);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], bytes32(dataOffset));
        assertEq(logs[0].topics[1], bytes32(uint256(length)));
        assertEq(logs[0].data, abi.encode(uint256(length), uint256(0)));
        assertEq(abi.decode(ret, (bytes)).length, length);
    }
}
