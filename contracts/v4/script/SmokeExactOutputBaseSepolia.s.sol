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

import { ArchemistV4Hook } from "../src/ArchemistV4Hook.sol";
import { ArchemistV4Launcher } from "../src/ArchemistV4Launcher.sol";
import { ArchemistV4Locker } from "../src/ArchemistV4Locker.sol";
import { ArchemistV4Token } from "../src/ArchemistV4Token.sol";

interface ITestnetBuybackSink {
    function redeem(address asset) external returns (uint256 amount);
}

contract SmokeExactOutputBaseSepolia is Script {
    using SafeCast for uint256;

    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    uint24 internal constant BASE_HOOK_FEE = 10_000;

    error WrongChain(uint256 actual);
    error AntiSnipeStillActive(uint24 currentFee);
    error UnknownToken();

    function run() external {
        if (block.chainid != BASE_SEPOLIA_CHAIN_ID) revert WrongChain(block.chainid);

        uint256 traderKey = vm.envUint("TRADER_PRIVATE_KEY");
        address trader = vm.addr(traderKey);
        ArchemistV4Launcher launcher = ArchemistV4Launcher(payable(vm.envAddress("LAUNCHER")));
        ArchemistV4Locker locker = ArchemistV4Locker(payable(launcher.LOCKER()));
        ArchemistV4Hook hook = ArchemistV4Hook(launcher.knownHookAt(0));
        ArchemistV4Token token = ArchemistV4Token(vm.envAddress("SMOKE_TOKEN"));
        PoolId poolId = launcher.launchInfoForToken(address(token)).poolId;
        if (PoolId.unwrap(poolId) == bytes32(0)) revert UnknownToken();
        uint24 fee = hook.currentFee(poolId);
        if (fee != BASE_HOOK_FEE) revert AntiSnipeStillActive(fee);

        PoolKey memory key = locker.getPoolKey(poolId);
        uint256 tokenOut = vm.envOr("SMOKE_EXACT_TOKEN_OUT", uint256(1e9));
        uint256 quoteOut = vm.envOr("SMOKE_EXACT_QUOTE_OUT", uint256(1e8));
        uint256 maxNative = vm.envOr("SMOKE_EXACT_MAX_NATIVE", uint256(0.00001 ether));

        vm.startBroadcast(traderKey);
        PoolSwapTest router = new PoolSwapTest(IPoolManager(address(launcher.POOL_MANAGER())));
        router.swap{ value: maxNative }(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: tokenOut.toInt256(), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            _settings(),
            bytes("")
        );

        token.approve(address(router), type(uint256).max);
        router.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: quoteOut.toInt256(), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            _settings(),
            bytes("")
        );

        uint256 creatorClaim = locker.claimable(trader, address(0));
        locker.claim(address(0), trader);
        address sink = launcher.BUYBACK_VAULT();
        uint256 buybackClaim = locker.claimable(sink, address(0));
        ITestnetBuybackSink(sink).redeem(address(0));
        vm.stopBroadcast();

        console2.log("Exact-output token", address(token));
        console2.logBytes32(PoolId.unwrap(poolId));
        console2.log("Creator claim redeemed", creatorClaim);
        console2.log("Buyback claim redeemed", buybackClaim);
        console2.log("Buyback sink native balance", sink.balance);
    }

    function _settings() private pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false });
    }
}
