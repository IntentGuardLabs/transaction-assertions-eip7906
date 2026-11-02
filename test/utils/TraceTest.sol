// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockTxTraceReader} from "../mocks/MockTxTraceReader.sol";
import {TxTrace} from "../../contracts/shared/TxTrace.sol";
import {TEST_READER} from "./TestReader.sol";

/// @notice Base for tests that build synthetic EIP-7906 traces.
abstract contract TraceTest is Test {
    bytes32 internal constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    bytes32 internal constant APPROVAL_TOPIC = keccak256("Approval(address,address,uint256)");
    bytes32 internal constant APPROVAL_FOR_ALL_TOPIC = keccak256("ApprovalForAll(address,address,bool)");

    MockTxTraceReader internal trace;

    /// @dev Installs the mock at the fixed reader address the contracts read from.
    function setUp() public virtual {
        vm.etch(address(TEST_READER), address(new MockTxTraceReader()).code);
        trace = MockTxTraceReader(address(TEST_READER));
    }

    function _word(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _topics(bytes32 t0) internal pure returns (bytes32[] memory t) {
        t = new bytes32[](1);
        t[0] = t0;
    }

    function _topics(bytes32 t0, bytes32 t1) internal pure returns (bytes32[] memory t) {
        t = new bytes32[](2);
        (t[0], t[1]) = (t0, t1);
    }

    function _topics(bytes32 t0, bytes32 t1, bytes32 t2) internal pure returns (bytes32[] memory t) {
        t = new bytes32[](3);
        (t[0], t[1], t[2]) = (t0, t1, t2);
    }

    function _topics(bytes32 t0, bytes32 t1, bytes32 t2, bytes32 t3) internal pure returns (bytes32[] memory t) {
        t = new bytes32[](4);
        (t[0], t[1], t[2], t[3]) = (t0, t1, t2, t3);
    }

    function _erc20Transfer(address token, address from, address to, uint256 value) internal returns (uint256) {
        return trace.pushEvent(token, _topics(TRANSFER_TOPIC, _word(from), _word(to)), abi.encode(value));
    }

    function _erc20Approval(address token, address owner, address spender, uint256 value) internal returns (uint256) {
        return trace.pushEvent(token, _topics(APPROVAL_TOPIC, _word(owner), _word(spender)), abi.encode(value));
    }

    function _erc721Transfer(address collection, address from, address to, uint256 tokenId) internal returns (uint256) {
        return trace.pushEvent(collection, _topics(TRANSFER_TOPIC, _word(from), _word(to), bytes32(tokenId)), "");
    }

    function _erc721Approval(address collection, address owner, address approved, uint256 tokenId)
        internal
        returns (uint256)
    {
        return trace.pushEvent(collection, _topics(APPROVAL_TOPIC, _word(owner), _word(approved), bytes32(tokenId)), "");
    }

    function _approvalForAll(address collection, address owner, address operator, bool approved)
        internal
        returns (uint256)
    {
        return trace.pushEvent(
            collection, _topics(APPROVAL_FOR_ALL_TOPIC, _word(owner), _word(operator)), abi.encode(approved)
        );
    }

    /// @dev An event unrelated to any token standard.
    function _noise(address emitter, uint256 salt) internal returns (uint256) {
        return trace.pushEvent(emitter, _topics(keccak256(abi.encode("noise", salt))), abi.encode(salt));
    }
}
