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
import { AntiSnipeParams, FeeRecipient } from "../src/ArchemistV4Types.sol";

interface IOfficialUsdc {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @dev Launches a token against real Base Sepolia USDC (not a mock). Unlike SmokeErc20PairBaseSepolia,
/// the admin cannot mint this quote - it must already hold enough from a faucet, and amounts here are
/// kept small (single-digit USDC) since faucet balances are limited. See BASE_SEPOLIA.md for how the
/// admin wallet was funded and how the pair was registered (registry probe against real USDC).
contract LaunchOfficialUsdcPairBaseSepolia is Script {
    using SafeCast for uint256;

    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    address internal constant OFFICIAL_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    uint256 internal constant FUND_AMOUNT = 5e6; // 5 USDC to the trader
    uint256 internal constant BUY_AMOUNT = 2e6; // 2 USDC exact-input buy

    error WrongChain(uint256 actual);
    error TransferFailed();
    error InsufficientAdminBalance(uint256 have, uint256 need);

    function run() external returns (address tokenAddress, PoolId poolId) {
        if (block.chainid != BASE_SEPOLIA_CHAIN_ID) revert WrongChain(block.chainid);
        uint256 adminKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint256 traderKey = vm.envUint("TRADER_PRIVATE_KEY");
        address admin = vm.addr(adminKey);
        address trader = vm.addr(traderKey);
        ArchemistV4Launcher launcher = ArchemistV4Launcher(payable(vm.envAddress("LAUNCHER")));
        ArchemistV4Locker locker = ArchemistV4Locker(payable(launcher.LOCKER()));
        IOfficialUsdc quote = IOfficialUsdc(OFFICIAL_USDC);

        uint256 adminBalance = quote.balanceOf(admin);
        if (adminBalance < FUND_AMOUNT) revert InsufficientAdminBalance(adminBalance, FUND_AMOUNT);

        vm.startBroadcast(adminKey);
        if (!quote.transfer(trader, FUND_AMOUNT)) revert TransferFailed();
        vm.stopBroadcast();

        bytes32 salt = keccak256(abi.encode("official-usdc-live", block.timestamp));
        address predicted = launcher.computeTokenAddress(salt, "USDC Pair Launch", "USDCARC", trader);
        // Only used for the swap direction below - the pool's actual orientation-correct tick is
        // derived on-chain by the launcher from targetFdvQuoteRaw, never computed here.
        bool tokenIsCurrency0 = predicted < OFFICIAL_USDC;
        FeeRecipient[] memory recipients = new FeeRecipient[](1);
        recipients[0] = FeeRecipient({ admin: trader, payout: trader, bps: 10_000 });
        ArchemistV4Launcher.LaunchParams memory params = ArchemistV4Launcher.LaunchParams({
            name: "USDC Pair Launch",
            symbol: "USDCARC",
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
        PoolSwapTest router = new PoolSwapTest(IPoolManager(address(launcher.POOL_MANAGER())));
        quote.approve(address(router), type(uint256).max);
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

        console2.log("Official USDC quote", OFFICIAL_USDC);
        console2.log("Launched token", tokenAddress);
        console2.logBytes32(PoolId.unwrap(poolId));
        console2.log("tokenIsCurrency0", tokenIsCurrency0);
        console2.log("creator fee claimed", creatorFee);
        console2.log("trader USDC balance", quote.balanceOf(trader));
    }
}
