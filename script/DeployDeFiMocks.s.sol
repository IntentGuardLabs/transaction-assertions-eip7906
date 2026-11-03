// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {MockERC20, MisleadingERC20} from "../test/mocks/MockTokens.sol";
import {MockSafe, SafeTakeover} from "../test/mocks/MockSafe.sol";
import {MockVenue} from "../test/mocks/MockVenue.sol";
import {TraceNoise, TraceBench} from "../test/mocks/TraceBench.sol";
import {ITxTraceReader} from "../contracts/shared/ITxTraceReader.sol";

/// @notice Local dev chains only. Deploys stand-ins for the DeFi protocols the use cases interact with, which exist on
///         real networks but not on a fresh local chain: tokens held by the wallet, a Safe it owns, three DEX venues
///         with fixed quotes, and the gas-benchmark helpers. On a shared network, point the use cases at the real
///         protocols instead. Writes the addresses to deployments/<chainId>-mocks.json.
///         forge script script/DeployDeFiMocks.s.sol --rpc-url local --broadcast --private-key <deployer>
contract DeployDeFiMocks is Script {
    /// @dev The wallet funded by script/node.sh.
    address internal constant DEFAULT_WALLET = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

    function run() external {
        require(block.chainid == 1337 || block.chainid == 31_337, "mocks are for local dev chains only");
        address wallet = vm.envOr("WALLET", DEFAULT_WALLET);

        vm.startBroadcast();
        MockERC20 usdc = new MockERC20();
        usdc.mint(wallet, 1_000_000e6);
        MockERC20 weth = new MockERC20();

        // A token the wallet forbids touching; it can change allowances without emitting Approval.
        MisleadingERC20 stakedToken = new MisleadingERC20();
        stakedToken.mint(wallet, 1000e18);

        // A Safe owned by the wallet, holding tokens, and a contract a malicious payload delegatecalls into.
        MockSafe safe = new MockSafe(wallet, address(0x5AFE));
        usdc.mint(address(safe), 1000e6);
        SafeTakeover takeover = new SafeTakeover();

        // Venues paying 18, 23 and 20 WETH for 50,000 USDC.
        MockVenue venueA = _venue(weth, 18e18);
        MockVenue venueB = _venue(weth, 23e18);
        MockVenue venueC = _venue(weth, 20e18);

        // Gas benchmarks: a body that pads the trace, and an assertion target with one access pattern per function.
        string memory deployment = vm.readFile(string.concat("deployments/", vm.toString(block.chainid), ".json"));
        TraceNoise noise = new TraceNoise();
        TraceBench bench = new TraceBench(ITxTraceReader(vm.parseJsonAddress(deployment, ".reader")));
        vm.stopBroadcast();

        string memory json = "mocks";
        vm.serializeAddress(json, "wallet", wallet);
        vm.serializeAddress(json, "usdc", address(usdc));
        vm.serializeAddress(json, "weth", address(weth));
        vm.serializeAddress(json, "stakedToken", address(stakedToken));
        vm.serializeAddress(json, "safe", address(safe));
        vm.serializeAddress(json, "takeover", address(takeover));
        vm.serializeAddress(json, "venueA", address(venueA));
        vm.serializeAddress(json, "venueB", address(venueB));
        vm.serializeAddress(json, "venueC", address(venueC));
        vm.serializeAddress(json, "traceNoise", address(noise));
        json = vm.serializeAddress(json, "traceBench", address(bench));
        vm.writeJson(json, string.concat("deployments/", vm.toString(block.chainid), "-mocks.json"));
    }

    function _venue(MockERC20 tokenOut, uint256 quote) internal returns (MockVenue venue) {
        venue = new MockVenue();
        venue.setQuote(quote);
        tokenOut.mint(address(venue), 1000e18);
    }
}
