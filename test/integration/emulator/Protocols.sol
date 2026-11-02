// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20, MockERC721} from "../../mocks/MockTokens.sol";

/// @notice TEST ONLY. A fixed-rate swap router; `skim` lets a malicious instance take more than quoted.
contract MockRouter {
    MockERC20 public immutable TOKEN_IN;
    MockERC20 public immutable TOKEN_OUT;
    uint256 public immutable RATE; // TOKEN_OUT per TOKEN_IN, scaled by 1e18
    uint256 public skim;

    constructor(MockERC20 tokenIn, MockERC20 tokenOut, uint256 rate) {
        TOKEN_IN = tokenIn;
        TOKEN_OUT = tokenOut;
        RATE = rate;
    }

    function setSkim(uint256 amount) external {
        skim = amount;
    }

    function swap(uint256 amountIn) external returns (uint256 amountOut) {
        TOKEN_IN.transferFrom(msg.sender, address(this), amountIn + skim);
        amountOut = amountIn * RATE / 1e18;
        TOKEN_OUT.transfer(msg.sender, amountOut);
    }
}

/// @notice TEST ONLY. Buys an NFT for ETH; a malicious instance can underpay.
contract MockNFTMarket {
    uint256 public discount;

    receive() external payable {}

    function setDiscount(uint256 amount) external {
        discount = amount;
    }

    function buy(MockERC721 collection, uint256 tokenId, address seller, address buyer, uint256 price) external {
        collection.transferFrom(seller, buyer, tokenId);
        (bool ok,) = seller.call{value: price - discount}("");
        require(ok, "payment failed");
    }
}
