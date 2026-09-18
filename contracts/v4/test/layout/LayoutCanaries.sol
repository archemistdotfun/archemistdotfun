// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { ArchemistBuybackVault } from "../../src/ArchemistBuybackVault.sol";
import { ArchemistHolderRewards } from "../../src/ArchemistHolderRewards.sol";
import { ArchemistPairRegistry } from "../../src/ArchemistPairRegistry.sol";
import { ArchemistV4Launcher } from "../../src/ArchemistV4Launcher.sol";
import { ArchemistV4Locker } from "../../src/ArchemistV4Locker.sol";
import { ArchemistUpgradeable } from "../../src/upgradeability/ArchemistUpgradeable.sol";

/// # Why these exist
///
/// Every upgradeable Archemist contract keeps all of its state inside one ERC-7201 namespaced struct,
/// reached through an assembly `.slot :=` assignment. That is what makes two contracts unable to
/// collide with each other. It also means **solc allocates nothing**, so `forge inspect <C>
/// storageLayout` comes back completely empty - `storage: []`, `types: {}` - for all five of them.
///
/// The first version of the upgrade gate read that empty output and asserted "no plain state
/// variables", which is trivially true and says nothing about the struct. A field reordered, retyped,
/// removed, or inserted in the middle would have sailed through the one check the entire upgrade policy
/// leans on. Found in review; this is the fix.
///
/// A canary declares the very same struct type as an ordinary state variable. That forces solc to lay
/// it out and emit the full member list - labels, types, slots and offsets, computed by the compiler
/// rather than by a script reading source text. `UpgradeLayout.t.sol` diffs that against a committed
/// reference and requires the reference to be a **prefix** of it, which is precisely the append-only
/// rule upgrade safety needs: appending a field passes, anything else fails.
///
/// These contracts are never deployed and hold no logic. Their only product is the layout artifact.
///
/// Adding a new upgradeable contract? Add a canary here, add a reference JSON, and list it in the test.

contract LauncherLayoutCanary {
    ArchemistV4Launcher.LauncherStorage internal s;
}

contract LockerLayoutCanary {
    ArchemistV4Locker.LockerStorage internal s;
}

contract BuybackVaultLayoutCanary {
    ArchemistBuybackVault.BuybackVaultStorage internal s;
}

contract HolderRewardsLayoutCanary {
    ArchemistHolderRewards.HolderRewardsStorage internal s;
}

contract PairRegistryLayoutCanary {
    ArchemistPairRegistry.PairRegistryStorage internal s;
}

contract OwnableLayoutCanary {
    ArchemistUpgradeable.OwnableStorage internal s;
}

/// @dev Deliberately wrong: the launcher's first two fields are swapped. Nothing imports it except the
/// gate's own self-test, which diffs it against the REAL launcher reference and requires a mismatch.
/// A gate that has never been seen to reject a struct mutation is not a gate, and the previous version
/// of this file's test proved only that it could spot a plain state variable, which is not the failure
/// anybody was worried about.
contract BrokenLauncherLayoutCanary {
    struct Reordered {
        address treasury; // was second
        address pairRegistry; // was first
        uint256 deployFee;
        address locker;
        address buybackVault;
        address holderRewards;
        bool createEnabled;
        bool retired;
        mapping(address => ArchemistV4Launcher.HookRecord) hookRecord;
        address[] knownHooks;
        mapping(address => ArchemistV4Launcher.LaunchInfo) launchInfoForToken;
        address[] allTokens;
    }

    Reordered internal s;
}

/// @notice The one list. Both the gate and the reference generator read it, so a canary that is added
/// here without a reference fails loudly, and a canary added to the file but not to this list is the
/// only real gap - which is why `UpgradeLayout.t.sol` also re-derives the namespace slots independently.
library LayoutCanaries {
    function names() internal pure returns (string[] memory out) {
        out = new string[](6);
        out[0] = "LauncherLayoutCanary";
        out[1] = "LockerLayoutCanary";
        out[2] = "BuybackVaultLayoutCanary";
        out[3] = "HolderRewardsLayoutCanary";
        out[4] = "PairRegistryLayoutCanary";
        out[5] = "OwnableLayoutCanary";
    }

    /// @dev The implementation contract each canary stands in for, for error messages that name the
    /// thing an operator actually has to reason about.
    function implementationOf(string memory canary) internal pure returns (string memory) {
        bytes32 h = keccak256(bytes(canary));
        if (h == keccak256("LauncherLayoutCanary")) return "ArchemistV4Launcher";
        if (h == keccak256("LockerLayoutCanary")) return "ArchemistV4Locker";
        if (h == keccak256("BuybackVaultLayoutCanary")) return "ArchemistBuybackVault";
        if (h == keccak256("HolderRewardsLayoutCanary")) return "ArchemistHolderRewards";
        if (h == keccak256("PairRegistryLayoutCanary")) return "ArchemistPairRegistry";
        if (h == keccak256("OwnableLayoutCanary")) return "ArchemistUpgradeable";
        revert("unknown canary");
    }

    function artifactPath(string memory canary) internal pure returns (string memory) {
        return string.concat("out/LayoutCanaries.sol/", canary, ".json");
    }

    function referencePath(string memory canary) internal pure returns (string memory) {
        return string.concat("test/layout/reference/", implementationOf(canary), ".layout.json");
    }
}
