// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Assertion} from "./Assertion.sol";
import {IAssertion} from "./interfaces/IAssertion.sol";
import {INativeETHAssertion} from "./interfaces/INativeETHAssertion.sol";
import {ITxTraceReader} from "../shared/ITxTraceReader.sol";
import {TxTrace} from "../shared/TxTrace.sol";

/// @title NativeETHAssertion
/// @notice ETH limits from the balance-change table. Gas is excluded by adding the gas pre-charge back for the payer.
contract NativeETHAssertion is Assertion, TxTrace, INativeETHAssertion {
    constructor(ITxTraceReader reader) TxTrace(reader) {}

    function minReceived(address account, uint256 amount) external view {
        (uint256 gain, uint256 loss) = netChange(account);
        if (gain < amount) revert MinReceivedNotMet(account, amount, gain, loss);
    }

    function maxSpent(address account, uint256 amount) external view {
        (uint256 gain, uint256 loss) = netChange(account);
        if (loss > amount) revert MaxSpentExceeded(account, amount, gain, loss);
    }

    function balanceUnchanged(address account) external view {
        (uint256 gain, uint256 loss) = netChange(account);
        if (gain != 0 || loss != 0) revert BalanceChanged(account, gain, loss);
    }

    function netChange(address account) public view returns (uint256 gain, uint256 loss) {
        (, uint256 beforeBalance, uint256 afterBalance) = balanceChange(account);
        (address payer, uint256 preCharge) = gasPayment();
        if (payer == account) afterBalance += preCharge;
        if (afterBalance >= beforeBalance) return (afterBalance - beforeBalance, 0);
        return (0, beforeBalance - afterBalance);
    }

    function supportsInterface(bytes4 interfaceId) public view override(Assertion, IAssertion) returns (bool) {
        return interfaceId == type(INativeETHAssertion).interfaceId || super.supportsInterface(interfaceId);
    }
}
