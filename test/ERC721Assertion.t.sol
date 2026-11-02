// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC721Assertion} from "../contracts/assertions/ERC721Assertion.sol";
import {IERC721Assertion} from "../contracts/assertions/interfaces/IERC721Assertion.sol";
import {MockERC721, RawResponder} from "./mocks/MockTokens.sol";

contract ERC721AssertionTest is Test {
    ERC721Assertion internal assertions;
    MockERC721 internal nft;
    address internal collection;

    address internal constant USER = address(0xA11CE);
    address internal constant BUYER = address(0xB0B);
    address internal constant MARKET = address(0x3A2CE7);
    uint256 internal constant ID = 42;

    function setUp() public {
        assertions = new ERC721Assertion();
        nft = new MockERC721();
        collection = address(nft);
        nft.mint(USER, ID);
    }

    // ---------------------------------------------------------------------
    // assertOwner
    // ---------------------------------------------------------------------

    function test_ownerRetained() public view {
        assertions.assertOwner(collection, ID, USER);
    }

    function test_ownerTransferred() public {
        vm.prank(USER);
        nft.transferFrom(USER, BUYER, ID);
        assertions.assertOwner(collection, ID, BUYER);
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Assertion.OwnerAssertionFailed.selector, collection, ID, USER, BUYER)
        );
        assertions.assertOwner(collection, ID, USER);
    }

    function test_wrongExpectedOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC721Assertion.OwnerAssertionFailed.selector, collection, ID, BUYER, USER)
        );
        assertions.assertOwner(collection, ID, BUYER);
    }

    function test_wrongTokenIdReverts() public {
        vm.expectRevert("nonexistent");
        assertions.assertOwner(collection, ID + 1, USER);
    }

    function test_malformedOwnerOfReverts() public {
        RawResponder raw = new RawResponder();
        raw.setResponse(abi.encode(type(uint256).max), false); // dirty address
        vm.expectRevert();
        assertions.assertOwner(address(raw), ID, USER);
        raw.setResponse(abi.encodePacked(USER), false); // 20 bytes
        vm.expectRevert();
        assertions.assertOwner(address(raw), ID, USER);
    }

    // ---------------------------------------------------------------------
    // assertApproved
    // ---------------------------------------------------------------------

    function test_approvalGrantedAndRevoked() public {
        vm.prank(USER);
        nft.approve(MARKET, ID);
        assertions.assertApproved(collection, ID, MARKET);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC721Assertion.ApprovedAssertionFailed.selector, collection, ID, address(0), MARKET
            )
        );
        assertions.assertApproved(collection, ID, address(0));

        vm.prank(USER);
        nft.approve(address(0), ID);
        assertions.assertApproved(collection, ID, address(0));
    }

    /// @dev The transfer clears the approval without an Approval event; the state read sees it.
    function test_approvalClearedByTransfer() public {
        vm.prank(USER);
        nft.approve(MARKET, ID);
        vm.prank(MARKET);
        nft.transferFrom(USER, BUYER, ID);
        assertions.assertApproved(collection, ID, address(0));
    }

    // ---------------------------------------------------------------------
    // assertApprovedForAll
    // ---------------------------------------------------------------------

    function test_operatorApproval() public {
        assertions.assertApprovedForAll(collection, USER, MARKET, false);
        vm.prank(USER);
        nft.setApprovalForAll(MARKET, true);
        assertions.assertApprovedForAll(collection, USER, MARKET, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC721Assertion.ApprovedForAllAssertionFailed.selector, collection, USER, MARKET, false
            )
        );
        assertions.assertApprovedForAll(collection, USER, MARKET, false);
    }

    /// @dev Token approval and operator approval are separate permissions.
    function test_tokenApprovalDoesNotCoverOperator() public {
        vm.prank(USER);
        nft.setApprovalForAll(MARKET, true);
        assertions.assertApproved(collection, ID, address(0));
        vm.expectRevert();
        assertions.assertApprovedForAll(collection, USER, MARKET, false);
    }

    function test_nonCanonicalBoolReverts() public {
        RawResponder raw = new RawResponder();
        raw.setResponse(abi.encode(2), false);
        vm.expectRevert();
        assertions.assertApprovedForAll(address(raw), USER, MARKET, true);
    }
}
