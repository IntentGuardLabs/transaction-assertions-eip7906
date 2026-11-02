// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ITxTraceReader} from "../../contracts/shared/ITxTraceReader.sol";
import {ERC20Assertion} from "../../contracts/assertions/ERC20Assertion.sol";
import {NativeETHAssertion} from "../../contracts/assertions/NativeETHAssertion.sol";
import {MockTxTraceReader} from "../mocks/MockTxTraceReader.sol";
import {TEST_READER} from "../utils/TestReader.sol";

/// @notice TEST ONLY. Storage-free reader that derives a synthetic trace arithmetically, so per-query cost stays close
///         to a real reader call instead of being dominated by mock storage reads.
/// @dev Events `[0, noise)`: emitted by `NOISE_EMITTER`, or by the token with another topic0 if `noiseFromToken`.
///      Events `[noise, noise + transfers)`: token Transfers of 1 unit alternating into and out of `ACCOUNT`.
///      Balance and storage tables: `entries` rows, row `i` at address `(i + 1) << 80`, slot key `i`, before 2,
///      after 1.
contract SyntheticTraceReader is ITxTraceReader {
    bytes32 internal constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    address internal constant NOISE_EMITTER = address(0x401);
    address internal constant COUNTERPARTY = address(0xC0);

    address public immutable TOKEN;
    address public immutable ACCOUNT;
    uint256 public immutable NOISE;
    uint256 public immutable TRANSFERS;
    uint256 public immutable ENTRIES;
    bool public immutable NOISE_FROM_TOKEN;

    constructor(address token, address account, uint256 noise, uint256 transfers, uint256 entries, bool fromToken) {
        TOKEN = token;
        ACCOUNT = account;
        NOISE = noise;
        TRANSFERS = transfers;
        ENTRIES = entries;
        NOISE_FROM_TOKEN = fromToken;
    }

    function txtrace(uint256 param, uint256 in2) public view returns (uint256) {
        if (param == 0x11) return NOISE + TRANSFERS;
        if (param <= 0x03) return param <= 0x01 ? ENTRIES : 0;
        if (param == 0x04 || param == 0x07) return (in2 + 1) << 80;
        if (param == 0x05 || param == 0x08) return 2;
        if (param == 0x06 || param == 0x09) return 1;
        if (param == 0x0A) return in2;
        if (param >= 0x19) return 0;
        bool isTransfer = in2 >= NOISE;
        if (param == 0x12) return uint256(uint160(isTransfer || NOISE_FROM_TOKEN ? TOKEN : NOISE_EMITTER));
        if (param == 0x13) return isTransfer ? 3 : 1;
        if (param == 0x14) return isTransfer ? uint256(TRANSFER_TOPIC) : 1;
        if (param == 0x18) return isTransfer ? 32 : 0;
        bool incoming = (in2 - NOISE) % 2 == 0;
        if (param == 0x15) return uint256(uint160(incoming ? COUNTERPARTY : ACCOUNT));
        if (param == 0x16) return uint256(uint160(incoming ? ACCOUNT : COUNTERPARTY));
        revert();
    }

    function eventDataCopy(uint256, uint256, uint256) external pure returns (bytes memory) {
        return abi.encode(uint256(1));
    }
}

/// @notice Issues `n` single TXTRACE queries, or `n` reads of an entry's three fields, the way TxTrace does.
contract QueryLoop {
    function single(uint256 n) external view returns (uint256 acc) {
        for (uint256 i; i < n; ++i) {
            acc ^= TEST_READER.txtrace(0x12, i);
        }
    }

    function threeSingles(uint256 n) external view returns (uint256 acc) {
        for (uint256 i; i < n; ++i) {
            acc ^= TEST_READER.txtrace(0x04, i) ^ TEST_READER.txtrace(0x05, i) ^ TEST_READER.txtrace(0x06, i);
        }
    }
}

/// @notice Padding contract an adversarial execution body could call: emits `n` empty LOG0 events.
contract LogPadder {
    function pad(uint256 n) external {
        for (uint256 i; i < n; ++i) {
            assembly {
                log0(0, 0)
            }
        }
    }
}

/// @notice Gas measurements behind docs/EIP-7906-implementation-feedback.md.
/// @dev Run with `forge test --match-path "test/gas/*" -vv`. Synthetic-reader figures include the reader's own
///      dispatch and are estimates; `test_gas_perQueryWithProductionReader` measures the production reader bytecode.
contract EventScanGasTest is Test {
    address internal constant TOKEN = address(0x7070);
    address internal constant ACCOUNT = address(0xA11CE);
    address internal constant READER = address(TEST_READER);

    function _install(uint256 noise, uint256 transfers, uint256 entries, bool noiseFromToken) internal {
        vm.etch(
            READER, address(new SyntheticTraceReader(TOKEN, ACCOUNT, noise, transfers, entries, noiseFromToken)).code
        );
        ITxTraceReader(READER).txtrace(0x11, 0); // warm, as after an ASSERT frame's first query
    }

    function _maxSpentGas(uint256 noise, uint256 transfers, bool noiseFromToken) internal returns (uint256 used) {
        _install(noise, transfers, 0, noiseFromToken);
        ERC20Assertion a = new ERC20Assertion(TEST_READER);
        uint256 start = gasleft();
        a.maxSpent(TOKEN, ACCOUNT, 1);
        used = start - gasleft();
    }

    /// @dev The production reader with TXTRACE patched to SUB (3 gas); add 97 per query for TXTRACE (100).
    function _installPatchedProductionReader() internal {
        string memory artifact = vm.readFile("out/TxTraceReader.yul/TxTraceReader.json");
        bytes memory code = vm.parseJsonBytes(artifact, ".deployedBytecode.object");
        for (uint256 pc; pc < code.length; ++pc) {
            uint8 op = uint8(code[pc]);
            if (op == 0xb6) code[pc] = 0x03;
            else if (op >= 0x60 && op <= 0x7f) pc += op - 0x5f;
        }
        vm.etch(READER, code);
    }

    // ---------------------------------------------------------------------
    // Cost of TXTRACE queries from Solidity
    // ---------------------------------------------------------------------

    function test_gas_perQueryWithProductionReader() public {
        _installPatchedProductionReader();
        QueryLoop loop = new QueryLoop();
        loop.single(1);
        uint256 n = 1000;

        uint256 start = gasleft();
        loop.single(n);
        uint256 perQuery = (start - gasleft()) / n + 97;

        start = gasleft();
        loop.threeSingles(n);
        uint256 threeSingles = (start - gasleft()) / n + 3 * 97;

        console.log("Gas per TXTRACE query through TxTraceReader.yul:  %d (TXTRACE itself: 100)", perQuery);
        console.log("Gas for 3 fields of one entry, 3 single calls:   %d (TXTRACE itself: 300)", threeSingles);
        assertLt(perQuery, 1000);
    }

    // ---------------------------------------------------------------------
    // Event scans
    // ---------------------------------------------------------------------

    function test_gas_eventScan() public {
        uint256 perUnrelated = (_maxSpentGas(5000, 2, false) - _maxSpentGas(0, 2, false)) / 5000;
        uint256 perSameEmitter = (_maxSpentGas(2000, 2, true) - _maxSpentGas(0, 2, true)) / 2000;
        uint256 perTransfer = (_maxSpentGas(0, 1000, false) - _maxSpentGas(0, 0, false)) / 1000;
        console.log("ERC20Assertion.maxSpent, synthetic reader, marginal gas per event:");
        console.log("  event from another contract      %d", perUnrelated);
        console.log("  token event with another topic0  %d", perSameEmitter);
        console.log("  matching Transfer                %d", perTransfer);
        console.log("  x 42,600 unrelated events (EIP-7906 worst case) = %d", perUnrelated * 42_600);
    }

    // ---------------------------------------------------------------------
    // Sorted tables
    // ---------------------------------------------------------------------

    function test_gas_sortedTableLookups() public {
        uint256[4] memory sizes = [uint256(1), 100, 1000, 10_000];
        console.log("Lookup cost vs table size (binary search, synthetic reader):");
        for (uint256 i; i < sizes.length; ++i) {
            _install(0, 0, sizes[i], false);
            NativeETHAssertion eth = new NativeETHAssertion(TEST_READER);
            ERC20Assertion erc20 = new ERC20Assertion(TEST_READER);
            address last = address(uint160(sizes[i] << 80));
            uint256 start = gasleft();
            eth.netChange(last);
            uint256 ethGas = start - gasleft();
            start = gasleft();
            erc20.slotNetChange(last, bytes32(sizes[i] - 1));
            uint256 slotGas = start - gasleft();
            console.log("  entries=%d NativeETH.netChange=%d ERC20.slotNetChange=%d", sizes[i], ethGas, slotGas);
        }
    }

    // ---------------------------------------------------------------------
    // Padding: what the body pays vs what an event-scanning assertion pays
    // ---------------------------------------------------------------------

    /// @dev Per padding event the assertion pays one TXTRACE query (the emitter) plus its own loop overhead L.
    ///      L = (per-event cost with the synthetic reader) - (per-query cost of the synthetic reader). The production
    ///      and native figures substitute the measured production query cost (`test_gas_perQueryWithProductionReader`)
    ///      and the bare TXTRACE cost (100) for the query.
    function test_gas_paddingCostRatio() public {
        LogPadder padder = new LogPadder();
        padder.pad(1);
        uint256 start = gasleft();
        padder.pad(1000);
        uint256 attackerPerEvent = (start - gasleft()) / 1000;

        uint256 defenderPerEvent = (_maxSpentGas(5000, 0, false) - _maxSpentGas(0, 0, false)) / 5000;
        _install(5000, 0, 0, false);
        QueryLoop loop = new QueryLoop();
        loop.single(1);
        start = gasleft();
        loop.single(1000);
        uint256 syntheticQuery = (start - gasleft()) / 1000;
        uint256 loopOverhead = defenderPerEvent - syntheticQuery;

        console.log("Execution body, gas per empty LOG0 padding event:     %d", attackerPerEvent);
        console.log("Assertion loop overhead per event, excluding query:  %d", loopOverhead);
        console.log("Assertion per padding event, synthetic reader:       %d", defenderPerEvent);
        console.log("Assertion per padding event, native TXTRACE (est.):  %d", loopOverhead + 100);
    }

    // ---------------------------------------------------------------------
    // Out of gas never passes
    // ---------------------------------------------------------------------

    function test_outOfGasDuringScanReverts() public {
        _install(5000, 2, 0, false);
        ERC20Assertion a = new ERC20Assertion(TEST_READER);
        bytes memory data = abi.encodeCall(ERC20Assertion.maxSpent, (TOKEN, ACCOUNT, type(uint256).max));
        (bool ok,) = address(a).call{gas: 300_000}(data);
        assertFalse(ok, "partial scan must not pass");
        (ok,) = address(a).call{gas: 30_000_000}(data);
        assertTrue(ok);
    }

    /// @dev A loss hidden in the last event can never pass, whatever the gas limit.
    function testFuzz_outOfGasNeverPasses(uint24 gasLimit) public {
        vm.etch(READER, address(new MockTxTraceReader()).code);
        MockTxTraceReader trace = MockTxTraceReader(READER);
        bytes32[] memory noiseTopics = new bytes32[](1);
        for (uint256 i; i < 200; ++i) {
            trace.pushEvent(address(0x401), noiseTopics, "");
        }
        bytes32[] memory t = new bytes32[](3);
        t[0] = keccak256("Transfer(address,address,uint256)");
        t[1] = bytes32(uint256(uint160(ACCOUNT)));
        t[2] = bytes32(uint256(0xC0));
        trace.pushEvent(TOKEN, t, abi.encode(uint256(100)));
        ERC20Assertion a = new ERC20Assertion(TEST_READER);

        (bool ok,) = address(a).call{gas: gasLimit}(abi.encodeCall(ERC20Assertion.maxSpent, (TOKEN, ACCOUNT, 0)));
        assertFalse(ok);
    }
}
