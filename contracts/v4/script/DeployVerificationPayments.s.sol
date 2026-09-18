// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { ArchemistVerificationPayments } from "../src/ArchemistVerificationPayments.sol";

/// @dev Deploys the escrow that collects payment for Verified Token Information.
///
/// Deliberately deployable before Blockscout has given us their Arc address: BLOCKSCOUT_RECIPIENT
/// defaults to the treasury, and the owner can point it at the real address later with
/// setBlockscoutRecipient. Nothing can be mis-sent in the meantime, because settlement only happens
/// when our server calls settle() - and it will not call it until a record is live, by which point
/// the address is known.
///
/// Amounts are in the chain's NATIVE currency. On Arc that currency is USDC with 18 decimals at the
/// native scale (the 0x3600… ERC-20 view of the same balance shows 6), so the defaults below are
/// 150e18 and 99e18, not 150e6. Pass PRICE/BLOCKSCOUT_FEE explicitly if that ever stops being true.
contract DeployVerificationPayments is Script {
    uint256 internal constant ARC_MAINNET_CHAIN_ID = 5042;
    uint256 internal constant ARC_TESTNET_CHAIN_ID = 5_042_002;
    /// @dev Rehearsal target. Blockscout's staging service only authorises our probe key for
    /// Sepolia, so the only place the full loop - pay, submit, publish, settle - can be run end to
    /// end today is here. Sepolia's native currency is ETH, not USDC, so pass a small PRICE.
    uint256 internal constant SEPOLIA_CHAIN_ID = 11_155_111;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address owner = vm.envOr("SYSTEM_OWNER", deployer);
        address treasury = vm.envOr("TREASURY", deployer);
        address blockscoutRecipient = vm.envOr("BLOCKSCOUT_RECIPIENT", treasury);
        address settler = vm.envOr("SETTLER", deployer);
        uint256 price = vm.envOr("PRICE", uint256(150 ether));
        uint256 blockscoutFee = vm.envOr("BLOCKSCOUT_FEE", uint256(99 ether));

        uint256 chainId = block.chainid;
        require(
            chainId == ARC_MAINNET_CHAIN_ID || chainId == ARC_TESTNET_CHAIN_ID || chainId == SEPOLIA_CHAIN_ID,
            "unexpected chain"
        );
        require(chainId != SEPOLIA_CHAIN_ID || price <= 0.01 ether, "rehearsal price must be small on Sepolia");

        vm.startBroadcast(deployerKey);
        ArchemistVerificationPayments payments = new ArchemistVerificationPayments(
            owner, treasury, blockscoutRecipient, settler, price, blockscoutFee, chainId
        );
        vm.stopBroadcast();

        console2.log("ArchemistVerificationPayments:", address(payments));
        console2.log("  chainId            ", chainId);
        console2.log("  owner              ", owner);
        console2.log("  settler            ", settler);
        console2.log("  treasury           ", treasury);
        console2.log("  blockscoutRecipient", blockscoutRecipient);
        console2.log("  price              ", price);
        console2.log("  blockscoutFee      ", blockscoutFee);
        if (blockscoutRecipient == treasury) {
            console2.log("  NOTE: blockscoutRecipient is still the treasury - set it before settling anything.");
        }
    }
}
