// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { IUniswapV3SwapCallback } from "../../src/interfaces/IUniswapV3Minimal.sol";

interface IMockToken {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @dev Minimal stand-in for a real Uniswap v3 pool, used to test ArchemistBuybackVault's v3 route in
/// isolation without vendoring the full v3-core AMM math. Applies a fixed, test-configured exchange rate
/// instead of a real concentrated-liquidity curve - this exists to prove the vault's settlement/callback
/// wiring against v3's actual calling convention (optimistic output transfer, then a payment callback,
/// opposite amountSpecified sign from v4), not to reimplement v3's own math.
contract MockUniswapV3Pool {
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;

    uint160 public sqrtPriceX96Override;
    /// @dev token1 out per token0 in, scaled by 1e18. Set the reciprocal-scaled rate if swapping 1->0.
    uint256 public rateToken1PerToken0X18 = 1e18;
    bool public starveOutput;

    constructor(address token0_, address token1_, uint24 fee_, uint160 initialSqrtPriceX96) {
        token0 = token0_;
        token1 = token1_;
        fee = fee_;
        sqrtPriceX96Override = initialSqrtPriceX96;
    }

    function setSqrtPriceX96(uint160 value) external {
        sqrtPriceX96Override = value;
    }

    function setRateToken1PerToken0X18(uint256 value) external {
        rateToken1PerToken0X18 = value;
    }

    /// @dev Test-only escape hatch to simulate a pool that doesn't send the promised output (e.g. thin
    /// liquidity reverting), so callers can prove the vault's minOut check would catch a shortfall.
    function setStarveOutput(bool value) external {
        starveOutput = value;
    }

    function slot0()
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool unlocked)
    {
        return (sqrtPriceX96Override, 0, 0, 0, 0, 0, true);
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        virtual
        returns (int256 amount0, int256 amount1)
    {
        require(amountSpecified > 0, "mock: only exact input supported");
        // Safe: just checked amountSpecified > 0.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amountIn = uint256(amountSpecified);
        uint256 amountOut =
            zeroForOne ? (amountIn * rateToken1PerToken0X18) / 1e18 : (amountIn * 1e18) / rateToken1PerToken0X18;
        if (starveOutput) amountOut = 0;

        address tokenOut = zeroForOne ? token1 : token0;
        address tokenIn = zeroForOne ? token0 : token1;
        uint256 balBefore = IMockToken(tokenIn).balanceOf(address(this));

        if (amountOut > 0) {
            require(IMockToken(tokenOut).transfer(recipient, amountOut), "mock: output transfer failed");
        }

        // Safe: both amounts are test-configured token balances, far below int256's range.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 amountInSigned = int256(amountIn);
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 amountOutSigned = -int256(amountOut);
        (amount0, amount1) = zeroForOne ? (amountInSigned, amountOutSigned) : (amountOutSigned, amountInSigned);

        IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);

        uint256 balAfter = IMockToken(tokenIn).balanceOf(address(this));
        require(balAfter - balBefore >= amountIn, "mock: payment not received");
    }
}
