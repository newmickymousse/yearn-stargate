from brownie import Contract, Wei, ZERO_ADDRESS
import brownie
from eth_abi import encode_single, encode_abi
from brownie.convert import to_bytes
from eth_abi.packed import encode_abi_packed
import pytest
import eth_utils

def test_profitable_harvest_eToken(
    chain,
    accounts,
    token,
    vault,
    strategy,
    user,
    strategist,
    amount,
    RELATIVE_APPROX,
    op_whale,
    velodrome_router,
    multicall_swapper,
    usdc,
    weth,
    ymechs_safe,
    trade_factory,
    gov,
    wantIsWeth,
    emissionTokenIsSTG,
    op_token,
    rando
):
    if (emissionTokenIsSTG == False):
        assert strategy.tradeFactory() == trade_factory

        # Deposit to the vault
        token.approve(vault.address, amount, {"from": user})
        vault.deposit(amount, {"from": user})
        assert token.balanceOf(vault.address) == amount

        # Harvest 1: Send funds through the strategy
        chain.sleep(1)
        tx = strategy.harvest({"from": gov})
        assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == amount

        op_token.transfer(strategy, 1_000e18, {"from": op_whale})

        token_in = op_token
        token_out = token

        print(f"Executing trade...")
        receiver = strategy.address

        amount_in = token_in.balanceOf(strategy)
        assert amount_in > 0

        asyncTradeExecutionDetails = [strategy, token_in, token_out, amount_in, 1]

        # always start with optimizations. 5 is CallOnlyNoValue
        optimizations = [["uint8"], [5]]
        a = optimizations[0]
        b = optimizations[1]

        calldata = token_in.approve.encode_input(velodrome_router, 2**256-1)
        t = createTx(token_in, calldata)
        a = a + t[0]
        b = b + t[1]

        calldata = velodrome_router.swapExactTokensForTokensSimple.encode_input(amount_in, 0, token_in, token_out, False, multicall_swapper.address, 2**256-1)
        t = createTx(velodrome_router, calldata)
        a = a + t[0]
        b = b + t[1]

        expected_out = velodrome_router.getAmountOut(amount_in, token_in, token_out)[0]

        calldata = token_out.transfer.encode_input(receiver, expected_out*0.9)
        t = createTx(token_out, calldata)
        a = a + t[0]
        b = b + t[1]

        transaction = encode_abi_packed(a, b)

        # min out must be at least 1 to ensure that the tx works correctly
        # trade_factory.execute["uint256, address, uint, bytes"](
        #    multicall_swapper.address, 1, transaction, {"from": ymechs_safe}
        # )
        trade_factory.execute["tuple,address,bytes"](asyncTradeExecutionDetails, multicall_swapper.address, transaction, {"from": ymechs_safe})
        print(token_out.balanceOf(strategy))

        tx = strategy.harvest({"from": strategist})
        print(tx.events)
        assert tx.events["Harvested"]["profit"] > 0

        before_pps = vault.pricePerShare()
        # Harvest 2: Realize profit
        chain.sleep(1)
        tx = strategy.harvest({"from": gov})
        chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
        chain.mine(1)
        profit = token.balanceOf(vault.address)  # Profits go to vault

        assert strategy.estimatedTotalAssets() + profit > amount
        assert vault.pricePerShare() > before_pps
        assert op_token.balanceOf(strategy) < 1e18  # dust is OK

######################################################################################################################################################## Mainnet:



def createTx(to, data):
    inBytes = eth_utils.to_bytes(hexstr=data)
    return [["address", "uint256", "bytes"], [to.address, len(inBytes), inBytes]]


def test_remove_trade_factory(strategy, gov, trade_factory, op_token):
    assert strategy.tradeFactory() == trade_factory.address
    assert op_token.allowance(strategy.address, trade_factory.address) > 0

    strategy.removeTradeFactoryPermissions({"from": gov})

    assert strategy.tradeFactory() != trade_factory.address
    assert op_token.allowance(strategy.address, trade_factory.address) == 0
