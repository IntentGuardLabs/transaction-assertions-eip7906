// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";

/// @notice Encodes and signs EIP-8141 frame transactions (type 0x06), which forge cannot broadcast itself. The
///         encoding follows go-ethereum bogota-devnet-2 (`core/types/tx_frame.go`).
library FrameTx {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint8 internal constant TYPE = 0x06;
    uint256 internal constant MODE_VERIFY = 1;
    uint256 internal constant MODE_SENDER = 2;
    uint256 internal constant MODE_ASSERT = 3;
    uint256 internal constant APPROVE_EXECUTION_AND_PAYMENT = 3;
    uint256 internal constant SCHEME_SECP256K1 = 1;

    struct Frame {
        uint256 mode;
        uint256 flags;
        address target; // address(0) encodes as nil: the transaction sender
        uint256 executionGas;
        uint256 stateGas;
        uint256 value;
        bytes data;
    }

    struct Tx {
        uint256 chainId;
        uint256 nonce; // account nonce (EIP-8250 empty nonce-key list)
        address sender;
        Frame[] frames;
        uint256 maxFee; // total wei budget
        uint256 maxPriorityFeePerGas;
    }

    /// @notice VERIFY frame for the protocol's default code: a secp256k1 signature by the sender.
    function verify() internal pure returns (Frame memory) {
        return Frame(MODE_VERIFY, APPROVE_EXECUTION_AND_PAYMENT, address(0), 50_000, 100_000, 0, "");
    }

    function call(address target, uint256 value, bytes memory data) internal pure returns (Frame memory) {
        return Frame(MODE_SENDER, 0, target, 2_000_000, 1_500_000, value, data);
    }

    function assertion(address target, bytes memory data) internal pure returns (Frame memory) {
        return Frame(MODE_ASSERT, 0, target, 300_000, 0, 0, data);
    }

    /// @notice The raw signed transaction, ready for `eth_sendRawTransaction`.
    function sign(Tx memory t, uint256 key) internal pure returns (bytes memory) {
        // The signature hash covers the signature's length (65) in place of the signature.
        bytes32 hash = keccak256(abi.encodePacked(TYPE, _encode(t, RLP.uint_(65))));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, hash);
        bytes memory signature = abi.encodePacked(v - 27, r, s); // EIP-8141: v || r || s
        return abi.encodePacked(TYPE, _encode(t, RLP.bytes_(signature)));
    }

    function _encode(Tx memory t, bytes memory encodedSignature) private pure returns (bytes memory) {
        bytes[] memory frames = new bytes[](t.frames.length);
        for (uint256 i; i < frames.length; ++i) {
            Frame memory f = t.frames[i];
            bytes[] memory limits = new bytes[](2);
            (limits[0], limits[1]) = (RLP.uint_(f.executionGas), RLP.uint_(f.stateGas));
            bytes[] memory frame = new bytes[](6);
            frame[0] = RLP.uint_(f.mode);
            frame[1] = RLP.uint_(f.flags);
            frame[2] = f.target == address(0) ? RLP.bytes_("") : RLP.bytes_(abi.encodePacked(f.target));
            frame[3] = RLP.list(limits);
            frame[4] = RLP.uint_(f.value);
            frame[5] = RLP.bytes_(f.data);
            frames[i] = RLP.list(frame);
        }

        // One signature entry: [scheme, signer (empty), msg (empty: canonical hash), signature].
        bytes[] memory sig = new bytes[](4);
        (sig[0], sig[1], sig[2], sig[3]) =
        (RLP.uint_(SCHEME_SECP256K1), RLP.bytes_(""), RLP.bytes_(""), encodedSignature);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = RLP.list(sig);

        bytes[] memory fees = new bytes[](2);
        (fees[0], fees[1]) = (RLP.uint_(t.maxFee), RLP.uint_(t.maxPriorityFeePerGas));

        bytes[] memory fields = new bytes[](8);
        fields[0] = RLP.uint_(t.chainId);
        fields[1] = RLP.list(new bytes[](0)); // nonce keys
        fields[2] = RLP.uint_(t.nonce);
        fields[3] = RLP.bytes_(abi.encodePacked(t.sender));
        fields[4] = RLP.list(frames);
        fields[5] = RLP.list(sigs);
        fields[6] = RLP.list(fees);
        fields[7] = RLP.list(new bytes[](0)); // blob versioned hashes
        return RLP.list(fields);
    }
}

/// @notice Minimal RLP encoding.
library RLP {
    function uint_(uint256 x) internal pure returns (bytes memory) {
        return bytes_(_trim(abi.encodePacked(x)));
    }

    function bytes_(bytes memory b) internal pure returns (bytes memory) {
        if (b.length == 1 && uint8(b[0]) < 0x80) return b;
        return abi.encodePacked(_prefix(0x80, b.length), b);
    }

    function list(bytes[] memory items) internal pure returns (bytes memory payload) {
        for (uint256 i; i < items.length; ++i) {
            payload = abi.encodePacked(payload, items[i]);
        }
        return abi.encodePacked(_prefix(0xc0, payload.length), payload);
    }

    function _prefix(uint8 offset, uint256 length) private pure returns (bytes memory) {
        if (length < 56) return abi.encodePacked(uint8(offset + length));
        bytes memory len = _trim(abi.encodePacked(length));
        return abi.encodePacked(uint8(offset + 55 + len.length), len);
    }

    /// @dev Big-endian bytes without leading zeros; 0 becomes the empty string.
    function _trim(bytes memory word) private pure returns (bytes memory out) {
        uint256 i;
        while (i < word.length && word[i] == 0) ++i;
        out = new bytes(word.length - i);
        for (uint256 j; j < out.length; ++j) {
            out[j] = word[i + j];
        }
    }
}
