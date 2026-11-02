// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ITxTraceReader} from "../../contracts/shared/ITxTraceReader.sol";

/// @dev Address where tests etch a mock reader. Assertions under test are deployed with it.
ITxTraceReader constant TEST_READER =
    ITxTraceReader(address(uint160(uint256(keccak256("transaction-assertions.test.reader")))));
