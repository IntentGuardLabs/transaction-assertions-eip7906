// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAssertion} from "./interfaces/IAssertion.sol";

/// @title Assertion
/// @notice Shared `IAssertion` implementation. Concrete assertions add their own interface id.
abstract contract Assertion is IAssertion {
    function supportsInterface(bytes4 interfaceId) public view virtual returns (bool) {
        return interfaceId == type(IAssertion).interfaceId || interfaceId == 0x01ffc9a7; // ERC-165
    }

    function version() external pure returns (string memory) {
        return "0.1.0";
    }
}
