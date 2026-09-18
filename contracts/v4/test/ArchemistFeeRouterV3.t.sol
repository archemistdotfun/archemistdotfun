// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { PoolManager } from "@uniswap/v4-core/src/PoolManager.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { HookMiner } from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import { ArchemistHolderRewards } from "../src/ArchemistHolderRewards.sol";
import { ArchemistPairRegistry } from "../src/ArchemistPairRegistry.sol";
import { ArchemistV4Hook } from "../src/ArchemistV4Hook.sol";
import { ArchemistV4Launcher } from "../src/ArchemistV4Launcher.sol";
import { ArchemistV4Locker } from "../src/ArchemistV4Locker.sol";
import { ArchemistV4Token } from "../src/ArchemistV4Token.sol";
import { AntiSnipeParams, FeeRecipient, PairConfig } from "../src/ArchemistV4Types.sol";
import { ArchemistDeploy } from "./Deploy.sol";
import { MockStandardQuote, MockSwapVenue } from "./mocks/ProbeMocks.sol";

import { ArchemistFeeRouterProxy } from "./vendored/ArchemistFeeRouterProxy.sol";
import { ArchemistFeeRouterV2 } from "./vendored/ArchemistFeeRouterV2.sol";
import { ArchemistFeeRouterV3, PoolKeyFR } from "./vendored/ArchemistFeeRouterV3.sol";

contract HookFeeReceiverV3 {
    receive() external payable { }
}

/// @dev Stands in for Uniswap's v2 router: pulls tokenIn, mints tokenOut at a fixed rate.
contract MockV2Router {
    uint256 public rate; // tokenOut per 1e18 tokenIn

    constructor(uint256 rate_) {
        rate = rate_;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        MockStandardQuote(path[0]).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = (amountIn * rate) / 1e18;
        require(out >= amountOutMin, "v2 slippage");
        MockStandardQuote(path[path.length - 1]).mint(to, out);
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = out;
    }
}

/// @dev Proves ArchemistFeeRouterV3's `exactInputMulti` against a real PoolManager and real Archemist
/// hook pools, and that upgrading a V2 proxy to V3 keeps every V2 behaviour and state intact.
/// The v2/v3 venues are mocks (a real one needs deployed pools this suite has no business standing
/// up); the v4 legs are the real thing. The Arc-only native<->alias crossing cannot be reproduced
/// here (it relies on a chain precompile keeping two balances in sync) and is covered by the
/// InvalidPath rejection test plus the testnet rehearsal in the upgrade script.
contract ArchemistFeeRouterV3Test is Test {
    uint160 internal constant REQUIRED_FLAGS = 0x28CC;
    uint256 internal constant ROUTER_FEE_BPS = 100;

    IPoolManager internal manager;
    ArchemistPairRegistry internal registry;
    ArchemistV4Launcher internal launcher;
    ArchemistV4Locker internal locker;
    ArchemistHolderRewards internal holderRewards;
    ArchemistV4Hook internal hook;
    MockStandardQuote internal erc20Quote;

    address internal routerOwner = address(0xA11CE);
    address internal routerTreasury = address(0xFEE7);
    ArchemistFeeRouterV3 internal router;
    address internal v2Impl;

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        HookFeeReceiverV3 hookTreasury = new HookFeeReceiverV3();
        HookFeeReceiverV3 buyback = new HookFeeReceiverV3();
        erc20Quote = new MockStandardQuote(18);

        registry = ArchemistDeploy.registry(address(this), address(0));
        registry.addPair(
            address(0),
            PairConfig({
                enabled: true,
                decimals: 18,
                defaultTick: 0,
                minTick: -600_000,
                maxTick: 600_000,
                tickSpacing: 60,
                flags: 1,
                buybackRoute: address(0),
                buybackRouteIsV4: false,
                buybackRouteFee: 0,
                buybackRouteTickSpacing: 0,
                minCreatorBps: 5_000,
                maxCreatorBps: 8_000
            }),
            0,
            false
        );
        registry.addPair(
            address(erc20Quote),
            PairConfig({
                enabled: true,
                decimals: 18,
                defaultTick: 0,
                minTick: -600_000,
                maxTick: 600_000,
                tickSpacing: 60,
                flags: 0,
                buybackRoute: address(0),
                buybackRouteIsV4: false,
                buybackRouteFee: 0,
                buybackRouteTickSpacing: 0,
                minCreatorBps: 5_000,
                maxCreatorBps: 8_000
            }),
            0,
            true
        );

        launcher = ArchemistDeploy.launcher(manager, address(this), address(registry), address(hookTreasury), 0);
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

        // Exactly the production history: proxy born on V2, then upgraded to V3 in place.
        ArchemistFeeRouterV2 impl2 = new ArchemistFeeRouterV2();
        v2Impl = address(impl2);
        bytes memory initData =
            abi.encodeCall(ArchemistFeeRouterV2.initialize, (routerOwner, routerTreasury, address(1), ROUTER_FEE_BPS));
        ArchemistFeeRouterProxy proxy = new ArchemistFeeRouterProxy(address(impl2), initData);
        ArchemistFeeRouterV2 asV2 = ArchemistFeeRouterV2(payable(address(proxy)));
        vm.prank(routerOwner);
        asV2.initializeV2(address(manager));

        ArchemistFeeRouterV3 impl3 = new ArchemistFeeRouterV3();
        vm.prank(routerOwner);
        asV2.upgradeToAndCall(
            address(impl3), abi.encodeCall(ArchemistFeeRouterV3.initializeV3, (address(0), address(0)))
        );
        router = ArchemistFeeRouterV3(payable(address(proxy)));
    }

    function _launch(bytes32 salt, address quote) private returns (address token, PoolId poolId) {
        FeeRecipient[] memory recipients = new FeeRecipient[](1);
        recipients[0] = FeeRecipient({ admin: address(this), payout: address(this), bps: 10_000 });
        ArchemistV4Launcher.LaunchParams memory params = ArchemistV4Launcher.LaunchParams({
            name: "Router Test Token",
            symbol: "RTT",
            salt: salt,
            quote: quote,
            targetFdvQuoteRaw: 1_000_000_000 ether,
            hook: address(hook),
            hookParams: abi.encode(AntiSnipeParams({ startHookFee: 10_000, windowSeconds: 1, maxBuyBps: 10_000 })),
            creatorShareBps: 7_000,
            recipients: recipients,
            creatorBuyAmount: 0,
            creatorBuyMinTokensOut: 0
        });
        (token, poolId) = launcher.createToken(params);
        vm.warp(block.timestamp + 2); // past the anti-snipe window -> flat 1% hook fee
    }

    function _toFR(PoolKey memory key) private pure returns (PoolKeyFR memory) {
        return PoolKeyFR({
            currency0: Currency.unwrap(key.currency0),
            currency1: Currency.unwrap(key.currency1),
            fee: key.fee,
            tickSpacing: key.tickSpacing,
            hooks: address(key.hooks)
        });
    }

    function _v4Leg(PoolId poolId, address tokenIn, address tokenOut)
        private
        view
        returns (ArchemistFeeRouterV3.Leg memory)
    {
        return ArchemistFeeRouterV3.Leg({
            kind: 2, tokenIn: tokenIn, tokenOut: tokenOut, fee: 0, key: _toFR(locker.getPoolKey(poolId))
        });
    }

    function _v3Leg(address tokenIn, address tokenOut) private pure returns (ArchemistFeeRouterV3.Leg memory) {
        return ArchemistFeeRouterV3.Leg({
            kind: 1,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: 10_000,
            key: PoolKeyFR({ currency0: address(0), currency1: address(0), fee: 0, tickSpacing: 0, hooks: address(0) })
        });
    }

    function _v2Leg(address tokenIn, address tokenOut) private pure returns (ArchemistFeeRouterV3.Leg memory) {
        ArchemistFeeRouterV3.Leg memory leg = _v3Leg(tokenIn, tokenOut);
        leg.kind = 0;
        return leg;
    }

    // ---- upgrade safety ----

    function test_upgradePreservesV2StateAndAddsV3() public view {
        assertEq(router.owner(), routerOwner);
        assertEq(router.treasury(), routerTreasury);
        assertEq(router.feeBps(), ROUTER_FEE_BPS);
        assertEq(router.poolManager(), address(manager));
        assertEq(router.routerVersion(), 3);
        assertEq(router.v2Router(), address(0));
        assertEq(router.nativeAlias(), address(0));
    }

    function test_initializeV3CannotRunTwice() public {
        vm.expectRevert(ArchemistFeeRouterV3.AlreadyInitialized.selector);
        router.initializeV3(address(1), address(2));
    }

    function test_v2EntrypointsStillWorkAfterUpgrade() public {
        (address token, PoolId poolId) = _launch(keccak256("v2-compat"), address(0));
        PoolKey memory key = locker.getPoolKey(poolId);
        address trader = address(0xB0B);
        vm.deal(trader, 1 ether);
        vm.prank(trader);
        uint256 amountOut = router.exactInputSingleV4{ value: 1 ether }(
            ArchemistFeeRouterV3.V4SwapParams({
                key: _toFR(key),
                zeroForOne: Currency.unwrap(key.currency0) == address(0),
                recipient: trader,
                amountIn: 1 ether,
                amountOutMinimum: 1
            })
        );
        assertGt(amountOut, 0);
        assertEq(ArchemistV4Token(token).balanceOf(trader), amountOut);
        assertEq(routerTreasury.balance, 0.01 ether);
    }

    // ---- exactInputMulti ----

    function test_multiSingleV4LegNativeBuyMatchesV2Path() public {
        (address token, PoolId poolId) = _launch(keccak256("multi-native"), address(0));
        ArchemistFeeRouterV3.Leg[] memory legs = new ArchemistFeeRouterV3.Leg[](1);
        legs[0] = _v4Leg(poolId, address(0), token);

        address trader = address(0xB0B1);
        vm.deal(trader, 1 ether);
        vm.prank(trader);
        uint256 amountOut = router.exactInputMulti{ value: 1 ether }(legs, 1 ether, 1, trader);

        assertGt(amountOut, 0);
        assertEq(ArchemistV4Token(token).balanceOf(trader), amountOut, "output reaches the recipient");
        assertEq(routerTreasury.balance, 0.01 ether, "1% skimmed once, in native");
        assertEq(address(router).balance, 0, "nothing stranded in the router");
    }

    function test_multiV3ThenV4SkimsOnceAndMatchesFusedEntrypoint() public {
        (address token, PoolId poolId) = _launch(keccak256("multi-v3-v4"), address(erc20Quote));
        MockStandardQuote payToken = new MockStandardQuote(18);
        MockSwapVenue venue = new MockSwapVenue(2e18);
        vm.prank(routerOwner);
        router.setSwapVenue(address(venue));

        ArchemistFeeRouterV3.Leg[] memory legs = new ArchemistFeeRouterV3.Leg[](2);
        legs[0] = _v3Leg(address(payToken), address(erc20Quote));
        legs[1] = _v4Leg(poolId, address(erc20Quote), token);

        address trader = address(0xB0B2);
        payToken.mint(trader, 100 ether);
        vm.prank(trader);
        payToken.approve(address(router), 100 ether);
        vm.prank(trader);
        uint256 amountOut = router.exactInputMulti(legs, 100 ether, 1, trader);

        assertEq(payToken.balanceOf(routerTreasury), 1 ether, "fee once, on the input token");
        assertEq(erc20Quote.balanceOf(routerTreasury), 0, "no second cut on the intermediate");
        assertGt(amountOut, 0);
        assertEq(ArchemistV4Token(token).balanceOf(trader), amountOut);
        assertEq(erc20Quote.balanceOf(address(router)), 0, "intermediate fully consumed");

        // Same trade through the V2-era fused entrypoint must land on the same number.
        (address token2, PoolId poolId2) = _launch(keccak256("multi-v3-v4-ref"), address(erc20Quote));
        PoolKey memory key2 = locker.getPoolKey(poolId2);
        payToken.mint(trader, 100 ether);
        vm.prank(trader);
        payToken.approve(address(router), 100 ether);
        vm.prank(trader);
        uint256 fusedOut = router.exactInputV3ThenV4(
            ArchemistFeeRouterV3.V3ThenV4Params({
                tokenIn: address(payToken),
                v3TokenOut: address(erc20Quote),
                v3Fee: 10_000,
                key: _toFR(key2),
                zeroForOne: Currency.unwrap(key2.currency0) == address(erc20Quote),
                recipient: trader,
                amountIn: 100 ether,
                amountOutMinimum: 1
            })
        );
        assertEq(amountOut, fusedOut, "multi and fused paths agree");
        assertEq(ArchemistV4Token(token2).balanceOf(trader), fusedOut);
    }

    function test_multiV4ThenV3SellsALaunchIntoAnotherToken() public {
        // The case V2 could not do in one transaction: sell a launch (v4) and turn the quote into
        // something else on v3, one signature, fee charged once on the tokens sold.
        (address token, PoolId poolId) = _launch(keccak256("multi-v4-v3"), address(erc20Quote));
        MockStandardQuote payout = new MockStandardQuote(18);
        MockSwapVenue venue = new MockSwapVenue(3e18);
        vm.prank(routerOwner);
        router.setSwapVenue(address(venue));

        address trader = address(0xB0B3);
        erc20Quote.mint(trader, 100 ether);
        vm.prank(trader);
        erc20Quote.approve(address(router), 100 ether);
        ArchemistFeeRouterV3.Leg[] memory buy = new ArchemistFeeRouterV3.Leg[](1);
        buy[0] = _v4Leg(poolId, address(erc20Quote), token);
        vm.prank(trader);
        uint256 bought = router.exactInputMulti(buy, 100 ether, 1, trader);
        uint256 treasuryQuoteAfterBuy = erc20Quote.balanceOf(routerTreasury);

        ArchemistFeeRouterV3.Leg[] memory legs = new ArchemistFeeRouterV3.Leg[](2);
        legs[0] = _v4Leg(poolId, token, address(erc20Quote));
        legs[1] = _v3Leg(address(erc20Quote), address(payout));
        vm.prank(trader);
        ArchemistV4Token(token).approve(address(router), bought);
        vm.prank(trader);
        uint256 amountOut = router.exactInputMulti(legs, bought, 1, trader);

        assertGt(amountOut, 0);
        assertEq(payout.balanceOf(trader), amountOut, "final leg pays the recipient directly");
        assertEq(
            ArchemistV4Token(token).balanceOf(routerTreasury),
            bought * ROUTER_FEE_BPS / 10_000,
            "fee once, in the sold token"
        );
        assertEq(erc20Quote.balanceOf(routerTreasury), treasuryQuoteAfterBuy, "no cut on the intermediate quote");
        assertEq(erc20Quote.balanceOf(address(router)), 0, "intermediate fully consumed");
        assertEq(ArchemistV4Token(token).balanceOf(trader), 0);
    }

    function test_multiV4ThenV4HopsBetweenTwoLaunches() public {
        (address tokenA, PoolId poolA) = _launch(keccak256("multi-a"), address(erc20Quote));
        (address tokenB, PoolId poolB) = _launch(keccak256("multi-b"), address(erc20Quote));

        address trader = address(0xB0B4);
        erc20Quote.mint(trader, 100 ether);
        vm.prank(trader);
        erc20Quote.approve(address(router), 100 ether);
        ArchemistFeeRouterV3.Leg[] memory buy = new ArchemistFeeRouterV3.Leg[](1);
        buy[0] = _v4Leg(poolA, address(erc20Quote), tokenA);
        vm.prank(trader);
        uint256 boughtA = router.exactInputMulti(buy, 100 ether, 1, trader);

        ArchemistFeeRouterV3.Leg[] memory legs = new ArchemistFeeRouterV3.Leg[](2);
        legs[0] = _v4Leg(poolA, tokenA, address(erc20Quote));
        legs[1] = _v4Leg(poolB, address(erc20Quote), tokenB);
        vm.prank(trader);
        ArchemistV4Token(tokenA).approve(address(router), boughtA);
        vm.prank(trader);
        uint256 amountOut = router.exactInputMulti(legs, boughtA, 1, trader);

        assertGt(amountOut, 0);
        assertEq(ArchemistV4Token(tokenB).balanceOf(trader), amountOut);
        assertEq(ArchemistV4Token(tokenA).balanceOf(trader), 0);
        assertEq(erc20Quote.balanceOf(address(router)), 0, "quote passed straight through");
    }

    function test_multiV2LegUsesConfiguredRouter() public {
        MockStandardQuote tokenIn = new MockStandardQuote(18);
        MockStandardQuote tokenOut = new MockStandardQuote(18);
        MockV2Router v2 = new MockV2Router(5e18);
        vm.prank(routerOwner);
        router.setV2Router(address(v2));

        ArchemistFeeRouterV3.Leg[] memory legs = new ArchemistFeeRouterV3.Leg[](1);
        legs[0] = _v2Leg(address(tokenIn), address(tokenOut));
        address trader = address(0xB0B5);
        tokenIn.mint(trader, 10 ether);
        vm.prank(trader);
        tokenIn.approve(address(router), 10 ether);
        vm.prank(trader);
        uint256 amountOut = router.exactInputMulti(legs, 10 ether, 1, trader);

        assertEq(amountOut, 9.9 ether * 5, "net 9.9 in at 5x");
        assertEq(tokenOut.balanceOf(trader), amountOut);
        assertEq(tokenIn.balanceOf(routerTreasury), 0.1 ether);
    }

    function test_multiV2LegRevertsWithoutRouter() public {
        MockStandardQuote tokenIn = new MockStandardQuote(18);
        MockStandardQuote tokenOut = new MockStandardQuote(18);
        ArchemistFeeRouterV3.Leg[] memory legs = new ArchemistFeeRouterV3.Leg[](1);
        legs[0] = _v2Leg(address(tokenIn), address(tokenOut));
        address trader = address(0xB0B6);
        tokenIn.mint(trader, 1 ether);
        vm.prank(trader);
        tokenIn.approve(address(router), 1 ether);
        vm.prank(trader);
        vm.expectRevert(ArchemistFeeRouterV3.InvalidLeg.selector);
        router.exactInputMulti(legs, 1 ether, 1, trader);
    }

    function test_multiRejectsLegsThatDoNotChain() public {
        (address token, PoolId poolId) = _launch(keccak256("multi-chain"), address(erc20Quote));
        MockStandardQuote payToken = new MockStandardQuote(18);
        MockStandardQuote unrelated = new MockStandardQuote(18);
        MockSwapVenue venue = new MockSwapVenue(2e18);
        vm.prank(routerOwner);
        router.setSwapVenue(address(venue));

        ArchemistFeeRouterV3.Leg[] memory legs = new ArchemistFeeRouterV3.Leg[](2);
        legs[0] = _v3Leg(address(payToken), address(unrelated));
        legs[1] = _v4Leg(poolId, address(erc20Quote), token);
        address trader = address(0xB0B7);
        payToken.mint(trader, 10 ether);
        vm.prank(trader);
        payToken.approve(address(router), 10 ether);
        vm.prank(trader);
        vm.expectRevert(ArchemistFeeRouterV3.InvalidPath.selector);
        router.exactInputMulti(legs, 10 ether, 1, trader);
    }

    function test_multiRejectsNativeAliasCrossingWhenUnset() public {
        // With nativeAlias unset the native -> ERC-20 step must be refused rather than swapping
        // whatever ERC-20 balance the router might hold.
        (address token, PoolId poolId) = _launch(keccak256("multi-alias"), address(0));
        MockStandardQuote fakeAlias = new MockStandardQuote(6);
        MockSwapVenue venue = new MockSwapVenue(2e18);
        vm.prank(routerOwner);
        router.setSwapVenue(address(venue));

        ArchemistFeeRouterV3.Leg[] memory legs = new ArchemistFeeRouterV3.Leg[](2);
        legs[0] = _v4Leg(poolId, token, address(0));
        legs[1] = _v3Leg(address(fakeAlias), address(erc20Quote));
        address trader = address(0xB0B8);
        vm.deal(trader, 1 ether);
        ArchemistFeeRouterV3.Leg[] memory buy = new ArchemistFeeRouterV3.Leg[](1);
        buy[0] = _v4Leg(poolId, address(0), token);
        vm.prank(trader);
        uint256 bought = router.exactInputMulti{ value: 1 ether }(buy, 1 ether, 1, trader);
        vm.prank(trader);
        ArchemistV4Token(token).approve(address(router), bought);
        vm.prank(trader);
        vm.expectRevert(ArchemistFeeRouterV3.InvalidPath.selector);
        router.exactInputMulti(legs, bought, 1, trader);
    }

    function test_multiEnforcesSlippageOnFinalOutput() public {
        (address token, PoolId poolId) = _launch(keccak256("multi-slippage"), address(0));
        ArchemistFeeRouterV3.Leg[] memory legs = new ArchemistFeeRouterV3.Leg[](1);
        legs[0] = _v4Leg(poolId, address(0), token);
        address trader = address(0xB0B9);
        vm.deal(trader, 1 ether);
        vm.prank(trader);
        vm.expectRevert();
        router.exactInputMulti{ value: 1 ether }(legs, 1 ether, type(uint256).max, trader);
    }

    function test_multiWrongNativeValueReverts() public {
        (address token, PoolId poolId) = _launch(keccak256("multi-badvalue"), address(0));
        ArchemistFeeRouterV3.Leg[] memory legs = new ArchemistFeeRouterV3.Leg[](1);
        legs[0] = _v4Leg(poolId, address(0), token);
        address trader = address(0xB0BA);
        vm.deal(trader, 1 ether);
        vm.prank(trader);
        vm.expectRevert(ArchemistFeeRouterV3.InvalidPayment.selector);
        router.exactInputMulti{ value: 0.5 ether }(legs, 1 ether, 1, trader);
    }
}
