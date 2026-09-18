// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";

import { INonfungiblePositionManagerMinimal, IWETH9Minimal } from "../src/interfaces/IUniswapV3Minimal.sol";

interface IMirrorArchApprove {
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @dev Adds a properly-balanced (matching the pool's already-initialized 1:1 tick-0 price) liquidity top-up
/// to the mARCH/WETH9 v3 pool from MirrorArchV3PoolBaseSepolia.s.sol, which was seeded far too thin (only
/// 0.01 ETH-equivalent each side) for a realistic swap size to clear the 2% slippage guard against.
contract TopUpMirrorPoolLiquidity is Script {
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    INonfungiblePositionManagerMinimal internal constant POSITION_MANAGER =
        INonfungiblePositionManagerMinimal(0x27F971cb582BF9E50F397e4d29a5C7A34f11faA2);
    IWETH9Minimal internal constant WETH9 = IWETH9Minimal(0x4200000000000000000000000000000000000006);
    uint24 internal constant FEE_1_PERCENT = 10_000;
    int24 internal constant TICK_SPACING_1_PERCENT = 200;
    uint256 internal constant TOP_UP_AMOUNT = 0.2 ether;

    error WrongChain(uint256 actual);

    function run(address mirrorArch) external {
        if (block.chainid != BASE_SEPOLIA_CHAIN_ID) revert WrongChain(block.chainid);

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        bool weth9IsToken0 = address(WETH9) < mirrorArch;
        address token0 = weth9IsToken0 ? address(WETH9) : mirrorArch;
        address token1 = weth9IsToken0 ? mirrorArch : address(WETH9);

        vm.startBroadcast(deployerKey);
        WETH9.deposit{ value: TOP_UP_AMOUNT }();
        WETH9.approve(address(POSITION_MANAGER), TOP_UP_AMOUNT);
        IMirrorArchApprove(mirrorArch).approve(address(POSITION_MANAGER), TOP_UP_AMOUNT);

        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = POSITION_MANAGER.mint(
            INonfungiblePositionManagerMinimal.MintParams({
                token0: token0,
                token1: token1,
                fee: FEE_1_PERCENT,
                tickLower: TickMath.minUsableTick(TICK_SPACING_1_PERCENT),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING_1_PERCENT),
                amount0Desired: TOP_UP_AMOUNT,
                amount1Desired: TOP_UP_AMOUNT,
                amount0Min: 0,
                amount1Min: 0,
                recipient: deployer,
                deadline: block.timestamp + 600
            })
        );
        vm.stopBroadcast();

        console2.log("tokenId", tokenId);
        console2.log("liquidity", liquidity);
        console2.log("amount0", amount0);
        console2.log("amount1", amount1);
    }
}
