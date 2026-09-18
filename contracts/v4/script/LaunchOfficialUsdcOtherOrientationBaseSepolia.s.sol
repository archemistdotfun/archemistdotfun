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
import { AntiSnipeParams, FeeRecipient } from "../src/ArchemistV4Types.sol";

interface IOfficialUsdc {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @dev Covers the address orientation LaunchOfficialUsdcPairBaseSepolia didn't: that launch produced
/// tokenIsCurrency0 == false (quote sorted first). This grinds a salt so the launched token sorts
/// below OFFICIAL_USDC instead (tokenIsCurrency0 == true), reusing the trader's leftover USDC balance
/// rather than asking the admin for another transfer.
contract LaunchOfficialUsdcOtherOrientationBaseSepolia is Script {
    using SafeCast for uint256;

    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    address internal constant OFFICIAL_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    uint256 internal constant BUY_AMOUNT = 1e6; // 1 USDC exact-input buy
    uint256 internal constant SALT_SEARCH_LIMIT = 20_000;

    error WrongChain(uint256 actual);
    error SaltNotFound();

    function run() external returns (address tokenAddress, PoolId poolId) {
        if (block.chainid != BASE_SEPOLIA_CHAIN_ID) revert WrongChain(block.chainid);
        uint256 traderKey = vm.envUint("TRADER_PRIVATE_KEY");
        address trader = vm.addr(traderKey);
        ArchemistV4Launcher launcher = ArchemistV4Launcher(payable(vm.envAddress("LAUNCHER")));
        ArchemistV4Locker locker = ArchemistV4Locker(payable(launcher.LOCKER()));

        bytes32 salt;
        address predicted;
        bool found;
        for (uint256 i; i < SALT_SEARCH_LIMIT; ++i) {
            salt = keccak256(abi.encode("official-usdc-orientation2-fixed", block.timestamp, i));
            predicted = launcher.computeTokenAddress(salt, "USDC Pair Orient2", "USDCARC2", trader);
            if (predicted < OFFICIAL_USDC) {
                found = true;
                break;
            }
        }
        if (!found) revert SaltNotFound();

        // This script used to compute a raw tick by hand here (`tokenIsCurrency0 ? -276_300 :
        // 276_300`), and getting that sign wrong once stranded a permanently-mispriced testnet token
        // (0x0345C29284a203Ac74Bf1EC3AfB16510b2F2720E - a 1 USDC buy rounded to zero token output; its
        // ConfigLocked state can't be fixed after the fact). That whole class of bug is exactly what
        // InitialPriceMath/targetFdvQuoteRaw exists to make structurally impossible: the launcher now
        // derives the orientation-correct tick on-chain from targetFdvQuoteRaw, so this script only
        // grinds a salt to deliberately land the launch token as currency0, nothing else.
        FeeRecipient[] memory recipients = new FeeRecipient[](1);
        recipients[0] = FeeRecipient({ admin: trader, payout: trader, bps: 10_000 });
        ArchemistV4Launcher.LaunchParams memory params = ArchemistV4Launcher.LaunchParams({
            name: "USDC Pair Orient2",
            symbol: "USDCARC2",
            salt: salt,
            quote: OFFICIAL_USDC,
            targetFdvQuoteRaw: 5_000e6,
            hook: launcher.knownHookAt(0),
            hookParams: abi.encode(AntiSnipeParams({ startHookFee: 10_000, windowSeconds: 120, maxBuyBps: 10_000 })),
            creatorShareBps: 7_000,
            recipients: recipients,
            creatorBuyAmount: 0,
            creatorBuyMinTokensOut: 0
        });

        vm.startBroadcast(traderKey);
        (tokenAddress, poolId) = launcher.createToken{ value: launcher.DEPLOY_FEE() }(params);
        PoolKey memory key = locker.getPoolKey(poolId);
        bool tokenIsCurrency0 = Currency.unwrap(key.currency0) == tokenAddress;
        PoolSwapTest router = new PoolSwapTest(IPoolManager(address(launcher.POOL_MANAGER())));
        IOfficialUsdc(OFFICIAL_USDC).approve(address(router), type(uint256).max);
        bool zeroForOne = !tokenIsCurrency0;
        router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -BUY_AMOUNT.toInt256(),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
        uint256 creatorFee = locker.claimable(trader, OFFICIAL_USDC);
        locker.claim(OFFICIAL_USDC, trader);
        vm.stopBroadcast();

        console2.log("Launched token", tokenAddress);
        console2.logBytes32(PoolId.unwrap(poolId));
        console2.log("tokenIsCurrency0", tokenIsCurrency0);
        console2.log("creator fee claimed", creatorFee);
    }
}
