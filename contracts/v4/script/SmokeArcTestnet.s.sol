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

import { ArchemistHolderRewards } from "../src/ArchemistHolderRewards.sol";
import { ArchemistV4Launcher } from "../src/ArchemistV4Launcher.sol";
import { ArchemistV4Locker } from "../src/ArchemistV4Locker.sol";
import { ArchemistV4Token } from "../src/ArchemistV4Token.sol";
import { AntiSnipeParams, FeeRecipient } from "../src/ArchemistV4Types.sol";

/// @dev The deployment-#7 rehearsal on Arc testnet: launch a native-quoted token through the registered
/// hook, buy, sell, and check on chain that every piece the restructure changed behaves as designed -
/// the hook fee is recorded, holder rewards accrue to a real holder, and the token's own deployed
/// bytecode contains no call opcode at all.
///
/// Native quote on purpose: Arc's linked USDC delegates `transferFrom` into a native blocklist
/// precompile that forge's local EVM does not have, so an ERC-20-quoted creator buy cannot be
/// simulated here (it works on the real chain - see SeedArcTestnetRoute.s.sol's header). Native avoids
/// that entirely and exercises the same code paths.
contract SmokeArcTestnet is Script {
    using SafeCast for uint256;

    uint256 internal constant ARC_TESTNET_CHAIN_ID = 5_042_002;

    error WrongChain(uint256 actual);
    error CreateNotEnabled();
    error NoTokensReceived();
    error TokenHasExternalCall(uint256 offset);
    error NoFeeRecorded();
    error NoHolderReward();

    function run() external returns (address tokenAddress, PoolId poolId) {
        if (block.chainid != ARC_TESTNET_CHAIN_ID) revert WrongChain(block.chainid);

        uint256 creatorKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address creator = vm.addr(creatorKey);
        ArchemistV4Launcher launcher = ArchemistV4Launcher(payable(vm.envAddress("LAUNCHER")));
        if (!launcher.createEnabled()) revert CreateNotEnabled();
        ArchemistV4Locker locker = ArchemistV4Locker(payable(launcher.LOCKER()));
        ArchemistHolderRewards rewards = ArchemistHolderRewards(payable(launcher.HOLDER_REWARDS()));
        IPoolManager poolManager = launcher.POOL_MANAGER();
        address hook = launcher.knownHookAt(0);

        uint256 buyAmount = vm.envOr("SMOKE_BUY_AMOUNT", uint256(0.05 ether));

        vm.startBroadcast(creatorKey);

        PoolSwapTest router = new PoolSwapTest(poolManager);

        FeeRecipient[] memory recipients = new FeeRecipient[](1);
        recipients[0] = FeeRecipient({ admin: creator, payout: creator, bps: 10_000 });
        (tokenAddress, poolId) = launcher.createToken{ value: launcher.DEPLOY_FEE() }(
            ArchemistV4Launcher.LaunchParams({
                name: "Arc Testnet Smoke Test",
                symbol: "SMOKE7",
                salt: keccak256(abi.encode("arc-testnet-smoke", block.timestamp)),
                quote: address(0),
                targetFdvQuoteRaw: 1_000_000_000 ether,
                hook: hook,
                hookParams: abi.encode(
                    AntiSnipeParams({ startHookFee: 300_000, windowSeconds: 120, maxBuyBps: 10_000 })
                ),
                creatorShareBps: 7_000,
                recipients: recipients,
                creatorBuyAmount: 0,
                creatorBuyMinTokensOut: 0
            })
        );

        PoolKey memory key = locker.getPoolKey(poolId);
        ArchemistV4Token token = ArchemistV4Token(tokenAddress);

        // --- buy (native in, token out) -------------------------------------------------------
        uint256 feeBefore = locker.totalClaimLiability(address(0));
        router.swap{ value: buyAmount }(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -buyAmount.toInt256(), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
        uint256 bought = token.balanceOf(creator);
        if (bought == 0) revert NoTokensReceived();
        uint256 buyFee = locker.totalClaimLiability(address(0)) - feeBefore;
        if (buyFee == 0) revert NoFeeRecorded();

        // --- sell half back (token in, native out) - this is what funds holder rewards ----------
        token.approve(address(router), bought / 2);
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

        // --- the property this whole deployment exists for -------------------------------------
        _assertNoExternalCall(tokenAddress);

        uint256 earned = rewards.earned(tokenAddress, creator);
        if (earned == 0) revert NoHolderReward();

        console2.log("token", tokenAddress);
        console2.log("poolId", uint256(PoolId.unwrap(poolId)));
        console2.log("hook", hook);
        console2.log("tokens bought", bought);
        console2.log("buy fee recorded (native)", buyFee);
        console2.log("eligibleSupply", token.eligibleSupply());
        console2.log("rewardPerTokenX128", token.rewardPerTokenX128());
        console2.log("creator earned (native)", earned);
        console2.log("creator claimable at locker", locker.claimable(creator, address(0)));
        console2.log("token bytecode: no CALL/DELEGATECALL/STATICCALL - OK");
    }

    /// @dev Walks the deployed bytecode, stepping over PUSH immediates so data is never mistaken for an
    /// opcode, and fails if it finds any call instruction. This is the on-chain version of
    /// `test_transferBytecodeHasNoExternalCall`: a token-safety scanner decompiles exactly this, and it
    /// is what used to produce the "Trade Restriction" finding.
    function _assertNoExternalCall(address token) private view {
        bytes memory code = token.code;
        uint256 i;
        while (i < code.length) {
            uint8 op = uint8(code[i]);
            if (op == 0xF1 || op == 0xF2 || op == 0xF4 || op == 0xFA) revert TokenHasExternalCall(i);
            i += (op >= 0x60 && op <= 0x7F) ? uint256(op) - 0x60 + 2 : 1;
        }
    }
}
