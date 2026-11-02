// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAssertion} from "./IAssertion.sol";

/// @title IERC20Assertion
/// @notice ERC-20 checks on the net change over the whole transaction, from one of two sources:
///         - Storage (`*AtSlot`): the change of the holder's balance slot in the token. Exact, if the wallet passes
///           the right slot. Reverts if the token's code or EIP-1967 implementation/beacon changed.
///         - Events (the rest): `Transfer` / `Approval` events from the token. Trusts the token to emit one standard
///           event per change; rebasing, fee-on-transfer and silent changes fool it.
interface IERC20Assertion is IAssertion {
    struct Transfer {
        uint256 eventIndex;
        address from;
        address to;
        uint256 value;
    }

    struct Approval {
        uint256 eventIndex;
        address owner;
        address spender;
        uint256 value;
    }

    error MinReceivedNotMet(address token, address account, uint256 minReceived, uint256 gain, uint256 loss);
    error MaxSpentExceeded(address token, address account, uint256 maxSpent, uint256 gain, uint256 loss);
    error BalanceChanged(address token, address account, uint256 gain, uint256 loss);
    error UnexpectedApproval(address token, address owner, address spender, uint256 value, uint256 eventIndex);
    error MalformedTransferEvent(uint256 eventIndex);
    error MalformedApprovalEvent(uint256 eventIndex);

    error SlotMinReceivedNotMet(address token, bytes32 balanceSlot, uint256 minReceived, uint256 gain, uint256 loss);
    error SlotMaxSpentExceeded(address token, bytes32 balanceSlot, uint256 maxSpent, uint256 gain, uint256 loss);
    error SlotBalanceChanged(address token, bytes32 balanceSlot, uint256 gain, uint256 loss);
    error TokenCodeChanged(address token);
    error TokenImplementationChanged(address token, bytes32 slot);

    function minReceived(address token, address account, uint256 amount) external view;

    function maxSpent(address token, address account, uint256 amount) external view;

    function balanceUnchanged(address token, address account) external view;

    /// @notice No non-zero `Approval` by `owner` to a spender outside `allowedSpenders`, even if revoked later.
    function noUnexpectedApprovals(address token, address owner, address[] calldata allowedSpenders) external view;

    function minReceivedAtSlot(address token, bytes32 balanceSlot, uint256 amount) external view;

    function maxSpentAtSlot(address token, bytes32 balanceSlot, uint256 amount) external view;

    function balanceUnchangedAtSlot(address token, bytes32 balanceSlot) external view;

    /// @notice Every `Transfer` emitted by `token`, in emission order.
    function transfers(address token) external view returns (Transfer[] memory);

    /// @notice Every `Approval` emitted by `token`, in emission order.
    function approvals(address token) external view returns (Approval[] memory);

    /// @notice Event-derived net change. At most one of `gain` and `loss` is non-zero.
    function eventNetChange(address token, address account) external view returns (uint256 gain, uint256 loss);

    /// @notice Storage-derived net change. At most one of `gain` and `loss` is non-zero.
    function slotNetChange(address token, bytes32 balanceSlot) external view returns (uint256 gain, uint256 loss);
}
