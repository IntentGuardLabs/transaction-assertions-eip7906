// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Assertion} from "./Assertion.sol";
import {IAssertion} from "./interfaces/IAssertion.sol";
import {IERC721Assertion} from "./interfaces/IERC721Assertion.sol";

/// @dev The ERC-721 view functions this contract reads.
interface IERC721View {
    function ownerOf(uint256 tokenId) external view returns (address);
    function getApproved(uint256 tokenId) external view returns (address);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
}

/// @title ERC721Assertion
/// @notice ERC-721 checks read from the collection's final state. Trusts the collection to report it.
contract ERC721Assertion is Assertion, IERC721Assertion {
    function assertOwner(address collection, uint256 tokenId, address expectedOwner) external view {
        address owner = IERC721View(collection).ownerOf(tokenId);
        if (owner != expectedOwner) revert OwnerAssertionFailed(collection, tokenId, expectedOwner, owner);
    }

    function assertApproved(address collection, uint256 tokenId, address expectedSpender) external view {
        address approved = IERC721View(collection).getApproved(tokenId);
        if (approved != expectedSpender) {
            revert ApprovedAssertionFailed(collection, tokenId, expectedSpender, approved);
        }
    }

    function assertApprovedForAll(address collection, address owner, address operator, bool expected) external view {
        if (IERC721View(collection).isApprovedForAll(owner, operator) != expected) {
            revert ApprovedForAllAssertionFailed(collection, owner, operator, expected);
        }
    }

    function supportsInterface(bytes4 interfaceId) public view override(Assertion, IAssertion) returns (bool) {
        return interfaceId == type(IERC721Assertion).interfaceId || super.supportsInterface(interfaceId);
    }
}
