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

    # calling redeemLocal for all unstaken LP tokens, pull from another chain

    # USDC - pull from Optimism
    if strategy.want() == "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48":
        tx = strategy.redeemLocal(111, 1, strategy.balanceOfUnstakedLPToken(), {"from": gov, "amount":1e17})
    
    # USDT - pull from Arbitrum
    if strategy.want() == "0xdAC17F958D2ee523a2206206994597C13D831ec7":
        tx = strategy.redeemLocal(110, 2, strategy.balanceOfUnstakedLPToken(), {"from": gov, "amount":1e17})
    
    # WETH - Pull from Optimism
    if strategy.want() == "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2":
        tx = strategy.redeemLocal(111, 13, strategy.balanceOfUnstakedLPToken(), {"from": gov, "amount":1e17})
    
    assert strategy.balanceOfUnstakedLPToken() == 0 # make sure we have transferred all LP tokens using redeemLocal
        