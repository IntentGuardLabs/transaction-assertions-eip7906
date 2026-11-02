// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAssertion} from "./IAssertion.sol";

/// @title IERC721Assertion
/// @notice ERC-721 checks read by calling the collection, not from the trace: transfers clear approvals without
///         necessarily emitting `Approval`, so events cannot tell the final approval state.
interface IERC721Assertion is IAssertion {
    error OwnerAssertionFailed(address collection, uint256 tokenId, address expectedOwner, address owner);
    error ApprovedAssertionFailed(address collection, uint256 tokenId, address expectedSpender, address approved);
    error ApprovedForAllAssertionFailed(address collection, address owner, address operator, bool expected);

    /// @notice Requires `ownerOf(tokenId) == expectedOwner`. Reverts as well if the token does not exist.
    function assertOwner(address collection, uint256 tokenId, address expectedOwner) external view;

    /// @notice Requires `getApproved(tokenId) == expectedSpender`; `address(0)` means no token approval.
    function assertApproved(address collection, uint256 tokenId, address expectedSpender) external view;

    /// @notice Requires `isApprovedForAll(owner, operator) == expected`.
    function assertApprovedForAll(address collection, address owner, address operator, bool expected) external view;
}
