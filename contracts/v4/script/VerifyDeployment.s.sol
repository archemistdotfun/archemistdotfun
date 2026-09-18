// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import { ArchemistBuybackVault } from "../src/ArchemistBuybackVault.sol";
import { ArchemistHolderRewards } from "../src/ArchemistHolderRewards.sol";
import { ArchemistPairRegistry } from "../src/ArchemistPairRegistry.sol";
import { ArchemistV4Hook } from "../src/ArchemistV4Hook.sol";
import { ArchemistV4Launcher } from "../src/ArchemistV4Launcher.sol";
import { ArchemistV4Locker } from "../src/ArchemistV4Locker.sol";

/// @notice **PD-01…PD-07 against a live deployment, read-only.**
///
/// Everything the deploy script asserts, it asserts about state it created moments earlier in its own
/// transaction. That is the weakest possible moment to check: it cannot see a failed broadcast, a
/// replaced implementation, a handover that was scheduled but never executed, or a stack that was
/// deployed correctly and then changed. Deployment #7 also ends with ownership *pending* rather than
/// transferred, so "the timelock owns it" is a claim about a later, separate transaction that nothing
/// in this repo verified. This is the check that runs afterwards, from outside.
///
/// It broadcasts nothing and needs no key:
///
/// ```sh
/// TIMELOCK=0x… REGISTRY=0x… LAUNCHER=0x… LOCKER=0x… VAULT=0x… REWARDS=0x… HOOK=0x… \
/// PROPOSER=0x… ARCH=0x… LINKED_USDC=0x… \
///   forge script script/VerifyDeployment.s.sol --rpc-url https://rpc.arc-scan.org
/// ```
///
/// All ten are required. `PROPOSER`, `ARCH` and `LINKED_USDC` are the three this block used to omit
/// while the code read them anyway, so the script died on a missing env var rather than on anything
/// it was meant to be checking.
///
/// PD-08…PD-09 (a real launch, a real buyback) need broadcasts and live in `SmokeArcMainnet.s.sol`;
/// PD-10…PD-12 are Blockscout, a third-party scanner and the manifest, which are not on-chain reads.
contract VerifyDeployment is Script {
    /// @dev ERC-1967. Read directly, because a proxy that answers `implementation()` is answering from
    /// whatever it currently delegates to - which is the thing in question.
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint160 internal constant REQUIRED_HOOK_FLAGS = 0x28CC;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 internal failures;

    function run() external {
        TimelockController timelock = TimelockController(payable(vm.envAddress("TIMELOCK")));
        ArchemistPairRegistry registry = ArchemistPairRegistry(vm.envAddress("REGISTRY"));
        ArchemistV4Launcher launcher = ArchemistV4Launcher(payable(vm.envAddress("LAUNCHER")));
        ArchemistV4Locker locker = ArchemistV4Locker(payable(vm.envAddress("LOCKER")));
        ArchemistBuybackVault vault = ArchemistBuybackVault(payable(vm.envAddress("VAULT")));
        ArchemistHolderRewards rewards = ArchemistHolderRewards(payable(vm.envAddress("REWARDS")));
        ArchemistV4Hook hook = ArchemistV4Hook(payable(vm.envAddress("HOOK")));

        console2.log("=== PD-01  every proxy points at code ===");
        _implementationOf("registry", address(registry));
        _implementationOf("launcher", address(launcher));
        _implementationOf("locker", address(locker));
        _implementationOf("vault", address(vault));
        _implementationOf("rewards", address(rewards));

        console2.log("=== PD-02  the timelock OWNS them, not merely pending ===");
        // The distinction that matters: after the deploy, `pendingOwner` is the timelock and `owner` is
        // still a single EOA that can upgrade anything instantly. Until these five read as the timelock,
        // the delay this whole design rests on does not exist yet.
        _eq("registry.owner", registry.owner(), address(timelock));
        _eq("launcher.owner", launcher.owner(), address(timelock));
        _eq("locker.owner", locker.owner(), address(timelock));
        _eq("vault.owner", vault.owner(), address(timelock));
        _eq("rewards.owner", rewards.owner(), address(timelock));
        _eq("registry.pendingOwner cleared", registry.pendingOwner(), address(0));
        _eq("launcher.pendingOwner cleared", launcher.pendingOwner(), address(0));
        _eq("locker.pendingOwner cleared", locker.pendingOwner(), address(0));
        _eq("vault.pendingOwner cleared", vault.pendingOwner(), address(0));
        _eq("rewards.pendingOwner cleared", rewards.pendingOwner(), address(0));

        console2.log("=== PD-03  timelock delay and roles ===");
        uint256 delay = timelock.getMinDelay();
        console2.log("  minDelay", delay);
        _check("minDelay >= 48h", delay >= 48 hours);
        _check("timelock is its own admin", timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));
        _check("executor role is open", timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));
        address proposer = vm.envAddress("PROPOSER");
        _check("proposer holds PROPOSER_ROLE", timelock.hasRole(timelock.PROPOSER_ROLE(), proposer));
        _check("proposer holds CANCELLER_ROLE", timelock.hasRole(timelock.CANCELLER_ROLE(), proposer));

        console2.log("=== PD-04  cross-links ===");
        _eq("launcher.LOCKER", launcher.LOCKER(), address(locker));
        _eq("launcher.BUYBACK_VAULT", launcher.BUYBACK_VAULT(), address(vault));
        _eq("launcher.HOLDER_REWARDS", launcher.HOLDER_REWARDS(), address(rewards));
        _eq("launcher.PAIR_REGISTRY", address(launcher.PAIR_REGISTRY()), address(registry));
        _eq("locker.LAUNCHER", locker.LAUNCHER(), address(launcher));
        _eq("rewards.LAUNCHER", rewards.LAUNCHER(), address(launcher));
        _eq("rewards.LOCKER", rewards.LOCKER(), address(locker));
        _eq("vault.LOCKER", vault.LOCKER(), address(locker));
        _eq("vault.PAIR_REGISTRY", address(vault.PAIR_REGISTRY()), address(registry));
        _eq("registry.LAUNCHER", registry.LAUNCHER(), address(launcher));

        console2.log("=== PD-05  the hook ===");
        _eq("hook.launcher", hook.launcher(), address(launcher));
        _eq("hook.locker", hook.locker(), address(locker));
        _eq("hook.BUYBACK_VAULT", hook.BUYBACK_VAULT(), address(vault));
        _eq("hook.poolManager", address(hook.poolManager()), address(launcher.POOL_MANAGER()));
        // The address IS the permission set: mined so its low 14 bits equal the flags it declares.
        _check("hook address bits == 0x28CC", uint160(address(hook)) & 0x3FFF == REQUIRED_HOOK_FLAGS);

        console2.log("=== PD-06  the hook registry and the launch switch ===");
        _check("hook is known", launcher.isKnownHook(address(hook)));
        _check("hook is enabled", launcher.isHookEnabled(address(hook)));
        _check("createEnabled", launcher.createEnabled());
        _check("not retired", !launcher.retired());

        console2.log("=== PD-07  ARCH is burned, not banked ===");
        _eq("vault.ARCH_SINK", vault.ARCH_SINK(), DEAD);
        _eq("vault.ARCH", vault.ARCH(), vm.envAddress("ARCH"));
        _eq("vault.LINKED_USDC", vault.LINKED_USDC(), vm.envAddress("LINKED_USDC"));

        console2.log("=== quote currencies ===");
        uint256 pairs = registry.pairCount();
        console2.log("  pairCount", pairs);
        _check("at least one quote currency is listed", pairs > 0);
        for (uint256 i; i < pairs; ++i) {
            address quote = registry.pairAt(i);
            console2.log("  quote", quote, registry.getPair(quote).enabled ? "enabled" : "DISABLED");
        }

        console2.log("");
        if (failures == 0) {
            console2.log("PD-01..PD-07 PASS. Next: PD-08/09 via SmokeArcMainnet, then Blockscout and the manifest.");
        } else {
            console2.log("FAILED checks:", failures);
            revert("deployment verification failed");
        }
    }

    function _implementationOf(string memory label, address proxy) private {
        address impl = address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
        console2.log(string.concat("  ", label, " impl"), impl);
        _check(string.concat(label, " has an implementation"), impl != address(0));
        _check(string.concat(label, " implementation has code"), impl.code.length > 0);
    }

    function _eq(string memory label, address actual, address expected) private {
        if (actual == expected) {
            console2.log(string.concat("  ok  ", label));
        } else {
            console2.log(string.concat("  FAIL ", label), actual, expected);
            ++failures;
        }
    }

    function _check(string memory label, bool ok) private {
        console2.log(string.concat(ok ? "  ok  " : "  FAIL ", label));
        if (!ok) ++failures;
    }
}
