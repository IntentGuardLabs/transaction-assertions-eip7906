// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Assertion} from "./Assertion.sol";
import {IAssertion} from "./interfaces/IAssertion.sol";
import {IStateAssertion} from "./interfaces/IStateAssertion.sol";
import {ITxTraceReader} from "../shared/ITxTraceReader.sol";
import {TxTrace} from "../shared/TxTrace.sol";

/// @title StateAssertion
/// @notice Protected slots, slot allowlists, code integrity and untouchable contracts. See `IStateAssertion`.
contract StateAssertion is Assertion, TxTrace, IStateAssertion {
    constructor(ITxTraceReader reader) TxTrace(reader) {}

    function slotUnchanged(address target, bytes32 slot) external view {
        (bool changed, bytes32 beforeValue, bytes32 afterValue) = storageChange(target, slot);
        if (changed) revert SlotChanged(target, slot, beforeValue, afterValue);
    }

    function onlySlotsChanged(address target, bytes32[] calldata allowedSlots) external view {
        if (codeChanged(target)) revert CodeChanged(target);
        StorageChange[] memory changes = storageChanges(target);
        for (uint256 i = 0; i < changes.length; i++) {
            if (!_contains(allowedSlots, changes[i].slot)) {
                revert SlotChanged(target, changes[i].slot, changes[i].beforeValue, changes[i].afterValue);
            }
        }
    }

    function codeUnchanged(address target) external view {
        if (codeChanged(target)) revert CodeChanged(target);
    }

    function untouched(address[] calldata targets) external view {
        for (uint256 i = 0; i < targets.length; i++) {
            uint256 slots = storageChanges(targets[i]).length;
            uint256 emitted = events(targets[i]).length;
            bool code = codeChanged(targets[i]);
            if (slots != 0 || emitted != 0 || code) revert ContractTouched(targets[i], slots, emitted, code);
        }
    }

    function _contains(bytes32[] calldata list, bytes32 item) private pure returns (bool) {
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == item) return true;
        }
        return false;
    }

    function supportsInterface(bytes4 interfaceId) public view override(Assertion, IAssertion) returns (bool) {
        return interfaceId == type(IStateAssertion).interfaceId || super.supportsInterface(interfaceId);
    }
}
