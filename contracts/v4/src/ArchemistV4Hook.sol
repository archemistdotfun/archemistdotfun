// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { ModifyLiquidityParams, SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";

import { AntiSnipeParams, ArchemistPoolConfig, ArchemistV4Constants } from "./ArchemistV4Types.sol";
import { HookFeeMath } from "./HookFeeMath.sol";
import { IArchemistHook } from "./interfaces/IArchemistHook.sol";
import { IArchemistV4Locker } from "./interfaces/IArchemistV4Locker.sol";

interface IArchemistBuybackVaultExecutable {
    function execute(address asset) external returns (uint256);
}

/// @notice The Archemist launch hook: a quote-only fee taken through v4's return-delta custom accounting,
/// a quadratically decaying anti-snipe start fee on buys, a per-buy cap during the window, and a
/// trading-triggered ARCH buyback.
///
/// **This contract is immutable and has no owner.** That is not an oversight, it is the design. A hook's
/// permission bits are the low 14 bits of its own address and its identity is baked into every
/// `PoolKey` that uses it, so an upgradeable hook could change what it does while its declared
/// permissions stayed frozen - which is why Uniswap's hook-warning taxonomy treats proxy hooks as a
/// dangerous flag and why `hooklist` tracks `upgradeable` as a property. New behaviour therefore means a
/// new hook contract plus one `ArchemistV4Launcher.registerHook` call, not an upgrade. The periphery it
/// pays (launcher, locker, vault, rewards) IS upgradeable, behind a 48-hour public timelock; that is
/// disclosed, not hidden - see `docs/HOOK_DISCLOSURE.md`.
///
/// **The four proxy addresses it points at never change**, which is what makes a permanently immutable
/// hook workable: a new vault or locker implementation is an upgrade behind the same proxy address, so
/// it does not force a new hook.
///
/// Reviewer's short list of everything here that can revert a swap, all of it deliberate and bounded:
/// `ExactOutputBuyBlocked` (buys only, inside the ≤120 s window), `MaxBuyExceeded` (buys only, inside
/// the window), `LiquidityLocked` (third-party `addLiquidity` only, inside the window), and
/// `PartialFillNotAllowed` (only when a caller passes a `sqrtPriceLimit` that stops the swap early on a
/// leg whose fee was already charged - routers pass MIN/MAX, so it does not fire for them). There is no
/// pause, no allowlist, no owner-settable fee, and no path by which the hook holds or moves anyone's
/// funds.
contract ArchemistV4Hook is IHooks, IArchemistHook {
    using PoolIdLibrary for PoolKey;
    using SafeCast for int128;
    using SafeCast for uint256;

    uint24 public constant FEE_DENOMINATOR = HookFeeMath.FEE_DENOMINATOR;
    uint24 public constant BASE_HOOK_FEE = ArchemistV4Constants.BASE_HOOK_FEE;
    uint24 public constant MAX_START_HOOK_FEE = ArchemistV4Constants.MAX_START_HOOK_FEE;
    uint32 public constant MAX_WINDOW_SECONDS = ArchemistV4Constants.MAX_WINDOW_SECONDS;
    uint256 public constant INITIAL_SUPPLY = ArchemistV4Constants.INITIAL_SUPPLY;

    uint256 public constant BUYBACK_GAS_STIPEND = ArchemistV4Constants.BUYBACK_GAS_STIPEND;
    uint256 public constant SWAP_TAIL_RESERVE = ArchemistV4Constants.SWAP_TAIL_RESERVE;
    uint256 public constant BUYBACK_MIN_GAS = ArchemistV4Constants.BUYBACK_MIN_GAS;

    IPoolManager public immutable poolManager;
    address public immutable launcher;
    address public immutable locker;
    /// @dev Immutable rather than looked up from the launcher on every swap. The swap path must never
    /// read another contract's mutable storage; the old `launcher.BUYBACK_VAULT()`
    /// lookup was the one place that did.
    address public immutable BUYBACK_VAULT;

    mapping(PoolId => ArchemistPoolConfig) public poolConfig;

    event ConfigLocked(
        PoolId indexed poolId,
        address indexed token,
        address indexed quote,
        uint24 startHookFee,
        uint64 windowEnd,
        uint16 maxBuyBps
    );
    event SwapFeeCharged(PoolId indexed poolId, address indexed quote, uint256 amount, uint24 feePips, bool isBuy);

    error NotPoolManager();
    error NotLauncher();
    error InvalidConfiguration();
    error ConfigAlreadyLocked();
    error PoolNotConfigured();
    error ExactOutputBuyBlocked();
    error MaxBuyExceeded(uint256 actual, uint256 maximum);
    error LiquidityLocked();
    error PartialFillNotAllowed();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager poolManager_, address launcher_, address locker_, address buybackVault_) {
        if (
            address(poolManager_) == address(0) || launcher_ == address(0) || locker_ == address(0)
                || buybackVault_ == address(0)
        ) {
            revert InvalidConfiguration();
        }
        poolManager = poolManager_;
        launcher = launcher_;
        locker = locker_;
        BUYBACK_VAULT = buybackVault_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.beforeInitialize = true;
        permissions.beforeAddLiquidity = true;
        permissions.beforeSwap = true;
        permissions.afterSwap = true;
        permissions.beforeSwapReturnDelta = true;
        permissions.afterSwapReturnDelta = true;
    }

    /// @notice Locks this pool's fee curve, once, from the launcher, immediately before the pool is
    /// initialized.
    ///
    /// The bounds below used to live in the launcher, which meant a hook with a different fee curve
    /// could not exist without a launcher redeploy. They live here now: the launcher passes `params`
    /// through opaquely and this contract decides what a legal configuration is. A malformed `params`
    /// fails at `abi.decode`, an out-of-range one at `InvalidConfiguration`, and either way the whole
    /// launch transaction reverts before a token is deployed or a pool initialized.
    /// @param params ABI-encoded `AntiSnipeParams`.
    function lockConfig(
        PoolKey calldata key,
        address token,
        Currency quote,
        bool tokenIsCurrency0,
        bytes calldata params
    ) external {
        if (msg.sender != launcher) revert NotLauncher();
        PoolId poolId = key.toId();
        if (poolConfig[poolId].token != address(0)) revert ConfigAlreadyLocked();

        AntiSnipeParams memory anti = abi.decode(params, (AntiSnipeParams));
        if (
            address(key.hooks) != address(this) || key.fee != 0 || token == address(0)
                || anti.startHookFee < BASE_HOOK_FEE || anti.startHookFee > MAX_START_HOOK_FEE
                || anti.windowSeconds == 0 || anti.windowSeconds > MAX_WINDOW_SECONDS || anti.maxBuyBps == 0
                || anti.maxBuyBps > 10_000
        ) revert InvalidConfiguration();

        address currency0 = Currency.unwrap(key.currency0);
        address currency1 = Currency.unwrap(key.currency1);
        bool validOrientation = tokenIsCurrency0
            ? currency0 == token && currency1 == Currency.unwrap(quote)
            : currency1 == token && currency0 == Currency.unwrap(quote);
        if (!validOrientation || Currency.unwrap(quote) == token) revert InvalidConfiguration();

        // The launch timestamp is this contract's own `block.timestamp`, never a launcher-supplied
        // field: config and launch are atomic by construction, so there is nothing to agree about.
        // forge-lint: disable-next-line(block-timestamp)
        uint64 startTime = uint64(block.timestamp);
        ArchemistPoolConfig memory config = ArchemistPoolConfig({
            token: token,
            locker: locker,
            tokenIsCurrency0: tokenIsCurrency0,
            quote: quote,
            baseHookFee: BASE_HOOK_FEE,
            startHookFee: anti.startHookFee,
            startTime: startTime,
            windowEnd: startTime + anti.windowSeconds,
            maxBuyBps: anti.maxBuyBps
        });

        poolConfig[poolId] = config;
        emit ConfigLocked(poolId, token, Currency.unwrap(quote), anti.startHookFee, config.windowEnd, anti.maxBuyBps);
    }

    function currentFee(PoolId poolId) public view returns (uint24 fee) {
        ArchemistPoolConfig storage config = poolConfig[poolId];
        if (config.token == address(0)) revert PoolNotConfigured();
        // The bounded launch window is intentionally timestamp-based.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= config.windowEnd) return config.baseHookFee;

        uint256 duration = config.windowEnd - config.startTime;
        uint256 remaining = config.windowEnd - block.timestamp;
        uint256 excess = config.startHookFee - config.baseHookFee;
        fee = uint24(config.baseHookFee + FullMath.mulDiv(excess, remaining * remaining, duration * duration));
    }

    /// @dev The single place that decides which fee rate applies to a swap. Sells always pay the flat
    /// base rate; buys pay the decaying anti-snipe rate, except the creator's own atomic launch buy,
    /// which pays the base rate because it executes inside the launch transaction itself and so has
    /// nothing to be sniped by. Every call site (beforeSwap, afterSwap, _requireSafeFill) must use this
    /// - three hand-rolled copies of this expression is what once let the fee rate diverge between them.
    function _feePipsFor(PoolId poolId, ArchemistPoolConfig storage config, bool buy, bool creatorBuy)
        private
        view
        returns (uint24)
    {
        if (!buy || creatorBuy) return config.baseHookFee;
        return currentFee(poolId);
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != launcher || poolConfig[key.toId()].token == address(0)) {
            revert InvalidConfiguration();
        }
        return IHooks.beforeInitialize.selector;
    }

    function beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        ArchemistPoolConfig storage config = _config(key.toId());
        // The bounded launch window is intentionally timestamp-based.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < config.windowEnd && sender != locker) revert LiquidityLocked();
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        ArchemistPoolConfig storage config = _config(poolId);
        bool buy = params.zeroForOne != config.tokenIsCurrency0;
        bool exactInput = params.amountSpecified < 0;
        // `sender` here is whoever called PoolManager.swap() directly - the launcher only ever does that
        // once, for the atomic creator buy inside createToken (never elsewhere), so this is an
        // unambiguous, safe signal. Anyone adding a future swap-triggering function to the launcher must
        // keep that invariant true, or this bypass would silently apply there too.
        bool creatorBuy = sender == launcher;

        // The bounded launch window is intentionally timestamp-based.
        // forge-lint: disable-next-line(block-timestamp)
        if (buy && !exactInput && block.timestamp < config.windowEnd) revert ExactOutputBuyBlocked();

        // Quote is the SPECIFIED currency for exact-input buys and exact-output sells - the two cases
        // the hook can charge up-front, before the pool has computed anything.
        if (buy == exactInput) {
            uint256 specified = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
            uint24 feePips = _feePipsFor(poolId, config, buy, creatorBuy);
            // exactInput: `specified` is the trader's whole outlay, fee comes out of it.
            // exactOutput: `specified` is what the trader wants net, fee is grossed up on top.
            uint256 fee =
                exactInput ? HookFeeMath.feeOnGross(specified, feePips) : HookFeeMath.feeOnNet(specified, feePips);
            if (fee != 0) {
                _mintAndRecord(poolId, config.quote, fee, feePips, buy);
                return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
            }
        }

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        PoolId poolId = key.toId();
        ArchemistPoolConfig storage config = _config(poolId);
        bool buy = params.zeroForOne != config.tokenIsCurrency0;
        bool exactInput = params.amountSpecified < 0;
        bool creatorBuy = sender == launcher;
        uint24 feePips = _feePipsFor(poolId, config, buy, creatorBuy);

        _requireSafeFill(config, params, delta, buy, exactInput, feePips);

        // The bounded launch window is intentionally timestamp-based. The creator's own atomic buy is
        // exempt from this cap for the same reason it's exempt from the fee decay above - it's a single,
        // uninterruptible transaction the creator themselves controls, not something snipers could abuse.
        // forge-lint: disable-next-line(block-timestamp)
        if (buy && block.timestamp < config.windowEnd && !creatorBuy) {
            int128 tokenDelta = config.tokenIsCurrency0 ? delta.amount0() : delta.amount1();
            uint256 tokenOutput = tokenDelta > 0 ? tokenDelta.toUint128() : 0;
            uint256 maximum = INITIAL_SUPPLY * config.maxBuyBps / 10_000;
            if (tokenOutput > maximum) revert MaxBuyExceeded(tokenOutput, maximum);
        }

        int128 hookDelta = 0;
        uint256 fee;
        // Quote is the UNSPECIFIED currency for exact-input sells and exact-output buys - only now, with
        // the pool's own delta in hand, is the quote amount known.
        if (buy != exactInput) {
            int128 quoteDelta = config.tokenIsCurrency0 ? delta.amount1() : delta.amount0();
            uint256 quoteAmount = _abs(quoteDelta);
            // A sell's quote delta is the pool's gross payout (fee carved out of it); a buy's is the
            // pool's bare input charge, which excludes the hook's cut, so the fee is grossed up on top.
            // Getting that second case wrong is exactly the error this split prevents.
            fee = buy ? HookFeeMath.feeOnNet(quoteAmount, feePips) : HookFeeMath.feeOnGross(quoteAmount, feePips);
            if (fee != 0) {
                _mintAndRecord(poolId, config.quote, fee, feePips, buy);
                hookDelta = fee.toInt128();
            }
        } else if (buy) {
            // Exact-input buy: the fee was already charged in beforeSwap. Recompute it here (pure math
            // on calldata, no extra storage reads) purely to decide whether this swap earned anything
            // for the buyback to act on.
            fee = HookFeeMath.feeOnGross(uint256(-params.amountSpecified), feePips);
        }

        // BUY funds the ARCH buyback; SELL funds holder rewards instead (credited by the locker, with no
        // swap of its own). So only a buy has anything for the vault to act on here.
        if (buy && fee != 0) _tryTriggerBuyback(Currency.unwrap(config.quote));

        return (IHooks.afterSwap.selector, hookDelta);
    }

    function _requireSafeFill(
        ArchemistPoolConfig storage config,
        SwapParams calldata params,
        BalanceDelta delta,
        bool buy,
        bool exactInput,
        uint24 feePips
    ) private view {
        int128 quoteDelta = config.tokenIsCurrency0 ? delta.amount1() : delta.amount0();

        if (buy && exactInput) {
            uint256 grossInput = uint256(-params.amountSpecified);
            uint256 fee = HookFeeMath.feeOnGross(grossInput, feePips);
            if (quoteDelta >= 0 || _abs(quoteDelta) != grossInput - fee) revert PartialFillNotAllowed();
        } else if (!buy && !exactInput) {
            uint256 requestedOutput = uint256(params.amountSpecified);
            uint256 fee = HookFeeMath.feeOnNet(requestedOutput, feePips);
            if (quoteDelta <= 0 || quoteDelta.toUint128() != requestedOutput + fee) revert PartialFillNotAllowed();
        } else if (buy && !exactInput) {
            int128 tokenDelta = config.tokenIsCurrency0 ? delta.amount0() : delta.amount1();
            if (tokenDelta <= 0 || tokenDelta.toUint128() != uint256(params.amountSpecified)) {
                revert PartialFillNotAllowed();
            }
        }
    }

    function _abs(int128 amount) private pure returns (uint256) {
        int256 widened = amount;
        return uint256(widened < 0 ? -widened : widened);
    }

    function _mintAndRecord(PoolId poolId, Currency quote, uint256 amount, uint24 feePips, bool isBuy) private {
        poolManager.mint(locker, quote.toId(), amount);
        IArchemistV4Locker(locker).recordHookFee(poolId, quote, amount, isBuy);
        emit SwapFeeCharged(poolId, Currency.unwrap(quote), amount, feePips, isBuy);
    }

    /// @dev Fires the buyback vault's own guarded `execute()` after a fee-generating buy, so a buyback
    /// attempt is *triggered* by trading itself (the behavior asked for), while the vault's own
    /// cooldown/epoch-cap/price-drift checks decide whether it actually fires this time.
    ///
    /// The budget is what makes this safe. An explicit `{gas:}` cap is essential: without one, a buyback
    /// that runs out of gas mid-execution leaves this frame holding only the 1/64 EIP-150 remainder -
    /// not enough to finish the trader's own swap - so the try/catch swallows the vault's revert and the
    /// transaction dies anyway. That is not hypothetical: the expensive path only becomes reachable once
    /// every COOLDOWN_SECONDS, so a gas estimate taken during cooldown systematically under-provisions
    /// the one transaction that later crosses the boundary.
    ///
    /// The budget is `whatever is spare above SWAP_TAIL_RESERVE`, capped at the stipend - not a fixed
    /// stipend gated behind a fixed floor. That distinction matters more than it looks: a fixed floor
    /// has to be met *in addition* to the swap's own costs, so a transaction whose gas was estimated
    /// with the buyback included would still fall short of it and skip - and the next estimate, taken
    /// without the buyback, would be lower still. Buybacks would flicker off permanently. Sizing the
    /// budget from what is actually spare makes the estimate self-consistent instead: whatever the
    /// estimator saw succeed, execution can afford too.
    ///
    /// The trader is protected at both ends. SWAP_TAIL_RESERVE is never lent out, so the swap always
    /// has enough left to settle; and if the budget turns out to be too small, the vault simply runs out
    /// inside its own frame and the catch-all absorbs it, along with the ordinary outcomes - cooldown
    /// active, no route configured, nothing to buy, price drifted - none of which are the trader's
    /// problem either.
    function _tryTriggerBuyback(address asset) private {
        uint256 available = gasleft();
        if (available <= SWAP_TAIL_RESERVE) return;
        uint256 budget = available - SWAP_TAIL_RESERVE;
        if (budget > BUYBACK_GAS_STIPEND) budget = BUYBACK_GAS_STIPEND;
        if (budget < BUYBACK_MIN_GAS) return;
        try IArchemistBuybackVaultExecutable(BUYBACK_VAULT).execute{ gas: budget }(asset) { } catch { }
    }

    function _config(PoolId poolId) private view returns (ArchemistPoolConfig storage config) {
        config = poolConfig[poolId];
        if (config.token == address(0)) revert PoolNotConfigured();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external view onlyPoolManager returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.afterDonate.selector;
    }
}
