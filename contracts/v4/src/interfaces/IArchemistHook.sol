// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice What the launcher requires of any hook before it will let a launch use it.
///
/// This interface is the whole of the coupling between the launcher and a hook, and it is deliberately
/// thin. A hook is **versioned, never upgraded**: `PoolKey.hooks` is part of a pool's identity
/// (`PoolId = keccak256(abi.encode(PoolKey))`), fixed at `initialize` and unchangeable thereafter, and
/// the hook's permission bits are encoded in the low 14 bits of its own address. A proxy hook would
/// therefore be able to change its behaviour while its declared permissions stayed frozen - the textbook
/// "dangerous flag" in Uniswap's own hook-warning taxonomy. So new behaviour means a new hook contract
/// and one `registerHook` call, not an upgrade.
///
/// The four view functions exist so `registerHook` can verify from this side that the hook is wired to
/// *this* launcher, *this* locker and *this* PoolManager before it is ever allowed to take a fee. A
/// mis-wired hook would otherwise mint fees into a locker that does not know it, where they would be
/// unclaimable.
interface IArchemistHook is IHooks {
    function launcher() external view returns (address);
    function locker() external view returns (address);
    function poolManager() external view returns (IPoolManager);
    function getHookPermissions() external pure returns (Hooks.Permissions memory);

    /// @notice Locks this pool's hook-specific configuration, once, immediately before the launcher
    /// initializes the pool. Everything the hook needs to know that the launcher cannot decide for it -
    /// fee curve, anti-snipe window, buy cap - is carried in `params` and decoded, bounds-checked and
    /// stored by the hook itself.
    /// @param params ABI-encoded, hook-defined. For `ArchemistV4Hook` this is an `AntiSnipeParams`.
    function lockConfig(
        PoolKey calldata key,
        address token,
        Currency quote,
        bool tokenIsCurrency0,
        bytes calldata params
    ) external;
}
