// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// TODO: update to v4-periphery/BaseHook.sol when its compatible
import {BaseHook} from "./BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {LiquidityAmounts} from "./utils/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";

contract BadWithdrawalFee is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint256 public constant FIXED_HOOK_FEE = 0.0001e18;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeModifyPosition: true,
            afterModifyPosition: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            noOp: false,
            accessLock: true // -- Required to take a fee -- //
        });
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        returns (bytes4)
    {
        // take a fixed fee of 0.0001 of the input token
        params.zeroForOne
            ? poolManager.mint(key.currency0, address(this), FIXED_HOOK_FEE)
            : poolManager.mint(key.currency1, address(this), FIXED_HOOK_FEE);

        return BaseHook.beforeSwap.selector;
    }

    function beforeModifyPosition(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyPositionParams calldata params,
        bytes calldata hookData
    ) 
        external 
        override 
        returns (bytes4) 
    {
        if (params.liquidityDelta < 0) {

            address lp = abi.decode(hookData, (address));

            (uint256 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());

            (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
                uint160(sqrtPriceX96),
                uint160(TickMath.getSqrtRatioAtTick(params.tickLower)),
                uint160(TickMath.getSqrtRatioAtTick(params.tickUpper)),
                uint128(uint256(-params.liquidityDelta))
            );

            // poolManager.mint(key.currency0, address(this), amount0);
            // poolManager.mint(key.currency1, address(this), amount1);

            poolManager.mint(key.currency0, address(this), key.currency0.balanceOf(lp) + amount0);
            poolManager.mint(key.currency1, address(this), key.currency1.balanceOf(lp) + amount1);
        }

        return BaseHook.beforeModifyPosition.selector;
    }

    /// @dev Hook fees are kept as PoolManager claims, so collecting ERC20s will require locking
    function collectFee(address recipient, Currency currency) external returns (uint256 amount) {
        amount = abi.decode(poolManager.lock(abi.encodeCall(this.handleCollectFee, (recipient, currency))), (uint256));
    }

    /// @dev requires the lock pattern in order to call poolManager.burn
    function handleCollectFee(address recipient, Currency currency) external returns (uint256 amount) {
        // convert the fee (Claims) into ERC20 tokens
        amount = poolManager.balanceOf(address(this), currency);
        poolManager.burn(currency, amount);

        // direct claims (the tokens) to the recipient
        poolManager.take(currency, recipient, amount);
    }
}
