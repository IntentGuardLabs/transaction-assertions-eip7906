// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console} from "forge-std/Script.sol";
import {INativeETHAssertion} from "../contracts/assertions/interfaces/INativeETHAssertion.sol";
import {IERC20Assertion} from "../contracts/assertions/interfaces/IERC20Assertion.sol";
import {IStateAssertion} from "../contracts/assertions/interfaces/IStateAssertion.sol";
import {FrameTx} from "./utils/FrameTx.sol";
import {FrameTxScript} from "./utils/FrameTxScript.sol";

interface IToken {
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface ISafe {
    function execTransaction(address to, uint256 value, bytes calldata data, uint8 operation) external payable;
    function getSingleton() external view returns (address);
    function isOwner(address) external view returns (bool);
}

/// @notice Sends real EIP-8141 frame transactions to a Bogota node, each followed by ASSERT frames that call the
///         deployed assertions. Each use case sends one transaction the assertions allow and one they must revert,
///         then checks the frame statuses in the receipt and the chain state.
///
///         forge script script/UseCases.s.sol --rpc-url local --ffi                              all use cases
///         forge script script/UseCases.s.sol --rpc-url local --ffi --sig "preventBybitHack()"  one use case
///
///         `--ffi` lets the script run `cast` to read receipts (see docs/WORKAROUNDS.md). Run script/node.sh,
///         DeployAssertions and DeployDeFiMocks first.
contract UseCases is FrameTxScript {
    address internal constant RECIPIENT = address(0xBEEF);
    address internal constant DRAINER = address(0xD7A1);
    bytes32 internal constant SAFE_SINGLETON_SLOT = bytes32(0);
    bytes32 internal constant SAFE_NONCE_SLOT = bytes32(uint256(5));
    uint256 internal constant HALF = 50_000e6;

    address internal usdc;
    address internal weth;
    address internal stakedToken;
    address internal safe;
    address internal takeover;
    address internal venueA;
    address internal venueB;
    address internal venueC;

    function run() external {
        preventOverspending();
        preventForbiddenTokenApproval();
        preventBybitHack();
        preventMinSwapOutput();
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Use cases
    // -----------------------------------------------------------------------------------------------------------------

    /// @notice The user caps what leaves the wallet: 0.5 ETH (gas excluded) and 100 USDC.
    function preventOverspending() public {
        _load("Prevent overspending: at most 0.5 ETH and 100 USDC leave the wallet");
        bytes memory maxEth = abi.encodeCall(INativeETHAssertion.maxSpent, (wallet, 0.5 ether));

        uint256 before = _ethBalance(RECIPIENT);
        _send("send 0.4 ETH", _frames(FrameTx.call(RECIPIENT, 0.4 ether, ""), FrameTx.assertion(nativeETH, maxEth)));
        _expectFrames(_statuses(1, 1, 1));
        _expect(_ethBalance(RECIPIENT) - before == 0.4 ether, "recipient received 0.4 ETH");

        before = _ethBalance(RECIPIENT);
        _send("send 0.6 ETH", _frames(FrameTx.call(RECIPIENT, 0.6 ether, ""), FrameTx.assertion(nativeETH, maxEth)));
        _expectFrames(_statuses(1, 1, 0));
        _expect(_ethBalance(RECIPIENT) == before, "transfer reverted: recipient received nothing");

        before = _tokenBalance(usdc, RECIPIENT);
        _send(
            "transfer 150 USDC",
            _frames(
                FrameTx.call(usdc, 0, abi.encodeCall(IToken.transfer, (RECIPIENT, 150e6))),
                FrameTx.assertion(
                    erc20, abi.encodeCall(IERC20Assertion.maxSpentAtSlot, (usdc, _balanceSlot(wallet), 100e6))
                )
            )
        );
        _expectFrames(_statuses(1, 1, 0));
        _expect(_tokenBalance(usdc, RECIPIENT) == before, "transfer reverted: recipient received no USDC");
    }

    /// @notice The user forbids any change to `stakedToken`. A USDC payment passes; the same payment bundled with a
    ///         hidden approval of the staked token to a drainer (no Approval event) is reverted.
    function preventForbiddenTokenApproval() public {
        _load("Prevent forbidden token approval: stakedToken cannot be touched");
        address[] memory forbidden = new address[](1);
        forbidden[0] = stakedToken;
        FrameTx.Frame memory payment = FrameTx.call(usdc, 0, abi.encodeCall(IToken.transfer, (RECIPIENT, 100e6)));
        FrameTx.Frame memory untouched =
            FrameTx.assertion(state, abi.encodeCall(IStateAssertion.untouched, (forbidden)));

        _send("pay 100 USDC", _frames(payment, untouched));
        _expectFrames(_statuses(1, 1, 1));

        uint256 before = _tokenBalance(usdc, RECIPIENT);
        FrameTx.Frame memory silentApproval = FrameTx.call(
            stakedToken,
            0,
            abi.encodeWithSignature("silentApprove(address,address,uint256)", wallet, DRAINER, type(uint256).max)
        );
        _send("pay 100 USDC + silent approval of stakedToken to a drainer", _frames(payment, silentApproval, untouched));
        _expectFrames(_statuses(1, 1, 1, 0));
        uint256 allowance =
            abi.decode(_read(stakedToken, abi.encodeCall(IToken.allowance, (wallet, DRAINER))), (uint256));
        _expect(allowance == 0, "drainer has no allowance");
        _expect(_tokenBalance(usdc, RECIPIENT) == before, "payment reverted too");
    }

    /// @notice The Bybit hack (February 2025): the signed Safe transaction delegatecalled a contract that replaced the
    ///         Safe's implementation (slot 0) with the attacker's. The user requires slot 0 unchanged and no Safe
    ///         storage change other than the nonce.
    function preventBybitHack() public {
        _load("Prevent Bybit hack: the Safe's implementation and owners cannot change");
        bytes32[] memory allowed = new bytes32[](1);
        allowed[0] = SAFE_NONCE_SLOT;
        FrameTx.Frame memory transfer = _safeExec(usdc, abi.encodeCall(IToken.transfer, (RECIPIENT, 10e6)), 0);
        FrameTx.Frame memory slot0 =
            FrameTx.assertion(state, abi.encodeCall(IStateAssertion.slotUnchanged, (safe, SAFE_SINGLETON_SLOT)));
        FrameTx.Frame memory onlyNonce =
            FrameTx.assertion(state, abi.encodeCall(IStateAssertion.onlySlotsChanged, (safe, allowed)));
        address singleton = abi.decode(_read(safe, abi.encodeCall(ISafe.getSingleton, ())), (address));

        _send("Safe transfer of 10 USDC", _frames(transfer, slot0, onlyNonce));
        _expectFrames(_statuses(1, 1, 1, 1));

        uint256 before = _tokenBalance(usdc, RECIPIENT);
        FrameTx.Frame memory swap = _safeExec(takeover, abi.encodeWithSignature("swapSingleton(address)", DRAINER), 1);
        _send("Safe transfer + delegatecall swapping the implementation", _frames(transfer, swap, slot0, onlyNonce));
        _expectFrames(_statuses(1, 1, 1, 0, 2));
        _expect(
            abi.decode(_read(safe, abi.encodeCall(ISafe.getSingleton, ())), (address)) == singleton,
            "implementation unchanged"
        );
        _expect(_tokenBalance(usdc, RECIPIENT) == before, "transfer reverted too");

        FrameTx.Frame memory addOwner = _safeExec(takeover, abi.encodeWithSignature("addOwner(address)", DRAINER), 1);
        _send("Safe transfer + delegatecall adding an owner", _frames(transfer, addOwner, slot0, onlyNonce));
        _expectFrames(_statuses(1, 1, 1, 1, 0));
        _expect(
            !abi.decode(_read(safe, abi.encodeCall(ISafe.isOwner, (DRAINER))), (bool)),
            "slot 0 untouched, the allowlist caught the new owner"
        );
    }

    /// @notice Sell 100,000 USDC for WETH in two halves on two venues. The user wants at least 39 WETH in total,
    ///         whatever each venue pays: 18 + 23 passes, 18 + 20 reverts both swaps. Both limits are computed from the
    ///         tokens' Transfer events: WETH received by the wallet, USDC sent by it.
    function preventMinSwapOutput() public {
        _load("Prevent min swap output: at least 39 WETH in total for at most 100,000 USDC, across two venues");
        uint256 wethBefore = _tokenBalance(weth, wallet);
        _swapBoth("venue A (18 WETH) + venue B (23 WETH)", venueB);
        _expectFrames(_statuses(1, 1, 1, 1, 1, 1, 1));
        _expect(_tokenBalance(weth, wallet) - wethBefore == 41e18, "wallet received 41 WETH");

        uint256 usdcBefore = _tokenBalance(usdc, wallet);
        wethBefore = _tokenBalance(weth, wallet);
        _swapBoth("venue A (18 WETH) + venue C (20 WETH)", venueC);
        _expectFrames(_statuses(1, 1, 1, 1, 1, 1, 0));
        _expect(
            _tokenBalance(usdc, wallet) == usdcBefore && _tokenBalance(weth, wallet) == wethBefore,
            "both swaps reverted: USDC and WETH unchanged"
        );
    }

    function _swapBoth(string memory title, address second) internal {
        bytes memory swap = abi.encodeWithSignature("swap(address,uint256,address,uint256)", usdc, HALF, weth, 0);
        FrameTx.Frame[] memory f = new FrameTx.Frame[](6);
        f[0] = FrameTx.call(usdc, 0, abi.encodeCall(IToken.approve, (venueA, HALF)));
        f[1] = FrameTx.call(usdc, 0, abi.encodeCall(IToken.approve, (second, HALF)));
        f[2] = FrameTx.call(venueA, 0, swap);
        f[3] = FrameTx.call(second, 0, swap);
        f[4] = FrameTx.assertion(erc20, abi.encodeCall(IERC20Assertion.maxSpent, (usdc, wallet, 2 * HALF)));
        f[5] = FrameTx.assertion(erc20, abi.encodeCall(IERC20Assertion.minReceived, (weth, wallet, 39e18)));
        _send(title, f);
    }

    function _load(string memory title) internal {
        console.log("");
        console.log("==", title);
        if (wallet != address(0)) return;
        string memory m = _loadDeployment();
        usdc = vm.parseJsonAddress(m, ".usdc");
        weth = vm.parseJsonAddress(m, ".weth");
        stakedToken = vm.parseJsonAddress(m, ".stakedToken");
        safe = vm.parseJsonAddress(m, ".safe");
        takeover = vm.parseJsonAddress(m, ".takeover");
        venueA = vm.parseJsonAddress(m, ".venueA");
        venueB = vm.parseJsonAddress(m, ".venueB");
        venueC = vm.parseJsonAddress(m, ".venueC");
    }

    function _safeExec(address to, bytes memory data, uint8 operation) internal view returns (FrameTx.Frame memory) {
        return FrameTx.call(safe, 0, abi.encodeCall(ISafe.execTransaction, (to, 0, data, operation)));
    }

    /// @dev MockERC20 keeps `balanceOf` at slot 0, like OpenZeppelin's ERC20.
    function _balanceSlot(address holder) internal pure returns (bytes32) {
        return keccak256(abi.encode(holder, uint256(0)));
    }
}
