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

// The production router files live outside this Foundry project (`solidity/`, compiled via a
// standalone solc pipeline with zero remappings - see contracts/v2/scripts/compile.mjs for the equivalent pipeline.
// They import nothing external by design. Forge won't traverse outside its project root for a
// plain relative import, so test/vendored/ symlinks back to the real files (see that directory) -
// same inode, so this exercises the exact bytecode that would actually be deployed, not a copy.
import { ArchemistFeeRouterProxy } from "./vendored/ArchemistFeeRouterProxy.sol";
import { ArchemistFeeRouterV2, PoolKeyFR } from "./vendored/ArchemistFeeRouterV2.sol";

contract HookFeeReceiver {
    receive() external payable { }
}

/// @dev Proves ArchemistFeeRouterV2's new v4 swap path (exactInputSingleV4) against a real
/// PoolManager + a real Archemist V3 hook pool, launched exactly the way the frontend would.
/// Covers: native-quote buy, ERC20-quote buy, sell back to quote, the router's own feeBps skim
/// stacking on top of the hook's own fee (confirmed design choice - see the PR discussion), and
/// slippage rejection.
contract ArchemistFeeRouterV2Test is Test {
    uint160 internal constant REQUIRED_FLAGS = 0x28CC;
    uint256 internal constant ROUTER_FEE_BPS = 100; // 1%, matches the live mainnet router's feeBps

    IPoolManager internal manager;
    HookFeeReceiver internal hookTreasury;
    HookFeeReceiver internal buyback;
    ArchemistPairRegistry internal registry;
    ArchemistV4Launcher internal launcher;
    ArchemistV4Locker internal locker;
    ArchemistHolderRewards internal holderRewards;
    ArchemistV4Hook internal hook;
    MockStandardQuote internal erc20Quote;

    address internal routerOwner = address(0xA11CE);
    address internal routerTreasury = address(0xFEE7);
    ArchemistFeeRouterV2 internal router;

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        hookTreasury = new HookFeeReceiver();
        buyback = new HookFeeReceiver();
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

        // --- deploy the real UUPS proxy + V2 implementation, exactly like the production script ---
        ArchemistFeeRouterV2 impl = new ArchemistFeeRouterV2();
        bytes memory initData =
            abi.encodeCall(ArchemistFeeRouterV2.initialize, (routerOwner, routerTreasury, address(1), ROUTER_FEE_BPS));
        ArchemistFeeRouterProxy proxy = new ArchemistFeeRouterProxy(address(impl), initData);
        router = ArchemistFeeRouterV2(payable(address(proxy)));

        vm.prank(routerOwner);
        router.initializeV2(address(manager));
    }

    function _launchNative(bytes32 salt, uint256 windowSeconds) private returns (address token, PoolId poolId) {
        FeeRecipient[] memory recipients = new FeeRecipient[](1);
        recipients[0] = FeeRecipient({ admin: address(this), payout: address(this), bps: 10_000 });
        ArchemistV4Launcher.LaunchParams memory params = ArchemistV4Launcher.LaunchParams({
            name: "Router Test Token",
            symbol: "RTT",
            salt: salt,
            quote: address(0),
            targetFdvQuoteRaw: 1_000_000_000 ether,
            hook: address(hook),
            hookParams: abi.encode(
                AntiSnipeParams({ startHookFee: 10_000, windowSeconds: uint32(windowSeconds), maxBuyBps: 10_000 })
            ),
            creatorShareBps: 7_000,
            recipients: recipients,
            creatorBuyAmount: 0,
            creatorBuyMinTokensOut: 0
        });
        (token, poolId) = launcher.createToken(params);
    }

    function _launchErc20(bytes32 salt, uint256 windowSeconds) private returns (address token, PoolId poolId) {
        FeeRecipient[] memory recipients = new FeeRecipient[](1);
        recipients[0] = FeeRecipient({ admin: address(this), payout: address(this), bps: 10_000 });
        ArchemistV4Launcher.LaunchParams memory params = ArchemistV4Launcher.LaunchParams({
            name: "Router Test Erc20 Token",
            symbol: "RTTE",
            salt: salt,
            quote: address(erc20Quote),
            targetFdvQuoteRaw: 1_000_000_000 ether,
            hook: address(hook),
            hookParams: abi.encode(
                AntiSnipeParams({ startHookFee: 10_000, windowSeconds: uint32(windowSeconds), maxBuyBps: 10_000 })
            ),
            creatorShareBps: 7_000,
            recipients: recipients,
            creatorBuyAmount: 0,
            creatorBuyMinTokensOut: 0
        });
        (token, poolId) = launcher.createToken(params);
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

    function test_buyNativeQuoteSkimsRouterFeeAndSwaps() public {
        (address token, PoolId poolId) = _launchNative(keccak256("native-buy"), 1);
        vm.warp(block.timestamp + 2); // past the anti-snipe window -> flat 1% hook fee
        PoolKey memory key = locker.getPoolKey(poolId);
        bool zeroForOne = Currency.unwrap(key.currency0) == address(0); // native quote is always currency0

        address trader = address(0xB0B);
        vm.deal(trader, 1 ether);
        vm.prank(trader);
        uint256 amountOut = router.exactInputSingleV4{ value: 1 ether }(
            ArchemistFeeRouterV2.V4SwapParams({
                key: _toFR(key), zeroForOne: zeroForOne, recipient: trader, amountIn: 1 ether, amountOutMinimum: 1
            })
        );

        assertEq(routerTreasury.balance, 0.01 ether, "router must skim 1% feeBps to its own treasury");
        assertGt(amountOut, 0, "trader must receive tokens");
        assertEq(ArchemistV4Token(token).balanceOf(trader), amountOut, "router must forward output to recipient");
        // Hook's own 1% base fee (on the router's net 0.99 ether) also accrued to the locker, on top
        // of the router's own skim - confirms the two fees stack as intended, not double-counted.
        assertEq(
            locker.totalClaimLiability(address(0)),
            0.99 ether * 10_000 / 1_000_000,
            "hook fee stacks on the net amount the router forwarded"
        );
    }

    function test_buyErc20QuotePullsApprovedAmountAndSwaps() public {
        (address token, PoolId poolId) = _launchErc20(keccak256("erc20-buy"), 1);
        vm.warp(block.timestamp + 2);
        PoolKey memory key = locker.getPoolKey(poolId);
        bool zeroForOne = Currency.unwrap(key.currency0) == address(erc20Quote);

        address trader = address(0xB0B2);
        erc20Quote.mint(trader, 100 ether);
        vm.prank(trader);
        erc20Quote.approve(address(router), 100 ether);

        vm.prank(trader);
        uint256 amountOut = router.exactInputSingleV4(
            ArchemistFeeRouterV2.V4SwapParams({
                key: _toFR(key), zeroForOne: zeroForOne, recipient: trader, amountIn: 100 ether, amountOutMinimum: 1
            })
        );

        assertEq(erc20Quote.balanceOf(routerTreasury), 1 ether, "router must skim 1% of 100 ether to treasury");
        assertEq(erc20Quote.balanceOf(trader), 0, "full amountIn must be pulled via transferFrom");
        assertGt(amountOut, 0, "trader must receive tokens");
        assertEq(ArchemistV4Token(token).balanceOf(trader), amountOut, "router must forward output to recipient");
    }

    function test_sellBackToNativeQuote() public {
        (address token, PoolId poolId) = _launchNative(keccak256("native-sell"), 1);
        vm.warp(block.timestamp + 2);
        PoolKey memory key = locker.getPoolKey(poolId);
        bool buyZeroForOne = Currency.unwrap(key.currency0) == address(0);

        address trader = address(0xB0B3);
        vm.deal(trader, 1 ether);
        vm.prank(trader);
        uint256 tokensBought = router.exactInputSingleV4{ value: 1 ether }(
            ArchemistFeeRouterV2.V4SwapParams({
                key: _toFR(key), zeroForOne: buyZeroForOne, recipient: trader, amountIn: 1 ether, amountOutMinimum: 1
            })
        );
        assertGt(tokensBought, 0);

        vm.prank(trader);
        ArchemistV4Token(token).approve(address(router), tokensBought);
        uint256 expectedTokenFee = tokensBought * ROUTER_FEE_BPS / 10_000;

        vm.prank(trader);
        uint256 nativeOut = router.exactInputSingleV4(
            ArchemistFeeRouterV2.V4SwapParams({
                key: _toFR(key),
                zeroForOne: !buyZeroForOne,
                recipient: trader,
                amountIn: tokensBought,
                amountOutMinimum: 1
            })
        );

        assertGt(nativeOut, 0, "sell must return some native quote");
        assertEq(ArchemistV4Token(token).balanceOf(trader), 0, "full token balance must be sold");
        // Sell leg's tokenIn is the project token itself, so the router's fee skim is paid in that
        // token (not native) - confirms the skim applies symmetrically on both buy and sell legs.
        assertEq(
            ArchemistV4Token(token).balanceOf(routerTreasury),
            expectedTokenFee,
            "router must skim its fee on the sell leg too (tokenIn = project token)"
        );
    }

    function test_slippageReverts() public {
        (, PoolId poolId) = _launchNative(keccak256("native-slippage"), 1);
        vm.warp(block.timestamp + 2);
        PoolKey memory key = locker.getPoolKey(poolId);
        bool zeroForOne = Currency.unwrap(key.currency0) == address(0);

        address trader = address(0xB0B4);
        vm.deal(trader, 1 ether);
        vm.prank(trader);
        vm.expectRevert();
        router.exactInputSingleV4{ value: 1 ether }(
            ArchemistFeeRouterV2.V4SwapParams({
                key: _toFR(key),
                zeroForOne: zeroForOne,
                recipient: trader,
                amountIn: 1 ether,
                amountOutMinimum: type(uint256).max
            })
        );
    }

    function test_wrongNativeValueReverts() public {
        (, PoolId poolId) = _launchNative(keccak256("native-badvalue"), 1);
        vm.warp(block.timestamp + 2);
        PoolKey memory key = locker.getPoolKey(poolId);
        bool zeroForOne = Currency.unwrap(key.currency0) == address(0);

        address trader = address(0xB0B5);
        vm.deal(trader, 1 ether);
        vm.prank(trader);
        vm.expectRevert(ArchemistFeeRouterV2.InvalidPayment.selector);
        router.exactInputSingleV4{ value: 0.5 ether }(
            ArchemistFeeRouterV2.V4SwapParams({
                key: _toFR(key), zeroForOne: zeroForOne, recipient: trader, amountIn: 1 ether, amountOutMinimum: 1
            })
        );
    }

    function test_onlyOwnerCanUpgradeOrReconfigure() public {
        vm.expectRevert(ArchemistFeeRouterV2.NotAuthorized.selector);
        router.setPoolManager(address(1));

        vm.expectRevert(ArchemistFeeRouterV2.NotAuthorized.selector);
        router.setFeeBps(0);
    }

    function test_initializeV2CannotRunTwice() public {
        vm.prank(routerOwner);
        vm.expectRevert(ArchemistFeeRouterV2.AlreadyInitialized.selector);
        router.initializeV2(address(manager));
    }

    /// The motivating case for the mixed route: a trader holding only USDC buying a launch whose
    /// only pool is against ARCH. Here `payToken` stands in for USDC and `erc20Quote` for ARCH -
    /// the v3 hop is a mock venue (a real one needs a deployed v3 pool, which this suite has no
    /// business standing up), the v4 hop is the real PoolManager and the real Archemist hook.
    function test_v3ThenV4RoutesAnUnheldQuoteAndSkimsFeeOnce() public {
        (address token, PoolId poolId) = _launchErc20(keccak256("v3-then-v4"), 1);
        vm.warp(block.timestamp + 2);
        PoolKey memory key = locker.getPoolKey(poolId);
        bool zeroForOne = Currency.unwrap(key.currency0) == address(erc20Quote);

        MockStandardQuote payToken = new MockStandardQuote(18);
        // 2 erc20Quote per payToken, so the intermediate amount is obviously
        // derived from the first hop rather than passed through unchanged.
        MockSwapVenue venue = new MockSwapVenue(2e18);
        vm.prank(routerOwner);
        router.setSwapVenue(address(venue));

        address trader = address(0xB0B3);
        payToken.mint(trader, 100 ether);
        vm.prank(trader);
        payToken.approve(address(router), 100 ether);

        vm.prank(trader);
        uint256 amountOut = router.exactInputV3ThenV4(
            ArchemistFeeRouterV2.V3ThenV4Params({
                tokenIn: address(payToken),
                v3TokenOut: address(erc20Quote),
                v3Fee: 10_000,
                key: _toFR(key),
                zeroForOne: zeroForOne,
                recipient: trader,
                amountIn: 100 ether,
                amountOutMinimum: 1
            })
        );

        assertEq(payToken.balanceOf(routerTreasury), 1 ether, "fee is skimmed once, on the input token only");
        assertEq(erc20Quote.balanceOf(routerTreasury), 0, "chaining a hop must not cost a second cut");
        assertEq(payToken.balanceOf(trader), 0, "full amountIn must be pulled");
        assertGt(amountOut, 0, "trader must receive tokens");
        assertEq(ArchemistV4Token(token).balanceOf(trader), amountOut, "output goes to the recipient");
        // 99 payToken survived the fee and became 198 erc20Quote, all of which
        // must have gone into the pool rather than settling in the router.
        assertEq(erc20Quote.balanceOf(address(router)), 0, "no intermediate may be left stranded");
    }

    function test_v3ThenV4RejectsHopsThatDoNotMeet() public {
        (, PoolId poolId) = _launchErc20(keccak256("v3-then-v4-mismatch"), 1);
        vm.warp(block.timestamp + 2);
        PoolKey memory key = locker.getPoolKey(poolId);
        bool zeroForOne = Currency.unwrap(key.currency0) == address(erc20Quote);

        MockStandardQuote payToken = new MockStandardQuote(18);
        MockStandardQuote unrelated = new MockStandardQuote(18);
        MockSwapVenue venue = new MockSwapVenue(2e18);
        vm.prank(routerOwner);
        router.setSwapVenue(address(venue));

        address trader = address(0xB0B4);
        payToken.mint(trader, 10 ether);
        vm.prank(trader);
        payToken.approve(address(router), 10 ether);

        // v3 pays out `unrelated`, but the v4 leg consumes erc20Quote - without
        // the check this would swap whatever the router happened to be holding.
        vm.prank(trader);
        vm.expectRevert(ArchemistFeeRouterV2.InvalidPath.selector);
        router.exactInputV3ThenV4(
            ArchemistFeeRouterV2.V3ThenV4Params({
                tokenIn: address(payToken),
                v3TokenOut: address(unrelated),
                v3Fee: 10_000,
                key: _toFR(key),
                zeroForOne: zeroForOne,
                recipient: trader,
                amountIn: 10 ether,
                amountOutMinimum: 1
            })
        );
    }

    function test_v3ThenV4EnforcesSlippageOnFinalOutput() public {
        (, PoolId poolId) = _launchErc20(keccak256("v3-then-v4-slippage"), 1);
        vm.warp(block.timestamp + 2);
        PoolKey memory key = locker.getPoolKey(poolId);
        bool zeroForOne = Currency.unwrap(key.currency0) == address(erc20Quote);

        MockStandardQuote payToken = new MockStandardQuote(18);
        MockSwapVenue venue = new MockSwapVenue(2e18);
        vm.prank(routerOwner);
        router.setSwapVenue(address(venue));

        address trader = address(0xB0B5);
        payToken.mint(trader, 10 ether);
        vm.prank(trader);
        payToken.approve(address(router), 10 ether);

        vm.prank(trader);
        vm.expectRevert();
        router.exactInputV3ThenV4(
            ArchemistFeeRouterV2.V3ThenV4Params({
                tokenIn: address(payToken),
                v3TokenOut: address(erc20Quote),
                v3Fee: 10_000,
                key: _toFR(key),
                zeroForOne: zeroForOne,
                recipient: trader,
                amountIn: 10 ether,
                amountOutMinimum: type(uint128).max
            })
        );
    }
}
