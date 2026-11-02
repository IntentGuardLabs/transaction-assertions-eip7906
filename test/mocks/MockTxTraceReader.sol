// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ITxTraceReader} from "../../contracts/shared/ITxTraceReader.sol";
import {TEST_READER} from "../utils/TestReader.sol";

/// @title MockTxTraceReader
/// @notice TEST ONLY. Serves a synthetic EIP-7906 trace through the same interface as `TxTraceReader.yul`.
///         Tests etch its code at `TEST_READER` (see `TraceTest`).
/// @dev Reproduces the EIP-7906 exceptional-halt conditions as reverts with `ExceptionalHalt`, so tests can show
///      the libraries never issue out-of-range queries. Balance, slot, code and nonce tables are kept in the
///      canonical order (ascending address, then slot key); the setters reject entries whose before and after values
///      are equal, which never appear in a real trace.
///      It never produces real trace data, so assertions bound to it prove nothing about a real transaction.
contract MockTxTraceReader is ITxTraceReader {
    enum Halt {
        NotInAssertFrame,
        InvalidParam,
        NonZeroIn2,
        IndexOutOfRange,
        TopicOutOfRange,
        DataOutOfRange
    }

    error ExceptionalHalt(Halt reason);
    error UnchangedEntry();

    struct Event {
        address emitter;
        bytes32[] topics;
        bytes data;
    }

    struct BalanceEntry {
        address account;
        uint256 beforeBalance;
        uint256 afterBalance;
    }

    struct SlotEntry {
        address account;
        bytes32 slot;
        bytes32 beforeValue;
        bytes32 afterValue;
    }

    struct CodeEntry {
        address account;
        bytes32 beforeHash;
        bytes32 afterHash;
    }

    struct NonceEntry {
        address account;
        uint256 beforeNonce;
        uint256 afterNonce;
    }

    struct Override {
        bool set;
        uint256 value;
    }

    Event[] internal _events;
    BalanceEntry[] internal _balances;
    SlotEntry[] internal _slots;
    CodeEntry[] internal _codes;
    NonceEntry[] internal _nonces;
    address internal _gasPayer;
    uint256 internal _gasPreCharge;
    mapping(uint256 param => mapping(uint256 in2 => Override)) internal _overrides;

    /// @notice When true, every read halts, as TXTRACE does outside an ASSERT frame. Defaults to false so the mock
    ///         also works when its code is etched at `TEST_READER`.
    bool public outsideAssertFrame;

    // ---------------------------------------------------------------------
    // Trace construction
    // ---------------------------------------------------------------------

    function setAssertFrameActive(bool active) external {
        outsideAssertFrame = !active;
    }

    function pushEvent(address emitter, bytes32[] memory topics, bytes memory data) public returns (uint256 index) {
        require(topics.length <= 4, "mock: too many topics");
        index = _events.length;
        Event storage e = _events.push();
        e.emitter = emitter;
        e.topics = topics;
        e.data = data;
    }

    function setBalanceChange(address account, uint256 beforeBalance, uint256 afterBalance) external {
        if (beforeBalance == afterBalance) revert UnchangedEntry();
        uint256 i = 0;
        while (i < _balances.length && _balances[i].account < account) ++i;
        if (i < _balances.length && _balances[i].account == account) {
            _balances[i] = BalanceEntry(account, beforeBalance, afterBalance);
            return;
        }
        _balances.push();
        for (uint256 j = _balances.length - 1; j > i; --j) {
            _balances[j] = _balances[j - 1];
        }
        _balances[i] = BalanceEntry(account, beforeBalance, afterBalance);
    }

    function setSlotChange(address account, bytes32 slot, bytes32 beforeValue, bytes32 afterValue) external {
        if (beforeValue == afterValue) revert UnchangedEntry();
        uint256 i = 0;
        while (i < _slots.length && _slotLess(_slots[i].account, _slots[i].slot, account, slot)) ++i;
        if (i < _slots.length && _slots[i].account == account && _slots[i].slot == slot) {
            _slots[i] = SlotEntry(account, slot, beforeValue, afterValue);
            return;
        }
        _slots.push();
        for (uint256 j = _slots.length - 1; j > i; --j) {
            _slots[j] = _slots[j - 1];
        }
        _slots[i] = SlotEntry(account, slot, beforeValue, afterValue);
    }

    /// @dev Code and nonce tables are appended; callers add them in ascending address order.
    function pushCodeChange(address account, bytes32 beforeHash, bytes32 afterHash) external {
        if (beforeHash == afterHash) revert UnchangedEntry();
        require(_codes.length == 0 || _codes[_codes.length - 1].account < account, "mock: unsorted");
        _codes.push(CodeEntry(account, beforeHash, afterHash));
    }

    function pushNonceChange(address account, uint256 beforeNonce, uint256 afterNonce) external {
        if (beforeNonce == afterNonce) revert UnchangedEntry();
        require(_nonces.length == 0 || _nonces[_nonces.length - 1].account < account, "mock: unsorted");
        _nonces.push(NonceEntry(account, beforeNonce, afterNonce));
    }

    function setGas(address payer, uint256 preCharge) external {
        _gasPayer = payer;
        _gasPreCharge = preCharge;
    }

    /// @notice Forces `txtrace(param, in2)` to return `value`, bypassing all checks. Used to simulate malformed
    ///         or non-conforming trace sources.
    function setOverride(uint256 param, uint256 in2, uint256 value) external {
        _overrides[param][in2] = Override(true, value);
    }

    function reset() external {
        delete _events;
        delete _balances;
        delete _slots;
        delete _codes;
        delete _nonces;
        delete _gasPayer;
        delete _gasPreCharge;
    }

    // ---------------------------------------------------------------------
    // ITxTraceReader
    // ---------------------------------------------------------------------

    function txtrace(uint256 param, uint256 in2) public view returns (uint256) {
        if (outsideAssertFrame) revert ExceptionalHalt(Halt.NotInAssertFrame);
        Override memory o = _overrides[param][in2];
        if (o.set) return o.value;
        if (param > 0x1A) revert ExceptionalHalt(Halt.InvalidParam);

        // Count and transaction-level params take no index.
        if (param <= 0x03 || param == 0x11 || param == 0x19 || param == 0x1A) {
            if (in2 != 0) revert ExceptionalHalt(Halt.NonZeroIn2);
            if (param == 0x00) return _balances.length;
            if (param == 0x01) return _slots.length;
            if (param == 0x02) return _codes.length;
            if (param == 0x03) return _nonces.length;
            if (param == 0x11) return _events.length;
            if (param == 0x19) return _gasPreCharge;
            return uint256(uint160(_gasPayer));
        }

        if (param <= 0x06) {
            if (in2 >= _balances.length) revert ExceptionalHalt(Halt.IndexOutOfRange);
            BalanceEntry storage b = _balances[in2];
            if (param == 0x04) return uint256(uint160(b.account));
            if (param == 0x05) return b.beforeBalance;
            return b.afterBalance;
        }
        if (param <= 0x0A) {
            if (in2 >= _slots.length) revert ExceptionalHalt(Halt.IndexOutOfRange);
            SlotEntry storage s = _slots[in2];
            if (param == 0x07) return uint256(uint160(s.account));
            if (param == 0x08) return uint256(s.beforeValue);
            if (param == 0x09) return uint256(s.afterValue);
            return uint256(s.slot);
        }
        if (param <= 0x0D) {
            if (in2 >= _codes.length) revert ExceptionalHalt(Halt.IndexOutOfRange);
            CodeEntry storage c = _codes[in2];
            if (param == 0x0B) return uint256(uint160(c.account));
            if (param == 0x0C) return uint256(c.beforeHash);
            return uint256(c.afterHash);
        }
        if (param <= 0x10) {
            if (in2 >= _nonces.length) revert ExceptionalHalt(Halt.IndexOutOfRange);
            NonceEntry storage n = _nonces[in2];
            if (param == 0x0E) return uint256(uint160(n.account));
            if (param == 0x0F) return n.beforeNonce;
            return n.afterNonce;
        }

        // 0x12 - 0x18: events.
        if (in2 >= _events.length) revert ExceptionalHalt(Halt.IndexOutOfRange);
        Event storage e = _events[in2];
        if (param == 0x12) return uint256(uint160(e.emitter));
        if (param == 0x13) return e.topics.length;
        if (param == 0x18) return e.data.length;
        uint256 topic = param - 0x14;
        if (topic >= e.topics.length) revert ExceptionalHalt(Halt.TopicOutOfRange);
        return uint256(e.topics[topic]);
    }

    function eventDataCopy(uint256 eventIndex, uint256 dataOffset, uint256 length)
        external
        view
        returns (bytes memory data)
    {
        if (outsideAssertFrame) revert ExceptionalHalt(Halt.NotInAssertFrame);
        if (eventIndex >= _events.length) revert ExceptionalHalt(Halt.IndexOutOfRange);
        bytes storage source = _events[eventIndex].data;
        // `dataOffset + length` is evaluated without wraparound, and the check applies even when `length` is 0.
        if (dataOffset > source.length || length > source.length - dataOffset) {
            revert ExceptionalHalt(Halt.DataOutOfRange);
        }
        data = new bytes(length);
        for (uint256 i; i < length; ++i) {
            data[i] = source[dataOffset + i];
        }
    }

    function _slotLess(address a, bytes32 slotA, address b, bytes32 slotB) private pure returns (bool) {
        return a < b || (a == b && uint256(slotA) < uint256(slotB));
    }
}
