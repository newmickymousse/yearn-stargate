// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ILPStaking {
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }
    struct PoolInfo {
        IERC20 lpToken;
        uint256 allocPoint;
        uint256 lastRewardBlock;
        uint256 accStargatePerShare;
    }

    function poolInfo(uint256 _index) external view returns (PoolInfo memory);
    function userInfo(uint256 _pid, address _user) external view returns (UserInfo memory);
    function stargate() external view returns (address);
    function eToken() external view returns (address); // The emission Token (if it's not STG, e.g. on Optimism)
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    function poolLength() external view returns (uint256);
    function pendingStargate(uint256 _pid, address _user) external view returns (uint256); // For Mainnet
    function pendingEmissionToken(uint256 _pid, address _user) external view returns (uint256); // For OP
    function deposit(uint256 _pid, uint256 _amount) external;
    function withdraw(uint256 _pid, uint256 _amount) external;
    function emergencyWithdraw(uint256 _pid) external;

}
