// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";

import { ArchemistBuybackVault } from "../src/ArchemistBuybackVault.sol";
import { ArchemistPairRegistry } from "../src/ArchemistPairRegistry.sol";
import { PairConfig } from "../src/ArchemistV4Types.sol";
import {
    INonfungiblePositionManagerMinimal,
    IUniswapV3FactoryMinimal,
    IWETH9Minimal
} from "../src/interfaces/IUniswapV3Minimal.sol";
import { Proxies } from "./lib/Proxies.s.sol";

/// @dev Freely mintable ERC-20 standing in for ARCH on this mirror deployment. Real ARCH already exists
/// and has a fixed supply on Arc mainnet; this exists purely so a fresh v3 pool can be created and seeded
/// on Base Sepolia to exercise ArchemistBuybackVault's v3 route against a real (not mocked) v3 pool before
/// wiring the vault to the real ARCH/native v3 pool on Arc.
contract MirrorArchToken {
    string public constant name = "Mirror ARCH (Base Sepolia test)";
    string public constant symbol = "mARCH";
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

/// @dev Minimal stand-in for ArchemistV4Locker's claim surface (matches IBuybackVaultLocker exactly),
/// deployed on Base Sepolia so this script can prove ArchemistBuybackVault.execute() end-to-end against a
/// real v3 pool without needing the full launcher/locker/hook stack redeployed for this test.
contract TestnetVaultLocker {
    mapping(address beneficiary => mapping(address asset => uint256)) public claimable;

    function setClaimable(address beneficiary, address asset, uint256 amount) external {
        claimable[beneficiary][asset] = amount;
    }

    function claim(address asset, address to) external returns (uint256 amount) {
        amount = claimable[to][asset];
        claimable[to][asset] = 0;
        if (amount == 0) return 0;
        (bool ok,) = asset.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        require(ok, "transfer failed");
    }
}

contract MirrorArchV3PoolBaseSepolia is Script {
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    IUniswapV3FactoryMinimal internal constant V3_FACTORY =
        IUniswapV3FactoryMinimal(0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24);
    INonfungiblePositionManagerMinimal internal constant POSITION_MANAGER =
        INonfungiblePositionManagerMinimal(0x27F971cb582BF9E50F397e4d29a5C7A34f11faA2);
    IWETH9Minimal internal constant WETH9 = IWETH9Minimal(0x4200000000000000000000000000000000000006);
    uint24 internal constant FEE_1_PERCENT = 10_000; // matches the real ARCH pool on Arc
    int24 internal constant TICK_SPACING_1_PERCENT = 200;

    uint256 internal constant MIRROR_SUPPLY = 1_000_000 ether;
    uint256 internal constant SEED_MIRROR = 500_000 ether;
    uint256 internal constant SEED_WETH = 0.01 ether;

    error WrongChain(uint256 actual);

    function run()
        external
        returns (MirrorArchToken mirrorArch, address pool, ArchemistBuybackVault vault, TestnetVaultLocker locker)
    {
        if (block.chainid != BASE_SEPOLIA_CHAIN_ID) revert WrongChain(block.chainid);

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        mirrorArch = new MirrorArchToken(deployer, MIRROR_SUPPLY);
        WETH9.deposit{ value: SEED_WETH }();

        bool weth9IsToken0 = address(WETH9) < address(mirrorArch);
        address token0 = weth9IsToken0 ? address(WETH9) : address(mirrorArch);
        address token1 = weth9IsToken0 ? address(mirrorArch) : address(WETH9);

        pool = POSITION_MANAGER.createAndInitializePoolIfNecessary(
            token0, token1, FEE_1_PERCENT, TickMath.getSqrtPriceAtTick(0)
        );

        mirrorArch.approve(address(POSITION_MANAGER), SEED_MIRROR);
        WETH9.approve(address(POSITION_MANAGER), SEED_WETH);
        POSITION_MANAGER.mint(
            INonfungiblePositionManagerMinimal.MintParams({
                token0: token0,
                token1: token1,
                fee: FEE_1_PERCENT,
                tickLower: (TickMath.minUsableTick(TICK_SPACING_1_PERCENT)),
                tickUpper: (TickMath.maxUsableTick(TICK_SPACING_1_PERCENT)),
                amount0Desired: weth9IsToken0 ? SEED_WETH : SEED_MIRROR,
                amount1Desired: weth9IsToken0 ? SEED_MIRROR : SEED_WETH,
                amount0Min: 0,
                amount1Min: 0,
                recipient: deployer,
                deadline: block.timestamp + 600
            })
        );

        // A throwaway vault/locker/registry set, standalone (not wired into the full launcher/hook
        // stack), purely to prove ArchemistBuybackVault's v3 route works end-to-end against this real
        // pool. The route comes from the registry and is
        // validated against the CANONICAL v3 factory, so the registry entry below is now load-bearing
        // rather than decorative - and this script proves that path, which is the one mainnet uses.
        locker = new TestnetVaultLocker();
        ArchemistPairRegistry throwawayRegistry = ArchemistPairRegistry(
            Proxies.deploy(
                address(new ArchemistPairRegistry(address(0), block.chainid)),
                abi.encodeCall(ArchemistPairRegistry.initialize, (deployer))
            )
        );
        throwawayRegistry.addPair(
            address(WETH9),
            PairConfig({
                enabled: true,
                decimals: 18,
                defaultTick: 0,
                minTick: -600_000,
                maxTick: 600_000,
                tickSpacing: 60,
                flags: 0,
                buybackRoute: pool,
                buybackRouteIsV4: false,
                buybackRouteFee: 0,
                buybackRouteTickSpacing: 0,
                minCreatorBps: 5_000,
                maxCreatorBps: 8_000
            }),
            0,
            true
        );
        vault = ArchemistBuybackVault(
            payable(Proxies.deploy(
                    address(
                        new ArchemistBuybackVault(
                            IPoolManager(address(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408)),
                            address(mirrorArch),
                            address(WETH9),
                            address(V3_FACTORY),
                            block.chainid
                        )
                    ),
                    abi.encodeCall(
                        ArchemistBuybackVault.initialize, (deployer, address(locker), address(throwawayRegistry))
                    )
                ))
        );

        vm.stopBroadcast();

        console2.log("MirrorArch token", address(mirrorArch));
        console2.log("WETH9", address(WETH9));
        console2.log("v3 pool (1%)", pool);
        console2.log("token0", token0);
        console2.log("token1", token1);
        console2.log("BuybackVault", address(vault));
        console2.log("TestnetVaultLocker", address(locker));
    }
}
