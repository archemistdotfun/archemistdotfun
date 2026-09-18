// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Converts a creator-supplied target FDV into a pool-ready initial tick, so nobody ever hands
/// the launcher a raw tick directly. Modeled on the pattern competitor launchpads settled on (Clanker's
/// SDK computes its `tickIfToken0IsClanker` from a human market-cap figure client-side, rather than
/// asking the caller for a raw tick with a name that only warns about, but doesn't prevent, orientation
/// mistakes). Here the conversion happens
/// on-chain instead of in a client SDK, so an orientation mistake is structurally impossible rather than
/// merely discouraged - the caller only ever states "I want this FDV in quote's raw units", and the
/// contract derives the correct tick for whichever side the launch token actually landed on.
library InitialPriceMath {
    error TargetFdvZero();

    /// @param targetFdvQuoteRaw Desired fully-diluted value of the entire launch supply, expressed in
    ///        the quote currency's own raw (smallest-unit) representation - e.g. `5_000e6` for a 5,000
    ///        USDC FDV, `5_000 ether` for 5,000 native-USDC-equivalent. Dividing two raw quantities
    ///        (this and totalSupplyRaw) cancels out both tokens' decimals automatically; the caller never
    ///        computes a decimal adjustment by hand.
    /// @param totalSupplyRaw The launch token's total supply in its own raw units (always 18 decimals for
    ///        ArchemistV4Token, i.e. `1_000_000_000 ether`).
    /// @param tokenIsCurrency0 Whether the launch token sorts below the quote currency's address.
    /// @param tickSpacing The pair's tick spacing; the result is always an exact multiple of this.
    /// @return tick The initial tick, rounded so the implied starting price never exceeds
    ///         `targetFdvQuoteRaw / totalSupplyRaw` (i.e. rounded in the creator's favor - the pool never
    ///         opens more expensive than requested, only equal or slightly cheaper due to tick spacing).
    /// @return sqrtPriceX96 `TickMath.getSqrtPriceAtTick(tick)` - the exact value the pool gets
    ///         initialized with, derived from the same rounded tick (not from the unrounded raw price),
    ///         so tick and sqrtPriceX96 can never disagree with each other.
    function computeInitialTick(
        uint256 targetFdvQuoteRaw,
        uint256 totalSupplyRaw,
        bool tokenIsCurrency0,
        int24 tickSpacing
    ) internal pure returns (int24 tick, uint160 sqrtPriceX96) {
        if (targetFdvQuoteRaw == 0) revert TargetFdvZero();

        // Pool price convention is "raw currency1 per raw currency0". When the launch token is
        // currency0, that price is quote-per-token = targetFdvQuoteRaw / totalSupplyRaw. When the quote
        // is currency0 instead, the same economic price is expressed as its reciprocal, token-per-quote.
        uint256 numerator = tokenIsCurrency0 ? targetFdvQuoteRaw : totalSupplyRaw;
        uint256 denominator = tokenIsCurrency0 ? totalSupplyRaw : targetFdvQuoteRaw;

        // sqrtPriceX96 = sqrt(numerator / denominator) * 2^96, computed as sqrt(numerator) * 2^96 /
        // sqrt(denominator) rather than sqrt(numerator * 2^192 / denominator) in one step. The combined
        // form overflows uint256 whenever numerator/denominator exceeds roughly 2^64 (~1.8e19) - a
        // perfectly reachable ratio for a low-FDV launch against a large supply (e.g. SUPPLY=1e27 raw
        // against a sub-$100 FDV already lands past that threshold). Splitting the sqrt keeps every
        // intermediate value well inside 256 bits at the cost of a little precision, which is immaterial
        // once the result gets rounded to a tickSpacing multiple anyway.
        uint160 rawSqrtPriceX96 = uint160(FullMath.mulDiv(_sqrt(numerator), 1 << 96, _sqrt(denominator)));

        // Reverts with TickMath's own bounds error for an FDV so extreme the price falls outside
        // [MIN_SQRT_PRICE, MAX_SQRT_PRICE] - deliberately not re-wrapped, so the failure mode for an
        // absurd input is exactly as loud as it is for any other TickMath caller in this codebase.
        int24 rawTick = TickMath.getTickAtSqrtPrice(rawSqrtPriceX96);

        // The computed tick becomes a literal boundary of the one-sided position (Launcher uses it as
        // tickLower when tokenIsCurrency0, tickUpper otherwise), so it must land exactly on a multiple
        // of tickSpacing, not just near one. Round toward the boundary that keeps the starting price at
        // or below what was requested, mirroring the direction of the one-sided range itself: token as
        // currency0 -> range grows upward from tick, so floor; quote as currency0 -> range grows
        // downward to tick, so ceil (which, in raw-tick terms, is still "round toward zero price
        // increase for the token side" - see the fuzz test asserting FDV symmetry across orientations).
        tick = tokenIsCurrency0 ? _floorToSpacing(rawTick, tickSpacing) : _ceilToSpacing(rawTick, tickSpacing);
        sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
    }

    /// @dev Babylonian method; standard integer sqrt, same algorithm as OpenZeppelin's Math.sqrt.
    function _sqrt(uint256 x) private pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    /// @dev Solidity truncates division toward zero, so a plain `tick / spacing * spacing` rounds
    /// negative ticks UP (toward zero) instead of down. This corrects that for the floor case.
    function _floorToSpacing(int24 tick, int24 spacing) private pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed -= 1;
        return compressed * spacing;
    }

    /// @dev Mirror of _floorToSpacing for the ceiling case (positive ticks truncate down, not up).
    function _ceilToSpacing(int24 tick, int24 spacing) private pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick > 0 && tick % spacing != 0) compressed += 1;
        return compressed * spacing;
    }
}
