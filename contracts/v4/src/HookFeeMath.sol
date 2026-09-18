// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { FullMath } from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @notice The two fee formulas ArchemistV4Hook charges with, kept in one place so the four swap cases
/// (buy/sell × exactInput/exactOutput) can never drift apart the way they had before - see the
/// finding recorded in docs/INTERNAL_AUDIT.md, where exact-output buys were charging
/// an effective f/(1+f) instead of f because they used the wrong one of these two.
///
/// The distinction is only ever about *which amount the hook already knows*:
///   - `feeOnGross` when the known amount already INCLUDES the fee (it is the total the trader parts
///     with, or the total the pool pays out), so the fee is carved out of it.
///   - `feeOnNet` when the known amount EXCLUDES the fee (it is what the trader/pool ends up with net),
///     so the fee is grossed up on top of it.
/// Both produce `fee == pips * (net + fee)` - i.e. the fee is always exactly `pips` of the gross amount
/// the trader actually pays or receives, in every one of the four cases.
library HookFeeMath {
    uint24 internal constant FEE_DENOMINATOR = 1_000_000;

    /// @dev Fee carved out of an amount that already includes it. `gross` is the trader's total outlay
    /// (exact-input buy: the specified quote in) or the pool's total payout (exact-input sell: the
    /// unspecified quote out).
    function feeOnGross(uint256 gross, uint24 pips) internal pure returns (uint256) {
        return FullMath.mulDiv(gross, pips, FEE_DENOMINATOR);
    }

    /// @dev Fee grossed up on top of an amount that excludes it, so that `fee == pips * (net + fee)`.
    /// `net` is the trader's requested payout (exact-output sell: the specified quote out) or the pool's
    /// bare input charge (exact-output buy: the unspecified quote in, before the hook's own cut).
    ///
    /// `pips < FEE_DENOMINATOR` is guaranteed by the caller: ArchemistV4Hook only ever passes
    /// `baseHookFee` (10_000) or `currentFee()` (bounded by MAX_START_HOOK_FEE = 990_000).
    function feeOnNet(uint256 net, uint24 pips) internal pure returns (uint256) {
        return FullMath.mulDiv(net, pips, FEE_DENOMINATOR - pips);
    }
}
