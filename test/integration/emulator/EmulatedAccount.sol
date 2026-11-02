// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FrameTxEmulator, IFrameValidator} from "./FrameTxEmulator.sol";

/// @title EmulatedAccount
/// @notice TEST ONLY. A smart account whose validation commits to its ASSERT frames.
/// @dev Shows the account-side half of the design. On EIP-8141 the account would read the signature hash with
///      `TXPARAM` and the frames with `FRAMEPARAM` / `FRAMEDATACOPY` inside its VERIFY frame. The emulator passes
///      the transaction's actual frames as calldata instead, and the signature hash is computed here over them.
///
///      - Owner key: may sign any frame list. The signature commits to every frame, including each ASSERT frame's
///        target and calldata, so the assertions cannot be dropped or altered after signing.
///      - Session key: may only sign frame lists whose ASSERT suffix contains `REQUIRED_ASSERT_TARGET` called with
///        exactly `REQUIRED_ASSERT_DATA`. Without that frame, validation fails and the transaction is invalid.
contract EmulatedAccount is IFrameValidator {
    address public immutable OWNER;
    address public immutable SESSION_KEY;
    address public immutable REQUIRED_ASSERT_TARGET;
    bytes32 public immutable REQUIRED_ASSERT_DATA_HASH;

    error InvalidSignature();
    error MissingRequiredAssertFrame();

    constructor(address owner, address sessionKey, address requiredTarget, bytes memory requiredData) {
        OWNER = owner;
        SESSION_KEY = sessionKey;
        REQUIRED_ASSERT_TARGET = requiredTarget;
        REQUIRED_ASSERT_DATA_HASH = keccak256(requiredData);
    }

    receive() external payable {}

    /// @notice Emulated signature hash over the frames the signer authorized.
    function sigHash(FrameTxEmulator.Frame[] memory frames) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), frames));
    }

    /// @notice VERIFY-frame entry point.
    function validate(FrameTxEmulator.Frame[] calldata frames, bytes calldata signature) external view {
        (uint8 v, bytes32 r, bytes32 s) = abi.decode(signature, (uint8, bytes32, bytes32));
        address signer = ecrecover(sigHash(frames), v, r, s);
        if (signer == address(0)) revert InvalidSignature();
        if (signer == OWNER) return;
        if (signer != SESSION_KEY) revert InvalidSignature();
        if (!hasRequiredAssertFrame(frames)) revert MissingRequiredAssertFrame();
    }

    /// @notice Scans the trailing ASSERT suffix (EIP-7906 requires ASSERT frames to be a contiguous suffix).
    function hasRequiredAssertFrame(FrameTxEmulator.Frame[] calldata frames) public view returns (bool) {
        for (uint256 i = frames.length; i > 0; --i) {
            FrameTxEmulator.Frame calldata f = frames[i - 1];
            if (f.mode != 3) return false;
            if (f.target == REQUIRED_ASSERT_TARGET && keccak256(f.data) == REQUIRED_ASSERT_DATA_HASH) return true;
        }
        return false;
    }

    /// @notice SENDER-frame entry point: arbitrary call authorized by validation.
    function execute(address target, uint256 value, bytes calldata data) external {
        require(msg.sender == address(this) || msg.sender == OWNER || msg.sender == SESSION_KEY, "unauthorized");
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}
