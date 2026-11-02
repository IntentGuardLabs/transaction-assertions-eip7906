// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/Script.sol";
import {FrameTx} from "./utils/FrameTx.sol";
import {FrameTxScript} from "./utils/FrameTxScript.sol";

/// @notice Measures assertion gas on a Bogota node: one frame transaction per padding size (0, 200, 1,000 empty
///         events), each ASSERT frame running one access pattern. The figures are each frame's `gasUsed` from the
///         receipt. They back docs/EIP-7906-implementation-feedback.md (F1, F3).
///
///         forge script script/GasBenchmarks.s.sol --rpc-url local --ffi
contract GasBenchmarks is FrameTxScript {
    address internal usdc;
    address internal noise;
    address internal bench;

    function run() external {
        string memory mocks = _loadDeployment();
        usdc = vm.parseJsonAddress(mocks, ".usdc");
        noise = vm.parseJsonAddress(mocks, ".traceNoise");
        bench = vm.parseJsonAddress(mocks, ".traceBench");
        _measure(0);
        _measure(200);
        _measure(1000);
    }

    function _measure(uint256 logs) internal {
        address[] memory payees = new address[](3);
        for (uint256 i; i < payees.length; ++i) {
            payees[i] = address(uint160(0xb0000 + logs * 16 + i));
        }
        bytes memory maxSpent = abi.encodeWithSignature("maxSpent(address,address,uint256)", usdc, wallet, 1);

        FrameTx.Frame[] memory f = new FrameTx.Frame[](11);
        // Body: padding events, 5 fresh slots (~98k state gas each), 3 balance changes, and one token transfer.
        f[0] = FrameTx.Frame(
            FrameTx.MODE_SENDER,
            0,
            noise,
            1_500_000,
            2_000_000,
            payees.length,
            abi.encodeWithSignature("run(uint256,uint256,address[])", logs, 5, payees)
        );
        f[1] = FrameTx.Frame(
            FrameTx.MODE_SENDER,
            0,
            usdc,
            100_000,
            200_000,
            0,
            abi.encodeWithSignature("transfer(address,uint256)", address(0xBEEF), 1)
        );
        // The first frame to a contract pays its cold access; the second nop is the warm baseline.
        f[2] = _assert(bench, 100_000, abi.encodeWithSignature("nop()"));
        f[3] = _assert(bench, 100_000, abi.encodeWithSignature("nop()"));
        f[4] = _assert(bench, 500_000, abi.encodeWithSignature("queries(uint256)", 100));
        f[5] = _assert(bench, 300_000, abi.encodeWithSignature("ethLookup(address)", wallet));
        f[6] = _assert(
            bench,
            300_000,
            abi.encodeWithSignature("slotLookup(address,bytes32)", usdc, keccak256(abi.encode(wallet, 0)))
        );
        f[7] = _assert(erc20, 1_500_000, maxSpent);
        f[8] = _assert(erc20, 1_500_000, maxSpent);
        f[9] = _assert(erc20, 1_500_000, maxSpent);
        f[10] = _assert(nativeETH, 300_000, abi.encodeWithSignature("maxSpent(address,uint256)", wallet, 10));
        _send(string.concat("assertion frames with ", vm.toString(logs), " padding events"), f);

        string[11] memory labels = [
            "body: padding",
            "body: token transfer",
            "nop (cold target)",
            "nop (warm target)",
            "100 TXTRACE queries",
            "ETH lookup",
            "slot lookup",
            "ERC20 maxSpent #1",
            "ERC20 maxSpent #2",
            "ERC20 maxSpent #3",
            "ETH maxSpent"
        ];
        for (uint256 i; i < labels.length; ++i) {
            require(_frameStatus(i + 1) == 1, "benchmark frame failed");
            console.log(string.concat("    ", labels[i], ": ", vm.toString(_frameGas(i + 1)), " gas"));
        }
    }

    function _assert(address target, uint256 gas, bytes memory data) internal pure returns (FrameTx.Frame memory) {
        return FrameTx.Frame(FrameTx.MODE_ASSERT, 0, target, gas, 0, 0, data);
    }
}
