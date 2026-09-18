// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolModifyLiquidityTest } from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { HookMiner } from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import { ArchemistBuybackVault } from "../src/ArchemistBuybackVault.sol";
import { ArchemistHolderRewards } from "../src/ArchemistHolderRewards.sol";
import { ArchemistPairRegistry } from "../src/ArchemistPairRegistry.sol";
import { ArchemistV4Hook } from "../src/ArchemistV4Hook.sol";
import { ArchemistV4Launcher } from "../src/ArchemistV4Launcher.sol";
import { ArchemistV4Locker } from "../src/ArchemistV4Locker.sol";
import { PairConfig } from "../src/ArchemistV4Types.sol";
import { Proxies } from "./lib/Proxies.s.sol";

/// @dev Testnet-only stand-in for the canonical linked USDC that Arc has at 0x3600...0000. The buyback
/// vault requires a non-zero LINKED_USDC because every non-USDC asset routes through it, so a testnet
/// stack has to supply something to play that part.
///
/// One caveat this mock CANNOT reproduce, and it matters: on Arc, native currency and linked USDC are
/// literally the same balance, kept in sync by a protocol precompile, which is why the vault treats
/// `execute(address(0))` as an alias for linked USDC. On Base Sepolia native ETH and this token are two
/// unrelated assets, so buyback for a NATIVE-quoted launch cannot work here - those fees accumulate in
/// the vault untouched. Native is still registered as a launch quote below, because launching, trading
/// and holder rewards all work fine on it; only the buyback leg is Arc-specific. Rehearse buyback
/// against the USDC-quoted pair instead, which is the path mainnet actually uses.
contract ArchemistTestnetUsdc {
    string public constant name = "Testnet Linked USDC";
    string public constant symbol = "tUSDC";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(address recipient, uint256 supply) {
        totalSupply = supply;
        balanceOf[recipient] = supply;
        emit Transfer(address(0), recipient, supply);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _move(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        return _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) private returns (bool) {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

/// @dev Testnet-only stand-in for ARCH. Real ARCH is a separate, already-existing token in production;
/// this mock exists purely so the buyback route can be exercised end-to-end on Base Sepolia. Replace
/// with the real ARCH address before any production deployment.
contract ArchemistTestnetArch {
    string public constant name = "Testnet ARCH";
    string public constant symbol = "tARCH";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(address recipient, uint256 supply) {
        totalSupply = supply;
        balanceOf[recipient] = supply;
        emit Transfer(address(0), recipient, supply);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

contract DeployBaseSepolia is Script {
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    uint160 internal constant REQUIRED_HOOK_FLAGS = 0x28CC;
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408);

    /// @dev Amount of native ETH (and matching tARCH) seeded into the native/ARCH route pool used by
    /// the buyback vault. Kept modest - this is only meant to prove the buyback swap executes, not to
    /// provide meaningful testnet liquidity.
    uint256 internal constant TARCH_SUPPLY = 1_000_000 ether;
    uint256 internal constant TUSDC_SUPPLY = 1_000_000_000e6;
    /// @dev Full-range liquidity for the tUSDC/tARCH route pool. Needs roughly this many raw units of
    /// each side at tick 0, which both mocks mint far more than.
    int256 internal constant ARCH_ROUTE_LIQUIDITY = 1e12;

    error WrongChain(uint256 actual);
    error MissingPoolManager();
    error HookAddressMismatch(address expected, address actual);

    function run()
        external
        returns (
            ArchemistPairRegistry registry,
            ArchemistV4Launcher launcher,
            ArchemistV4Locker locker,
            ArchemistV4Hook hook,
            ArchemistBuybackVault vault,
            ArchemistTestnetArch arch,
            ArchemistTestnetUsdc usdc,
            ArchemistHolderRewards holderRewards
        )
    {
        if (block.chainid != BASE_SEPOLIA_CHAIN_ID) revert WrongChain(block.chainid);
        if (address(POOL_MANAGER).code.length == 0) revert MissingPoolManager();

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address treasury = vm.envOr("TREASURY", deployer);
        address finalOwner = vm.envOr("SYSTEM_OWNER", deployer);
        uint256 deployFee = vm.envOr("DEPLOY_FEE", uint256(0));
        bool enableCreate = vm.envOr("ENABLE_CREATE", false);

        vm.startBroadcast(deployerKey);
        registry = ArchemistPairRegistry(
            Proxies.deploy(
                address(new ArchemistPairRegistry(address(0), BASE_SEPOLIA_CHAIN_ID)),
                abi.encodeCall(ArchemistPairRegistry.initialize, (deployer))
            )
        );
        registry.addPair(
            address(0),
            PairConfig({
                enabled: true,
                decimals: 18,
                defaultTick: 0,
                // Native's launch token is always currency1, so a modest FDV against the
                // 1e9-token, 18-decimal supply lands a large POSITIVE tick (token is "cheap" per
                // raw-unit price, i.e. you get many raw token units per raw quote unit) - bounds must
                // allow that, not just the negative range earlier hardcoded raw ticks happened to use.
                minTick: -600_000,
                maxTick: 600_000,
                tickSpacing: 60,
                flags: registry.FLAG_NATIVE(),
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
        launcher = ArchemistV4Launcher(
            payable(Proxies.deploy(
                    address(new ArchemistV4Launcher(POOL_MANAGER, BASE_SEPOLIA_CHAIN_ID)),
                    abi.encodeCall(ArchemistV4Launcher.initialize, (deployer, address(registry), treasury, deployFee))
                ))
        );
        locker = ArchemistV4Locker(
            payable(Proxies.deploy(
                    address(new ArchemistV4Locker(POOL_MANAGER, BASE_SEPOLIA_CHAIN_ID)),
                    abi.encodeCall(ArchemistV4Locker.initialize, (deployer, address(launcher)))
                ))
        );

        // Real buyback vault: sends bought-back ARCH to TREASURY, guarded by cooldown/epoch-cap/
        // price-drift, triggered automatically from the hook.
        arch = new ArchemistTestnetArch(deployer, TARCH_SUPPLY);
        usdc = new ArchemistTestnetUsdc(deployer, TUSDC_SUPPLY);
        // There is no canonical Uniswap v3 factory on Base Sepolia that matters here, and the rehearsal
        // route below is a v4 pool anyway - so the v3 factory argument is the PoolManager's own address
        // purely to satisfy the non-zero/has-code check. Every route this deployment resolves is v4.
        vault = ArchemistBuybackVault(
            payable(Proxies.deploy(
                    address(
                        new ArchemistBuybackVault(
                            POOL_MANAGER, address(arch), address(usdc), address(POOL_MANAGER), BASE_SEPOLIA_CHAIN_ID
                        )
                    ),
                    abi.encodeCall(ArchemistBuybackVault.initialize, (deployer, address(locker), address(registry)))
                ))
        );

        holderRewards = ArchemistHolderRewards(
            payable(Proxies.deploy(
                    address(new ArchemistHolderRewards(BASE_SEPOLIA_CHAIN_ID)),
                    abi.encodeCall(ArchemistHolderRewards.initialize, (deployer, address(launcher), address(locker)))
                ))
        );
        // The hook carries the vault address as an immutable now, so the vault has to exist before the
        // hook is mined - its address is part of the hook's creation code and therefore of its salt.
        bytes memory constructorArgs = abi.encode(POOL_MANAGER, address(launcher), address(locker), address(vault));
        (address expectedHook, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, REQUIRED_HOOK_FLAGS, type(ArchemistV4Hook).creationCode, constructorArgs);
        hook = new ArchemistV4Hook{ salt: salt }(POOL_MANAGER, address(launcher), address(locker), address(vault));
        if (address(hook) != expectedHook) revert HookAddressMismatch(expectedHook, address(hook));

        // tUSDC/tARCH route pool the vault swaps through - a plain, unhooked v4 pool, independent of
        // the Archemist launch pools. This is the pair mainnet's own buyback terminates on (linked USDC
        // -> ARCH), so rehearsing it here rehearses the real thing.
        bool usdcIsCurrency0 = address(usdc) < address(arch);
        PoolKey memory archPoolKey = PoolKey({
            currency0: Currency.wrap(usdcIsCurrency0 ? address(usdc) : address(arch)),
            currency1: Currency.wrap(usdcIsCurrency0 ? address(arch) : address(usdc)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        POOL_MANAGER.initialize(archPoolKey, TickMath.getSqrtPriceAtTick(0));
        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(POOL_MANAGER);
        arch.approve(address(liquidityRouter), type(uint256).max);
        usdc.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity(
            archPoolKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: ARCH_ROUTE_LIQUIDITY,
                salt: bytes32(0)
            }),
            bytes("")
        );
        // The vault derives this exact key from the registry entry below
        // ({tUSDC, tARCH, fee 3000, spacing 60, hooks: address(0)}), so the pool seeded here is by
        // construction the one it will use, and nobody can point it anywhere else.

        // tUSDC as a launch quote, so the USDC-quoted path (the one mainnet uses, and the only one whose
        // buyback can work here) is testable. Registered before configureProbeRecipients below, so the
        // registry's transfer probe is skipped - same as the native pair above.
        registry.addPair(
            address(usdc),
            PairConfig({
                enabled: true,
                decimals: 6,
                defaultTick: 0,
                minTick: -600_000,
                maxTick: 600_000,
                tickSpacing: 60,
                flags: 0,
                buybackRoute: address(0),
                buybackRouteIsV4: true,
                buybackRouteFee: 3_000,
                buybackRouteTickSpacing: 60,
                minCreatorBps: 5_000,
                maxCreatorBps: 8_000
            }),
            0,
            true
        );

        launcher.configureSystemOnce(address(locker), address(vault), address(holderRewards));
        launcher.registerHook(address(hook));
        // Switches on the ERC-20 quote safety probe for every addPair from now on (see
        // ArchemistPairRegistry._probePair). Must run after configureSystemOnce so LOCKER/
        // TREASURY/BUYBACK_VAULT are all set, and before ownership transfers below.
        registry.configureProbeRecipients(address(launcher));
        if (enableCreate) launcher.enableCreate();
        if (finalOwner != deployer) {
            launcher.transferOwnership(finalOwner);
            registry.transferOwnership(finalOwner);
            vault.transferOwnership(finalOwner);
            locker.transferOwnership(finalOwner);
            holderRewards.transferOwnership(finalOwner);
        }
        vm.stopBroadcast();

        console2.log("chainId", block.chainid);
        console2.log("PoolManager", address(POOL_MANAGER));
        console2.log("PairRegistry", address(registry));
        console2.log("Launcher", address(launcher));
        console2.log("Locker", address(locker));
        console2.log("Hook", address(hook));
        console2.log("BuybackVault", address(vault));
        console2.log("TestnetArch", address(arch));
        console2.log("TestnetLinkedUsdc", address(usdc));
        console2.log("HolderRewards", address(holderRewards));
        console2.log("Hook low-14 bits", uint160(address(hook)) & 0x3FFF);
        console2.log("createEnabled", launcher.createEnabled());
        console2.log("owner", launcher.owner());
        console2.log("ARCH sink (burn)", vault.ARCH_SINK());
        console2.log("pendingOwner", launcher.pendingOwner());
    }
}
