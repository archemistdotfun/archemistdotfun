// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Script } from "forge-std/Script.sol";

import { LayoutCanaries } from "../test/layout/LayoutCanaries.sol";
import { LayoutDump } from "../test/layout/LayoutDump.sol";

/// @notice Regenerates the committed storage-layout references that `test/UpgradeLayout.t.sol` enforces.
///
/// ```sh
/// forge build && forge script script/WriteLayoutReferences.s.sol
/// git diff test/layout/reference/
/// ```
///
/// **The diff is the deliverable.** Running this turns a failing gate green, so running it without
/// reading what changed defeats the entire mechanism. Appended lines at the end of `members` are the
/// only safe diff; anything else - a line changing, a line disappearing, a line appearing in the middle
/// - means live state at that slot is about to be reinterpreted as something else, and no timelock
/// proposal should be created until that is understood.
contract WriteLayoutReferences is Script {
    function run() external {
        string[] memory names = LayoutCanaries.names();
        for (uint256 i; i < names.length; ++i) {
            string memory out = LayoutDump.serialize(LayoutDump.read(LayoutCanaries.artifactPath(names[i])));
            vm.writeFile(LayoutCanaries.referencePath(names[i]), out);
        }
    }
}
