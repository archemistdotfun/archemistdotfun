// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { TransientStateLibrary } from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { Currency, CurrencyLibrary } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";

import { PairConfig } from "./ArchemistV4Types.sol";
import { IArchemistPairRegistry } from "./interfaces/IArchemistPairRegistry.sol";
import { IUniswapV3FactoryMinimal, IUniswapV3PoolMinimal } from "./interfaces/IUniswapV3Minimal.sol";
import { ArchemistUpgradeable } from "./upgradeability/ArchemistUpgradeable.sol";

interface IBuybackVaultLocker {
    function claimable(address beneficiary, address asset) external view returns (uint256);
    function claim(address asset, address to) external returns (uint256);
}

/// @notice Accumulates the buyback share of protocol fees (credited by ArchemistV4Locker, pull-based)
/// and periodically swaps a bounded slice of each currency's balance for ARCH, which it **burns**.
///
/// **Design notes.**
///
/// *ARCH is burned, not banked.* The previous vault forwarded every ARCH it bought to the treasury EOA,
/// which meant "buyback" was only ever half a promise - what happened next was a human decision. The
/// destination is now the constant `ARCH_SINK = 0x…dEaD`, with no setter and no alternative path. State
/// it precisely, because the UI must: ARCH has no `burn()` and its `_transfer` rejects `address(0)`, so
/// `totalSupply()` does **not** move; what moves is `balanceOf(0xdead)`, and tokens there are provably
/// unspendable. That is the same convention the V2 factory already uses for dust, and the same number
/// the site already shows as "burned".
///
/// *Routes come from one place.* `PairRegistry.getPair(asset).buybackRoute`, validated against the
/// canonical Uniswap v3 factory (`getPool(asset, counterpart, pool.fee()) == pool`), so a route can only
/// ever be the real, canonical pool for that pair - not a private one that happens to hold the same two
/// tokens. An asset with no route simply waits; `execute` reverts `NoRoute` and the balance stays put
/// until the registry gains a route for it, at which point anyone can execute. There is no withdrawal
/// path, and none is needed.
///
/// *Nobody chooses a v4 pool either.* A v4 route is derived entirely from registry data - {asset, its fixed counterpart, the
/// pair's `buybackRouteFee` and `buybackRouteTickSpacing`, `hooks: address(0)}` - which means there is
/// no address to spoof in the first place: a v4 pool IS its key, PoolManager custodies every pool, and
/// forcing `hooks == address(0)` keeps a buyback from ever routing through a hooked pool that could
/// interfere with its own swap.
///
/// The remaining design constraints are as specified in docs/PROTOCOL_MECHANISM.md:
///
///   1. `execute` is **permissionless**. Anyone may call it; it is the hook's `afterSwap` that usually
///      does, so a buyback is triggered by trading itself rather than by a keeper anyone has to trust.
///   2. It is **bounded** in three independent ways: a 6-hour cooldown per asset, a 30% cap on how much
///      of the balance one call may swap, and a rolling price-drift check that refuses to run when spot
///      has moved more than 5% (in sqrt price) from its own EMA checkpoint. Together these make the
///      contract uninteresting to sandwich and unable to dump its whole balance into a manipulated pool.
///   3. Everything above LINKED_USDC routes through it: `asset -> LINKED_USDC -> ARCH`. Only the first
///      hop is cooldown- and epoch-capped, because the second hop's size is already fully determined by
///      the first.
///   4. Native currency is not a two-hop asset - on Arc it **is** LINKED_USDC, the same balance at a
///      different decimal scale, kept in sync by a protocol precompile. It aliases straight into
///      LINKED_USDC's own route and never needs a pool.
///
/// The only privileged function is `upgradeToAndCall`, and its owner is the 48-hour timelock.
contract ArchemistBuybackVault is ArchemistUpgradeable, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using StateLibrary for IPoolManager;

    /// @notice Where bought ARCH goes, permanently. Not settable, not the treasury, not `address(0)`
    /// (ARCH's own `_transfer` rejects that and ARCH has no `burn()`), so "burned" here means
    /// `balanceOf(0xdead)` grows while `totalSupply()` stands still.
    address public constant ARCH_SINK = 0x000000000000000000000000000000000000dEaD;

    uint16 public constant BPS = 10_000;
    /// @dev Max fraction of the vault's current balance of an asset that a single execute() may swap.
    uint16 public constant MAX_EPOCH_BPS = 3_000; // 30%
    /// @dev Same-block slippage floor applied to the swap itself, on top of the spot-implied output.
    uint16 public constant SWAP_SLIPPAGE_BPS = 200; // 2%
    /// @dev How far the current spot sqrtPriceX96 may drift from the rolling checkpoint before
    /// execute() refuses to run. Bounds sqrtPrice directly (not the squared price), so this is
    /// deliberately conservative relative to its bps value.
    uint16 public constant MAX_SQRT_PRICE_DRIFT_BPS = 500; // 5%
    /// @dev How much that tolerance widens for each full cooldown period the checkpoint has gone
    /// without being updated. See `driftToleranceBps` for why this exists: without it the guard is a
    /// one-way ratchet that bricks the vault permanently on an ordinary market move.
    uint16 public constant DRIFT_RELAXATION_BPS_PER_PERIOD = 500; // +5% per 6h of staleness
    /// @dev The ceiling that widening stops at. At 100% any sqrtPrice within 2x of the checkpoint is
    /// accepted, which is where the guard stops meaning anything; it is reached after ~5 days of a
    /// vault that cannot execute, by which point the alternative is a 48-hour governance action.
    uint16 public constant MAX_DRIFT_TOLERANCE_BPS = 10_000; // 100%
    /// @dev EMA weight given to a fresh spot observation when updating the rolling checkpoint.
    uint16 public constant CHECKPOINT_ALPHA_BPS = 2_000; // 20%
    uint32 public constant COOLDOWN_SECONDS = 6 hours;

    enum RouteKind {
        None,
        V4,
        V3
    }

    struct Route {
        RouteKind kind;
        PoolKey key; // v4 only
        address v3Pool; // v3 only
        /// @dev Whether `asset` is the lower-sorted side of the pair - currency0 for a v4 route, token0
        /// for a v3 route. Same underlying concept in both cases.
        bool assetIsCurrency0;
        bool exists;
    }

    /// @custom:storage-location erc7201:archemist.storage.BuybackVault
    struct BuybackVaultStorage {
        address locker;
        address pairRegistry;
        mapping(address asset => Route) routes;
        mapping(address asset => uint160) referenceSqrtPriceX96;
        mapping(address asset => uint64) lastExecuteAt;
        /// @dev When `referenceSqrtPriceX96[asset]` was last written. Appended in the drift-ratchet fix;
        /// zero for any checkpoint written before that, which reads as "stale" and so relaxes rather
        /// than tightens - the safe direction for a value that defaults to zero.
        mapping(address asset => uint64) checkpointAt;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("archemist.storage.BuybackVault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant BUYBACK_VAULT_STORAGE = 0x19cb286284977180c0c895a47c4910fab1fade273d58b8bb41971310be02aa00;

    /// @dev Per-swap scratch, read back by `uniswapV3SwapCallback`. Transient: no storage slot, cleared
    /// at the end of the transaction, and it is also the guard that makes an unsolicited callback
    /// impossible (`_activeV3Pool` must equal `msg.sender`).
    bytes32 private constant ACTIVE_ASSET_SLOT = keccak256("archemist.transient.Vault.activeAsset");
    bytes32 private constant ACTIVE_POOL_SLOT = keccak256("archemist.transient.Vault.activePool");
    bytes32 private constant ACTIVE_AMOUNT_IN_SLOT = keccak256("archemist.transient.Vault.activeAmountIn");
    bytes32 private constant ACTIVE_MIN_OUT_SLOT = keccak256("archemist.transient.Vault.activeMinOut");
    bytes32 private constant ACTIVE_ZERO_FOR_ONE_SLOT = keccak256("archemist.transient.Vault.activeZeroForOne");
    bytes32 private constant ACTIVE_UNLOCK_PENDING_SLOT = keccak256("archemist.transient.Vault.unlockPending");

    IPoolManager public immutable POOL_MANAGER;
    address public immutable ARCH;
    address public immutable LINKED_USDC;
    IUniswapV3FactoryMinimal public immutable UNISWAP_V3_FACTORY;
    uint256 public immutable EXPECTED_CHAIN_ID;

    event RouteResolved(
        address indexed asset, address indexed counterpart, address indexed pool, bool assetIsCurrency0
    );
    event BuybackExecuted(address indexed asset, uint256 amountIn, uint256 archBurned);
    event CheckpointReset(address indexed asset, uint160 clearedPrice);

    error InvalidAddress();
    error InvalidChain(uint256 actual, uint256 expected);
    error NoRoute(address asset);
    error InvalidRoute(address asset, address pool);
    error CooldownActive(uint64 readyAt);
    error NothingToBuy();
    error PriceDriftTooLarge(uint160 spot, uint160 checkpoint);
    error CheckpointAlreadyClear(address asset);
    error UnexpectedCallback();
    error TransferFailed();

    constructor(
        IPoolManager poolManager_,
        address arch_,
        address linkedUsdc_,
        address uniswapV3Factory_,
        uint256 expectedChainId_
    ) {
        POOL_MANAGER = poolManager_;
        ARCH = arch_;
        LINKED_USDC = linkedUsdc_;
        UNISWAP_V3_FACTORY = IUniswapV3FactoryMinimal(uniswapV3Factory_);
        EXPECTED_CHAIN_ID = expectedChainId_;
    }

    function initialize(address owner_, address locker_, address pairRegistry_) external initializer {
        if (block.chainid != EXPECTED_CHAIN_ID) revert InvalidChain(block.chainid, EXPECTED_CHAIN_ID);
        if (
            ARCH == address(0) || LINKED_USDC == address(0) || address(UNISWAP_V3_FACTORY) == address(0)
                || address(POOL_MANAGER) == address(0) || locker_ == address(0) || pairRegistry_ == address(0)
        ) revert InvalidAddress();
        if (ARCH == LINKED_USDC) revert InvalidAddress();
        if (
            locker_.code.length == 0 || pairRegistry_.code.length == 0 || address(UNISWAP_V3_FACTORY).code.length == 0
                || address(POOL_MANAGER).code.length == 0
        ) revert InvalidAddress();
        __ArchemistUpgradeable_init(owner_);
        BuybackVaultStorage storage $ = _s();
        $.locker = locker_;
        $.pairRegistry = pairRegistry_;
    }

    function LOCKER() public view returns (address) {
        return _s().locker;
    }

    function PAIR_REGISTRY() public view returns (IArchemistPairRegistry) {
        return IArchemistPairRegistry(_s().pairRegistry);
    }

    function referenceSqrtPriceX96(address asset) external view returns (uint160) {
        return _s().referenceSqrtPriceX96[asset];
    }

    function lastExecuteAt(address asset) external view returns (uint64) {
        return _s().lastExecuteAt[asset];
    }

    function getRoute(address asset)
        external
        view
        returns (RouteKind kind, PoolKey memory key, address v3Pool, bool assetIsCurrency0, bool exists)
    {
        Route memory route = _s().routes[asset];
        return (route.kind, route.key, route.v3Pool, route.assetIsCurrency0, route.exists);
    }

    /// @notice Permissionless. Pulls this vault's claimable balance of `asset` from the locker, swaps up
    /// to MAX_EPOCH_BPS of the resulting balance toward ARCH - directly if `asset` is LINKED_USDC, via an
    /// automatic LINKED_USDC intermediate hop otherwise - and burns what it receives to `ARCH_SINK`.
    /// Reverts (does not silently no-op) if there is no route for either hop, the cooldown has not
    /// elapsed, there is nothing to buy, or either hop's spot price has drifted too far from its own
    /// rolling checkpoint.
    function execute(address asset) external nonReentrant returns (uint256 archBurned) {
        // Native is not a two-hop asset - it IS LINKED_USDC, just viewed through a different decimal
        // scale. Every step below operates on `swapAsset`; only the locker claim uses the original
        // `asset`, since that is the key native fees are credited under.
        address swapAsset = asset == address(0) ? LINKED_USDC : asset;
        BuybackVaultStorage storage $ = _s();

        // ARCH needs no route: it is already the thing this vault exists to burn.
        //
        // Every non-USDC asset is routed to LINKED_USDC for hop 1 and LINKED_USDC back to ARCH for
        // hop 2, so without this branch `execute(ARCH)` would put both legs on the same pool and sell
        // ARCH to buy back less ARCH. Unreachable while ARCH is not a listed quote, but it was only ever
        // one timelocked `addPair` away, and refusing instead of burning would have stranded the fees -
        // this contract has no withdrawal path by design.
        if (swapAsset == ARCH) return _burnDirectly(asset, $);

        Route memory hop1 = _resolveRoute(swapAsset);
        uint64 lastExecute = $.lastExecuteAt[swapAsset];
        if (lastExecute != 0) {
            uint64 readyAt = lastExecute + COOLDOWN_SECONDS;
            // The cooldown window is intentionally timestamp-based (hours-scale, not sensitive to the
            // seconds-level drift a validator could exploit).
            // forge-lint: disable-next-line(block-timestamp)
            if (block.timestamp < readyAt) revert CooldownActive(readyAt);
        }

        // Both hops are cleared BEFORE anything is claimed or swapped. This call is made from inside a
        // trader's swap, on their gas, and hop 2 is shared by every asset - so a tripped hop-2 guard
        // used to charge every trader for a locker claim and a full hop-1 swap before reverting. Now a
        // doomed attempt costs two price reads.
        //
        // "Two price reads" is the cost, not the whole story: `_resolveRoute` caches a route the first
        // time it validates one, so the very first call for an asset does write. Every call after it,
        // including every doomed one, is the read-only path described above.
        bool twoHop = swapAsset != LINKED_USDC;
        Route memory hop2;
        uint160 hop1Spot = _assertDriftWithinTolerance(swapAsset, hop1);
        uint160 hop2Spot;
        if (twoHop) {
            hop2 = _resolveRoute(LINKED_USDC);
            // Hop 1 trades `asset` against LINKED_USDC and hop 2 trades LINKED_USDC against ARCH, so
            // executing hop 1 does not move hop 2's pool: reading its price up front is sound.
            hop2Spot = _assertDriftWithinTolerance(LINKED_USDC, hop2);
        }

        uint256 pending = IBuybackVaultLocker($.locker).claimable(address(this), asset);
        if (pending > 0) IBuybackVaultLocker($.locker).claim(asset, address(this));

        uint256 balance = _balanceOf(swapAsset);
        if (balance == 0) revert NothingToBuy();
        uint256 amountIn = balance * MAX_EPOCH_BPS / BPS;
        if (amountIn == 0) amountIn = balance;

        uint256 minOut1 = _minOutFromSqrtPrice(amountIn, hop1Spot, hop1.assetIsCurrency0);
        uint256 hop1Out = _swap(swapAsset, hop1, amountIn, minOut1);
        // forge-lint: disable-next-line(block-timestamp)
        $.lastExecuteAt[swapAsset] = uint64(block.timestamp);
        _commitCheckpoint(swapAsset, hop1Spot);

        if (!twoHop) {
            archBurned = hop1Out;
        } else {
            // Second, unthrottled hop: LINKED_USDC -> ARCH. Its own price-drift check already ran above
            // (against its own independent checkpoint); it is just not separately cooldown/epoch-capped,
            // because its amount is already fully bounded by hop1's epoch cap.
            uint256 minOut2 = _minOutFromSqrtPrice(hop1Out, hop2Spot, hop2.assetIsCurrency0);
            archBurned = _swap(LINKED_USDC, hop2, hop1Out, minOut2);
            _commitCheckpoint(LINKED_USDC, hop2Spot);
        }

        _transferOut(ARCH, ARCH_SINK, archBurned);
        emit BuybackExecuted(asset, amountIn, archBurned);
    }

    /// @dev The ARCH branch of `execute`: claim, then burn the epoch's slice outright. Same cooldown and
    /// same `MAX_EPOCH_BPS` cap as any other asset, so the only thing that differs is that no swap - and
    /// therefore no route, no drift checkpoint and no slippage floor - is involved at all.
    function _burnDirectly(address asset, BuybackVaultStorage storage $) private returns (uint256 archBurned) {
        uint64 lastExecute = $.lastExecuteAt[ARCH];
        if (lastExecute != 0) {
            uint64 readyAt = lastExecute + COOLDOWN_SECONDS;
            // forge-lint: disable-next-line(block-timestamp)
            if (block.timestamp < readyAt) revert CooldownActive(readyAt);
        }

        uint256 pending = IBuybackVaultLocker($.locker).claimable(address(this), asset);
        if (pending > 0) IBuybackVaultLocker($.locker).claim(asset, address(this));

        uint256 balance = _balanceOf(ARCH);
        if (balance == 0) revert NothingToBuy();
        archBurned = balance * MAX_EPOCH_BPS / BPS;
        if (archBurned == 0) archBurned = balance;

        // forge-lint: disable-next-line(block-timestamp)
        $.lastExecuteAt[ARCH] = uint64(block.timestamp);
        _transferOut(ARCH, ARCH_SINK, archBurned);
        emit BuybackExecuted(asset, archBurned, archBurned);
    }

    /// @dev LINKED_USDC's own route always targets ARCH (single hop); every other asset's route always
    /// targets LINKED_USDC (the first hop of the chain). Never asset-configurable, by design.
    ///
    /// ARCH itself is handled before this is ever reached - see `execute`. Without that, listing ARCH
    /// as a quote pair would map it to LINKED_USDC for hop 1 and back to ARCH for hop 2, both legs on
    /// the same pool: the vault would sell ARCH to buy back less ARCH, and the premise behind reading
    /// `hop2Spot` before hop 1 executes (that hop 1 cannot move hop 2's pool) would be false.
    function _counterpartFor(address asset) private view returns (address) {
        return asset == LINKED_USDC ? ARCH : LINKED_USDC;
    }

    /// @notice Resolves the route for `asset` from `PairRegistry.getPair(asset).buybackRoute`, validates
    /// it against the canonical v3 factory, and caches it permanently on first successful use.
    /// @dev The cache is what makes a route immutable once real money has flowed through it: a later
    /// `updatePair` can point the registry at a different pool, and this vault will keep using the one
    /// it first validated. Curation of *future* behaviour, never a lever over what is already running -
    /// the same rule the hook registry follows.
    function _resolveRoute(address asset) private returns (Route memory route) {
        BuybackVaultStorage storage $ = _s();
        route = $.routes[asset];
        if (route.exists) return route;

        address counterpart = _counterpartFor(asset);
        // getPair reverts PairNotRegistered for an asset the registry has never heard of at all (never
        // a real launch quote) - collapse that into the same NoRoute this function already returns for
        // "registered, but no buybackRoute set yet", so callers see one consistent failure mode.
        PairConfig memory config;
        try IArchemistPairRegistry($.pairRegistry).getPair(asset) returns (PairConfig memory c) {
            config = c;
        } catch {
            revert NoRoute(asset);
        }

        if (config.buybackRouteIsV4) {
            route = _v4Route(asset, counterpart, config);
        } else {
            if (config.buybackRoute == address(0)) revert NoRoute(asset);
            bool assetIsToken0 = _validateV3Route(asset, counterpart, config);
            PoolKey memory emptyKey;
            route = Route({
                kind: RouteKind.V3,
                key: emptyKey,
                v3Pool: config.buybackRoute,
                assetIsCurrency0: assetIsToken0,
                exists: true
            });
        }
        $.routes[asset] = route;
        emit RouteResolved(asset, counterpart, route.v3Pool, route.assetIsCurrency0);
    }

    /// @dev A v4 route has no address to configure and therefore nothing to spoof: the pool IS its key,
    /// PoolManager custodies every pool, and the key here is built entirely from registry data plus the
    /// asset's fixed counterpart. `hooks` is pinned to `address(0)` so a buyback can never be routed
    /// through a hooked pool that could interfere with its own swap. All that is left to check is that
    /// the pool actually exists and is initialized.
    function _v4Route(address asset, address counterpart, PairConfig memory config)
        private
        view
        returns (Route memory route)
    {
        if (config.buybackRoute != address(0)) revert InvalidRoute(asset, config.buybackRoute);
        if (config.buybackRouteTickSpacing <= 0) revert InvalidRoute(asset, address(0));
        bool assetIsCurrency0 = asset < counterpart;
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(assetIsCurrency0 ? asset : counterpart),
            currency1: Currency.wrap(assetIsCurrency0 ? counterpart : asset),
            fee: config.buybackRouteFee,
            tickSpacing: config.buybackRouteTickSpacing,
            hooks: IHooks(address(0))
        });
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(key.toId());
        if (sqrtPriceX96 == 0) revert NoRoute(asset);
        route = Route({
            kind: RouteKind.V4, key: key, v3Pool: address(0), assetIsCurrency0: assetIsCurrency0, exists: true
        });
    }

    /// @dev The check that closes the "route into a pool I control" hole on the v3 side. Confirming the
    /// pool holds the right two tokens is not enough - anyone can deploy a contract that says it does.
    /// The pool must be the one the canonical Uniswap v3 factory itself returns for that exact pair and
    /// fee tier, so it is by construction a real pool with real, public liquidity anyone can arbitrage.
    function _validateV3Route(address asset, address counterpart, PairConfig memory config)
        private
        view
        returns (bool assetIsToken0)
    {
        address pool = config.buybackRoute;
        if (pool.code.length == 0) revert InvalidRoute(asset, pool);
        address token0 = IUniswapV3PoolMinimal(pool).token0();
        address token1 = IUniswapV3PoolMinimal(pool).token1();
        assetIsToken0 = token0 == asset;
        if (!assetIsToken0 && token1 != asset) revert InvalidRoute(asset, pool);
        if (!assetIsToken0 && token0 != counterpart) revert InvalidRoute(asset, pool);
        if (assetIsToken0 && token1 != counterpart) revert InvalidRoute(asset, pool);
        if (UNISWAP_V3_FACTORY.getPool(asset, counterpart, IUniswapV3PoolMinimal(pool).fee()) != pool) {
            revert InvalidRoute(asset, pool);
        }
    }

    /// @notice How far `asset`'s spot sqrtPrice may currently sit from its checkpoint, in bps.
    ///
    /// `MAX_SQRT_PRICE_DRIFT_BPS` while the checkpoint is fresh, widening by
    /// `DRIFT_RELAXATION_BPS_PER_PERIOD` for every full `COOLDOWN_SECONDS` since it was last written,
    /// up to `MAX_DRIFT_TOLERANCE_BPS`.
    ///
    /// ## Why this is not a fixed number
    ///
    /// The checkpoint is only written by a *successful* `execute`. With a fixed tolerance that makes the
    /// guard a one-way ratchet: the moment spot moves more than 5% away, every future `execute` reverts,
    /// which writes no checkpoint, which keeps it reverting - permanently, on nothing worse than an
    /// ordinary market move. It is not hypothetical; an earlier deployment's vault stalled for two days
    /// this way, and the only remedy would have been a 48-hour timelocked upgrade, for a guard tripping
    /// on a price doing what prices do. Worse, hop 2 (`LINKED_USDC -> ARCH`) is shared by every asset, so
    /// one stale USDC checkpoint stops the buyback for *all* of them.
    ///
    /// Relaxation makes it self-healing. The property being traded away is stated plainly rather than
    /// papered over: after a long silence the guard is looser, so a manipulated spot has a wider band to
    /// hide in. What bounds that is everything around it - `execute` runs at most once per
    /// `COOLDOWN_SECONDS` per asset and swaps at most `MAX_EPOCH_BPS` of the balance, so the exposure is
    /// a slice of accrued fees on one asset, once per six hours. Within a single cooldown window the
    /// tolerance is exactly what it always was. A permanently dead buyback is the worse failure.
    function driftToleranceBps(address asset) public view returns (uint256) {
        uint64 writtenAt = _s().checkpointAt[asset];
        // A checkpoint written before this field existed reads as slot zero. Treating that as maximally
        // stale is the safe default for a value that cannot be told apart from "never written".
        if (writtenAt == 0) return MAX_DRIFT_TOLERANCE_BPS;
        // Hours-scale, so seconds-level validator drift is irrelevant.
        // forge-lint: disable-next-line(block-timestamp)
        uint256 periods = (block.timestamp - writtenAt) / COOLDOWN_SECONDS;
        uint256 tolerance = uint256(MAX_SQRT_PRICE_DRIFT_BPS) + periods * DRIFT_RELAXATION_BPS_PER_PERIOD;
        return tolerance > MAX_DRIFT_TOLERANCE_BPS ? MAX_DRIFT_TOLERANCE_BPS : tolerance;
    }

    /// @notice The rolling checkpoint for `asset`, and when it was last written.
    function checkpointOf(address asset) external view returns (uint160 sqrtPriceX96, uint64 writtenAt) {
        BuybackVaultStorage storage $ = _s();
        return ($.referenceSqrtPriceX96[asset], $.checkpointAt[asset]);
    }

    /// @notice Clears `asset`'s drift checkpoint, so the next `execute` reseeds it from spot.
    ///
    /// An escape hatch in the one shape that cannot be abused: it moves no funds, chooses no route, and its only effect is on a guard whose
    /// failure mode is refusing to run. The owner is the `TimelockController`, so calling it is public
    /// 48 hours in advance - which also means it can never be *timed* to a manipulation, the one thing
    /// that would make reseeding dangerous. It is strictly weaker than the upgrade the owner already
    /// has, and exists so that recovering from a tripped guard does not require redeploying the vault.
    ///
    /// Ordinarily unnecessary: `driftToleranceBps` heals this on its own within days.
    function resetCheckpoint(address asset) external onlyOwner {
        BuybackVaultStorage storage $ = _s();
        uint160 cleared = $.referenceSqrtPriceX96[asset];
        if (cleared == 0) revert CheckpointAlreadyClear(asset);
        $.referenceSqrtPriceX96[asset] = 0;
        $.checkpointAt[asset] = 0;
        emit CheckpointReset(asset, cleared);
    }

    /// @dev Reads `asset`'s spot price and reverts if it sits outside `driftToleranceBps` of the rolling
    /// checkpoint. **Writes nothing** - the checkpoint is committed separately, by `_commitCheckpoint`,
    /// only once every hop is known to be good.
    ///
    /// That separation is the point. `execute` used to check hop 1, swap hop 1, then check hop 2 and
    /// revert - so with hop 2 tripped, every trader whose buy crossed the cooldown boundary paid for a
    /// locker claim and a full swap before the attempt died, out of their own gas. Now both hops are
    /// cleared before anything is claimed or swapped, and a doomed attempt costs two price reads.
    ///
    /// Shared between hop1 (asset -> LINKED_USDC) and hop2 (LINKED_USDC -> ARCH); each hop's `asset`
    /// argument is that hop's own input currency, so each gets its own independent checkpoint.
    function _assertDriftWithinTolerance(address asset, Route memory route)
        private
        view
        returns (uint160 spotSqrtPriceX96)
    {
        spotSqrtPriceX96 = _spotSqrtPriceX96(route);
        uint160 checkpointPrice = _s().referenceSqrtPriceX96[asset];
        if (checkpointPrice == 0) return spotSqrtPriceX96;

        uint160 diff = spotSqrtPriceX96 > checkpointPrice
            ? spotSqrtPriceX96 - checkpointPrice
            : checkpointPrice - spotSqrtPriceX96;
        if (uint256(diff) * BPS > uint256(checkpointPrice) * driftToleranceBps(asset)) {
            revert PriceDriftTooLarge(spotSqrtPriceX96, checkpointPrice);
        }
    }

    /// @dev Moves `asset`'s checkpoint toward the observed spot by `CHECKPOINT_ALPHA_BPS`, and records
    /// when. Called only after every hop has passed, so a reverted attempt leaves the checkpoint alone.
    function _commitCheckpoint(address asset, uint160 spotSqrtPriceX96) private {
        BuybackVaultStorage storage $ = _s();
        uint160 checkpointPrice = $.referenceSqrtPriceX96[asset];
        $.referenceSqrtPriceX96[asset] = checkpointPrice == 0
            ? spotSqrtPriceX96
            : uint160(
                (uint256(checkpointPrice)
                        * (BPS - CHECKPOINT_ALPHA_BPS)
                        + uint256(spotSqrtPriceX96)
                        * CHECKPOINT_ALPHA_BPS) / BPS
            );
        // forge-lint: disable-next-line(block-timestamp)
        $.checkpointAt[asset] = uint64(block.timestamp);
    }

    /// @dev Uniswap v3's own swap callback - called synchronously, from inside `pool.swap(...)`, by
    /// whichever pool this vault is actively swapping through. The output token has already been sent to
    /// this vault by the time this fires; the only job here is to pay the pool the input token it is
    /// owed. Guarded by the transient `_activeV3Pool`, so only the pool this vault itself just called
    /// can invoke it - an arbitrary contract calling this function directly is rejected.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        address activePool = address(uint160(_tload(ACTIVE_POOL_SLOT)));
        if (activePool == address(0) || msg.sender != activePool) revert UnexpectedCallback();
        // Safe: a canonical, unmodified Uniswap v3 pool guarantees exactly one of the two deltas is
        // positive (what the pool is owed) for any swap against nonzero liquidity - this callback only
        // ever fires synchronously from inside the pool.swap() call this vault itself just made, on the
        // exact pool the canonical factory returned for this pair.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amountOwed = amount0Delta > 0 ? uint256(amount0Delta) : uint256(amount1Delta);
        _transferOut(address(uint160(_tload(ACTIVE_ASSET_SLOT))), msg.sender, amountOwed);
    }

    function _spotSqrtPriceX96(Route memory route) private view returns (uint160 sqrtPriceX96) {
        if (route.kind == RouteKind.V3) {
            (sqrtPriceX96,,,,,,) = IUniswapV3PoolMinimal(route.v3Pool).slot0();
        } else {
            (sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(route.key.toId());
        }
    }

    function _swap(address asset, Route memory route, uint256 amountIn, uint256 minOut)
        private
        returns (uint256 amountOut)
    {
        _tstore(ACTIVE_ASSET_SLOT, uint256(uint160(asset)));
        _tstore(ACTIVE_AMOUNT_IN_SLOT, amountIn);
        _tstore(ACTIVE_MIN_OUT_SLOT, minOut);
        _tstore(ACTIVE_ZERO_FOR_ONE_SLOT, route.assetIsCurrency0 ? 1 : 0);

        if (route.kind == RouteKind.V3) {
            // No PoolManager or unlock involvement at all - v3's swap is a plain synchronous call that
            // calls back into `uniswapV3SwapCallback` before it returns.
            amountOut = _executeV3Swap(route.v3Pool, amountIn, minOut, route.assetIsCurrency0);
        } else if (TransientStateLibrary.isUnlocked(POOL_MANAGER)) {
            // Already inside someone else's active unlock frame - which is the normal case, since the
            // hook triggers this from mid-swap. `unlock()` cannot be called again there
            // (`AlreadyUnlocked()`), but `swap`/`settle`/`take` only require the manager to BE unlocked,
            // not that this contract is the one that unlocked it, so run the swap inline.
            amountOut = _executeV4Swap(route.key, amountIn, minOut, route.assetIsCurrency0);
        } else {
            _tstore(ACTIVE_UNLOCK_PENDING_SLOT, 1);
            bytes memory result = POOL_MANAGER.unlock(abi.encode(route.key, amountIn, minOut, route.assetIsCurrency0));
            _tstore(ACTIVE_UNLOCK_PENDING_SLOT, 0);
            amountOut = abi.decode(result, (uint256));
        }

        _tstore(ACTIVE_ASSET_SLOT, 0);
        _tstore(ACTIVE_AMOUNT_IN_SLOT, 0);
        _tstore(ACTIVE_MIN_OUT_SLOT, 0);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert UnexpectedCallback();
        if (_tload(ACTIVE_UNLOCK_PENDING_SLOT) == 0) revert UnexpectedCallback();
        (PoolKey memory key, uint256 amountIn, uint256 minOut, bool assetIsCurrency0) =
            abi.decode(data, (PoolKey, uint256, uint256, bool));
        return abi.encode(_executeV4Swap(key, amountIn, minOut, assetIsCurrency0));
    }

    function _executeV4Swap(PoolKey memory key, uint256 amountIn, uint256 minOut, bool assetIsCurrency0)
        private
        returns (uint256 amountOut)
    {
        bool zeroForOne = assetIsCurrency0;
        BalanceDelta delta = POOL_MANAGER.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -amountIn.toInt256(),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            bytes("")
        );

        int128 inDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 outDelta = zeroForOne ? delta.amount1() : delta.amount0();
        if (inDelta >= 0 || outDelta <= 0) revert NothingToBuy();
        // Safe: outDelta was just checked > 0, so its uint128 bit pattern is a plain positive value.
        // forge-lint: disable-next-line(unsafe-typecast)
        amountOut = uint256(uint128(outDelta));
        if (amountOut < minOut) revert NothingToBuy();

        // Safe: inDelta was just checked < 0 and is int128, so -inDelta fits uint128 exactly (it cannot
        // be int128.min: that would need an in-pool balance change of 2^127, far beyond amountIn, which
        // is bounded by this vault's own balance).
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amountPaid = uint256(uint128(-inDelta));
        _settle(assetIsCurrency0 ? key.currency0 : key.currency1, amountPaid);
        POOL_MANAGER.take(assetIsCurrency0 ? key.currency1 : key.currency0, address(this), amountOut);
    }

    function _executeV3Swap(address pool, uint256 amountIn, uint256 minOut, bool assetIsCurrency0)
        private
        returns (uint256 amountOut)
    {
        bool zeroForOne = assetIsCurrency0;
        _tstore(ACTIVE_POOL_SLOT, uint256(uint160(pool)));
        (int256 amount0, int256 amount1) = IUniswapV3PoolMinimal(pool)
            .swap(
                address(this),
                zeroForOne,
                // v3 uses the OPPOSITE sign convention from v4: positive amountSpecified is exact input.
                // Safe: amountIn is bounded by MAX_EPOCH_BPS of this vault's own token balance, far below
                // int256's range.
                // forge-lint: disable-next-line(unsafe-typecast)
                int256(amountIn),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
                bytes("")
            );
        _tstore(ACTIVE_POOL_SLOT, 0);

        int256 outDelta = zeroForOne ? amount1 : amount0;
        int256 inDelta = zeroForOne ? amount0 : amount1;
        // inDelta > 0 (we owe the pool) and outDelta < 0 (the pool paid us) is the only valid outcome
        // of a successful input -> output swap.
        if (inDelta <= 0 || outDelta >= 0) revert NothingToBuy();
        // Safe: outDelta was just checked < 0 and is int256, so -outDelta fits uint256 exactly (it
        // cannot be int256.min: that would need a pool balance change far beyond any real liquidity).
        // forge-lint: disable-next-line(unsafe-typecast)
        amountOut = uint256(-outDelta);
        if (amountOut < minOut) revert NothingToBuy();
    }

    function _settle(Currency currency, uint256 amount) private {
        if (currency.isAddressZero()) {
            POOL_MANAGER.settle{ value: amount }();
        } else {
            POOL_MANAGER.sync(currency);
            _transferOut(Currency.unwrap(currency), address(POOL_MANAGER), amount);
            POOL_MANAGER.settle();
        }
    }

    function _transferOut(address token, address to, uint256 amount) private {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        if (!ok || (ret.length != 0 && (ret.length < 32 || !abi.decode(ret, (bool))))) revert TransferFailed();
    }

    function _balanceOf(address asset) private view returns (uint256) {
        if (asset == address(0)) return address(this).balance;
        (bool ok, bytes memory ret) = asset.staticcall(abi.encodeWithSignature("balanceOf(address)", address(this)));
        if (!ok || ret.length < 32) return 0;
        return abi.decode(ret, (uint256));
    }

    /// @dev Spot-implied output for `amountIn` of the input side, less SWAP_SLIPPAGE_BPS - the swap's own
    /// same-transaction slippage floor. Uses the same split-sqrt technique as InitialPriceMath to avoid
    /// overflowing on an extreme price ratio (see that library for the full derivation).
    function _minOutFromSqrtPrice(uint256 amountIn, uint160 sqrtPriceX96, bool assetIsCurrency0)
        private
        pure
        returns (uint256)
    {
        // Applied in two halves of 2^96 each, never squaring the price.
        //
        // The previous version computed `priceX192 = mulDiv(sqrtPriceX96, sqrtPriceX96, 1)` first, and
        // its comment described the split technique it was not using. `mulDiv` reverts when the result
        // exceeds 2^256, so that squaring reverts for any `sqrtPriceX96 >= 2^128` - a raw price of
        // 2^64, which is not exotic: it is what a 6-decimal currency0 against a very cheap 18-decimal
        // currency1 looks like, exactly the shape a launch quoted in linked USDC can take. The whole
        // buyback for that asset would have reverted, permanently, on arithmetic.
        //
        // Splitting keeps every intermediate bounded by `amountIn * 2^64` instead.
        uint256 spotOut = assetIsCurrency0
            ? FullMath.mulDiv(FullMath.mulDiv(amountIn, sqrtPriceX96, 1 << 96), sqrtPriceX96, 1 << 96)
            : FullMath.mulDiv(FullMath.mulDiv(amountIn, 1 << 96, sqrtPriceX96), 1 << 96, sqrtPriceX96);
        return spotOut * (BPS - SWAP_SLIPPAGE_BPS) / BPS;
    }

    /// @inheritdoc ArchemistUpgradeable
    function ARCHEMIST_KIND() public pure override returns (bytes32) {
        return keccak256("archemist.kind.BuybackVault");
    }

    function _checkImplementation(address newImplementation) internal view override {
        ArchemistBuybackVault impl = ArchemistBuybackVault(payable(newImplementation));
        if (
            impl.ARCH() != ARCH || impl.LINKED_USDC() != LINKED_USDC
                || address(impl.UNISWAP_V3_FACTORY()) != address(UNISWAP_V3_FACTORY)
                // The launcher and the locker compare this too. A vault pointed at a
                // different PoolManager would take and settle against a venue holding none of its money.
                || address(impl.POOL_MANAGER()) != address(POOL_MANAGER)
                || impl.EXPECTED_CHAIN_ID() != EXPECTED_CHAIN_ID
        ) revert ImplementationMismatch();
    }

    function _s() private pure returns (BuybackVaultStorage storage $) {
        assembly ("memory-safe") {
            $.slot := BUYBACK_VAULT_STORAGE
        }
    }

    function _tstore(bytes32 slot, uint256 value) private {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    function _tload(bytes32 slot) private view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    receive() external payable {
        // The PoolManager pays out during a v4 buyback swap's own `take()`; the locker pays out when
        // this vault claims its accrued native-currency fee share. Nothing else has any reason to send
        // native currency here, and nothing can withdraw it - it is only ever spent, as LINKED_USDC, on
        // buying ARCH to burn.
        if (msg.sender != address(POOL_MANAGER) && msg.sender != _s().locker) revert UnexpectedCallback();
    }
}
