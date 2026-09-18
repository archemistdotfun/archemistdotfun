// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";

import { ArchemistV4Launcher } from "../src/ArchemistV4Launcher.sol";
import { ArchemistV4Locker } from "../src/ArchemistV4Locker.sol";
import { ArchemistV4Token } from "../src/ArchemistV4Token.sol";

interface IOfficialUsdc {
    function balanceOf(address account) external view returns (uint256);
}

interface ITestnetBuybackSink {
    function redeem(address asset) external returns (uint256 amount);
}

/// @dev Completes the USDC-pair coverage LaunchOfficialUsdcPairBaseSepolia started: sells (both
/// exact-input and exact-output) into the already-live pool, then claims all three fee buckets
/// (creator, buyback via the testnet sink, treasury) for the USDC leg so the full 70/12.5/17.5 split
/// is exercised against a real token, not a mock.
contract SellOfficialUsdcBaseSepolia is Script {
    using SafeCast for uint256;

    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    address internal constant OFFICIAL_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    uint256 internal constant SELL_EXACT_QUOTE_OUT = 300_000; // 0.3 USDC exact-output sell target

    error WrongChain(uint256 actual);
    error NoTokenBalance();

    function run() external {
        if (block.chainid != BASE_SEPOLIA_CHAIN_ID) revert WrongChain(block.chainid);
        uint256 traderKey = vm.envUint("TRADER_PRIVATE_KEY");
        uint256 adminKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address trader = vm.addr(traderKey);
        address admin = vm.addr(adminKey);
        ArchemistV4Launcher launcher = ArchemistV4Launcher(payable(vm.envAddress("LAUNCHER")));
        ArchemistV4Locker locker = ArchemistV4Locker(payable(launcher.LOCKER()));
        ArchemistV4Token token = ArchemistV4Token(vm.envAddress("SMOKE_USDC_TOKEN"));

        PoolId poolId = launcher.launchInfoForToken(address(token)).poolId;
        PoolKey memory key = locker.getPoolKey(poolId);
        bool tokenIsCurrency0 = Currency.unwrap(key.currency0) == address(token);
        // SELL: token in, quote out. zeroForOne = token is currency0 (token -> quote flows 0 -> 1).
        bool zeroForOne = tokenIsCurrency0;

        uint256 traderTokenBalance = token.balanceOf(trader);
        if (traderTokenBalance == 0) revert NoTokenBalance();
        uint256 sellExactInputAmount = traderTokenBalance / 4;

        vm.startBroadcast(traderKey);
        PoolSwapTest router = new PoolSwapTest(IPoolManager(address(launcher.POOL_MANAGER())));
        token.approve(address(router), type(uint256).max);

        router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -sellExactInputAmount.toInt256(),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );

        router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: SELL_EXACT_QUOTE_OUT.toInt256(),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );

        uint256 creatorClaim = locker.claimable(trader, OFFICIAL_USDC);
        locker.claim(OFFICIAL_USDC, trader);
        vm.stopBroadcast();

        address vault = launcher.BUYBACK_VAULT();
        uint256 buybackClaimable = locker.claimable(vault, OFFICIAL_USDC);
        vm.startBroadcast(adminKey);
        uint256 buybackRedeemed = ITestnetBuybackSink(vault).redeem(OFFICIAL_USDC);
        uint256 treasuryClaim = locker.claimable(admin, OFFICIAL_USDC);
        locker.claim(OFFICIAL_USDC, admin);
        vm.stopBroadcast();

        console2.log("token", address(token));
        console2.log("tokenIsCurrency0", tokenIsCurrency0);
        console2.log("sellExactInputAmount", sellExactInputAmount);
        console2.log("creator claim (this round + prior)", creatorClaim);
        console2.log("buyback claimable before redeem", buybackClaimable);
        console2.log("buyback redeemed", buybackRedeemed);
        console2.log("treasury claim (this round + prior)", treasuryClaim);
        console2.log("trader final token balance", token.balanceOf(trader));
        console2.log("trader final USDC balance", IOfficialUsdc(OFFICIAL_USDC).balanceOf(trader));
    }
}
