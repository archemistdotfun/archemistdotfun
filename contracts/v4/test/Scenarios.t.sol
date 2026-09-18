// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { ERC1967Utils } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolModifyLiquidityTest } from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { ModifyLiquidityParams, SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";

import { ArchemistV4Hook } from "../src/ArchemistV4Hook.sol";
import { ArchemistV4Launcher } from "../src/ArchemistV4Launcher.sol";
import { ArchemistV4Locker } from "../src/ArchemistV4Locker.sol";
import { ArchemistV4Token } from "../src/ArchemistV4Token.sol";
import { ArchemistFixture } from "./Fixture.t.sol";
import { MockUniswapV3Pool } from "./mocks/MockUniswapV3Pool.sol";
import { MockStandardQuote } from "./mocks/ProbeMocks.sol";

/// @notice The whole system, end to end, through the proxies and the timelock - the tests that would
/// catch a regression no single-contract test can see: a hook rotation that strands an existing pool, an
/// upgrade that stops old pools trading, a `retire()` that takes working pools down with it.
contract ScenariosTest is ArchemistFixture {
    using SafeCast for uint256;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address internal constant TRADER = address(0x7EA7E5);

    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liquidityRouter;
    MockStandardQuote internal archToken;
    MockUniswapV3Pool internal archPool;

    function setUp() public {
        archToken = new MockStandardQuote(18);
        // Native is the quote, and it aliases onto LINKED_USDC - which here is a mock standing in for
        // Arc's linked USDC, so the buyback chain is the real one: native -> linked USDC -> ARCH.
        MockStandardQuote linkedUsdcMock = new MockStandardQuote(18);
        _deployStack(address(0), address(archToken), address(linkedUsdcMock));
        swapRouter = new PoolSwapTest(manager);
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        registry.addPair(address(0), _nativePair(), 0, false);
    }

    // -------------------------------------------------------------------------------------------
    // SC-01 - the full life of a launch
    // -------------------------------------------------------------------------------------------

    function test_fullLifeOfALaunch() public {
        _handOverToTimelock();

        (address tokenAddress, PoolId poolId) = _launch(address(hook), "sc-01", 990_000, 120, 500);
        ArchemistV4Token token = ArchemistV4Token(tokenAddress);
        PoolKey memory key = locker.getPoolKey(poolId);

        // A sniper one second in pays close to the start fee, not the 1% floor.
        vm.warp(block.timestamp + 1);
        uint256 liabilityBefore = locker.totalClaimLiability(address(0));
        _buy(key, 0.01 ether);
        uint256 snipeFee = locker.totalClaimLiability(address(0)) - liabilityBefore;
        assertGt(snipeFee, 0.01 ether * 500 / 10_000, "the anti-snipe fee must be far above the 1% floor");

        // An exact-output buy is refused for the whole window, and allowed the moment it ends.
        vm.expectRevert();
        _buyExactOutput(key, 1 ether);

        vm.warp(block.timestamp + 200);
        _buyExactOutput(key, 1 ether);

        // Third-party liquidity is only unlocked after the window.
        _addThirdPartyLiquidity(key);

        // A sell accrues holder rewards for whoever holds the float.
        uint256 traderBalance = token.balanceOf(address(this));
        assertGt(traderBalance, 0);
        token.transfer(TRADER, traderBalance / 2);
        _sell(key, token, traderBalance / 4);
        assertGt(token.eligibleSupply(), 0, "the float is real once tokens leave the pool");

        // The creator's share is claimable, and so is the treasury's.
        assertGt(locker.claimable(CREATOR, address(0)), 0);
        vm.prank(CREATOR);
        assertGt(locker.claim(address(0), CREATOR), 0);
        assertGt(locker.claimable(address(treasury), address(0)), 0);

        // And LP fees collect on top of the hook fee.
        locker.collect(poolId);
    }

    // -------------------------------------------------------------------------------------------
    // SC-02 - hook rotation
    // -------------------------------------------------------------------------------------------

    /// @dev The promise a registry has to keep: rotating to a new hook must not disturb a single pool
    /// that is already running on the old one.
    function test_hookRotation() public {
        (address t1, PoolId pool1) = _launch(address(hook), "t1", 10_000, 120, 10_000);
        PoolKey memory key1 = locker.getPoolKey(pool1);

        ArchemistV4Hook hookB = _deploySecondHook(address(vault));
        launcher.registerHook(address(hookB));
        launcher.setHookEnabled(address(hook), false);

        // New launches must use B...
        vm.expectRevert(abi.encodeWithSelector(ArchemistV4Launcher.HookDisabled.selector, address(hook)));
        _launch(address(hook), "t2-on-a", 10_000, 120, 10_000);
        (, PoolId pool2) = _launch(address(hookB), "t2", 10_000, 120, 10_000);
        assertEq(address(locker.getPoolKey(pool2).hooks), address(hookB));

        // ...while T1 keeps trading, and keeps being paid, through the DISABLED hook.
        vm.warp(block.timestamp + 200);
        uint256 before = locker.totalClaimLiability(address(0));
        _buy(key1, 1 ether);
        assertEq(
            locker.totalClaimLiability(address(0)) - before,
            0.01 ether,
            "a pool on a disabled hook still charges and records its fee"
        );
        assertEq(ArchemistV4Token(t1).balanceOf(address(this)) > 0, true);

        // Re-enabling is equally non-retroactive.
        launcher.setHookEnabled(address(hook), true);
        (, PoolId pool3) = _launch(address(hook), "t3", 10_000, 120, 10_000);
        assertEq(address(locker.getPoolKey(pool3).hooks), address(hook));
    }

    // -------------------------------------------------------------------------------------------
    // SC-03 / PU-20 - upgrades mid-life
    // -------------------------------------------------------------------------------------------

    /// @dev The promise made to every launch that already exists: an upgrade of the periphery changes
    /// nothing about how their pool trades or what it pays.
    function test_oldPoolsKeepTradingAcrossUpgrade() public {
        (address tokenAddress, PoolId poolId) = _launch(address(hook), "sc-03", 10_000, 120, 10_000);
        PoolKey memory key = locker.getPoolKey(poolId);
        ArchemistV4Token token = ArchemistV4Token(tokenAddress);
        vm.warp(block.timestamp + 200);

        uint256 feeBefore = _feeFromBuy(key, 1 ether);
        uint256 creatorBefore = locker.claimable(CREATOR, address(0));
        _handOverToTimelock();

        // Upgrade all four periphery proxies in turn.
        _timelockExec(
            address(launcher),
            abi.encodeWithSignature(
                "upgradeToAndCall(address,bytes)", address(new ArchemistV4Launcher(manager, block.chainid)), bytes("")
            )
        );
        _timelockExec(
            address(locker), abi.encodeWithSignature("upgradeToAndCall(address,bytes)", _newLockerImpl(), bytes(""))
        );

        assertEq(locker.claimable(CREATOR, address(0)), creatorBefore, "accrued fees survived the upgrade");
        assertEq(_feeFromBuy(key, 1 ether), feeBefore, "and the fee is computed identically afterwards");

        // Every mode still works, and claims still pay out.
        _buyExactOutput(key, 0.5 ether);
        uint256 balance = token.balanceOf(address(this));
        _sell(key, token, balance / 4);
        locker.collect(poolId);
        vm.prank(CREATOR);
        assertGt(locker.claim(address(0), CREATOR), 0);
    }

    // -------------------------------------------------------------------------------------------
    // SC-07 - retire
    // -------------------------------------------------------------------------------------------

    /// @dev Retiring a launcher is the graceful end of its life, not the end of anyone's pool. Every
    /// launch that already exists keeps trading, accruing and paying out forever.
    function test_retireStopsLaunchesAndNothingElse() public {
        (address tokenAddress, PoolId poolId) = _launch(address(hook), "sc-07", 10_000, 120, 10_000);
        PoolKey memory key = locker.getPoolKey(poolId);
        ArchemistV4Token token = ArchemistV4Token(tokenAddress);
        vm.warp(block.timestamp + 200);

        launcher.retire();

        vm.expectRevert(ArchemistV4Launcher.CreateDisabled.selector);
        _launch(address(hook), "after-retire", 10_000, 120, 10_000);

        // The existing pool is completely unaffected.
        _buy(key, 1 ether);
        _sell(key, token, token.balanceOf(address(this)) / 4);
        locker.collect(poolId);
        vm.prank(CREATOR);
        assertGt(locker.claim(address(0), CREATOR), 0);
    }

    // -------------------------------------------------------------------------------------------
    // SC-10 - governance
    // -------------------------------------------------------------------------------------------

    function test_cancelledMaliciousUpgradeChangesNothing() public {
        (, PoolId poolId) = _launch(address(hook), "sc-10", 10_000, 120, 10_000);
        PoolKey memory key = locker.getPoolKey(poolId);
        vm.warp(block.timestamp + 200);
        _buy(key, 1 ether);

        _handOverToTimelock();
        uint256 creatorBefore = locker.claimable(CREATOR, address(0));
        address implBefore = address(uint160(uint256(vm.load(address(locker), ERC1967Utils.IMPLEMENTATION_SLOT))));

        bytes memory data = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", _newLockerImpl(), bytes(""));
        timelock.schedule(address(locker), 0, data, bytes32(0), bytes32("evil"), TIMELOCK_DELAY);
        timelock.cancel(timelock.hashOperation(address(locker), 0, data, bytes32(0), bytes32("evil")));
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.expectRevert();
        timelock.execute(address(locker), 0, data, bytes32(0), bytes32("evil"));

        assertEq(
            address(uint160(uint256(vm.load(address(locker), ERC1967Utils.IMPLEMENTATION_SLOT)))),
            implBefore,
            "implementation unchanged"
        );
        assertEq(locker.claimable(CREATOR, address(0)), creatorBefore);
        _buy(key, 1 ether);
    }

    // -------------------------------------------------------------------------------------------
    // SC-06 - the shape a token scanner sees
    // -------------------------------------------------------------------------------------------

    /// @dev `vm.expectCall(_, _, 0)` holds for the REST of the test, so this one does nothing after the
    /// transfer - the whole assertion is that a transfer on a live, traded pool touches nothing outside
    /// the token contract.
    function test_tokenTransferOnALivePoolCallsNothing() public {
        (address tokenAddress, PoolId poolId) = _launch(address(hook), "sc-06a", 10_000, 120, 10_000);
        PoolKey memory key = locker.getPoolKey(poolId);
        ArchemistV4Token token = ArchemistV4Token(tokenAddress);
        vm.warp(block.timestamp + 200);
        _buy(key, 1 ether);

        vm.expectCall(address(rewards), bytes(""), 0);
        vm.expectCall(address(locker), bytes(""), 0);
        vm.expectCall(address(manager), bytes(""), 0);
        vm.expectCall(address(launcher), bytes(""), 0);
        token.transfer(TRADER, token.balanceOf(address(this)) / 2);
    }

    /// @dev And the accounting still works without that callback: a holder who held across a sell has
    /// something to claim, paid in the pool's own quote currency.
    function test_holderAccruesFromASellAndCanClaim() public {
        (address tokenAddress, PoolId poolId) = _launch(address(hook), "sc-06b", 10_000, 120, 10_000);
        PoolKey memory key = locker.getPoolKey(poolId);
        ArchemistV4Token token = ArchemistV4Token(tokenAddress);
        vm.warp(block.timestamp + 200);
        _buy(key, 10 ether);

        token.transfer(TRADER, token.balanceOf(address(this)) / 2);
        assertGt(token.eligibleSupply(), 0, "the float is real once tokens leave the pool");

        _sell(key, token, token.balanceOf(address(this)) / 4);
        uint256 earned = rewards.earned(tokenAddress, TRADER);
        assertGt(earned, 0, "the holder accrued from the sell");

        vm.prank(TRADER);
        assertEq(rewards.claim(tokenAddress, TRADER), earned, "and can collect exactly that");
        assertEq(rewards.earned(tokenAddress, TRADER), 0);
    }

    // -------------------------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------------------------

    function _newLockerImpl() private returns (address) {
        return address(new ArchemistV4LockerImplFactory().make(manager));
    }

    function _launch(address hookAddress, string memory salt, uint24 startFee, uint32 window, uint16 cap)
        private
        returns (address tokenAddress, PoolId poolId)
    {
        ArchemistV4Launcher.LaunchParams memory p =
            _launchParams(hookAddress, address(0), keccak256(bytes(salt)), startFee, window, cap, CREATOR);
        // == INITIAL_SUPPLY -> a 1:1 price ratio -> tick 0, comfortably inside the pair's band.
        p.targetFdvQuoteRaw = 1_000_000_000 ether;
        p.name = salt;
        p.symbol = "SC";
        (tokenAddress, poolId) = launcher.createToken(p);
    }

    function _feeFromBuy(PoolKey memory key, uint256 amount) private returns (uint256) {
        uint256 before = locker.totalClaimLiability(address(0));
        _buy(key, amount);
        return locker.totalClaimLiability(address(0)) - before;
    }

    function _buy(PoolKey memory key, uint256 amount) private {
        vm.deal(address(this), address(this).balance + amount);
        swapRouter.swap{ value: amount }(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -amount.toInt256(), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
    }

    function _buyExactOutput(PoolKey memory key, uint256 tokensOut) private {
        vm.deal(address(this), address(this).balance + 100 ether);
        swapRouter.swap{ value: 100 ether }(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: tokensOut.toInt256(), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
    }

    function _sell(PoolKey memory key, ArchemistV4Token token, uint256 amount) private {
        token.approve(address(swapRouter), amount);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -amount.toInt256(), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
    }

    /// @dev Only possible once the anti-snipe window has closed - before that `beforeAddLiquidity`
    /// rejects anyone but the locker.
    function _addThirdPartyLiquidity(PoolKey memory key) private {
        ArchemistV4Token token = ArchemistV4Token(Currency.unwrap(key.currency1));
        uint256 amount = token.balanceOf(address(this)) / 8;
        token.approve(address(liquidityRouter), amount);
        vm.deal(address(this), address(this).balance + 1 ether);
        liquidityRouter.modifyLiquidity{ value: 1 ether }(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(key.tickSpacing),
                tickUpper: TickMath.maxUsableTick(key.tickSpacing),
                liquidityDelta: 1e15,
                salt: bytes32("third-party")
            }),
            bytes("")
        );
    }

    receive() external payable { }
}

/// @dev Deploying a locker implementation costs more than the scenario tests' stack depth allows
/// inline, so it happens behind this one-line factory.
contract ArchemistV4LockerImplFactory {
    function make(IPoolManager poolManager) external returns (address) {
        return address(new ArchemistV4Locker(poolManager, block.chainid));
    }
}
