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

import { ArchemistBuybackVault } from "../src/ArchemistBuybackVault.sol";
import { ArchemistV4Launcher } from "../src/ArchemistV4Launcher.sol";
import { ArchemistV4Locker } from "../src/ArchemistV4Locker.sol";
import { ArchemistV4Token } from "../src/ArchemistV4Token.sol";
import { AntiSnipeParams, FeeRecipient } from "../src/ArchemistV4Types.sol";

interface IErc20Minimal {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @dev Real smoke test on the live Arc mainnet deployment: launch a token WITH the new atomic creator
/// buy, sell half back, and confirm the buyback fires automatically against the real ARCH/USDC v3 pool.
/// Deliberately named/symbolled as an explicit test artifact, not under the Archemist name, so it's
/// unambiguous on-chain that this is a smoke-test token and not a real Archemist-branded launch.
contract SmokeArcMainnet is Script {
    using SafeCast for uint256;

    uint256 internal constant ARC_CHAIN_ID = 5042;
    address internal constant LINKED_USDC = 0x3600000000000000000000000000000000000000;

    error WrongChain(uint256 actual);
    error CreateNotEnabled();
    error NoTokensReceived();

    function run() external returns (address tokenAddress, PoolId poolId) {
        if (block.chainid != ARC_CHAIN_ID) revert WrongChain(block.chainid);

        uint256 creatorKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address creator = vm.addr(creatorKey);
        ArchemistV4Launcher launcher = ArchemistV4Launcher(payable(vm.envAddress("LAUNCHER")));
        if (!launcher.createEnabled()) revert CreateNotEnabled();
        ArchemistV4Locker locker = ArchemistV4Locker(payable(launcher.LOCKER()));
        ArchemistBuybackVault vault = ArchemistBuybackVault(payable(launcher.BUYBACK_VAULT()));

        uint256 buyAmount = vm.envOr("SMOKE_BUY_AMOUNT", uint256(2e6)); // 2 USDC (6 decimals)

        FeeRecipient[] memory recipients = new FeeRecipient[](1);
        recipients[0] = FeeRecipient({ admin: creator, payout: creator, bps: 10_000 });
        ArchemistV4Launcher.LaunchParams memory params = ArchemistV4Launcher.LaunchParams({
            name: "Arc Mainnet Smoke Test",
            symbol: "SMOKETEST",
            salt: keccak256(abi.encode("arc-mainnet-smoke-test", block.timestamp)),
            quote: LINKED_USDC,
            targetFdvQuoteRaw: vm.envOr("SMOKE_TARGET_FDV", uint256(5_000e6)),
            hook: launcher.knownHookAt(0),
            hookParams: abi.encode(AntiSnipeParams({ startHookFee: 30_000, windowSeconds: 120, maxBuyBps: 100 })),
            creatorShareBps: 7_000,
            recipients: recipients,
            // The atomic creator buy this whole script exists to exercise - executes inside createToken
            // itself, exempt from the anti-snipe fee decay and maxBuyBps cap (still pays the flat base fee).
            creatorBuyAmount: buyAmount,
            creatorBuyMinTokensOut: 1
        });

        vm.startBroadcast(creatorKey);
        // LINKED_USDC is an ERC-20 quote - the launcher pulls creatorBuyAmount via transferFrom, so it
        // needs an approval first (native quotes would instead add creatorBuyAmount to msg.value).
        IErc20Minimal(LINKED_USDC).approve(address(launcher), buyAmount);
        (tokenAddress, poolId) = launcher.createToken{ value: launcher.DEPLOY_FEE() }(params);
        PoolKey memory key = locker.getPoolKey(poolId);

        uint256 bought = ArchemistV4Token(tokenAddress).balanceOf(creator);
        if (bought == 0) revert NoTokensReceived();

        // Sell half back - exercises the SELL side (flat 1% fee, no anti-snipe decay applies to sells
        // anyway) and produces a second buyback trigger, this time from an ordinary trade.
        PoolSwapTest router = new PoolSwapTest(IPoolManager(address(launcher.POOL_MANAGER())));
        bool tokenIsCurrency0 = Currency.unwrap(key.currency0) == tokenAddress;
        ArchemistV4Token(tokenAddress).approve(address(router), bought / 2);
        router.swap(
            key,
            SwapParams({
                zeroForOne: tokenIsCurrency0,
                amountSpecified: -(bought / 2).toInt256(),
                sqrtPriceLimitX96: tokenIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
        vm.stopBroadcast();

        console2.log("Smoke token", tokenAddress);
        console2.logBytes32(PoolId.unwrap(poolId));
        console2.log("Creator atomic buy - tokens received", bought);
        console2.log("Creator linked-USDC fee credit", locker.claimable(creator, LINKED_USDC));
        console2.log("Vault lastExecuteAt(linked-USDC)", vault.lastExecuteAt(LINKED_USDC));
    }
}
