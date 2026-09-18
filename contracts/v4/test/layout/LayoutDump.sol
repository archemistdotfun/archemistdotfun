// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Vm } from "forge-std/Vm.sol";

/// @notice Turns a layout canary's compiler artifact into a **stable, diffable description** of one
/// ERC-7201 namespace struct: every member's slot, offset, label and type, plus every type reachable
/// from it.
///
/// Stability is the whole job. solc's raw `storageLayout` is not comparable across commits: it carries
/// `astId`s and a `contract` path on every entry, and it keys its type table on strings like
/// `t_struct(LaunchInfo)10695_storage` whose number is an AST id that moves when an unrelated line is
/// added to an unrelated file. Diffing that raw output would fail constantly for no reason, and a gate
/// that cries wolf gets regenerated without being read, which is worse than no gate. So every AST id is
/// dropped and every type reference is resolved to its human label (`struct ArchemistV4Launcher.LaunchInfo`),
/// which changes only when the type actually changes.
///
/// What survives normalisation is exactly what an upgrade can get wrong: order, slot, offset, and type.
///
/// One implementation, two callers - `UpgradeLayout.t.sol` compares against the committed reference and
/// `script/WriteLayoutReferences.s.sol` writes it. A gate and a generator that each normalise in their
/// own way will eventually disagree, and the generator always wins that argument, silently.
library LayoutDump {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct Dump {
        /// @dev The namespace struct's own members, **in declaration order**. Order is load-bearing:
        /// the gate requires the committed list to be a prefix of this one.
        string[] members;
        /// @dev Every type reachable from the struct, one line each, sorted so the list does not
        /// reshuffle when an unrelated field is appended.
        string[] types;
    }

    error CanaryMustDeclareExactlyOneVariable(string canary);
    error NoStorageLayout(string canary);

    /// @param artifactPath e.g. `out/LayoutCanaries.sol/LauncherLayoutCanary.json`
    function read(string memory artifactPath) internal view returns (Dump memory d) {
        string memory j = vm.readFile(artifactPath);
        if (!vm.keyExistsJson(j, ".storageLayout")) revert NoStorageLayout(artifactPath);

        // A canary holds one state variable and nothing else, so `storage[0]` IS the namespace struct.
        // If someone adds a second, the dump would silently describe only the first.
        if (!vm.keyExistsJson(j, ".storageLayout.storage[0]") || vm.keyExistsJson(j, ".storageLayout.storage[1]")) {
            revert CanaryMustDeclareExactlyOneVariable(artifactPath);
        }

        string memory rootType = vm.parseJsonString(j, ".storageLayout.storage[0].type");
        d.members = _membersOf(j, rootType);
        // The namespace struct is deliberately left OUT of `types`: `members` already describes it, and
        // under the right rule. Its type line contains every member, so appending a field - the one
        // change upgrades are supposed to be able to make - would change that line and be reported as a
        // reshaped type, with a message about nested structs that has nothing to do with what happened.
        d.types = _allTypesExcept(j, rootType);
    }

    /// @dev `"<slot>:<offset> <label> <type label>"`, in declaration order.
    function _membersOf(string memory j, string memory typeKey) private view returns (string[] memory out) {
        string memory base = string.concat(_typePath(typeKey), ".members");
        uint256 n;
        while (vm.keyExistsJson(j, string.concat(base, "[", vm.toString(n), "]"))) {
            ++n;
            require(n < 512, "implausible member count");
        }
        out = new string[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = _memberLine(j, string.concat(base, "[", vm.toString(i), "]"));
        }
    }

    function _memberLine(string memory j, string memory at) private pure returns (string memory) {
        // `slot` is a JSON string, `offset` a JSON number - solc is not consistent about this and
        // parsing either one the wrong way reverts rather than returning something wrong, thankfully.
        return string.concat(
            vm.parseJsonString(j, string.concat(at, ".slot")),
            ":",
            vm.toString(vm.parseJsonUint(j, string.concat(at, ".offset"))),
            " ",
            vm.parseJsonString(j, string.concat(at, ".label")),
            " ",
            _labelOf(j, vm.parseJsonString(j, string.concat(at, ".type")))
        );
    }

    /// @dev One line per reachable type EXCEPT the namespace struct itself: `"<label> | <encoding> | <bytes>"`, and for a struct, its
    /// members appended. A nested struct that gets reordered changes its own line here even though the
    /// outer member list is untouched, which is the case a single-level dump would miss.
    function _allTypesExcept(string memory j, string memory rootType) private view returns (string[] memory out) {
        string[] memory keys = vm.parseJsonKeys(j, ".storageLayout.types");
        uint256 n;
        out = new string[](keys.length - 1);
        for (uint256 i; i < keys.length; ++i) {
            if (keccak256(bytes(keys[i])) == keccak256(bytes(rootType))) continue;
            string memory p = _typePath(keys[i]);
            string memory line = string.concat(
                _labelOf(j, keys[i]),
                " | ",
                vm.parseJsonString(j, string.concat(p, ".encoding")),
                " | ",
                vm.parseJsonString(j, string.concat(p, ".numberOfBytes")),
                " bytes"
            );
            if (vm.keyExistsJson(j, string.concat(p, ".members"))) {
                string[] memory m = _membersOf(j, keys[i]);
                for (uint256 k; k < m.length; ++k) {
                    line = string.concat(line, k == 0 ? " | " : ", ", m[k]);
                }
            }
            out[n++] = line;
        }
        _sort(out);
    }

    function _labelOf(string memory j, string memory typeKey) private pure returns (string memory) {
        return vm.parseJsonString(j, string.concat(_typePath(typeKey), ".label"));
    }

    /// @dev Type keys contain `(`, `)` and `,`, so they have to be bracket-quoted rather than dotted.
    function _typePath(string memory typeKey) private pure returns (string memory) {
        return string.concat('.storageLayout.types["', typeKey, '"]');
    }

    /// @dev Insertion sort. The lists are a dozen entries long and this runs off chain.
    function _sort(string[] memory a) private pure {
        for (uint256 i = 1; i < a.length; ++i) {
            string memory key = a[i];
            uint256 k = i;
            while (k != 0 && _gt(a[k - 1], key)) {
                a[k] = a[k - 1];
                --k;
            }
            a[k] = key;
        }
    }

    function _gt(string memory x, string memory y) private pure returns (bool) {
        bytes memory bx = bytes(x);
        bytes memory by = bytes(y);
        uint256 n = bx.length < by.length ? bx.length : by.length;
        for (uint256 i; i < n; ++i) {
            if (bx[i] != by[i]) return uint8(bx[i]) > uint8(by[i]);
        }
        return bx.length > by.length;
    }

    /// @dev The committed reference, as written by `script/WriteLayoutReferences.s.sol`. Two string
    /// arrays, one entry per line, so a real diff shows a real field moving.
    function serialize(Dump memory d) internal pure returns (string memory out) {
        out = string.concat("{\n  \"members\": [", _jsonArray(d.members), "],\n  \"types\": [");
        out = string.concat(out, _jsonArray(d.types), "]\n}\n");
    }

    function _jsonArray(string[] memory a) private pure returns (string memory out) {
        for (uint256 i; i < a.length; ++i) {
            out = string.concat(out, i == 0 ? "\n    \"" : ",\n    \"", a[i], "\"");
        }
        out = string.concat(out, a.length == 0 ? "" : "\n  ");
    }
}
