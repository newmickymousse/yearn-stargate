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

    _estimated_total_assets_before = strategy.estimatedTotalAssets()

    # unstake all lp
    strategy.unstakeLP(strategy.balanceOfStakedLPToken(), {"from": gov})
    assert strategy.balanceOfStakedLPToken() == 0

    # calling redeemLocal for all unstaken LP tokens, pull for OP (111)
    strategy.redeemLocal(111, 1, strategy.balanceOfUnstakedLPToken(), {"from": gov})
    assert strategy.balanceOfUnstakedLPToken() == 0 # this will transfer all LP tokens out of the strategy

    # wait a full day
    chain.sleep(60*60*24)

    _estimated_total_assets_after= strategy.estimatedTotalAssets()

    # check that we have gotten the native asset back
    assert _estimated_total_assets_after >= _estimated_total_assets_before