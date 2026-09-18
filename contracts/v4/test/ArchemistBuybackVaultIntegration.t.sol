// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolModifyLiquidityTest } from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { ModifyLiquidityParams, SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";

import { ArchemistV4Launcher } from "../src/ArchemistV4Launcher.sol";
import { PairConfig } from "../src/ArchemistV4Types.sol";
import { ArchemistFixture } from "./Fixture.t.sol";
import { MockUniswapV3Pool } from "./mocks/MockUniswapV3Pool.sol";
import { MockStandardQuote } from "./mocks/ProbeMocks.sol";

/// @dev Proves the end-to-end wiring: a real trade on a real Archemist pool automatically triggers
/// `ArchemistBuybackVault.execute()` from inside `ArchemistV4Hook._tryTriggerBuyback`, which swaps the
/// vault's freshly-credited buyback share for ARCH and **burns** it - all within the trader's own
/// transaction, with no keeper and no separate call. Deployment #7's change is the destination: the ARCH
/// ends at `0xdead`, not at the treasury (D2), and there is no longer any human step after the buy.
contract ArchemistBuybackVaultIntegrationTest is ArchemistFixture {
    using SafeCast for uint256;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    PoolSwapTest internal swapRouter;
    MockStandardQuote internal archToken;
    MockStandardQuote internal quote;
    MockUniswapV3Pool internal archPool;

    function setUp() public {
        archToken = new MockStandardQuote(18);
        quote = new MockStandardQuote(18);
        // `quote` doubles as LINKED_USDC here, so a launch on it is a single-hop buyback.
        _deployStack(address(0), address(archToken), address(quote));
        swapRouter = new PoolSwapTest(manager);

        bool quoteIsToken0 = address(quote) < address(archToken);
        archPool = new MockUniswapV3Pool(
            quoteIsToken0 ? address(quote) : address(archToken),
            quoteIsToken0 ? address(archToken) : address(quote),
            10_000,
            TickMath.getSqrtPriceAtTick(0)
        );
        v3Factory.registerPool(address(quote), address(archToken), 10_000, address(archPool));
        archToken.mint(address(archPool), 1_000_000 ether);

        registry.addPair(
            address(quote),
            PairConfig({
                enabled: true,
                decimals: 18,
                defaultTick: 0,
                minTick: -120_000,
                maxTick: 120_000,
                tickSpacing: 60,
                flags: 0,
                buybackRoute: address(archPool),
                buybackRouteIsV4: false,
                buybackRouteFee: 0,
                buybackRouteTickSpacing: 0,
                minCreatorBps: 5_000,
                maxCreatorBps: 8_000
            }),
            0,
            true
        );

        quote.mint(address(this), 3_000_000 ether);
        archToken.mint(address(this), 1_000_000 ether);
        quote.approve(address(swapRouter), type(uint256).max);

        // A plain, unrelated hookless pool, seeded so the PoolManager actually HOLDS quote currency.
        // This matters and is not scaffolding: the buyback runs from inside `afterSwap`, before the
        // trader's own swap has settled, so the locker's ERC-6909 claim is redeemed against the
        // manager's AGGREGATE reserves rather than against this trade's not-yet-paid input. On a live
        // chain those reserves are simply there; an empty test PoolManager has to be given them, or the
        // buyback silently fails and the hook's try/catch hides it.
        _seedManagerReserves();
    }

    function _seedManagerReserves() private {
        bool quoteIsCurrency0 = address(quote) < address(archToken);
        PoolKey memory reserveKey = PoolKey({
            currency0: Currency.wrap(quoteIsCurrency0 ? address(quote) : address(archToken)),
            currency1: Currency.wrap(quoteIsCurrency0 ? address(archToken) : address(quote)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        manager.initialize(reserveKey, TickMath.getSqrtPriceAtTick(0));
        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(manager);
        quote.approve(address(liquidityRouter), type(uint256).max);
        archToken.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity(
            reserveKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 1e21,
                salt: bytes32(0)
            }),
            bytes("")
        );
    }

    function test_tradeAutomaticallyTriggersBuybackAndBurnsArch() public {
        (, PoolId poolId) = launcher.createToken(_tokenParams("Auto Buyback Token", "AUTOBB", "auto-buyback"));
        PoolKey memory key = locker.getPoolKey(poolId);

        assertEq(archToken.balanceOf(DEAD), 0, "nothing burned before any trade");

        _buy(key, 1 ether);

        // The buyback fired automatically, inside the trader's own swap transaction.
        assertGt(archToken.balanceOf(DEAD), 0, "ARCH must have been bought and burned as part of the trade");
        assertEq(archToken.balanceOf(address(vault)), 0, "vault must not retain ARCH");
        assertEq(archToken.balanceOf(address(treasury)), 0, "the treasury is no longer a destination for ARCH");
        assertGt(vault.lastExecuteAt(address(quote)), 0, "vault must record that it executed");
    }

    /// @dev A buyback that cannot run must never take a trader's swap with it. The vault's own cooldown
    /// is the easiest way to make the second and third trades' triggers fail internally; the hook's
    /// gas-capped try/catch has to absorb that silently.
    function test_stuckBuybackNeverBlocksTrading() public {
        (, PoolId poolId) = launcher.createToken(_tokenParams("Cooldown Token", "CDTOK", "cooldown-token"));
        PoolKey memory key = locker.getPoolKey(poolId);
        assertEq(launcher.BUYBACK_VAULT(), address(vault), "sanity: the wired vault is the one under test");

        for (uint256 i; i < 3; ++i) {
            _buy(key, 1 ether);
        }

        // Confirm the cooldown is the actual reason the 2nd/3rd triggers did nothing - not some
        // unrelated non-revert - by asserting it is still active on a direct call right now.
        vm.expectRevert();
        vault.execute(address(quote));
    }

    /// @dev The shape the owner cares about most: a launch quoted in something that is NOT the currency
    /// ARCH trades against. A MEME/NVDA pool accrues its buyback slice in NVDA, and there is no
    /// NVDA/ARCH pool anywhere - nor does there need to be. The vault chains NVDA -> linked USDC ->
    /// ARCH and burns the result, triggered by the trade itself, with no keeper and no configuration
    /// beyond the registry entry that listing NVDA as a quote already required.
    function test_launchOnAnUnrelatedQuoteStillBuysBackAndBurns() public {
        (MockStandardQuote nvda, PoolKey memory key) = _launchOnAnUnrelatedQuote();

        assertEq(archToken.balanceOf(DEAD), 0, "nothing burned before any trade");
        _buyWith(nvda, key, 100 ether);

        assertGt(archToken.balanceOf(DEAD), 0, "NVDA fees reached ARCH and were burned");
        assertEq(archToken.balanceOf(address(vault)), 0, "the vault keeps no ARCH");
        assertEq(quote.balanceOf(address(vault)), 0, "nor any of the intermediate hop");
    }

    /// @dev Builds the two-hop shape: a MEME/NVDA launch where NVDA has no ARCH pool, so the vault has
    /// to chain NVDA -> linked USDC -> ARCH. Shared by the two tests that need it.
    function _launchOnAnUnrelatedQuote() private returns (MockStandardQuote nvda, PoolKey memory key) {
        PoolId poolId;
        nvda = new MockStandardQuote(18);
        MockUniswapV3Pool nvdaUsdcPool = new MockUniswapV3Pool(
            address(nvda) < address(quote) ? address(nvda) : address(quote),
            address(nvda) < address(quote) ? address(quote) : address(nvda),
            3_000,
            TickMath.getSqrtPriceAtTick(0)
        );
        v3Factory.registerPool(address(nvda), address(quote), 3_000, address(nvdaUsdcPool));
        quote.mint(address(nvdaUsdcPool), 1_000_000 ether);

        registry.addPair(
            address(nvda),
            PairConfig({
                enabled: true,
                decimals: 18,
                defaultTick: 0,
                minTick: -120_000,
                maxTick: 120_000,
                tickSpacing: 60,
                flags: 0,
                buybackRoute: address(nvdaUsdcPool),
                buybackRouteIsV4: false,
                buybackRouteFee: 0,
                buybackRouteTickSpacing: 0,
                minCreatorBps: 5_000,
                maxCreatorBps: 8_000
            }),
            0,
            true
        );

        nvda.mint(address(this), 3_000_000 ether);
        nvda.approve(address(swapRouter), type(uint256).max);
        _seedManagerReservesFor(nvda);

        ArchemistV4Launcher.LaunchParams memory p =
            _launchParams(address(hook), address(nvda), keccak256("meme-nvda"), 10_000, 120, 10_000, address(this));
        p.name = "MEME";
        p.symbol = "MEME";
        p.targetFdvQuoteRaw = 1_000_000_000 ether;
        p.creatorShareBps = 7_000;
        (, poolId) = launcher.createToken(p);
        key = locker.getPoolKey(poolId);
    }

    /// @dev **F8.** `ArchemistV4Types` cites this test by name to justify the 1,500,000 stipend, and it
    /// did not exist - it went with `ArchemistBuybackVaultV3.t.sol` when that was deleted. Nothing
    /// measured a two-hop `execute` through the deployment-#7 proxies, where every call into the vault,
    /// the locker and the registry now costs an extra delegatecall. If the real cost had grown past the
    /// stipend, trading-triggered buybacks would simply never fire: the hook hands out whatever is
    /// spare below the cap and swallows the failure, so the symptom is silence, not an error.
    ///
    /// Measured against the number in the source, so the comment cannot drift away from the code.
    function test_buybackStipendCoversAMeasuredTwoHopExecute() public {
        (MockStandardQuote nvda, PoolKey memory key) = _launchOnAnUnrelatedQuote();

        // A real trade, so the fees are real hook fees credited through the real locker - then past the
        // cooldown so the call below takes the expensive path rather than returning early. The cheap
        // path was never in question; what is being measured is a full two-hop swap and burn.
        _buyWith(nvda, key, 100 ether);
        vm.warp(block.timestamp + vault.COOLDOWN_SECONDS() + 1);
        uint256 burnedBefore = archToken.balanceOf(DEAD);

        uint256 before = gasleft();
        vault.execute(address(nvda));
        uint256 used = before - gasleft();

        emit log_named_uint("two-hop execute gas (through proxies)", used);
        assertLt(used, hook.BUYBACK_GAS_STIPEND(), "a two-hop buyback must fit the stipend it is given");
        assertGt(archToken.balanceOf(DEAD), burnedBefore, "and it must actually have burned something");
    }

    /// @dev Same reason as `_seedManagerReserves`: the buyback runs inside `afterSwap`, before the
    /// trader's own input has settled, so the locker's claim is redeemed against the manager's
    /// aggregate reserves.
    function _seedManagerReservesFor(MockStandardQuote asset) private {
        bool assetIsCurrency0 = address(asset) < address(archToken);
        PoolKey memory reserveKey = PoolKey({
            currency0: Currency.wrap(assetIsCurrency0 ? address(asset) : address(archToken)),
            currency1: Currency.wrap(assetIsCurrency0 ? address(archToken) : address(asset)),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });
        manager.initialize(reserveKey, TickMath.getSqrtPriceAtTick(0));
        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(manager);
        asset.approve(address(liquidityRouter), type(uint256).max);
        archToken.mint(address(this), 1_000_000 ether);
        archToken.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity(
            reserveKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(10),
                tickUpper: TickMath.maxUsableTick(10),
                liquidityDelta: 1e21,
                salt: bytes32(0)
            }),
            bytes("")
        );
    }

    function _buyWith(MockStandardQuote asset, PoolKey memory key, uint256 amountIn) private {
        bool assetIsToken0 = Currency.unwrap(key.currency0) == address(asset);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: assetIsToken0,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: assetIsToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
    }

    function _tokenParams(string memory name, string memory symbol, string memory salt)
        private
        view
        returns (ArchemistV4Launcher.LaunchParams memory p)
    {
        p = _launchParams(address(hook), address(quote), keccak256(bytes(salt)), 10_000, 120, 10_000, address(this));
        p.name = name;
        p.symbol = symbol;
        p.targetFdvQuoteRaw = 1_000_000_000 ether;
        p.creatorShareBps = 7_000;
    }

    function _buy(PoolKey memory key, uint256 amountIn) private {
        bool quoteIsToken0 = Currency.unwrap(key.currency0) == address(quote);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: quoteIsToken0,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: quoteIsToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
    }

    receive() external payable { }
}
