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
import "../interfaces/Stargate/IPool.sol";
import "../interfaces/Stargate/ILPStaking.sol";
import "../interfaces/Velodrome/IVelodromeRouter.sol";
import "./ySwaps/ITradeFactory.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    uint256 private constant max = type(uint256).max;
    bool internal isOriginal = true;

    address public tradeFactory;

    uint256 public liquidityPoolID; // @note Main Pool ID
    uint256 public liquidityPoolIDInLPStaking; // @note Pool ID for LPStaking
    uint256 public maxSlippageSellingRewards;

    IERC20 public reward;
    IPool public liquidityPool;
    IERC20 public lpToken;
    IStargateRouter public stargateRouter;
    ILPStaking public lpStaker;

    string internal strategyName;
    bool private wantIsWETH;
    bool private emissionTokenIsSTG;
    bool internal unstakeLPOnMigration;

    address internal constant velodromeRouter = 0xa132DAB612dB5cB9fC9Ac426A0Cc215A3423F9c9;

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
            // @note on Optimism rewards are OP only
            reward = IERC20(lpStaker.eToken());
            IERC20(reward).safeApprove(address(velodromeRouter), max);
            maxSlippageSellingRewards = 30;
        }

        liquidityPoolIDInLPStaking = _liquidityPoolIDInLPStaking;
        lpToken = lpStaker.poolInfo(_liquidityPoolIDInLPStaking).lpToken;
        liquidityPool = IPool(address(lpToken));
        liquidityPoolID = liquidityPool.poolId();
        lpToken.safeApprove(address(lpStaker), max);
        require(liquidityPool.convertRate() > 0);
        wantIsWETH = _wantIsWETH;
        stargateRouter = IStargateRouter(liquidityPool.router());

        if (wantIsWETH == false) {
            require(address(want) == liquidityPool.token());
            IERC20(want).safeApprove(address(stargateRouter), max);
        } else {
            require(liquidityPoolID == 13); // @note PoolID == 13 for ETH pool on mainnet, Optimism, Arbitrum
            address SGETH = IPool(address(lpToken)).token();
            IERC20(SGETH).safeApprove(address(stargateRouter), max);
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
        return string(abi.encodePacked("StrategyStargateV3", IERC20Metadata(address(want)).symbol())); // @note check if interface is working
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
        if (emissionTokenIsSTG == false) {
            _sell(balanceOfReward());
        }

        // @note Grab the estimate total debt from the vault
        uint256 _vaultDebt = vault.strategies(address(this)).totalDebt;
        uint256 _totalAssets = estimatedTotalAssets();

        unchecked {
            _profit = _totalAssets > _vaultDebt ? _totalAssets - _vaultDebt : 0;
        }

        // @note Free up _debtOutstanding + our profit, and make any necessary adjustments to the accounting.
        uint256 _amountNeeded = _debtOutstanding + _profit;
        uint256 _wantBalance = balanceOfWant();

        if (_amountNeeded > _wantBalance) {
            withdrawSome(_amountNeeded);
        }

        unchecked {
            _loss = (_vaultDebt > _totalAssets ? _vaultDebt - _totalAssets : 0);
        }

        uint256 _liquidWant = balanceOfWant();

        // @note calculate final p&l and _debtPayment
        // @note enough to pay profit (partial or full) only
        if (_liquidWant <= _profit) {
            _profit = _liquidWant;
            _debtPayment = 0;
            // @note enough to pay for all profit and _debtOutstanding (partial or full)
        } else {
            _debtPayment = Math.min(_liquidWant - _profit, _debtOutstanding);
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
        uint256 _toWithdraw = _amountNeeded - balanceOfWant();
        uint256 _preWithdrawWant = balanceOfWant();
        uint256 unstakedBalance = balanceOfUnstakedLPToken();
        uint256 lpAmountToWithdraw = _ldToLp(_toWithdraw);

        if (unstakedBalance < lpAmountToWithdraw && balanceOfStakedLPToken() > 0) {
            _unstakeLP(lpAmountToWithdraw - unstakedBalance);
            unstakedBalance = balanceOfUnstakedLPToken();
        }

        if (unstakedBalance > 0) {
            _withdrawFromLP(lpAmountToWithdraw);
        }

        uint256 _liquidatedAmount = balanceOfWant() - _preWithdrawWant;
        if (_toWithdraw > _liquidatedAmount) {
            uint256 balanceOfLPTokens = _lpToLd(balanceOfAllLPToken());
            uint256 _potentialLoss = _toWithdraw - _liquidatedAmount;
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
            (_loss) = withdrawSome(_amountNeeded);
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
        _claimRewards();
        uint256 _balanceOfReward = balanceOfReward();
        if (_balanceOfReward > 0) {
            reward.safeTransfer(_newStrategy, _balanceOfReward);
        }
    }

    function harvestTrigger(uint256 callCostInWei) public view virtual override returns (bool) {
        StrategyParams memory params = vault.strategies(address(this));
        return super.harvestTrigger(callCostInWei) || block.timestamp - params.lastReport > minReportDelay;
    }

    function protectedTokens() internal view override returns (address[] memory) {}

    function ethToWant(uint256 _ethAmount) public view override returns (uint256) {}

    // --------- UTILITY & HELPER FUNCTIONS ------------
    function _lpToLd(uint256 _amountLP) internal returns (uint256) {
        return liquidityPool.amountLPtoLD(_amountLP);
    }

    function _ldToLp(uint256 _amountLD) internal returns (uint256) {
        uint256 _totalLiquidity = liquidityPool.totalLiquidity();
        require(_totalLiquidity > 0); // @note Stargate: cant convert SDtoLP when totalLiq == 0
        return (_amountLD * liquidityPool.totalSupply()) / (_totalLiquidity);
    }

    function _addToLP(uint256 _amount) internal {
        // @note Check if want token is WETH to unwrap from WETH to ETH to wrap to SGETH:
        if (wantIsWETH) {
            IWETH(address(want)).withdraw(_amount);
            address SGETH = IPool(address(lpToken)).token();
            ISGETH(SGETH).deposit{value: _amount}();
            stargateRouter.addLiquidity(liquidityPoolID, _amount, address(this));
        } else {
            // @note want is not WETH:
            stargateRouter.addLiquidity(liquidityPoolID, _amount, address(this));
        }
    }

    receive() external payable {}

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

    function sweepETH() public onlyGovernance {
        (bool success,) = governance().call{value: address(this).balance}("");
        require(success, "!FailedETHSweep");
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

    function balanceOfReward() public view returns (uint256) {
        return reward.balanceOf(address(this));
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

    function setMaxSlippageSellingRewards(uint256 _maxSlippageSellingRewards) external onlyVaultManagers {
        maxSlippageSellingRewards = _maxSlippageSellingRewards;
    }

    // @note Redeem LP position, non-atomic, s*token will be burned and corresponding native token will be sent when available
    // @note Can take up to 30 min - block confs of source chain + block confs of B chain
    function redeemLocal(uint16 _dstChainId, uint256 _lpAmount) external payable onlyGovernance {
        bytes memory _address = abi.encodePacked(address(this));
        IStargateRouter.lzTxObj memory _lzTxParams = IStargateRouter.lzTxObj(0, 0, "0x");
        stargateRouter.redeemLocal{value: msg.value}(
            _dstChainId, liquidityPoolID, liquidityPoolID, payable(address(this)), _lpAmount, _address, _lzTxParams
        );
    }

    // ----------------- YSWAPS FUNCTIONS ---------------------

    function setTradeFactory(address _tradeFactory) external onlyGovernance {
        if (tradeFactory != address(0)) {
            _removeTradeFactoryPermissions();
        }

        // @note approve and set up trade factory
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

    // ----------------- DEX LOGIC FOR OPTIMISM ---------------------

    function _sell(uint256 _rewardTokenAmount) internal {
        if (_rewardTokenAmount > 1e17) {
            (uint256 _expectedOut,) = IVelodromeRouter(velodromeRouter).getAmountOut(
                _rewardTokenAmount, // amountIn
                address(reward), // tokenIn
                address(want) // tokenOut
            );
            uint256 _amountOutMin = _expectedOut * (10_000 - maxSlippageSellingRewards) / 10_000;
            IVelodromeRouter(velodromeRouter).swapExactTokensForTokensSimple(
                _rewardTokenAmount, // amountIn
                _amountOutMin, // amountOutMin
                address(reward), // tokenFrom
                address(want), // tokenTo
                false, // stable
                address(this), // to
                block.timestamp // deadline
            );
        }
    }
}
