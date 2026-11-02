// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {NativeETHAssertion} from "../contracts/assertions/NativeETHAssertion.sol";
import {INativeETHAssertion} from "../contracts/assertions/interfaces/INativeETHAssertion.sol";
import {MockTxTraceReader} from "./mocks/MockTxTraceReader.sol";
import {TraceTest} from "./utils/TraceTest.sol";
import {TEST_READER} from "./utils/TestReader.sol";

contract NativeETHAssertionTest is TraceTest {
    NativeETHAssertion internal eth;

    address internal constant USER = address(0xA11CE);
    address internal constant OTHER = address(0xB0B);
    address internal constant PAYMASTER = address(0x9A7);

    function setUp() public override {
        super.setUp();
        eth = new NativeETHAssertion(TEST_READER);
        trace.setGas(PAYMASTER, 0); // default: someone else pays, nothing pre-charged
    }

    function test_received() public {
        trace.setBalanceChange(USER, 1 ether, 3 ether);
        eth.minReceived(USER, 2 ether);
        eth.maxSpent(USER, 0);
        vm.expectRevert(
            abi.encodeWithSelector(INativeETHAssertion.MinReceivedNotMet.selector, USER, 2 ether + 1, 2 ether, 0)
        );
        eth.minReceived(USER, 2 ether + 1);
        vm.expectRevert(abi.encodeWithSelector(INativeETHAssertion.BalanceChanged.selector, USER, 2 ether, 0));
        eth.balanceUnchanged(USER);
    }

    function test_spent() public {
        trace.setBalanceChange(USER, 5 ether, 4 ether);
        eth.maxSpent(USER, 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(INativeETHAssertion.MaxSpentExceeded.selector, USER, 1 ether - 1, 0, 1 ether)
        );
        eth.maxSpent(USER, 1 ether - 1);
        vm.expectRevert(abi.encodeWithSelector(INativeETHAssertion.MinReceivedNotMet.selector, USER, 1, 0, 1 ether));
        eth.minReceived(USER, 1);
        eth.minReceived(USER, 0); // "receive at least 0" does not forbid spending; combine with maxSpent
    }

    function test_noChange() public view {
        eth.balanceUnchanged(USER);
        eth.maxSpent(USER, 0);
        eth.minReceived(USER, 0);
        (uint256 gain, uint256 loss) = eth.netChange(USER);
        assertEq(gain, 0);
        assertEq(loss, 0);
    }

    /// @dev Other accounts' entries around the protected one do not matter: absent means unchanged.
    function test_accountMissingFromDiff() public {
        trace.setBalanceChange(address(0x1), 1, 2);
        trace.setBalanceChange(address(uint160(USER) + 1), 9, 3);
        eth.balanceUnchanged(USER);
    }

    function test_multipleAccountsIndependently() public {
        trace.setBalanceChange(USER, 10 ether, 7 ether);
        trace.setBalanceChange(OTHER, 0, 3 ether);
        eth.maxSpent(USER, 3 ether);
        eth.minReceived(OTHER, 3 ether);
        vm.expectRevert();
        eth.maxSpent(USER, 2 ether);
        eth.maxSpent(OTHER, 0);
    }

    /// @dev The user pays gas: 0.02 ETH pre-charge plus 1 ETH sent. Only the 1 ETH counts.
    function test_gasPayerIsProtectedAccount() public {
        trace.setGas(USER, 0.02 ether);
        trace.setBalanceChange(USER, 10 ether, 10 ether - 1 ether - 0.02 ether);
        eth.maxSpent(USER, 1 ether);
        vm.expectRevert(
            abi.encodeWithSelector(INativeETHAssertion.MaxSpentExceeded.selector, USER, 0.99 ether, 0, 1 ether)
        );
        eth.maxSpent(USER, 0.99 ether);
    }

    /// @dev Gas payer pays but moves no value: unchanged, although its raw balance dropped.
    function test_gasPayerOnlyPaysGas() public {
        trace.setGas(USER, 0.02 ether);
        trace.setBalanceChange(USER, 10 ether, 10 ether - 0.02 ether);
        eth.balanceUnchanged(USER);
    }

    /// @dev A paymaster pays: the user's figures are untouched by the pre-charge.
    function test_gasPayerDifferentFromProtectedAccount() public {
        trace.setGas(PAYMASTER, 0.03 ether);
        trace.setBalanceChange(PAYMASTER, 1 ether, 0.97 ether);
        trace.setBalanceChange(USER, 2 ether, 1 ether);
        eth.maxSpent(USER, 1 ether);
        vm.expectRevert();
        eth.maxSpent(USER, 0.99 ether);
        eth.balanceUnchanged(PAYMASTER);
    }

    /// @dev Incoming ETH exactly offsets the pre-charge: no entry, but the payer did receive the pre-charge amount.
    function test_gasPayerMissingFromDiff() public {
        trace.setGas(USER, 0.02 ether);
        eth.minReceived(USER, 0.02 ether);
        vm.expectRevert();
        eth.balanceUnchanged(USER);
    }

    function test_largeValues() public {
        trace.setBalanceChange(USER, 0, type(uint256).max);
        eth.minReceived(USER, type(uint256).max);
        trace.setBalanceChange(OTHER, type(uint256).max, 0);
        eth.maxSpent(OTHER, type(uint256).max);
        vm.expectRevert();
        eth.maxSpent(OTHER, type(uint256).max - 1);
    }

    /// @dev An after-balance plus pre-charge above 2^256 - 1 cannot come from a real chain; it reverts.
    function test_preChargeOverflowFailsClosed() public {
        trace.setGas(USER, 2);
        trace.setBalanceChange(USER, 0, type(uint256).max);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        eth.minReceived(USER, 0);
    }

    function test_unavailableTraceFailsClosed() public {
        trace.setAssertFrameActive(false);
        vm.expectRevert(
            abi.encodeWithSelector(MockTxTraceReader.ExceptionalHalt.selector, MockTxTraceReader.Halt.NotInAssertFrame)
        );
        eth.minReceived(USER, 0);
    }

    function testFuzz_netChange(uint128 beforeBalance, uint128 afterBalance, uint64 preCharge, bool userPays) public {
        vm.assume(beforeBalance != afterBalance);
        trace.setBalanceChange(USER, beforeBalance, afterBalance);
        trace.setGas(userPays ? USER : PAYMASTER, preCharge);
        int256 net = int256(uint256(afterBalance)) - int256(uint256(beforeBalance))
            + (userPays ? int256(uint256(preCharge)) : int256(0));
        (uint256 gain, uint256 loss) = eth.netChange(USER);
        assertEq(int256(gain) - int256(loss), net);
        assertTrue(gain == 0 || loss == 0);
        eth.minReceived(USER, gain);
        eth.maxSpent(USER, loss);
    }
}
