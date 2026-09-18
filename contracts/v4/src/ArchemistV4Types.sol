// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice Values that ArchemistV4Hook and ArchemistV4Launcher must agree on exactly. They used to be
/// declared separately in both contracts; changing one without the other silently bricked every launch
/// (the hook's `lockConfig` rejects a config whose baseHookFee/window bounds don't match its own), so
/// they live here now and both contracts read them from this one place.
library ArchemistV4Constants {
    uint256 internal constant INITIAL_SUPPLY = 1_000_000_000 ether;
    /// @dev The permanent post-window fee floor, and the only fee a sell ever pays. Not creator-settable.
    uint24 internal constant BASE_HOOK_FEE = 10_000; // 1%
    uint24 internal constant MAX_START_HOOK_FEE = 990_000; // 99%
    uint32 internal constant MAX_WINDOW_SECONDS = 120;
    uint16 internal constant BPS = 10_000;
    /// @dev Ceiling on the gas one buyback attempt may take out of a trader's transaction. Only a
    /// ceiling - the attempt is handed whatever is spare below it, so raising this never makes a
    /// buyback less likely to fire, it only bounds the worst case.
    ///
    /// `test_buybackStipendCoversAMeasuredTwoHopExecute` measures a full two-hop `execute` through the
    /// proxies - locker claim, v4 hop, v3 hop, burn - and logs what it cost. Against the suite's mock
    /// pools that is well under 100k, so the headroom here is large; but a mock pool transfers where a
    /// real one walks ticks, so treat that figure as a floor, not an estimate. The number this constant
    /// actually has to survive is a real Arc pool under real liquidity, which only PD-08/PD-09 on a live
    /// deployment can settle. What the test does establish is that the cost is measured rather than
    /// assumed, and that a regression in it will be seen.
    uint256 internal constant BUYBACK_GAS_STIPEND = 1_500_000;
    /// @dev Gas that must survive the buyback attempt for the swap itself to finish: PoolManager's
    /// delta accounting, then settle/take and the caller's epilogue in its own unlock frame.
    uint256 internal constant SWAP_TAIL_RESERVE = 150_000;
    /// @dev Below this there is no realistic chance of a buyback completing, so the attempt is skipped
    /// rather than started and wasted. Deliberately low: it only has to exclude budgets that could not
    /// even reach the vault's own cooldown check.
    uint256 internal constant BUYBACK_MIN_GAS = 100_000;
}

struct FeeRecipient {
    address admin;
    address payout;
    uint16 bps;
}

struct PairConfig {
    bool enabled;
    uint8 decimals;
    int24 defaultTick;
    int24 minTick;
    int24 maxTick;
    int24 tickSpacing;
    uint16 flags;
    // How the buyback vault reaches ARCH from this quote currency. Two shapes, and NEITHER of them is
    // an address anyone can point anywhere they like:
    //   - Uniswap v3 (`buybackRouteIsV4 == false`): `buybackRoute` is the pool address, and the vault
    //     checks it against the canonical v3 factory - `getPool(asset, counterpart, fee) == pool` -
    //     so it can only ever be the real public pool for that pair and fee tier.
    //   - Uniswap v4 (`buybackRouteIsV4 == true`): `buybackRoute` is unused and must be address(0).
    //     The vault builds the PoolKey itself from {asset, its fixed counterpart, buybackRouteFee,
    //     buybackRouteTickSpacing, hooks: address(0)}. A v4 pool IS its key - `PoolId` is the key's
    //     hash and PoolManager custodies every pool - so there is nothing to spoof, and forcing
    //     `hooks == address(0)` keeps a buyback from ever routing through a hooked pool that could
    //     interfere with the swap.
    address buybackRoute;
    bool buybackRouteIsV4;
    uint24 buybackRouteFee;
    int24 buybackRouteTickSpacing;
    // Creator fee share band for this pair class, in bps of the hook fee. Bounded by the registry's
    // global hard CREATOR_SHARE_MIN/MAX; a launch on this pair must pick creatorShareBps somewhere
    // in [minCreatorBps, maxCreatorBps]. Lets regulated pairs (tokenized equity) be capped lower
    // than plain crypto pairs without a code change.
    uint16 minCreatorBps;
    uint16 maxCreatorBps;
}

/// @notice The anti-snipe curve one launch asks ArchemistV4Hook for, ABI-encoded into
/// `LaunchParams.hookParams`. The launcher passes these through opaquely; the hook decodes them and
/// applies its own bounds (see `ArchemistV4Hook.lockConfig`), so a future hook with a different curve
/// needs no launcher change at all.
struct AntiSnipeParams {
    /// @dev Starting buy fee, decaying quadratically to BASE_HOOK_FEE over `windowSeconds`. Must sit in
    /// [BASE_HOOK_FEE, MAX_START_HOOK_FEE].
    uint24 startHookFee;
    /// @dev Length of the anti-snipe window. Must be in (0, MAX_WINDOW_SECONDS].
    uint32 windowSeconds;
    /// @dev Largest single buy during the window, in bps of INITIAL_SUPPLY. Must be in [1, 10_000].
    uint16 maxBuyBps;
}

struct ArchemistPoolConfig {
    address token;
    address locker;
    bool tokenIsCurrency0;
    Currency quote;
    uint24 baseHookFee;
    uint24 startHookFee;
    uint64 startTime;
    uint64 windowEnd;
    uint16 maxBuyBps;
}
