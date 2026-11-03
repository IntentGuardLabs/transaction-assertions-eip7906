// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ITxTraceReader} from "../contracts/shared/ITxTraceReader.sol";
import {NativeETHAssertion} from "../contracts/assertions/NativeETHAssertion.sol";
import {ERC20Assertion} from "../contracts/assertions/ERC20Assertion.sol";
import {ERC721Assertion} from "../contracts/assertions/ERC721Assertion.sol";
import {StateAssertion} from "../contracts/assertions/StateAssertion.sol";

/// @notice The product deployment: `TxTraceReader` (CREATE2 factory, salt 0, so the same address on every chain) and
///         the assertion contracts that read it. Run it on any chain with EIP-7906; wallets only need these
///         addresses. Writes them to deployments/<chainId>.json. Refuses mainnet.
///         forge script script/DeployAssertions.s.sol --rpc-url <rpc> --broadcast --skip-simulation
///         Signs with DEPLOYER_KEY from .env if set (script/node.sh writes it), else with --private-key / --account.
contract DeployAssertions is Script {
    error MainnetDeploymentDisabled();
    error ReaderDeploymentFailed();

    struct Deployment {
        ITxTraceReader reader;
        NativeETHAssertion nativeETH;
        ERC20Assertion erc20;
        ERC721Assertion erc721;
        StateAssertion state;
    }

    /// @notice CREATE2 address of `TxTraceReader` for the compiled bytecode.
    function readerAddress() public view returns (address) {
        return vm.computeCreate2Address(bytes32(0), keccak256(_readerInitCode()), CREATE2_FACTORY);
    }

    function run() external returns (Deployment memory d) {
        if (block.chainid == 1) revert MainnetDeploymentDisabled();

        bytes memory initCode = _readerInitCode();
        bytes memory runtime = vm.parseJsonBytes(_readerArtifact(), ".deployedBytecode.object");
        address reader = readerAddress();

        uint256 key = vm.envOr("DEPLOYER_KEY", uint256(0));
        if (key == 0) vm.startBroadcast();
        else vm.startBroadcast(key);
        if (reader.code.length == 0) {
            (bool ok,) = CREATE2_FACTORY.call(abi.encodePacked(bytes32(0), initCode));
            if (!ok) revert ReaderDeploymentFailed();
        }
        if (reader.codehash != keccak256(runtime)) revert ReaderDeploymentFailed();

        d.reader = ITxTraceReader(reader);
        d.nativeETH = new NativeETHAssertion(d.reader);
        d.erc20 = new ERC20Assertion(d.reader);
        d.erc721 = new ERC721Assertion();
        d.state = new StateAssertion(d.reader);
        vm.stopBroadcast();

        console.log("TxTraceReader      ", reader);
        console.log("NativeETHAssertion ", address(d.nativeETH));
        console.log("ERC20Assertion     ", address(d.erc20));
        console.log("ERC721Assertion    ", address(d.erc721));
        console.log("StateAssertion     ", address(d.state));

        string memory json = "deployment";
        vm.serializeAddress(json, "reader", reader);
        vm.serializeAddress(json, "nativeETH", address(d.nativeETH));
        vm.serializeAddress(json, "erc20", address(d.erc20));
        vm.serializeAddress(json, "erc721", address(d.erc721));
        json = vm.serializeAddress(json, "state", address(d.state));
        vm.writeJson(json, path());
    }

    /// @notice Where the addresses are written, read by the other scripts.
    function path() public view returns (string memory) {
        return string.concat("deployments/", vm.toString(block.chainid), ".json");
    }

    function _readerArtifact() internal view returns (string memory) {
        // Yul artifacts carry no ABI, so read the bytecode straight from the JSON.
        return vm.readFile("out/TxTraceReader.yul/TxTraceReader.json");
    }

    function _readerInitCode() internal view returns (bytes memory) {
        return vm.parseJsonBytes(_readerArtifact(), ".bytecode.object");
    }
}
