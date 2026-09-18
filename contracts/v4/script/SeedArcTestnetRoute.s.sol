// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolModifyLiquidityTest } from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";

interface IErc20Minimal {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @dev Creates the linked-USDC/tARCH pool the Arc testnet buyback routes through, seeds it, and points
/// the vault at it. Split out of DeployArcTestnet for one specific reason:
///
/// Arc's linked USDC is not plain ERC-20 bytecode. Its `transferFrom` delegates into an implementation
/// that consults a native blocklist precompile at 0x1800...0001, and forge's local EVM has no such
/// precompile - the call comes back StackUnderflow and the whole simulation reverts, even though the
/// exact same transaction succeeds on the real chain. So this script MUST be broadcast with
/// `--skip-simulation`; the node's own gas estimation runs against the real precompile and works fine.
///
/// Everything in DeployArcTestnet simulates cleanly, which is why only this part is separated: a
/// deployment that big should not be broadcast blind.
///
/// Native currency needs no route of its own. The vault treats `execute(address(0))` as an alias for
/// linked USDC, which on Arc is the same underlying balance at a different decimal scale.
///
/// The vault derives this exact PoolKey
/// from the registry's own `buybackRouteFee`/`buybackRouteTickSpacing` for the linked-USDC pair, with
/// `hooks` pinned to address(0). This script therefore only has to CREATE the pool the vault will
/// already be looking for - which is why the key below must keep matching DeployArcTestnet's registry
/// entry exactly (fee 3000, tick spacing 60, hookless).
contract SeedArcTestnetRoute is Script {
    uint256 internal constant ARC_TESTNET_CHAIN_ID = 5_042_002;
    address internal constant LINKED_USDC = 0x3600000000000000000000000000000000000000;
    /// @dev Full-range liquidity at tick 0 needs roughly this many raw units per side: 1e8 raw linked
    /// USDC is 100 USDC, enough depth for a buyback to execute without tying up the faucet balance.
    int256 internal constant ROUTE_LIQUIDITY = 1e8;

    error WrongChain(uint256 actual);

    function run() external {
        if (block.chainid != ARC_TESTNET_CHAIN_ID) revert WrongChain(block.chainid);

        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        address arch = vm.envAddress("TARCH");
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        bool usdcIsCurrency0 = LINKED_USDC < arch;
        PoolKey memory routeKey = PoolKey({
            currency0: Currency.wrap(usdcIsCurrency0 ? LINKED_USDC : arch),
            currency1: Currency.wrap(usdcIsCurrency0 ? arch : LINKED_USDC),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        vm.startBroadcast(deployerKey);
        poolManager.initialize(routeKey, TickMath.getSqrtPriceAtTick(0));

        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(poolManager);
        IErc20Minimal(LINKED_USDC).approve(address(liquidityRouter), type(uint256).max);
        IErc20Minimal(arch).approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity(
            routeKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: ROUTE_LIQUIDITY,
                salt: bytes32(0)
            }),
            bytes("")
        );

        vm.stopBroadcast();

        console2.log("route pool currency0", Currency.unwrap(routeKey.currency0));
        console2.log("route pool currency1", Currency.unwrap(routeKey.currency1));
        console2.log("liquidity router", address(liquidityRouter));
    }
}
