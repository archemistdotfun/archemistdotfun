// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { PoolManager } from "@uniswap/v4-core/src/PoolManager.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { HookMiner } from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import { ArchemistHolderRewards } from "../src/ArchemistHolderRewards.sol";
import { ArchemistPairRegistry } from "../src/ArchemistPairRegistry.sol";
import { ArchemistV4Hook } from "../src/ArchemistV4Hook.sol";
import { ArchemistV4Launcher } from "../src/ArchemistV4Launcher.sol";
import { ArchemistV4Locker } from "../src/ArchemistV4Locker.sol";
import { ArchemistV4Token } from "../src/ArchemistV4Token.sol";
import { AntiSnipeParams, FeeRecipient, PairConfig } from "../src/ArchemistV4Types.sol";
import { ArchemistDeploy } from "./Deploy.sol";
import { MockAllowlistToken, MockPausableToken, MockReentrantQuote, MockStandardQuote } from "./mocks/ProbeMocks.sol";

contract ProblemTokenReceiver {
    receive() external payable { }
}

/// @dev TOK-08/TOK-09-style coverage: quote tokens that misbehave
/// AFTER a pool is already live and trading, not at registration/probe time. Also covers malicious-ERC20
/// reentrancy against the locker and decimals-agnostic fee-split accounting, per the security-hardening
/// items called out for stage 4.
contract ArchemistV4ProblemTokensTest is Test {
    using SafeCast for uint256;

    uint160 internal constant REQUIRED_FLAGS = 0x28CC;
    int24 internal constant SPACING = 60;

    IPoolManager internal manager;
    PoolSwapTest internal router;
    ArchemistPairRegistry internal registry;
    ArchemistV4Launcher internal launcher;
    ArchemistV4Locker internal locker;
    ArchemistHolderRewards internal holderRewards;
    ArchemistV4Hook internal hook;
    ProblemTokenReceiver internal treasury;
    ProblemTokenReceiver internal buyback;

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        router = new PoolSwapTest(manager);
        treasury = new ProblemTokenReceiver();
        buyback = new ProblemTokenReceiver();
    }

    // ---------------------------------------------------------------------
    // TOK-08: token paused AFTER the pool is already live and has traded.
    // ---------------------------------------------------------------------
    function test_AcceptedRisk_PausedQuoteFreezesPoolButPreservesPending() public {
        MockPausableToken quote = new MockPausableToken(6);
        (address token,, PoolKey memory key) = _launchWithQuote(address(quote), address(this), 5_000e6);

        // 10 swaps succeed while the token is not yet paused, generating real, claimable fee credit.
        for (uint256 i; i < 10; ++i) {
            _buyExactInput(address(quote), key, 1e6);
        }
        uint256 pendingBefore = locker.claimable(address(this), address(quote));
        assertGt(pendingBefore, 0);

        // Pre-fund/approve/mint everything needed for the reverting attempts BEFORE pausing and BEFORE
        // arming vm.expectRevert() - it only ever applies to the single next call, so any setup call
        // (mint/approve) must happen outside its scope.
        quote.mint(address(this), 1e6);
        quote.approve(address(router), type(uint256).max);
        ArchemistV4Token(token).approve(address(router), type(uint256).max);
        bool buyZeroForOne = Currency.unwrap(key.currency0) == address(quote);

        quote.setPaused(true);

        // BUY reverts: the quote leg of the swap can't settle into the pool.
        vm.expectRevert();
        _swapExactInput(address(quote), key, 1e6);

        // SELL reverts too: the quote leg can't be taken out of the pool either.
        vm.expectRevert();
        router.swap(
            key,
            SwapParams({
                zeroForOne: !buyZeroForOne,
                amountSpecified: -1e18,
                sqrtPriceLimitX96: !buyZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );

        // claim() for the paused asset reverts, but the pending balance is NOT lost - the whole claim
        // transaction rolled back, so it's exactly what it was before the attempt.
        vm.expectRevert();
        locker.claim(address(quote), address(this));
        assertEq(locker.claimable(address(this), address(quote)), pendingBefore, "pending must survive a failed claim");

        // Unpausing restores every path. This swap adds its own fresh fee credit on top of the
        // pre-pause pending amount, so the claim below must pay out both combined, not just
        // pendingBefore - that combined total is exactly what "claimable in full, nothing lost" means.
        quote.setPaused(false);
        _swapExactInput(address(quote), key, 1e6);
        uint256 totalPending = locker.claimable(address(this), address(quote));
        assertGe(totalPending, pendingBefore, "pre-pause pending must still be included");
        uint256 before = quote.balanceOf(address(this));
        locker.claim(address(quote), address(this));
        assertEq(quote.balanceOf(address(this)) - before, totalPending);
        assertEq(locker.claimable(address(this), address(quote)), 0);
    }

    // ---------------------------------------------------------------------
    // TOK-09: quote issuer de-allowlists the locker AFTER the pool is live.
    // ---------------------------------------------------------------------
    function test_AcceptedRisk_DeallowlistedLockerBlocksThatAssetOnly() public {
        MockAllowlistToken quote = new MockAllowlistToken(6);
        // Nothing needs allowlisting yet: launching doesn't move any quote (no creator buy in these
        // params), so the real router/manager/locker addresses only exist - and only need allowlisting
        // - once _launchWithQuote returns them below.
        (,, PoolKey memory key) = _launchWithQuote(address(quote), address(this), 5_000e6);
        quote.setAllowed(address(this), true);
        quote.setAllowed(address(router), true);
        quote.setAllowed(address(manager), true);
        quote.setAllowed(address(locker), true);
        quote.setAllowed(address(treasury), true);
        quote.setAllowed(address(buyback), true);
        _buyExactInput(address(quote), key, 1e6);
        uint256 pendingBefore = locker.claimable(address(this), address(quote));
        assertGt(pendingBefore, 0);

        // Issuer pulls the locker's own allowlist status - PoolManager (and everyone else) stays
        // allowlisted, so ordinary trading is unaffected.
        quote.setAllowed(address(locker), false);

        // Swaps still succeed: the AMM leg settles with PoolManager, which is still allowlisted.
        _buyExactInput(address(quote), key, 1e6);

        // But redeeming the ERC-6909-backed credit requires PoolManager to pay the real token OUT to
        // the locker first, and that now reverts.
        vm.expectRevert();
        locker.claim(address(quote), address(this));
        assertGe(locker.claimable(address(this), address(quote)), pendingBefore, "pending must survive a failed claim");

        // Re-allowlisting the locker immediately restores the claim path, full amount intact.
        quote.setAllowed(address(locker), true);
        uint256 pendingAfter = locker.claimable(address(this), address(quote));
        uint256 before = quote.balanceOf(address(this));
        locker.claim(address(quote), address(this));
        assertEq(quote.balanceOf(address(this)) - before, pendingAfter);
    }

    // ---------------------------------------------------------------------
    // Malicious ERC-20: quote token tries to re-enter the locker mid-payout.
    // ---------------------------------------------------------------------
    function test_MaliciousQuote_ReentrantClaimIsBlockedByTheSharedLock() public {
        MockReentrantQuote quote = new MockReentrantQuote(6);
        (,, PoolKey memory key) = _launchWithQuote(address(quote), address(this), 5_000e6);
        _buyExactInput(address(quote), key, 1e6);
        uint256 pending = locker.claimable(address(this), address(quote));
        assertGt(pending, 0);

        // On the outbound leg of claim()'s own transfer, the token tries to re-enter claim() again for
        // the same beneficiary - a naive double-spend attempt. The reentrant call does revert with
        // Reentrancy() (confirmed via trace), but it happens inside PoolManager.take -> token.transfer,
        // and PoolManager wraps nested-call reverts in its own WrappedError before it reaches us here -
        // so this only asserts *some* revert, not the exact selector, matching the real error shape.
        quote.armReentrantClaim(address(locker), address(quote), address(this));
        vm.expectRevert();
        locker.claim(address(quote), address(this));

        // The whole attempted claim reverted (Solidity reverts unwind all state changes in the call),
        // so nothing was lost or double-paid - the pending amount is exactly what it was before.
        assertEq(
            locker.claimable(address(this), address(quote)), pending, "pending must survive the blocked reentrancy"
        );
    }

    // ---------------------------------------------------------------------
    // Decimals-agnostic fee accounting (ORD-06-style, applied to real swaps not just tick math).
    // ---------------------------------------------------------------------
    function testFuzz_feeSplitConservesAcrossQuoteDecimals(uint8 decimalsSeed, uint96 amountSeed) public {
        // Registry.MIN/MAX_QUOTE_DECIMALS is [6, 18] (a deliberate policy call, not this library's own
        // constraint), so 24 isn't a registrable quote decimals
        // value and doesn't belong in this set.
        uint8[3] memory decimalsSet = [uint8(6), uint8(8), uint8(18)];
        uint8 decimals = decimalsSet[decimalsSeed % 3];
        uint256 amount = bound(uint256(amountSeed), 10 ** decimals, 1_000 * 10 ** decimals);

        MockStandardQuote quote = new MockStandardQuote(decimals);
        (address launchToken,, PoolKey memory key) =
            _launchWithQuote(address(quote), address(this), 5_000 * 10 ** decimals);
        quote.mint(address(this), amount);
        quote.approve(address(router), type(uint256).max);

        uint256 beforeLiability = locker.totalClaimLiability(address(quote));
        router.swap(
            key,
            SwapParams({
                zeroForOne: Currency.unwrap(key.currency0) == address(quote),
                amountSpecified: -amount.toInt256(),
                sqrtPriceLimitX96: Currency.unwrap(key.currency0) == address(quote)
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
        uint256 feeCredited = locker.totalClaimLiability(address(quote)) - beforeLiability;
        assertGt(feeCredited, 0);

        uint256 buybackAfterBuy = locker.erc6909Claimable(address(buyback), address(quote));
        assertApproxEqAbs(buybackAfterBuy, feeCredited * 1_250 / 10_000, 1, "a buy fills the buyback bucket");
        assertEq(locker.erc6909Claimable(address(holderRewards), address(quote)), 0, "and leaves holders untouched");

        // Now the other direction, which must split identically except for where the 12.5% lands.
        uint256 sellAmount = ArchemistV4Token(launchToken).balanceOf(address(this)) / 2;
        ArchemistV4Token(launchToken).approve(address(router), type(uint256).max);
        router.swap(
            key,
            SwapParams({
                zeroForOne: Currency.unwrap(key.currency0) == launchToken,
                amountSpecified: -sellAmount.toInt256(),
                sqrtPriceLimitX96: Currency.unwrap(key.currency0) == launchToken
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
        uint256 totalFee = locker.totalClaimLiability(address(quote)) - beforeLiability;
        assertGt(totalFee, feeCredited, "the sell charged a fee too");

        uint256 creatorShare = locker.claimable(address(this), address(quote));
        uint256 buybackShare = locker.erc6909Claimable(address(buyback), address(quote));
        uint256 rewardsShare = locker.erc6909Claimable(address(holderRewards), address(quote));
        uint256 treasuryShare = locker.claimable(address(treasury), address(quote));

        // 70 / 12.5 / 17.5 conservation must hold exactly regardless of the quote's decimals, since the
        // split operates on raw units throughout - decimals never enter the arithmetic. The 12.5% is
        // now split across two buckets by direction, but its total size is unchanged.
        assertEq(
            creatorShare + buybackShare + rewardsShare + treasuryShare,
            totalFee,
            "70/12.5/17.5 must conserve the raw fee"
        );
        assertApproxEqAbs(creatorShare, totalFee * 7_000 / 10_000, 2);
        assertApproxEqAbs(buybackShare + rewardsShare, totalFee * 1_250 / 10_000, 2);
        assertEq(buybackShare, buybackAfterBuy, "the sell must not add to the buyback bucket");
        assertGt(rewardsShare, 0, "the sell must have funded holder rewards");
    }

    // ---------------------------------------------------------------------
    // Shared setup: deploy a fresh stack for `quote` and launch one token against it.
    // ---------------------------------------------------------------------
    function _launchWithQuote(address quote, address creator, uint256 targetFdvQuoteRaw)
        private
        returns (address token, PoolId poolId, PoolKey memory key)
    {
        registry = ArchemistDeploy.registry(address(this), address(0));
        registry.addPair(
            quote,
            PairConfig({
                enabled: true,
                decimals: _decimalsOf(quote),
                defaultTick: 0,
                minTick: -600_000,
                maxTick: 600_000,
                tickSpacing: SPACING,
                flags: 0,
                buybackRoute: address(0),
                buybackRouteIsV4: false,
                buybackRouteFee: 0,
                buybackRouteTickSpacing: 0,
                minCreatorBps: 5_000,
                maxCreatorBps: 8_000
            }),
            0,
            true // skipProbe: these are our own mocks under full control, no need to self-probe.
        );

        launcher = ArchemistDeploy.launcher(manager, address(this), address(registry), address(treasury), 0);
        locker = ArchemistDeploy.locker(manager, address(this), address(launcher));
        holderRewards = ArchemistDeploy.rewards(address(this), address(launcher), address(locker));
        bytes memory constructorArgs = abi.encode(manager, address(launcher), address(locker), address(buyback));
        (address expectedHook, bytes32 salt) =
            HookMiner.find(address(this), REQUIRED_FLAGS, type(ArchemistV4Hook).creationCode, constructorArgs);
        hook = new ArchemistV4Hook{ salt: salt }(manager, address(launcher), address(locker), address(buyback));
        assertEq(address(hook), expectedHook);
        launcher.configureSystemOnce(address(locker), address(buyback), address(holderRewards));
        launcher.registerHook(address(hook));
        launcher.enableCreate();

        FeeRecipient[] memory recipients = new FeeRecipient[](1);
        recipients[0] = FeeRecipient({ admin: creator, payout: creator, bps: 10_000 });
        ArchemistV4Launcher.LaunchParams memory params = ArchemistV4Launcher.LaunchParams({
            name: "Problem Token Pair",
            symbol: "PROB",
            salt: keccak256(abi.encode(quote, block.timestamp)),
            quote: quote,
            targetFdvQuoteRaw: targetFdvQuoteRaw,
            hook: address(hook),
            hookParams: abi.encode(AntiSnipeParams({ startHookFee: 10_000, windowSeconds: 120, maxBuyBps: 10_000 })),
            creatorShareBps: 7_000,
            recipients: recipients,
            creatorBuyAmount: 0,
            creatorBuyMinTokensOut: 0
        });
        (token, poolId) = launcher.createToken(params);
        key = locker.getPoolKey(poolId);
    }

    function _buyExactInput(address quote, PoolKey memory key, uint256 amount) private {
        MockStandardQuote(quote).mint(address(this), amount);
        MockStandardQuote(quote).approve(address(router), type(uint256).max);
        _swapExactInput(quote, key, amount);
    }

    /// @dev Swap-only leg, no mint/approve - so a caller can pre-fund once, then wrap only the actual
    /// swap call in vm.expectRevert() (which only ever applies to the very next call).
    function _swapExactInput(address quote, PoolKey memory key, uint256 amount) private {
        bool zeroForOne = Currency.unwrap(key.currency0) == quote;
        router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -amount.toInt256(),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
    }

    function _decimalsOf(address quote) private view returns (uint8) {
        return MockStandardQuote(quote).decimals();
    }
}
