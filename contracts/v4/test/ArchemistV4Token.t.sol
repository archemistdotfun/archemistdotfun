// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";

import { ArchemistV4Token } from "../src/ArchemistV4Token.sol";

/// @dev An independent re-derivation of the reward accounting, written from the specification rather
/// than copied from the token, so `testFuzz_matchesAnIndependentModel` is a real differential and not a
/// tautology. Keeps per-holder state in plain mappings and recomputes from first principles.
contract ReferenceRewardModel {
    uint256 private constant Q128 = 1 << 128;

    mapping(address => uint256) public balanceOf;
    mapping(address => bool) public excluded;
    mapping(address => uint256) public paid;
    mapping(address => uint256) public owed;
    uint256 public rewardPerTokenX128;
    uint256 public eligibleSupply;

    function setExcluded(address who) external {
        excluded[who] = true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        if (!excluded[to]) eligibleSupply += amount;
    }

    function notify(uint256 amount) external returns (bool) {
        if (eligibleSupply == 0 || amount == 0 || amount >= Q128) return false;
        unchecked {
            rewardPerTokenX128 += FullMath.mulDiv(amount, Q128, eligibleSupply);
        }
        return true;
    }

    function transfer(address from, address to, uint256 amount) external {
        if (!excluded[from]) _settle(from);
        if (!excluded[to] && to != from) _settle(to);
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        if (excluded[from] != excluded[to]) {
            if (excluded[from]) {
                eligibleSupply += amount;
            } else {
                eligibleSupply -= amount;
            }
        }
    }

    function earned(address holder) external view returns (uint256) {
        if (excluded[holder]) return 0;
        return owed[holder] + _pending(holder);
    }

    function _settle(address holder) private {
        owed[holder] += _pending(holder);
        paid[holder] = rewardPerTokenX128;
    }

    function _pending(address holder) private view returns (uint256) {
        unchecked {
            return FullMath.mulDiv(balanceOf[holder], rewardPerTokenX128 - paid[holder], Q128);
        }
    }
}

/// @notice The launch token, and above all the property deployment #7 exists to establish: a transfer
/// touches nothing outside this contract, and can fail for exactly the two reasons every plain ERC-20
/// can fail.
contract ArchemistV4TokenTest is Test {
    address internal constant LOCKER = address(0x10C4E7);
    address internal constant POOL_MANAGER = address(0xF00D);
    address internal constant REWARDS = address(0xEEEE);
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant Q128 = 1 << 128;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    ArchemistV4Token internal token;

    function setUp() public {
        token = new ArchemistV4Token("Launch", "LNCH", SUPPLY, REWARDS, LOCKER, POOL_MANAGER);
        // The launcher (this contract) is excluded, so handing the supply to the locker - also excluded -
        // leaves the eligible float at zero, exactly as a real launch does.
        token.transfer(LOCKER, SUPPLY);
    }

    // -------------------------------------------------------------------------------------------
    // TK-01 - the whole point
    // -------------------------------------------------------------------------------------------

    /// @dev Scans the deployed bytecode for every call opcode, stepping over PUSH immediates so data
    /// bytes are never mistaken for instructions. The bar is deliberately absolute rather than
    /// "unreachable from transfer": this contract makes no external call ANYWHERE, so a scanner cannot
    /// find one to report no matter how it decompiles, and no future edit can quietly reintroduce one.
    function test_transferBytecodeHasNoExternalCall() public view {
        bytes memory code = address(token).code;
        assertGt(code.length, 0);
        uint256 i;
        while (i < code.length) {
            uint8 op = uint8(code[i]);
            assertTrue(
                op != 0xF1 && op != 0xF2 && op != 0xF4 && op != 0xFA,
                "ArchemistV4Token must contain no CALL/CALLCODE/DELEGATECALL/STATICCALL"
            );
            // PUSH1..PUSH32 carry 1..32 immediate bytes that are data, not opcodes.
            if (op >= 0x60 && op <= 0x7F) {
                i += uint256(op) - 0x60 + 2;
            } else {
                i += 1;
            }
        }
    }

    function test_transferMakesNoCallToAnyAddress() public {
        _give(alice, 100 ether);
        _notify(1 ether);

        // Nothing is called during a transfer - not the rewards contract, not the locker, nothing.
        vm.expectCall(REWARDS, bytes(""), 0);
        vm.expectCall(LOCKER, bytes(""), 0);
        vm.prank(alice);
        token.transfer(bob, 40 ether);
    }

    // -------------------------------------------------------------------------------------------
    // TK-02 / TK-03 - transfers cannot fail for any other reason
    // -------------------------------------------------------------------------------------------

    function testFuzz_transferNeverRevertsWithSufficientBalance(
        uint256 amount,
        uint256 seedRpt,
        uint256 seedPaid,
        bool toExcluded,
        bool selfTransfer
    ) public {
        _give(alice, 1_000 ether);
        address to = selfTransfer ? alice : (toExcluded ? POOL_MANAGER : bob);
        amount = bound(amount, 0, token.balanceOf(alice));

        // Force the accumulator and the holder's watermark to arbitrary points, including either side
        // of a wrap, which is the one place the `unchecked` arithmetic has to be argued rather than
        // assumed.
        _forceAccumulator(seedRpt);
        _forcePaid(alice, seedPaid);

        uint256 fromBefore = token.balanceOf(alice);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(alice);
        token.transfer(to, amount);

        if (to == alice) {
            assertEq(token.balanceOf(alice), fromBefore);
        } else {
            assertEq(token.balanceOf(alice), fromBefore - amount);
            assertEq(token.balanceOf(to), toBefore + amount);
        }
    }

    function test_transferRevertsOnlyForBalanceAndZeroAddress() public {
        _give(alice, 10 ether);

        vm.prank(alice);
        vm.expectRevert(ArchemistV4Token.InsufficientBalance.selector);
        token.transfer(bob, 10 ether + 1);

        vm.prank(alice);
        vm.expectRevert(ArchemistV4Token.InvalidReceiver.selector);
        token.transfer(address(0), 1);

        // Everything else a caller can do succeeds: zero amount, self-transfer, transfer to a contract
        // that would reject a callback, transfer of the entire balance.
        vm.startPrank(alice);
        token.transfer(bob, 0);
        token.transfer(alice, 10 ether);
        token.transfer(address(this), 10 ether);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------------------------
    // TK-04 / TK-05 - the exclusion set and the denominator
    // -------------------------------------------------------------------------------------------

    function test_excludedSetIsFixedAtConstruction() public {
        assertTrue(token.excluded(address(this)), "launcher");
        assertTrue(token.excluded(LOCKER));
        assertTrue(token.excluded(POOL_MANAGER));
        assertTrue(token.excluded(REWARDS));
        assertTrue(token.excluded(address(token)));
        assertFalse(token.excluded(alice));
        // And there is no setter at all - `excluded` is a public mapping with no writer outside the
        // constructor, so this is a compile-time guarantee, not a runtime check.
        (bool ok,) = address(token).call(abi.encodeWithSignature("setExcluded(address,bool)", alice, false));
        assertFalse(ok);
    }

    function test_eligibleSupplyTracksCrossingsOnly() public {
        _give(alice, 100 ether);
        assertEq(token.eligibleSupply(), 100 ether, "excluded -> holder raises the float");

        vm.prank(alice);
        token.transfer(bob, 40 ether);
        assertEq(token.eligibleSupply(), 100 ether, "holder -> holder leaves it alone");

        vm.prank(bob);
        token.transfer(POOL_MANAGER, 40 ether);
        assertEq(token.eligibleSupply(), 60 ether, "holder -> excluded shrinks it, as a sell does");

        vm.prank(LOCKER);
        token.transfer(POOL_MANAGER, 1 ether);
        assertEq(token.eligibleSupply(), 60 ether, "excluded -> excluded leaves it alone");
    }

    function test_eligibleSupplyAlwaysEqualsTheSumOfNonExcludedBalances() public {
        _give(alice, 100 ether);
        _give(bob, 250 ether);
        vm.prank(alice);
        token.transfer(carol, 30 ether);
        vm.prank(carol);
        token.transfer(POOL_MANAGER, 10 ether);
        _assertEligibleSupplyExact();
    }

    // -------------------------------------------------------------------------------------------
    // TK-06 / TK-07 / TK-08 - the accounting itself
    // -------------------------------------------------------------------------------------------

    /// @dev Entitlement is measured over the intervals a holder actually held, not sampled at some
    /// instant - so there is no snapshot moment to buy into and sell out of. (Within one wei per
    /// settlement of Q128 truncation, which is the design's deliberate trade: truncate once at
    /// settlement rather than on every distribution, so small holders are never rounded to nothing.)
    function test_settleAtPreTransferBalances() public {
        _give(alice, 10 ether);
        _notify(1 ether);
        assertApproxEqAbs(token.earned(alice), 1 ether, 1, "alice held the whole float for interval one");

        vm.prank(alice);
        token.transfer(bob, 5 ether);
        _notify(1 ether);

        assertApproxEqAbs(token.earned(alice), 1.5 ether, 2, "all of interval one, half of interval two");
        assertApproxEqAbs(token.earned(bob), 0.5 ether, 1, "nothing for an interval bob did not hold");
    }

    function test_holderWithAMinusculeShareStillAccrues() public {
        // 1 part in 10 million. A per-distribution truncation would round this to nothing every time.
        _give(alice, 1e7 ether);
        _give(bob, 1 ether);
        for (uint256 i; i < 10; ++i) {
            _notify(1 ether);
        }
        assertGt(token.earned(bob), 0, "small holders must not be rounded away");
        assertApproxEqAbs(token.earned(bob), uint256(10 ether) / (1e7 + 1), 1);
    }

    function testFuzz_rewardConservation(uint96[8] memory moves, uint96[4] memory fees) public {
        address[3] memory holders = [alice, bob, carol];
        _give(alice, 1_000 ether);

        uint256 totalNotified;
        for (uint256 i; i < moves.length; ++i) {
            address from = holders[i % 3];
            address to = holders[(i + 1) % 3];
            uint256 balance = token.balanceOf(from);
            if (balance != 0) {
                vm.prank(from);
                token.transfer(to, 1 + uint256(moves[i]) % balance);
            }
            if (i < fees.length && fees[i] != 0) {
                _notify(fees[i]);
                totalNotified += fees[i];
            }
            _assertEligibleSupplyExact();
        }

        uint256 earnedTotal;
        for (uint256 i; i < 3; ++i) {
            earnedTotal += token.earned(holders[i]);
        }
        // Never more than was notified, and never short by more than the per-notify truncation dust
        // (below one wei per holder per notify).
        assertLe(earnedTotal, totalNotified, "no reward may be created");
        assertGe(earnedTotal + 3 * fees.length, totalNotified, "and none may be lost beyond rounding dust");
    }

    function test_accumulatorWrapAroundIsHarmless() public {
        _give(alice, 100 ether);
        // Park the accumulator just below the wrap, with alice settled there.
        _forceAccumulator(type(uint256).max - 10);
        _forcePaid(alice, type(uint256).max - 10);

        // A notify now wraps `rewardPerTokenX128` past zero. The entitlement is computed from the
        // difference, which wraps identically, so it stays correct.
        _notify(1 ether);
        assertApproxEqAbs(token.earned(alice), 1 ether, 1, "entitlement survives the wrap");

        vm.prank(alice);
        token.transfer(bob, 50 ether);
        assertApproxEqAbs(token.earned(alice), 1 ether, 1, "and a transfer across it does not revert");
    }

    function testFuzz_matchesAnIndependentModel(uint96[10] memory moves, uint96[6] memory fees) public {
        ReferenceRewardModel model = new ReferenceRewardModel();
        model.setExcluded(address(this));
        model.setExcluded(LOCKER);
        model.setExcluded(POOL_MANAGER);
        model.setExcluded(REWARDS);
        model.setExcluded(address(token));

        address[3] memory holders = [alice, bob, carol];
        _give(alice, 1_000 ether);
        model.mint(alice, 1_000 ether);

        for (uint256 i; i < moves.length; ++i) {
            address from = holders[i % 3];
            address to = holders[(i + 1) % 3];
            uint256 balance = token.balanceOf(from);
            if (balance != 0) {
                uint256 amount = 1 + uint256(moves[i]) % balance;
                vm.prank(from);
                token.transfer(to, amount);
                model.transfer(from, to, amount);
            }
            if (i < fees.length && fees[i] != 0) {
                _notify(fees[i]);
                model.notify(fees[i]);
            }
            for (uint256 h; h < 3; ++h) {
                assertEq(token.earned(holders[h]), model.earned(holders[h]), "entitlement diverged from the model");
            }
        }
    }

    // -------------------------------------------------------------------------------------------
    // TK-09 / TK-10 - the reward surface
    // -------------------------------------------------------------------------------------------

    function test_notifyAndConsumeAreRewardsOnly() public {
        address[3] memory callers = [alice, LOCKER, address(this)];
        for (uint256 i; i < callers.length; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(ArchemistV4Token.NotRewards.selector);
            token.notifyReward(1 ether);
            vm.expectRevert(ArchemistV4Token.NotRewards.selector);
            token.consumeReward(alice);
            vm.expectRevert(ArchemistV4Token.NotRewards.selector);
            token.restoreReward(alice, 1 ether);
            vm.stopPrank();
        }
    }

    function test_notifyReturnsFalseInsteadOfReverting() public {
        // No eligible supply yet - the whole float is still inside the pool.
        vm.prank(REWARDS);
        assertFalse(token.notifyReward(1 ether));

        _give(alice, 100 ether);
        vm.prank(REWARDS);
        assertFalse(token.notifyReward(0), "nothing to distribute");
        vm.prank(REWARDS);
        assertFalse(token.notifyReward(Q128), "an amount far outside any real fee");
        vm.prank(REWARDS);
        assertFalse(token.notifyReward(type(uint256).max));
        assertEq(token.rewardPerTokenX128(), 0, "state must be untouched in every refused case");
    }

    function test_consumeRewardZeroesAndReturns() public {
        _give(alice, 100 ether);
        _notify(1 ether);
        uint256 expected = token.earned(alice);

        vm.prank(REWARDS);
        assertEq(token.consumeReward(alice), expected);
        assertEq(token.earned(alice), 0);

        vm.prank(REWARDS);
        assertEq(token.consumeReward(alice), 0, "a second consume takes nothing");
    }

    function test_restoreRewardPutsBackWhatCouldNotBeDelivered() public {
        _give(alice, 100 ether);
        _notify(1 ether);
        vm.startPrank(REWARDS);
        uint256 taken = token.consumeReward(alice);
        token.restoreReward(alice, taken);
        vm.stopPrank();
        assertEq(token.earned(alice), taken, "nothing lost, nothing stuck");
    }

    function test_excludedAddressesEarnNothing() public {
        _give(alice, 100 ether);
        _notify(1 ether);
        assertEq(token.earned(POOL_MANAGER), 0);
        assertEq(token.earned(LOCKER), 0);
        vm.prank(REWARDS);
        assertEq(token.consumeReward(POOL_MANAGER), 0);
    }

    // -------------------------------------------------------------------------------------------
    // TK-12 / TK-13 - gas and the plain ERC-20 surface
    // -------------------------------------------------------------------------------------------

    function test_transferGasBounded() public {
        _give(alice, 100 ether);
        _give(bob, 100 ether);

        vm.prank(alice);
        uint256 before = gasleft();
        token.transfer(carol, 1 ether);
        uint256 withoutSettlement = before - gasleft();

        _notify(1 ether);
        vm.prank(bob);
        before = gasleft();
        token.transfer(carol, 1 ether);
        uint256 withSettlement = before - gasleft();

        assertLt(withoutSettlement, 120_000, "wallets and scanners estimate on this");
        assertLt(withSettlement, 120_000);
    }

    function test_erc20SurfaceUnchanged() public {
        assertEq(token.name(), "Launch");
        assertEq(token.symbol(), "LNCH");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);

        _give(alice, 100 ether);
        vm.prank(alice);
        token.approve(bob, 40 ether);
        assertEq(token.allowance(alice, bob), 40 ether);

        vm.prank(bob);
        token.transferFrom(alice, carol, 30 ether);
        assertEq(token.allowance(alice, bob), 10 ether);

        vm.prank(bob);
        vm.expectRevert(ArchemistV4Token.InsufficientAllowance.selector);
        token.transferFrom(alice, carol, 11 ether);

        // The infinite-allowance path must not decrement.
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(alice, carol, 1 ether);
        assertEq(token.allowance(alice, bob), type(uint256).max);
    }

    function test_constructorRejectsDegenerateArguments() public {
        vm.expectRevert(ArchemistV4Token.EmptyMetadata.selector);
        new ArchemistV4Token("", "LNCH", SUPPLY, REWARDS, LOCKER, POOL_MANAGER);
        vm.expectRevert(ArchemistV4Token.EmptyMetadata.selector);
        new ArchemistV4Token("Launch", "", SUPPLY, REWARDS, LOCKER, POOL_MANAGER);
        vm.expectRevert(ArchemistV4Token.InsufficientBalance.selector);
        new ArchemistV4Token("Launch", "LNCH", 0, REWARDS, LOCKER, POOL_MANAGER);
        vm.expectRevert(ArchemistV4Token.InvalidReceiver.selector);
        new ArchemistV4Token("Launch", "LNCH", SUPPLY, address(0), LOCKER, POOL_MANAGER);
        vm.expectRevert(ArchemistV4Token.InvalidReceiver.selector);
        new ArchemistV4Token("Launch", "LNCH", SUPPLY, REWARDS, address(0), POOL_MANAGER);
        vm.expectRevert(ArchemistV4Token.InvalidReceiver.selector);
        new ArchemistV4Token("Launch", "LNCH", SUPPLY, REWARDS, LOCKER, address(0));
    }

    // -------------------------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------------------------

    function _give(address to, uint256 amount) private {
        vm.prank(LOCKER);
        token.transfer(to, amount);
    }

    function _notify(uint256 amount) private {
        vm.prank(REWARDS);
        token.notifyReward(amount);
    }

    /// @dev `rewardPerTokenX128` is the 8th declared slot (name, symbol, balanceOf, allowance,
    /// excluded, eligibleSupply, rewardPerTokenX128 - string storage takes one slot each). Located by
    /// search rather than hardcoded so it survives a reordering.
    function _forceAccumulator(uint256 value) private {
        uint256 slot = _findSlot(token.rewardPerTokenX128());
        vm.store(address(token), bytes32(slot), bytes32(value));
        assertEq(token.rewardPerTokenX128(), value, "failed to locate rewardPerTokenX128");
    }

    function _forcePaid(address holder, uint256 value) private {
        // holderState is a mapping to a two-word struct; the first word is paidPerTokenX128.
        for (uint256 slot; slot < 32; ++slot) {
            bytes32 entry = keccak256(abi.encode(holder, slot));
            bytes32 current = vm.load(address(token), entry);
            vm.store(address(token), entry, bytes32(value));
            (uint256 paid,) = token.holderState(holder);
            if (paid == value) return;
            vm.store(address(token), entry, current);
        }
        revert("failed to locate holderState");
    }

    function _findSlot(uint256 currentValue) private returns (uint256) {
        for (uint256 slot; slot < 32; ++slot) {
            bytes32 current = vm.load(address(token), bytes32(slot));
            if (uint256(current) != currentValue) continue;
            vm.store(address(token), bytes32(slot), bytes32(uint256(1)));
            bool matched = token.rewardPerTokenX128() == 1;
            vm.store(address(token), bytes32(slot), current);
            if (matched) return slot;
        }
        revert("failed to locate rewardPerTokenX128");
    }

    function _assertEligibleSupplyExact() private view {
        uint256 excludedHeld = token.balanceOf(address(this)) + token.balanceOf(LOCKER) + token.balanceOf(POOL_MANAGER)
            + token.balanceOf(REWARDS) + token.balanceOf(address(token));
        assertEq(token.eligibleSupply(), token.totalSupply() - excludedHeld);
    }
}
