// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";

import { InitialPriceMath } from "../src/InitialPriceMath.sol";

contract InitialPriceMathTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    function test_zeroFdvReverts() public {
        // Routed through an external call so vm.expectRevert has a real CALL boundary to attach to -
        // computeInitialTick is `internal`, so a same-contract call gets inlined with no call frame.
        vm.expectRevert(InitialPriceMath.TargetFdvZero.selector);
        this.callCompute(0, true, 60);
    }

    function callCompute(uint256 fdv, bool tokenIsCurrency0, int24 spacing) external pure returns (int24, uint160) {
        return InitialPriceMath.computeInitialTick(fdv, SUPPLY, tokenIsCurrency0, spacing);
    }

    function test_resultAlwaysAlignedToTickSpacing() public pure {
        int24[4] memory spacings = [int24(1), int24(10), int24(60), int24(200)];
        // 1e6 is deliberately tiny relative to SUPPLY (1e27 raw) - this is what used to overflow the
        // naive "multiply the whole ratio by 2^192 first" implementation (ratio ~1e21 > 2^64).
        uint256[3] memory fdvs = [uint256(1e6), uint256(5_000e18), uint256(1e30)];
        for (uint256 s; s < spacings.length; ++s) {
            for (uint256 f; f < fdvs.length; ++f) {
                (int24 tickTrue,) = InitialPriceMath.computeInitialTick(fdvs[f], SUPPLY, true, spacings[s]);
                (int24 tickFalse,) = InitialPriceMath.computeInitialTick(fdvs[f], SUPPLY, false, spacings[s]);
                assertEq(tickTrue % spacings[s], 0, "tokenIsCurrency0 tick must align");
                assertEq(tickFalse % spacings[s], 0, "!tokenIsCurrency0 tick must align");
            }
        }
    }

    /// ORD-04-style property: the same target FDV must produce (near) mirror-image ticks across the
    /// two orientations, since it's the same economic price just expressed from the other side.
    function test_orientationIsSymmetricWithinOneTickSpacing() public pure {
        int24 spacing = 60;
        uint256[6] memory fdvs =
            [uint256(100e18), uint256(5_000e18), uint256(1_000_000e18), uint256(1e12), uint256(7e24), uint256(1e6)];
        for (uint256 i; i < fdvs.length; ++i) {
            (int24 tickTrue,) = InitialPriceMath.computeInitialTick(fdvs[i], SUPPLY, true, spacing);
            (int24 tickFalse,) = InitialPriceMath.computeInitialTick(fdvs[i], SUPPLY, false, spacing);
            int256 diff = int256(tickTrue) + int256(tickFalse);
            // Safe: diff and spacing are both bounded well within int24 range, negation can't overflow.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 absDiff = diff < 0 ? uint256(-diff) : uint256(diff);
            // forge-lint: disable-next-line(unsafe-typecast)
            assertLe(absDiff, uint256(uint24(spacing)), "orientations must mirror within 1 tick spacing");
        }
    }

    /// ORD-06-style property. Note this does NOT assert the tick is identical across decimals - that
    /// would be wrong: the tick encodes a RAW-to-RAW ratio, and raw units genuinely change with decimals
    /// (e.g. "$1" is raw value 1e6 at 6 decimals but 1e18 at 18 decimals - different tokens, different
    /// raw price). What must hold instead is the real invariant: expressing the SAME human FDV in a
    /// quote's own decimals must recover that same human FDV back out of the resulting price, for every
    /// decimals value - i.e. the conversion is internally consistent per-decimals, not decimals-blind.
    function testFuzz_sameHumanFdvRoundTripsAcrossDecimals(uint32 wholeFdv) public pure {
        uint256 whole = bound(uint256(wholeFdv), 1, 1_000_000);
        uint8[4] memory decimalsSet = [uint8(6), uint8(8), uint8(18), uint8(24)];
        int24 spacing = 1; // finest granularity so rounding tolerance can stay tight
        for (uint256 i; i < decimalsSet.length; ++i) {
            uint256 fdvRaw = whole * (10 ** decimalsSet[i]);
            (int24 tick,) = InitialPriceMath.computeInitialTick(fdvRaw, SUPPLY, true, spacing);
            // Recover implied whole FDV: impliedFdvRaw = (sqrtPrice^2 / 2^192) * SUPPLY, chained as two
            // mulDiv calls that multiply by SUPPLY *before* dividing by 2^192 - doing the division first
            // (as a standalone `price = sqrtPrice^2/2^192`) truncates to 0 for any price ratio under 1,
            // which is the common case (a cheap token split across a 1e9-token supply almost always
            // prices under 1 quote-raw-unit per token-raw-unit).
            uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
            uint256 impliedFdvRaw = FullMath.mulDiv(FullMath.mulDiv(sqrtPriceX96, SUPPLY, 1), sqrtPriceX96, 1 << 192);
            uint256 impliedWhole = impliedFdvRaw / (10 ** decimalsSet[i]);
            // Tick-spacing=1 rounding can only move price by <= 1 bps, so the recovered whole FDV must
            // be within a couple of units of what was requested (tighter for larger `whole`, looser -
            // but still bounded - for tiny ones where integer division itself loses a unit or two).
            uint256 tolerance = whole / 5000 + 2;
            assertLe(
                impliedWhole > whole ? impliedWhole - whole : whole - impliedWhole,
                tolerance,
                "round-trip must recover the requested FDV"
            );
        }
    }

    /// Rounding must always favor the creator: the returned tick never sits on the side of the raw
    /// (unrounded) tick that would imply a richer starting price than requested. Compared at the tick
    /// level (not by reconstructing a combined ratio*2^192, which is exactly the overflow this library
    /// itself had to route around - see the split-sqrt comment in InitialPriceMath.computeInitialTick).
    function testFuzz_roundingNeverExceedsRequestedFdv(uint128 fdvRaw, bool tokenIsCurrency0) public pure {
        uint256 fdv = bound(uint256(fdvRaw), 1, 1e30);
        int24 spacing = 60;

        uint256 numerator = tokenIsCurrency0 ? fdv : SUPPLY;
        uint256 denominator = tokenIsCurrency0 ? SUPPLY : fdv;
        uint160 requestedSqrtPriceX96 = uint160(FullMath.mulDiv(_sqrt(numerator), 1 << 96, _sqrt(denominator)));
        int24 rawTick = TickMath.getTickAtSqrtPrice(requestedSqrtPriceX96);

        (int24 tick, uint160 sqrtPriceX96) = InitialPriceMath.computeInitialTick(fdv, SUPPLY, tokenIsCurrency0, spacing);
        assertEq(TickMath.getSqrtPriceAtTick(tick), sqrtPriceX96, "returned sqrtPriceX96 must match the returned tick");

        if (tokenIsCurrency0) {
            assertLe(tick, rawTick, "must round down (cheaper), never up, for tokenIsCurrency0");
        } else {
            assertGe(tick, rawTick, "must round up, never down, for !tokenIsCurrency0");
        }
    }

    function _sqrt(uint256 x) private pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
