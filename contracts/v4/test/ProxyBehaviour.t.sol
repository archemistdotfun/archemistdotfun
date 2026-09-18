// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { ERC1967Utils } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";

import { ArchemistBuybackVault } from "../src/ArchemistBuybackVault.sol";
import { ArchemistHolderRewards } from "../src/ArchemistHolderRewards.sol";
import { ArchemistPairRegistry } from "../src/ArchemistPairRegistry.sol";
import { ArchemistV4Hook } from "../src/ArchemistV4Hook.sol";
import { ArchemistV4Launcher } from "../src/ArchemistV4Launcher.sol";
import { ArchemistV4Locker } from "../src/ArchemistV4Locker.sol";
import { ArchemistV4Token } from "../src/ArchemistV4Token.sol";
import { ArchemistERC1967Proxy } from "../src/upgradeability/ArchemistERC1967Proxy.sol";
import { ArchemistUpgradeable } from "../src/upgradeability/ArchemistUpgradeable.sol";
import { ArchemistFixture } from "./Fixture.t.sol";
import { MockStandardQuote } from "./mocks/ProbeMocks.sol";

/// @dev A UUPS implementation that is layout-compatible with the launcher and appends one field, which
/// is what a real v2 implementation looks like. Used to prove state survives an upgrade.
contract LauncherV2Mock is ArchemistV4Launcher {
    /// @custom:storage-location erc7201:archemist.storage.LauncherV2
    struct LauncherV2Storage {
        uint256 appended;
    }

    bytes32 private constant LAUNCHER_V2_STORAGE = keccak256("archemist.storage.LauncherV2.test");

    constructor(IPoolManager poolManager_, uint256 expectedChainId_)
        ArchemistV4Launcher(poolManager_, expectedChainId_)
    { }

    function initializeV2(uint256 value) external reinitializer(2) {
        _v2().appended = value;
    }

    function appended() external view returns (uint256) {
        return _v2().appended;
    }

    function _v2() private pure returns (LauncherV2Storage storage $) {
        bytes32 slot = LAUNCHER_V2_STORAGE;
        assembly ("memory-safe") {
            $.slot := slot
        }
    }
}

/// @dev Compiled with a different PoolManager. Layout-identical, so only the immutable check can catch
/// it - which is exactly why that check exists.
contract LauncherWrongImmutables is ArchemistV4Launcher {
    constructor(IPoolManager poolManager_, uint256 expectedChainId_)
        ArchemistV4Launcher(poolManager_, expectedChainId_)
    { }
}

/// @dev Not UUPS at all: no `proxiableUUID`. Upgrading to this would brick the proxy forever.
contract NotUUPS {
    function anything() external pure returns (uint256) {
        return 1;
    }
}

/// @notice Behaviour that only exists because the system is now a set of proxies owned by a timelock:
/// initialization, upgrade authorisation, state survival, delegatecall context, and the governance
/// path itself. These are the tests that would have caught every classic way a proxy system is stolen
/// or bricked.
contract ProxyBehaviourTest is ArchemistFixture {
    MockStandardQuote internal archToken;
    MockStandardQuote internal quote;

    function setUp() public {
        archToken = new MockStandardQuote(18);
        quote = new MockStandardQuote(18);
        _deployStack(address(0), address(archToken), address(quote));
        registry.addPair(address(0), _nativePair(), 0, false);
    }

    // -------------------------------------------------------------------------------------------
    // PU-01..PU-03 - initialization
    // -------------------------------------------------------------------------------------------

    /// @dev An initialisable logic contract left open is the classic UUPS hole: whoever calls
    /// `initialize` on the IMPLEMENTATION owns it, and can then make it `upgradeToAndCall` itself into
    /// something that self-destructs - bricking every proxy that points at it.
    function test_implementationCannotBeInitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        ArchemistV4Launcher(payable(launcherImpl)).initialize(address(this), address(registry), address(this), 0);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        ArchemistV4Locker(payable(lockerImpl)).initialize(address(this), address(launcher));

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        ArchemistHolderRewards(payable(rewardsImpl)).initialize(address(this), address(launcher), address(locker));

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        ArchemistBuybackVault(payable(vaultImpl)).initialize(address(this), address(locker), address(registry));

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        ArchemistPairRegistry(registryImpl).initialize(address(this));

        assertEq(ArchemistV4Launcher(payable(launcherImpl)).owner(), address(0), "and it stays unowned");
    }

    function test_initializeRunsOnceThroughProxy() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        launcher.initialize(address(this), address(registry), address(this), 0);

        // Including with a different owner - re-initialisation is ownership takeover.
        vm.prank(address(0xBEEF));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        launcher.initialize(address(0xBEEF), address(registry), address(this), 0);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        locker.initialize(address(0xBEEF), address(launcher));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        rewards.initialize(address(0xBEEF), address(launcher), address(locker));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(address(0xBEEF), address(locker), address(registry));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        registry.initialize(address(0xBEEF));

        assertEq(launcher.owner(), address(this));
    }

    /// @dev Everything the old constructors checked has to still be checked, or a mis-wired deployment
    /// becomes possible for the first time in this system's history.
    function test_initializeValidatesLikeTheOldConstructor() public {
        address launcherLogic = address(new ArchemistV4Launcher(manager, block.chainid));

        vm.expectRevert(ArchemistV4Launcher.InvalidAddress.selector);
        new ArchemistERC1967Proxy(
            launcherLogic, abi.encodeCall(ArchemistV4Launcher.initialize, (address(this), address(0), address(1), 0))
        );
        vm.expectRevert(ArchemistV4Launcher.InvalidAddress.selector);
        new ArchemistERC1967Proxy(
            launcherLogic,
            abi.encodeCall(ArchemistV4Launcher.initialize, (address(this), address(registry), address(0), 0))
        );
        vm.expectRevert(abi.encodeWithSelector(ArchemistUpgradeable.OwnableInvalidOwner.selector, address(0)));
        new ArchemistERC1967Proxy(
            launcherLogic,
            abi.encodeCall(ArchemistV4Launcher.initialize, (address(0), address(registry), address(1), 0))
        );
        // A registry address with no code.
        vm.expectRevert(ArchemistV4Launcher.InvalidInfrastructure.selector);
        new ArchemistERC1967Proxy(
            launcherLogic,
            abi.encodeCall(ArchemistV4Launcher.initialize, (address(this), address(0xBEEF), address(1), 0))
        );

        // Wrong chain.
        address wrongChainLogic = address(new ArchemistV4Launcher(manager, block.chainid + 1));
        vm.expectRevert(
            abi.encodeWithSelector(ArchemistV4Launcher.InvalidChain.selector, block.chainid, block.chainid + 1)
        );
        new ArchemistERC1967Proxy(
            wrongChainLogic,
            abi.encodeCall(ArchemistV4Launcher.initialize, (address(this), address(registry), address(1), 0))
        );

        // A locker pointed at a different launcher must not be accepted by `configureSystemOnce`.
        ArchemistV4Locker foreign = ArchemistV4Locker(
            payable(address(
                    new ArchemistERC1967Proxy(
                        address(new ArchemistV4Locker(manager, block.chainid)),
                        abi.encodeCall(ArchemistV4Locker.initialize, (address(this), address(registry)))
                    )
                ))
        );
        ArchemistV4Launcher fresh = ArchemistV4Launcher(
            payable(address(
                    new ArchemistERC1967Proxy(
                        launcherLogic,
                        abi.encodeCall(
                            ArchemistV4Launcher.initialize, (address(this), address(registry), address(1), 0)
                        )
                    )
                ))
        );
        vm.expectRevert(ArchemistV4Launcher.InvalidInfrastructure.selector);
        fresh.configureSystemOnce(address(foreign), address(vault), address(rewards));
    }

    // -------------------------------------------------------------------------------------------
    // PU-04..PU-08 - upgrade authorisation
    // -------------------------------------------------------------------------------------------

    function test_upgradeRequiresOwner() public {
        _handOverToTimelock();
        address newImpl = address(new ArchemistV4Launcher(manager, block.chainid));

        address[2] memory callers = [address(0xBEEF), address(this)];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(
                abi.encodeWithSelector(ArchemistUpgradeable.OwnableUnauthorizedAccount.selector, callers[i])
            );
            launcher.upgradeToAndCall(newImpl, "");
        }
    }

    function test_upgradeViaTimelockAfterDelay() public {
        _handOverToTimelock();
        address newImpl = address(new ArchemistV4Launcher(manager, block.chainid));
        bytes memory data = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", newImpl, bytes(""));

        timelock.schedule(address(launcher), 0, data, bytes32(0), bytes32("up"), TIMELOCK_DELAY);
        vm.expectRevert();
        timelock.execute(address(launcher), 0, data, bytes32(0), bytes32("up"));

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        timelock.execute(address(launcher), 0, data, bytes32(0), bytes32("up"));
        assertEq(_implementationOf(address(launcher)), newImpl);
    }

    function test_timelockCancelStopsUpgrade() public {
        _handOverToTimelock();
        address newImpl = address(new ArchemistV4Launcher(manager, block.chainid));
        address before = _implementationOf(address(launcher));
        bytes memory data = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", newImpl, bytes(""));

        timelock.schedule(address(launcher), 0, data, bytes32(0), bytes32("cancel-me"), TIMELOCK_DELAY);
        bytes32 id = timelock.hashOperation(address(launcher), 0, data, bytes32(0), bytes32("cancel-me"));
        timelock.cancel(id);

        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert();
        timelock.execute(address(launcher), 0, data, bytes32(0), bytes32("cancel-me"));
        assertEq(_implementationOf(address(launcher)), before, "implementation unchanged");
    }

    function test_upgradeRejectsNonUUPSImplementation() public {
        _handOverToTimelock();

        // An address with no code - the check in `_authorizeUpgrade`.
        _expectTimelockedRevert(address(launcher), address(0xDEAD));
        _expectTimelockedRevert(address(launcher), address(0));
        // A contract that is not UUPS - OZ's own `proxiableUUID` check.
        _expectTimelockedRevert(address(launcher), address(new NotUUPS()));
    }

    /// @dev Immutables live in the implementation's CODE, not in storage, so a layout check can never
    /// see them change. An implementation compiled against a different PoolManager would silently
    /// re-point the entire system while every storage slot stayed identical.
    function test_upgradeRejectsDifferentImmutables() public {
        _handOverToTimelock();
        address wrongPm = address(new LauncherWrongImmutables(IPoolManager(address(0xBEEF)), block.chainid));
        address wrongChain = address(new LauncherWrongImmutables(manager, block.chainid + 1));
        _expectTimelockedRevert(address(launcher), wrongPm);
        _expectTimelockedRevert(address(launcher), wrongChain);
    }

    /// @dev **PU-08c. Every proxy refuses every other system contract.**
    ///
    /// `proxiableUUID` returns the same constant for every UUPS implementation ever written, and all
    /// five of these were compiled against the same PoolManager and chain id - so before the
    /// `ARCHEMIST_KIND` tag, `upgradeToAndCall(launcherProxy, lockerImpl)` passed every check and
    /// succeeded. The launcher proxy came back speaking the locker's ABI over the launcher's storage:
    /// `LOCKER()` gone, `allTokens` reinterpreted as a fee mapping, and no way to tell from the
    /// timelock's own event log that anything was wrong. Found in review by doing exactly that.
    ///
    /// These five proxies are deployed minutes apart by one script and upgraded by copy-pasted `cast`
    /// commands. Pointing one at the neighbouring implementation is the single most plausible operator
    /// mistake in the whole procedure, and it is precisely what these checks exist to catch. So this
    /// walks the full 5x5 grid rather than spot-checking: the diagonal must be accepted, every one of
    /// the twenty off-diagonal pairs refused.
    function test_noProxyAcceptsAnotherSystemContractAsItsImplementation() public {
        _handOverToTimelock();

        address[5] memory proxies =
            [address(launcher), address(locker), address(vault), address(rewards), address(registry)];
        address[5] memory impls = [launcherImpl, lockerImpl, vaultImpl, rewardsImpl, registryImpl];

        for (uint256 i; i < proxies.length; ++i) {
            for (uint256 j; j < impls.length; ++j) {
                if (i == j) continue;
                _expectTimelockedRevert(proxies[i], impls[j]);
            }
        }
    }

    /// @dev The other half: the grid above must not be passing because *everything* is refused. Each
    /// proxy still accepts a fresh implementation of its own kind, which is the upgrade path itself.
    function test_everyProxyStillAcceptsItsOwnKind() public {
        _handOverToTimelock();

        address[5] memory proxies =
            [address(launcher), address(locker), address(vault), address(rewards), address(registry)];
        address[5] memory freshImpls = [
            address(new ArchemistV4Launcher(manager, block.chainid)),
            address(new ArchemistV4Locker(manager, block.chainid)),
            address(new ArchemistBuybackVault(manager, arch, linkedUsdc, address(v3Factory), block.chainid)),
            address(new ArchemistHolderRewards(block.chainid)),
            address(new ArchemistPairRegistry(address(0), block.chainid))
        ];

        for (uint256 i; i < proxies.length; ++i) {
            _upgradeViaTimelock(proxies[i], freshImpls[i]);
            assertEq(_implementationOf(proxies[i]), freshImpls[i], "an in-kind upgrade must still work");
        }
    }

    /// @dev The tags must actually be distinct, or the grid above passes for the wrong reason.
    function test_everySystemContractHasADistinctKind() public view {
        bytes32[5] memory kinds = [
            launcher.ARCHEMIST_KIND(),
            locker.ARCHEMIST_KIND(),
            vault.ARCHEMIST_KIND(),
            rewards.ARCHEMIST_KIND(),
            registry.ARCHEMIST_KIND()
        ];
        for (uint256 i; i < kinds.length; ++i) {
            assertTrue(kinds[i] != bytes32(0), "an unset kind would match another unset kind");
            for (uint256 j = i + 1; j < kinds.length; ++j) {
                assertTrue(kinds[i] != kinds[j], "two system contracts share an ARCHEMIST_KIND");
            }
        }
    }

    /// @dev F9. The vault was the one contract that did not compare `POOL_MANAGER`, and PU-08 tested
    /// only the launcher, so nothing would have noticed. A vault pointed at a different PoolManager
    /// would `take` and `settle` against a venue holding none of its money.
    function test_vaultUpgradeRejectsADifferentPoolManager() public {
        _handOverToTimelock();

        address wrongPm = address(
            new ArchemistBuybackVault(
                IPoolManager(address(0xBEEF)), arch, linkedUsdc, address(v3Factory), block.chainid
            )
        );
        _expectTimelockedRevert(address(vault), wrongPm);

        // ...and the same contract compiled with the right one is accepted, so the revert above is the
        // PoolManager and not something incidental.
        _upgradeViaTimelock(
            address(vault),
            address(new ArchemistBuybackVault(manager, arch, linkedUsdc, address(v3Factory), block.chainid))
        );
    }

    /// @dev Each proxy also refuses an implementation of its own kind compiled for another chain or
    /// another PoolManager - `test_upgradeRejectsDifferentImmutables` covered only the launcher.
    function test_everyProxyRejectsItsOwnKindFromTheWrongChain() public {
        _handOverToTimelock();
        uint256 elsewhere = block.chainid + 1;

        _expectTimelockedRevert(address(launcher), address(new ArchemistV4Launcher(manager, elsewhere)));
        _expectTimelockedRevert(address(locker), address(new ArchemistV4Locker(manager, elsewhere)));
        _expectTimelockedRevert(
            address(vault), address(new ArchemistBuybackVault(manager, arch, linkedUsdc, address(v3Factory), elsewhere))
        );
        _expectTimelockedRevert(address(rewards), address(new ArchemistHolderRewards(elsewhere)));
        _expectTimelockedRevert(address(registry), address(new ArchemistPairRegistry(address(0), elsewhere)));
    }

    // -------------------------------------------------------------------------------------------
    // PU-09..PU-11 - state across an upgrade
    // -------------------------------------------------------------------------------------------

    function test_upgradePreservesState() public {
        // Build up real state: a second registered hook (disabled), a launched token, a creator with
        // claimable fees, and a pending recipient-admin transfer.
        ArchemistV4Hook hookB = _deploySecondHook(address(vault));
        launcher.registerHook(address(hookB));
        launcher.setHookEnabled(address(hookB), false);

        ArchemistV4Launcher.LaunchParams memory p =
            _launchParams(address(hook), address(0), keccak256("state"), 300_000, 120, 10_000, address(0xFEE));
        // == INITIAL_SUPPLY -> a 1:1 price ratio -> tick 0, comfortably inside the pair's band.
        p.targetFdvQuoteRaw = 1_000_000_000 ether;
        (address token, PoolId poolId) = launcher.createToken(p);

        uint256 totalBefore = launcher.getTotalTokens();
        address hookBefore = launcher.launchInfoForToken(token).hook;
        uint256 supplyBefore = ArchemistV4Token(token).balanceOf(address(locker));
        bytes32 keyHash = keccak256(abi.encode(locker.getPoolKey(poolId)));

        _handOverToTimelock();
        LauncherV2Mock v2 = new LauncherV2Mock(manager, block.chainid);
        _timelockExec(
            address(launcher),
            abi.encodeWithSignature(
                "upgradeToAndCall(address,bytes)", address(v2), abi.encodeCall(LauncherV2Mock.initializeV2, (42))
            )
        );

        assertEq(launcher.getTotalTokens(), totalBefore, "token count survived");
        assertEq(launcher.launchInfoForToken(token).hook, hookBefore, "the pool's hook survived");
        assertEq(launcher.allTokens(0), token);
        assertTrue(launcher.isKnownHook(address(hook)));
        assertTrue(launcher.isKnownHook(address(hookB)));
        assertEq(launcher.knownHooksLength(), 2);
        assertEq(ArchemistV4Token(token).balanceOf(address(locker)), supplyBefore);
        assertEq(keccak256(abi.encode(locker.getPoolKey(poolId))), keyHash, "the locker's pool key survived");
        assertEq(LauncherV2Mock(payable(address(launcher))).appended(), 42, "the appended field is readable");
    }

    function test_reinitializerRunsOnceOnUpgrade() public {
        _handOverToTimelock();
        LauncherV2Mock v2 = new LauncherV2Mock(manager, block.chainid);
        bytes memory migrate = abi.encodeCall(LauncherV2Mock.initializeV2, (7));
        _timelockExec(
            address(launcher), abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(v2), migrate)
        );
        assertEq(LauncherV2Mock(payable(address(launcher))).appended(), 7);

        // A second run of the same migration must refuse, or an upgrade could re-run a one-time step.
        vm.prank(address(timelock));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        LauncherV2Mock(payable(address(launcher))).initializeV2(8);
    }

    // -------------------------------------------------------------------------------------------
    // PU-12..PU-17 - proxy mechanics
    // -------------------------------------------------------------------------------------------

    function test_ownershipHandoverIsTwoStep() public {
        launcher.transferOwnership(address(timelock));
        assertEq(launcher.owner(), address(this), "nothing changes until the timelock accepts");

        _timelockExec(address(launcher), abi.encodeWithSignature("acceptOwnership()"));
        assertEq(launcher.owner(), address(timelock));

        address newImpl = address(new ArchemistV4Launcher(manager, block.chainid));
        vm.expectRevert(abi.encodeWithSelector(ArchemistUpgradeable.OwnableUnauthorizedAccount.selector, address(this)));
        launcher.upgradeToAndCall(newImpl, "");
    }

    /// @dev OZ's `ERC1967Proxy` has no `receive()`, so an empty-calldata native transfer falls through
    /// to `fallback` and is delegated - which means the implementation's own `receive()` sender check
    /// still runs. That is an assumption worth proving rather than believing.
    function test_nativeTransfersReachImplementationReceive() public {
        vm.deal(address(this), 3 ether);
        vm.deal(address(manager), 3 ether);
        vm.deal(address(0xBEEF), 3 ether);
        vm.prank(address(manager));
        (bool ok,) = address(locker).call{ value: 1 ether }("");
        assertTrue(ok, "the PoolManager may pay the locker");
        assertEq(address(locker).balance, 1 ether);

        vm.prank(address(0xBEEF));
        (bool rejected,) = address(locker).call{ value: 1 ether }("");
        assertFalse(rejected, "a random EOA may not - the impl's check still applies through the proxy");

        vm.prank(address(0xBEEF));
        (bool rewardsRejected,) = address(rewards).call{ value: 1 ether }("");
        assertFalse(rewardsRejected);
        vm.prank(address(0xBEEF));
        (bool vaultRejected,) = address(vault).call{ value: 1 ether }("");
        assertFalse(vaultRejected);
    }

    function test_delegatecallContextForCallbacks() public {
        // Every cross-contract check now compares against a PROXY address.
        assertEq(locker.LAUNCHER(), address(launcher));
        assertEq(rewards.LAUNCHER(), address(launcher));
        assertEq(rewards.LOCKER(), address(locker));
        assertEq(vault.LOCKER(), address(locker));
        assertEq(hook.launcher(), address(launcher));
        assertEq(hook.locker(), address(locker));
        assertEq(launcher.LOCKER(), address(locker));

        // And the `onlyX` guards reject anything else.
        vm.expectRevert(ArchemistV4Locker.NotAuthorized.selector);
        locker.unlockCallback(bytes(""));
        vm.expectRevert(ArchemistHolderRewards.NotLauncher.selector);
        rewards.register(address(0xDEAD), address(0));
        vm.expectRevert(ArchemistHolderRewards.NotLocker.selector);
        rewards.notify(address(0xDEAD), address(0), 1);
    }

    function test_proxyHasNoAdminFunctionsOfItsOwn() public {
        // The proxy is dumb: `upgradeToAndCall` is delegated to the implementation and rejected THERE,
        // not intercepted by the proxy, and an unknown selector finds no function at all.
        vm.prank(address(0xBEEF));
        vm.expectRevert(
            abi.encodeWithSelector(ArchemistUpgradeable.OwnableUnauthorizedAccount.selector, address(0xBEEF))
        );
        launcher.upgradeToAndCall(address(0xDEAD), "");

        (bool ok,) = address(launcher).call(abi.encodeWithSignature("changeAdmin(address)", address(0xBEEF)));
        assertFalse(ok);
        (bool ok2,) = address(launcher).call(abi.encodeWithSignature("admin()"));
        assertFalse(ok2);
    }

    // -------------------------------------------------------------------------------------------
    // PU-18..PU-23 - the timelock itself
    // -------------------------------------------------------------------------------------------

    function test_timelockRolesAreMinimal() public view {
        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        bytes32 cancellerRole = timelock.CANCELLER_ROLE();
        bytes32 executorRole = timelock.EXECUTOR_ROLE();
        bytes32 adminRole = timelock.DEFAULT_ADMIN_ROLE();

        assertTrue(timelock.hasRole(adminRole, address(timelock)), "the timelock is its own admin");
        assertFalse(timelock.hasRole(adminRole, address(this)), "and nobody else is");
        assertTrue(timelock.hasRole(proposerRole, address(this)));
        assertTrue(timelock.hasRole(cancellerRole, address(this)));
        assertFalse(timelock.hasRole(proposerRole, address(0xBEEF)));
        assertFalse(timelock.hasRole(proposerRole, address(launcher)));
        assertTrue(timelock.hasRole(executorRole, address(0)), "execution is open to anyone");
        assertGe(timelock.getMinDelay(), 48 hours);
    }

    function test_timelockCannotLowerDelayWithoutDelay() public {
        // "Temporarily set the delay to zero" must be impossible to do quietly. A direct call is
        // rejected outright; going through the timelock still costs the CURRENT delay.
        vm.expectRevert();
        timelock.updateDelay(0);

        bytes memory data = abi.encodeCall(TimelockController.updateDelay, (0));
        timelock.schedule(address(timelock), 0, data, bytes32(0), bytes32("delay"), TIMELOCK_DELAY);
        vm.expectRevert();
        timelock.execute(address(timelock), 0, data, bytes32(0), bytes32("delay"));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        timelock.execute(address(timelock), 0, data, bytes32(0), bytes32("delay"));
        assertEq(timelock.getMinDelay(), 0, "which is why it must never be scheduled on a live network");
    }

    function test_executorIsOpen() public {
        _handOverToTimelock();
        address newImpl = address(new ArchemistV4Launcher(manager, block.chainid));
        bytes memory data = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", newImpl, bytes(""));
        timelock.schedule(address(launcher), 0, data, bytes32(0), bytes32("open"), TIMELOCK_DELAY);
        vm.warp(block.timestamp + TIMELOCK_DELAY);

        // Nobody can be locked out of executing a change that is already public.
        vm.prank(address(0xF00D));
        timelock.execute(address(launcher), 0, data, bytes32(0), bytes32("open"));
        assertEq(_implementationOf(address(launcher)), newImpl);
    }

    /// @dev D10's exit path: the proposer role moves to a multisig with no upgrade and no redeploy.
    function test_proposerCanBeMigratedToMultisigWithoutUpgrade() public {
        _handOverToTimelock();
        address multisig = address(0xC0FFEE1);
        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        bytes32 cancellerRole = timelock.CANCELLER_ROLE();
        address launcherImplBefore = _implementationOf(address(launcher));

        _timelockExec(address(timelock), abi.encodeWithSignature("grantRole(bytes32,address)", proposerRole, multisig));
        _timelockExec(address(timelock), abi.encodeWithSignature("grantRole(bytes32,address)", cancellerRole, multisig));
        assertTrue(timelock.hasRole(proposerRole, multisig));

        // The multisig can now schedule, and it revokes the deployer key.
        bytes memory revoke = abi.encodeWithSignature("revokeRole(bytes32,address)", proposerRole, address(this));
        vm.prank(multisig);
        timelock.schedule(address(timelock), 0, revoke, bytes32(0), bytes32("revoke"), TIMELOCK_DELAY);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        timelock.execute(address(timelock), 0, revoke, bytes32(0), bytes32("revoke"));

        assertFalse(timelock.hasRole(proposerRole, address(this)), "the old key can no longer schedule");
        vm.expectRevert();
        timelock.schedule(address(launcher), 0, bytes(""), bytes32(0), bytes32("nope"), TIMELOCK_DELAY);
        assertEq(_implementationOf(address(launcher)), launcherImplBefore, "no proxy was touched");
    }

    /// @dev The realistic D10 incident, rehearsed. A leaked proposer key can SCHEDULE anything; what it
    /// cannot do is make it happen inside 48 hours, and every attempt is a public `CallScheduled` event
    /// that the canceller answers.
    function test_leakedProposerKeyIsBoundedByDelayAndCancel() public {
        _handOverToTimelock();
        address drain = address(new NotUUPS());
        address before = _implementationOf(address(locker));
        bytes memory data = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", drain, bytes(""));

        for (uint256 attempt; attempt < 2; ++attempt) {
            bytes32 salt = bytes32(attempt);
            timelock.schedule(address(locker), 0, data, bytes32(0), salt, TIMELOCK_DELAY);
            // The defence is that the whole 48 hours is public. Cancel with an hour to spare.
            vm.warp(block.timestamp + TIMELOCK_DELAY - 1 hours);
            timelock.cancel(timelock.hashOperation(address(locker), 0, data, bytes32(0), salt));
            vm.warp(block.timestamp + 2 hours);
            vm.expectRevert();
            timelock.execute(address(locker), 0, data, bytes32(0), salt);
        }
        assertEq(_implementationOf(address(locker)), before, "funds and code never moved");
    }

    // -------------------------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------------------------

    function _implementationOf(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
    }

    /// @dev The mirror of `_expectTimelockedRevert`: schedule, wait out the delay, execute, succeed.
    /// The salt binds the implementation and the timestamp so repeated calls in one test do not collide
    /// on an already-scheduled operation id.
    function _upgradeViaTimelock(address proxy, address newImpl) private {
        bytes memory data = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", newImpl, bytes(""));
        bytes32 salt = keccak256(abi.encode(proxy, newImpl, block.timestamp));
        timelock.schedule(proxy, 0, data, bytes32(0), salt, TIMELOCK_DELAY);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        timelock.execute(proxy, 0, data, bytes32(0), salt);
    }

    function _expectTimelockedRevert(address proxy, address newImpl) private {
        bytes memory data = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", newImpl, bytes(""));
        bytes32 salt = keccak256(abi.encode(newImpl, block.timestamp));
        timelock.schedule(proxy, 0, data, bytes32(0), salt, TIMELOCK_DELAY);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert();
        timelock.execute(proxy, 0, data, bytes32(0), salt);
    }
}
