// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

import { ArchemistHolderRewards } from "../src/ArchemistHolderRewards.sol";
import { ArchemistPairRegistry } from "../src/ArchemistPairRegistry.sol";
import { ArchemistV4Launcher } from "../src/ArchemistV4Launcher.sol";
import { ArchemistV4Token } from "../src/ArchemistV4Token.sol";
import { AntiSnipeParams, ArchemistV4Constants, FeeRecipient, PairConfig } from "../src/ArchemistV4Types.sol";
import { ArchemistUpgradeable } from "../src/upgradeability/ArchemistUpgradeable.sol";
import { ArchemistDeploy } from "./Deploy.sol";

contract MockLauncherPoolManager {
    bool public sawLockedConfig;

    function extsload(bytes32) external pure returns (bytes32) {
        return bytes32(0);
    }

    function initialize(PoolKey memory key, uint160) external returns (int24) {
        sawLockedConfig = MockLauncherHook(address(key.hooks)).configured(key.toId());
        return 0;
    }
}

contract MockLauncherLocker {
    using PoolIdLibrary for PoolKey;

    address public immutable LAUNCHER;
    IPoolManager public immutable POOL_MANAGER;
    mapping(PoolId => address) public currency0ForPool;
    mapping(PoolId => address) public currency1ForPool;
    mapping(PoolId => int24) public tickSpacingForPool;
    mapping(PoolId => int24) public tickLowerForPool;
    mapping(PoolId => int24) public tickUpperForPool;
    mapping(PoolId => address) public hookForPool;

    constructor(address launcher_, IPoolManager poolManager_) {
        LAUNCHER = launcher_;
        POOL_MANAGER = poolManager_;
    }

    function seedPosition(
        address token,
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint16,
        FeeRecipient[] calldata
    ) external returns (PoolId, uint128, uint256) {
        require(msg.sender == LAUNCHER);
        PoolId poolId = key.toId();
        currency0ForPool[poolId] = Currency.unwrap(key.currency0);
        currency1ForPool[poolId] = Currency.unwrap(key.currency1);
        tickSpacingForPool[poolId] = key.tickSpacing;
        tickLowerForPool[poolId] = tickLower;
        tickUpperForPool[poolId] = tickUpper;
        hookForPool[poolId] = address(key.hooks);
        return (poolId, 123, ArchemistV4Token(token).balanceOf(address(this)));
    }
}

contract MockLauncherQuote {
    uint8 public immutable decimals;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }
}

/// @dev Stands in for a registered hook. It declares the same six permissions the real hook does, so
/// that `registerHook`'s address-bits check is exercised for real, and it applies the same
/// `AntiSnipeParams` bounds the hook now owns (they used to live in the launcher - LA-06 proves they
/// were not simply dropped in the move).
contract MockLauncherHook {
    using PoolIdLibrary for PoolKey;

    address public immutable launcher;
    address public immutable locker;
    IPoolManager public immutable poolManager;
    mapping(PoolId => bool) public configured;
    mapping(PoolId => bytes) public paramsSeen;

    error InvalidConfiguration();

    constructor(address launcher_, address locker_, IPoolManager poolManager_) {
        launcher = launcher_;
        locker = locker_;
        poolManager = poolManager_;
    }

    function getHookPermissions() external pure virtual returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = true;
        permissions.beforeAddLiquidity = true;
        permissions.beforeSwap = true;
        permissions.afterSwap = true;
        permissions.beforeSwapReturnDelta = true;
        permissions.afterSwapReturnDelta = true;
    }

    function lockConfig(PoolKey calldata key, address token, Currency, bool, bytes calldata params) external {
        require(msg.sender == launcher);
        require(token != address(0));
        AntiSnipeParams memory anti = abi.decode(params, (AntiSnipeParams));
        if (
            anti.startHookFee < ArchemistV4Constants.BASE_HOOK_FEE
                || anti.startHookFee > ArchemistV4Constants.MAX_START_HOOK_FEE || anti.windowSeconds == 0
                || anti.windowSeconds > ArchemistV4Constants.MAX_WINDOW_SECONDS || anti.maxBuyBps == 0
                || anti.maxBuyBps > 10_000
        ) revert InvalidConfiguration();
        configured[key.toId()] = true;
        paramsSeen[key.toId()] = params;
    }
}

/// @dev Same wiring, different declared permissions - so its address bits cannot match.
contract WrongPermissionsHook is MockLauncherHook {
    constructor(address launcher_, address locker_, IPoolManager poolManager_)
        MockLauncherHook(launcher_, locker_, poolManager_)
    { }

    function getHookPermissions() external pure override returns (Hooks.Permissions memory permissions) {
        permissions.beforeSwap = true;
    }
}

contract TreasuryReceiver {
    receive() external payable { }
}

contract ArchemistV4LauncherTest is Test {
    uint256 internal constant DEPLOY_FEE = 0.1 ether;
    // Any address whose low 14 bits are 0x28CC is a validly-mined hook address for these permissions.
    address internal constant HOOK_A = address(0x28CC);
    address internal constant HOOK_B = address(0xaaAA000000000000000000000000000000a028Cc);
    address internal constant HOOK_C = address(0xbBBb000000000000000000000000000000B028cc);

    MockLauncherPoolManager internal manager;
    TreasuryReceiver internal treasury;
    ArchemistV4Launcher internal launcher;
    ArchemistPairRegistry internal registry;
    MockLauncherLocker internal locker;
    ArchemistHolderRewards internal holderRewards;
    address internal hook = HOOK_A;

    function setUp() public {
        manager = new MockLauncherPoolManager();
        treasury = new TreasuryReceiver();
        registry = ArchemistDeploy.registry(address(this), address(0));
        registry.addPair(address(0), _nativePair(), 0, false);
        launcher = _newLauncher();
        locker = new MockLauncherLocker(address(launcher), IPoolManager(address(manager)));
        holderRewards = ArchemistDeploy.rewards(address(this), address(launcher), address(locker));

        launcher.configureSystemOnce(address(locker), address(treasury), address(holderRewards));
        _etchHook(HOOK_A);
        launcher.registerHook(HOOK_A);
        launcher.enableCreate();
    }

    // -------------------------------------------------------------------------------------------
    // LA-01..LA-09 - the hook registry
    // -------------------------------------------------------------------------------------------

    function test_registerHookValidationMatrix() public {
        // Not a contract.
        vm.expectRevert(ArchemistV4Launcher.NotAContract.selector);
        launcher.registerHook(address(0xDEAD));

        vm.expectRevert(ArchemistV4Launcher.InvalidAddress.selector);
        launcher.registerHook(address(0));

        // Wired to a different launcher.
        ArchemistV4Launcher other = _newLauncher();
        _etchAt(HOOK_B, address(new MockLauncherHook(address(other), address(locker), IPoolManager(address(manager)))));
        vm.expectRevert(ArchemistV4Launcher.HookLauncherMismatch.selector);
        launcher.registerHook(HOOK_B);

        // Wired to a different locker.
        _etchAt(
            HOOK_B, address(new MockLauncherHook(address(launcher), address(0xBEEF), IPoolManager(address(manager))))
        );
        vm.expectRevert(ArchemistV4Launcher.HookLockerMismatch.selector);
        launcher.registerHook(HOOK_B);

        // Wired to a different PoolManager.
        _etchAt(
            HOOK_B, address(new MockLauncherHook(address(launcher), address(locker), IPoolManager(address(0xFEED))))
        );
        vm.expectRevert(ArchemistV4Launcher.HookPoolManagerMismatch.selector);
        launcher.registerHook(HOOK_B);

        // Correctly wired, but its address bits do not match the permissions it declares - so
        // PoolManager would silently skip callbacks it claims to implement.
        _etchAt(
            HOOK_B,
            address(new WrongPermissionsHook(address(launcher), address(locker), IPoolManager(address(manager))))
        );
        vm.expectRevert(ArchemistV4Launcher.HookAddressMismatch.selector);
        launcher.registerHook(HOOK_B);

        // The good case, and then the duplicate.
        _etchHook(HOOK_B);
        vm.expectEmit(true, false, false, false, address(launcher));
        emit ArchemistV4Launcher.HookRegistered(HOOK_B);
        launcher.registerHook(HOOK_B);
        assertTrue(launcher.isKnownHook(HOOK_B));
        assertTrue(launcher.isHookEnabled(HOOK_B));

        vm.expectRevert(ArchemistV4Launcher.HookAlreadyKnown.selector);
        launcher.registerHook(HOOK_B);
    }

    function test_registerHookIsOwnerOnly() public {
        _etchHook(HOOK_B);
        address[2] memory callers = [address(0xBEEF), HOOK_B];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(
                abi.encodeWithSelector(ArchemistUpgradeable.OwnableUnauthorizedAccount.selector, callers[i])
            );
            launcher.registerHook(HOOK_B);
        }
    }

    function test_setHookEnabledAffectsOnlyFutureLaunches() public {
        ArchemistV4Launcher.LaunchParams memory p = _validParams();
        p.salt = keccak256("t1");
        (address t1,) = launcher.createToken{ value: DEPLOY_FEE }(p);

        launcher.setHookEnabled(HOOK_A, false);
        assertTrue(launcher.isKnownHook(HOOK_A), "a disabled hook is still KNOWN, forever");
        assertFalse(launcher.isHookEnabled(HOOK_A));

        p.salt = keccak256("t2");
        vm.expectRevert(abi.encodeWithSelector(ArchemistV4Launcher.HookDisabled.selector, HOOK_A));
        launcher.createToken{ value: DEPLOY_FEE }(p);

        // T1 is untouched: its hook is part of its PoolKey and nobody, including the owner, can change it.
        assertEq(launcher.launchInfoForToken(t1).hook, HOOK_A);

        launcher.setHookEnabled(HOOK_A, true);
        p.salt = keccak256("t3");
        (address t3,) = launcher.createToken{ value: DEPLOY_FEE }(p);
        assertTrue(t3.code.length != 0);
    }

    function test_setHookEnabledRejectsUnknownHook() public {
        vm.expectRevert(abi.encodeWithSelector(ArchemistV4Launcher.HookDisabled.selector, HOOK_B));
        launcher.setHookEnabled(HOOK_B, true);
    }

    function test_launchRequiresAHook() public {
        ArchemistV4Launcher.LaunchParams memory p = _validParams();
        p.hook = address(0);
        vm.expectRevert(abi.encodeWithSelector(ArchemistV4Launcher.HookDisabled.selector, address(0)));
        launcher.createToken{ value: DEPLOY_FEE }(p);

        p.hook = HOOK_B; // a real contract, but never registered
        _etchHook(HOOK_B);
        vm.expectRevert(abi.encodeWithSelector(ArchemistV4Launcher.HookDisabled.selector, HOOK_B));
        launcher.createToken{ value: DEPLOY_FEE }(p);
    }

    function test_twoHooksCoexist() public {
        _etchHook(HOOK_B);
        launcher.registerHook(HOOK_B);

        ArchemistV4Launcher.LaunchParams memory p = _validParams();
        p.salt = keccak256("on-a");
        (, PoolId poolA) = launcher.createToken{ value: DEPLOY_FEE }(p);

        p.salt = keccak256("on-b");
        p.hook = HOOK_B;
        p.hookParams = abi.encode(AntiSnipeParams({ startHookFee: 990_000, windowSeconds: 120, maxBuyBps: 500 }));
        (, PoolId poolB) = launcher.createToken{ value: DEPLOY_FEE }(p);

        assertEq(locker.hookForPool(poolA), HOOK_A);
        assertEq(locker.hookForPool(poolB), HOOK_B);
        // Each hook received its own params and nothing was crossed over.
        assertEq(
            MockLauncherHook(HOOK_B).paramsSeen(poolB),
            abi.encode(AntiSnipeParams({ startHookFee: 990_000, windowSeconds: 120, maxBuyBps: 500 }))
        );
    }

    /// @dev The bounds moved out of the launcher and into the hook. They must not have been lost on the
    /// way: every one of these used to be a launcher-side `InvalidConfiguration`.
    function test_hookParamsAreDecodedAndBoundedByTheHook() public {
        uint256 before = launcher.getTotalTokens();
        bytes[7] memory bad = [
            abi.encode(AntiSnipeParams({ startHookFee: 9_999, windowSeconds: 120, maxBuyBps: 100 })),
            abi.encode(AntiSnipeParams({ startHookFee: 990_001, windowSeconds: 120, maxBuyBps: 100 })),
            abi.encode(AntiSnipeParams({ startHookFee: 300_000, windowSeconds: 0, maxBuyBps: 100 })),
            abi.encode(AntiSnipeParams({ startHookFee: 300_000, windowSeconds: 121, maxBuyBps: 100 })),
            abi.encode(AntiSnipeParams({ startHookFee: 300_000, windowSeconds: 120, maxBuyBps: 0 })),
            abi.encode(AntiSnipeParams({ startHookFee: 300_000, windowSeconds: 120, maxBuyBps: 10_001 })),
            bytes(hex"0badc0de")
        ];
        for (uint256 i; i < bad.length; ++i) {
            ArchemistV4Launcher.LaunchParams memory p = _validParams();
            p.hookParams = bad[i];
            vm.expectRevert();
            launcher.createToken{ value: DEPLOY_FEE }(p);
        }
        assertEq(launcher.getTotalTokens(), before, "no partial launch may survive a rejected config");
    }

    function test_enableCreateRequiresConfiguredSystemAndAHook() public {
        ArchemistV4Launcher fresh = _newLauncher();
        vm.expectRevert(ArchemistV4Launcher.InvalidInfrastructure.selector);
        fresh.enableCreate();

        MockLauncherLocker freshLocker = new MockLauncherLocker(address(fresh), IPoolManager(address(manager)));
        ArchemistHolderRewards freshRewards =
            ArchemistDeploy.rewards(address(this), address(fresh), address(freshLocker));
        fresh.configureSystemOnce(address(freshLocker), address(treasury), address(freshRewards));

        // Configured, but with no hook registered there is nothing a launch could use.
        vm.expectRevert(ArchemistV4Launcher.InvalidInfrastructure.selector);
        fresh.enableCreate();

        _etchAt(
            HOOK_C, address(new MockLauncherHook(address(fresh), address(freshLocker), IPoolManager(address(manager))))
        );
        fresh.registerHook(HOOK_C);
        vm.expectEmit(false, false, false, false, address(fresh));
        emit ArchemistV4Launcher.CreateEnabled();
        fresh.enableCreate();
        assertTrue(fresh.createEnabled());
    }

    function test_retireIsIrrevocable() public {
        launcher.retire();
        assertFalse(launcher.createEnabled());
        assertTrue(launcher.retired());

        vm.expectRevert(ArchemistV4Launcher.Retired_.selector);
        launcher.enableCreate();

        vm.expectRevert(ArchemistV4Launcher.CreateDisabled.selector);
        launcher.createToken{ value: DEPLOY_FEE }(_validParams());
    }

    function test_knownHooksEnumeration() public {
        _etchHook(HOOK_B);
        _etchHook(HOOK_C);
        launcher.registerHook(HOOK_B);
        launcher.registerHook(HOOK_C);
        launcher.setHookEnabled(HOOK_B, false);

        assertEq(launcher.knownHooksLength(), 3);
        assertEq(launcher.knownHookAt(0), HOOK_A);
        assertEq(launcher.knownHookAt(1), HOOK_B);
        assertEq(launcher.knownHookAt(2), HOOK_C);
        assertTrue(launcher.isHookEnabled(HOOK_A));
        assertFalse(launcher.isHookEnabled(HOOK_B));
        assertTrue(launcher.isHookEnabled(HOOK_C));
    }

    function testFuzz_launchParamsNeverLeaveAPartialLaunch(
        uint24 startHookFee,
        uint32 windowSeconds,
        uint16 maxBuyBps,
        uint16 creatorShareBps,
        uint256 targetFdv
    ) public {
        ArchemistV4Launcher.LaunchParams memory p = _validParams();
        p.hookParams = abi.encode(
            AntiSnipeParams({ startHookFee: startHookFee, windowSeconds: windowSeconds, maxBuyBps: maxBuyBps })
        );
        p.creatorShareBps = creatorShareBps;
        p.targetFdvQuoteRaw = targetFdv;

        address predicted = launcher.computeTokenAddress(p.salt, p.name, p.symbol, address(this));
        try launcher.createToken{ value: DEPLOY_FEE }(p) returns (address token, PoolId) {
            assertEq(token, predicted);
            assertEq(launcher.getTotalTokens(), 1);
        } catch {
            assertEq(predicted.code.length, 0, "a rejected launch must leave no token behind");
            assertEq(launcher.getTotalTokens(), 0);
            (, bool registered) = holderRewards.tokenState(predicted);
            assertFalse(registered, "a rejected launch must leave no rewards registration behind");
        }
    }

    // -------------------------------------------------------------------------------------------
    // Behaviour carried over from deployment #6
    // -------------------------------------------------------------------------------------------

    function test_configureSystemIsOneTime() public {
        vm.expectRevert(ArchemistV4Launcher.AlreadyConfigured.selector);
        launcher.configureSystemOnce(address(locker), address(treasury), address(holderRewards));
    }

    function test_configureSystemChecksLinksFromBothEnds() public {
        ArchemistV4Launcher fresh = _newLauncher();
        // A locker wired to a different launcher.
        MockLauncherLocker foreignLocker = new MockLauncherLocker(address(launcher), IPoolManager(address(manager)));
        ArchemistHolderRewards freshRewards =
            ArchemistDeploy.rewards(address(this), address(fresh), address(foreignLocker));
        vm.expectRevert(ArchemistV4Launcher.InvalidInfrastructure.selector);
        fresh.configureSystemOnce(address(foreignLocker), address(treasury), address(freshRewards));
    }

    function test_createLocksConfigBeforeInitializeAndSeedsFullSupply() public {
        ArchemistV4Launcher.LaunchParams memory params = _validParams();
        address predicted = launcher.computeTokenAddress(params.salt, params.name, params.symbol, address(this));
        uint256 treasuryBefore = address(treasury).balance;

        (address tokenAddress, PoolId poolId) = launcher.createToken{ value: DEPLOY_FEE }(params);

        assertEq(tokenAddress, predicted);
        assertTrue(manager.sawLockedConfig(), "the hook's config must be locked BEFORE initialize");
        assertEq(address(treasury).balance - treasuryBefore, DEPLOY_FEE);
        assertEq(ArchemistV4Token(tokenAddress).balanceOf(address(locker)), launcher.INITIAL_SUPPLY());

        ArchemistV4Launcher.LaunchInfo memory info = launcher.launchInfoForToken(tokenAddress);
        assertEq(info.creator, address(this));
        assertEq(PoolId.unwrap(info.poolId), PoolId.unwrap(poolId));
        // targetFdvQuoteRaw == INITIAL_SUPPLY -> price ratio 1:1 -> tick 0, for either orientation.
        assertEq(info.initialTick, 0);
        assertEq(info.liquidity, 123);
        assertEq(info.tokensInPosition, launcher.INITIAL_SUPPLY());
        assertEq(info.hook, HOOK_A);
    }

    /// @dev PU-14: `address(this)` under delegatecall is the proxy, so the proxy is the CREATE2 deployer
    /// and the frontend's salt mining depends on it.
    function test_create2DeployerIsTheProxy() public {
        ArchemistV4Launcher.LaunchParams memory params = _validParams();
        address predicted = launcher.computeTokenAddress(params.salt, params.name, params.symbol, address(this));
        (address token,) = launcher.createToken{ value: DEPLOY_FEE }(params);
        assertEq(token, predicted);
        assertEq(ArchemistV4Token(token).launcher(), address(launcher), "deployer must be the PROXY");
    }

    function test_createRequiresExactFee() public {
        vm.expectRevert(ArchemistV4Launcher.InvalidPayment.selector);
        launcher.createToken{ value: DEPLOY_FEE - 1 }(_validParams());
    }

    function test_sameCreatorAndSaltRevertsWithExplicitCollision() public {
        ArchemistV4Launcher.LaunchParams memory params = _validParams();
        (address tokenAddress,) = launcher.createToken{ value: DEPLOY_FEE }(params);

        vm.expectRevert(abi.encodeWithSelector(ArchemistV4Launcher.TokenAlreadyDeployed.selector, tokenAddress));
        launcher.createToken{ value: DEPLOY_FEE }(params);
        assertEq(launcher.getTotalTokens(), 1);
    }

    function test_sameSaltIsNamespacedByCreator() public {
        ArchemistV4Launcher.LaunchParams memory params = _validParams();
        (address first,) = launcher.createToken{ value: DEPLOY_FEE }(params);

        address secondCreator = address(0xCAFE);
        vm.deal(secondCreator, DEPLOY_FEE);
        vm.prank(secondCreator);
        (address second,) = launcher.createToken{ value: DEPLOY_FEE }(params);

        assertNotEq(first, second);
        assertEq(launcher.getTotalTokens(), 2);
    }

    function test_createRejectsUnsafeLaunchParameters() public {
        ArchemistV4Launcher.LaunchParams memory params = _validParams();
        params.name = "";
        vm.expectRevert(ArchemistV4Launcher.InvalidConfiguration.selector);
        launcher.createToken{ value: DEPLOY_FEE }(params);

        params = _validParams();
        params.targetFdvQuoteRaw = 0;
        vm.expectRevert(ArchemistV4Launcher.InvalidConfiguration.selector);
        launcher.createToken{ value: DEPLOY_FEE }(params);

        params = _validParams();
        params.creatorShareBps = 4_999;
        vm.expectRevert(ArchemistV4Launcher.InvalidConfiguration.selector);
        launcher.createToken{ value: DEPLOY_FEE }(params);

        params = _validParams();
        params.creatorShareBps = 8_001;
        vm.expectRevert(ArchemistV4Launcher.InvalidConfiguration.selector);
        launcher.createToken{ value: DEPLOY_FEE }(params);
    }

    function test_createHonorsPerPairCreatorShareRange() public {
        MockLauncherQuote quote = new MockLauncherQuote(6);
        PairConfig memory narrowPair = _erc20Pair(60);
        narrowPair.minCreatorBps = 6_000;
        narrowPair.maxCreatorBps = 6_000;
        registry.addPair(address(quote), narrowPair, 0, false);

        ArchemistV4Launcher.LaunchParams memory params = _validParams();
        params.quote = address(quote);
        params.creatorShareBps = 7_000;
        vm.expectRevert(ArchemistV4Launcher.InvalidConfiguration.selector);
        launcher.createToken{ value: DEPLOY_FEE }(params);

        params.creatorShareBps = 6_000;
        (address tokenAddress,) = launcher.createToken{ value: DEPLOY_FEE }(params);
        assertTrue(tokenAddress.code.length != 0);
    }

    function test_unregisteredAndDisabledPairsBlockOnlyNewLaunches() public {
        MockLauncherQuote quote = new MockLauncherQuote(6);
        ArchemistV4Launcher.LaunchParams memory params = _validParams();
        params.quote = address(quote);

        vm.expectRevert(abi.encodeWithSelector(ArchemistPairRegistry.PairNotRegistered.selector, address(quote)));
        launcher.createToken{ value: DEPLOY_FEE }(params);

        registry.addPair(address(quote), _erc20Pair(60), 0, false);
        registry.setPairEnabled(address(quote), false);
        vm.expectRevert(abi.encodeWithSelector(ArchemistV4Launcher.PairDisabled.selector, address(quote)));
        launcher.createToken{ value: DEPLOY_FEE }(params);
        assertEq(launcher.getTotalTokens(), 0);
    }

    function test_sameFactoryLaunchesNewPairAndSnapshotsItsConfig() public {
        MockLauncherQuote quote = new MockLauncherQuote(6);
        registry.addPair(address(quote), _erc20Pair(60), 0, false);
        ArchemistV4Launcher.LaunchParams memory params = _validParams();
        params.quote = address(quote);
        params.salt = keccak256("erc20-pair-one");

        (address token, PoolId firstPoolId) = launcher.createToken{ value: DEPLOY_FEE }(params);
        assertEq(locker.tickSpacingForPool(firstPoolId), 60);
        assertEq(locker.currency0ForPool(firstPoolId), token < address(quote) ? token : address(quote));
        assertEq(locker.currency1ForPool(firstPoolId), token < address(quote) ? address(quote) : token);
        // targetFdvQuoteRaw == INITIAL_SUPPLY -> tick 0 regardless of which side the token landed on.
        if (token < address(quote)) {
            assertEq(locker.tickLowerForPool(firstPoolId), 0);
            assertEq(locker.tickUpperForPool(firstPoolId), TickMath.maxUsableTick(60));
        } else {
            assertEq(locker.tickLowerForPool(firstPoolId), TickMath.minUsableTick(60));
            assertEq(locker.tickUpperForPool(firstPoolId), 0);
        }

        registry.updatePair(address(quote), _erc20Pair(200));
        assertEq(locker.tickSpacingForPool(firstPoolId), 60, "old pool snapshot must not change");

        params.salt = keccak256("erc20-pair-two");
        (, PoolId secondPoolId) = launcher.createToken{ value: DEPLOY_FEE }(params);
        assertEq(locker.tickSpacingForPool(secondPoolId), 200, "new launch must use updated registry config");
    }

    function test_ownershipTransferIsTwoStep() public {
        address nextOwner = address(0xBEEF);
        launcher.transferOwnership(nextOwner);
        assertEq(launcher.owner(), address(this));

        vm.expectRevert(abi.encodeWithSelector(ArchemistUpgradeable.OwnableUnauthorizedAccount.selector, address(this)));
        launcher.acceptOwnership();

        vm.prank(nextOwner);
        launcher.acceptOwnership();
        assertEq(launcher.owner(), nextOwner);
    }

    // -------------------------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------------------------

    function _etchHook(address at) private {
        _etchAt(at, address(new MockLauncherHook(address(launcher), address(locker), IPoolManager(address(manager)))));
    }

    function _etchAt(address at, address implementation) private {
        vm.etch(at, implementation.code);
    }

    function _newLauncher() private returns (ArchemistV4Launcher) {
        return ArchemistDeploy.launcher(
            IPoolManager(address(manager)), address(this), address(registry), address(treasury), DEPLOY_FEE
        );
    }

    function _validParams() private view returns (ArchemistV4Launcher.LaunchParams memory params) {
        FeeRecipient[] memory recipients = new FeeRecipient[](1);
        recipients[0] = FeeRecipient({ admin: address(this), payout: address(0x2000), bps: 10_000 });
        params = ArchemistV4Launcher.LaunchParams({
            name: "Launch",
            symbol: "LNCH",
            salt: keccak256("salt"),
            quote: address(0),
            // == INITIAL_SUPPLY -> price ratio 1:1 -> tick 0 for either orientation. A deliberately
            // simple, deterministic choice so most assertions can just check `initialTick == 0` instead
            // of re-deriving InitialPriceMath's output by hand.
            targetFdvQuoteRaw: 1_000_000_000 ether,
            hook: hook,
            hookParams: abi.encode(AntiSnipeParams({ startHookFee: 300_000, windowSeconds: 120, maxBuyBps: 100 })),
            creatorShareBps: 7_000,
            recipients: recipients,
            creatorBuyAmount: 0,
            creatorBuyMinTokensOut: 0
        });
    }

    function _nativePair() private pure returns (PairConfig memory) {
        return PairConfig({
            enabled: true,
            decimals: 18,
            defaultTick: 0,
            minTick: -120_000,
            maxTick: 120_000,
            tickSpacing: 60,
            flags: 1,
            buybackRoute: address(0),
            buybackRouteIsV4: false,
            buybackRouteFee: 0,
            buybackRouteTickSpacing: 0,
            minCreatorBps: 5_000,
            maxCreatorBps: 8_000
        });
    }

    function _erc20Pair(int24 spacing) private pure returns (PairConfig memory) {
        return PairConfig({
            enabled: true,
            decimals: 6,
            defaultTick: 0,
            minTick: -120_000,
            maxTick: 120_000,
            tickSpacing: spacing,
            flags: 0,
            buybackRoute: address(0),
            buybackRouteIsV4: false,
            buybackRouteFee: 0,
            buybackRouteTickSpacing: 0,
            minCreatorBps: 5_000,
            maxCreatorBps: 8_000
        });
    }

    receive() external payable { }
}
