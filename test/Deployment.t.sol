// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TxTrace} from "../contracts/shared/TxTrace.sol";
import {NativeETHAssertion} from "../contracts/assertions/NativeETHAssertion.sol";
import {ERC20Assertion} from "../contracts/assertions/ERC20Assertion.sol";
import {ITxTraceReader} from "../contracts/shared/ITxTraceReader.sol";
import {DeployAssertions} from "../script/DeployAssertions.s.sol";

contract DeploymentTest is Test {
    function test_deployScriptWiresReaderIntoAssertions() public {
        vm.chainId(31_337);
        DeployAssertions script = new DeployAssertions();
        DeployAssertions.Deployment memory d = script.run();

        string memory artifact = vm.readFile("out/TxTraceReader.yul/TxTraceReader.json");
        assertEq(address(d.reader), script.readerAddress());
        assertEq(address(d.reader).codehash, keccak256(vm.parseJsonBytes(artifact, ".deployedBytecode.object")));
        assertEq(address(d.nativeETH.traceReader()), address(d.reader));
        assertEq(address(d.erc20.traceReader()), address(d.reader));
        assertEq(address(d.state.traceReader()), address(d.reader));
    }

    function test_deployScriptRefusesMainnet() public {
        vm.chainId(1);
        DeployAssertions d = new DeployAssertions();
        vm.expectRevert(DeployAssertions.MainnetDeploymentDisabled.selector);
        d.run();
    }

    function test_readerMustHaveCode() public {
        address empty = makeAddr("empty");
        vm.expectRevert(abi.encodeWithSelector(TxTrace.ReaderHasNoCode.selector, empty));
        new ERC20Assertion(ITxTraceReader(empty));
    }

    /// @dev The reader is an immutable (in the code, not storage): nothing a transaction could change.
    function test_assertionsHaveNoStorage() public {
        vm.chainId(31_337);
        DeployAssertions.Deployment memory d = new DeployAssertions().run();
        for (uint256 slot; slot < 4; ++slot) {
            assertEq(vm.load(address(d.erc20), bytes32(slot)), bytes32(0));
            assertEq(vm.load(address(d.nativeETH), bytes32(slot)), bytes32(0));
            assertEq(vm.load(address(d.state), bytes32(slot)), bytes32(0));
        }
    }
}
