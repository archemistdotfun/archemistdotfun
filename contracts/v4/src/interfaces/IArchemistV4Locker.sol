// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { FeeRecipient } from "../ArchemistV4Types.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IArchemistV4Locker {
    function LAUNCHER() external view returns (address);
    function POOL_MANAGER() external view returns (IPoolManager);

    function seedPosition(
        address token,
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint16 creatorShareBps,
        FeeRecipient[] calldata recipients
    ) external returns (PoolId poolId, uint128 liquidity, uint256 tokenUsed);

    /// @param isBuy Direction of the swap that produced this fee, relative to the launch token
    ///        (true = quote in / token out). Decides whether the 12.5% non-creator, non-protocol slice
    ///        funds the ARCH buyback (buy) or this token's holder rewards (sell).
    function recordHookFee(PoolId poolId, Currency currency, uint256 amount, bool isBuy) external;
}
