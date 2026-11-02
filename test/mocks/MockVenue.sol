// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice A venue that pays a fixed ETH amount per swap, set by the test. Reverts below the caller's minimum, as a
///         router with per-swap slippage protection would.
contract MockVenue {
    error Slippage(uint256 out, uint256 minOut);

    uint256 public quote;

    function setQuote(uint256 ethOut) external {
        quote = ethOut;
    }

    function swap(address token, uint256 amountIn, uint256 minOut) external returns (uint256 out) {
        out = quote;
        if (out < minOut) revert Slippage(out, minOut);
        (bool ok, bytes memory ret) =
            token.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", msg.sender, this, amountIn));
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "transferFrom failed");
        (ok,) = msg.sender.call{value: out}("");
        require(ok, "ETH transfer failed");
    }

    receive() external payable {}
}
