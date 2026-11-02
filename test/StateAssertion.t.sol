// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StateAssertion} from "../contracts/assertions/StateAssertion.sol";
import {IStateAssertion} from "../contracts/assertions/interfaces/IStateAssertion.sol";
import {TraceTest} from "./utils/TraceTest.sol";
import {TEST_READER} from "./utils/TestReader.sol";

contract StateAssertionTest is TraceTest {
    StateAssertion internal state;

    address internal constant SAFE = address(0x5AFE);
    address internal constant TOKEN = address(0x7070);
    address internal constant OTHER = address(0x07E2);
    address internal constant SINGLETON = address(0x1111);
    address internal constant ATTACKER = address(0xBAD);
    bytes32 internal constant SINGLETON_SLOT = bytes32(0);
    bytes32 internal constant NONCE_SLOT = bytes32(uint256(5));

    function setUp() public override {
        super.setUp();
        state = new StateAssertion(TEST_READER);
    }

    function _list(bytes32 a) internal pure returns (bytes32[] memory l) {
        l = new bytes32[](1);
        l[0] = a;
    }

    function _list(address a, address b) internal pure returns (address[] memory l) {
        l = new address[](2);
        (l[0], l[1]) = (a, b);
    }

    /// @dev Bybit: a delegatecall rewrites the Safe's implementation pointer at slot 0.
    function test_slotUnchanged_bybit() public {
        trace.setSlotChange(SAFE, NONCE_SLOT, bytes32(uint256(7)), bytes32(uint256(8)));
        trace.setSlotChange(OTHER, SINGLETON_SLOT, bytes32(0), _word(ATTACKER));
        state.slotUnchanged(SAFE, SINGLETON_SLOT);

        trace.setSlotChange(SAFE, SINGLETON_SLOT, _word(SINGLETON), _word(ATTACKER));
        vm.expectRevert(
            abi.encodeWithSelector(
                IStateAssertion.SlotChanged.selector, SAFE, SINGLETON_SLOT, _word(SINGLETON), _word(ATTACKER)
            )
        );
        state.slotUnchanged(SAFE, SINGLETON_SLOT);
    }

    /// @dev Adding an owner leaves slot 0 alone; the allowlist still catches the owners-mapping write.
    function test_onlySlotsChanged_catchesHashedSlots() public {
        bytes32 ownerSlot = keccak256(abi.encode(ATTACKER, uint256(2)));
        trace.setSlotChange(SAFE, NONCE_SLOT, bytes32(uint256(7)), bytes32(uint256(8)));
        state.onlySlotsChanged(SAFE, _list(NONCE_SLOT));

        trace.setSlotChange(SAFE, ownerSlot, bytes32(0), _word(address(1)));
        state.slotUnchanged(SAFE, SINGLETON_SLOT);
        vm.expectRevert(
            abi.encodeWithSelector(IStateAssertion.SlotChanged.selector, SAFE, ownerSlot, bytes32(0), _word(address(1)))
        );
        state.onlySlotsChanged(SAFE, _list(NONCE_SLOT));
    }

    function test_codeChecks() public {
        state.codeUnchanged(SAFE);
        trace.pushCodeChange(SAFE, keccak256("proxy"), keccak256("delegation"));
        vm.expectRevert(abi.encodeWithSelector(IStateAssertion.CodeChanged.selector, SAFE));
        state.codeUnchanged(SAFE);
        vm.expectRevert(abi.encodeWithSelector(IStateAssertion.CodeChanged.selector, SAFE));
        state.onlySlotsChanged(SAFE, new bytes32[](0));
    }

    function test_untouched() public {
        trace.setSlotChange(OTHER, bytes32(0), bytes32(0), bytes32(uint256(1)));
        _noise(OTHER, 1);
        state.untouched(_list(TOKEN, SAFE));

        // A silent approval: a storage write with no event.
        trace.setSlotChange(TOKEN, keccak256("allowance"), bytes32(0), bytes32(type(uint256).max));
        vm.expectRevert(abi.encodeWithSelector(IStateAssertion.ContractTouched.selector, TOKEN, 1, 0, false));
        state.untouched(_list(SAFE, TOKEN));

        trace.reset();
        _noise(SAFE, 2);
        vm.expectRevert(abi.encodeWithSelector(IStateAssertion.ContractTouched.selector, SAFE, 0, 1, false));
        state.untouched(_list(TOKEN, SAFE));
    }
}
