// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { HookMiner } from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import { ArchemistV4Hook } from "../src/ArchemistV4Hook.sol";
import { ArchemistV4Launcher } from "../src/ArchemistV4Launcher.sol";

/// @dev Deploys a SECOND hook against an existing deployment and prints the `registerHook` call to
/// schedule through the timelock.
///
/// This script is the point of the hook registry, reduced to one file: adding a hook costs one
/// immutable contract and one owner call. Nothing else moves - not the launcher, not the locker, not
/// the vault, not the rewards contract, and above all not a single pool that already exists. Compare
/// with a design in which the whole stack must be redeployed to change the hook.
///
/// A second hook with IDENTICAL constructor arguments still lands at a different address, and the
/// reason is worth stating correctly because the previous version of this comment described a
/// caller-supplied nonce that does not exist anywhere in this file.
///
/// `HookMiner.find` is deterministic in its inputs, so mining twice with the same creation code and the
/// same constructor arguments starts from the same salt - but it skips any candidate address that
/// already has code. The first hook is sitting at that address, so the second mine walks past it and
/// returns the next salt whose address satisfies the flag mask. That is what makes a repeat deployment
/// land somewhere new; it is a property of the miner, not of an argument the operator passes.
contract DeploySecondHook is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 internal constant REQUIRED_HOOK_FLAGS = 0x28CC;

    error HookAddressMismatch(address expected, address actual);
    error AlreadyKnown(address hook);

    function run() external returns (ArchemistV4Hook hook) {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        ArchemistV4Launcher launcher = ArchemistV4Launcher(payable(vm.envAddress("LAUNCHER")));
        IPoolManager poolManager = launcher.POOL_MANAGER();
        address locker = launcher.LOCKER();
        address vault = launcher.BUYBACK_VAULT();

        bytes memory args = abi.encode(poolManager, address(launcher), locker, vault);
        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, REQUIRED_HOOK_FLAGS, type(ArchemistV4Hook).creationCode, args);
        if (launcher.isKnownHook(expected)) revert AlreadyKnown(expected);

        vm.startBroadcast(deployerKey);
        hook = new ArchemistV4Hook{ salt: salt }(poolManager, address(launcher), locker, vault);
        vm.stopBroadcast();
        if (address(hook) != expected) revert HookAddressMismatch(expected, address(hook));

        console2.log("new hook", address(hook));
        console2.log("low-14 bits", uint160(address(hook)) & 0x3FFF);
        console2.log("wired to launcher", hook.launcher());
        console2.log("wired to locker", hook.locker());
        console2.log("wired to vault", hook.BUYBACK_VAULT());
        console2.log("");
        console2.log("Next: schedule registerHook(address) on the launcher through the timelock.");
        console2.logBytes(abi.encodeCall(ArchemistV4Launcher.registerHook, (address(hook))));
    }
}
