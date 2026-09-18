// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { LayoutCanaries } from "./layout/LayoutCanaries.sol";
import { LayoutDump } from "./layout/LayoutDump.sol";

/// @dev A deliberately wrong contract, kept here so the "nothing outside the namespace" check can be
/// shown to reject something. See `test_theLayoutGateRejectsAViolation` for the check that matters more.
contract LayoutViolator {
    address public plainStateVariable;
    uint256 public anotherOne;
}

/// @notice **The gate.** A storage-layout mistake does not fail loudly - it silently reinterprets live
/// state, and by the time anyone notices, the proxy is holding real money against a corrupted ledger.
/// No timelocked upgrade may be proposed until this test passes.
///
/// Every upgradeable contract here keeps **all** of its state inside one ERC-7201 namespaced struct, at
/// a slot derived from a string nobody will collide with by accident. Two consequences follow:
///
///   1. Two contracts, or a base and its derived contract, cannot collide with each other at all -
///      their namespaces are different hashes. Inheritance order, which is the usual source of proxy
///      layout bugs, stops mattering entirely.
///   2. "Is this upgrade safe?" reduces to one mechanical question: **is the namespace struct
///      append-only, and is there nothing outside it?**
///
/// So this file checks both halves, against the compiler's own layout output rather than against
/// anybody's reading of the source:
///
///   - **Inside the struct** (`test_namespaceStructsAreAppendOnly`): the committed layout in
///     `test/layout/reference/` must be a *prefix* of what the compiler emits today. Appending a field
///     passes. Reordering, retyping, removing, or inserting in the middle fails, and so does any change
///     to a nested struct the namespace reaches.
///   - **Outside the struct** (`test_upgradeLayoutIsCompatible`): no plain state variable exists at all,
///     which is what makes the namespace argument hold in the first place.
///   - **The slot constants** (`test_namespaceSlotsMatchErc7201`): hand-written hex in the source, so
///     exactly the kind of thing a typo ruins invisibly.
///
/// Immutables are unaffected by layout, which is why `_authorizeUpgrade` checks them separately (see
/// `ProxyBehaviourTest.test_upgradeRejectsDifferentImmutables`).
///
/// ### Why the references exist at all
///
/// A namespaced struct is reached through an assembly `.slot :=` assignment, so **solc allocates
/// nothing for it** and `storageLayout` comes back completely empty - `storage: []`, `types: {}`. The
/// first version of this gate read that empty output and concluded "no plain state variables", which is
/// true, trivial, and says nothing whatsoever about the struct: a reordered field sailed straight
/// through the one check the entire upgrade policy leans on. The canaries in `layout/LayoutCanaries.sol`
/// declare each struct as an ordinary state variable purely so the compiler is forced to lay it out and
/// report it.
///
/// Regenerate after a deliberate change, and **read the diff**:
/// `forge build && forge script script/WriteLayoutReferences.s.sol`
contract UpgradeLayoutTest is Test {
    uint256 private constant NONE = type(uint256).max;

    /// @dev Contract name -> the ERC-7201 namespace string its storage struct declares.
    struct Namespaced {
        string contractName;
        string namespace;
    }

    function _contracts() private pure returns (Namespaced[] memory list) {
        list = new Namespaced[](6);
        list[0] = Namespaced("ArchemistV4Launcher", "archemist.storage.Launcher");
        list[1] = Namespaced("ArchemistV4Locker", "archemist.storage.Locker");
        list[2] = Namespaced("ArchemistBuybackVault", "archemist.storage.BuybackVault");
        list[3] = Namespaced("ArchemistHolderRewards", "archemist.storage.HolderRewards");
        list[4] = Namespaced("ArchemistPairRegistry", "archemist.storage.PairRegistry");
        list[5] = Namespaced("ArchemistUpgradeable", "archemist.storage.Ownable2Step");
    }

    // ---------------------------------------------------------------------------------------------
    // The real check: the struct is append-only.
    // ---------------------------------------------------------------------------------------------

    function test_namespaceStructsAreAppendOnly() public view {
        string[] memory canaries = LayoutCanaries.names();
        for (uint256 i; i < canaries.length; ++i) {
            string memory impl = LayoutCanaries.implementationOf(canaries[i]);
            LayoutDump.Dump memory current = LayoutDump.read(LayoutCanaries.artifactPath(canaries[i]));
            (string[] memory refMembers, string[] memory refTypes) =
                _reference(LayoutCanaries.referencePath(canaries[i]));

            uint256 member = _firstMismatch(refMembers, current.members);
            if (member != NONE) {
                assertTrue(
                    false,
                    string.concat(
                        impl,
                        ": storage member #",
                        vm.toString(member),
                        " is no longer what the committed layout says it is.\n    committed: ",
                        refMembers[member],
                        "\n    now:       ",
                        member < current.members.length ? current.members[member] : "(removed)",
                        "\n    Live state at that slot would be reinterpreted. Only appending at the end is safe."
                    )
                );
            }

            uint256 nested = _missing(refTypes, current.types);
            if (nested != NONE) {
                assertTrue(
                    false,
                    string.concat(
                        impl,
                        ": a type its storage reaches has changed shape. A nested struct can move a field",
                        " without the outer member list changing at all.\n    committed: ",
                        refTypes[nested]
                    )
                );
            }
        }
    }

    /// @dev Every contract must have a canary and every canary a committed layout, or a contract quietly
    /// stops being covered by the paragraph above.
    function test_everyUpgradeableContractHasALayoutReference() public view {
        Namespaced[] memory list = _contracts();
        string[] memory canaries = LayoutCanaries.names();
        assertEq(canaries.length, list.length, "a namespaced contract has no layout canary");

        for (uint256 i; i < list.length; ++i) {
            bool found;
            for (uint256 j; j < canaries.length; ++j) {
                if (_eq(LayoutCanaries.implementationOf(canaries[j]), list[i].contractName)) found = true;
            }
            assertTrue(found, string.concat(list[i].contractName, " has no layout canary"));
            assertTrue(
                vm.exists(LayoutCanaries.referencePath(canaries[i])),
                string.concat("missing committed layout for ", list[i].contractName)
            );
        }
    }

    /// @dev **Proving the gate works.** `BrokenLauncherLayoutCanary` is the launcher's struct with its
    /// first two fields swapped - a change no compiler warns about, that no plain-state-variable check
    /// can see, and that would hand a live deployment its treasury address as a pair registry. The same
    /// comparison that clears all six real contracts must reject it, at the exact field that moved.
    ///
    /// A gate that has never been observed to fail is a comment, not a gate.
    function test_theLayoutGateRejectsAStructReorder() public view {
        LayoutDump.Dump memory broken = LayoutDump.read(LayoutCanaries.artifactPath("BrokenLauncherLayoutCanary"));
        (string[] memory refMembers, string[] memory refTypes) =
            _reference(LayoutCanaries.referencePath("LauncherLayoutCanary"));

        assertEq(
            _firstMismatch(refMembers, broken.members),
            0,
            "the gate must reject a swap of the launcher's first two fields"
        );
        // And it is a *reorder*, not a resize: same field count, same total bytes. Nothing about the
        // struct's size would have given this away, which is why the member-by-member check above is
        // the one that has to catch it.
        assertEq(broken.members.length, refMembers.length);
        // The reachable types are identical either way - same field types, just in a different order -
        // so the type check has nothing to say here. That is the division of labour: `members` catches
        // the namespace struct's own shape, `types` catches everything it reaches.
        assertEq(_missing(refTypes, broken.types), NONE, "a reorder does not change which types exist");
    }

    /// @dev The inverse: the check is not rejecting everything. The real launcher clears the same code.
    function test_theLayoutGateAcceptsTheRealLauncher() public view {
        (uint256 member, uint256 nested) = _compareAgainstReference("LauncherLayoutCanary");
        assertEq(member, NONE);
        assertEq(nested, NONE);
    }

    /// @dev Appending is the one change that must stay allowed, or the gate makes the contracts
    /// un-upgradeable and gets bypassed the first time someone needs a new field.
    function test_theLayoutGateAllowsAnAppendedField() public view {
        (string[] memory refMembers,) = _reference(LayoutCanaries.referencePath("LauncherLayoutCanary"));
        string[] memory appended = new string[](refMembers.length + 1);
        for (uint256 i; i < refMembers.length; ++i) {
            appended[i] = refMembers[i];
        }
        appended[refMembers.length] = "10:0 someNewField uint256";
        assertEq(_firstMismatch(refMembers, appended), NONE, "appending a field must pass");
    }

    /// @dev ...and truncating is not appending. A removed field leaves every later field shifted up.
    function test_theLayoutGateRejectsARemovedField() public view {
        (string[] memory refMembers,) = _reference(LayoutCanaries.referencePath("LauncherLayoutCanary"));
        string[] memory truncated = new string[](refMembers.length - 1);
        for (uint256 i; i < truncated.length; ++i) {
            truncated[i] = refMembers[i];
        }
        assertEq(_firstMismatch(refMembers, truncated), truncated.length, "a removed field must be rejected");
    }

    // ---------------------------------------------------------------------------------------------
    // The supporting checks.
    // ---------------------------------------------------------------------------------------------

    /// @dev ST-03. If this ever fails, some contract has grown a plain state variable and the whole
    /// "namespaces cannot collide" argument is void.
    function test_upgradeLayoutIsCompatible() public view {
        Namespaced[] memory list = _contracts();
        for (uint256 i; i < list.length; ++i) {
            assertEq(
                _plainStorageCount(list[i].contractName),
                0,
                string.concat(list[i].contractName, " declares plain storage outside its ERC-7201 namespace")
            );
        }
    }

    /// @dev PU-10's second half, for the outside-the-struct check: `LayoutViolator` declares exactly the
    /// kind of plain state variable that would collide across an upgrade, and the same code path that
    /// clears every real contract must see it.
    function test_theLayoutGateRejectsAViolation() public view {
        assertEq(_plainStorageCount("LayoutViolator"), 2, "the gate must see the violator's plain state variables");
    }

    /// @dev The slot constants are hand-written hex in the source (the compiler cannot fold
    /// `keccak256(abi.encode(...))` into a `constant`), so a typo ruins them invisibly. This recomputes
    /// each one and compares.
    function test_namespaceSlotsMatchErc7201() public pure {
        assertEq(
            _erc7201("archemist.storage.Ownable2Step"),
            0x7eb7f18e4d696b88a6173537c021982d31a432da9a9a67478d114aa61f4a6f00
        );
        assertEq(
            _erc7201("archemist.storage.Launcher"), 0x689b88330ef928c36efa0226238999b0a3788c71c79c8e51a7e2490244a1ee00
        );
        assertEq(
            _erc7201("archemist.storage.Locker"), 0x5c5807cf979554ded7e2333bb96537bdaaba8e3c42b08ea68baed3700da5a100
        );
        assertEq(
            _erc7201("archemist.storage.BuybackVault"),
            0x19cb286284977180c0c895a47c4910fab1fade273d58b8bb41971310be02aa00
        );
        assertEq(
            _erc7201("archemist.storage.HolderRewards"),
            0x7cc4e3216ff2a8a828543bdf480b8c60cfb363339885b57639e432fb9de1f000
        );
        assertEq(
            _erc7201("archemist.storage.PairRegistry"),
            0x4b98d64879486bcfb1c6847ae653aaf294e40726bf0eda79e0156f7466fd7100
        );
    }

    /// @dev And that they are all distinct, which is the property the whole scheme rests on.
    function test_namespaceSlotsAreDistinct() public pure {
        Namespaced[] memory list = _contracts();
        for (uint256 i; i < list.length; ++i) {
            for (uint256 j = i + 1; j < list.length; ++j) {
                assertTrue(
                    _erc7201(list[i].namespace) != _erc7201(list[j].namespace),
                    "two contracts share a storage namespace"
                );
            }
        }
    }

    // ---------------------------------------------------------------------------------------------

    function _compareAgainstReference(string memory canary) private view returns (uint256 member, uint256 nested) {
        LayoutDump.Dump memory current = LayoutDump.read(LayoutCanaries.artifactPath(canary));
        (string[] memory refMembers, string[] memory refTypes) = _reference(LayoutCanaries.referencePath(canary));
        member = _firstMismatch(refMembers, current.members);
        nested = _missing(refTypes, current.types);
    }

    function _reference(string memory path) private view returns (string[] memory members, string[] memory types) {
        require(vm.exists(path), string.concat("no committed layout at ", path));
        string memory j = vm.readFile(path);
        members = vm.parseJsonStringArray(j, ".members");
        types = vm.parseJsonStringArray(j, ".types");
        require(members.length != 0, "empty committed layout: regenerate it and read the diff");
    }

    /// @dev Append-only: `committed` must be a prefix of `current`. Returns the index of the first entry
    /// that breaks that, or `NONE`. A `current` that is shorter mismatches at its own length, which is
    /// what a removed field looks like.
    function _firstMismatch(string[] memory committed, string[] memory current) private pure returns (uint256) {
        for (uint256 i; i < committed.length; ++i) {
            if (i >= current.length || !_eq(committed[i], current[i])) return i;
        }
        return NONE;
    }

    /// @dev Types are compared as a set, because appending a field of a brand-new type legitimately adds
    /// entries. Every type the committed layout knew about must still be there, byte for byte.
    function _missing(string[] memory committed, string[] memory current) private pure returns (uint256) {
        for (uint256 i; i < committed.length; ++i) {
            bool found;
            for (uint256 j; j < current.length; ++j) {
                if (_eq(committed[i], current[j])) {
                    found = true;
                    break;
                }
            }
            if (!found) return i;
        }
        return NONE;
    }

    /// @dev Counts by probing indices rather than with a `[*]` selector, which cannot express "zero
    /// matches" - and zero is the answer this check expects, so it has to be representable.
    function _plainStorageCount(string memory contractName) private view returns (uint256 count) {
        string memory artifact =
            vm.readFile(string.concat("out/", _sourceFileOf(contractName), "/", contractName, ".json"));
        require(vm.keyExistsJson(artifact, ".storageLayout"), "no storageLayout: is extra_output set?");
        while (vm.keyExistsJson(artifact, string.concat(".storageLayout.storage[", vm.toString(count), "]"))) {
            ++count;
            require(count < 256, "implausible storage layout");
        }
    }

    /// @dev Every one of these lives in a file named after itself, except the test-only violator, which
    /// shares this test file.
    function _sourceFileOf(string memory contractName) private pure returns (string memory) {
        if (keccak256(bytes(contractName)) == keccak256("LayoutViolator")) return "UpgradeLayout.t.sol";
        return string.concat(contractName, ".sol");
    }

    function _erc7201(string memory namespace) private pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(namespace))) - 1)) & ~bytes32(uint256(0xff));
    }

    function _eq(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
