// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { ArchemistArchRedistributor } from "../src/ArchemistArchRedistributor.sol";

interface IV2LockerView {
    function positionForToken(address token)
        external
        view
        returns (
            uint256 positionId,
            address creatorFeeAdmin,
            address creatorFeeRecipient,
            address token0,
            address token1,
            bool released
        );
    function protocolFeeBps() external view returns (uint256);
}

/// @dev Deploys the ARCH-only fee redistributor and reads back everything the operator needs to
/// finish the wiring by hand.
///
/// Deploying this changes nothing on its own. The redistributor only starts receiving fees when
/// `creatorFeeAdmin` (an address this script does not control) calls, on the V2 locker:
///
///     updateCreatorFeeRecipient(ARCH, <redistributor>)
///
/// That is deliberately a separate, manual step: it is the one action that redirects live revenue,
/// and it should be taken with the deployed address in front of you. The script prints the exact
/// call. Fees credited to the OLD recipient before the switch stay with the old recipient and must
/// be claimed there - the switch is not retroactive.
contract DeployArchRedistributor is Script {
    uint256 internal constant ARC_MAINNET_CHAIN_ID = 5042;
    uint256 internal constant ARC_TESTNET_CHAIN_ID = 5_042_002;

    // Arc mainnet defaults - the V2 USDC launchpad.
    address internal constant ARCH_MAINNET = 0x5042419b1F2498959787Bc23Be1F484Ed1306650;
    address internal constant LINKED_USDC = 0x3600000000000000000000000000000000000000;
    /// @dev ArchemistV2LockerV2 (V2 USDC launchpad, protocolFeeBps 2000) - custodian of ARCH's LP
    /// position #5228. Confirmed on-chain, not assumed.
    address internal constant LOCKER_MAINNET = 0x7Dd53C388F650c0DaB535eFb03d8bd80F0A6bD07;
    /// @dev Where the USDC side of the fees goes. The protocol treasury, unchanged from today.
    address internal constant TREASURY_MAINNET = 0x4C85e3847c549f4823cf9bBD5Dfc7E1724559AEf;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        uint256 chainId = block.chainid;
        require(chainId == ARC_MAINNET_CHAIN_ID || chainId == ARC_TESTNET_CHAIN_ID, "unexpected chain");

        address arch = vm.envOr("ARCH", ARCH_MAINNET);
        address usdc = vm.envOr("USDC", LINKED_USDC);
        address locker = vm.envOr("LOCKER", LOCKER_MAINNET);
        address owner = vm.envOr("SYSTEM_OWNER", deployer);
        // The key that publishes each epoch's Merkle root. Separate from the owner so the snapshot
        // schedule can run from a hot wallet without that wallet being able to change the sink.
        address publisher = vm.envOr("PUBLISHER", deployer);
        address usdcSink = vm.envOr("USDC_SINK", TREASURY_MAINNET);

        // The position has to exist, be this token's, and still be held by the locker - otherwise the
        // redistributor would be pointed at a locker that can never pay it.
        (
            uint256 positionId,
            address creatorFeeAdmin,
            address creatorFeeRecipient,
            address token0,
            address token1,
            bool released
        ) = IV2LockerView(locker).positionForToken(arch);
        require(positionId != 0, "no LP position for ARCH on this locker");
        require(!released, "position no longer held by the locker");
        require(token0 == usdc || token1 == usdc, "USDC is not a side of this pool");
        require(token0 == arch || token1 == arch, "ARCH is not a side of this pool");

        vm.startBroadcast(deployerKey);
        ArchemistArchRedistributor dist =
            new ArchemistArchRedistributor(arch, usdc, locker, owner, publisher, usdcSink, chainId);
        vm.stopBroadcast();

        console2.log("ArchemistArchRedistributor:", address(dist));
        console2.log("  chainId                ", chainId);
        console2.log("  ARCH                   ", arch);
        console2.log("  USDC (swept, never paid to holders)", usdc);
        console2.log("  locker                 ", locker);
        console2.log("  LP position            ", positionId);
        console2.log("  protocolFeeBps         ", IV2LockerView(locker).protocolFeeBps());
        console2.log("  owner                  ", owner);
        console2.log("  publisher              ", publisher);
        console2.log("  usdcSink               ", usdcSink);
        console2.log("");
        console2.log("NOT YET RECEIVING FEES. To redirect the creator share, from creatorFeeAdmin:");
        console2.log("  creatorFeeAdmin        ", creatorFeeAdmin);
        console2.log("  current recipient      ", creatorFeeRecipient);
        console2.log("  cast send <locker> 'updateCreatorFeeRecipient(address,address)' <ARCH> <redistributor>");
    }
}
