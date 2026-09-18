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

/// @dev The promise the hook registry has to keep, checked against a live chain rather than a test
/// harness: after the hook a pool was launched with has been DISABLED and the launcher itself has been
/// UPGRADED, that pool must still trade and still pay its creator exactly as before. If this is not
/// true, the registry is not curation - it is a kill switch on other people's pools.
///
/// Run against the Arc testnet rehearsal after the timelock has executed
/// `setHookEnabled(hookA, false)` and `upgradeToAndCall(newLauncherImpl)`.
contract VerifyRotationArcTestnet is Script {
    using SafeCast for uint256;

    error PoolStoppedPayingItsCreator();
    error DisabledHookStillAcceptsNewLaunches();
    error EnabledHookRejectsNewLaunches();

    function run() external {
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address creator = vm.addr(key);
        ArchemistV4Launcher launcher = ArchemistV4Launcher(payable(vm.envAddress("LAUNCHER")));
        ArchemistV4Locker locker = ArchemistV4Locker(payable(launcher.LOCKER()));
        address oldToken = vm.envAddress("EXISTING_TOKEN");
        address disabledHook = vm.envAddress("DISABLED_HOOK");
        address enabledHook = vm.envAddress("ENABLED_HOOK");

        PoolId poolId = launcher.launchInfoForToken(oldToken).poolId;
        PoolKey memory poolKey = locker.getPoolKey(poolId);
        require(address(poolKey.hooks) == disabledHook, "pool is not on the disabled hook");
        require(!launcher.isHookEnabled(disabledHook), "hook is not actually disabled");
        require(launcher.isKnownHook(disabledHook), "a disabled hook must stay KNOWN forever");

        uint256 creatorBefore = locker.claimable(creator, address(0));
        uint256 liabilityBefore = locker.totalClaimLiability(address(0));

        vm.startBroadcast(key);
        PoolSwapTest router = new PoolSwapTest(launcher.POOL_MANAGER());
        // 1. The existing pool still trades, through the disabled hook, after the upgrade.
        router.swap{ value: 1e13 }(
            poolKey,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(1e13), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
        vm.stopBroadcast();

        uint256 feeCharged = locker.totalClaimLiability(address(0)) - liabilityBefore;
        uint256 creatorGained = locker.claimable(creator, address(0)) - creatorBefore;
        if (feeCharged == 0 || creatorGained == 0) revert PoolStoppedPayingItsCreator();

        // 2. A NEW launch on the disabled hook must be refused...
        ArchemistV4Launcher.LaunchParams memory p = _params(creator, disabledHook, "rot-disabled");
        (bool refused,) = address(launcher).call{ value: 0 }(abi.encodeCall(ArchemistV4Launcher.createToken, (p)));
        if (refused) revert DisabledHookStillAcceptsNewLaunches();

        // 3. ...and a new launch on the newly registered hook must work.
        vm.startBroadcast(key);
        p = _params(creator, enabledHook, string.concat("rot-enabled-", vm.toString(block.timestamp)));
        (address newToken,) = launcher.createToken{ value: launcher.DEPLOY_FEE() }(p);
        vm.stopBroadcast();

        console2.log("existing pool traded through the DISABLED hook after the upgrade");
        console2.log("  fee charged (native)   ", feeCharged);
        console2.log("  creator gained (native)", creatorGained);
        console2.log("new launch on the disabled hook was refused");
        console2.log("new launch on the newly registered hook succeeded");
        console2.log("  token", newToken);
        console2.log("  hook ", launcher.launchInfoForToken(newToken).hook);
        console2.log("  total tokens now", launcher.getTotalTokens());
    }

    function _params(address creator, address hook, string memory salt)
        private
        pure
        returns (ArchemistV4Launcher.LaunchParams memory p)
    {
        FeeRecipient[] memory recipients = new FeeRecipient[](1);
        recipients[0] = FeeRecipient({ admin: creator, payout: creator, bps: 10_000 });
        p = ArchemistV4Launcher.LaunchParams({
            name: "Rotation Check",
            symbol: "ROT7",
            salt: keccak256(bytes(salt)),
            quote: address(0),
            targetFdvQuoteRaw: 1_000_000_000 ether,
            hook: hook,
            hookParams: abi.encode(AntiSnipeParams({ startHookFee: 10_000, windowSeconds: 60, maxBuyBps: 10_000 })),
            creatorShareBps: 7_000,
            recipients: recipients,
            creatorBuyAmount: 0,
            creatorBuyMinTokensOut: 0
        });
    }
}
