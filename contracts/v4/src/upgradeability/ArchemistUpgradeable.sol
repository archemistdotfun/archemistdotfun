// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @notice The shared base of every upgradeable Archemist system contract: two-step ownership, a
/// transient reentrancy guard, and UUPS upgrade authorisation that refuses an implementation whose
/// immutables disagree with the one currently installed.
///
/// Three properties of this base are load-bearing, and each exists to defeat a specific way a proxy
/// system gets bricked or stolen:
///
///   1. **All state is ERC-7201 namespaced.** Neither this base nor any contract deriving from it may
///      declare a storage variable outside a `@custom:storage-location erc7201:...` struct. Inheriting
///      contracts therefore cannot collide with the base no matter what they add, and "is this upgrade
///      layout-compatible?" reduces to the single, mechanically checkable question "is every namespace
///      struct append-only?" (see `test/UpgradeLayout.t.sol`).
///
///   2. **Immutables are part of the implementation, not the proxy.** `POOL_MANAGER`, `EXPECTED_CHAIN_ID`
///      and friends live in the implementation's *code*, so an upgrade silently re-points them. That is
///      the one storage-layout-clean way to swap the entire system out from under a proxy without
///      touching a single slot, so `_authorizeUpgrade` makes every implementation declare its immutables
///      and compares them against the running one. See `_checkImplementation`.
///
///   3. **The logic contract is locked at construction.** `_disableInitializers()` in the constructor
///      means the implementation itself can never be initialized, and so can never be owned - the
///      classic "uninitialized UUPS implementation gets taken over and `upgradeToAndCall`s itself into
///      a `selfdestruct`" hole, which for a UUPS proxy bricks every proxy pointing at it.
///
/// Ownership is deliberately two-step and deliberately OZ-shaped: the error and event signatures match
/// `Ownable2Step` exactly, so explorers, indexers and `cast` decode them without a custom ABI, even
/// though the storage is ours.
abstract contract ArchemistUpgradeable is Initializable, UUPSUpgradeable {
    /// @custom:storage-location erc7201:archemist.storage.Ownable2Step
    struct OwnableStorage {
        address owner;
        address pendingOwner;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("archemist.storage.Ownable2Step")) - 1)) & ~bytes32(uint256(0xff))
    ///      Verified at test time by `test_ownableStorageSlotIsErc7201`, so a typo here cannot go unnoticed.
    bytes32 private constant OWNABLE_STORAGE = 0x7eb7f18e4d696b88a6173537c021982d31a432da9a9a67478d114aa61f4a6f00;

    /// @dev Transient (EIP-1153) reentrancy flag. Cleared automatically at the end of the transaction,
    ///      so it occupies no storage slot and can never collide with a namespace struct. The slot is
    ///      an arbitrary high-entropy constant for the same reason ERC-7201 slots are.
    bytes32 private constant REENTRANCY_SLOT = keccak256("archemist.transient.ReentrancyGuard");

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error OwnableUnauthorizedAccount(address account);
    error OwnableInvalidOwner(address owner);
    error ReentrantCall();
    error InvalidImplementation(address implementation);
    error ImplementationMismatch();

    modifier onlyOwner() {
        if (msg.sender != _ownableStorage().owner) revert OwnableUnauthorizedAccount(msg.sender);
        _;
    }

    modifier nonReentrant() {
        bytes32 slot = REENTRANCY_SLOT;
        assembly ("memory-safe") {
            if tload(slot) {
                // ReentrantCall()
                mstore(0x00, 0x37ed32e8)
                revert(0x1c, 0x04)
            }
            tstore(slot, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
    }

    constructor() {
        _disableInitializers();
    }

    function owner() public view returns (address) {
        return _ownableStorage().owner;
    }

    function pendingOwner() public view returns (address) {
        return _ownableStorage().pendingOwner;
    }

    /// @notice Step one of two. Nothing changes until `newOwner` calls `acceptOwnership`, so a mistyped
    /// address cannot strand the contract with an owner nobody controls - which for these contracts
    /// would mean losing the ability to upgrade them, permanently.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert OwnableInvalidOwner(address(0));
        OwnableStorage storage $ = _ownableStorage();
        $.pendingOwner = newOwner;
        emit OwnershipTransferStarted($.owner, newOwner);
    }

    function acceptOwnership() external {
        OwnableStorage storage $ = _ownableStorage();
        if (msg.sender != $.pendingOwner) revert OwnableUnauthorizedAccount(msg.sender);
        address previousOwner = $.owner;
        $.owner = msg.sender;
        $.pendingOwner = address(0);
        emit OwnershipTransferred(previousOwner, msg.sender);
    }

    function __ArchemistUpgradeable_init(address owner_) internal onlyInitializing {
        if (owner_ == address(0)) revert OwnableInvalidOwner(address(0));
        _ownableStorage().owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
    }

    /// @notice What kind of contract this is. Distinct per system contract, and checked on every
    /// upgrade so a proxy can only ever be pointed at another implementation of *itself*.
    ///
    /// This closes a hole that the immutables check does not: `proxiableUUID` is the same value for
    /// every UUPS contract ever written, so without a tag, `upgradeToAndCall(launcherProxy, lockerImpl)`
    /// **succeeds** - both are UUPS, both were compiled against the same `POOL_MANAGER` and chain id, so
    /// every check passes and the launcher proxy silently comes back with the locker's ABI over the
    /// launcher's storage. Two proxies deployed minutes
    /// apart from one script, upgraded by a copy-pasted `cast` command, is the most plausible operator
    /// typo there is, and it is the one these checks exist to catch.
    ///
    /// `pure` and derived from a literal, so it lives in code rather than storage: an upgrade cannot
    /// change it, and reading it off an uninitialized implementation is safe.
    function ARCHEMIST_KIND() public pure virtual returns (bytes32);

    /// @dev UUPS's authorisation point. `proxiableUUID` is already checked by OZ's `upgradeToAndCall`,
    /// which rules out a non-UUPS target; what is left for us is (a) only the owner - the timelock - may
    /// upgrade at all, (b) the target must be a contract, (c) it must be the same *kind* of contract,
    /// and (d) its immutables must match, because those live in code rather than storage and a layout
    /// check would never see them change.
    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        if (newImplementation.code.length == 0) revert InvalidImplementation(newImplementation);
        // A target without this function reverts here rather than returning something wrong, which is
        // the safe direction: anything that is not an Archemist implementation is refused.
        if (ArchemistUpgradeable(newImplementation).ARCHEMIST_KIND() != ARCHEMIST_KIND()) {
            revert ImplementationMismatch();
        }
        _checkImplementation(newImplementation);
    }

    /// @dev Implemented by each system contract to assert that `newImplementation` was compiled with the
    /// same infrastructure immutables as this one. Reverts `ImplementationMismatch` if not. A staticcall
    /// into an uninitialized implementation is safe here precisely because immutable getters read from
    /// code, not storage.
    function _checkImplementation(address newImplementation) internal view virtual;

    function _ownableStorage() private pure returns (OwnableStorage storage $) {
        assembly ("memory-safe") {
            $.slot := OWNABLE_STORAGE
        }
    }
}
