// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAssertion
/// @notice Base interface of every assertion. An ASSERT frame's `data` is a call to one `view` check whose limits
///         are its arguments, so the transaction signature covers them. A check returns if it holds and reverts
///         with the observed values otherwise.
interface IAssertion {
    /// @notice ERC-165.
    function supportsInterface(bytes4 interfaceId) external view returns (bool);

    function version() external pure returns (string memory);
}
