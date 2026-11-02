// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20Assertion} from "../contracts/assertions/ERC20Assertion.sol";
import {IERC20Assertion} from "../contracts/assertions/interfaces/IERC20Assertion.sol";
import {MockTxTraceReader} from "./mocks/MockTxTraceReader.sol";
import {TraceTest} from "./utils/TraceTest.sol";
import {TEST_READER} from "./utils/TestReader.sol";

/// @notice ERC20Assertion against synthetic traces. Real token contracts and real storage diffs are exercised in
///         test/integration/FrameTransactionEmulation.t.sol.
contract ERC20AssertionTest is TraceTest {
    ERC20Assertion internal erc20;

    address internal constant TOKEN = address(0x05DC);
    address internal constant OTHER_TOKEN = address(0xDA1);
    address internal constant USER = address(0xA11CE);
    address internal constant POOL = address(0x9001);
    address internal constant ROUTER = address(0x2007E2);
    address internal constant OTHER = address(0x07E2);
    bytes32 internal constant BALANCE_SLOT = keccak256("user balance slot");
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant BEACON_SLOT = 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50;

    function setUp() public override {
        super.setUp();
        erc20 = new ERC20Assertion(TEST_READER);
    }

    function _net(address account) internal view returns (int256) {
        (uint256 gain, uint256 loss) = erc20.eventNetChange(TOKEN, account);
        return int256(gain) - int256(loss);
    }

    function _allowed(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    // ---------------------------------------------------------------------
    // Event-derived balance constraints
    // ---------------------------------------------------------------------

    function test_transfersAndApprovalsCollected() public {
        _erc20Transfer(TOKEN, USER, POOL, 100);
        _noise(OTHER, 1);
        _erc20Approval(TOKEN, USER, ROUTER, 50);
        _erc20Transfer(OTHER_TOKEN, USER, POOL, 7);
        _erc20Transfer(TOKEN, POOL, USER, 30);

        IERC20Assertion.Transfer[] memory t = erc20.transfers(TOKEN);
        assertEq(t.length, 2);
        assertEq(t[0].eventIndex, 0);
        assertEq(t[0].from, USER);
        assertEq(t[0].to, POOL);
        assertEq(t[0].value, 100);
        assertEq(t[1].eventIndex, 4);
        assertEq(t[1].value, 30);

        IERC20Assertion.Approval[] memory a = erc20.approvals(TOKEN);
        assertEq(a.length, 1);
        assertEq(a[0].owner, USER);
        assertEq(a[0].spender, ROUTER);
        assertEq(a[0].value, 50);
        assertEq(erc20.transfers(OTHER).length, 0);
    }

    function test_transfersRejectsMalformedEvent() public {
        trace.pushEvent(TOKEN, _topics(TRANSFER_TOPIC, _word(USER)), abi.encode(uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(IERC20Assertion.MalformedTransferEvent.selector, 0));
        erc20.transfers(TOKEN);
    }

    function test_standardTransfer() public {
        _erc20Transfer(TOKEN, POOL, USER, 100e6);
        erc20.minReceived(TOKEN, USER, 100e6);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Assertion.MinReceivedNotMet.selector, TOKEN, USER, 100e6 + 1, 100e6, 0)
        );
        erc20.minReceived(TOKEN, USER, 100e6 + 1);
        erc20.maxSpent(TOKEN, POOL, 100e6);
        vm.expectRevert(abi.encodeWithSelector(IERC20Assertion.MaxSpentExceeded.selector, TOKEN, POOL, 99e6, 0, 100e6));
        erc20.maxSpent(TOKEN, POOL, 99e6);
    }

    /// @dev transferFrom emits the same Transfer(from, to, value); the spender is not credited or debited.
    function test_transferFrom() public {
        _erc20Approval(TOKEN, USER, ROUTER, 100e6);
        _erc20Transfer(TOKEN, USER, POOL, 60e6); // router pulls from user to pool
        erc20.maxSpent(TOKEN, USER, 60e6);
        erc20.balanceUnchanged(TOKEN, ROUTER);
    }

    function test_mintAndBurn() public {
        _erc20Transfer(TOKEN, address(0), USER, 70);
        _erc20Transfer(TOKEN, USER, address(0), 20);
        assertEq(_net(USER), 50);
    }

    function test_multipleTransfers() public {
        _erc20Transfer(TOKEN, USER, POOL, 100e6);
        _erc20Transfer(TOKEN, POOL, USER, 30e6);
        _erc20Transfer(TOKEN, OTHER, USER, 5e6);
        _erc20Transfer(TOKEN, USER, OTHER, 1e6);
        assertEq(_net(USER), -66e6);
        erc20.maxSpent(TOKEN, USER, 66e6);
    }

    function test_selfTransferIsNeutral() public {
        _erc20Transfer(TOKEN, USER, USER, 1e30);
        erc20.balanceUnchanged(TOKEN, USER);
    }

    function test_unrelatedTokensAccountsAndEventsIgnored() public {
        _erc20Transfer(OTHER_TOKEN, USER, POOL, 1000e18);
        _erc20Transfer(TOKEN, POOL, OTHER, 1000e6);
        _erc20Approval(TOKEN, USER, POOL, 5);
        _noise(TOKEN, 1);
        trace.pushEvent(TOKEN, new bytes32[](0), abi.encode(1)); // anonymous event
        erc20.balanceUnchanged(TOKEN, USER);
    }

    /// @dev Another contract cannot fake events for `TOKEN`: the emitter is set by the protocol.
    function test_fakeEventsFromOtherEmitterIgnored() public {
        _erc20Transfer(address(0xBAD), POOL, USER, 1_000_000e6);
        _erc20Transfer(TOKEN, USER, POOL, 100e6);
        vm.expectRevert(abi.encodeWithSelector(IERC20Assertion.MaxSpentExceeded.selector, TOKEN, USER, 0, 0, 100e6));
        erc20.maxSpent(TOKEN, USER, 0);
    }

    function test_malformedTransfersRevert() public {
        bytes32 dirty = bytes32((uint256(1) << 160) | uint160(USER));
        bytes32[][4] memory topics = [
            _topics(TRANSFER_TOPIC, _word(USER)), // 2 topics
            _topics(TRANSFER_TOPIC, _word(USER), _word(POOL), bytes32(uint256(1))), // ERC-721 shape
            _topics(TRANSFER_TOPIC, _word(USER), _word(POOL)), // wrong data length (below)
            _topics(TRANSFER_TOPIC, dirty, _word(POOL)) // non-canonical address
        ];
        bytes[4] memory data = [abi.encode(1), bytes(""), abi.encode(1, 2), abi.encode(1)];
        for (uint256 i; i < 4; ++i) {
            trace.reset();
            _noise(OTHER, i);
            trace.pushEvent(TOKEN, topics[i], data[i]);
            vm.expectRevert(abi.encodeWithSelector(IERC20Assertion.MalformedTransferEvent.selector, 1));
            erc20.maxSpent(TOKEN, OTHER, type(uint256).max); // even for an uninvolved account
        }
    }

    function test_largeAmountsAndOverflow() public {
        _erc20Transfer(TOKEN, POOL, USER, type(uint256).max);
        erc20.minReceived(TOKEN, USER, type(uint256).max);
        _erc20Transfer(TOKEN, OTHER, USER, 1);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        erc20.minReceived(TOKEN, USER, 0);
    }

    function testFuzz_eventNetChange(uint256 seed, uint8 n) public {
        n = uint8(bound(n, 0, 40));
        address[3] memory accounts = [USER, POOL, OTHER];
        int256[3] memory expected;
        for (uint256 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            (address from, address to, uint256 value) = (accounts[r % 3], accounts[(r >> 8) % 3], (r >> 16) % 1e30);
            if ((r >> 128) % 4 == 0) {
                _erc20Transfer(OTHER_TOKEN, from, to, value);
                continue;
            }
            if ((r >> 136) % 5 == 0) _noise(TOKEN, i);
            _erc20Transfer(TOKEN, from, to, value);
            for (uint256 k; k < 3; ++k) {
                if (accounts[k] == to) expected[k] += int256(value);
                if (accounts[k] == from) expected[k] -= int256(value);
            }
        }
        for (uint256 k; k < 3; ++k) {
            assertEq(_net(accounts[k]), expected[k]);
        }
    }

    // ---------------------------------------------------------------------
    // Approvals
    // ---------------------------------------------------------------------

    function test_approvalIncreaseToAllowedSpender() public {
        _erc20Approval(TOKEN, USER, ROUTER, 100e6);
        _erc20Approval(TOKEN, USER, ROUTER, 500e6);
        erc20.noUnexpectedApprovals(TOKEN, USER, _allowed(ROUTER));
    }

    function test_approvalRevocationsAlwaysPass() public {
        _erc20Approval(TOKEN, USER, OTHER, 0);
        erc20.noUnexpectedApprovals(TOKEN, USER, new address[](0));
    }

    function test_unexpectedSpenderReverts() public {
        _erc20Approval(TOKEN, USER, ROUTER, 100e6);
        _erc20Approval(TOKEN, USER, OTHER, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Assertion.UnexpectedApproval.selector, TOKEN, USER, OTHER, type(uint256).max, 1
            )
        );
        erc20.noUnexpectedApprovals(TOKEN, USER, _allowed(ROUTER));
    }

    /// @dev Strict by design: an approval later revoked in the same transaction still fails.
    function test_unexpectedApprovalThenRevocationStillReverts() public {
        _erc20Approval(TOKEN, USER, OTHER, 1);
        _erc20Approval(TOKEN, USER, OTHER, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Assertion.UnexpectedApproval.selector, TOKEN, USER, OTHER, 1, 0));
        erc20.noUnexpectedApprovals(TOKEN, USER, new address[](0));
    }

    function test_approvalsForOtherOwnersAndTokensIgnored() public {
        _erc20Approval(TOKEN, OTHER, ROUTER, 1);
        _erc20Approval(OTHER_TOKEN, USER, OTHER, 1);
        _erc20Approval(address(0xBAD), USER, OTHER, 1);
        erc20.noUnexpectedApprovals(TOKEN, USER, new address[](0));
    }

    function test_malformedApprovalReverts() public {
        trace.pushEvent(TOKEN, _topics(APPROVAL_TOPIC, _word(USER)), abi.encode(_word(OTHER), 1));
        vm.expectRevert(abi.encodeWithSelector(IERC20Assertion.MalformedApprovalEvent.selector, 0));
        erc20.noUnexpectedApprovals(TOKEN, USER, new address[](0));
    }

    // ---------------------------------------------------------------------
    // Storage-derived balance constraints
    // ---------------------------------------------------------------------

    function test_slotReceivedAndSpent() public {
        trace.setSlotChange(TOKEN, BALANCE_SLOT, bytes32(uint256(100)), bytes32(uint256(250)));
        erc20.minReceivedAtSlot(TOKEN, BALANCE_SLOT, 150);
        erc20.maxSpentAtSlot(TOKEN, BALANCE_SLOT, 0);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Assertion.SlotMinReceivedNotMet.selector, TOKEN, BALANCE_SLOT, 151, 150, 0)
        );
        erc20.minReceivedAtSlot(TOKEN, BALANCE_SLOT, 151);

        trace.setSlotChange(TOKEN, BALANCE_SLOT, bytes32(uint256(250)), bytes32(uint256(100)));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Assertion.SlotMaxSpentExceeded.selector, TOKEN, BALANCE_SLOT, 149, 0, 150)
        );
        erc20.maxSpentAtSlot(TOKEN, BALANCE_SLOT, 149);
    }

    /// @dev An unchanged slot is absent from the table; other slots and other contracts do not interfere.
    function test_slotUnchanged() public {
        trace.setSlotChange(TOKEN, bytes32(uint256(BALANCE_SLOT) + 1), bytes32(0), bytes32(uint256(1)));
        trace.setSlotChange(OTHER_TOKEN, BALANCE_SLOT, bytes32(0), bytes32(uint256(1)));
        erc20.balanceUnchangedAtSlot(TOKEN, BALANCE_SLOT);
    }

    /// @dev Storage is the source of truth: a misleading Transfer event does not change the slot-based figure.
    function test_slotIgnoresMisleadingEvents() public {
        _erc20Transfer(TOKEN, POOL, USER, 1_000_000e6);
        erc20.minReceived(TOKEN, USER, 1_000_000e6); // event-derived: fooled
        vm.expectRevert();
        erc20.minReceivedAtSlot(TOKEN, BALANCE_SLOT, 1); // storage-derived: nothing changed
    }

    function test_slotRejectsTokenCodeChange() public {
        trace.setSlotChange(TOKEN, BALANCE_SLOT, bytes32(0), bytes32(uint256(1)));
        trace.pushCodeChange(TOKEN, keccak256("v1"), keccak256("v2"));
        vm.expectRevert(abi.encodeWithSelector(IERC20Assertion.TokenCodeChanged.selector, TOKEN));
        erc20.minReceivedAtSlot(TOKEN, BALANCE_SLOT, 0);
    }

    function test_slotRejectsProxyUpgrade() public {
        trace.setSlotChange(TOKEN, IMPLEMENTATION_SLOT, _word(address(1)), _word(address(2)));
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Assertion.TokenImplementationChanged.selector, TOKEN, IMPLEMENTATION_SLOT)
        );
        erc20.balanceUnchangedAtSlot(TOKEN, BALANCE_SLOT);

        trace.reset();
        trace.setSlotChange(TOKEN, BEACON_SLOT, _word(address(1)), _word(address(2)));
        vm.expectRevert(abi.encodeWithSelector(IERC20Assertion.TokenImplementationChanged.selector, TOKEN, BEACON_SLOT));
        erc20.balanceUnchangedAtSlot(TOKEN, BALANCE_SLOT);
    }

    function test_slotLargeValues() public {
        trace.setSlotChange(TOKEN, BALANCE_SLOT, bytes32(type(uint256).max), bytes32(0));
        erc20.maxSpentAtSlot(TOKEN, BALANCE_SLOT, type(uint256).max);
        vm.expectRevert();
        erc20.maxSpentAtSlot(TOKEN, BALANCE_SLOT, type(uint256).max - 1);
    }

    function testFuzz_slotNetChange(uint256 beforeValue, uint256 afterValue) public {
        vm.assume(beforeValue != afterValue);
        trace.setSlotChange(TOKEN, BALANCE_SLOT, bytes32(beforeValue), bytes32(afterValue));
        (uint256 gain, uint256 loss) = erc20.slotNetChange(TOKEN, BALANCE_SLOT);
        if (afterValue > beforeValue) {
            assertEq(gain, afterValue - beforeValue);
            assertEq(loss, 0);
        } else {
            assertEq(gain, 0);
            assertEq(loss, beforeValue - afterValue);
        }
        erc20.minReceivedAtSlot(TOKEN, BALANCE_SLOT, gain);
        erc20.maxSpentAtSlot(TOKEN, BALANCE_SLOT, loss);
    }

    // ---------------------------------------------------------------------
    // Failing safely
    // ---------------------------------------------------------------------

    function test_unavailableTraceFailsClosed() public {
        trace.setAssertFrameActive(false);
        bytes memory halt =
            abi.encodeWithSelector(MockTxTraceReader.ExceptionalHalt.selector, MockTxTraceReader.Halt.NotInAssertFrame);
        vm.expectRevert(halt);
        erc20.maxSpent(TOKEN, USER, type(uint256).max);
        vm.expectRevert(halt);
        erc20.maxSpentAtSlot(TOKEN, BALANCE_SLOT, type(uint256).max);
        vm.expectRevert(halt);
        erc20.noUnexpectedApprovals(TOKEN, USER, new address[](0));
    }
}
