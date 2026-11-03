// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20Like {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice A venue that pays a fixed amount of `tokenOut` per swap, set at deployment. Reverts below the caller's
///         minimum, as a router with per-swap slippage protection would.
contract MockVenue {
    error Slippage(uint256 out, uint256 minOut);

    uint256 public quote;

    function setQuote(uint256 amountOut) external {
        quote = amountOut;
    }

    function swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 minOut) external returns (uint256 out) {
        out = quote;
        if (out < minOut) revert Slippage(out, minOut);
        require(IERC20Like(tokenIn).transferFrom(msg.sender, address(this), amountIn), "transferFrom failed");
        require(IERC20Like(tokenOut).transfer(msg.sender, out), "transfer failed");
    }
}
