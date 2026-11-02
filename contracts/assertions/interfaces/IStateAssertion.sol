// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAssertion} from "./IAssertion.sol";

/// @title IStateAssertion
/// @notice Checks that a contract's state did not change in ways the user did not expect. Protocol-enforced: read
///         from the storage, code and event tables, no knowledge of the contract needed beyond slot numbers.
/// @dev Example (Bybit, Feb 2025): a Safe signed a transaction whose delegatecall rewrote slot 0, the Safe's
///      implementation pointer. `slotUnchanged(safe, 0)` reverts it. `onlySlotsChanged(safe, [nonce slot])` also
///      catches owner, threshold, module and guard changes, whose slots are hashes the wallet cannot list.
interface IStateAssertion is IAssertion {
    error SlotChanged(address target, bytes32 slot, bytes32 beforeValue, bytes32 afterValue);
    error CodeChanged(address target);
    error ContractTouched(address target, uint256 storageChanges, uint256 events, bool codeChanged);

    /// @notice `slot` of `target` is unchanged.
    function slotUnchanged(address target, bytes32 slot) external view;

    /// @notice `target`'s code is unchanged and every changed slot is in `allowedSlots`.
    function onlySlotsChanged(address target, bytes32[] calldata allowedSlots) external view;

    /// @notice `target`'s code hash (including an EIP-7702 delegation) is unchanged.
    function codeUnchanged(address target) external view;

    /// @notice None of `targets` changed storage or code or emitted an event. Strict: also fails if the transaction
    ///         routes one of them for someone else.
    function untouched(address[] calldata targets) external view;
}
