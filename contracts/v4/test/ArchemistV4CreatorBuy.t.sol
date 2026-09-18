// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { PoolManager } from "@uniswap/v4-core/src/PoolManager.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
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
import { MockStandardQuote } from "./mocks/ProbeMocks.sol";

contract HookFeeReceiver {
    receive() external payable { }
}

/// @dev Covers the atomic creator buy (LaunchParams.creatorBuyAmount): executes inside createToken itself,
/// right after the position is seeded, so it can never be front-run. Confirms both of the confirmed
/// exemptions - flat base fee instead of the anti-snipe decay, and no maxBuyBps cap - while proving those
/// exemptions are scoped ONLY to the launcher-triggered buy, not a general anti-snipe bypass.
contract ArchemistV4CreatorBuyTest is Test {
    using SafeCast for uint256;

    uint160 internal constant REQUIRED_FLAGS = 0x28CC;

    IPoolManager internal manager;
    PoolSwapTest internal swapRouter;
    HookFeeReceiver internal treasury;
    HookFeeReceiver internal buyback;
    ArchemistPairRegistry internal registry;
    ArchemistV4Launcher internal launcher;
    ArchemistV4Locker internal locker;
    ArchemistHolderRewards internal holderRewards;
    ArchemistV4Hook internal hook;
    MockStandardQuote internal erc20Quote;

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        swapRouter = new PoolSwapTest(manager);
        treasury = new HookFeeReceiver();
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
    }

    function test_creatorBuyNativePaysFlatFeeNotAntiSnipeDecay() public {
        // startHookFee = 30% (max); if the decay applied, 1 ether in would cost 0.3 ether in fee.
        ArchemistV4Launcher.LaunchParams memory params =
            _nativeParams("Flat Fee Token", "FLAT", keccak256("flat-fee"), 300_000, 10_000, 1 ether, 1);
        vm.deal(address(this), 1 ether);
        launcher.createToken{ value: 1 ether }(params);

        // Flat base fee is 1% (BASE_HOOK_FEE = 10_000 / FEE_DENOMINATOR = 1_000_000).
        assertEq(locker.totalClaimLiability(address(0)), 0.01 ether, "creator buy must pay the flat 1% base fee");
    }

    /// @dev Deliberately cheap FDV (100 ether nominal for the whole 1e9-token supply, vs. the ~1:1 price
    /// used elsewhere in this file) so that a 1 ether buy produces roughly 1% of total supply - comfortably
    /// past the maxBuyBps=10 (0.1%) cap used in both cap-related tests below, without draining the position.
    uint256 private constant CHEAP_FDV = 100 ether;

    function test_creatorBuyExemptFromMaxBuyBpsCap() public {
        ArchemistV4Launcher.LaunchParams memory params = _nativeParamsWithFdv(
            "Cap Exempt Token", "CAPX", keccak256("cap-exempt"), 10_000, 10, CHEAP_FDV, 1 ether, 1
        );
        vm.deal(address(this), 1 ether);
        (address tokenAddress,) = launcher.createToken{ value: 1 ether }(params);

        uint256 maxAllowedForNormalBuyer = ArchemistV4Launcher(launcher).INITIAL_SUPPLY() * 10 / 10_000;
        uint256 received = ArchemistV4Token(tokenAddress).balanceOf(address(this));
        assertGt(received, maxAllowedForNormalBuyer, "creator buy output should exceed the normal maxBuyBps cap");
    }

    function test_normalBuyerStillCappedAfterCreatorBuy() public {
        // Same cheap price and tiny cap as above, but this time prove a THIRD PARTY buying the same size
        // right after gets rejected - the exemption must be scoped to the launcher's own atomic buy only,
        // not a side effect that weakens the cap for everyone during the window.
        ArchemistV4Launcher.LaunchParams memory params = _nativeParamsWithFdv(
            "Still Capped Token", "STILLCAP", keccak256("still-capped"), 10_000, 10, CHEAP_FDV, 0, 0
        );
        (, PoolId poolId) = launcher.createToken(params);
        PoolKey memory key = locker.getPoolKey(poolId);

        vm.deal(address(this), 1 ether);
        vm.expectRevert();
        swapRouter.swap{ value: 1 ether }(
            key,
            SwapParams({ zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
    }

    function test_creatorBuySlippageReverts() public {
        ArchemistV4Launcher.LaunchParams memory params = _nativeParams(
            "Slippage Token", "SLIP", keccak256("slippage"), 10_000, 10_000, 1 ether, type(uint256).max
        );
        vm.deal(address(this), 1 ether);
        // Bare expectRevert: the exact tokensOut isn't precomputed here, only that an unreachable
        // minTokensOut (uint256.max) correctly trips the slippage check.
        vm.expectRevert();
        launcher.createToken{ value: 1 ether }(params);
    }

    function test_creatorBuyWrongMsgValueReverts() public {
        ArchemistV4Launcher.LaunchParams memory params =
            _nativeParams("Bad Value Token", "BADVAL", keccak256("bad-value"), 10_000, 10_000, 1 ether, 1);
        vm.deal(address(this), 1 ether);
        vm.expectRevert(ArchemistV4Launcher.InvalidPayment.selector);
        // Sends only 0.5 ether when 1 ether (creatorBuyAmount) is required.
        launcher.createToken{ value: 0.5 ether }(params);
    }

    function test_creatorBuyErc20QuotePullsViaTransferFrom() public {
        uint256 buyAmount = 100 ether;
        erc20Quote.mint(address(this), buyAmount);
        erc20Quote.approve(address(launcher), buyAmount);

        FeeRecipient[] memory recipients = new FeeRecipient[](1);
        recipients[0] = FeeRecipient({ admin: address(this), payout: address(this), bps: 10_000 });
        ArchemistV4Launcher.LaunchParams memory params = ArchemistV4Launcher.LaunchParams({
            name: "Erc20 Buy Token",
            symbol: "ERC20BUY",
            salt: keccak256("erc20-buy"),
            quote: address(erc20Quote),
            targetFdvQuoteRaw: 1_000_000 ether,
            hook: address(hook),
            hookParams: abi.encode(AntiSnipeParams({ startHookFee: 300_000, windowSeconds: 120, maxBuyBps: 10 })),
            creatorShareBps: 7_000,
            recipients: recipients,
            creatorBuyAmount: buyAmount,
            creatorBuyMinTokensOut: 1
        });

        (address tokenAddress,) = launcher.createToken(params);

        assertEq(erc20Quote.balanceOf(address(this)), 0, "creatorBuyAmount must be pulled via transferFrom");
        assertGt(ArchemistV4Token(tokenAddress).balanceOf(address(this)), 0, "creator must receive bought tokens");
        assertEq(locker.totalClaimLiability(address(erc20Quote)), 1 ether, "flat 1% fee on 100 ether buy");
    }

    function test_creatorBuyTriggersBuyback() public {
        ArchemistV4Launcher.LaunchParams memory params =
            _nativeParams("Buyback Trigger Token", "BBTRIG", keccak256("buyback-trigger"), 10_000, 10_000, 1 ether, 1);
        vm.deal(address(this), 1 ether);
        launcher.createToken{ value: 1 ether }(params);

        // 12.5% of the 1% flat fee credited to the buyback vault address, ERC-6909-backed.
        assertEq(
            locker.erc6909Claimable(address(buyback), address(0)),
            locker.totalClaimLiability(address(0)) * 1_250 / 10_000,
            "creator buy must credit the buyback vault's share like any other swap"
        );
    }

    function test_creatorBuyZeroSkipsSwapEntirely() public {
        ArchemistV4Launcher.LaunchParams memory params =
            _nativeParams("No Buy Token", "NOBUY", keccak256("no-buy"), 10_000, 10_000, 0, 0);
        (address tokenAddress,) = launcher.createToken(params);
        assertEq(ArchemistV4Token(tokenAddress).balanceOf(address(this)), 0, "no creator buy means no tokens");
        assertEq(locker.totalClaimLiability(address(0)), 0, "no swap means no fee accrued");
    }

    function _nativeParams(
        string memory name,
        string memory symbol,
        bytes32 salt,
        uint24 startHookFee,
        uint16 maxBuyBps,
        uint256 creatorBuyAmount,
        uint256 creatorBuyMinTokensOut
    ) private view returns (ArchemistV4Launcher.LaunchParams memory params) {
        return _nativeParamsWithFdv(
            name, symbol, salt, startHookFee, maxBuyBps, 1_000_000_000 ether, creatorBuyAmount, creatorBuyMinTokensOut
        );
    }

    function _nativeParamsWithFdv(
        string memory name,
        string memory symbol,
        bytes32 salt,
        uint24 startHookFee,
        uint16 maxBuyBps,
        uint256 targetFdvQuoteRaw,
        uint256 creatorBuyAmount,
        uint256 creatorBuyMinTokensOut
    ) private view returns (ArchemistV4Launcher.LaunchParams memory params) {
        FeeRecipient[] memory recipients = new FeeRecipient[](1);
        recipients[0] = FeeRecipient({ admin: address(this), payout: address(this), bps: 10_000 });
        params = ArchemistV4Launcher.LaunchParams({
            name: name,
            symbol: symbol,
            salt: salt,
            quote: address(0),
            targetFdvQuoteRaw: targetFdvQuoteRaw,
            hook: address(hook),
            hookParams: abi.encode(
                AntiSnipeParams({ startHookFee: startHookFee, windowSeconds: 120, maxBuyBps: maxBuyBps })
            ),
            creatorShareBps: 7_000,
            recipients: recipients,
            creatorBuyAmount: creatorBuyAmount,
            creatorBuyMinTokensOut: creatorBuyMinTokensOut
        });
    }
}
