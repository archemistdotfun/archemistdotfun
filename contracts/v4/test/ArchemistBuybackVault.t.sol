// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { PoolManager } from "@uniswap/v4-core/src/PoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolModifyLiquidityTest } from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";

import { ArchemistBuybackVault } from "../src/ArchemistBuybackVault.sol";
import { ArchemistPairRegistry } from "../src/ArchemistPairRegistry.sol";
import { PairConfig } from "../src/ArchemistV4Types.sol";
import { ArchemistERC1967Proxy } from "../src/upgradeability/ArchemistERC1967Proxy.sol";
import { ArchemistUpgradeable } from "../src/upgradeability/ArchemistUpgradeable.sol";
import { MockUniswapV3Factory } from "./Fixture.t.sol";
import { MockUniswapV3Pool } from "./mocks/MockUniswapV3Pool.sol";
import { MockStandardQuote } from "./mocks/ProbeMocks.sol";
import { MockVaultLocker } from "./mocks/VaultMocks.sol";

/// @dev A "pool" that calls back into `execute` from inside the swap it was asked to perform - the
/// shape a malicious ARCH-side venue would take. The transient reentrancy guard must stop it (BV-06).
contract ReenteringPool is MockUniswapV3Pool {
    ArchemistBuybackVault public target;
    address public reenterAsset;

    constructor(address token0_, address token1_, uint24 fee_, uint160 price_)
        MockUniswapV3Pool(token0_, token1_, fee_, price_)
    { }

    function arm(ArchemistBuybackVault target_, address asset_) external {
        target = target_;
        reenterAsset = asset_;
    }

    function swap(address, bool, int256, uint160, bytes calldata) external override returns (int256, int256) {
        target.execute(reenterAsset);
        return (0, 0);
    }
}

/// @notice Covers the deployment-#7 buyback vault: ARCH is burned rather than banked (D2), routes come
/// only from the pair registry and only as canonical factory pools, and the owner has no power over the
/// vault beyond a timelocked upgrade.
///
/// Swaps run against `MockUniswapV3Pool`, a settlement- and callback-accurate stand-in for a real v3
/// pool (optimistic output transfer, then a payment callback, with v3's opposite `amountSpecified` sign
/// convention) rather than a reimplementation of v3's AMM math. What is under test here is the vault's
/// own guards and wiring, not Uniswap's curve.
contract ArchemistBuybackVaultTest is Test {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IPoolManager internal manager;
    MockVaultLocker internal locker;
    MockStandardQuote internal arch;
    MockStandardQuote internal usdc; // stands in for LINKED_USDC
    MockStandardQuote internal other; // a second launch quote, reached via the two-hop chain
    ArchemistPairRegistry internal registry;
    ArchemistBuybackVault internal vault;
    MockUniswapV3Factory internal factory;
    MockUniswapV3Pool internal usdcArchPool;
    MockUniswapV3Pool internal otherUsdcPool;

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        locker = new MockVaultLocker();
        arch = new MockStandardQuote(18);
        usdc = new MockStandardQuote(18);
        other = new MockStandardQuote(18);
        factory = new MockUniswapV3Factory();

        address registryImpl = address(new ArchemistPairRegistry(address(0), block.chainid));
        registry = ArchemistPairRegistry(
            address(
                new ArchemistERC1967Proxy(
                    registryImpl, abi.encodeCall(ArchemistPairRegistry.initialize, (address(this)))
                )
            )
        );

        address vaultImpl =
            address(new ArchemistBuybackVault(manager, address(arch), address(usdc), address(factory), block.chainid));
        vault = ArchemistBuybackVault(
            payable(address(
                    new ArchemistERC1967Proxy(
                        vaultImpl,
                        abi.encodeCall(
                            ArchemistBuybackVault.initialize, (address(this), address(locker), address(registry))
                        )
                    )
                ))
        );

        usdcArchPool = _makePool(address(usdc), address(arch), 10_000);
        otherUsdcPool = _makePool(address(other), address(usdc), 3_000);

        // The pools only become usable routes once the canonical factory vouches for them.
        factory.registerPool(address(usdc), address(arch), 10_000, address(usdcArchPool));
        factory.registerPool(address(other), address(usdc), 3_000, address(otherUsdcPool));

        arch.mint(address(usdcArchPool), 1_000_000 ether);
        usdc.mint(address(otherUsdcPool), 1_000_000 ether);

        _addPair(address(usdc), address(usdcArchPool));
        _addPair(address(other), address(otherUsdcPool));
    }

    // -------------------------------------------------------------------------------------------
    // BV-01 / BV-02 - ARCH is burned, never banked
    // -------------------------------------------------------------------------------------------

    function test_executeBurnsArch() public {
        _fund(address(usdc), 1_000 ether);

        uint256 deadBefore = arch.balanceOf(DEAD);
        uint256 archBurned = vault.execute(address(usdc));

        assertGt(archBurned, 0);
        assertEq(arch.balanceOf(DEAD) - deadBefore, archBurned, "ARCH must land at 0xdead");
        assertEq(arch.balanceOf(address(vault)), 0, "vault must not retain ARCH");
        // Epoch cap: only MAX_EPOCH_BPS (30%) of the pulled balance is swapped in a single execute().
        assertEq(usdc.balanceOf(address(vault)), 700 ether, "70% must remain for future epochs");
        assertEq(archBurned, 300 ether, "mock pool's 1:1 rate means archBurned equals the 30% amountIn");
    }

    function test_executeEmitsBuybackExecutedWithArchBurned() public {
        _fund(address(usdc), 1_000 ether);
        vm.expectEmit(true, false, false, true, address(vault));
        emit ArchemistBuybackVault.BuybackExecuted(address(usdc), 300 ether, 300 ether);
        vault.execute(address(usdc));
    }

    function test_twoHopEndsAtDead() public {
        _fund(address(other), 1_000 ether);

        uint256 deadBefore = arch.balanceOf(DEAD);
        uint256 archBurned = vault.execute(address(other));

        assertEq(arch.balanceOf(DEAD) - deadBefore, archBurned);
        assertEq(usdc.balanceOf(address(vault)), 0, "the intermediate USDC hop must be fully consumed");
        assertEq(other.balanceOf(address(vault)), 700 ether);
    }

    /// @dev The case that matters in practice, and the reason the chain is two hops rather than one: a
    /// launch can be quoted in ANY registered currency, and ARCH's own liquidity lives wherever it
    /// happens to live. A MEME/NVDA launch accrues its buyback slice in NVDA; there is no NVDA/ARCH
    /// pool and there never needs to be. The vault routes NVDA -> linked USDC -> ARCH, and each hop is
    /// resolved independently, so the two may sit on completely different venues - here hop 1 is a
    /// Uniswap v4 pool and hop 2 is the real v3 ARCH pool, which is exactly the Arc mainnet shape.
    function test_anyQuoteReachesArchAcrossMixedVenues() public {
        MockStandardQuote nvda = new MockStandardQuote(18);

        // Hop 1 lives on v4: a hookless NVDA/USDC pool, with NO address in the registry at all - the
        // vault derives the key from the fee and tick spacing below.
        bool nvdaIsCurrency0 = address(nvda) < address(usdc);
        PoolKey memory hop1Key = PoolKey({
            currency0: Currency.wrap(nvdaIsCurrency0 ? address(nvda) : address(usdc)),
            currency1: Currency.wrap(nvdaIsCurrency0 ? address(usdc) : address(nvda)),
            fee: 3_000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        manager.initialize(hop1Key, TickMath.getSqrtPriceAtTick(0));
        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(manager);
        // Deep enough that the 300-token first hop moves the price by a fraction of a percent - well
        // inside the vault's own 2% same-transaction slippage floor. A thin pool would (correctly) be
        // refused by that floor, which is the point of having it.
        nvda.mint(address(this), 10_000_000 ether);
        usdc.mint(address(this), 10_000_000 ether);
        nvda.approve(address(liquidityRouter), type(uint256).max);
        usdc.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity(
            hop1Key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 1e24,
                salt: bytes32(0)
            }),
            bytes("")
        );

        PairConfig memory nvdaPair = _pairConfig(address(0));
        nvdaPair.buybackRouteIsV4 = true;
        nvdaPair.buybackRouteFee = 3_000;
        nvdaPair.buybackRouteTickSpacing = 60;
        registry.addPair(address(nvda), nvdaPair, 0, true);

        // Hop 2 is the v3 ARCH pool registered in setUp. Nothing about it changes.
        _fund(address(nvda), 1_000 ether);

        uint256 deadBefore = arch.balanceOf(DEAD);
        uint256 archBurned = vault.execute(address(nvda));

        assertGt(archBurned, 0, "a quote with no ARCH pool of its own still reaches ARCH");
        assertEq(arch.balanceOf(DEAD) - deadBefore, archBurned, "and it is burned, not banked");
        assertEq(usdc.balanceOf(address(vault)), 0, "the intermediate hop is fully consumed");
        assertEq(nvda.balanceOf(address(vault)), 700 ether, "only the epoch cap was spent");
    }

    // -------------------------------------------------------------------------------------------
    // BV-08 - the admin surface
    // -------------------------------------------------------------------------------------------

    function test_vaultOwnerIsTimelockAndHasNoOtherPower() public {
        // The owner-gated surface is the upgrade path, the ownership handover, and `resetCheckpoint` -
        // which moves no funds and chooses no route. There is nothing else to call.
        vm.startPrank(address(0xBEEF));
        vm.expectRevert(
            abi.encodeWithSelector(ArchemistUpgradeable.OwnableUnauthorizedAccount.selector, address(0xBEEF))
        );
        vault.upgradeToAndCall(address(0xDEAD), "");
        vm.expectRevert(
            abi.encodeWithSelector(ArchemistUpgradeable.OwnableUnauthorizedAccount.selector, address(0xBEEF))
        );
        vault.resetCheckpoint(address(usdc));
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------------------------
    // The drift guard is not a one-way ratchet (F4)
    // -------------------------------------------------------------------------------------------

    /// @dev The failure this replaces: the checkpoint is written only by a *successful* execute, so once
    /// spot moved more than 5% away, every execute reverted, which wrote no checkpoint, which kept it
    /// reverting - permanently, on an ordinary market move. An earlier deployment's vault stalled for two
    /// days this way.
    ///
    /// Here the price doubles, which no amount of waiting used to survive. The guard refuses while the
    /// checkpoint is fresh and lets it through once enough cooldown periods have passed - without an
    /// upgrade, without an owner, without anyone's permission.
    function test_theDriftGuardHealsItselfInsteadOfBrickingForever() public {
        _fund(address(usdc), 1_000 ether);
        vault.execute(address(usdc)); // seeds the checkpoint

        // A 50% fall in sqrtPrice. `MockUniswapV3Pool` swaps 1:1 regardless of its own slot0, so moving
        // the price DOWN keeps the vault's spot-derived `minOut` satisfiable and leaves the drift guard
        // as the only thing that can refuse - which is what this test is about.
        usdcArchPool.setSqrtPriceX96(uint160(uint256(usdcArchPool.sqrtPriceX96Override()) / 2));

        // Cooldown elapsed, but the checkpoint is one period old: tolerance 10%, drift 50%. Refused.
        vm.warp(block.timestamp + vault.COOLDOWN_SECONDS());
        assertEq(vault.driftToleranceBps(address(usdc)), 1_000);
        vm.expectRevert(
            abi.encodeWithSelector(
                ArchemistBuybackVault.PriceDriftTooLarge.selector,
                usdcArchPool.sqrtPriceX96Override(),
                uint160(uint256(usdcArchPool.sqrtPriceX96Override()) * 2)
            )
        );
        vault.execute(address(usdc));

        // Eight more periods (~2 days of a vault that cannot run) and the band reaches 50%.
        vm.warp(block.timestamp + 8 * uint256(vault.COOLDOWN_SECONDS()));
        assertEq(vault.driftToleranceBps(address(usdc)), 5_000);
        _fund(address(usdc), 1_000 ether);
        assertGt(vault.execute(address(usdc)), 0, "the buyback must recover on its own");
    }

    function test_driftToleranceWidensWithStalenessAndThenStops() public {
        _fund(address(usdc), 1_000 ether);
        vault.execute(address(usdc));

        assertEq(vault.driftToleranceBps(address(usdc)), vault.MAX_SQRT_PRICE_DRIFT_BPS(), "fresh = unchanged");

        uint256 period = vault.COOLDOWN_SECONDS();
        vm.warp(block.timestamp + period - 1);
        assertEq(vault.driftToleranceBps(address(usdc)), 500, "widens per WHOLE period, not continuously");

        vm.warp(block.timestamp + 1);
        assertEq(vault.driftToleranceBps(address(usdc)), 1_000);
        vm.warp(block.timestamp + 3 * period);
        assertEq(vault.driftToleranceBps(address(usdc)), 2_500);

        // And it stops widening rather than running away.
        vm.warp(block.timestamp + 3650 days);
        assertEq(vault.driftToleranceBps(address(usdc)), vault.MAX_DRIFT_TOLERANCE_BPS());
    }

    /// @dev A successful execute re-anchors the clock, so an active vault is always held to the tight
    /// band. Relaxation is a consequence of *not running*, never of running.
    function test_aSuccessfulExecuteResetsTheToleranceToTight() public {
        _fund(address(usdc), 1_000 ether);
        vault.execute(address(usdc));

        vm.warp(block.timestamp + 5 * uint256(vault.COOLDOWN_SECONDS()));
        assertEq(vault.driftToleranceBps(address(usdc)), 3_000);

        _fund(address(usdc), 1_000 ether);
        vault.execute(address(usdc));
        assertEq(vault.driftToleranceBps(address(usdc)), vault.MAX_SQRT_PRICE_DRIFT_BPS());
    }

    /// @dev A reverted attempt must not move the checkpoint. If it did, a sequence of failures would
    /// walk the reference toward a manipulated price for free.
    function test_aRefusedExecuteLeavesTheCheckpointUntouched() public {
        _fund(address(usdc), 1_000 ether);
        vault.execute(address(usdc));
        (uint160 before, uint64 writtenAt) = vault.checkpointOf(address(usdc));

        usdcArchPool.setSqrtPriceX96(uint160(uint256(usdcArchPool.sqrtPriceX96Override()) * 2));
        vm.warp(block.timestamp + vault.COOLDOWN_SECONDS());
        vm.expectRevert();
        vault.execute(address(usdc));

        (uint160 nowPrice, uint64 nowAt) = vault.checkpointOf(address(usdc));
        assertEq(nowPrice, before);
        assertEq(nowAt, writtenAt);
    }

    /// @dev `resetCheckpoint` is the deliberate escape hatch: owner-only, so in production it is the
    /// timelock and therefore public 48 hours ahead. It clears the reference and nothing else.
    function test_ownerCanClearACheckpointAndTheNextExecuteReseeds() public {
        _fund(address(usdc), 1_000 ether);
        vault.execute(address(usdc));
        usdcArchPool.setSqrtPriceX96(uint160(uint256(usdcArchPool.sqrtPriceX96Override()) / 2));
        vm.warp(block.timestamp + vault.COOLDOWN_SECONDS());
        vm.expectRevert();
        vault.execute(address(usdc));

        (uint160 stale,) = vault.checkpointOf(address(usdc));
        vm.expectEmit(true, false, false, true, address(vault));
        emit ArchemistBuybackVault.CheckpointReset(address(usdc), stale);
        vault.resetCheckpoint(address(usdc));

        (uint160 cleared, uint64 clearedAt) = vault.checkpointOf(address(usdc));
        assertEq(cleared, 0);
        assertEq(clearedAt, 0);

        _fund(address(usdc), 1_000 ether);
        assertGt(vault.execute(address(usdc)), 0, "reseeds from spot and runs");
    }

    /// @dev The other half of the ratchet problem, and the one that charged people money.
    ///
    /// `execute` is called from inside a trader's swap, on the trader's gas. It used to check hop 1,
    /// swap hop 1, and only then check hop 2 - so with hop 2 tripped, every buy that crossed the
    /// cooldown boundary paid for a locker claim and a full swap before the attempt died in the hook's
    /// `catch`. And hop 2 (`LINKED_USDC -> ARCH`) is shared by every asset, so that was every launch at
    /// once. Both hops are now cleared before anything is claimed or swapped.
    ///
    /// Measured rather than asserted structurally, because what was wrong was the *cost*.
    function test_aDoomedTwoHopAttemptCostsTwoPriceReadsNotASwap() public {
        // Seed hop 2's checkpoint (LINKED_USDC -> ARCH), then move that pool away from it.
        _fund(address(usdc), 1_000 ether);
        vault.execute(address(usdc));

        // A successful two-hop execute, for scale.
        _fund(address(other), 1_000 ether);
        uint256 beforeOk = gasleft();
        vault.execute(address(other));
        uint256 successGas = beforeOk - gasleft();

        usdcArchPool.setSqrtPriceX96(uint160(uint256(usdcArchPool.sqrtPriceX96Override()) / 2));
        vm.warp(block.timestamp + vault.COOLDOWN_SECONDS());
        _fund(address(other), 1_000 ether);

        uint256 beforeDoomed = gasleft();
        try vault.execute(address(other)) {
            revert("hop 2 must refuse");
        } catch { }
        uint256 doomedGas = beforeDoomed - gasleft();

        assertLt(doomedGas, successGas / 4, "a doomed attempt must not cost a claim plus a swap");

        // ...and hop 1's own checkpoint was not advanced by the failed attempt either.
        (, uint64 hop1At) = vault.checkpointOf(address(other));
        vm.warp(block.timestamp + 1 days);
        assertGt(vault.driftToleranceBps(address(other)), vault.MAX_SQRT_PRICE_DRIFT_BPS());
        assertGt(hop1At, 0, "hop 1 was checkpointed by the successful execute, not by the failed one");
    }

    /// @dev F12. `_minOutFromSqrtPrice` used to square the price first, and `mulDiv` reverts when the
    /// result exceeds 2^256 - so any `sqrtPriceX96 >= 2^128` made the whole buyback for that asset
    /// revert on arithmetic, permanently. That is a raw price of 2^64, which a 6-decimal currency0
    /// against a cheap 18-decimal currency1 reaches easily. Driven through `execute` rather than a
    /// unit-tested helper, because the helper is private and the failure was end-to-end.
    function test_executeSurvivesASqrtPriceAboveTwoToThe128() public {
        // 2^130: comfortably past where squaring overflows, comfortably inside Uniswap's own range.
        uint160 hugeSqrtPrice = uint160(uint256(1) << 130);
        usdcArchPool.setSqrtPriceX96(hugeSqrtPrice);

        _fund(address(usdc), 1_000 ether);
        // It may refuse for economic reasons - the mock pool pays 1:1 and this price implies far more -
        // but it must not die in `mulDiv`. `NothingToBuy` from the slippage floor is a real answer;
        // an arithmetic panic is not.
        try vault.execute(address(usdc)) { }
        catch (bytes memory reason) {
            bytes4 selector = bytes4(reason);
            assertTrue(
                selector == ArchemistBuybackVault.NothingToBuy.selector,
                "the only acceptable refusal here is economic, not arithmetic"
            );
        }
    }

    /// @dev And on the two-hop path, where the same math runs twice against two different pools.
    function test_twoHopSurvivesASqrtPriceAboveTwoToThe128() public {
        otherUsdcPool.setSqrtPriceX96(uint160(uint256(1) << 130));
        _fund(address(other), 1_000 ether);

        try vault.execute(address(other)) { }
        catch (bytes memory reason) {
            assertTrue(
                bytes4(reason) == ArchemistBuybackVault.NothingToBuy.selector,
                "the only acceptable refusal here is economic, not arithmetic"
            );
        }
    }

    /// @dev **N1.** Every non-USDC asset routes to LINKED_USDC for hop 1, and LINKED_USDC routes back
    /// to ARCH for hop 2 - so listing ARCH itself as a quote currency would have put both legs on the
    /// same pool and had the vault sell ARCH to buy back less ARCH, while also falsifying the premise
    /// that hop 1 cannot move hop 2's pool. Unreachable while ARCH is not a listed quote, but only one
    /// timelocked `addPair` away from being reachable. ARCH now short-circuits to a direct burn, which
    /// is what the vault exists to do anyway.
    function test_archFeesAreBurnedDirectlyInsteadOfRoundTripping() public {
        _addPair(address(arch), address(usdcArchPool));
        _fund(address(arch), 1_000 ether);

        uint256 poolUsdcBefore = usdc.balanceOf(address(usdcArchPool));
        uint256 poolArchBefore = arch.balanceOf(address(usdcArchPool));
        uint256 deadBefore = arch.balanceOf(DEAD);

        uint256 burned = vault.execute(address(arch));

        assertEq(burned, 1_000 ether * uint256(vault.MAX_EPOCH_BPS()) / 10_000, "the epoch cap still applies");
        assertEq(arch.balanceOf(DEAD) - deadBefore, burned, "and it went to the sink");
        assertEq(usdc.balanceOf(address(usdcArchPool)), poolUsdcBefore, "no swap touched the pool");
        assertEq(arch.balanceOf(address(usdcArchPool)), poolArchBefore, "in either direction");
        assertGt(vault.lastExecuteAt(address(arch)), 0, "and it recorded that it ran");
    }

    /// @dev The direct burn is not a bypass: it is the same cooldown as every other asset.
    function test_theDirectArchBurnRespectsTheCooldown() public {
        _addPair(address(arch), address(usdcArchPool));
        _fund(address(arch), 1_000 ether);
        vault.execute(address(arch));

        vm.expectRevert();
        vault.execute(address(arch));

        vm.warp(block.timestamp + vault.COOLDOWN_SECONDS());
        assertGt(vault.execute(address(arch)), 0, "and runs again once it has elapsed");
    }

    /// @dev With nothing accrued it refuses rather than emitting a zero burn.
    function test_theDirectArchBurnRefusesWhenThereIsNothingToBurn() public {
        _addPair(address(arch), address(usdcArchPool));
        vm.expectRevert(ArchemistBuybackVault.NothingToBuy.selector);
        vault.execute(address(arch));
    }

    function test_resetCheckpointRefusesWhenThereIsNothingToClear() public {
        vm.expectRevert(abi.encodeWithSelector(ArchemistBuybackVault.CheckpointAlreadyClear.selector, address(usdc)));
        vault.resetCheckpoint(address(usdc));
    }

    // -------------------------------------------------------------------------------------------
    // BV-04 / BV-05 / BV-07 - routes come from the registry, and only as canonical pools
    // -------------------------------------------------------------------------------------------

    function test_routeComesFromRegistryOnly() public {
        _fund(address(usdc), 1_000 ether);
        vault.execute(address(usdc));
        (,, address cached,, bool exists) = vault.getRoute(address(usdc));
        assertTrue(exists);
        assertEq(cached, address(usdcArchPool));

        // Point the registry somewhere else. The cached route must not follow: curation is never
        // retroactive, and a route real money has already flowed through is settled.
        MockUniswapV3Pool replacement = _makePool(address(usdc), address(arch), 500);
        factory.registerPool(address(usdc), address(arch), 500, address(replacement));
        arch.mint(address(replacement), 1_000_000 ether);
        _updatePairRoute(address(usdc), address(replacement));

        (,, address stillCached,,) = vault.getRoute(address(usdc));
        assertEq(stillCached, address(usdcArchPool), "cached route must be immutable once used");
    }

    function test_routeMustBeCanonicalFactoryPool() public {
        // A pool holding exactly the right two tokens, but not the one the factory returns - i.e. one
        // anyone could have deployed and filled with their own liquidity.
        MockUniswapV3Pool impostor = _makePool(address(other), address(usdc), 3_000);
        arch.mint(address(impostor), 1_000_000 ether);
        usdc.mint(address(impostor), 1_000_000 ether);
        _updatePairRoute(address(other), address(impostor));

        _fund(address(other), 1_000 ether);
        vm.expectRevert(
            abi.encodeWithSelector(ArchemistBuybackVault.InvalidRoute.selector, address(other), address(impostor))
        );
        vault.execute(address(other));
    }

    function test_routeMustHoldAssetAndItsFixedCounterpart() public {
        MockStandardQuote unrelated = new MockStandardQuote(18);
        MockUniswapV3Pool wrongPair = _makePool(address(other), address(unrelated), 3_000);
        factory.registerPool(address(other), address(unrelated), 3_000, address(wrongPair));
        _updatePairRoute(address(other), address(wrongPair));

        _fund(address(other), 1_000 ether);
        vm.expectRevert(
            abi.encodeWithSelector(ArchemistBuybackVault.InvalidRoute.selector, address(other), address(wrongPair))
        );
        vault.execute(address(other));
    }

    function test_unroutedAssetJustWaits() public {
        MockStandardQuote stranded = new MockStandardQuote(18);
        stranded.mint(address(vault), 500 ether);

        vm.expectRevert(abi.encodeWithSelector(ArchemistBuybackVault.NoRoute.selector, address(stranded)));
        vault.execute(address(stranded));
        assertEq(
            stranded.balanceOf(address(vault)), 500 ether, "balance untouched - there is no rescue, and none needed"
        );

        // Once the registry knows a route, anyone can execute. Nothing had to be withdrawn in between.
        MockUniswapV3Pool pool = _makePool(address(stranded), address(usdc), 3_000);
        factory.registerPool(address(stranded), address(usdc), 3_000, address(pool));
        usdc.mint(address(pool), 1_000_000 ether);
        _addPair(address(stranded), address(pool));

        vm.prank(address(0xF00D));
        uint256 burned = vault.execute(address(stranded));
        assertGt(burned, 0);
    }

    /// @dev A v4 route carries no pool address at all: the vault derives the whole `PoolKey` from the
    /// registry's fee and tick spacing plus the asset's fixed counterpart, and pins `hooks` to
    /// address(0). There is therefore nothing for an admin to point anywhere, and a hooked pool can
    /// never be a buyback venue.
    function test_v4RouteIsDerivedFromTheRegistryAndIsAlwaysHookless() public {
        PairConfig memory config = _pairConfig(address(0));
        config.buybackRouteIsV4 = true;
        config.buybackRouteFee = 3_000;
        config.buybackRouteTickSpacing = 60;

        // Not initialized yet -> there is no such pool, so there is no route.
        registry.updatePair(address(usdc), config);
        MockStandardQuote fresh = new MockStandardQuote(18);
        registry.addPair(address(fresh), config, 0, true);
        fresh.mint(address(vault), 100 ether);
        vm.expectRevert(abi.encodeWithSelector(ArchemistBuybackVault.NoRoute.selector, address(fresh)));
        vault.execute(address(fresh));

        // A v4 config that also names a pool address is rejected by the registry itself - the two
        // shapes are exclusive, and accepting a mixture is how an address nobody validated ends up
        // being used. Caught at registration, before any money depends on it.
        config.buybackRoute = address(usdcArchPool);
        MockStandardQuote confused = new MockStandardQuote(18);
        vm.expectRevert(abi.encodeWithSelector(ArchemistPairRegistry.InvalidPair.selector, address(confused)));
        registry.addPair(address(confused), config, 0, true);
    }

    function test_registryRouteOfZeroIsNoRoute() public {
        MockStandardQuote listed = new MockStandardQuote(18);
        _addPair(address(listed), address(0));
        listed.mint(address(vault), 100 ether);
        vm.expectRevert(abi.encodeWithSelector(ArchemistBuybackVault.NoRoute.selector, address(listed)));
        vault.execute(address(listed));
    }

    // -------------------------------------------------------------------------------------------
    // BV-06 and the bounds that were already there
    // -------------------------------------------------------------------------------------------

    function test_executeIsPermissionlessAndReentrancySafe() public {
        _fund(address(usdc), 1_000 ether);
        vm.prank(address(0xF00D));
        assertGt(vault.execute(address(usdc)), 0, "anyone may execute");
    }

    function test_reentrantExecuteReverts() public {
        ReenteringPool pool = new ReenteringPool(
            address(other) < address(usdc) ? address(other) : address(usdc),
            address(other) < address(usdc) ? address(usdc) : address(other),
            3_000,
            TickMath.getSqrtPriceAtTick(0)
        );
        factory.registerPool(address(other), address(usdc), 3_000, address(pool));
        usdc.mint(address(pool), 1_000_000 ether);
        _updatePairRoute(address(other), address(pool));
        pool.arm(vault, address(other));

        _fund(address(other), 1_000 ether);
        // execute -> pool.swap -> execute. The transient guard must stop the inner call, and because
        // the pool does not swallow it, the outer call fails too.
        vm.expectRevert();
        vault.execute(address(other));
    }

    function test_executeRespectsCooldown() public {
        _fund(address(usdc), 1_000 ether);
        vault.execute(address(usdc));

        vm.expectRevert();
        vault.execute(address(usdc));

        vm.warp(block.timestamp + vault.COOLDOWN_SECONDS());
        // No new claimable, but the vault still holds the 70% left over from the first execute.
        assertGt(vault.execute(address(usdc)), 0);
    }

    function test_executeRejectsOnLargePriceDrift() public {
        _fund(address(usdc), 1_000 ether);
        vault.execute(address(usdc)); // establishes the first checkpoint

        vm.warp(block.timestamp + vault.COOLDOWN_SECONDS());
        usdcArchPool.setSqrtPriceX96(uint160(uint256(usdcArchPool.sqrtPriceX96Override()) * 2));

        vm.expectRevert();
        vault.execute(address(usdc));
    }

    function test_executeRejectsWhenPoolUnderpays() public {
        _fund(address(usdc), 1_000 ether);
        usdcArchPool.setStarveOutput(true);
        vm.expectRevert(ArchemistBuybackVault.NothingToBuy.selector);
        vault.execute(address(usdc));
    }

    function test_executeRespectsMinOutSlippageFloor() public {
        _fund(address(usdc), 1_000 ether);
        // 5% worse than spot - beyond the vault's 2% same-tx slippage floor.
        bool usdcIsToken0 = address(usdc) < address(arch);
        usdcArchPool.setRateToken1PerToken0X18(usdcIsToken0 ? 0.95e18 : uint256(1e18) * 1e18 / 0.95e18);
        vm.expectRevert(ArchemistBuybackVault.NothingToBuy.selector);
        vault.execute(address(usdc));
    }

    function test_uniswapV3SwapCallbackRejectsCallerThatIsNotTheActivePool() public {
        vm.expectRevert(ArchemistBuybackVault.UnexpectedCallback.selector);
        vault.uniswapV3SwapCallback(1, -1, bytes(""));
    }

    /// @dev Native is an alias for LINKED_USDC on Arc - the same balance at a different decimal scale -
    /// so it must redirect into LINKED_USDC's own route, cooldown and checkpoint rather than getting any
    /// state of its own. Funded directly here because a plain mock ERC-20 cannot replicate Arc's
    /// balance-aliasing precompile; this isolates exactly the routing redirect.
    function test_executeNativeRedirectsToLinkedUsdcRoute() public {
        usdc.mint(address(vault), 1_000 ether);

        uint256 deadBefore = arch.balanceOf(DEAD);
        uint256 archBurned = vault.execute(address(0));

        assertGt(archBurned, 0);
        assertEq(arch.balanceOf(DEAD) - deadBefore, archBurned);
        assertEq(vault.lastExecuteAt(address(usdc)), block.timestamp, "state keyed by LINKED_USDC, not native");
        assertEq(vault.lastExecuteAt(address(0)), 0, "native never gets its own cooldown state");
    }

    function test_executeNativeAndLinkedUsdcShareOneCooldown() public {
        usdc.mint(address(vault), 1_000 ether);
        vault.execute(address(0));
        vm.expectRevert();
        vault.execute(address(usdc));
    }

    function test_executeRevertsWithNothingToBuy() public {
        vm.expectRevert(ArchemistBuybackVault.NothingToBuy.selector);
        vault.execute(address(usdc));
    }

    // -------------------------------------------------------------------------------------------
    // helpers
    // -------------------------------------------------------------------------------------------

    function _makePool(address a, address b, uint24 fee) private returns (MockUniswapV3Pool) {
        bool aIsToken0 = a < b;
        return new MockUniswapV3Pool(aIsToken0 ? a : b, aIsToken0 ? b : a, fee, TickMath.getSqrtPriceAtTick(0));
    }

    function _pairConfig(address route) private pure returns (PairConfig memory) {
        return PairConfig({
            enabled: true,
            decimals: 18,
            defaultTick: 0,
            minTick: -120_000,
            maxTick: 120_000,
            tickSpacing: 60,
            flags: 0,
            buybackRoute: route,
            buybackRouteIsV4: false,
            buybackRouteFee: 0,
            buybackRouteTickSpacing: 0,
            minCreatorBps: 5_000,
            maxCreatorBps: 8_000
        });
    }

    function _addPair(address quote, address route) private {
        registry.addPair(quote, _pairConfig(route), 0, true);
    }

    function _updatePairRoute(address quote, address route) private {
        registry.updatePair(quote, _pairConfig(route));
    }

    function _fund(address asset, uint256 amount) private {
        MockStandardQuote(asset).mint(address(locker), amount);
        locker.setClaimable(address(vault), asset, amount);
    }
}
