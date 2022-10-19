// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import "@openzeppelin/contracts/math/Math.sol";
import {IERC20, Address} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "../interfaces/IERC20Metadata.sol";
import "../interfaces/IWETH.sol";
import "../interfaces/ISGETH.sol";
import "../interfaces/Stargate/IStargateRouter.sol";
import "../interfaces/Stargate/IPool.sol";
import "../interfaces/Stargate/ILPStaking.sol";
import "./ySwaps/ITradeFactory.sol";

interface IBaseFee {
    function isCurrentBaseFeeAcceptable() external view returns (bool);
}

contract Strategy is BaseStrategy {
    using Address for address;

    uint256 private constant max = type(uint256).max;
    bool internal isOriginal = true;

    address public tradeFactory;

    address public baseFeeOracle = 0xb5e1CAcB567d98faaDB60a1fD4820720141f064F;

    uint256 public liquidityPoolID;
    uint256 public liquidityPoolIDInLPStaking; // Each pool has a main Pool ID and then a separate Pool ID that refers to the pool in the LPStaking contract.

    IERC20 public STG;
    IPool public liquidityPool;
    IERC20 public lpToken;
    IStargateRouter public stargateRouter;
    ILPStaking public lpStaker;

    string internal strategyName;
    bool public wantIsWETH;
    bool public emissionTokenIsSTG;

    uint256 public creditThreshold; // amount of credit in underlying tokens that will automatically trigger a harvest
    bool internal forceHarvestTriggerOnce; // only set this to true when we want to trigger our keepers to harvest for us

    constructor(
        address _vault,
        address _lpStaker,
        uint16 _liquidityPoolIDInLPStaking,
        bool _wantIsWETH,
        bool _emissionTokenIsSTG,
        string memory _strategyName
    ) public BaseStrategy(_vault) {
        _initializeThis(
            _lpStaker,
            _liquidityPoolIDInLPStaking,
            _wantIsWETH,
            _emissionTokenIsSTG,
            _strategyName
        );
    }

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _lpStaker,
        uint16 _liquidityPoolIDInLPStaking,
        bool _wantIsWETH,
        bool _emissionTokenIsSTG,
        string memory _strategyName
    ) public {
        // Make sure we only initialize one time
        require(address(lpStaker) == address(0)); // dev: strategy already initialized

        // Initialize BaseStrategy
        _initialize(_vault, _strategist, _rewards, _keeper);

        // Initialize cloned instance
        _initializeThis(
            _lpStaker,
            _liquidityPoolIDInLPStaking,
            _wantIsWETH,
            _emissionTokenIsSTG,
            _strategyName
        );
    }

    function _initializeThis(
        address _lpStaker,
        uint16 _liquidityPoolIDInLPStaking,
        bool _wantIsWETH,
        bool _emissionTokenIsSTG,
        string memory _strategyName
    ) internal {
        minReportDelay = 21 days; // time to trigger harvesting by keeper depending on gas base fee
        maxReportDelay = 100 days; // time to trigger haresting by keeper no matter what
        creditThreshold = 1e6 * 1e18; //Credit threshold is in want token, and will trigger a harvest if strategy credit is above this amount.
        lpStaker = ILPStaking(_lpStaker);
        
        emissionTokenIsSTG = _emissionTokenIsSTG;
        if (emissionTokenIsSTG == true){
            STG = IERC20(lpStaker.stargate());
        } else {
            STG = IERC20(lpStaker.eToken());
        }
        
        liquidityPoolIDInLPStaking = _liquidityPoolIDInLPStaking;
        lpToken = lpStaker.poolInfo(_liquidityPoolIDInLPStaking).lpToken;
        liquidityPool = IPool(address(lpToken));
        liquidityPoolID = liquidityPool.poolId();
        stargateRouter = IStargateRouter(liquidityPool.router());
        lpToken.safeApprove(address(lpStaker), max);
        strategyName = _strategyName;
        wantIsWETH = _wantIsWETH;
        if (wantIsWETH == false){
            require(address(want) == liquidityPool.token());
        }
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
        bool _emissionTokenIsSTG,
        string memory _strategyName
    ) external returns (address payable newStrategy) {
        require(isOriginal);

        bytes20 addressBytes = bytes20(address(this));

        assembly {
            // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(
                clone_code,
                0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000
            )
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(
                add(clone_code, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000
            )
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
            _emissionTokenIsSTG,
            _strategyName
        );

        emit Cloned(newStrategy);
    }

    function name() external view override returns (string memory) {
        return strategyName;
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant().add(valueOfLPTokens());
    }

    function pendingSTGRewards() public view returns (uint256) {
        if (emissionTokenIsSTG == true){
            return lpStaker.pendingStargate(liquidityPoolIDInLPStaking, address(this));
        } else {
            return lpStaker.pendingEmissionToken(liquidityPoolIDInLPStaking, address(this));
        }
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        _claimRewards();
        
        //grab the estimate total debt from the vault
        uint256 _vaultDebt = vault.strategies(address(this)).totalDebt;
        uint256 _totalAssets = estimatedTotalAssets();
        _profit = _totalAssets > _vaultDebt ? _totalAssets.sub(_vaultDebt) : 0;

        //free up _debtOutstanding + our profit, and make any necessary adjustments to the accounting.
        uint256 _amountFreed;
        uint256 _toLiquidate = _debtOutstanding.add(_profit);
        uint256 _wantBalance = balanceOfWant();
        if (_toLiquidate > _wantBalance) {
            (_amountFreed, _loss) = withdrawSome(
                _toLiquidate.sub(_wantBalance)
            );
            _totalAssets = estimatedTotalAssets();
        } else {
            _amountFreed = balanceOfWant();
        }
        _debtPayment = Math.min(_debtOutstanding, _amountFreed);
        _loss = _loss.add(
            _vaultDebt > _totalAssets ? _vaultDebt.sub(_totalAssets) : 0
        );

        if (_loss > _profit) {
            _loss = _loss.sub(_profit);
            _profit = 0;
        } else {
            _profit = _profit.sub(_loss);
            _loss = 0;
        }

        // we're done harvesting, so reset our trigger if we used it
        forceHarvestTriggerOnce = false;
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 _looseWant = balanceOfWant();

        if (_looseWant > _debtOutstanding) {
            uint256 _amountToDeposit = _looseWant.sub(_debtOutstanding);
            _addToLP(_amountToDeposit);
        }
        // we will need to do this no matter the want situation. If there is any unstaked LP Token, let's stake it.
        uint256 unstakedBalance = balanceOfUnstakedLPToken();
        if (unstakedBalance > 0) {
            //redeposit to farm
            _stakeLP(unstakedBalance);
        }
    }

    function withdrawSome(uint256 _amountNeeded)
        internal
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 _preWithdrawWant = balanceOfWant();
        if (_amountNeeded > 0 && balanceOfStakedLPToken() > 0) {
            _unstakeLP(balanceOfStakedLPToken());
            uint256 unstakedBalance = balanceOfUnstakedLPToken();
            if (unstakedBalance > 0) {
                //withdraw from pool
                _withdrawFromLP(unstakedBalance);
            }

            //check current want balance
            uint256 _postWithdrawWant = balanceOfWant();

            uint256 _unstakedWant = _postWithdrawWant.sub(_preWithdrawWant);
            //redeposit to pool
            if (_unstakedWant > _amountNeeded) {
                _addToLP(_unstakedWant.sub(_amountNeeded));

                unstakedBalance = balanceOfUnstakedLPToken();
                if (unstakedBalance > 0) {
                    //redeposit to farm
                    _stakeLP(unstakedBalance);
                }
            }
        }

        uint256 _liquidAssets = balanceOfWant().sub(_preWithdrawWant);
        if (_amountNeeded > _liquidAssets) {
            _liquidatedAmount = _liquidAssets;
            _loss = _amountNeeded.sub(_liquidAssets);
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 _liquidAssets = balanceOfWant();

        if (_liquidAssets < _amountNeeded) {
            withdrawSome(_amountNeeded.sub(_liquidAssets));
            _liquidAssets = balanceOfWant();
            _loss = _amountNeeded.sub(_liquidAssets);
        }

        _liquidatedAmount = Math.min(_amountNeeded, _liquidAssets);
        require(_amountNeeded == _liquidatedAmount.add(_loss), "!check");
    }

    function liquidateAllPositions() internal override returns (uint256) {
        _emergencyUnstakeLP();

        uint256 _lpTokenBalance = balanceOfUnstakedLPToken();
        if (_lpTokenBalance > 0) {
            _withdrawFromLP(_lpTokenBalance);
        }
        return balanceOfWant();
    }

    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary
    function prepareMigration(address _newStrategy) internal override {
        _emergencyUnstakeLP();
        lpToken.safeTransfer(_newStrategy, balanceOfUnstakedLPToken());
    }

    /* ========== KEEP3RS ========== */
    // use this to determine when to harvest
    function harvestTrigger(uint256 callCostinEth)
        public
        view
        override
        returns (bool)
    {
        // Should not trigger if strategy is not active (no assets and no debtRatio). This means we don't need to adjust keeper job.
        if (!isActive()) {
            return false;
        }

        StrategyParams memory params = vault.strategies(address(this));
        // harvest no matter what once we reach our maxDelay
        if (block.timestamp.sub(params.lastReport) > maxReportDelay) {
            return true;
        }

        // check if the base fee gas price is higher than we allow. if it is, block harvests.
        if (!isBaseFeeAcceptable()) {
            return false;
        }

        // trigger if we want to manually harvest, but only if our gas price is acceptable
        if (forceHarvestTriggerOnce) {
            return true;
        }

        // harvest if we hit our minDelay, but only if our gas price is acceptable
        if (block.timestamp.sub(params.lastReport) > minReportDelay) {
            return true;
        }

        // harvest our credit if it's above our threshold
        if (vault.creditAvailable() > creditThreshold) {
            return true;
        }

        // otherwise, we don't harvest
        return false;
    }

    // Override this to add all tokens/tokenized positions this contract manages
    // on a *persistent* basis (e.g. not just for swapping back to want ephemerally)
    // NOTE: Do *not* include `want`, already included in `sweep` below
    //
    // Example:
    //
    //    function protectedTokens() internal override view returns (address[] memory) {
    //      address[] memory protected = new address[](3);
    //      protected[0] = tokenA;
    //      protected[1] = tokenB;
    //      protected[2] = tokenC;
    //      return protected;
    //    }
    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    // convert our keeper's eth cost into want, we don't need this anymore since we override the baseStrategy harvestTrigger
    function ethToWant(uint256 _ethAmount)
        public
        view
        override
        returns (uint256)
    {}

    // --------- UTILITY & HELPER FUNCTIONS ------------

    function _addToLP(uint256 _amount) internal {
        // Nice! DRY principle
        _amount = Math.min(balanceOfWant(), _amount); // we don't want to add to LP more than we have
        // Check if want token is WETH to unwrap from WETH to ETH to wrap to SGETH:
        if (wantIsWETH == true){
            _convertWETHtoSGETH(_amount);
        } else { // want is not WETH:
        _checkAllowance(address(stargateRouter), address(want), _amount);
        }
        stargateRouter.addLiquidity(liquidityPoolID, _amount, address(this));
    }

    // Strategy needs to have a payable fallback to receive the ETH from WETH contract in case the want of the Strategy is WETH, otherwise revert
    receive() external payable {
        require(wantIsWETH == true);
    }

    // conversion function needs to be payable to send ETH and thus needs to be public
    function _convertWETHtoSGETH(uint256 _amount) internal {
        IWETH(address(want)).withdraw(_amount);
        address SGETH = IERC20Metadata(address(lpToken)).token();
        ISGETH(SGETH).deposit{value: _amount}();
        _checkAllowance(address(stargateRouter), SGETH, _amount);
    }

    function _wrapETHtoWETH() internal {
        uint256 balanceOfETH = address(this).balance;
        if (balanceOfETH > 0){
            IWETH(address(want)).deposit{value: balanceOfETH}();
        }
    }

    function withdrawFromLP(uint256 lpAmount) external onlyVaultManagers {
        if (lpAmount > 0 && balanceOfUnstakedLPToken() > 0) {
            _withdrawFromLP(lpAmount);
        }
    }

    function _withdrawFromLP(uint256 _lpAmount) internal {
        _lpAmount = Math.min(balanceOfUnstakedLPToken(), _lpAmount); // we don't want to withdraw more than we have
        // This will convert all lp tokens to ETH directly (skipping SGETH)
        stargateRouter.instantRedeemLocal(
            uint16(liquidityPoolID),
            _lpAmount,
            address(this)
        );
        // Check if want token is WETH to unwrap from SGETH to ETH to wrap to want WETH:
        if (wantIsWETH == true){ // We have now all ETH! --> Wrap to WETH:
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
        lpStaker.emergencyWithdraw(liquidityPoolIDInLPStaking);
    }

    function emergencyUnstakedLP() public onlyAuthorized {
        lpStaker.emergencyWithdraw(liquidityPoolIDInLPStaking);
    }

    //emergency transfering sends wand balance plus amount to governance
    function emergencyTransfer(uint256 _wantAmount, uint256 _STGAmount) external onlyGovernance {
        if (wantIsWETH == true){
            _wrapETHtoWETH();
        }
        if (_wantAmount > 0){
            want.safeTransfer(vault.governance(), _wantAmount);
        }
        if (_STGAmount > 0){
            STG.safeTransfer(vault.governance(), _STGAmount);
        }
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function valueOfLPTokens() public view returns (uint256) {
        uint256 _totalLPTokenBalance = balanceOfAllLPToken();

        return liquidityPool.amountLPtoLD(_totalLPTokenBalance);
    }

    function balanceOfAllLPToken() public view returns (uint256) {
        return balanceOfUnstakedLPToken().add(balanceOfStakedLPToken());
    }

    function balanceOfUnstakedLPToken() public view returns (uint256) {
        return lpToken.balanceOf(address(this));
    }

    function balanceOfStakedLPToken() public view returns (uint256) {
        return
            lpStaker.userInfo(liquidityPoolIDInLPStaking, address(this)).amount;
    }

    function balanceOfSTG() public view returns (uint256) {
        return STG.balanceOf(address(this));
    }

    // _checkAllowance adapted from https://github.com/therealmonoloco/liquity-stability-pool-strategy/blob/1fb0b00d24e0f5621f1e57def98c26900d551089/contracts/Strategy.sol#L316

    function _checkAllowance(
        address _contract,
        address _token,
        uint256 _amount
    ) internal {
        if (IERC20(_token).allowance(address(this), _contract) < _amount) {
            IERC20(_token).safeApprove(_contract, 0);
            IERC20(_token).safeApprove(_contract, _amount);
        }
    }

    function _claimRewards() internal {
        if (pendingSTGRewards() > 0) {
            _stakeLP(0);
        }
    }

    function claimRewards() external onlyVaultManagers {
        _claimRewards();
    }

    // check if the current baseFee is below our external target
    function isBaseFeeAcceptable() internal view returns (bool) {
        return IBaseFee(baseFeeOracle).isCurrentBaseFeeAcceptable();
    }

    // This allows us to manually harvest with our keeper as needed
    function setForceHarvestTriggerOnce(bool _forceHarvestTriggerOnce) external onlyVaultManagers {
        forceHarvestTriggerOnce = _forceHarvestTriggerOnce;
    }

    ///@notice Credit threshold is in want token, and will trigger a harvest if strategy credit is above this amount.
    function setCreditThreshold(uint256 _creditThreshold) external onlyVaultManagers
    {
        creditThreshold = _creditThreshold;
    }

    ///@notice Change the contract to call to determine if basefee is acceptable for automated harvesting.
    function setBaseFeeOracle(address _baseFeeOracle) external onlyVaultManagers
    {
        baseFeeOracle = _baseFeeOracle;
    }

    // ----------------- YSWAPS FUNCTIONS ---------------------

    function setTradeFactory(address _tradeFactory) external onlyGovernance {
        if (tradeFactory != address(0)) {
            _removeTradeFactoryPermissions();
        }

        // approve and set up trade factory
        STG.safeApprove(_tradeFactory, max);
        ITradeFactory tf = ITradeFactory(_tradeFactory);
        tf.enable(address(STG), address(want));
        tradeFactory = _tradeFactory;
    }

    function removeTradeFactoryPermissions() external onlyEmergencyAuthorized {
        _removeTradeFactoryPermissions();
    }

    function _removeTradeFactoryPermissions() internal {
        STG.safeApprove(tradeFactory, 0);
        tradeFactory = address(0);
    }
}
