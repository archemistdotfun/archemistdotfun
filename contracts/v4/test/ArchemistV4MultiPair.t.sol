// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { PoolManager } from "@uniswap/v4-core/src/PoolManager.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { HookMiner } from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import { ArchemistHolderRewards } from "../src/ArchemistHolderRewards.sol";
import { ArchemistPairRegistry } from "../src/ArchemistPairRegistry.sol";
import { ArchemistV4Hook } from "../src/ArchemistV4Hook.sol";
import { ArchemistV4Launcher } from "../src/ArchemistV4Launcher.sol";
import { ArchemistV4Locker } from "../src/ArchemistV4Locker.sol";
import { ArchemistV4Token } from "../src/ArchemistV4Token.sol";
import { AntiSnipeParams, FeeRecipient, PairConfig } from "../src/ArchemistV4Types.sol";
import { ArchemistDeploy } from "./Deploy.sol";

contract MultiPairQuoteToken {
    string public constant name = "Mock USD";
    string public constant symbol = "mUSD";
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MultiPairReceiver {
    receive() external payable { }
}

contract ArchemistV4MultiPairTest is Test {
    using SafeCast for uint256;

    uint160 internal constant REQUIRED_FLAGS = 0x28CC;
    int24 internal constant SPACING = 60;
    // targetFdvQuoteRaw == INITIAL_SUPPLY below -> price ratio 1:1 -> tick 0 for either orientation.
    int24 internal constant INITIAL_TICK = 0;

    IPoolManager internal manager;
    PoolSwapTest internal router;
    ArchemistPairRegistry internal registry;
    ArchemistV4Launcher internal launcher;
    ArchemistV4Locker internal locker;
    ArchemistHolderRewards internal holderRewards;
    ArchemistV4Hook internal hook;
    MultiPairQuoteToken internal quote;
    MultiPairReceiver internal treasury;
    MultiPairReceiver internal buyback;

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        router = new PoolSwapTest(manager);
        quote = new MultiPairQuoteToken();
        treasury = new MultiPairReceiver();
        buyback = new MultiPairReceiver();
        registry = ArchemistDeploy.registry(address(this), address(0));
        registry.addPair(
            address(quote),
            PairConfig({
                enabled: true,
                decimals: 6,
                defaultTick: INITIAL_TICK,
                minTick: -360_000,
                maxTick: 360_000,
                tickSpacing: SPACING,
                flags: 0,
                buybackRoute: address(0),
                buybackRouteIsV4: false,
                buybackRouteFee: 0,
                buybackRouteTickSpacing: 0,
                minCreatorBps: 5_000,
                maxCreatorBps: 8_000
            }),
            0,
            false
        );

        launcher = ArchemistDeploy.launcher(manager, address(this), address(registry), address(treasury), 0);
        locker = ArchemistDeploy.locker(manager, address(this), address(launcher));
        holderRewards = ArchemistDeploy.rewards(address(this), address(launcher), address(locker));
        bytes memory constructorArgs = abi.encode(manager, address(launcher), address(locker), address(buyback));
        (address expectedHook, bytes32 salt) =
            HookMiner.find(address(this), REQUIRED_FLAGS, type(ArchemistV4Hook).creationCode, constructorArgs);
        hook = new ArchemistV4Hook{ salt: salt }(manager, address(launcher), address(locker), address(buyback));
        assertEq(address(hook), expectedHook);
        launcher.configureSystemOnce(address(locker), address(buyback), address(holderRewards));
        launcher.registerHook(address(hook));
        launcher.enableCreate();

        quote.mint(address(this), 100_000e6);
        quote.approve(address(router), type(uint256).max);
    }

    function test_sameFactoryLaunchesAndTradesBothErc20Orientations() public {
        (ArchemistV4Token token0, PoolId pool0, PoolKey memory key0) = _launch(true, 1);
        (ArchemistV4Token token1, PoolId pool1, PoolKey memory key1) = _launch(false, 10_000);
        assertTrue(address(token0) < address(quote));
        assertTrue(address(token1) > address(quote));

        _assertOneSidedOrientation(pool0, key0, true);
        _assertOneSidedOrientation(pool1, key1, false);

        registry.setPairEnabled(address(quote), false);
        _buy(key0, true, 1e6);
        _buy(key1, false, 1e6);

        uint256 creatorCredit = locker.claimable(address(this), address(quote));
        assertEq(creatorCredit, 14_000, "70% of two 1% fees");
        assertEq(
            manager.balanceOf(address(locker), uint256(uint160(address(quote)))),
            locker.totalClaimLiability(address(quote)),
            "ERC-6909 backing must exactly match quote liability"
        );

        uint256 before = quote.balanceOf(address(this));
        locker.claim(address(quote), address(this));
        assertEq(quote.balanceOf(address(this)) - before, creatorCredit);
        assertEq(locker.claimable(address(this), address(quote)), 0);

        ArchemistV4Launcher.LaunchParams memory blocked = _params(bytes32(uint256(999_999)));
        vm.expectRevert(abi.encodeWithSelector(ArchemistV4Launcher.PairDisabled.selector, address(quote)));
        launcher.createToken(blocked);
    }

    function _launch(bool tokenIsCurrency0, uint256 seed)
        private
        returns (ArchemistV4Token token, PoolId poolId, PoolKey memory key)
    {
        bytes32 salt = _findSalt(tokenIsCurrency0, seed);
        ArchemistV4Launcher.LaunchParams memory params = _params(salt);
        (address tokenAddress, PoolId launchedPoolId) = launcher.createToken(params);
        token = ArchemistV4Token(tokenAddress);
        poolId = launchedPoolId;
        key = locker.getPoolKey(poolId);
    }

    function _findSalt(bool tokenIsCurrency0, uint256 seed) private view returns (bytes32 salt) {
        for (uint256 i = seed; i < seed + 10_000; ++i) {
            salt = bytes32(i);
            address predicted = launcher.computeTokenAddress(salt, "Multi Pair", "MULTI", address(this));
            if ((predicted < address(quote)) == tokenIsCurrency0) return salt;
        }
        revert("orientation salt not found");
    }

    function _params(bytes32 salt) private view returns (ArchemistV4Launcher.LaunchParams memory params) {
        FeeRecipient[] memory recipients = new FeeRecipient[](1);
        recipients[0] = FeeRecipient({ admin: address(this), payout: address(this), bps: 10_000 });
        params = ArchemistV4Launcher.LaunchParams({
            name: "Multi Pair",
            symbol: "MULTI",
            salt: salt,
            quote: address(quote),
            targetFdvQuoteRaw: 1_000_000_000 ether,
            hook: address(hook),
            hookParams: abi.encode(AntiSnipeParams({ startHookFee: 10_000, windowSeconds: 120, maxBuyBps: 10_000 })),
            creatorShareBps: 7_000,
            recipients: recipients,
            creatorBuyAmount: 0,
            creatorBuyMinTokensOut: 0
        });
    }

    function _assertOneSidedOrientation(PoolId poolId, PoolKey memory key, bool tokenIsCurrency0) private view {
        ArchemistV4Locker.PositionInfo memory _pi = locker.positionInfo(poolId);
        address storedToken = _pi.token;
        int24 tickLower = _pi.tickLower;
        int24 tickUpper = _pi.tickUpper;
        bool exists = _pi.exists;
        assertTrue(exists);
        if (tokenIsCurrency0) {
            assertEq(Currency.unwrap(key.currency0), storedToken);
            assertEq(tickLower, INITIAL_TICK);
            assertEq(tickUpper, TickMath.maxUsableTick(SPACING));
        } else {
            assertEq(Currency.unwrap(key.currency1), storedToken);
            assertEq(tickLower, TickMath.minUsableTick(SPACING));
            assertEq(tickUpper, INITIAL_TICK);
        }
    }

    function _buy(PoolKey memory key, bool tokenIsCurrency0, uint256 amount) private {
        bool zeroForOne = !tokenIsCurrency0;
        router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -amount.toInt256(),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
    }
}
