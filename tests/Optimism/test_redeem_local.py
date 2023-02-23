import brownie
from brownie import Contract, ZERO_ADDRESS
import pytest

def test_redeem_local(
    chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, gov, token_LP_whale, stargate_token_pool
):
    # Deposit to the vault
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount
    strategy.setDoHealthCheck(False, {"from": gov})

    # harvest
    chain.sleep(1)
    strategy.harvest({"from": gov})
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

    # whale withdraws all available deltaCredit
    liquidityPool = Contract(strategy.liquidityPool())
    router = Contract(liquidityPool.router())
    router.instantRedeemLocal(liquidityPool.poolId(), liquidityPool.deltaCredit(), strategist, {"from":token_LP_whale})
    assert liquidityPool.deltaCredit() < amount

    # unstake all lp
    assert strategy.balanceOfStakedLPToken() > 0
    strategy.unstakeLP(strategy.balanceOfStakedLPToken(), {"from": gov})
    assert strategy.balanceOfUnstakedLPToken() > 0    
    assert strategy.balanceOfStakedLPToken() == 0

    # make sure gov has ETH for gas!
    accounts.at("0xD6216fC19DB775Df9774a6E33526131dA7D19a2c").transfer(gov, "1 ether")

    # calling redeemLocal for all unstaken LP tokens, pull from another chain
    tx = strategy.redeemLocal(101, strategy.balanceOfUnstakedLPToken(), {"from": gov, "amount":1e17})
    
    assert strategy.balanceOfUnstakedLPToken() == 0 # make sure we have transferred all LP tokens using redeemLocal
        