// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {MockTxTraceReader} from "../../mocks/MockTxTraceReader.sol";
import {TxTrace} from "../../../contracts/shared/TxTrace.sol";
import {TEST_READER} from "../../utils/TestReader.sol";

/// @notice VERIFY-frame entry point expected by the emulator.
interface IFrameValidator {
    function validate(FrameTxEmulator.Frame[] calldata frames, bytes calldata signature) external view;
}

/// @title FrameTxEmulator
/// @notice TEST ONLY. Approximates EIP-8141 frame-transaction execution with EIP-7906 ASSERT frames on a
///         standard Foundry EVM.
/// @dev What is emulated:
///      - Frame order: a validation prefix (VERIFY frames, then the payment approval), the execution body
///        (DEFAULT / SENDER frames) and a trailing suffix of ASSERT frames.
///      - Gas pre-charge: `preCharge` is deducted from `payer` when the validation prefix approves payment.
///      - The trace: events recorded during the transaction (`vm.recordLogs`) and the net balance and storage diff
///        against the transaction prestate (`vm.startStateDiffRecording` plus live reads), loaded into a
///        `MockTxTraceReader` before the ASSERT frames run.
///      - ASSERT frames run as static calls. If one fails, state is reset to the end of the validation prefix,
///        so the body is undone and the pre-charge is kept.
///      What is NOT emulated: transaction encoding and signature hashing, the real frame opcodes (FRAMEPARAM, ...),
///      APPROVE, per-frame gas limits, refunds, receipts, and TXTRACE itself. The assertions read the mock, not
///      the opcodes. Passing here shows the assertion logic composes with real token contracts; it does NOT show
///      EIP-7906 or EIP-8141 support.
abstract contract FrameTxEmulator is Test {
    uint8 internal constant MODE_DEFAULT = 0;
    uint8 internal constant MODE_VERIFY = 1;
    uint8 internal constant MODE_SENDER = 2;
    uint8 internal constant MODE_ASSERT = 3; // added by EIP-7906

    struct Frame {
        uint8 mode;
        address target;
        uint256 value;
        bytes data;
    }

    struct FrameTx {
        address sender;
        address payer;
        uint256 preCharge;
        Frame[] frames;
    }

    struct Result {
        bool valid; // false: the validation prefix failed, so the transaction could not be included
        bool assertionsPassed;
        uint256 failedFrame; // index of the failing ASSERT frame, or type(uint256).max
        bytes failure; // revert data of the failing ASSERT frame
    }

    MockTxTraceReader internal emulatedTrace;

    /// @dev Accounts whose prestate balance is captured explicitly (the state-diff recorder does not see the
    ///      emulated pre-charge).
    address[] internal watched;

    /// @dev Installs the mock at the fixed reader address the assertion contracts read from.
    function _setUpEmulator() internal {
        vm.etch(address(TEST_READER), address(new MockTxTraceReader()).code);
        emulatedTrace = MockTxTraceReader(address(TEST_READER));
    }

    function _watch(address account) internal {
        watched.push(account);
    }

    /// @dev One emulated transaction per test: the diff bookkeeping below is not reset between transactions.
    function _execute(FrameTx memory t) internal returns (Result memory r) {
        require(!_executed, "emulator: one transaction per test");
        _executed = true;
        r.failedFrame = type(uint256).max;

        uint256[] memory prestate = new uint256[](watched.length + 1);
        for (uint256 w; w < watched.length; ++w) {
            prestate[w] = watched[w].balance;
        }
        prestate[watched.length] = t.payer.balance;

        vm.recordLogs();
        vm.startStateDiffRecording();

        // Validation prefix. VERIFY frames are static; a failure makes the transaction invalid. Each VERIFY target
        // receives the transaction's actual non-VERIFY frames (standing in for FRAMEPARAM / FRAMEDATACOPY
        // introspection) plus its own frame data as the signature.
        Frame[] memory authorized = _nonVerifyFrames(t.frames);
        uint256 i;
        for (; i < t.frames.length && t.frames[i].mode == MODE_VERIFY; ++i) {
            (bool ok,) = t.frames[i].target
                .staticcall(abi.encodeWithSelector(IFrameValidator.validate.selector, authorized, t.frames[i].data));
            if (!ok) {
                vm.stopAndReturnStateDiff();
                vm.getRecordedLogs();
                return r;
            }
        }
        r.valid = true;
        // Payment approved: the protocol pre-charges the payer.
        vm.deal(t.payer, t.payer.balance - t.preCharge);
        uint256 afterValidation = vm.snapshotState();

        // Execution body. A reverting body frame only reverts itself.
        for (; i < t.frames.length && t.frames[i].mode != MODE_ASSERT; ++i) {
            Frame memory f = t.frames[i];
            address caller = f.mode == MODE_SENDER ? t.sender : address(0xaa); // ENTRY_POINT
            vm.prank(caller, caller);
            (bool ok,) = f.target.call{value: f.value}(f.data);
            ok; // emulating per-frame revert: nothing else to do
        }

        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        _loadTrace(t, logs, accesses, prestate);

        // ASSERT suffix.
        r.assertionsPassed = true;
        for (; i < t.frames.length; ++i) {
            require(t.frames[i].mode == MODE_ASSERT, "emulator: ASSERT frames must be a trailing suffix");
            (bool ok, bytes memory ret) = t.frames[i].target.staticcall(t.frames[i].data);
            if (!ok) {
                r.assertionsPassed = false;
                r.failedFrame = i;
                r.failure = ret;
                vm.revertToState(afterValidation);
                break;
            }
        }
    }

    function _nonVerifyFrames(Frame[] memory frames) private pure returns (Frame[] memory result) {
        result = new Frame[](frames.length);
        uint256 n;
        for (uint256 i; i < frames.length; ++i) {
            if (frames[i].mode != MODE_VERIFY) result[n++] = frames[i];
        }
        assembly ("memory-safe") {
            mstore(result, n)
        }
    }

    function _loadTrace(
        FrameTx memory t,
        Vm.Log[] memory logs,
        Vm.AccountAccess[] memory accesses,
        uint256[] memory prestate
    ) private {
        for (uint256 i; i < logs.length; ++i) {
            emulatedTrace.pushEvent(logs[i].emitter, logs[i].topics, logs[i].data);
        }

        // Net balance changes: prestate is the explicitly watched balance, or the first observed old balance.
        for (uint256 i; i < watched.length; ++i) {
            _setBalance(watched[i], prestate[i]);
        }
        _setBalance(t.payer, prestate[watched.length]);
        // Accounts that only send value appear as accessors, not accounts: watch them explicitly.
        for (uint256 i; i < accesses.length; ++i) {
            _setBalance(accesses[i].account, accesses[i].oldBalance);
        }

        // Net storage changes against the first observed value.
        for (uint256 i; i < accesses.length; ++i) {
            Vm.StorageAccess[] memory s = accesses[i].storageAccesses;
            for (uint256 j; j < s.length; ++j) {
                bytes32 key = keccak256(abi.encode(s[j].account, s[j].slot));
                if (_slotSeen[key]) continue;
                _slotSeen[key] = true;
                bytes32 current = vm.load(s[j].account, s[j].slot);
                if (current != s[j].previousValue) {
                    emulatedTrace.setSlotChange(s[j].account, s[j].slot, s[j].previousValue, current);
                }
            }
        }

        emulatedTrace.setGas(t.payer, t.preCharge);
    }

    bool private _executed;
    mapping(bytes32 => bool) private _slotSeen;
    mapping(address => bool) private _balanceSeen;

    /// @dev Records `account`'s change from `prestate` the first time it is seen; later calls are ignored.
    function _setBalance(address account, uint256 prestate) private {
        if (_balanceSeen[account]) return;
        _balanceSeen[account] = true;
        if (account.balance != prestate) emulatedTrace.setBalanceChange(account, prestate, account.balance);
    }
}
