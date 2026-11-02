// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ITxTraceReader} from "../../contracts/shared/ITxTraceReader.sol";
import {TxTrace} from "../../contracts/shared/TxTrace.sol";

/// @notice Gas benchmarks only (script/GasBenchmarks.s.sol). Body helper: `logs` empty LOG0 events, `slots` fresh storage writes, 1 wei to each payee.
contract TraceNoise {
    mapping(uint256 => uint256) public slot;
    uint256 public cursor;

    function run(uint256 logs, uint256 slots, address[] calldata payees) external payable {
        for (uint256 i = 0; i < logs; i++) {
            assembly {
                log0(0, 0)
            }
        }
        uint256 c = cursor;
        for (uint256 i = 0; i < slots; i++) {
            slot[c + i] = 1;
        }
        cursor = c + slots;
        for (uint256 i = 0; i < payees.length; i++) {
            (bool ok,) = payees[i].call{value: 1}("");
            require(ok, "payee");
        }
    }
}

/// @notice Gas benchmarks only. Each function is one access pattern, measured as one ASSERT frame's gas.
contract TraceBench is TxTrace {
    constructor(ITxTraceReader reader) TxTrace(reader) {}

    function nop() external pure {}

    function ethLookup(address account) external view returns (bool changed) {
        (changed,,) = balanceChange(account);
    }

    function slotLookup(address account, bytes32 slot) external view returns (bool changed) {
        (changed,,) = storageChange(account, slot);
    }

    /// @notice `n` raw TXTRACE reads: the cost of one query through the reader.
    function queries(uint256 n) external view returns (uint256 acc) {
        for (uint256 i = 0; i < n; i++) {
            acc ^= traceReader.txtrace(EVENTS_COUNT, 0);
        }
    }
}
