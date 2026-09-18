// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { PoolManager } from "@uniswap/v4-core/src/PoolManager.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { HookMiner } from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import { ArchemistBuybackVault } from "../src/ArchemistBuybackVault.sol";
import { ArchemistHolderRewards } from "../src/ArchemistHolderRewards.sol";
import { ArchemistPairRegistry } from "../src/ArchemistPairRegistry.sol";
import { ArchemistV4Hook } from "../src/ArchemistV4Hook.sol";
import { ArchemistV4Launcher } from "../src/ArchemistV4Launcher.sol";
import { ArchemistV4Locker } from "../src/ArchemistV4Locker.sol";
import { PairConfig } from "../src/ArchemistV4Types.sol";
import { ArchemistTestnetArch } from "./DeployBaseSepolia.s.sol";
import { Proxies } from "./lib/Proxies.s.sol";

interface IErc20Approve {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @dev Archemist V4 on ARC TESTNET (chain 5042002).
///
/// The one thing that makes this script different from every other deployment: **Arc testnet has no
/// Uniswap v4 at all.** Probed directly before writing this - PoolManager, PositionManager, StateView,
/// V4Quoter and UniversalRouter are all empty addresses there; only Permit2 exists (it is deployed
/// deterministically everywhere). So this script deploys its own PoolManager. That is normal for a
/// testnet, but it has two consequences worth stating plainly:
///
///   1. The PoolManager here is OURS, not a canonical Uniswap deployment. Nothing else on Arc testnet
///      shares it, so there is no external v4 liquidity to interact with.
///   2. The indexer's `uniswap-v4` protocol config points at Arc MAINNET's PoolManager, and there is no
///      arc-testnet chain entry at all. Indexing this deployment would need both added first.
///
/// What IS faithful here, and is why Arc testnet beats Base Sepolia as a rehearsal target: the linked
/// USDC at 0x3600...0000 is real, and Arc's native/linked-USDC aliasing (one balance, two decimal
/// scales, kept in sync by a protocol precompile) is real too. That aliasing is the single most
/// Arc-specific assumption in ArchemistBuybackVault, and it is the one thing Base Sepolia cannot
/// reproduce. ARCH does not exist on testnet, so a mock stands in for it.
contract DeployArcTestnet is Script {
    uint256 internal constant ARC_TESTNET_CHAIN_ID = 5_042_002;
    uint160 internal constant REQUIRED_HOOK_FLAGS = 0x28CC;
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address internal constant LINKED_USDC = 0x3600000000000000000000000000000000000000;
    uint256 internal constant TARCH_SUPPLY = 1_000_000 ether;

    error WrongChain(uint256 actual);
    error MissingCreate2Deployer();
    error MissingLinkedUsdc();
    error HookAddressMismatch(address expected, address actual);

    function run()
        external
        returns (
            PoolManager poolManager,
            ArchemistPairRegistry registry,
            ArchemistV4Launcher launcher,
            ArchemistV4Locker locker,
            ArchemistV4Hook hook,
            ArchemistBuybackVault vault,
            ArchemistHolderRewards holderRewards,
            ArchemistTestnetArch arch,
            TimelockController timelock
        )
    {
        if (block.chainid != ARC_TESTNET_CHAIN_ID) revert WrongChain(block.chainid);
        if (CREATE2_DEPLOYER.code.length == 0) revert MissingCreate2Deployer();
        if (LINKED_USDC.code.length == 0) revert MissingLinkedUsdc();

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address treasury = vm.envOr("TREASURY", deployer);
        address finalOwner = vm.envOr("SYSTEM_OWNER", deployer);
        uint256 deployFee = vm.envOr("DEPLOY_FEE", uint256(0));
        bool enableCreate = vm.envOr("ENABLE_CREATE", true);
        // Mainnet's 48 hours would make a rehearsal take three days. A short delay is legitimate HERE
        // and nowhere else: this must be recorded in the testnet manifest so nobody mistakes this
        // deployment's governance for mainnet's. Never pass a short delay to DeployArcMainnet - that
        // script refuses anything under 48h precisely so this cannot happen by habit.
        uint256 timelockDelay = vm.envOr("TIMELOCK_DELAY", uint256(10 minutes));

        vm.startBroadcast(deployerKey);

        poolManager = new PoolManager(deployer);

        address[] memory proposers = new address[](1);
        proposers[0] = vm.envOr("TIMELOCK_PROPOSER", deployer);
        timelock = Proxies.timelock(timelockDelay, proposers);

        // canonicalNativeAlias is address(0), matching mainnet: the registry lists BOTH native and
        // linked USDC as launch quotes, which the canonical-conflict check would otherwise reject.
        registry = ArchemistPairRegistry(
            Proxies.deploy(
                address(new ArchemistPairRegistry(address(0), ARC_TESTNET_CHAIN_ID)),
                abi.encodeCall(ArchemistPairRegistry.initialize, (deployer))
            )
        );
        registry.addPair(address(0), _nativePair(registry), 0, false);
        registry.addPair(LINKED_USDC, _usdcPair(), 0, true);

        launcher = ArchemistV4Launcher(
            payable(Proxies.deploy(
                    address(new ArchemistV4Launcher(poolManager, ARC_TESTNET_CHAIN_ID)),
                    abi.encodeCall(ArchemistV4Launcher.initialize, (deployer, address(registry), treasury, deployFee))
                ))
        );
        locker = ArchemistV4Locker(
            payable(Proxies.deploy(
                    address(new ArchemistV4Locker(poolManager, ARC_TESTNET_CHAIN_ID)),
                    abi.encodeCall(ArchemistV4Locker.initialize, (deployer, address(launcher)))
                ))
        );
        arch = new ArchemistTestnetArch(deployer, TARCH_SUPPLY);
        // Arc testnet has no Uniswap v3 (it has no v4 either - this script deploys its own
        // PoolManager), so every route here is a v4 pool derived from the registry entry below. The v3
        // factory argument is the PoolManager's own address purely to satisfy the non-zero/has-code
        // check; no v3 route can ever resolve on this chain.
        vault = ArchemistBuybackVault(
            payable(Proxies.deploy(
                    address(
                        new ArchemistBuybackVault(
                            poolManager, address(arch), LINKED_USDC, address(poolManager), ARC_TESTNET_CHAIN_ID
                        )
                    ),
                    abi.encodeCall(ArchemistBuybackVault.initialize, (deployer, address(locker), address(registry)))
                ))
        );
        holderRewards = ArchemistHolderRewards(
            payable(Proxies.deploy(
                    address(new ArchemistHolderRewards(ARC_TESTNET_CHAIN_ID)),
                    abi.encodeCall(ArchemistHolderRewards.initialize, (deployer, address(launcher), address(locker)))
                ))
        );

        // The hook carries the vault address as an immutable, so the vault has to exist before the hook
        // is mined - its address is part of the hook's creation code and therefore of its salt.
        bytes memory constructorArgs = abi.encode(poolManager, address(launcher), address(locker), address(vault));
        (address expectedHook, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, REQUIRED_HOOK_FLAGS, type(ArchemistV4Hook).creationCode, constructorArgs);
        hook = new ArchemistV4Hook{ salt: salt }(poolManager, address(launcher), address(locker), address(vault));
        if (address(hook) != expectedHook) revert HookAddressMismatch(expectedHook, address(hook));

        // Deliberately NOT seeded here - see SeedArcTestnetRoute.s.sol for why this cannot run inside
        // a simulated script on Arc.
        launcher.configureSystemOnce(address(locker), address(vault), address(holderRewards));
        launcher.registerHook(address(hook));
        registry.configureProbeRecipients(address(launcher));
        if (enableCreate) launcher.enableCreate();

        // Step one of the two-step handover. `finalOwner` defaults to the timelock so the rehearsal
        // exercises the real governance path; the timelock must then schedule and execute five
        // `acceptOwnership()` calls. Until it does, the deployer still owns everything.
        if (finalOwner == deployer) finalOwner = address(timelock);
        if (finalOwner != deployer) {
            launcher.transferOwnership(finalOwner);
            registry.transferOwnership(finalOwner);
            vault.transferOwnership(finalOwner);
            locker.transferOwnership(finalOwner);
            holderRewards.transferOwnership(finalOwner);
        }
        vm.stopBroadcast();

        console2.log("chainId", block.chainid);
        console2.log("PoolManager (ours, testnet-only)", address(poolManager));
        console2.log("PairRegistry", address(registry));
        console2.log("Launcher", address(launcher));
        console2.log("Locker", address(locker));
        console2.log("Hook", address(hook));
        console2.log("BuybackVault", address(vault));
        console2.log("HolderRewards", address(holderRewards));
        console2.log("TestnetArch (tARCH)", address(arch));
        console2.log("Linked USDC (real)", LINKED_USDC);
        console2.log("Timelock", address(timelock));
        console2.log("Timelock minDelay (TESTNET ONLY - mainnet is 48h)", timelock.getMinDelay());
        console2.log("Hook low-14 bits", uint160(address(hook)) & 0x3FFF);
        console2.log("createEnabled", launcher.createEnabled());
        console2.log("owner", launcher.owner());
        console2.log("treasury", launcher.TREASURY());
        console2.log("ARCH sink (burn)", vault.ARCH_SINK());
        console2.log("NOTE: buyback route pool not seeded yet - run SeedArcTestnetRoute.s.sol next");
    }

    function _nativePair(ArchemistPairRegistry registry) private view returns (PairConfig memory) {
        return PairConfig({
            enabled: true,
            decimals: 18,
            defaultTick: 0,
            minTick: -600_000,
            maxTick: 600_000,
            tickSpacing: 60,
            flags: registry.FLAG_NATIVE(),
            // Never read: the vault aliases native straight to linked USDC's own route.
            buybackRoute: address(0),
            buybackRouteIsV4: false,
            buybackRouteFee: 0,
            buybackRouteTickSpacing: 0,
            minCreatorBps: 5_000,
            maxCreatorBps: 8_000
        });
    }

    function _usdcPair() private pure returns (PairConfig memory) {
        return PairConfig({
            enabled: true,
            decimals: 6,
            defaultTick: 0,
            minTick: -600_000,
            maxTick: 600_000,
            tickSpacing: 60,
            flags: 0,
            // No address, by design: the vault derives the v4 key itself from these two numbers plus
            // {LINKED_USDC, tARCH, hooks: address(0)}. SeedArcTestnetRoute.s.sol initializes and seeds
            // exactly that pool - there is nothing to "point" the vault at afterwards.
            buybackRoute: address(0),
            buybackRouteIsV4: true,
            buybackRouteFee: 3_000,
            buybackRouteTickSpacing: 60,
            minCreatorBps: 5_000,
            maxCreatorBps: 8_000
        });
    }
}
