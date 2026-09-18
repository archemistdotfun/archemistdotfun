// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { PoolManager } from "@uniswap/v4-core/src/PoolManager.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { HookMiner } from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import { ArchemistBuybackVault } from "../src/ArchemistBuybackVault.sol";
import { ArchemistHolderRewards } from "../src/ArchemistHolderRewards.sol";
import { ArchemistPairRegistry } from "../src/ArchemistPairRegistry.sol";
import { ArchemistV4Hook } from "../src/ArchemistV4Hook.sol";
import { ArchemistV4Launcher } from "../src/ArchemistV4Launcher.sol";
import { ArchemistV4Locker } from "../src/ArchemistV4Locker.sol";
import { AntiSnipeParams, FeeRecipient, PairConfig } from "../src/ArchemistV4Types.sol";
import { ArchemistERC1967Proxy } from "../src/upgradeability/ArchemistERC1967Proxy.sol";

/// @dev Deploys hooks from its own address, so a second hook can be mined to a DIFFERENT address than
/// the first while carrying identical constructor arguments - CREATE2 includes the deployer, and
/// `HookMiner.find` is deterministic, so mining twice from one deployer would collide.
contract HookFactory {
    function deploy(bytes32 salt, IPoolManager poolManager, address launcher_, address locker_, address vault_)
        external
        returns (ArchemistV4Hook)
    {
        return new ArchemistV4Hook{ salt: salt }(poolManager, launcher_, locker_, vault_);
    }
}

/// @dev Plain receiver, used as the treasury and as fee payouts.
contract FixtureReceiver {
    receive() external payable { }
}

/// @dev Minimal canonical-factory stand-in: `registerPool` is what a real deployment's Uniswap v3
/// factory does when someone creates a pool, and `getPool` is the lookup `ArchemistBuybackVault`
/// validates a registry route against. Having it here at all is the point - without a factory the vault
/// cannot tell a real pool from one an admin deployed to route their own buybacks into.
contract MockUniswapV3Factory {
    mapping(bytes32 => address) private _pools;

    function registerPool(address tokenA, address tokenB, uint24 fee, address pool) external {
        _pools[_key(tokenA, tokenB, fee)] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        return _pools[_key(tokenA, tokenB, fee)];
    }

    function createPool(address, address, uint24) external pure returns (address) {
        revert("unused");
    }

    function _key(address a, address b, uint24 fee) private pure returns (bytes32) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        return keccak256(abi.encode(t0, t1, fee));
    }
}

/// @notice Builds the whole deployment-#7 stack the way the real deploy script does - five UUPS proxies
/// owned by a real `TimelockController`, a CREATE2-mined immutable hook registered through the launcher -
/// so that every test starts from a realistic state rather than from bare implementations.
///
/// That is not a convenience. Almost everything this restructure changed only *behaves* differently
/// through a proxy: `address(this)` inside `createToken` is the proxy (so CREATE2 token addresses depend
/// on it), every `msg.sender` check now compares against a proxy address, the implementation's
/// `receive()` is only reached through the proxy's `fallback`, and transient state is keyed by the proxy.
/// A test against a bare implementation would pass while the deployed system was broken.
abstract contract ArchemistFixture is Test {
    uint160 internal constant REQUIRED_FLAGS = 0x28CC;
    uint256 internal constant TIMELOCK_DELAY = 48 hours;
    address internal constant CREATOR = address(0xC0FFEE);

    IPoolManager internal manager;
    TimelockController internal timelock;
    ArchemistPairRegistry internal registry;
    ArchemistV4Launcher internal launcher;
    ArchemistV4Locker internal locker;
    ArchemistHolderRewards internal rewards;
    ArchemistBuybackVault internal vault;
    ArchemistV4Hook internal hook;
    FixtureReceiver internal treasury;
    MockUniswapV3Factory internal v3Factory;

    /// @dev Implementation addresses, kept so upgrade tests can assert what the proxy points at.
    address internal registryImpl;
    address internal launcherImpl;
    address internal lockerImpl;
    address internal rewardsImpl;
    address internal vaultImpl;

    address internal arch;
    address internal linkedUsdc;

    // ---------------------------------------------------------------------------------------------
    // Stack construction
    // ---------------------------------------------------------------------------------------------

    /// @param vaultOverride When non-zero, the launcher and hook are wired to this address as the
    ///        buyback vault instead of a real vault proxy. Hook tests use it to observe the trigger.
    function _deployStack(address vaultOverride, address arch_, address linkedUsdc_) internal {
        manager = IPoolManager(address(new PoolManager(address(this))));
        treasury = new FixtureReceiver();
        v3Factory = new MockUniswapV3Factory();
        arch = arch_;
        linkedUsdc = linkedUsdc_;

        address[] memory proposers = new address[](1);
        proposers[0] = address(this);
        address[] memory executors = new address[](1);
        // address(0) as the sole executor means "anyone may execute once the delay has passed", which is
        // the point: nobody can be locked out of executing a change that is already public.
        executors[0] = address(0);
        timelock = new TimelockController(TIMELOCK_DELAY, proposers, executors, address(0));

        // --- registry --------------------------------------------------------------------------
        registryImpl = address(new ArchemistPairRegistry(address(0), block.chainid));
        registry = ArchemistPairRegistry(
            address(
                new ArchemistERC1967Proxy(
                    registryImpl, abi.encodeCall(ArchemistPairRegistry.initialize, (address(this)))
                )
            )
        );

        // --- launcher --------------------------------------------------------------------------
        launcherImpl = address(new ArchemistV4Launcher(manager, block.chainid));
        launcher = ArchemistV4Launcher(
            payable(address(
                    new ArchemistERC1967Proxy(
                        launcherImpl,
                        abi.encodeCall(
                            ArchemistV4Launcher.initialize, (address(this), address(registry), address(treasury), 0)
                        )
                    )
                ))
        );

        // --- locker ----------------------------------------------------------------------------
        lockerImpl = address(new ArchemistV4Locker(manager, block.chainid));
        locker = ArchemistV4Locker(
            payable(address(
                    new ArchemistERC1967Proxy(
                        lockerImpl, abi.encodeCall(ArchemistV4Locker.initialize, (address(this), address(launcher)))
                    )
                ))
        );

        // --- vault -----------------------------------------------------------------------------
        address vaultAddress = vaultOverride;
        if (vaultAddress == address(0)) {
            vaultImpl =
                address(new ArchemistBuybackVault(manager, arch_, linkedUsdc_, address(v3Factory), block.chainid));
            vault = ArchemistBuybackVault(
                payable(address(
                        new ArchemistERC1967Proxy(
                            vaultImpl,
                            abi.encodeCall(
                                ArchemistBuybackVault.initialize, (address(this), address(locker), address(registry))
                            )
                        )
                    ))
            );
            vaultAddress = address(vault);
        }

        // --- holder rewards --------------------------------------------------------------------
        rewardsImpl = address(new ArchemistHolderRewards(block.chainid));
        rewards = ArchemistHolderRewards(
            payable(address(
                    new ArchemistERC1967Proxy(
                        rewardsImpl,
                        abi.encodeCall(
                            ArchemistHolderRewards.initialize, (address(this), address(launcher), address(locker))
                        )
                    )
                ))
        );

        launcher.configureSystemOnce(address(locker), vaultAddress, address(rewards));

        hook = _deployHook(vaultAddress);
        launcher.registerHook(address(hook));
        launcher.enableCreate();
    }

    /// @dev A second real hook at a different address, for the tests that need two of them. Mined from
    /// a separate deployer for exactly that reason.
    function _deploySecondHook(address vaultAddress) internal returns (ArchemistV4Hook deployed) {
        HookFactory factory = new HookFactory();
        bytes memory args = abi.encode(manager, address(launcher), address(locker), vaultAddress);
        (address expected, bytes32 salt) =
            HookMiner.find(address(factory), REQUIRED_FLAGS, type(ArchemistV4Hook).creationCode, args);
        deployed = factory.deploy(salt, manager, address(launcher), address(locker), vaultAddress);
        require(address(deployed) == expected, "fixture: second hook mining failed");
    }

    /// @dev Mines a CREATE2 salt so the hook's low 14 address bits equal its declared permissions -
    /// exactly what `registerHook` re-derives and checks, and what PoolManager keys every callback off.
    function _deployHook(address vaultAddress) internal returns (ArchemistV4Hook deployed) {
        bytes memory args = abi.encode(manager, address(launcher), address(locker), vaultAddress);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), REQUIRED_FLAGS, type(ArchemistV4Hook).creationCode, args);
        deployed = new ArchemistV4Hook{ salt: salt }(manager, address(launcher), address(locker), vaultAddress);
        require(address(deployed) == expected, "fixture: hook mining failed");
    }

    /// @dev Hands every proxy to the timelock, then executes the five `acceptOwnership` calls through it.
    /// After this, the deployer can no longer upgrade anything.
    function _handOverToTimelock() internal {
        registry.transferOwnership(address(timelock));
        launcher.transferOwnership(address(timelock));
        locker.transferOwnership(address(timelock));
        rewards.transferOwnership(address(timelock));
        if (address(vault) != address(0)) vault.transferOwnership(address(timelock));

        _timelockExec(address(registry), abi.encodeWithSignature("acceptOwnership()"));
        _timelockExec(address(launcher), abi.encodeWithSignature("acceptOwnership()"));
        _timelockExec(address(locker), abi.encodeWithSignature("acceptOwnership()"));
        _timelockExec(address(rewards), abi.encodeWithSignature("acceptOwnership()"));
        if (address(vault) != address(0)) {
            _timelockExec(address(vault), abi.encodeWithSignature("acceptOwnership()"));
        }
    }

    /// @dev Schedule, wait out the real delay, execute. Every privileged action in the deployed system
    /// goes through exactly this path, so tests do too.
    function _timelockExec(address target, bytes memory data) internal {
        bytes32 salt = keccak256(abi.encode(target, data, block.timestamp, gasleft()));
        timelock.schedule(target, 0, data, bytes32(0), salt, TIMELOCK_DELAY);
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        timelock.execute(target, 0, data, bytes32(0), salt);
    }

    // ---------------------------------------------------------------------------------------------
    // Launch helpers
    // ---------------------------------------------------------------------------------------------

    function _nativePair() internal pure returns (PairConfig memory) {
        return PairConfig({
            enabled: true,
            decimals: 18,
            defaultTick: 0,
            minTick: -120_000,
            maxTick: 120_000,
            tickSpacing: 60,
            flags: 1, // FLAG_NATIVE
            buybackRoute: address(0),
            buybackRouteIsV4: false,
            buybackRouteFee: 0,
            buybackRouteTickSpacing: 0,
            minCreatorBps: 5_000,
            maxCreatorBps: 8_000
        });
    }

    function _antiSnipe(uint24 startHookFee, uint32 windowSeconds, uint16 maxBuyBps)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            AntiSnipeParams({ startHookFee: startHookFee, windowSeconds: windowSeconds, maxBuyBps: maxBuyBps })
        );
    }

    function _defaultRecipients(address payout) internal pure returns (FeeRecipient[] memory recipients) {
        recipients = new FeeRecipient[](1);
        recipients[0] = FeeRecipient({ admin: CREATOR, payout: payout, bps: 10_000 });
    }

    function _launchParams(
        address hookAddress,
        address quote,
        bytes32 salt,
        uint24 startHookFee,
        uint32 windowSeconds,
        uint16 maxBuyBps,
        address payout
    ) internal pure returns (ArchemistV4Launcher.LaunchParams memory p) {
        p = ArchemistV4Launcher.LaunchParams({
            name: "Archemist Test",
            symbol: "ARCT",
            salt: salt,
            quote: quote,
            targetFdvQuoteRaw: 5_000 ether,
            hook: hookAddress,
            hookParams: _antiSnipe(startHookFee, windowSeconds, maxBuyBps),
            creatorShareBps: 8_000,
            recipients: _defaultRecipients(payout),
            creatorBuyAmount: 0,
            creatorBuyMinTokensOut: 0
        });
    }

    function _poolKeyOf(PoolId poolId) internal view returns (PoolKey memory) {
        return locker.getPoolKey(poolId);
    }
}
