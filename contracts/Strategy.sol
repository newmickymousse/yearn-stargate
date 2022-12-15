// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.15;

import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IERC20Metadata.sol";
import "../interfaces/IWETH.sol";
import "../interfaces/ISGETH.sol";
import "../interfaces/Stargate/IStargateRouter.sol";
import "../interfaces/Stargate/IStargateRouterETH.sol";
import "../interfaces/Stargate/IPool.sol";
import "../interfaces/Stargate/ILPStaking.sol";
import "./ySwaps/ITradeFactory.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    struct lzTxObj {
        uint256 dstGasForCall;
        uint256 dstNativeAmount;
        bytes dstNativeAddr;
    }

    uint256 private constant max = type(uint256).max;
    bool internal isOriginal = true;

    address public tradeFactory;

    uint256 public liquidityPoolID; // @note Main Pool ID
    uint256 public liquidityPoolIDInLPStaking; // @note Pool ID for LPStaking

    IERC20 public reward;
    IPool public liquidityPool;
    IERC20 public lpToken;
    IStargateRouter public stargateRouter;
    IStargateRouterETH public stargateRouterETH;
    ILPStaking public lpStaker;

    string internal strategyName;
    bool public wantIsWETH;
    bool public emissionTokenIsSTG;

    bool internal unstakeLPOnMigration;

    constructor(
        address _vault,
        address _lpStaker,
        uint16 _liquidityPoolIDInLPStaking,
        bool _wantIsWETH,
        bool _emissionTokenIsSTG
    ) public BaseStrategy(_vault) {
        _initializeStrategy(_lpStaker, _liquidityPoolIDInLPStaking, _wantIsWETH, _emissionTokenIsSTG);
    }

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _lpStaker,
        uint16 _liquidityPoolIDInLPStaking,
        bool _wantIsWETH,
        bool _emissionTokenIsSTG
    ) public {
        require(address(lpStaker) == address(0)); // @note Only initialize once

        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrategy(_lpStaker, _liquidityPoolIDInLPStaking, _wantIsWETH, _emissionTokenIsSTG);
    }

    function _initializeStrategy(
        address _lpStaker,
        uint16 _liquidityPoolIDInLPStaking,
        bool _wantIsWETH,
        bool _emissionTokenIsSTG
    ) internal {
        lpStaker = ILPStaking(_lpStaker);
        emissionTokenIsSTG = _emissionTokenIsSTG;
        if (emissionTokenIsSTG) {
            reward = IERC20(lpStaker.stargate());
        } else {
            reward = IERC20(lpStaker.eToken());
        }

        liquidityPoolIDInLPStaking = _liquidityPoolIDInLPStaking;
        lpToken = lpStaker.poolInfo(_liquidityPoolIDInLPStaking).lpToken;
        liquidityPool = IPool(address(lpToken));
        liquidityPoolID = liquidityPool.poolId();
        stargateRouter = IStargateRouter(liquidityPool.router());
        lpToken.safeApprove(address(lpStaker), max);
        wantIsWETH = _wantIsWETH;
        if (wantIsWETH == false) {
            require(address(want) == liquidityPool.token());
        } else {
            require(liquidityPoolID == 13); // @note PoolID == 13 for ETH pool on mainnet, Optimism, Arbitrum
        }
        unstakeLPOnMigration = true;
    }

    event Cloned(address indexed clone);

    function clone(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _lpStaker,
        uint16 _liquidityPoolIDInLPStaking,
        bool _wantIsWETH,
        bool _emissionTokenIsSTG
    ) external returns (address payable newStrategy) {
        require(isOriginal);

        bytes20 addressBytes = bytes20(address(this));

        assembly {
            let clone_code := mload(0x40)
            mstore(clone_code, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(add(clone_code, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            newStrategy := create(0, clone_code, 0x37)
        }

        Strategy(newStrategy).initialize(
            _vault,
            _strategist,
            _rewards,
            _keeper,
            _lpStaker,
            _liquidityPoolIDInLPStaking,
            _wantIsWETH,
            _emissionTokenIsSTG
        );

        emit Cloned(newStrategy);
    }

    function name() external view override returns (string memory) {
        return string(abi.encodePacked("Stargate-v3-", IERC20Metadata(address(want)).symbol())); // @note check if interface is working
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant() + valueOfLPTokens();
    }

    function pendingRewards() public view returns (uint256) {
        if (emissionTokenIsSTG) {
            return lpStaker.pendingStargate(liquidityPoolIDInLPStaking, address(this));
        } else {
            return lpStaker.pendingEmissionToken(liquidityPoolIDInLPStaking, address(this));
        }
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (uint256 _profit, uint256 _loss, uint256 _debtPayment)
    {
        _claimRewards();

        // @note Grab the estimate total debt from the vault
        uint256 _vaultDebt = vault.strategies(address(this)).totalDebt;
        uint256 _totalAssets = estimatedTotalAssets();

        unchecked {
            _profit = _totalAssets > _vaultDebt ? _totalAssets - _vaultDebt : 0;
        }

        // @note Free up _debtOutstanding + our profit, and make any necessary adjustments to the accounting.
        uint256 _toLiquidate = _debtOutstanding + _profit;
        uint256 _wantBalance = balanceOfWant();

        if (_toLiquidate > _wantBalance) {
            _loss = withdrawSome(_toLiquidate - _wantBalance);
            _totalAssets = estimatedTotalAssets();
        }

        uint256 _liquidWant = balanceOfWant();

        // @note Calculate final p&l and _debtPayment

        // @note Enough to pay profit (partial or full) only
        if (_liquidWant > _profit) {
            unchecked {
                _debtPayment = Math.min(_liquidWant - _profit, _debtOutstanding);
            }

            // @note Enough to pay for all profit and _debtOutstanding (partial or full)
        } else {
            _profit = _liquidWant;
            _debtPayment = 0;
        }

        unchecked {
            _loss = _loss + (_vaultDebt > _totalAssets ? _vaultDebt - _totalAssets : 0);
        }

        if (_loss > _profit) {
            unchecked {
                _loss = _loss - _profit;
            }
            _profit = 0;
        } else {
            unchecked {
                _profit = _profit - _loss;
            }
            _loss = 0;
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 _looseWant = balanceOfWant();
        if (_looseWant > _debtOutstanding) {
            uint256 _amountToDeposit = _looseWant - _debtOutstanding;
            _addToLP(_amountToDeposit);
        }
        // @note We will need to do this no matter the want situation. If there is any unstaked LP Token, let's stake it.
        uint256 unstakedBalance = balanceOfUnstakedLPToken();
        if (unstakedBalance > 0) {
            _stakeLP(unstakedBalance);
        }
    }

    function withdrawSome(uint256 _amountNeeded) internal returns (uint256 _loss) {
        uint256 _preWithdrawWant = balanceOfWant();
        uint256 unstakedBalance = balanceOfUnstakedLPToken();
        uint256 lpAmountNeeded = _ldToLp(_amountNeeded);

        if (unstakedBalance < lpAmountNeeded && balanceOfStakedLPToken() > 0) {
            _unstakeLP(lpAmountNeeded - unstakedBalance);
            unstakedBalance = balanceOfUnstakedLPToken();
        }
        if (unstakedBalance > 0) {
            _withdrawFromLP(lpAmountNeeded);
        }

        uint256 _liquidatedAmount = balanceOfWant() - _preWithdrawWant;
        if (_amountNeeded > _liquidatedAmount) {
            uint256 balanceOfLPTokens = _lpToLd(balanceOfAllLPToken());
            uint256 _potentialLoss = _amountNeeded - _liquidatedAmount;
            unchecked {
                _loss = _potentialLoss > balanceOfLPTokens ? _potentialLoss - balanceOfLPTokens : 0;
            }
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 _liquidAssets = balanceOfWant();

        if (_liquidAssets < _amountNeeded) {
            (_loss) = withdrawSome(_amountNeeded - _liquidAssets);
            _liquidAssets = balanceOfWant();
        }

        _liquidatedAmount = Math.min(_amountNeeded, _liquidAssets);
        require(_amountNeeded >= _liquidatedAmount + _loss, "!check");
    }

    function liquidateAllPositions() internal override returns (uint256) {
        _emergencyUnstakeLP();
        uint256 _lpTokenBalance = balanceOfUnstakedLPToken();
        if (_lpTokenBalance > 0) {
            _withdrawFromLP(_lpTokenBalance);
        }
        return balanceOfWant();
    }

    function prepareMigration(address _newStrategy) internal override {
        if (unstakeLPOnMigration) {
            _emergencyUnstakeLP();
        }
        lpToken.safeTransfer(_newStrategy, balanceOfUnstakedLPToken());
    }

    function harvestTrigger(uint256 callCostInWei) public view virtual override returns (bool) {
        StrategyParams memory params = vault.strategies(address(this));
        return super.harvestTrigger(callCostInWei) || block.timestamp - params.lastReport > minReportDelay;
    }

    function protectedTokens() internal view override returns (address[] memory) {}

    function ethToWant(uint256 _ethAmount) public view override returns (uint256) {}

    // --------- UTILITY & HELPER FUNCTIONS ------------
    function _lpToLd(uint256 _amountLP) internal returns (uint256) {
        return _lpToLd(_amountLP);
    }

    function _ldToLp(uint256 _amountLD) internal returns (uint256) {
        uint256 _totalLiquidity = liquidityPool.totalLiquidity();
        uint256 _convertRate = liquidityPool.convertRate();
        require(_totalLiquidity > 0); // @note Stargate: cant convert SDtoLP when totalLiq == 0
        require(_convertRate > 0);
        return
            (_amountLD * liquidityPool.totalSupply()) / (_convertRate * _totalLiquidity);
    }

    function _addToLP(uint256 _amount) internal {
        _amount = Math.min(balanceOfWant(), _amount); // @note We don't want to add to LP more than we have
        // @note Check if want token is WETH to unwrap from WETH to ETH to wrap to SGETH:
        if (wantIsWETH) {
            IWETH(address(want)).withdraw(_amount);
            stargateRouterETH.addLiquidity(liquidityPoolID, _amount, address(this));
        } else {
            // @note want is not WETH:
            _checkAllowance(address(stargateRouter), address(want), _amount);
            stargateRouter.addLiquidity(liquidityPoolID, _amount, address(this));
        }
    }

    // @note Strategy needs to have a payable fallback to receive the ETH from WETH
    receive() external payable {
        require(wantIsWETH);
    }

    function _wrapETHtoWETH() internal {
        uint256 balanceOfETH = address(this).balance;
        if (balanceOfETH > 0) {
            IWETH(address(want)).deposit{value: balanceOfETH}();
        }
    }

    function wrapETHtoWETH() external onlyVaultManagers {
        _wrapETHtoWETH();
    }

    function withdrawFromLP(uint256 lpAmount) external onlyVaultManagers {
        if (lpAmount > 0 && balanceOfUnstakedLPToken() > 0) {
            _withdrawFromLP(lpAmount);
        }
    }

    function _withdrawFromLP(uint256 _lpAmount) internal {
        _lpAmount = Math.min(balanceOfUnstakedLPToken(), _lpAmount); // @note We don't want to withdraw more than we have
        // @note This will convert all lp tokens to ETH directly (skipping SGETH)
        stargateRouter.instantRedeemLocal(uint16(liquidityPoolID), _lpAmount, address(this));
        // @note Check if want token is WETH to unwrap from SGETH to ETH to wrap to want WETH:
        if (wantIsWETH) {
            _wrapETHtoWETH();
        }
    }

    function _stakeLP(uint256 _amountToStake) internal {
        lpStaker.deposit(liquidityPoolIDInLPStaking, _amountToStake);
    }

    function unstakeLP(uint256 amountToUnstake) external onlyVaultManagers {
        if (amountToUnstake > 0 && balanceOfStakedLPToken() > 0) {
            _unstakeLP(amountToUnstake);
        }
    }

    function _unstakeLP(uint256 _amountToUnstake) internal {
        _amountToUnstake = Math.min(_amountToUnstake, balanceOfStakedLPToken());
        lpStaker.withdraw(liquidityPoolIDInLPStaking, _amountToUnstake);
    }

    function _emergencyUnstakeLP() internal {
        try lpStaker.deposit(liquidityPoolIDInLPStaking, 0) {} catch {}
        lpStaker.emergencyWithdraw(liquidityPoolIDInLPStaking);
    }

    function emergencyUnstakeLP() public onlyAuthorized {
        _emergencyUnstakeLP();
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function valueOfLPTokens() public view returns (uint256) {
        uint256 _totalLPTokenBalance = balanceOfAllLPToken();
        return liquidityPool.amountLPtoLD(_totalLPTokenBalance);
    }

    function balanceOfAllLPToken() public view returns (uint256) {
        return balanceOfUnstakedLPToken() + balanceOfStakedLPToken();
    }

    function balanceOfUnstakedLPToken() public view returns (uint256) {
        return lpToken.balanceOf(address(this));
    }

    function balanceOfStakedLPToken() public view returns (uint256) {
        return lpStaker.userInfo(liquidityPoolIDInLPStaking, address(this)).amount;
    }

    function balanceOfReward() external view returns (uint256) {
        return reward.balanceOf(address(this));
    }

    function _checkAllowance(address _contract, address _token, uint256 _amount) internal {
        if (IERC20(_token).allowance(address(this), _contract) < _amount) {
            IERC20(_token).safeApprove(_contract, 0);
            IERC20(_token).safeApprove(_contract, _amount);
        }
    }

    function _claimRewards() internal {
        if (pendingRewards() > 0) {
            _stakeLP(0);
        }
    }

    function claimRewards() external onlyVaultManagers {
        _claimRewards();
    }

    // @note This allows us to unstake or not before migration
    function setUnstakeLPOnMigration(bool _unstakeLPOnMigration) external onlyVaultManagers {
        unstakeLPOnMigration = _unstakeLPOnMigration;
    }

    // @note Redeem LP position, non-atomic, s*token will be burned and corresponding native token will be sent when available
    function redeemLocal(uint16 _dstChainId, uint256 _dstPoolId, uint256 _lpAmount) external onlyVaultManagers {
        bytes memory _address = abi.encodePacked(address(this));
        IStargateRouter.lzTxObj memory _lzTxParams = IStargateRouter.lzTxObj(0, 0, _address);
        stargateRouter.redeemLocal(
            _dstChainId, uint16(liquidityPoolID), _dstPoolId, payable(address(this)), _lpAmount, _address, _lzTxParams
        );
    }

    // ----------------- YSWAPS FUNCTIONS ---------------------

    function setTradeFactory(address _tradeFactory) external onlyGovernance {
        if (tradeFactory != address(0)) {
            _removeTradeFactoryPermissions();
        }

        reward.safeApprove(_tradeFactory, max);
        ITradeFactory tf = ITradeFactory(_tradeFactory);
        tf.enable(address(reward), address(want));
        tradeFactory = _tradeFactory;
    }

    function removeTradeFactoryPermissions() external onlyEmergencyAuthorized {
        _removeTradeFactoryPermissions();
    }

    function _removeTradeFactoryPermissions() internal {
        reward.safeApprove(tradeFactory, 0);
        tradeFactory = address(0);
    }
}
