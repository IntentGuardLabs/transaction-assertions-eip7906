// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {FrameTx} from "./FrameTx.sol";

/// @notice Base for scripts that send frame transactions to a Bogota node and read the results. Reads go to the
///         node at `latest` over JSON-RPC, so they see the transactions the script sent. Run with `--ffi`.
abstract contract FrameTxScript is Script {
    uint256 internal walletKey;
    address internal wallet;
    address internal nativeETH;
    address internal erc20;
    address internal state;

    /// @dev Receipt of the last transaction, as JSON.
    string internal receipt;

    /// @dev Reads the addresses written by script/DeployAssertions.s.sol and returns the mocks file's contents.
    function _loadDeployment() internal returns (string memory mocks) {
        string memory chain = vm.toString(block.chainid);
        string memory d = vm.readFile(string.concat("deployments/", chain, ".json"));
        mocks = vm.readFile(string.concat("deployments/", chain, "-mocks.json"));
        walletKey = vm.envUint("WALLET_KEY"); // from .env, written by script/node.sh
        wallet = vm.addr(walletKey);
        require(wallet == vm.parseJsonAddress(mocks, ".wallet"), "WALLET_KEY does not match the mocks' wallet");
        nativeETH = vm.parseJsonAddress(d, ".nativeETH");
        erc20 = vm.parseJsonAddress(d, ".erc20");
        state = vm.parseJsonAddress(d, ".state");
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Sending and reading
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev Signs the frames (after a VERIFY frame) as a frame transaction from the wallet, sends it and waits for
    ///      the receipt.
    function _send(string memory title, FrameTx.Frame[] memory body) internal {
        FrameTx.Frame[] memory frames = new FrameTx.Frame[](body.length + 1);
        frames[0] = FrameTx.verify();
        for (uint256 i; i < body.length; ++i) {
            frames[i + 1] = body[i];
        }
        bytes memory raw = FrameTx.sign(
            FrameTx.Tx({
                chainId: block.chainid,
                nonce: _quantity(vm.rpc("eth_getTransactionCount", _params(wallet))),
                sender: wallet,
                frames: frames,
                maxFee: 20 gwei * 16_000_000,
                maxPriorityFeePerGas: 1 gwei
            }),
            walletKey
        );
        bytes32 hash = bytes32(vm.rpc("eth_sendRawTransaction", string.concat('["', vm.toString(raw), '"]')));
        receipt = _receipt(hash);

        console.log("");
        console.log(title);
        console.log("  tx", vm.toString(hash));
        for (uint256 i; i < frames.length; ++i) {
            uint256 status = _frameStatus(i);
            string memory mode = frames[i].mode == FrameTx.MODE_VERIFY
                ? "VERIFY"
                : frames[i].mode == FrameTx.MODE_SENDER ? "SENDER" : "ASSERT";
            console.log(
                string.concat("  frame ", vm.toString(i), " ", mode, "  ", _statusName(status)), frames[i].target
            );
        }
    }

    /// @dev The receipt as JSON, for its per-frame statuses (`frameReceipts`). forge 1.5 has no `vm.rpcJson` and
    ///      `vm.rpc` returns objects ABI-encoded, so the receipt is fetched with `cast rpc` through ffi.
    function _receipt(bytes32 hash) internal returns (string memory json) {
        string[] memory cmd = new string[](6);
        (cmd[0], cmd[1], cmd[2], cmd[3], cmd[4], cmd[5]) =
        ("cast", "rpc", "eth_getTransactionReceipt", vm.toString(hash), "--rpc-url", vm.rpcUrl("local"));
        for (uint256 i; i < 50; ++i) {
            json = string(vm.ffi(cmd));
            if (bytes(json).length > 4) return json; // not "null"
            vm.sleep(100);
        }
        revert("no receipt");
    }

    /// @dev Reads go to the node at `latest`, so they see the transactions this script sent.
    function _read(address to, bytes memory data) internal returns (bytes memory) {
        return
            vm.rpc(
                "eth_call", string.concat('[{"to":"', vm.toString(to), '","data":"', vm.toString(data), '"},"latest"]')
            );
    }

    function _tokenBalance(address token, address holder) internal returns (uint256) {
        return abi.decode(_read(token, abi.encodeWithSignature("balanceOf(address)", holder)), (uint256));
    }

    function _ethBalance(address account) internal returns (uint256) {
        return _quantity(vm.rpc("eth_getBalance", _params(account)));
    }

    function _params(address account) internal pure returns (string memory) {
        return string.concat('["', vm.toString(account), '","latest"]');
    }

    /// @dev A JSON-RPC quantity, which `vm.rpc` returns as big-endian bytes.
    function _quantity(bytes memory b) internal pure returns (uint256 v) {
        for (uint256 i; i < b.length; ++i) {
            v = (v << 8) | uint8(b[i]);
        }
    }

    function _frameStatus(uint256 i) internal view returns (uint256) {
        return vm.parseJsonUint(receipt, string.concat(".frameReceipts[", vm.toString(i), "].status"));
    }

    function _statusName(uint256 status) internal pure returns (string memory) {
        return status == 1 ? "ok      " : status == 0 ? "REVERTED" : "skipped ";
    }

    function _expectFrames(uint256[] memory want) internal view {
        bool ok = true;
        for (uint256 i; i < want.length; ++i) {
            ok = ok && _frameStatus(i) == want[i];
        }
        _expect(ok, want[want.length - 1] == 1 ? "all assertions held" : "an assertion reverted the transaction");
    }

    function _expect(bool ok, string memory what) internal pure {
        console.log(ok ? "  =>" : "  => UNEXPECTED:", what);
        require(ok, string.concat("use case did not behave as expected: ", what));
    }

    function _frames(FrameTx.Frame memory a, FrameTx.Frame memory b) internal pure returns (FrameTx.Frame[] memory f) {
        f = new FrameTx.Frame[](2);
        (f[0], f[1]) = (a, b);
    }

    function _frames(FrameTx.Frame memory a, FrameTx.Frame memory b, FrameTx.Frame memory c)
        internal
        pure
        returns (FrameTx.Frame[] memory f)
    {
        f = new FrameTx.Frame[](3);
        (f[0], f[1], f[2]) = (a, b, c);
    }

    function _frames(FrameTx.Frame memory a, FrameTx.Frame memory b, FrameTx.Frame memory c, FrameTx.Frame memory d)
        internal
        pure
        returns (FrameTx.Frame[] memory f)
    {
        f = new FrameTx.Frame[](4);
        (f[0], f[1], f[2], f[3]) = (a, b, c, d);
    }

    function _statuses(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory s) {
        s = new uint256[](3);
        (s[0], s[1], s[2]) = (a, b, c);
    }

    function _statuses(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (uint256[] memory s) {
        s = new uint256[](4);
        (s[0], s[1], s[2], s[3]) = (a, b, c, d);
    }

    function _statuses(uint256 a, uint256 b, uint256 c, uint256 d, uint256 e)
        internal
        pure
        returns (uint256[] memory s)
    {
        s = new uint256[](5);
        (s[0], s[1], s[2], s[3], s[4]) = (a, b, c, d, e);
    }

    function _statuses(uint256 a, uint256 b, uint256 c, uint256 d, uint256 e, uint256 f, uint256 g)
        internal
        pure
        returns (uint256[] memory s)
    {
        s = new uint256[](7);
        (s[0], s[1], s[2], s[3], s[4], s[5], s[6]) = (a, b, c, d, e, f, g);
    }

    /// @dev Execution gas of frame `i`, excluding state gas (EIP-8037).
    function _frameGas(uint256 i) internal view returns (uint256) {
        return vm.parseJsonUint(receipt, string.concat(".frameReceipts[", vm.toString(i), "].executionGasUsed"));
    }
}
