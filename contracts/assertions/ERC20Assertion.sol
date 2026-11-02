// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Assertion} from "./Assertion.sol";
import {IAssertion} from "./interfaces/IAssertion.sol";
import {IERC20Assertion} from "./interfaces/IERC20Assertion.sol";
import {ITxTraceReader} from "../shared/ITxTraceReader.sol";
import {TxTrace} from "../shared/TxTrace.sol";

/// @title ERC20Assertion
/// @notice Token limits for an account: at most X spent, at least X received, balance unchanged, no approval to an
///         unknown spender. Reads the holder's balance slot (exact) or the token's Transfer/Approval events.
/// @dev A `Transfer` or `Approval` from the token that is not exactly ERC-20 shaped reverts: it cannot be decoded,
///      so it cannot be ruled out.
contract ERC20Assertion is Assertion, TxTrace, IERC20Assertion {
    bytes32 internal constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    bytes32 internal constant APPROVAL_TOPIC = keccak256("Approval(address,address,uint256)");
    bytes32 internal constant EIP1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant EIP1967_BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;

    constructor(ITxTraceReader reader) TxTrace(reader) {}

    // Events

    function minReceived(address token, address account, uint256 amount) external view {
        (uint256 gain, uint256 loss) = eventNetChange(token, account);
        if (gain < amount) revert MinReceivedNotMet(token, account, amount, gain, loss);
    }

    function maxSpent(address token, address account, uint256 amount) external view {
        (uint256 gain, uint256 loss) = eventNetChange(token, account);
        if (loss > amount) revert MaxSpentExceeded(token, account, amount, gain, loss);
    }

    function balanceUnchanged(address token, address account) external view {
        (uint256 gain, uint256 loss) = eventNetChange(token, account);
        if (gain != 0 || loss != 0) revert BalanceChanged(token, account, gain, loss);
    }

    function eventNetChange(address token, address account) public view returns (uint256 gain, uint256 loss) {
        Transfer[] memory t = transfers(token);
        uint256 received;
        uint256 sent;
        for (uint256 i = 0; i < t.length; i++) {
            if (t[i].to == account) received += t[i].value;
            if (t[i].from == account) sent += t[i].value;
        }
        if (received >= sent) return (received - sent, 0);
        return (0, sent - received);
    }

    function noUnexpectedApprovals(address token, address owner, address[] calldata allowedSpenders) external view {
        Approval[] memory a = approvals(token);
        for (uint256 i = 0; i < a.length; i++) {
            if (a[i].owner == owner && a[i].value != 0 && !_contains(allowedSpenders, a[i].spender)) {
                revert UnexpectedApproval(token, owner, a[i].spender, a[i].value, a[i].eventIndex);
            }
        }
    }

    function transfers(address token) public view returns (Transfer[] memory result) {
        Event[] memory e = events(token, TRANSFER_TOPIC);
        result = new Transfer[](e.length);
        for (uint256 i = 0; i < e.length; i++) {
            (address from, address to, uint256 value, bool ok) = _decode(e[i]);
            if (!ok) revert MalformedTransferEvent(e[i].index);
            result[i] = Transfer(e[i].index, from, to, value);
        }
    }

    function approvals(address token) public view returns (Approval[] memory result) {
        Event[] memory e = events(token, APPROVAL_TOPIC);
        result = new Approval[](e.length);
        for (uint256 i = 0; i < e.length; i++) {
            (address owner, address spender, uint256 value, bool ok) = _decode(e[i]);
            if (!ok) revert MalformedApprovalEvent(e[i].index);
            result[i] = Approval(e[i].index, owner, spender, value);
        }
    }

    // Storage

    function minReceivedAtSlot(address token, bytes32 balanceSlot, uint256 amount) external view {
        (uint256 gain, uint256 loss) = slotNetChange(token, balanceSlot);
        if (gain < amount) revert SlotMinReceivedNotMet(token, balanceSlot, amount, gain, loss);
    }

    function maxSpentAtSlot(address token, bytes32 balanceSlot, uint256 amount) external view {
        (uint256 gain, uint256 loss) = slotNetChange(token, balanceSlot);
        if (loss > amount) revert SlotMaxSpentExceeded(token, balanceSlot, amount, gain, loss);
    }

    function balanceUnchangedAtSlot(address token, bytes32 balanceSlot) external view {
        (uint256 gain, uint256 loss) = slotNetChange(token, balanceSlot);
        if (gain != 0 || loss != 0) revert SlotBalanceChanged(token, balanceSlot, gain, loss);
    }

    function slotNetChange(address token, bytes32 balanceSlot) public view returns (uint256 gain, uint256 loss) {
        // The slot only means "balance" under the code that wrote it.
        if (codeChanged(token)) revert TokenCodeChanged(token);
        (bool upgraded,,) = storageChange(token, EIP1967_IMPLEMENTATION_SLOT);
        if (upgraded) revert TokenImplementationChanged(token, EIP1967_IMPLEMENTATION_SLOT);
        (upgraded,,) = storageChange(token, EIP1967_BEACON_SLOT);
        if (upgraded) revert TokenImplementationChanged(token, EIP1967_BEACON_SLOT);

        (, bytes32 beforeValue, bytes32 afterValue) = storageChange(token, balanceSlot);
        if (afterValue >= beforeValue) return (uint256(afterValue) - uint256(beforeValue), 0);
        return (0, uint256(beforeValue) - uint256(afterValue));
    }

    /// @dev `(address indexed a, address indexed b, uint256 value)`; `ok` is false for any other shape.
    function _decode(Event memory e) private pure returns (address a, address b, uint256 value, bool ok) {
        if (e.topics.length != 3 || e.data.length != 32) return (a, b, value, false);
        if (uint256(e.topics[1]) > type(uint160).max || uint256(e.topics[2]) > type(uint160).max) {
            return (a, b, value, false);
        }
        return (toAddress(uint256(e.topics[1])), toAddress(uint256(e.topics[2])), abi.decode(e.data, (uint256)), true);
    }

    function _contains(address[] calldata list, address item) private pure returns (bool) {
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == item) return true;
        }
        return false;
    }

    function supportsInterface(bytes4 interfaceId) public view override(Assertion, IAssertion) returns (bool) {
        return interfaceId == type(IERC20Assertion).interfaceId || super.supportsInterface(interfaceId);
    }
}
