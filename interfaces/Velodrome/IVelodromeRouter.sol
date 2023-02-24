// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

interface IVelodromeRouter {
    function swapExactTokensForTokensSimple(
        uint amountIn,
        uint amountOutMin,
        address tokenFrom,
        address tokenTo,
        bool stable,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    function getAmountOut(
        uint256 amountIn,
        address tokenIn,
        address tokenOut
    ) external returns (uint256, bool);
}