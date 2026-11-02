// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAssertion} from "./IAssertion.sol";

/// @title INativeETHAssertion
/// @notice ETH checks on the net balance change over the whole transaction, gas excluded. Protocol-enforced.
interface INativeETHAssertion is IAssertion {
    error MinReceivedNotMet(address account, uint256 minReceived, uint256 gain, uint256 loss);
    error MaxSpentExceeded(address account, uint256 maxSpent, uint256 gain, uint256 loss);
    error BalanceChanged(address account, uint256 gain, uint256 loss);

    function minReceived(address account, uint256 amount) external view;

    function maxSpent(address account, uint256 amount) external view;

    function balanceUnchanged(address account) external view;

    /// @notice Net change, gas excluded. At most one of `gain` and `loss` is non-zero.
    function netChange(address account) external view returns (uint256 gain, uint256 loss);
}
