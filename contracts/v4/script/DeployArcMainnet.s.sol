// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { HookMiner } from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import { ArchemistBuybackVault } from "../src/ArchemistBuybackVault.sol";
import { ArchemistHolderRewards } from "../src/ArchemistHolderRewards.sol";
import { ArchemistPairRegistry } from "../src/ArchemistPairRegistry.sol";
import { ArchemistV4Hook } from "../src/ArchemistV4Hook.sol";
import { ArchemistV4Launcher } from "../src/ArchemistV4Launcher.sol";
import { ArchemistV4Locker } from "../src/ArchemistV4Locker.sol";
import { PairConfig } from "../src/ArchemistV4Types.sol";
import { Proxies } from "./lib/Proxies.s.sol";

/// @dev **Deployment #7 on Arc mainnet - the last full redeploy of this stack.**
///
/// Everything before it was immutable and constructor-wired to its neighbours, so changing any one
/// contract meant redeploying all of them; that happened six times. From here on, the five system
/// contracts live behind UUPS proxies whose addresses never change, and the two things that genuinely
/// must stay immutable - the hook and the per-launch token - are versioned instead of upgraded:
///
///   - a new hook is one immutable contract plus one `registerHook` call, and existing pools keep
///     trading on the hook they were launched with, forever;
///   - a new launcher / locker / vault / rewards / registry is one implementation plus one timelocked
///     `upgradeToAndCall`.
///
/// **The trust model, stated plainly**, because it is what a reviewer will ask about. An upgradeable
/// locker is strictly more powerful than any single administrative function - an upgrade can do
/// anything. What makes it acceptable is that it is slow and public: every privileged
/// action, upgrades included, is a `TimelockController` operation visible on chain at least 48 hours
/// before it can execute. "Trustless" becomes "transparent and time-delayed". And because there is no
/// multisig on Arc yet, the proposer is a single EOA - so the honest sentence for users is: *one
/// key can propose any change to the system contracts, but nothing it proposes can take effect for 48
/// hours, and it cannot touch the hook or your token.* Moving the proposer role to a multisig later is a
/// scheduled `grantRole`/`revokeRole`, needing no upgrade and no redeploy.
///
/// **What else changes in #7:** the buyback burns ARCH to `0xdead` instead of forwarding it to the
/// treasury; the vault takes routes only from the registry, validated against the canonical Uniswap v3
/// factory; the launch token does its own holder-reward accounting so `_transfer` makes no external
/// call at all; and launches are opened by the one-way `enableCreate()` and closed by an irrevocable
/// `retire()`.
///
/// Deployment #6 stays live and untouched; its launched tokens keep trading on it and cannot be
/// migrated. Frontend and indexer must serve both launchers.
///
/// **Ordering.** The proxies must exist before anything is wired to them, and the hook must be mined
/// last because all four of its constructor arguments are proxy addresses baked into its creation code
/// (and therefore into its salt). Native (`address(0)`) needs no buyback route of its own: on Arc it is
/// the same underlying balance as linked-USDC, kept in sync 1:1 by a protocol precompile, so the vault
/// aliases `execute(address(0))` straight onto LINKED_USDC's route, cooldown and checkpoint.
contract DeployArcMainnet is Script {
    uint256 internal constant ARC_CHAIN_ID = 5042;
    uint160 internal constant REQUIRED_HOOK_FLAGS = 0x28CC;
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address internal constant ARCH = 0x5042419b1F2498959787Bc23Be1F484Ed1306650;
    address internal constant LINKED_USDC = 0x3600000000000000000000000000000000000000;
    address internal constant ARCH_V3_POOL = 0xC7CF0c94850c912A5045f2A0f2d70Ca18085b829;
    address internal constant UNISWAP_V3_FACTORY = 0xf0db7b58379503491d857dB50AC9ece64c653918;
    /// @dev Never lower this on a live network. The delay is the entire protection against the single
    /// proposer key.
    uint256 internal constant MIN_TIMELOCK_DELAY = 48 hours;

    struct Deployed {
        TimelockController timelock;
        ArchemistPairRegistry registry;
        ArchemistV4Launcher launcher;
        ArchemistV4Locker locker;
        ArchemistV4Hook hook;
        ArchemistBuybackVault vault;
        ArchemistHolderRewards holderRewards;
    }

    error WrongChain(uint256 actual);
    error MissingPoolManager();
    error MissingArchToken();
    error MissingV3Factory();
    error HookAddressMismatch(address expected, address actual);
    error WiringMismatch(string what);
    error DelayTooShort(uint256 delay);

    function run() external returns (Deployed memory d) {
        if (block.chainid != ARC_CHAIN_ID) revert WrongChain(block.chainid);
        if (address(POOL_MANAGER).code.length == 0) revert MissingPoolManager();
        if (ARCH.code.length == 0) revert MissingArchToken();
        if (UNISWAP_V3_FACTORY.code.length == 0) revert MissingV3Factory();

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        // Required, not defaulted. `vm.envOr("TREASURY", deployer)` meant that forgetting one export
        // silently pointed every protocol fee at the deploying EOA, on mainnet, with no error and
        // nothing in the output that looked wrong. `DEPLOY_FEE` keeps its zero default because zero is
        // the intended launch value and a wrong one is a governance call away; a wrong treasury is not.
        address treasury = vm.envAddress("TREASURY");
        uint256 deployFee = vm.envOr("DEPLOY_FEE", uint256(0));
        uint256 timelockDelay = vm.envOr("TIMELOCK_DELAY", MIN_TIMELOCK_DELAY);
        // The proposer and canceller: a single EOA until a multisig exists on Arc.
        address proposer = vm.envOr("TIMELOCK_PROPOSER", deployer);
        _requireSafeDelay(timelockDelay);

        vm.startBroadcast(deployerKey);
        d = _deploy(deployer, treasury, deployFee, timelockDelay, proposer);
        vm.stopBroadcast();

        _report(d, treasury, proposer);
    }

    /// @dev The CREATE2 deployer the hook's salt is mined against. Virtual for one reason: under
    /// `forge script --broadcast`, `new X{salt:}` is routed through this canonical deployer, but inside
    /// `forge test` it is not, so a test exercising this script has to mine for itself. Overriding it
    /// is the only concession the test needs; everything else below runs exactly as it will on mainnet.
    /// @dev Mainnet governance IS the delay: a script that could be run with a short one would make
    /// the entire published upgrade policy a matter of operator discipline rather than of code.
    /// Extracted so it can be tested directly (`test_mainnetScriptRefusesAShortDelay`) instead of only
    /// through a full broadcast.
    /// @dev The salt every `acceptOwnership` handover operation is scheduled under. Fixed so the five
    /// execute commands are reproducible from this file alone, two days after the deploy.
    bytes32 public constant HANDOVER_SALT = keccak256("archemist.deployment7.handover");

    function _requireSafeDelay(uint256 delay) internal pure {
        if (delay < MIN_TIMELOCK_DELAY) revert DelayTooShort(delay);
    }

    function _create2Deployer() internal view virtual returns (address) {
        return CREATE2_DEPLOYER;
    }

    function _deploy(address deployer, address treasury, uint256 deployFee, uint256 delay, address proposer)
        internal
        returns (Deployed memory d)
    {
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        d.timelock = Proxies.timelock(delay, proposers);

        // --- the five proxies, in dependency order ----------------------------------------------
        d.registry = ArchemistPairRegistry(
            Proxies.deploy(
                // canonicalNativeAlias is address(0), which DISABLES the registry's
                // canonical-conflict check. That is deliberate.
                //
                // The check exists to stop a registry listing both native and its ERC-20 alias as
                // two separate quote currencies. Archemist deliberately lists both: on Arc they are
                // one balance at two decimal scales, and a creator may reasonably want either. Passing
                // LINKED_USDC here turns the check on and makes `_addPairs` below revert
                // `CanonicalConflict` on its second call, which is exactly what it did until this was
                // Do not "fix" this to LINKED_USDC; `test_mainnetDeployScriptRuns`
                // exists to catch it if anyone does.
                address(new ArchemistPairRegistry(address(0), ARC_CHAIN_ID)),
                abi.encodeCall(ArchemistPairRegistry.initialize, (deployer))
            )
        );
        d.launcher = ArchemistV4Launcher(
            payable(Proxies.deploy(
                    address(new ArchemistV4Launcher(POOL_MANAGER, ARC_CHAIN_ID)),
                    abi.encodeCall(ArchemistV4Launcher.initialize, (deployer, address(d.registry), treasury, deployFee))
                ))
        );
        d.locker = ArchemistV4Locker(
            payable(Proxies.deploy(
                    address(new ArchemistV4Locker(POOL_MANAGER, ARC_CHAIN_ID)),
                    abi.encodeCall(ArchemistV4Locker.initialize, (deployer, address(d.launcher)))
                ))
        );
        d.vault = ArchemistBuybackVault(
            payable(Proxies.deploy(
                    address(
                        new ArchemistBuybackVault(POOL_MANAGER, ARCH, LINKED_USDC, UNISWAP_V3_FACTORY, ARC_CHAIN_ID)
                    ),
                    abi.encodeCall(ArchemistBuybackVault.initialize, (deployer, address(d.locker), address(d.registry)))
                ))
        );
        d.holderRewards = ArchemistHolderRewards(
            payable(Proxies.deploy(
                    address(new ArchemistHolderRewards(ARC_CHAIN_ID)),
                    abi.encodeCall(
                        ArchemistHolderRewards.initialize, (deployer, address(d.launcher), address(d.locker))
                    )
                ))
        );

        _addPairs(d);
        d.launcher.configureSystemOnce(address(d.locker), address(d.vault), address(d.holderRewards));
        d.registry.configureProbeRecipients(address(d.launcher));

        // --- the hook, mined last: all four of its arguments are proxy addresses ------------------
        bytes memory args = abi.encode(POOL_MANAGER, address(d.launcher), address(d.locker), address(d.vault));
        (address expectedHook, bytes32 salt) =
            HookMiner.find(_create2Deployer(), REQUIRED_HOOK_FLAGS, type(ArchemistV4Hook).creationCode, args);
        d.hook =
            new ArchemistV4Hook{ salt: salt }(POOL_MANAGER, address(d.launcher), address(d.locker), address(d.vault));
        if (address(d.hook) != expectedHook) revert HookAddressMismatch(expectedHook, address(d.hook));

        d.launcher.registerHook(address(d.hook));
        if (vm.envOr("ENABLE_CREATE", false)) d.launcher.enableCreate();

        _assertWiring(d);
        _handOver(d);
        _scheduleHandoverAcceptance(d, deployer, proposer, delay);
    }

    function _addPairs(Deployed memory d) internal {
        d.registry
            .addPair(
                address(0),
                PairConfig({
                    enabled: true,
                    decimals: 18,
                    defaultTick: 0,
                    minTick: -600_000,
                    maxTick: 600_000,
                    tickSpacing: 60,
                    flags: d.registry.FLAG_NATIVE(),
                    // Left unset deliberately - the vault never reads native's own buybackRoute, it aliases
                    // straight onto LINKED_USDC's (see this file's contract-level comment).
                    buybackRoute: address(0),
                    buybackRouteIsV4: false,
                    buybackRouteFee: 0,
                    buybackRouteTickSpacing: 0,
                    minCreatorBps: 5_000,
                    maxCreatorBps: 8_000
                }),
                0,
                false
            );
        d.registry
            .addPair(
                LINKED_USDC,
                PairConfig({
                    enabled: true,
                    decimals: 6,
                    defaultTick: 0,
                    minTick: -600_000,
                    maxTick: 600_000,
                    tickSpacing: 60,
                    flags: 0,
                    // The vault's ONLY source of routes since #7. It validates this against the canonical
                    // v3 factory on first use and caches it permanently, so a later `updatePair` cannot
                    // redirect a buyback that is already running.
                    buybackRoute: ARCH_V3_POOL,
                    buybackRouteIsV4: false,
                    buybackRouteFee: 0,
                    buybackRouteTickSpacing: 0,
                    minCreatorBps: 5_000,
                    maxCreatorBps: 8_000
                }),
                0,
                // skipProbe: canonical Arc infrastructure, not a third-party token needing a probe.
                true
            );
    }

    /// @dev Every cross-link, checked on chain before ownership is handed over - while the deployer can
    /// still fix a mistake cheaply, rather than after a 48-hour timelock stands between them and it.
    function _assertWiring(Deployed memory d) internal view {
        if (d.launcher.LOCKER() != address(d.locker)) revert WiringMismatch("launcher.LOCKER");
        if (d.launcher.BUYBACK_VAULT() != address(d.vault)) revert WiringMismatch("launcher.BUYBACK_VAULT");
        if (d.launcher.HOLDER_REWARDS() != address(d.holderRewards)) revert WiringMismatch("launcher.HOLDER_REWARDS");
        if (address(d.launcher.PAIR_REGISTRY()) != address(d.registry)) {
            revert WiringMismatch("launcher.PAIR_REGISTRY");
        }
        if (d.locker.LAUNCHER() != address(d.launcher)) revert WiringMismatch("locker.LAUNCHER");
        if (d.holderRewards.LAUNCHER() != address(d.launcher)) revert WiringMismatch("rewards.LAUNCHER");
        if (d.holderRewards.LOCKER() != address(d.locker)) revert WiringMismatch("rewards.LOCKER");
        if (d.vault.LOCKER() != address(d.locker)) revert WiringMismatch("vault.LOCKER");
        if (address(d.vault.PAIR_REGISTRY()) != address(d.registry)) revert WiringMismatch("vault.PAIR_REGISTRY");
        if (d.vault.ARCH_SINK() != 0x000000000000000000000000000000000000dEaD) {
            revert WiringMismatch("vault.ARCH_SINK");
        }
        if (d.hook.launcher() != address(d.launcher)) revert WiringMismatch("hook.launcher");
        if (d.hook.locker() != address(d.locker)) revert WiringMismatch("hook.locker");
        if (d.hook.BUYBACK_VAULT() != address(d.vault)) revert WiringMismatch("hook.BUYBACK_VAULT");
        if (!d.launcher.isKnownHook(address(d.hook))) revert WiringMismatch("launcher.isKnownHook");
        if (uint160(address(d.hook)) & 0x3FFF != REQUIRED_HOOK_FLAGS) revert WiringMismatch("hook flags");
    }

    /// @dev Step one of the two-step handover. Until the timelock accepts, the deployer is still the
    /// owner - which is what makes a typo'd timelock address recoverable rather than terminal.
    function _handOver(Deployed memory d) internal {
        d.registry.transferOwnership(address(d.timelock));
        d.launcher.transferOwnership(address(d.timelock));
        d.locker.transferOwnership(address(d.timelock));
        d.vault.transferOwnership(address(d.timelock));
        d.holderRewards.transferOwnership(address(d.timelock));
    }

    function _proxies(Deployed memory d) internal pure returns (address[5] memory) {
        return [address(d.registry), address(d.launcher), address(d.locker), address(d.vault), address(d.holderRewards)];
    }

    /// @dev Step two, **scheduled inside the same broadcast as step one**.
    ///
    /// The script used to end with `pendingOwner == timelock` and nothing else, leaving five
    /// `acceptOwnership` operations for someone to remember to propose. Until they did, one EOA could
    /// upgrade any contract in the system instantly - the exact power the timelock exists to remove -
    /// and nothing anywhere enforced that the handover ever finished. The fix is to
    /// make forgetting impossible rather than to write it down again.
    ///
    /// Scheduling here is safe precisely because it is still only step two of three: the operations
    /// cannot execute for `delay` seconds, they are public the whole time, and the proposer can cancel
    /// any of them. If the timelock address were wrong, the deployer is still the owner and can
    /// `transferOwnership` somewhere else before these mature.
    ///
    /// Skipped when the proposer is not the deployer, because then this broadcast has no right to
    /// propose anything; `_report` prints the commands for whoever does.
    function _scheduleHandoverAcceptance(Deployed memory d, address deployer, address proposer, uint256 delay)
        internal
    {
        if (proposer != deployer) return;
        address[5] memory proxies = _proxies(d);
        bytes memory acceptCall = abi.encodeWithSignature("acceptOwnership()");
        for (uint256 i; i < proxies.length; ++i) {
            // Operation ids already differ by target, so one shared salt keeps the execute commands
            // predictable - which matters when five of them have to be run by hand two days later.
            d.timelock.schedule(proxies[i], 0, acceptCall, bytes32(0), HANDOVER_SALT, delay);
        }
    }

    function _report(Deployed memory d, address treasury, address proposer) private view {
        console2.log("chainId", block.chainid);
        console2.log("PoolManager", address(POOL_MANAGER));
        console2.log("UniswapV3Factory", UNISWAP_V3_FACTORY);
        console2.log("ARCH", ARCH);
        console2.log("Linked USDC (quote pair)", LINKED_USDC);
        console2.log("ARCH v3 pool (route target)", ARCH_V3_POOL);
        console2.log("Timelock", address(d.timelock));
        console2.log("  minDelay", d.timelock.getMinDelay());
        console2.log("  proposer/canceller", proposer);
        console2.log("PairRegistry (proxy)", address(d.registry));
        console2.log("Launcher (proxy)", address(d.launcher));
        console2.log("Locker (proxy)", address(d.locker));
        console2.log("BuybackVault (proxy)", address(d.vault));
        console2.log("HolderRewards (proxy)", address(d.holderRewards));
        console2.log("Hook (immutable)", address(d.hook));
        console2.log("Hook low-14 bits", uint160(address(d.hook)) & 0x3FFF);
        console2.log("createEnabled", d.launcher.createEnabled());
        console2.log("treasury", treasury);
        console2.log("ARCH sink (burn)", d.vault.ARCH_SINK());
        console2.log("");
        if (proposer == vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY"))) {
            console2.log("acceptOwnership() is SCHEDULED on all five proxies, salt:");
            console2.logBytes32(HANDOVER_SALT);
            console2.log("NEXT: after the delay, execute each one (anyone may):");
            console2.log("  ./script/timelock.sh execute <PROXY> $(cast calldata 'acceptOwnership()') <SALT>");
        } else {
            console2.log("NEXT: the PROPOSER must schedule+execute acceptOwnership() on all five proxies.");
        }
        console2.log("Until they execute, the deployer still owns them. See docs/UPGRADE_POLICY.md.");
        address[5] memory proxies = _proxies(d);
        for (uint256 i; i < proxies.length; ++i) {
            console2.log("  proxy", proxies[i]);
        }
    }
}
