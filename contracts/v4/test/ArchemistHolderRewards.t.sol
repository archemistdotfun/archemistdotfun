// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { ArchemistHolderRewards } from "../src/ArchemistHolderRewards.sol";
import { ArchemistV4Token } from "../src/ArchemistV4Token.sol";
import { ArchemistDeploy } from "./Deploy.sol";

/// @dev Minimal 6-decimal ERC-20, so reward payouts are exercised against a currency whose smallest
/// unit is coarse - the case where a naive per-distribution rounding would quietly erase small holders.
contract MockRewardQuote {
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Stands in for ArchemistV4Locker: holds the credited rewards and hands them over on claim.
contract MockRewardsLocker {
    mapping(address => mapping(address => uint256)) public claimable;

    function creditNative(address who) external payable {
        claimable[who][address(0)] += msg.value;
    }

    function creditToken(address who, address asset, uint256 amount) external {
        claimable[who][asset] += amount;
    }

    function claim(address asset, address to) external returns (uint256 amount) {
        amount = claimable[msg.sender][asset];
        claimable[msg.sender][asset] = 0;
        if (asset == address(0)) {
            (bool ok,) = to.call{ value: amount }("");
            require(ok, "native payout");
        } else {
            require(MockRewardQuote(asset).transfer(to, amount), "token payout");
        }
    }

    receive() external payable { }
}

/// @dev Stands in for ArchemistV4Launcher: the only address allowed to register tokens, and the address
/// that mints them. Both roles matter - the minter must be an excluded address or eligible supply would
/// start out disagreeing with real balances.
contract MockRewardsLauncher {
    ArchemistHolderRewards public rewards;
    address public immutable locker;
    address public immutable poolManager;

    constructor(address locker_, address poolManager_) {
        locker = locker_;
        poolManager = poolManager_;
    }

    function setRewards(ArchemistHolderRewards rewards_) external {
        rewards = rewards_;
    }

    function deployToken(string calldata name_, string calldata symbol_, address quote)
        external
        returns (ArchemistV4Token token)
    {
        token = new ArchemistV4Token(name_, symbol_, 1_000_000_000 ether, address(rewards), locker, poolManager);
        rewards.register(address(token), quote);
    }

    function send(ArchemistV4Token token, address to, uint256 amount) external {
        token.transfer(to, amount);
    }
}

contract RejectingHolder {
    receive() external payable {
        revert("no thanks");
    }
}

contract PassiveHolder {
    receive() external payable { }
}

contract ArchemistHolderRewardsTest is Test {
    address internal constant POOL_MANAGER = address(0xF00D);
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    MockRewardsLauncher internal launcher;
    MockRewardsLocker internal locker;
    ArchemistHolderRewards internal rewards;
    ArchemistV4Token internal token;

    function setUp() public {
        locker = new MockRewardsLocker();
        launcher = new MockRewardsLauncher(address(locker), POOL_MANAGER);
        rewards = ArchemistDeploy.rewards(address(this), address(launcher), address(locker));
        launcher.setRewards(rewards);
        token = launcher.deployToken("Holder Token", "HOLD", address(0));
    }

    // --- Registration and access control ------------------------------------------------------------

    function test_onlyLauncherCanRegister() public {
        vm.expectRevert(ArchemistHolderRewards.NotLauncher.selector);
        rewards.register(address(0xdead), address(0));
    }

    function test_registrationIsOncePerToken() public {
        vm.prank(address(launcher));
        vm.expectRevert(ArchemistHolderRewards.AlreadyRegistered.selector);
        rewards.register(address(token), address(0));
    }

    /// @dev The exclusion set now lives on the token, fixed in its constructor, with no setter anywhere.
    function test_exclusionSetIsExactlyTheInfrastructure() public view {
        assertTrue(token.excluded(POOL_MANAGER), "pool manager holds the float");
        assertTrue(token.excluded(address(locker)));
        assertTrue(token.excluded(address(launcher)));
        assertTrue(token.excluded(address(rewards)));
        assertTrue(token.excluded(address(token)));
        assertFalse(token.excluded(alice), "a real holder is never excluded");
    }

    /// @dev The custodian is the only caller the token's reward surface accepts. Anyone else - including
    /// the launcher and the locker - gets nothing.
    function test_tokenRewardSurfaceIsRewardsOnly() public {
        address[3] memory callers = [alice, address(launcher), address(locker)];
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

    function test_onlyLockerCanNotify() public {
        vm.expectRevert(ArchemistHolderRewards.NotLocker.selector);
        rewards.notify(address(token), address(0), 1 ether);
    }

    function test_notifyRejectsAnAssetThatIsNotThePoolQuote() public {
        _give(alice, 100 ether);
        vm.prank(address(locker));
        vm.expectRevert(ArchemistHolderRewards.AssetMismatch.selector);
        rewards.notify(address(token), address(0xBEEF), 1 ether);
    }

    // --- Pro-rata distribution ---------------------------------------------------------------------

    function test_rewardsSplitInProportionToBalances() public {
        _give(alice, 100 ether);
        _give(bob, 300 ether);

        _notify(4 ether);

        assertApproxEqAbs(rewards.earned(address(token), alice), 1 ether, 1, "alice holds a quarter of the float");
        assertApproxEqAbs(rewards.earned(address(token), bob), 3 ether, 1, "bob holds three quarters");
    }

    function test_aHolderWithAMinusculeShareStillAccrues() public {
        // 1 part in 10 million. A per-distribution truncation would round this to nothing every time.
        _give(alice, 1e7 ether);
        _give(bob, 1 ether);

        for (uint256 i; i < 10; ++i) {
            _notify(1 ether);
        }

        assertGt(rewards.earned(address(token), bob), 0, "small holders must not be rounded away");
        // The float is 1e7 + 1 tokens, so bob's exact share of 10 ether is 10e18/(1e7 + 1).
        assertApproxEqAbs(rewards.earned(address(token), bob), uint256(10 ether) / (1e7 + 1), 1);
    }

    function test_shareIsRelativeToFloatNotTotalSupply() public {
        // Only a sliver of the supply has been bought; the rest sits with the pool manager and must not
        // dilute the holders who actually exist.
        _give(alice, 1000 ether);
        _notify(1 ether);
        assertApproxEqAbs(rewards.earned(address(token), alice), 1 ether, 1, "sole holder of the float takes all of it");
    }

    function test_transferMovesFutureEntitlementButNotAccruedRewards() public {
        _give(alice, 100 ether);
        _notify(1 ether);
        uint256 aliceEarned = rewards.earned(address(token), alice);
        assertApproxEqAbs(aliceEarned, 1 ether, 1);

        vm.prank(alice);
        token.transfer(bob, 100 ether);

        assertEq(rewards.earned(address(token), alice), aliceEarned, "already-earned rewards stay with alice");
        assertEq(rewards.earned(address(token), bob), 0, "bob earns nothing for a period he did not hold");

        _notify(1 ether);
        assertEq(rewards.earned(address(token), alice), aliceEarned, "alice accrues nothing further");
        assertApproxEqAbs(rewards.earned(address(token), bob), 1 ether, 1, "bob accrues from now on");
    }

    function test_entitlementTracksHoldingIntervalsNotSnapshots() public {
        _give(alice, 100 ether);
        _give(bob, 100 ether);
        _notify(2 ether); // 1 each

        vm.prank(bob);
        token.transfer(alice, 100 ether); // alice now holds the whole float
        _notify(2 ether); // all to alice

        assertApproxEqAbs(rewards.earned(address(token), alice), 3 ether, 2);
        assertApproxEqAbs(rewards.earned(address(token), bob), 1 ether, 1);
    }

    // --- Nothing to distribute to ------------------------------------------------------------------

    function test_notifyIsRejectedWhenNobodyHoldsTheFloat() public {
        vm.prank(address(locker));
        assertFalse(rewards.notify(address(token), address(0), 1 ether), "no eligible supply, nothing to divide");
    }

    function test_notifyIsRejectedForZeroAmount() public {
        _give(alice, 100 ether);
        vm.prank(address(locker));
        assertFalse(rewards.notify(address(token), address(0), 0));
    }

    /// The whole point of returning false instead of reverting: this call happens inside a trader's
    /// swap, so it must always have a defined, cheap outcome.
    function test_notifyNeverRevertsOnAnAbsurdAmount() public {
        _give(alice, 100 ether);
        vm.prank(address(locker));
        assertFalse(rewards.notify(address(token), address(0), type(uint256).max));
    }

    // --- Claiming ----------------------------------------------------------------------------------

    function test_claimPaysTheHolderAndZeroesTheEntitlement() public {
        _give(alice, 100 ether);
        _notify(1 ether);

        vm.prank(alice);
        uint256 paid = rewards.claim(address(token), alice);

        assertApproxEqAbs(paid, 1 ether, 1);
        assertEq(alice.balance, paid);
        assertEq(rewards.earned(address(token), alice), 0);
    }

    function test_claimRevertsWhenThereIsNothingToClaim() public {
        vm.prank(alice);
        vm.expectRevert(ArchemistHolderRewards.NothingToClaim.selector);
        rewards.claim(address(token), alice);
    }

    function test_excludedAddressesCanNeverClaim() public {
        _give(alice, 100 ether);
        _notify(1 ether);

        vm.prank(POOL_MANAGER);
        vm.expectRevert(ArchemistHolderRewards.NothingToClaim.selector);
        rewards.claim(address(token), POOL_MANAGER);
    }

    function test_claimWorksForASixDecimalQuote() public {
        MockRewardQuote quote = new MockRewardQuote();
        ArchemistV4Token erc20Token = launcher.deployToken("Quote Token", "QT", address(quote));
        launcher.send(erc20Token, alice, 100 ether);
        launcher.send(erc20Token, bob, 300 ether);

        quote.mint(address(locker), 4_000_000);
        locker.creditToken(address(rewards), address(quote), 4_000_000);
        vm.prank(address(locker));
        assertTrue(rewards.notify(address(erc20Token), address(quote), 4_000_000));

        vm.prank(alice);
        rewards.claim(address(erc20Token), alice);
        vm.prank(bob);
        rewards.claim(address(erc20Token), bob);

        assertApproxEqAbs(quote.balanceOf(alice), 1_000_000, 1);
        assertApproxEqAbs(quote.balanceOf(bob), 3_000_000, 1);
    }

    // --- The push path ------------------------------------------------------------------------------

    function test_claimForPushesToEveryHolderWithoutThemActing() public {
        _give(alice, 100 ether);
        _give(bob, 300 ether);
        _notify(4 ether);

        address[] memory holders = new address[](2);
        holders[0] = alice;
        holders[1] = bob;
        uint256 paid = rewards.claimFor(address(token), holders);

        assertApproxEqAbs(paid, 4 ether, 2);
        assertApproxEqAbs(alice.balance, 1 ether, 1);
        assertApproxEqAbs(bob.balance, 3 ether, 1);
        assertEq(alice.balance + bob.balance, paid);
    }

    function test_oneUnreachableHolderNeverBlocksTheRest() public {
        RejectingHolder rejecting = new RejectingHolder();
        _give(address(rejecting), 100 ether);
        _give(alice, 100 ether);
        _notify(2 ether);

        address[] memory holders = new address[](2);
        holders[0] = address(rejecting);
        holders[1] = alice;
        uint256 paid = rewards.claimFor(address(token), holders);

        assertApproxEqAbs(paid, 1 ether, 1, "only the reachable holder was paid");
        assertEq(alice.balance, paid);
        assertApproxEqAbs(
            rewards.earned(address(token), address(rejecting)), 1 ether, 1, "the refused payout stays owed, not lost"
        );
    }

    function test_claimForSkipsExcludedAddressesAndEmptyEntitlements() public {
        _give(alice, 100 ether);
        _notify(1 ether);

        address[] memory holders = new address[](3);
        holders[0] = POOL_MANAGER;
        holders[1] = carol; // never held anything
        holders[2] = alice;
        assertApproxEqAbs(rewards.claimFor(address(token), holders), 1 ether, 1);
    }

    /// Documents an accepted limitation rather than preventing it: a contract that holds the token
    /// accrues a share like anyone else, and it is on that contract to be able to collect it.
    function test_aThirdPartyContractHolderAccruesLikeAnyoneElse() public {
        PassiveHolder pool = new PassiveHolder();
        _give(address(pool), 100 ether);
        _give(alice, 100 ether);
        _notify(2 ether);

        assertApproxEqAbs(rewards.earned(address(token), address(pool)), 1 ether, 1);
        address[] memory holders = new address[](1);
        holders[0] = address(pool);
        assertApproxEqAbs(rewards.claimFor(address(token), holders), 1 ether, 1);
    }

    // --- Eligible supply bookkeeping ----------------------------------------------------------------

    function test_eligibleSupplyTracksTheFloatAcrossEveryMovement() public {
        _give(alice, 100 ether);
        _assertEligibleSupplyMatchesBalances();

        vm.prank(alice);
        token.transfer(bob, 40 ether);
        _assertEligibleSupplyMatchesBalances();

        // Back into an excluded address: the float shrinks, exactly as a sell into the pool would.
        vm.prank(bob);
        token.transfer(POOL_MANAGER, 40 ether);
        _assertEligibleSupplyMatchesBalances();
    }

    function test_selfTransferLeavesAccountingUntouched() public {
        _give(alice, 100 ether);
        _notify(1 ether);

        vm.prank(alice);
        token.transfer(alice, 50 ether);

        _assertEligibleSupplyMatchesBalances();
        assertApproxEqAbs(rewards.earned(address(token), alice), 1 ether, 1);
        assertEq(token.balanceOf(alice), 100 ether);
    }

    function testFuzz_eligibleSupplyAndEntitlementsStayConsistent(uint96[8] memory moves, uint96[4] memory fees)
        public
    {
        address[3] memory holders = [alice, bob, carol];
        _give(alice, 1_000 ether);

        for (uint256 i; i < moves.length; ++i) {
            address from = holders[i % 3];
            address to = holders[(i + 1) % 3];
            uint256 balance = token.balanceOf(from);
            if (balance != 0) {
                vm.prank(from);
                token.transfer(to, 1 + uint256(moves[i]) % balance);
            }
            if (i < fees.length && uint256(fees[i]) != 0) {
                _notify(uint256(fees[i]));
            }
            _assertEligibleSupplyMatchesBalances();
        }

        uint256 owed;
        for (uint256 i; i < 3; ++i) {
            owed += rewards.earned(address(token), holders[i]);
        }
        assertLe(owed, address(rewards).balance + locker.claimable(address(rewards), address(0)));
    }

    // --- Helpers ------------------------------------------------------------------------------------

    function _give(address to, uint256 amount) private {
        launcher.send(token, to, amount);
    }

    function _notify(uint256 amount) private {
        vm.deal(address(this), address(this).balance + amount);
        locker.creditNative{ value: amount }(address(rewards));
        vm.prank(address(locker));
        rewards.notify(address(token), address(0), amount);
    }

    function _assertEligibleSupplyMatchesBalances() private view {
        (,, uint256 eligibleSupply,) = rewards.getTokenState(address(token));
        uint256 excludedHeld = token.balanceOf(POOL_MANAGER) + token.balanceOf(address(locker))
            + token.balanceOf(address(launcher)) + token.balanceOf(address(rewards)) + token.balanceOf(address(token));
        assertEq(eligibleSupply, token.totalSupply() - excludedHeld);
    }
}
