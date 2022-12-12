// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

interface IStargateRouterETH {
    function addLiquidity(uint256 _poolId, uint256 _amountLD, address _to) external;
}