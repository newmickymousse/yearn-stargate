// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

interface IPool {
    function poolId() external view returns (uint256);
    function token() external view returns (address);
    function router() external view returns (address);
    function totalLiquidity() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function convertRate() external view returns (uint256);
    function amountLPtoLD(uint256 _amountLP) external view returns (uint256);
}
