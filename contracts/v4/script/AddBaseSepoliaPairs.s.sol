// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { ArchemistPairRegistry } from "../src/ArchemistPairRegistry.sol";
import { ArchemistV4Launcher } from "../src/ArchemistV4Launcher.sol";
import { PairConfig } from "../src/ArchemistV4Types.sol";

contract ArchemistTestnetQuoteAsset {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(string memory name_, string memory symbol_, uint8 decimals_, address recipient) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
        uint256 supply = 1_000_000 * 10 ** decimals_;
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

contract AddBaseSepoliaPairs is Script {
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    address internal constant OFFICIAL_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    error WrongChain(uint256 actual);
    error WrongRegistryOwner(address expected, address actual);

    function run() external returns (ArchemistTestnetQuoteAsset mockUsdt, ArchemistTestnetQuoteAsset mockNvda) {
        if (block.chainid != BASE_SEPOLIA_CHAIN_ID) revert WrongChain(block.chainid);
        uint256 adminKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address admin = vm.addr(adminKey);
        ArchemistV4Launcher launcher = ArchemistV4Launcher(payable(vm.envAddress("LAUNCHER")));
        ArchemistPairRegistry registry = ArchemistPairRegistry(address(launcher.PAIR_REGISTRY()));
        if (registry.owner() != admin) revert WrongRegistryOwner(admin, registry.owner());

        vm.startBroadcast(adminKey);
        mockUsdt = new ArchemistTestnetQuoteAsset("Testnet Mock USDT", "mUSDT", 6, admin);
        mockNvda = new ArchemistTestnetQuoteAsset("Testnet NVIDIA 1:1", "mNVDA", 18, admin);

        // The registry probe (active once DeployBaseSepolia has called configureProbeRecipients)
        // pulls probeAmount from `admin` and forwards thirds of it to LOCKER/TREASURY/BUYBACK_VAULT,
        // so it needs an approval and a balance to draw from for every ERC-20 quote. OFFICIAL_USDC is
        // real testnet USDC we don't mint ourselves - skip it here (instead of reverting the whole
        // broadcast) if `admin` hasn't been funded with enough from a faucet yet.
        uint256 usdcProbeAmount = registry.LAUNCHER() == address(0) ? 0 : 3e6;
        bool usdcRegistered;
        if (usdcProbeAmount == 0 || ArchemistTestnetQuoteAsset(OFFICIAL_USDC).balanceOf(admin) >= usdcProbeAmount) {
            if (usdcProbeAmount != 0) {
                ArchemistTestnetQuoteAsset(OFFICIAL_USDC).approve(address(registry), usdcProbeAmount);
            }
            registry.addPair(OFFICIAL_USDC, _pair(6, 0), usdcProbeAmount, false);
            usdcRegistered = true;
        }

        uint256 usdtProbeAmount = registry.LAUNCHER() == address(0) ? 0 : 3e6;
        mockUsdt.approve(address(registry), usdtProbeAmount);
        registry.addPair(address(mockUsdt), _pair(6, 0), usdtProbeAmount, false);

        uint256 nvdaProbeAmount = registry.LAUNCHER() == address(0) ? 0 : 3e18;
        mockNvda.approve(address(registry), nvdaProbeAmount);
        registry.addPair(address(mockNvda), _pair(18, 0), nvdaProbeAmount, false);
        vm.stopBroadcast();

        console2.log("PairRegistry", address(registry));
        console2.log("Official Base Sepolia USDC", OFFICIAL_USDC);
        console2.log("Official USDC registered", usdcRegistered);
        console2.log("Mock USDT", address(mockUsdt));
        console2.log("Mock NVIDIA", address(mockNvda));
        console2.log("pairCount", registry.pairCount());
    }

    function _pair(uint8 decimals, uint16 flags) private pure returns (PairConfig memory) {
        return PairConfig({
            enabled: true,
            decimals: decimals,
            defaultTick: 0,
            minTick: -600_000,
            maxTick: 600_000,
            tickSpacing: 60,
            flags: flags,
            buybackRoute: address(0),
            buybackRouteIsV4: false,
            buybackRouteFee: 0,
            buybackRouteTickSpacing: 0,
            minCreatorBps: 5_000,
            maxCreatorBps: 8_000
        });
    }
}
