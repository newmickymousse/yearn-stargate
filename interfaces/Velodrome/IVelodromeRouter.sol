// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.15;

interface IVelodromeRouter {
    struct Route {
        address from;
        address to;
        bool stable;
    }
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        Route[] calldata routes,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    function getAmountOut(
        uint256 amountIn,
        address tokenIn,
        address tokenOut
    ) external returns (uint256, bool);
}