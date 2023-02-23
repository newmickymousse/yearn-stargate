import brownie
from brownie import Contract, ZERO_ADDRESS
import pytest


def test_mint_fee(
    chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, gov, token_LP_whale, stargate_router, router_owner, token_whale
):
    # Activate mint fees at 3%
    stargate_router.setFees(1, 300, {"from": router_owner})
    stargate_router.setFees(2, 300, {"from": router_owner})
    stargate_router.setFees(13, 300, {"from": router_owner})
    
    # Deposit to the vault
    user_balance_before = token.balanceOf(user)
    token.approve(vault.address, amount, {"from": user})
    vault.deposit(amount, {"from": user})
    assert token.balanceOf(vault.address) == amount
    strategy.setDoHealthCheck(False, {"from": gov})

    # harvest
    chain.sleep(1)
    strategy.harvest({"from": gov})

    # Simulate 1% gain from rewards + fees
    token.transfer(strategy, amount*0.01, {"from":token_whale})
    
    vault.updateStrategyDebtRatio(strategy.address, 0, {"from": gov})
    chain.sleep(1)
    tx = strategy.harvest({"from": gov})
    assert pytest.approx(tx.events['StrategyReported']['loss'], rel=RELATIVE_APPROX) == amount * 0.02 # we are expecting a 2% loss



    
