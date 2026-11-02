// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAssertion} from "../contracts/assertions/interfaces/IAssertion.sol";
import {INativeETHAssertion} from "../contracts/assertions/interfaces/INativeETHAssertion.sol";
import {IERC20Assertion} from "../contracts/assertions/interfaces/IERC20Assertion.sol";
import {IERC721Assertion} from "../contracts/assertions/interfaces/IERC721Assertion.sol";
import {NativeETHAssertion} from "../contracts/assertions/NativeETHAssertion.sol";
import {ERC20Assertion} from "../contracts/assertions/ERC20Assertion.sol";
import {ERC721Assertion} from "../contracts/assertions/ERC721Assertion.sol";
import {IStateAssertion} from "../contracts/assertions/interfaces/IStateAssertion.sol";
import {StateAssertion} from "../contracts/assertions/StateAssertion.sol";
import {TEST_READER} from "./utils/TestReader.sol";
import {MockTxTraceReader} from "./mocks/MockTxTraceReader.sol";

/// @notice Every assertion contract implements `IAssertion` and reports its own interface through ERC-165.
contract AssertionTest is Test {
    bytes4 internal constant ERC165_ID = 0x01ffc9a7;

    function test_supportsInterface() public {
        vm.etch(address(TEST_READER), address(new MockTxTraceReader()).code);
        _check(new NativeETHAssertion(TEST_READER), type(INativeETHAssertion).interfaceId);
        _check(new ERC20Assertion(TEST_READER), type(IERC20Assertion).interfaceId);
        _check(new ERC721Assertion(), type(IERC721Assertion).interfaceId);
        _check(new StateAssertion(TEST_READER), type(IStateAssertion).interfaceId);
    }

    function test_specificInterfacesAreDistinct() public pure {
        assertTrue(type(INativeETHAssertion).interfaceId != type(IERC20Assertion).interfaceId);
        assertTrue(type(IERC20Assertion).interfaceId != type(IERC721Assertion).interfaceId);
        assertTrue(type(INativeETHAssertion).interfaceId != type(IERC721Assertion).interfaceId);
    }

    function _check(IAssertion assertion, bytes4 specificId) internal view {
        assertTrue(assertion.supportsInterface(ERC165_ID));
        assertTrue(assertion.supportsInterface(type(IAssertion).interfaceId));
        assertTrue(assertion.supportsInterface(specificId));
        assertFalse(assertion.supportsInterface(0xffffffff));
        assertEq(assertion.version(), "0.1.0");
    }
}
