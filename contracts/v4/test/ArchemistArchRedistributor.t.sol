// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { ArchemistArchRedistributor } from "../src/ArchemistArchRedistributor.sol";

/// @dev 18-decimal stand-in for ARCH, and (with `decimals` ignored) for the 6-decimal USDC side.
contract MockToken {
    string public name;
    mapping(address => uint256) public balanceOf;
    /// @dev Stands in for a recipient the token itself refuses - a blocklist, an allowlist it is not
    /// on, a contract that reverts in a hook. The batch must step over it without losing anything.
    mapping(address => bool) public blocked;

    constructor(string memory name_) {
        name = name_;
    }

    function setBlocked(address who, bool value) external {
        blocked[who] = value;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(!blocked[to], "blocked");
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Stands in for ArchemistV2LockerV2: credits the creator's share as `claimable` (it never
/// pushes), hands it over on `claim`, and lets `collectFees` be made to revert - the locker really
/// does revert when the position is unknown or no longer held.
contract MockV2Locker {
    mapping(address => mapping(address => uint256)) public claimable;
    bool public collectReverts;
    uint256 public collectCalls;
    address public arch;
    address public usdc;
    uint256 public pendingArch;
    uint256 public pendingUsdc;
    address public recipient;

    constructor(address arch_, address usdc_) {
        arch = arch_;
        usdc = usdc_;
    }

    function setRecipient(address who) external {
        recipient = who;
    }

    function setCollectReverts(bool value) external {
        collectReverts = value;
    }

    /// @dev What the pool would hand over on the next collectFees().
    function setPending(uint256 archAmount, uint256 usdcAmount) external {
        pendingArch = archAmount;
        pendingUsdc = usdcAmount;
    }

    function collectFees(address) external returns (uint256, uint256) {
        collectCalls++;
        require(!collectReverts, "collect");
        claimable[recipient][arch] += pendingArch;
        claimable[recipient][usdc] += pendingUsdc;
        pendingArch = 0;
        pendingUsdc = 0;
        return (0, 0);
    }

    function credit(address who, address asset, uint256 amount) external {
        claimable[who][asset] += amount;
    }

    function claim(address asset, address to) external returns (uint256 amount) {
        amount = claimable[msg.sender][asset];
        require(amount != 0, "nothing");
        claimable[msg.sender][asset] = 0;
        require(MockToken(asset).transfer(to, amount), "payout");
    }
}

contract ArchemistArchRedistributorTest is Test {
    ArchemistArchRedistributor internal dist;
    MockToken internal arch;
    MockToken internal usdc;
    MockV2Locker internal locker;

    address internal owner = address(0xA11CE);
    address internal publisher = address(0xB0B);
    address internal sink = address(0x5152);

    address internal alice = address(0xA1);
    address internal bob = address(0xB2);
    address internal carol = address(0xC3);
    address internal dave = address(0xD4);

    function setUp() public {
        arch = new MockToken("ARCH");
        usdc = new MockToken("USDC");
        locker = new MockV2Locker(address(arch), address(usdc));

        dist = new ArchemistArchRedistributor(
            address(arch), address(usdc), address(locker), owner, publisher, sink, block.chainid
        );
        locker.setRecipient(address(dist));
    }

    // --- helpers ----------------------------------------------------------------------------

    function _leaf(uint256 epochId, address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(epochId, account, amount))));
    }

    /// @dev Sorted-pair Merkle tree, odd node promoted - the same shape the contract verifies and the
    /// snapshot script builds.
    function _root(bytes32[] memory leaves) internal pure returns (bytes32) {
        bytes32[] memory level = leaves;
        while (level.length > 1) {
            uint256 next = (level.length + 1) / 2;
            bytes32[] memory parents = new bytes32[](next);
            for (uint256 i; i < next; ++i) {
                uint256 l = 2 * i;
                uint256 r = l + 1;
                parents[i] = r < level.length ? _hashPair(level[l], level[r]) : level[l];
            }
            level = parents;
        }
        return level.length == 0 ? bytes32(0) : level[0];
    }

    function _proof(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory proof) {
        bytes32[] memory tmp = new bytes32[](32);
        uint256 depth;
        bytes32[] memory level = leaves;
        uint256 idx = index;
        while (level.length > 1) {
            uint256 sibling = idx ^ 1;
            if (sibling < level.length) {
                tmp[depth++] = level[sibling];
            }
            uint256 next = (level.length + 1) / 2;
            bytes32[] memory parents = new bytes32[](next);
            for (uint256 i; i < next; ++i) {
                uint256 l = 2 * i;
                uint256 r = l + 1;
                parents[i] = r < level.length ? _hashPair(level[l], level[r]) : level[l];
            }
            level = parents;
            idx /= 2;
        }
        proof = new bytes32[](depth);
        for (uint256 i; i < depth; ++i) {
            proof[i] = tmp[i];
        }
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    function _fourLeaves(uint256 epochId) internal pure returns (bytes32[] memory leaves) {
        leaves = new bytes32[](4);
        leaves[0] = _leaf(epochId, address(0xA1), 40 ether);
        leaves[1] = _leaf(epochId, address(0xB2), 30 ether);
        leaves[2] = _leaf(epochId, address(0xC3), 20 ether);
        leaves[3] = _leaf(epochId, address(0xD4), 10 ether);
    }

    function _publishFour(uint256 epochId) internal returns (bytes32[] memory leaves) {
        leaves = _fourLeaves(epochId);
        vm.prank(publisher);
        dist.publishEpoch(_root(leaves), 100 ether, uint64(block.number), "ipfs://epoch");
    }

    // --- fee intake -------------------------------------------------------------------------

    function test_pull_collectsArchAndSweepsUsdcToSink() public {
        arch.mint(address(locker), 500 ether);
        usdc.mint(address(locker), 250e6);
        locker.setPending(500 ether, 250e6);

        (uint256 pulledArch, uint256 sweptUsdc) = dist.pull();

        assertEq(pulledArch, 500 ether, "arch pulled");
        assertEq(sweptUsdc, 250e6, "usdc swept");
        assertEq(arch.balanceOf(address(dist)), 500 ether, "arch held for holders");
        assertEq(usdc.balanceOf(sink), 250e6, "usdc went to the sink, not to holders");
        assertEq(usdc.balanceOf(address(dist)), 0, "no usdc retained");
        assertEq(dist.unallocated(), 500 ether, "all of it distributable");
    }

    function test_pull_isPermissionlessAndSurvivesACollectRevert() public {
        arch.mint(address(locker), 10 ether);
        locker.credit(address(dist), address(arch), 10 ether);
        locker.setCollectReverts(true);

        // The attempt is made and reverts; the revert (and the mock's own counter with it) is
        // swallowed, which is the whole point.
        vm.expectCall(address(locker), abi.encodeWithSignature("collectFees(address)", address(arch)));
        vm.prank(address(0xDEAD));
        (uint256 pulledArch,) = dist.pull();

        assertEq(pulledArch, 10 ether, "already-credited fees still came through");
    }

    function test_sweepUsdc_alsoMovesUsdcSentDirectly() public {
        usdc.mint(address(dist), 7e6);
        uint256 swept = dist.sweepUsdc();
        assertEq(swept, 7e6);
        assertEq(usdc.balanceOf(sink), 7e6);
    }

    // --- epochs -----------------------------------------------------------------------------

    function test_publishEpoch_reservesTheBalance() public {
        arch.mint(address(dist), 100 ether);
        _publishFour(0);

        assertEq(dist.reserved(), 100 ether, "reserved");
        assertEq(dist.unallocated(), 0, "nothing left to promise twice");
        assertEq(dist.epochCount(), 1);

        (, uint256 total,, uint64 snapshotBlock,, bool revoked, string memory uri) = dist.epochs(0);
        assertEq(total, 100 ether);
        assertEq(snapshotBlock, uint64(block.number));
        assertFalse(revoked);
        assertEq(uri, "ipfs://epoch");
    }

    function test_publishEpoch_cannotPromiseArchItDoesNotHold() public {
        arch.mint(address(dist), 99 ether);
        bytes32[] memory leaves = _fourLeaves(0);
        vm.prank(publisher);
        vm.expectRevert(
            abi.encodeWithSelector(ArchemistArchRedistributor.InsufficientUnallocated.selector, 100 ether, 99 ether)
        );
        dist.publishEpoch(_root(leaves), 100 ether, uint64(block.number), "");
    }

    function test_publishEpoch_cannotDoublePromiseTheSameArch() public {
        arch.mint(address(dist), 100 ether);
        _publishFour(0);

        bytes32[] memory leaves = _fourLeaves(1);
        vm.prank(publisher);
        vm.expectRevert(
            abi.encodeWithSelector(ArchemistArchRedistributor.InsufficientUnallocated.selector, 100 ether, 0)
        );
        dist.publishEpoch(_root(leaves), 100 ether, uint64(block.number), "");
    }

    function test_publishEpoch_onlyPublisherOrOwner() public {
        arch.mint(address(dist), 100 ether);
        bytes32[] memory leaves = _fourLeaves(0);

        vm.prank(alice);
        vm.expectRevert(ArchemistArchRedistributor.NotPublisher.selector);
        dist.publishEpoch(_root(leaves), 100 ether, uint64(block.number), "");

        vm.prank(owner);
        dist.publishEpoch(_root(leaves), 100 ether, uint64(block.number), "");
        assertEq(dist.epochCount(), 1, "owner can publish too");
    }

    function test_revokeEpoch_freesTheReservationBeforeAnyoneClaims() public {
        arch.mint(address(dist), 100 ether);
        _publishFour(0);

        vm.prank(owner);
        dist.revokeEpoch(0);

        assertEq(dist.reserved(), 0);
        assertEq(dist.unallocated(), 100 ether, "back in the pot for a corrected root");
    }

    function test_revokeEpoch_blockedOnceSomeoneHasBeenPaid() public {
        arch.mint(address(dist), 100 ether);
        bytes32[] memory leaves = _publishFour(0);

        dist.claim(0, alice, 40 ether, _proof(leaves, 0));

        vm.prank(owner);
        vm.expectRevert(ArchemistArchRedistributor.EpochStarted.selector);
        dist.revokeEpoch(0);
    }

    function test_claim_revertsForARevokedEpoch() public {
        arch.mint(address(dist), 100 ether);
        bytes32[] memory leaves = _publishFour(0);
        vm.prank(owner);
        dist.revokeEpoch(0);

        vm.expectRevert(ArchemistArchRedistributor.EpochRevokedError.selector);
        dist.claim(0, alice, 40 ether, _proof(leaves, 0));
    }

    // --- claiming ---------------------------------------------------------------------------

    function test_claim_paysTheLeafAccountNotTheCaller() public {
        arch.mint(address(dist), 100 ether);
        bytes32[] memory leaves = _publishFour(0);

        // A keeper submits alice's proof; alice gets the ARCH.
        vm.prank(address(0xBEEF));
        uint256 paid = dist.claim(0, alice, 40 ether, _proof(leaves, 0));

        assertEq(paid, 40 ether);
        assertEq(arch.balanceOf(alice), 40 ether, "holder paid");
        assertEq(arch.balanceOf(address(0xBEEF)), 0, "keeper paid nothing to itself");
        assertEq(dist.reserved(), 60 ether);
        assertTrue(dist.isClaimed(0, alice));
    }

    function test_claim_rejectsWrongAmountWrongAccountAndDoubleClaim() public {
        arch.mint(address(dist), 100 ether);
        bytes32[] memory leaves = _publishFour(0);
        bytes32[] memory aliceProof = _proof(leaves, 0);

        vm.expectRevert(ArchemistArchRedistributor.InvalidProof.selector);
        dist.claim(0, alice, 41 ether, aliceProof);

        vm.expectRevert(ArchemistArchRedistributor.InvalidProof.selector);
        dist.claim(0, address(0xF00D), 40 ether, aliceProof);

        dist.claim(0, alice, 40 ether, aliceProof);
        vm.expectRevert(ArchemistArchRedistributor.AlreadyClaimed.selector);
        dist.claim(0, alice, 40 ether, aliceProof);
    }

    function test_claim_proofFromOneEpochDoesNotWorkInAnother() public {
        arch.mint(address(dist), 200 ether);
        bytes32[] memory leaves0 = _publishFour(0);
        _publishFour(1);

        // Epoch 1's leaves are hashed with epochId 1, so epoch 0's proof cannot cross over.
        vm.expectRevert(ArchemistArchRedistributor.InvalidProof.selector);
        dist.claim(1, alice, 40 ether, _proof(leaves0, 0));
    }

    function test_claimBatch_paysEveryoneAndIsIdempotent() public {
        arch.mint(address(dist), 100 ether);
        bytes32[] memory leaves = _publishFour(0);

        uint256[] memory ids = new uint256[](4);
        address[] memory accounts = new address[](4);
        uint256[] memory amounts = new uint256[](4);
        bytes32[][] memory proofs = new bytes32[][](4);
        accounts[0] = alice;
        amounts[0] = 40 ether;
        accounts[1] = bob;
        amounts[1] = 30 ether;
        accounts[2] = carol;
        amounts[2] = 20 ether;
        accounts[3] = dave;
        amounts[3] = 10 ether;
        for (uint256 i; i < 4; ++i) {
            proofs[i] = _proof(leaves, i);
        }

        vm.prank(address(0xC0FFEE));
        uint256 totalPaid = dist.claimBatch(ids, accounts, amounts, proofs);
        assertEq(totalPaid, 100 ether);
        assertEq(arch.balanceOf(alice), 40 ether);
        assertEq(arch.balanceOf(dave), 10 ether);
        assertEq(dist.reserved(), 0);
        assertEq(arch.balanceOf(address(dist)), 0, "the epoch is fully paid out");

        // Re-running the same batch is a no-op rather than a double payment or a revert.
        uint256 second = dist.claimBatch(ids, accounts, amounts, proofs);
        assertEq(second, 0);
        assertEq(arch.balanceOf(alice), 40 ether);
    }

    function test_claimBatch_skipsABadProofButPaysTheRest() public {
        arch.mint(address(dist), 100 ether);
        bytes32[] memory leaves = _publishFour(0);

        uint256[] memory ids = new uint256[](2);
        address[] memory accounts = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        bytes32[][] memory proofs = new bytes32[][](2);
        accounts[0] = alice;
        amounts[0] = 999 ether; // wrong amount: not in the tree
        proofs[0] = _proof(leaves, 0);
        accounts[1] = bob;
        amounts[1] = 30 ether;
        proofs[1] = _proof(leaves, 1);

        uint256 totalPaid = dist.claimBatch(ids, accounts, amounts, proofs);
        assertEq(totalPaid, 30 ether);
        assertEq(arch.balanceOf(alice), 0);
        assertFalse(dist.isClaimed(0, alice), "alice's real entitlement is untouched");
        assertEq(arch.balanceOf(bob), 30 ether);
    }

    function test_claimBatch_leavesAnUnpayableHolderClaimableLater() public {
        arch.mint(address(dist), 100 ether);

        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = _leaf(0, carol, 60 ether);
        leaves[1] = _leaf(0, bob, 40 ether);
        vm.prank(publisher);
        dist.publishEpoch(_root(leaves), 100 ether, uint64(block.number), "");

        // Carol cannot receive the token at all right now.
        arch.setBlocked(carol, true);

        uint256[] memory ids = new uint256[](2);
        address[] memory accounts = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        bytes32[][] memory proofs = new bytes32[][](2);
        accounts[0] = carol;
        amounts[0] = 60 ether;
        proofs[0] = _proof(leaves, 0);
        accounts[1] = bob;
        amounts[1] = 40 ether;
        proofs[1] = _proof(leaves, 1);

        uint256 totalPaid = dist.claimBatch(ids, accounts, amounts, proofs);

        assertEq(totalPaid, 40 ether, "only bob could be paid");
        assertEq(arch.balanceOf(bob), 40 ether, "one bad recipient did not take the batch down");
        assertFalse(dist.isClaimed(0, carol), "carol's entitlement is intact");
        assertEq(dist.reserved(), 60 ether, "and still reserved for her");

        // Once she can receive again, the same proof pays her - nothing was lost.
        arch.setBlocked(carol, false);
        dist.claim(0, carol, 60 ether, proofs[0]);
        assertEq(arch.balanceOf(carol), 60 ether);
        assertEq(dist.reserved(), 0);
    }

    function test_claim_revertsRatherThanSilentlySucceedingWhenTheHolderCannotReceive() public {
        arch.mint(address(dist), 100 ether);
        bytes32[] memory leaves = _publishFour(0);
        arch.setBlocked(alice, true);

        vm.expectRevert(ArchemistArchRedistributor.TransferFailed.selector);
        dist.claim(0, alice, 40 ether, _proof(leaves, 0));
    }

    function test_overdrawnRootCannotReachIntoAnotherEpoch() public {
        arch.mint(address(dist), 100 ether);

        // A root whose leaves sum to more than the epoch reserves.
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = _leaf(0, alice, 30 ether);
        leaves[1] = _leaf(0, bob, 90 ether);
        vm.prank(publisher);
        dist.publishEpoch(_root(leaves), 50 ether, uint64(block.number), "");

        dist.claim(0, alice, 30 ether, _proof(leaves, 0));

        vm.expectRevert(ArchemistArchRedistributor.EpochOverdrawn.selector);
        dist.claim(0, bob, 90 ether, _proof(leaves, 1));

        assertEq(arch.balanceOf(address(dist)), 70 ether, "the other 50 was never at risk");
    }

    // --- sweeping and admin -----------------------------------------------------------------

    function test_archIsNotSweepable() public {
        arch.mint(address(dist), 100 ether);
        vm.prank(owner);
        vm.expectRevert(ArchemistArchRedistributor.ArchNotSweepable.selector);
        dist.sweepToken(address(arch));
    }

    function test_sweepToken_forwardsStrayTokens() public {
        MockToken stray = new MockToken("STRAY");
        stray.mint(address(dist), 5 ether);
        dist.sweepToken(address(stray));
        assertEq(stray.balanceOf(sink), 5 ether);
    }

    function test_adminSettersAreOwnerOnlyAndOwnershipIsTwoStep() public {
        vm.prank(alice);
        vm.expectRevert(ArchemistArchRedistributor.NotOwner.selector);
        dist.setPublisher(alice);

        vm.prank(owner);
        dist.setPublisher(carol);
        assertEq(dist.publisher(), carol);

        vm.prank(owner);
        dist.setUsdcSink(carol);
        assertEq(dist.usdcSink(), carol);

        vm.prank(owner);
        dist.transferOwnership(bob);
        assertEq(dist.owner(), owner, "not yet");
        vm.prank(bob);
        dist.acceptOwnership();
        assertEq(dist.owner(), bob);
    }

    /// @dev Cross-implementation check against fixtures produced by scripts/arch-redistributor-snapshot.mjs
    /// (viem, JS). If the two ever disagree on leaf encoding, pair ordering or how an odd node is
    /// promoted, every proof the script publishes would be rejected on-chain - and the only place
    /// that would show up is here. Five leaves deliberately, so the odd-node path is exercised.
    function test_acceptsProofsBuiltByTheSnapshotScript() public {
        arch.mint(address(dist), 105 ether);

        bytes32 root = 0x3154b20cb4b42df43961626163a038e03d531229ef3ab8b81b97845772748551;
        vm.prank(publisher);
        dist.publishEpoch(root, 105 ether, uint64(block.number), "ipfs://fixture");

        // Index 0: a full-depth proof.
        bytes32[] memory p0 = new bytes32[](3);
        p0[0] = 0x7a2f985873b7937bcb9f63524c9597eb00122ac3155d478696c7ed6062c98ac8;
        p0[1] = 0x474bf1f8b64407b14a71cfd3a794bddefe58f3c12f656ee244349bee8aec5746;
        p0[2] = 0x0b2e8aa46a6d334a235294707adae755fb86a778be3235c12d63d9a431aeb523;
        dist.claim(0, address(0xa1), 40 ether, p0);
        assertEq(arch.balanceOf(address(0xa1)), 40 ether);

        // Index 4: the odd leaf, promoted twice, so its proof is one node long.
        bytes32[] memory p4 = new bytes32[](1);
        p4[0] = 0x153697a7fbddd7414874270e185549ddf087c1fad5b3e1bf0f04efd0fcbc5061;
        dist.claim(0, address(0xe5), 5 ether, p4);
        assertEq(arch.balanceOf(address(0xe5)), 5 ether);
    }

    /// @dev The leaf encoding itself, against the same fixture generator.
    function test_leafEncodingMatchesTheScript() public view {
        assertEq(dist.leaf(0, address(0xa1), 40 ether), _leaf(0, address(0xa1), 40 ether));
    }

    function testFuzz_reservedNeverExceedsTheBalance(uint96 funded, uint96 promised, uint8 claims) public {
        funded = uint96(bound(funded, 1 ether, 1_000_000 ether));
        promised = uint96(bound(promised, 1, funded));
        arch.mint(address(dist), funded);

        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = _leaf(0, alice, promised);
        vm.prank(publisher);
        dist.publishEpoch(_root(leaves), promised, uint64(block.number), "");

        assertLe(dist.reserved(), arch.balanceOf(address(dist)), "solvent on publish");

        if (claims % 2 == 0) {
            dist.claim(0, alice, promised, _proof(leaves, 0));
            assertEq(dist.reserved(), 0);
        }
        assertLe(dist.reserved(), arch.balanceOf(address(dist)), "solvent after claiming");
    }
}
