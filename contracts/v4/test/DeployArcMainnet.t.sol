// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { PoolManager } from "@uniswap/v4-core/src/PoolManager.sol";

import { DeployArcMainnet } from "../script/DeployArcMainnet.s.sol";
import { VerifyDeployment } from "../script/VerifyDeployment.s.sol";
import { ArchemistPairRegistry } from "../src/ArchemistPairRegistry.sol";
import { MockStandardQuote } from "./mocks/ProbeMocks.sol";

/// @dev Lets the test mine the hook's salt for itself. Under `forge script --broadcast` a salted
/// `new` is routed through the canonical CREATE2 deployer; inside `forge test` it is not.
contract DeployArcMainnetHarness is DeployArcMainnet {
    function _create2Deployer() internal view override returns (address) {
        return address(this);
    }

    function deployForTest(address deployer, address treasury, uint256 delay, address proposer)
        external
        returns (Deployed memory)
    {
        return _deploy(deployer, treasury, 0, delay, proposer);
    }

    function requireSafeDelayForTest(uint256 delay) external pure {
        _requireSafeDelay(delay);
    }
}

/// @notice Runs the **mainnet** deploy script end to end.
///
/// This test exists because the script was broken and nothing caught it. Every other caller of
/// `ArchemistPairRegistry` - the testnet script, the fixture, `Deploy.sol` - passes
/// `canonicalNativeAlias = address(0)`, so the one argument the mainnet script passed differently was
/// the one argument no test ever evaluated. It reverted `CanonicalConflict` on the second `addPair`,
/// and it would have reverted on the real broadcast.
///
/// The lesson generalises past that one bug: a deploy script is production code that runs exactly once,
/// under conditions nothing else reproduces, and it is the least forgiving code in the repo to get
/// wrong. So this runs the real `_deploy` body, on the real chain id, against the real infrastructure
/// addresses, and asserts the same wiring the script asserts before it hands over ownership.
contract DeployArcMainnetTest is Test {
    uint256 internal constant ARC_CHAIN_ID = 5042;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant ARCH = 0x5042419b1F2498959787Bc23Be1F484Ed1306650;
    address internal constant LINKED_USDC = 0x3600000000000000000000000000000000000000;
    address internal constant ARCH_V3_POOL = 0xC7CF0c94850c912A5045f2A0f2d70Ca18085b829;
    address internal constant UNISWAP_V3_FACTORY = 0xf0db7b58379503491d857dB50AC9ece64c653918;

    DeployArcMainnetHarness internal script;
    /// @dev The harness itself is the deployer. On a real run `vm.startBroadcast(deployerKey)` makes
    /// the deployer both the address the proxies are initialized as owner of AND the caller of the
    /// owner-only wiring that follows; splitting them here would fail for a reason mainnet will not have.
    address internal deployer;
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        vm.chainId(ARC_CHAIN_ID);
        // The script refuses to run unless each of these has code, which is the check that would
        // otherwise make this test a no-op.
        vm.etch(POOL_MANAGER, address(new PoolManager(address(this))).code);
        vm.etch(ARCH, address(new MockStandardQuote(18)).code);
        // Linked USDC is 6 decimals, and the registry reads `decimals()` off it.
        vm.etch(LINKED_USDC, address(new MockStandardQuote(6)).code);
        vm.etch(UNISWAP_V3_FACTORY, address(new MockStandardQuote(18)).code);
        vm.etch(ARCH_V3_POOL, address(new MockStandardQuote(18)).code);
        script = new DeployArcMainnetHarness();
        deployer = address(script);
    }

    function test_mainnetDeployScriptRuns() public {
        DeployArcMainnet.Deployed memory d = script.deployForTest(deployer, treasury, 48 hours, deployer);

        // Both quote currencies are registered. This is the assertion that fails if anyone sets
        // `canonicalNativeAlias` to LINKED_USDC again: the second addPair would revert.
        assertTrue(d.registry.getPair(address(0)).enabled, "native pair must be listed");
        assertTrue(d.registry.getPair(LINKED_USDC).enabled, "linked-USDC pair must be listed");
        assertEq(d.registry.getPair(LINKED_USDC).buybackRoute, ARCH_V3_POOL, "ARCH route must be wired");
        assertEq(d.registry.pairCount(), 2);

        // The script's own `_assertWiring` already ran inside `_deploy`; re-assert the handful that
        // would make the deployment unusable rather than merely wrong.
        assertEq(d.launcher.LOCKER(), address(d.locker));
        assertEq(d.locker.LAUNCHER(), address(d.launcher));
        assertEq(d.vault.LOCKER(), address(d.locker));
        assertEq(d.holderRewards.LAUNCHER(), address(d.launcher));
        assertTrue(d.launcher.isKnownHook(address(d.hook)), "the mined hook must be registered");
        assertEq(uint160(address(d.hook)) & 0x3FFF, 0x28CC, "hook address bits must equal its permissions");
        assertEq(d.vault.ARCH_SINK(), 0x000000000000000000000000000000000000dEaD);
    }

    /// @dev The two-step handover is what makes a typo'd timelock address recoverable instead of
    /// terminal, so the script must leave it half-done rather than complete.
    function test_deployLeavesOwnershipPendingNotTransferred() public {
        DeployArcMainnet.Deployed memory d = script.deployForTest(deployer, treasury, 48 hours, deployer);

        assertEq(d.launcher.owner(), deployer, "deployer still owns it until the timelock accepts");
        assertEq(d.launcher.pendingOwner(), address(d.timelock));
        assertEq(d.locker.pendingOwner(), address(d.timelock));
        assertEq(d.vault.pendingOwner(), address(d.timelock));
        assertEq(d.holderRewards.pendingOwner(), address(d.timelock));
        assertEq(d.registry.pendingOwner(), address(d.timelock));
    }

    /// @dev F7. The script used to stop at `pendingOwner == timelock`, leaving five `acceptOwnership`
    /// operations for somebody to remember to propose - and until they did, one EOA could upgrade any
    /// contract in the system instantly, which is the exact power the timelock exists to remove.
    /// Nothing enforced that the handover ever finished. Now the same broadcast schedules all five.
    function test_deployAlsoSchedulesTheHandoverAcceptance() public {
        DeployArcMainnet.Deployed memory d = script.deployForTest(deployer, treasury, 48 hours, deployer);

        address[5] memory proxies =
            [address(d.registry), address(d.launcher), address(d.locker), address(d.vault), address(d.holderRewards)];
        bytes memory acceptCall = abi.encodeWithSignature("acceptOwnership()");

        for (uint256 i; i < proxies.length; ++i) {
            bytes32 id = d.timelock.hashOperation(proxies[i], 0, acceptCall, bytes32(0), script.HANDOVER_SALT());
            assertTrue(d.timelock.isOperationPending(id), "acceptOwnership must already be scheduled");
            assertFalse(d.timelock.isOperationReady(id), "and must not be executable yet");
        }

        // It is still only step two of three: the delay is real, and anyone may finish it afterwards.
        vm.warp(block.timestamp + 48 hours);
        for (uint256 i; i < proxies.length; ++i) {
            vm.prank(makeAddr("a passer-by"));
            d.timelock.execute(proxies[i], 0, acceptCall, bytes32(0), script.HANDOVER_SALT());
        }
        assertEq(d.launcher.owner(), address(d.timelock));
        assertEq(d.locker.owner(), address(d.timelock));
        assertEq(d.vault.owner(), address(d.timelock));
        assertEq(d.holderRewards.owner(), address(d.timelock));
        assertEq(d.registry.owner(), address(d.timelock));
    }

    /// @dev ...and the deployer can still back out before they mature, which is the whole reason the
    /// handover is two-step. A typo'd timelock address must not be terminal.
    function test_theDeployerCanStillRedirectOwnershipBeforeTheDelayElapses() public {
        DeployArcMainnet.Deployed memory d = script.deployForTest(deployer, treasury, 48 hours, deployer);
        address rescue = makeAddr("a correctly typed owner");

        vm.prank(deployer);
        d.launcher.transferOwnership(rescue);
        assertEq(d.launcher.pendingOwner(), rescue, "the pending owner is replaceable until accepted");

        // Read before arming: an `expectRevert` latches onto the very next call, and a getter that
        // returns normally would satisfy it.
        bytes32 salt = script.HANDOVER_SALT();
        bytes memory acceptCall = abi.encodeWithSignature("acceptOwnership()");

        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert();
        d.timelock.execute(address(d.launcher), 0, acceptCall, bytes32(0), salt);
        assertEq(d.launcher.pendingOwner(), rescue, "the stale operation cannot take the launcher back");
    }

    /// @dev When the proposer is somebody else, this broadcast has no right to propose anything, so it
    /// must not try - a reverting deploy is far worse than a handover that needs one more command.
    function test_deploySkipsSchedulingWhenTheProposerIsNotTheDeployer() public {
        address proposer = makeAddr("a separate proposer");
        DeployArcMainnet.Deployed memory d = script.deployForTest(deployer, treasury, 48 hours, proposer);

        bytes32 id = d.timelock
            .hashOperation(
                address(d.launcher), 0, abi.encodeWithSignature("acceptOwnership()"), bytes32(0), script.HANDOVER_SALT()
            );
        assertFalse(d.timelock.isOperation(id), "nothing may be scheduled by a non-proposer");
        assertEq(d.launcher.pendingOwner(), address(d.timelock), "but the handover still started");
    }

    /// @dev **The post-deploy check, checked.** `VerifyDeployment` exists because everything the deploy
    /// script asserts, it asserts about state it created moments earlier in its own transaction - which
    /// cannot see a handover that was scheduled and never executed, or a stack that was changed after
    /// the fact. A verifier nobody has run against a real stack is just more source code, so this runs
    /// it against one, after finishing the handover exactly as mainnet will.
    function test_verifyDeploymentPassesOnAFinishedDeployment() public {
        VerifyDeployment verifier = _verifierFor(_finishedStack());
        verifier.run();
    }

    /// @dev And the case it exists for: the deploy ran, the handover was started, and the five
    /// `acceptOwnership` operations were never executed. Every cross-link is perfect; one EOA can still
    /// upgrade the entire system instantly. The verifier must refuse this.
    function test_verifyDeploymentRejectsAnUnfinishedHandover() public {
        DeployArcMainnet.Deployed memory d = script.deployForTest(deployer, treasury, 48 hours, deployer);
        VerifyDeployment verifier = _verifierFor(d);

        vm.expectRevert("deployment verification failed");
        verifier.run();
    }

    /// @dev ...and a stack whose hook was disabled after the fact, which no amount of deploy-time
    /// assertion could ever have caught.
    function test_verifyDeploymentRejectsADisabledHook() public {
        DeployArcMainnet.Deployed memory d = _finishedStack();
        VerifyDeployment verifier = _verifierFor(d);

        vm.prank(address(d.timelock));
        d.launcher.setHookEnabled(address(d.hook), false);

        vm.expectRevert("deployment verification failed");
        verifier.run();
    }

    /// @dev Deploys, then executes the handover the way mainnet will: schedule (already done inside the
    /// broadcast), wait out the delay, execute.
    function _finishedStack() private returns (DeployArcMainnet.Deployed memory d) {
        d = script.deployForTest(deployer, treasury, 48 hours, deployer);
        address[5] memory proxies =
            [address(d.registry), address(d.launcher), address(d.locker), address(d.vault), address(d.holderRewards)];
        bytes memory acceptCall = abi.encodeWithSignature("acceptOwnership()");
        bytes32 salt = script.HANDOVER_SALT();

        vm.warp(block.timestamp + 48 hours);
        for (uint256 i; i < proxies.length; ++i) {
            d.timelock.execute(proxies[i], 0, acceptCall, bytes32(0), salt);
        }
        vm.prank(address(d.timelock));
        d.launcher.enableCreate();
    }

    function _verifierFor(DeployArcMainnet.Deployed memory d) private returns (VerifyDeployment verifier) {
        verifier = new VerifyDeployment();
        vm.setEnv("TIMELOCK", vm.toString(address(d.timelock)));
        vm.setEnv("REGISTRY", vm.toString(address(d.registry)));
        vm.setEnv("LAUNCHER", vm.toString(address(d.launcher)));
        vm.setEnv("LOCKER", vm.toString(address(d.locker)));
        vm.setEnv("VAULT", vm.toString(address(d.vault)));
        vm.setEnv("REWARDS", vm.toString(address(d.holderRewards)));
        vm.setEnv("HOOK", vm.toString(address(d.hook)));
        vm.setEnv("PROPOSER", vm.toString(deployer));
        vm.setEnv("ARCH", vm.toString(ARCH));
        vm.setEnv("LINKED_USDC", vm.toString(LINKED_USDC));
    }

    /// @dev Mainnet governance IS the delay, and the testnet script legitimately uses 600 seconds.
    /// The only thing keeping an operator from carrying that habit across is this guard.
    function test_mainnetScriptRefusesAShortDelay() public {
        vm.expectRevert(abi.encodeWithSelector(DeployArcMainnet.DelayTooShort.selector, uint256(10 minutes)));
        script.requireSafeDelayForTest(10 minutes);

        vm.expectRevert(abi.encodeWithSelector(DeployArcMainnet.DelayTooShort.selector, uint256(48 hours - 1)));
        script.requireSafeDelayForTest(48 hours - 1);

        script.requireSafeDelayForTest(48 hours);
        script.requireSafeDelayForTest(72 hours);
    }
}
