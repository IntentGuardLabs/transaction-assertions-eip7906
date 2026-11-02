// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TxTrace} from "../contracts/shared/TxTrace.sol";
import {ITxTraceReader} from "../contracts/shared/ITxTraceReader.sol";
import {MockTxTraceReader} from "./mocks/MockTxTraceReader.sol";
import {TraceTest} from "./utils/TraceTest.sol";
import {TEST_READER} from "./utils/TestReader.sol";

/// @notice Exposes TxTrace's internal functions.
contract TxTraceHarness is TxTrace {
    constructor(ITxTraceReader reader) TxTrace(reader) {}

    function balanceChange_(address a) external view returns (bool, uint256, uint256) {
        return balanceChange(a);
    }

    function gasPayment_() external view returns (address, uint256) {
        return gasPayment();
    }

    function storageChange_(address a, bytes32 slot) external view returns (bool, bytes32, bytes32) {
        return storageChange(a, slot);
    }

    function storageChanges_(address a) external view returns (StorageChange[] memory) {
        return storageChanges(a);
    }

    function codeChanged_(address a) external view returns (bool) {
        return codeChanged(a);
    }

    function events_(address emitter) external view returns (Event[] memory) {
        return events(emitter);
    }

    function events_(address emitter, bytes32 topic0) external view returns (Event[] memory) {
        return events(emitter, topic0);
    }
}

contract TxTraceTest is TraceTest {
    TxTraceHarness internal h;

    address internal constant EMITTER = address(0x7070);
    bytes32 internal constant TOPIC = keccak256("Something(uint256)");

    function setUp() public override {
        super.setUp();
        h = new TxTraceHarness(TEST_READER);
    }

    function _halt(MockTxTraceReader.Halt reason) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(MockTxTraceReader.ExceptionalHalt.selector, reason);
    }

    /// @dev The mock reproduces EIP-7906's exceptional halts.
    function test_mockHalts() public {
        trace.pushEvent(address(1), _topics(bytes32(0)), hex"0102");
        vm.expectRevert(_halt(MockTxTraceReader.Halt.InvalidParam));
        trace.txtrace(0x1B, 0);
        vm.expectRevert(_halt(MockTxTraceReader.Halt.NonZeroIn2));
        trace.txtrace(0x11, 1);
        vm.expectRevert(_halt(MockTxTraceReader.Halt.IndexOutOfRange));
        trace.txtrace(0x12, 1);
        vm.expectRevert(_halt(MockTxTraceReader.Halt.TopicOutOfRange));
        trace.txtrace(0x15, 0);
        vm.expectRevert(_halt(MockTxTraceReader.Halt.DataOutOfRange));
        trace.eventDataCopy(0, 3, 0);
        vm.expectRevert(_halt(MockTxTraceReader.Halt.DataOutOfRange));
        trace.eventDataCopy(0, 1, type(uint256).max);
        trace.setAssertFrameActive(false);
        vm.expectRevert(_halt(MockTxTraceReader.Halt.NotInAssertFrame));
        trace.txtrace(0x11, 0);
    }

    function test_readerMustHaveCode() public {
        vm.expectRevert(abi.encodeWithSelector(TxTrace.ReaderHasNoCode.selector, address(0xdead)));
        new TxTraceHarness(ITxTraceReader(address(0xdead)));
    }

    // Balances and gas

    function test_balanceChangeAndGas() public {
        trace.setGas(address(0xA), 30);
        trace.setBalanceChange(address(0xA), 100, 60);
        (bool changed, uint256 b, uint256 a) = h.balanceChange_(address(0xA));
        assertTrue(changed);
        assertEq(b, 100);
        assertEq(a, 60);
        (changed,,) = h.balanceChange_(address(0xB));
        assertFalse(changed);
        (address payer, uint256 preCharge) = h.gasPayment_();
        assertEq(payer, address(0xA));
        assertEq(preCharge, 30);
    }

    function testFuzz_balanceChange(uint8 n, uint256 seed, uint8 pick) public {
        n = uint8(bound(n, 1, 50));
        address[] memory accounts = new address[](n);
        for (uint256 i; i < n; ++i) {
            accounts[i] = address(uint160(uint256(keccak256(abi.encode(seed, i)))));
            trace.setBalanceChange(accounts[i], i + 1, 0);
        }
        uint256 target = pick % n;
        (bool changed, uint256 b,) = h.balanceChange_(accounts[target]);
        assertTrue(changed);
        assertEq(b, target + 1);
        (changed,,) = h.balanceChange_(address(uint160(uint256(keccak256(abi.encode(seed, "absent"))))));
        assertFalse(changed);
    }

    // Storage and code

    /// @dev Several slots per address: the search orders by (address, slot).
    function testFuzz_storageChange(uint8 n, uint256 seed, uint8 pick) public {
        n = uint8(bound(n, 1, 40));
        address[3] memory accounts = [address(0x100), address(0x200), address(0x300)];
        bytes32[] memory slots = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            slots[i] = keccak256(abi.encode(seed, i));
            trace.setSlotChange(accounts[i % 3], slots[i], bytes32(i + 1), bytes32(0));
        }
        uint256 target = pick % n;
        (bool changed, bytes32 b, bytes32 a) = h.storageChange_(accounts[target % 3], slots[target]);
        assertTrue(changed);
        assertEq(b, bytes32(target + 1));
        assertEq(a, bytes32(0));
        (changed,,) = h.storageChange_(accounts[(target + 1) % 3], slots[target]);
        assertFalse(changed);
    }

    function test_storageChanges() public {
        trace.setSlotChange(address(0x3), bytes32(uint256(1)), bytes32(0), bytes32(uint256(1)));
        trace.setSlotChange(address(0x2), bytes32(uint256(9)), bytes32(uint256(4)), bytes32(uint256(5)));
        trace.setSlotChange(address(0x1), bytes32(uint256(7)), bytes32(0), bytes32(uint256(1)));
        trace.setSlotChange(address(0x2), bytes32(uint256(2)), bytes32(uint256(1)), bytes32(0));

        TxTrace.StorageChange[] memory changes = h.storageChanges_(address(0x2));
        assertEq(changes.length, 2);
        assertEq(changes[0].slot, bytes32(uint256(2)));
        assertEq(changes[0].beforeValue, bytes32(uint256(1)));
        assertEq(changes[1].slot, bytes32(uint256(9)));
        assertEq(changes[1].afterValue, bytes32(uint256(5)));
        assertEq(h.storageChanges_(address(0x1)).length, 1);
        assertEq(h.storageChanges_(address(0x3)).length, 1);
        assertEq(h.storageChanges_(address(0x4)).length, 0);
    }

    function test_codeChanged() public {
        trace.pushCodeChange(address(0x3), keccak256(""), keccak256("code"));
        assertTrue(h.codeChanged_(address(0x3)));
        assertFalse(h.codeChanged_(address(0x4)));
    }

    // Events

    function test_events() public {
        trace.pushEvent(address(0xBAD), _topics(TOPIC), ""); // other emitter
        trace.pushEvent(EMITTER, new bytes32[](0), hex"01"); // anonymous
        trace.pushEvent(EMITTER, _topics(keccak256("Other()")), ""); // other topic0
        trace.pushEvent(EMITTER, _topics(TOPIC, bytes32(uint256(7))), hex"aabb");
        trace.pushEvent(EMITTER, _topics(TOPIC), "");

        TxTrace.Event[] memory all = h.events_(EMITTER);
        assertEq(all.length, 4);
        assertEq(all[0].index, 1);
        assertEq(all[0].topics.length, 0);
        assertEq(all[0].data, hex"01");

        TxTrace.Event[] memory matching = h.events_(EMITTER, TOPIC);
        assertEq(matching.length, 2);
        assertEq(matching[0].index, 3);
        assertEq(matching[0].topics[1], bytes32(uint256(7)));
        assertEq(matching[0].data, hex"aabb");
        assertEq(matching[1].index, 4);
        assertEq(h.events_(address(0x6)).length, 0);
    }

    function testFuzz_eventsFindsEveryMatch(uint8 n, uint256 seed) public {
        uint256 expected;
        for (uint256 i; i < n; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            bool isMatch = r % 3 == 0;
            trace.pushEvent(isMatch ? EMITTER : address(uint160(r)), _topics(TOPIC), abi.encode(i));
            if (isMatch) expected++;
        }
        TxTrace.Event[] memory all = h.events_(EMITTER, TOPIC);
        assertEq(all.length, expected);
        for (uint256 k; k < all.length; ++k) {
            assertEq(all[k].data, abi.encode(all[k].index));
        }
    }

    // Failing closed

    function test_nonCanonicalAddressRejected() public {
        trace.pushEvent(EMITTER, _topics(TOPIC), "");
        uint256 dirty = (uint256(1) << 160) | uint160(EMITTER);
        trace.setOverride(0x12, 0, dirty);
        vm.expectRevert(abi.encodeWithSelector(TxTrace.NonCanonicalAddress.selector, dirty));
        h.events_(EMITTER);
    }

    /// @dev A count larger than the table halts on the first out-of-range read.
    function test_malformedTraceFailsClosed() public {
        trace.setOverride(0x11, 0, 3);
        vm.expectRevert(_halt(MockTxTraceReader.Halt.IndexOutOfRange));
        h.events_(EMITTER);
        trace.setOverride(0x00, 0, 1);
        vm.expectRevert(_halt(MockTxTraceReader.Halt.IndexOutOfRange));
        h.balanceChange_(address(1));
    }

    function test_outsideAssertFrameFailsClosed() public {
        trace.setAssertFrameActive(false);
        vm.expectRevert(_halt(MockTxTraceReader.Halt.NotInAssertFrame));
        h.events_(EMITTER);
    }

    function test_missingReaderFailsClosed() public {
        vm.etch(address(TEST_READER), "");
        vm.expectRevert();
        h.events_(EMITTER);
    }
}
