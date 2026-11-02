// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ITxTraceReader} from "./ITxTraceReader.sol";

/// @title TxTrace
/// @notice Base contract of the assertions. Reads what the current transaction changed (ETH balances, storage
///         slots, code) and the events it emitted, using the EIP-7906 opcodes TXTRACE (0xb6) and EVENTDATACOPY
///         (0xb7). The client only answers these opcodes inside an ASSERT frame.
/// @dev The reader is fixed at deployment, so a caller cannot supply its own trace. State tables are sorted by
///      address (storage then by slot), so lookups are binary searches. Events are in emission order, so per-emitter
///      queries scan every event. Any failed read reverts, failing the assertion.
abstract contract TxTrace {
    // TXTRACE params. A state table entry is (address, before, after[, key]) at address, address + 1, address + 2.
    uint256 internal constant BALANCES_CHANGED = 0x00;
    uint256 internal constant SLOTS_CHANGED = 0x01;
    uint256 internal constant CODES_CHANGED = 0x02;
    uint256 internal constant BALANCE_ADDRESS = 0x04;
    uint256 internal constant SLOT_ADDRESS = 0x07;
    uint256 internal constant SLOT_KEY = 0x0A;
    uint256 internal constant CODE_ADDRESS = 0x0B;
    uint256 internal constant EVENTS_COUNT = 0x11;
    uint256 internal constant EVENT_ADDRESS = 0x12;
    uint256 internal constant EVENT_TOPIC_COUNT = 0x13;
    uint256 internal constant EVENT_TOPIC0 = 0x14;
    uint256 internal constant EVENT_DATA_LEN = 0x18;
    uint256 internal constant GAS_PRE_CHARGE = 0x19;
    uint256 internal constant GAS_PAYER = 0x1A;

    struct StorageChange {
        bytes32 slot;
        bytes32 beforeValue;
        bytes32 afterValue;
    }

    struct Event {
        uint256 index;
        bytes32[] topics;
        bytes data;
    }

    error ReaderHasNoCode(address reader);
    error NonCanonicalAddress(uint256 word);

    /// @notice The `TxTraceReader` the trace is read from.
    ITxTraceReader public immutable traceReader;

    constructor(ITxTraceReader reader) {
        if (address(reader).code.length == 0) revert ReaderHasNoCode(address(reader));
        traceReader = reader;
    }

    /// @notice ETH balance of `account` at transaction start and now. Both are 0 if it did not change.
    function balanceChange(address account)
        internal
        view
        returns (bool changed, uint256 beforeBalance, uint256 afterBalance)
    {
        return _find(BALANCE_ADDRESS, BALANCES_CHANGED, account);
    }

    /// @notice Gas payer and the amount pre-charged to it (EIP-8141 `max_cost`).
    function gasPayment() internal view returns (address payer, uint256 preCharge) {
        return (toAddress(_read(GAS_PAYER, 0)), _read(GAS_PRE_CHARGE, 0));
    }

    /// @notice Value of `slot` in `account` at transaction start and now. Both are 0 if it did not change.
    function storageChange(address account, bytes32 slot)
        internal
        view
        returns (bool changed, bytes32 beforeValue, bytes32 afterValue)
    {
        uint256 low = 0;
        uint256 high = _read(SLOTS_CHANGED, 0);
        while (low < high) {
            uint256 mid = (low + high) / 2;
            address entry = toAddress(_read(SLOT_ADDRESS, mid));
            uint256 key = entry == account ? _read(SLOT_KEY, mid) : 0;
            if (entry == account && key == uint256(slot)) {
                return (true, bytes32(_read(SLOT_ADDRESS + 1, mid)), bytes32(_read(SLOT_ADDRESS + 2, mid)));
            }
            if (entry < account || (entry == account && key < uint256(slot))) low = mid + 1;
            else high = mid;
        }
    }

    /// @notice Every changed slot of `account`, ordered by slot.
    function storageChanges(address account) internal view returns (StorageChange[] memory result) {
        uint256 count = _read(SLOTS_CHANGED, 0);
        uint256 low = 0;
        uint256 high = count;
        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (toAddress(_read(SLOT_ADDRESS, mid)) < account) low = mid + 1;
            else high = mid;
        }
        uint256 end = low;
        while (end < count && toAddress(_read(SLOT_ADDRESS, end)) == account) end++;
        result = new StorageChange[](end - low);
        for (uint256 i = low; i < end; i++) {
            result[i - low] = StorageChange(
                bytes32(_read(SLOT_KEY, i)), bytes32(_read(SLOT_ADDRESS + 1, i)), bytes32(_read(SLOT_ADDRESS + 2, i))
            );
        }
    }

    /// @notice Whether `account`'s code hash changed (including EIP-7702 delegations).
    function codeChanged(address account) internal view returns (bool changed) {
        (changed,,) = _find(CODE_ADDRESS, CODES_CHANGED, account);
    }

    /// @notice Every event emitted by `emitter`, in emission order.
    function events(address emitter) internal view returns (Event[] memory) {
        return _events(emitter, false, 0);
    }

    /// @notice Every event emitted by `emitter` with first topic `topic0`, in emission order.
    function events(address emitter, bytes32 topic0) internal view returns (Event[] memory) {
        return _events(emitter, true, topic0);
    }

    /// @notice Converts a word to an address, rejecting words with any of the upper 96 bits set.
    function toAddress(uint256 word) internal pure returns (address) {
        if (word > type(uint160).max) revert NonCanonicalAddress(word);
        // forge-lint: disable-next-line(unsafe-typecast) -- upper 96 bits checked above
        return address(uint160(word));
    }

    function _read(uint256 param, uint256 in2) private view returns (uint256) {
        return traceReader.txtrace(param, in2);
    }

    function _find(uint256 addressParam, uint256 countParam, address account)
        private
        view
        returns (bool found, uint256 beforeValue, uint256 afterValue)
    {
        uint256 low = 0;
        uint256 high = _read(countParam, 0);
        while (low < high) {
            uint256 mid = (low + high) / 2;
            address entry = toAddress(_read(addressParam, mid));
            if (entry == account) return (true, _read(addressParam + 1, mid), _read(addressParam + 2, mid));
            if (entry < account) low = mid + 1;
            else high = mid;
        }
    }

    function _events(address emitter, bool filter, bytes32 topic0) private view returns (Event[] memory result) {
        // Collect matches first: `new Event[](n)` allocates a zeroed struct per element, so size it to the matches.
        uint256 count = _read(EVENTS_COUNT, 0);
        uint256[] memory matches = new uint256[](count); // index << 8 | topic count
        uint256 found;
        for (uint256 i = 0; i < count; i++) {
            if (toAddress(_read(EVENT_ADDRESS, i)) != emitter) continue;
            uint256 topicCount = _read(EVENT_TOPIC_COUNT, i);
            if (filter && (topicCount == 0 || bytes32(_read(EVENT_TOPIC0, i)) != topic0)) continue;
            matches[found++] = (i << 8) | topicCount;
        }
        result = new Event[](found);
        for (uint256 k = 0; k < found; k++) {
            (uint256 i, uint256 topicCount) = (matches[k] >> 8, matches[k] & 0xff);
            bytes32[] memory topics = new bytes32[](topicCount);
            for (uint256 t = 0; t < topicCount; t++) {
                topics[t] = bytes32(_read(EVENT_TOPIC0 + t, i));
            }
            result[k] = Event(i, topics, traceReader.eventDataCopy(i, 0, _read(EVENT_DATA_LEN, i)));
        }
    }
}
