// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolIdLibrary, PoolId} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {Deployers} from "@uniswap/v4-core/test/foundry-tests/utils/Deployers.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/types/Currency.sol";
import {HookTest} from "./utils/HookTest.sol";
import {BadEulerMedianOracle} from "../src/BadEulerMedianOracle.sol";
import {BadEulerMedianOracleImplementation} from "./implementation/BadEulerMedianOracleImplementation.sol";

contract EulerMedianOracleTest is HookTest, Deployers, GasSnapshot {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    BadEulerMedianOracle hook = BadEulerMedianOracle(address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG)));
    PoolKey poolKey;
    PoolId poolId;

    address owner;

    function setUp() public {
        vm.warp(1690023971);
        // creates the pool manager, test tokens, and other utility routers
        HookTest.initHookTestEnv();

        owner = vm.addr(1);
        vm.label(owner, "owner");

        // testing environment requires our contract to override `validateHookAddress`
        // well do that via the Implementation contract to avoid deploying the override with the production contract
        vm.record();
        BadEulerMedianOracleImplementation impl = new BadEulerMedianOracleImplementation(manager, owner, hook);
        etchHook(address(impl), address(hook));

        // Create the pool
        poolKey = PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 3000, 60, IHooks(hook));
        poolId = PoolIdLibrary.toId(poolKey);
        bytes memory initData = abi.encode(uint16(144), uint64(block.timestamp));
        manager.initialize(poolKey, SQRT_RATIO_1_1, initData);

        assertEq(hook.ringSizes(poolId), 144);
        assertEq(hook.lastUpdates(poolId), block.timestamp);

        // Provide liquidity to the pool
        modifyPositionRouter.modifyPosition(poolKey, IPoolManager.ModifyPositionParams(-60, 60, 10 ether));
        modifyPositionRouter.modifyPosition(poolKey, IPoolManager.ModifyPositionParams(-120, 120, 10 ether));
        modifyPositionRouter.modifyPosition(
            poolKey, IPoolManager.ModifyPositionParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 10 ether)
        );
    }

    function test_abuser_read() public {
        createSwaps();

        (, int24 tick,,,,) = manager.getSlot0(poolId);
        assertEq(tick != 0, true);

        int24 medianPrice_;
        int256 medianPrice;

        (, medianPrice_) = hook.readOracle(poolKey, 50);
        medianPrice = int256(medianPrice_);
        assertEq(medianPrice, 15);

        vm.startPrank(owner);
        hook.updatePriceTicks(poolKey, hook.ringCurrs(poolId), 10);
        vm.stopPrank();

        (, medianPrice_) = hook.readOracle(poolKey, 50);
        medianPrice = int256(medianPrice_);

        // Check manipulated price
        assertGt(medianPrice, 150);

    }

    function createSwaps() internal {
        int256 amount0 = 0.01e18;
        int256 amount1 = 0.003e18;

        uint256 count;

        // create 50 unique observations
        while (count < 50) {
            count = uint256(hook.ringSizes(poolId));
            swap(poolKey, amount0, true);
            skip(12);
            swap(poolKey, amount1, false);
            skip(12);
        }
    }
}
