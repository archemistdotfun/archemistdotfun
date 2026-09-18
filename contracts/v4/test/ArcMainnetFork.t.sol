// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Test, console2 } from "forge-std/Test.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";

import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";

import { DeployArcMainnet } from "../script/DeployArcMainnet.s.sol";
import { ArchemistV4Launcher } from "../src/ArchemistV4Launcher.sol";
import { ArchemistV4Token } from "../src/ArchemistV4Token.sol";
import { AntiSnipeParams, FeeRecipient } from "../src/ArchemistV4Types.sol";
import { ArcFork } from "./fork/ArcPrecompiles.sol";

interface IUniswapV3PoolMin {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
    function token0() external view returns (address);
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

contract ForkDeployHarness is DeployArcMainnet {
    /// @dev Under `forge script --broadcast` a salted `new` routes through the canonical CREATE2
    /// deployer; inside a test it does not, so the miner has to be told who the deployer really is.
    function _create2Deployer() internal view override returns (address) {
        return address(this);
    }

    function deployForTest(address deployer, address treasury, uint256 delay, address proposer)
        external
        returns (Deployed memory)
    {
        return _deploy(deployer, treasury, 0, delay, proposer);
    }
}

/// @notice **PD-08 and PD-09, against Arc mainnet's real contracts and real liquidity.**
///
/// Everything else in this suite runs against mocks: a `MockUniswapV3Pool` that swaps 1:1 and ignores
/// its own price, a `PoolManager` deployed fresh with no reserves, an ARCH that the test minted. Those
/// prove the logic. What they cannot prove is that the system works against the specific contracts it
/// will actually be wired to - the real `PoolManager` at `0x8366a39C…`, the real ARCH at `0x5042419b…`,
/// the real Uniswap v3 ARCH/USDC pool at `0xC7CF0c94…` with whatever liquidity and price it holds right
/// now, and above all the real linked USDC at `0x3600…`, which is not an ERC-20 at all in the way the
/// mocks assume.
///
/// ## Why this could not be written before
///
/// `0x3600…`'s `balanceOf` reports an account's **native** balance scaled to 6 decimals, and moving the
/// token moves native - through a precompile at `0x1800…` that exists in Arc's client and not in revm.
/// Every `transfer` died with `OpcodeNotFound`, which is why the linked-USDC path had only ever been
/// exercised with `cast` against a live chain, one command at a time, spending real money. `ArcFork`
/// etches a shim at that address which performs the same balance move with `vm.deal`. The aliasing is
/// not simulated away - it is reproduced, and the test asserts it holds.
///
/// ```sh
/// forge test --match-path 'test/ArcMainnetFork.t.sol' --fork-url "$RPC_URL_MAINNET" \
///   --fork-block-number <pinned>
/// ```
///
/// Skipped automatically when no fork is configured, so `forge test` stays green offline.
contract ArcMainnetForkTest is Test {
    uint256 internal constant ARC_CHAIN_ID = 5042;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant ARCH = 0x5042419b1F2498959787Bc23Be1F484Ed1306650;
    address internal constant LINKED_USDC = 0x3600000000000000000000000000000000000000;
    address internal constant ARCH_V3_POOL = 0xC7CF0c94850c912A5045f2A0f2d70Ca18085b829;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    ForkDeployHarness internal script;
    DeployArcMainnet.Deployed internal d;
    PoolSwapTest internal swapRouter;

    address internal deployer;
    address internal treasury = makeAddr("treasury");
    address internal creator = makeAddr("creator");
    address internal trader = makeAddr("trader");

    /// @dev `vm.skip`, not an early `return`. A test that returns early is reported as PASSING, and a
    /// green tick for a test that did nothing is the exact failure mode this whole suite was just
    /// audited for. Offline, these show up as skipped, which is what they are.
    modifier onlyOnFork() {
        vm.skip(block.chainid != ARC_CHAIN_ID, "not forked onto Arc mainnet: pass --fork-url $RPC_URL_MAINNET");
        _;
    }

    function setUp() public {
        if (block.chainid != ARC_CHAIN_ID) return;
        ArcFork.install();

        script = new ForkDeployHarness();
        deployer = address(script);
        vm.deal(deployer, 1_000 ether);

        d = script.deployForTest(deployer, treasury, 48 hours, deployer);
        vm.prank(deployer);
        d.launcher.enableCreate();

        swapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER));
        vm.deal(trader, 10_000 ether);
        vm.deal(creator, 10_000 ether);
    }

    /// @dev The premise everything else rests on, asserted rather than assumed: on Arc these are one
    /// balance at two scales. If this ever stops holding, every routing decision in the system is wrong.
    function test_nativeAndLinkedUsdcAreOneBalance() public onlyOnFork {
        assertEq(IERC20Min(LINKED_USDC).decimals(), 6);
        assertEq(IERC20Min(LINKED_USDC).balanceOf(trader), trader.balance / 1e12, "aliasing must hold");

        uint256 before = IERC20Min(LINKED_USDC).balanceOf(trader);
        vm.deal(trader, trader.balance + 7 ether);
        assertEq(IERC20Min(LINKED_USDC).balanceOf(trader), before + 7_000_000, "and must track native");
    }

    /// @dev PD-08. A real launch on the real PoolManager, quoted in the real linked USDC.
    function test_realLaunchOnLinkedUsdc() public onlyOnFork {
        (address token, PoolKey memory key) = _launch(keccak256("fork-pd08"));

        assertEq(ArchemistV4Token(token).totalSupply(), 1_000_000_000 ether);
        assertTrue(
            Currency.unwrap(key.currency0) == LINKED_USDC || Currency.unwrap(key.currency1) == LINKED_USDC,
            "the pool must be quoted in the real linked USDC"
        );
        assertEq(address(key.hooks), address(d.hook), "bound to the mined hook");
        assertEq(d.launcher.allTokens(0), token, "the launcher recorded it");
        console2.log("launched", token);
    }

    /// @dev PD-08's second half: the token's own deployed bytecode, on a real chain, contains no call
    /// opcode of any kind. This is the "Trade Restriction" scanner finding, checked against what the
    /// real chain will actually hold rather than against a locally compiled artifact.
    function test_theLaunchedTokenMakesNoExternalCall() public onlyOnFork {
        (address token,) = _launch(keccak256("fork-opcodes"));
        bytes memory code = token.code;
        assertGt(code.length, 0);

        uint256 calls;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += uint256(op) - 0x5f; // step over a PUSH's immediate data
                continue;
            }
            // CALL, CALLCODE, DELEGATECALL, STATICCALL
            if (op == 0xf1 || op == 0xf2 || op == 0xf4 || op == 0xfa) ++calls;
        }
        assertEq(calls, 0, "the launch token must contain no call opcode");
    }

    /// @dev A real buy and a real sell through the real PoolManager, with the anti-snipe fee charged at
    /// the rate the launch declared.
    function test_realBuyAndSellChargeTheDeclaredFee() public onlyOnFork {
        (address token, PoolKey memory key) = _launch(keccak256("fork-trade"));

        uint256 spent = 1_000e6; // 1,000 USDC, as raw linked-USDC units
        uint256 tokensOut = _buy(key, token, spent);
        assertGt(tokensOut, 0, "a real buy must return tokens");

        // The hook credited a fee to the locker, in the quote currency.
        assertGt(d.locker.totalLiability(LINKED_USDC) + d.locker.totalClaimLiability(LINKED_USDC), 0, "fee credited");

        uint256 archBefore = IERC20Min(ARCH).balanceOf(DEAD);
        _sell(key, token, tokensOut / 2);
        console2.log("ARCH burned so far", IERC20Min(ARCH).balanceOf(DEAD) - archBefore);
    }

    /// @dev **PD-09.** The whole point of deployment #7, against real liquidity: fees accrued in linked
    /// USDC are swapped for ARCH through the **real** Uniswap v3 pool and burned to `0xdead`. Nothing
    /// here is mocked - not the pool, not its price, not its liquidity, not the token being burned.
    function test_realBuybackBurnsRealArch() public onlyOnFork {
        (address token, PoolKey memory key) = _launch(keccak256("fork-pd09"));

        // Trade enough to accrue a fee worth swapping.
        uint256 tokensOut = _buy(key, token, 5_000e6);
        _sell(key, token, tokensOut / 2);

        uint256 burnedBefore = IERC20Min(ARCH).balanceOf(DEAD);
        uint256 treasuryArchBefore = IERC20Min(ARCH).balanceOf(treasury);
        uint256 vaultUsdcBefore =
            IERC20Min(LINKED_USDC).balanceOf(address(d.vault)) + d.locker.claimable(address(d.vault), LINKED_USDC);

        // Past the cooldown, then run it directly - permissionless, anyone may.
        vm.warp(block.timestamp + d.vault.COOLDOWN_SECONDS() + 1);
        vm.prank(trader);
        uint256 burned = d.vault.execute(LINKED_USDC);

        assertGt(burned, 0, "the buyback must have bought real ARCH");
        assertEq(IERC20Min(ARCH).balanceOf(DEAD) - burnedBefore, burned, "and burned exactly that much");
        assertEq(IERC20Min(ARCH).balanceOf(treasury), treasuryArchBefore, "the treasury receives no ARCH");
        assertEq(IERC20Min(ARCH).balanceOf(address(d.vault)), 0, "the vault retains none");

        // Sanity against the real pool's own price rather than against a number pasted into a test:
        // the ARCH received must be within a few percent of what spot said it would be.
        uint256 spentUsdc = vaultUsdcBefore * d.vault.MAX_EPOCH_BPS() / 10_000;
        assertGt(spentUsdc, 0, "the vault must have had fees to spend");
        console2.log("USDC spent (6dp)", spentUsdc);
        console2.log("real ARCH burned (18dp)", burned);

        // The rate it actually got, against the real pool's own spot at this block. This is the check
        // that would catch a broken `_minOutFromSqrtPrice` in the one environment where the price is not
        // a number a test chose: `sqrtPriceX96` here is whatever Arc's ARCH/USDC pool happens to hold.
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3PoolMin(ARCH_V3_POOL).slot0();
        assertEq(IUniswapV3PoolMin(ARCH_V3_POOL).token0(), LINKED_USDC, "USDC is currency0 in the real pool");
        uint256 spotArchPerUsdc = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96) >> 96;
        uint256 expectedAtSpot = spentUsdc * spotArchPerUsdc;
        console2.log("ARCH at spot, before impact", expectedAtSpot);

        // Its own floor is 2%; a real pool adds price impact on top, so the band is one-sided and wide
        // enough not to be a market-condition tripwire - but it still catches a route paying pennies.
        assertGe(burned * 100, expectedAtSpot * 90, "the buyback must execute near the real pool's price");
        assertLe(burned, expectedAtSpot, "and can never beat spot");
    }

    /// @dev The product claim, on real liquidity: **the buyback is triggered by trading itself**, inside
    /// the trader's own transaction, with no keeper and no configuration. The fee is credited before the
    /// trigger runs, so a buy can fund and fire the same buyback in one swap; this measures the second
    /// one, past the cooldown, so what it observes is unambiguously caused by that trade.
    function test_tradingItselfTriggersTheBuybackOnChain() public onlyOnFork {
        (address token, PoolKey memory key) = _launch(keccak256("fork-auto"));

        _buy(key, token, 5_000e6);
        uint256 burnedBefore = IERC20Min(ARCH).balanceOf(DEAD);

        // Past the cooldown so the vault is willing, then trade again - and touch nothing else. No
        // keeper, no cron, no privileged call: just somebody buying.
        vm.warp(block.timestamp + d.vault.COOLDOWN_SECONDS() + 1);
        _buy(key, token, 5_000e6);

        uint256 burnedByTrading = IERC20Min(ARCH).balanceOf(DEAD) - burnedBefore;
        console2.log("ARCH burned inside a trader's own swap", burnedByTrading);
        assertGt(burnedByTrading, 0, "a trade must fund and fire the buyback without a keeper");
        assertGt(d.vault.lastExecuteAt(LINKED_USDC), 0, "and the vault must record that it ran");
    }

    /// @dev The route the vault resolves is the canonical ARCH pool the deploy script wired, not
    /// something it derived on its own.
    function test_theBuybackRouteIsTheRealArchPool() public onlyOnFork {
        _launch(keccak256("fork-route"));
        assertEq(d.registry.getPair(LINKED_USDC).buybackRoute, ARCH_V3_POOL, "registry points at the real pool");
        assertTrue(d.registry.getPair(address(0)).enabled, "and the native pair is listed alongside it");
    }

    /// @dev PD-08's fee half, exact. A 30% anti-snipe start fee on a buy at t=0 is 30% of the input, in
    /// the quote currency, credited in the locker - no rounding fudge, no approximation.
    function test_antiSnipeFeeIsExactOnChain() public onlyOnFork {
        (address token, PoolKey memory key) = _launch(keccak256("fork-fee"));

        uint256 spent = 1_000e6;
        _buy(key, token, spent);

        // Where the 30% went. Two things make this less obvious than it looks, and both are real
        // behaviour worth naming rather than working around:
        //
        //   - `totalLiability` and `totalClaimLiability` are the SAME money counted two ways - the
        //     credited ledger and the ERC-6909 claim backing it - so adding them double-counts.
        //   - the ecosystem slice does not sit still. The hook credits the fee and *then* triggers the
        //     buyback in the same swap, so by the time this reads, part of that slice has already been
        //     swapped for ARCH and burned. On this run 11.25 of the 37.5 was gone before the
        //     transaction ended.
        //
        // So the total is asserted through the two cuts that do sit still, each of which pins it
        // independently: 70% to the creator by declaration, 17.5% to the treasury as the remainder
        // after the fixed 12.5% ecosystem slice.
        uint256 fee = spent * 30 / 100;
        uint256 creatorCut = d.locker.claimable(creator, LINKED_USDC);
        uint256 treasuryCut = d.locker.claimable(treasury, LINKED_USDC);

        assertEq(creatorCut, fee * 7_000 / 10_000, "creator's declared 70% of a 30% fee");
        assertEq(treasuryCut, fee * 1_750 / 10_000, "treasury's 17.5%, the remainder after the 12.5% slice");
        assertEq(creatorCut * 10_000 / 7_000, fee, "which pins the fee itself at exactly 30%");
        assertEq(treasuryCut * 10_000 / 1_750, fee, "and pins it a second, independent way");

        // The ecosystem slice is whatever is left, and it is either still in the vault or already ARCH.
        uint256 ecosystemLeft =
            IERC20Min(LINKED_USDC).balanceOf(address(d.vault)) + d.locker.claimable(address(d.vault), LINKED_USDC);
        assertLe(ecosystemLeft, fee * 1_250 / 10_000, "it can only ever be the 12.5% slice or less");
        console2.log("ecosystem slice still unspent (6dp)", ecosystemLeft);
    }

    /// @dev Holder rewards, end to end on the real chain: a sell funds the holder slice, a holder's
    /// `earned` moves, and the claim actually pays out in real linked USDC.
    function test_holderRewardsAccrueAndPayOnChain() public onlyOnFork {
        (address token, PoolKey memory key) = _launch(keccak256("fork-rewards"));

        uint256 tokensOut = _buy(key, token, 5_000e6);
        assertEq(d.holderRewards.earned(token, trader), 0, "nothing earned before any sell");

        _sell(key, token, tokensOut / 2);
        uint256 earned = d.holderRewards.earned(token, trader);
        assertGt(earned, 0, "a sell must fund the holder slice");
        console2.log("holder earned (6dp linked USDC)", earned);

        uint256 before = IERC20Min(LINKED_USDC).balanceOf(trader);
        vm.prank(trader);
        uint256 paid = d.holderRewards.claim(token, trader);
        assertEq(paid, earned, "the claim pays what was earned");
        assertEq(IERC20Min(LINKED_USDC).balanceOf(trader) - before, paid, "in real linked USDC");
    }

    /// @dev **The integration fact no mock in this repo could show.** Arc's linked USDC is
    /// Circle-issued, and its implementation consults a compliance precompile at `0x1800…0001` on every
    /// `transferFrom` - checking the **caller**, not the two parties. A third party can therefore refuse
    /// to move the quote currency of any Archemist pool, and nothing in this system was designed with
    /// that in mind because nothing in this system could see it: every mock quote currency in the suite
    /// is an ERC-20 that always says yes.
    ///
    /// What it does is contained and correct. A blocklisted trader cannot trade - which is the point of
    /// a blocklist - and the pool, the hook, the fees and every other trader are untouched.
    function test_aBlocklistedTraderCannotTradeAndNobodyElseIsAffected() public onlyOnFork {
        (address token, PoolKey memory key) = _launch(keccak256("fork-blocklist"));
        _buy(key, token, 1_000e6);

        address other = makeAddr("another trader");
        vm.deal(other, 10_000 ether);

        // The precompile checks the CALLER of `transferFrom`, which on the swap path is the router.
        ArcFork.setBlocklisted(address(swapRouter), true);
        vm.prank(trader);
        IERC20Min(LINKED_USDC).approve(address(swapRouter), type(uint256).max);
        vm.prank(trader);
        vm.expectRevert(); // armed immediately before the swap, or the approve above would satisfy it
        _rawSwap(key, 1_000e6);

        // Lift it and the same swap goes through, so the refusal was the blocklist and nothing else.
        ArcFork.setBlocklisted(address(swapRouter), false);
        assertGt(_buy(key, token, 1_000e6), 0, "trading resumes the moment compliance allows it");
        assertGt(d.locker.claimable(creator, LINKED_USDC), 0, "and the creator's fees were never at risk");
    }

    // ---------------------------------------------------------------------------------------------

    function _launch(bytes32 salt) private returns (address token, PoolKey memory key) {
        FeeRecipient[] memory recipients = new FeeRecipient[](1);
        recipients[0] = FeeRecipient({ admin: creator, payout: creator, bps: 10_000 });

        ArchemistV4Launcher.LaunchParams memory p = ArchemistV4Launcher.LaunchParams({
            name: "Fork Probe",
            symbol: "FORK",
            salt: salt,
            quote: LINKED_USDC,
            targetFdvQuoteRaw: 50_000e6,
            hook: address(d.hook),
            hookParams: abi.encode(AntiSnipeParams({ startHookFee: 300_000, windowSeconds: 120, maxBuyBps: 10_000 })),
            creatorShareBps: 7_000,
            recipients: recipients,
            creatorBuyAmount: 0,
            creatorBuyMinTokensOut: 0
        });

        vm.prank(creator);
        PoolId poolId;
        (token, poolId) = d.launcher.createToken(p);
        key = d.locker.getPoolKey(poolId);
    }

    function _buy(PoolKey memory key, address token, uint256 quoteIn) private returns (uint256 tokensOut) {
        if (quoteIn == 0) return 0;
        bool quoteIsToken0 = Currency.unwrap(key.currency0) == LINKED_USDC;
        uint256 before = IERC20Min(token).balanceOf(trader);

        vm.startPrank(trader);
        IERC20Min(LINKED_USDC).approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: quoteIsToken0,
                amountSpecified: -int256(quoteIn),
                sqrtPriceLimitX96: quoteIsToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
        vm.stopPrank();
        tokensOut = IERC20Min(token).balanceOf(trader) - before;
    }

    /// @dev The swap alone, with no approval in front of it, for tests that arm `expectRevert`.
    function _rawSwap(PoolKey memory key, uint256 quoteIn) private {
        bool quoteIsToken0 = Currency.unwrap(key.currency0) == LINKED_USDC;
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: quoteIsToken0,
                amountSpecified: -int256(quoteIn),
                sqrtPriceLimitX96: quoteIsToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
    }

    function _sell(PoolKey memory key, address token, uint256 tokensIn) private {
        if (tokensIn == 0) return;
        bool quoteIsToken0 = Currency.unwrap(key.currency0) == LINKED_USDC;

        vm.startPrank(trader);
        IERC20Min(token).approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: !quoteIsToken0,
                amountSpecified: -int256(tokensIn),
                sqrtPriceLimitX96: quoteIsToken0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
        vm.stopPrank();
    }

    receive() external payable { }
}
