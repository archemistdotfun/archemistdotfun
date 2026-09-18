// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";

import { ArchemistV4Launcher } from "../src/ArchemistV4Launcher.sol";
import { ArchemistV4Locker } from "../src/ArchemistV4Locker.sol";
import { ArchemistV4Token } from "../src/ArchemistV4Token.sol";
import { AntiSnipeParams, FeeRecipient } from "../src/ArchemistV4Types.sol";

contract SmokeBaseSepolia is Script {
    using SafeCast for uint256;

    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84_532;

    error WrongChain(uint256 actual);
    error CreateNotEnabled();
    error NoTokensReceived();

    function run() external returns (address tokenAddress, PoolId poolId) {
        if (block.chainid != BASE_SEPOLIA_CHAIN_ID) revert WrongChain(block.chainid);

        uint256 creatorKey = vm.envUint("TRADER_PRIVATE_KEY");
        address creator = vm.addr(creatorKey);
        ArchemistV4Launcher launcher = ArchemistV4Launcher(payable(vm.envAddress("LAUNCHER")));
        if (!launcher.createEnabled()) revert CreateNotEnabled();
        ArchemistV4Locker locker = ArchemistV4Locker(payable(launcher.LOCKER()));

        uint256 buyAmount = vm.envOr("SMOKE_BUY_AMOUNT", uint256(0.0001 ether));

        FeeRecipient[] memory recipients = new FeeRecipient[](1);
        recipients[0] = FeeRecipient({ admin: creator, payout: creator, bps: 10_000 });
        ArchemistV4Launcher.LaunchParams memory params = ArchemistV4Launcher.LaunchParams({
            name: "Archemist V3 Base Sepolia Smoke",
            symbol: "ARCV3TEST",
            salt: keccak256(abi.encode("base-sepolia-smoke", block.timestamp)),
            quote: vm.envOr("SMOKE_QUOTE", address(0)),
            targetFdvQuoteRaw: vm.envOr("SMOKE_TARGET_FDV", uint256(5_000 ether)),
            hook: launcher.knownHookAt(0),
            hookParams: abi.encode(AntiSnipeParams({ startHookFee: 30_000, windowSeconds: 120, maxBuyBps: 100 })),
            creatorShareBps: 7_000,
            recipients: recipients,
            // The atomic creator buy: executes inside createToken itself, exempt from the anti-snipe fee
            // decay and maxBuyBps cap (still pays the flat base fee), so it can never be front-run.
            creatorBuyAmount: buyAmount,
            creatorBuyMinTokensOut: 1
        });

        vm.startBroadcast(creatorKey);
        (tokenAddress, poolId) = launcher.createToken{ value: launcher.DEPLOY_FEE() + buyAmount }(params);
        PoolKey memory key = locker.getPoolKey(poolId);
        PoolSwapTest router = new PoolSwapTest(IPoolManager(address(launcher.POOL_MANAGER())));

        uint256 bought = ArchemistV4Token(tokenAddress).balanceOf(creator);
        if (bought == 0) revert NoTokensReceived();
        ArchemistV4Token(tokenAddress).approve(address(router), bought / 2);
        router.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -(bought / 2).toInt256(),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
        vm.stopBroadcast();

        console2.log("Smoke token", tokenAddress);
        console2.logBytes32(PoolId.unwrap(poolId));
        console2.log("Bought token units", bought);
        console2.log("Creator native fee credit", locker.claimable(creator, address(0)));
    }
}
