// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {NativeETHAssertion} from "../../contracts/assertions/NativeETHAssertion.sol";
import {ERC20Assertion} from "../../contracts/assertions/ERC20Assertion.sol";
import {IERC20Assertion} from "../../contracts/assertions/interfaces/IERC20Assertion.sol";
import {INativeETHAssertion} from "../../contracts/assertions/interfaces/INativeETHAssertion.sol";
import {MockERC20, UnderReportingFeeERC20, SilentRebasingERC20, MisleadingERC20} from "../mocks/MockTokens.sol";
import {FrameTxEmulator} from "./emulator/FrameTxEmulator.sol";
import {EmulatedAccount} from "./emulator/EmulatedAccount.sol";
import {MockRouter} from "./emulator/Protocols.sol";
import {TEST_READER} from "../utils/TestReader.sol";

/// @notice End-to-end scenarios on the frame-transaction EMULATOR (see FrameTxEmulator for what is and is not
///         emulated). Real token contracts run in the body; the ASSERT frames read a trace built from the logs and
///         the storage and balance diff of that run. Mock tokens keep `balanceOf` at storage slot 0, so a holder's
///         balance slot is `keccak256(abi.encode(holder, uint256(0)))`.
contract FrameTransactionEmulationTest is FrameTxEmulator {
    NativeETHAssertion internal eth;
    ERC20Assertion internal erc20;

    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockRouter internal router;
    EmulatedAccount internal account;

    uint256 internal ownerKey = 0xA11CE;
    uint256 internal sessionKey = 0x5E5510;
    uint256 internal constant PRE_CHARGE = 0.01 ether;
    uint256 internal constant SESSION_LIMIT = 0.5 ether;

    function setUp() public {
        _setUpEmulator();
        eth = new NativeETHAssertion(TEST_READER);
        erc20 = new ERC20Assertion(TEST_READER);

        usdc = new MockERC20();
        weth = new MockERC20();
        router = new MockRouter(usdc, weth, 0.0004e18 * 1e12); // 1 USDC (6 dp) -> 0.0004 WETH (18 dp)
        weth.mint(address(router), 1000 ether);

        // The session key may only sign transactions that cap ETH spending (excluding gas) at SESSION_LIMIT.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        account = new EmulatedAccount(
            vm.addr(ownerKey),
            vm.addr(sessionKey),
            address(eth),
            abi.encodeCall(INativeETHAssertion.maxSpent, (predicted, SESSION_LIMIT))
        );
        assertEq(address(account), predicted);

        usdc.mint(address(account), 1000e6);
        vm.deal(address(account), 10 ether);
        _watch(address(account));
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _balanceSlot(address holder) internal pure returns (bytes32) {
        return keccak256(abi.encode(holder, uint256(0)));
    }

    function _senderCall(address target, uint256 value, bytes memory data) internal view returns (Frame memory) {
        return Frame(MODE_SENDER, address(account), 0, abi.encodeCall(EmulatedAccount.execute, (target, value, data)));
    }

    function _assert(address target, bytes memory data) internal pure returns (Frame memory) {
        return Frame(MODE_ASSERT, target, 0, data);
    }

    function _signed(Frame[] memory frames, uint256 key) internal view returns (FrameTx memory t) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, account.sigHash(frames));
        t.sender = address(account);
        t.payer = address(account);
        t.preCharge = PRE_CHARGE;
        t.frames = new Frame[](frames.length + 1);
        t.frames[0] = Frame(MODE_VERIFY, address(account), 0, abi.encode(v, r, s));
        for (uint256 i; i < frames.length; ++i) {
            t.frames[i + 1] = frames[i];
        }
    }

    /// @dev Swap USDC -> WETH, protected by: USDC spent <= amountIn (events and storage), WETH received >= minOut,
    ///      no unexpected USDC approval, no ETH spent.
    function _swapFrames(uint256 approveAmount, uint256 amountIn, uint256 minOut, address[] memory allowedSpenders)
        internal
        view
        returns (Frame[] memory f)
    {
        f = new Frame[](7);
        f[0] = _senderCall(address(usdc), 0, abi.encodeCall(MockERC20.approve, (address(router), approveAmount)));
        f[1] = _senderCall(address(router), 0, abi.encodeCall(MockRouter.swap, (amountIn)));
        f[2] = _assert(
            address(erc20), abi.encodeCall(IERC20Assertion.maxSpent, (address(usdc), address(account), amountIn))
        );
        f[3] = _assert(
            address(erc20),
            abi.encodeCall(IERC20Assertion.maxSpentAtSlot, (address(usdc), _balanceSlot(address(account)), amountIn))
        );
        f[4] = _assert(
            address(erc20), abi.encodeCall(IERC20Assertion.minReceived, (address(weth), address(account), minOut))
        );
        f[5] = _assert(
            address(erc20),
            abi.encodeCall(IERC20Assertion.noUnexpectedApprovals, (address(usdc), address(account), allowedSpenders))
        );
        f[6] = _assert(address(eth), abi.encodeCall(INativeETHAssertion.maxSpent, (address(account), 0)));
    }

    function _routerOnly() internal view returns (address[] memory list) {
        list = new address[](1);
        list[0] = address(router);
    }

    // ---------------------------------------------------------------------
    // Swap
    // ---------------------------------------------------------------------

    function test_swapSucceeds() public {
        Result memory r = _execute(_signed(_swapFrames(100e6, 100e6, 0.04 ether, _routerOnly()), ownerKey));
        assertTrue(r.valid);
        assertTrue(r.assertionsPassed);
        assertEq(usdc.balanceOf(address(account)), 900e6);
        assertEq(weth.balanceOf(address(account)), 0.04 ether);
        assertEq(address(account).balance, 10 ether - PRE_CHARGE, "pre-charge only, not counted as spent");
        (uint256 gain, uint256 loss) = erc20.slotNetChange(address(usdc), _balanceSlot(address(account)));
        assertEq(gain, 0);
        assertEq(loss, 100e6);
    }

    function test_overspendingRouterRevertsBodyKeepsGas() public {
        router.setSkim(50e6);
        Result memory r = _execute(_signed(_swapFrames(150e6, 100e6, 0.04 ether, _routerOnly()), ownerKey));
        assertTrue(r.valid);
        assertFalse(r.assertionsPassed);
        assertEq(r.failedFrame, 3);
        assertEq(
            r.failure,
            abi.encodeWithSelector(
                IERC20Assertion.MaxSpentExceeded.selector, address(usdc), address(account), 100e6, 0, 150e6
            )
        );
        assertEq(usdc.balanceOf(address(account)), 1000e6, "body undone");
        assertEq(address(account).balance, 10 ether - PRE_CHARGE, "gas payment kept");
    }

    function test_insufficientOutputReverts() public {
        Result memory r = _execute(_signed(_swapFrames(100e6, 100e6, 0.05 ether, _routerOnly()), ownerKey));
        assertFalse(r.assertionsPassed);
        assertEq(r.failedFrame, 5);
    }

    function test_unexpectedSpenderApprovalReverts() public {
        Result memory r = _execute(_signed(_swapFrames(100e6, 100e6, 0.04 ether, new address[](0)), ownerKey));
        assertFalse(r.assertionsPassed);
        assertEq(r.failedFrame, 6);
        assertEq(usdc.allowance(address(account), address(router)), 0);
    }

    /// @dev increaseAllowance emits Approval with the new total; an allowed spender may be increased.
    function test_approvalIncreaseForAllowedSpender() public {
        Frame[] memory f = new Frame[](3);
        f[0] = _senderCall(address(usdc), 0, abi.encodeCall(MockERC20.approve, (address(router), 1)));
        f[1] = _senderCall(address(usdc), 0, abi.encodeCall(MockERC20.increaseAllowance, (address(router), 99)));
        f[2] = _assert(
            address(erc20),
            abi.encodeCall(IERC20Assertion.noUnexpectedApprovals, (address(usdc), address(account), _routerOnly()))
        );
        assertTrue(_execute(_signed(f, ownerKey)).assertionsPassed);
        assertEq(usdc.allowance(address(account), address(router)), 100);
    }

    // ---------------------------------------------------------------------
    // ETH and account-side enforcement
    // ---------------------------------------------------------------------

    function _sessionFrames(uint256 amount, bool includeRequiredAssert) internal view returns (Frame[] memory f) {
        f = new Frame[](includeRequiredAssert ? 2 : 1);
        f[0] = _senderCall(address(0xCAFE), amount, "");
        if (includeRequiredAssert) {
            f[1] =
                _assert(address(eth), abi.encodeCall(INativeETHAssertion.maxSpent, (address(account), SESSION_LIMIT)));
        }
    }

    function test_sessionKeyWithoutRequiredAssertFrameIsInvalid() public {
        Result memory r = _execute(_signed(_sessionFrames(5 ether, false), sessionKey));
        assertFalse(r.valid);
        assertEq(address(account).balance, 10 ether, "nothing executed, nothing charged");
    }

    function test_sessionKeyOverLimitReverts() public {
        Result memory r = _execute(_signed(_sessionFrames(5 ether, true), sessionKey));
        assertTrue(r.valid);
        assertFalse(r.assertionsPassed);
        assertEq(
            r.failure,
            abi.encodeWithSelector(
                INativeETHAssertion.MaxSpentExceeded.selector, address(account), SESSION_LIMIT, 0, 5 ether
            )
        );
        assertEq(address(0xCAFE).balance, 0);
    }

    function test_sessionKeyWithinLimitSucceeds() public {
        assertTrue(_execute(_signed(_sessionFrames(0.4 ether, true), sessionKey)).assertionsPassed);
        assertEq(address(0xCAFE).balance, 0.4 ether);
    }

    function test_tamperedAssertFrameInvalidatesSignature() public {
        FrameTx memory t = _signed(_sessionFrames(5 ether, true), ownerKey);
        t.frames[2].data = abi.encodeCall(INativeETHAssertion.maxSpent, (address(account), type(uint256).max));
        assertFalse(_execute(t).valid);
    }

    // ---------------------------------------------------------------------
    // Where events and storage disagree
    // ---------------------------------------------------------------------

    function _receiveFrames(MockERC20 token, uint256 amount) internal view returns (Frame[] memory f) {
        f = new Frame[](3);
        f[0] = Frame(
            MODE_DEFAULT,
            address(token),
            0,
            abi.encodeCall(MockERC20.transferFrom, (address(0xF00), address(account), amount))
        );
        f[1] = _assert(
            address(erc20), abi.encodeCall(IERC20Assertion.minReceived, (address(token), address(account), amount))
        );
        f[2] = _assert(
            address(erc20),
            abi.encodeCall(IERC20Assertion.minReceivedAtSlot, (address(token), _balanceSlot(address(account)), amount))
        );
    }

    /// @dev The token credits 99 but reports 100: the event check passes, the storage check catches it.
    function test_feeOnTransfer() public {
        UnderReportingFeeERC20 token = new UnderReportingFeeERC20();
        token.mint(address(0xF00), 100e6);
        vm.prank(address(0xF00));
        token.approve(address(0xaa), type(uint256).max); // ENTRY_POINT pulls in the DEFAULT frame
        Result memory r = _execute(_signed(_receiveFrames(token, 100e6), ownerKey));
        assertFalse(r.assertionsPassed);
        assertEq(r.failedFrame, 3, "event check (frame 2) passed; storage check (frame 3) failed");
        assertEq(
            r.failure,
            abi.encodeWithSelector(
                IERC20Assertion.SlotMinReceivedNotMet.selector,
                address(token),
                _balanceSlot(address(account)),
                100e6,
                99e6,
                0
            )
        );
    }

    /// @dev A balance change without events: invisible to the event check, caught by the storage check.
    function test_rebaseWithoutEvents() public {
        SilentRebasingERC20 token = new SilentRebasingERC20();
        token.mint(address(account), 100e6);
        Frame[] memory f = new Frame[](3);
        f[0] = Frame(MODE_DEFAULT, address(token), 0, abi.encodeCall(SilentRebasingERC20.rebase, (address(account), 0)));
        f[1] = _assert(
            address(erc20), abi.encodeCall(IERC20Assertion.balanceUnchanged, (address(token), address(account)))
        );
        f[2] = _assert(
            address(erc20),
            abi.encodeCall(IERC20Assertion.balanceUnchangedAtSlot, (address(token), _balanceSlot(address(account))))
        );
        Result memory r = _execute(_signed(f, ownerKey));
        assertFalse(r.assertionsPassed);
        assertEq(r.failedFrame, 3, "event check passed; storage check failed");
    }

    /// @dev A Transfer event with no balance change: the event check is fooled, the storage check is not.
    function test_misleadingEvent() public {
        MisleadingERC20 token = new MisleadingERC20();
        Frame[] memory f = new Frame[](3);
        f[0] = Frame(
            MODE_DEFAULT,
            address(token),
            0,
            abi.encodeCall(MisleadingERC20.fakeTransfer, (address(0xF00), address(account), 100e6))
        );
        f[1] = _assert(
            address(erc20), abi.encodeCall(IERC20Assertion.minReceived, (address(token), address(account), 100e6))
        );
        f[2] = _assert(
            address(erc20),
            abi.encodeCall(IERC20Assertion.minReceivedAtSlot, (address(token), _balanceSlot(address(account)), 100e6))
        );
        Result memory r = _execute(_signed(f, ownerKey));
        assertFalse(r.assertionsPassed);
        assertEq(r.failedFrame, 3);
    }

    /// @dev Limitation: an allowance set without an Approval event is invisible to noUnexpectedApprovals.
    function test_limitation_silentApproval() public {
        MisleadingERC20 token = new MisleadingERC20();
        Frame[] memory f = new Frame[](2);
        f[0] = Frame(
            MODE_DEFAULT,
            address(token),
            0,
            abi.encodeCall(MisleadingERC20.silentApprove, (address(account), address(0xBAD), 1e30))
        );
        f[1] = _assert(
            address(erc20),
            abi.encodeCall(IERC20Assertion.noUnexpectedApprovals, (address(token), address(account), new address[](0)))
        );
        Result memory r = _execute(_signed(f, ownerKey));
        assertTrue(r.assertionsPassed, "not detectable from events");
        assertEq(token.allowance(address(account), address(0xBAD)), 1e30);
    }
}
