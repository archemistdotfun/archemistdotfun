// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";

import { PoolManager } from "@uniswap/v4-core/src/PoolManager.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolDonateTest } from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import { PoolModifyLiquidityTest } from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { ModifyLiquidityParams, SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { HookMiner } from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import { ArchemistHolderRewards } from "../src/ArchemistHolderRewards.sol";
import { ArchemistPairRegistry } from "../src/ArchemistPairRegistry.sol";
import { ArchemistV4Hook } from "../src/ArchemistV4Hook.sol";
import { ArchemistV4Launcher } from "../src/ArchemistV4Launcher.sol";
import { ArchemistV4Locker } from "../src/ArchemistV4Locker.sol";
import { ArchemistV4Token } from "../src/ArchemistV4Token.sol";
import { AntiSnipeParams, FeeRecipient, PairConfig } from "../src/ArchemistV4Types.sol";
import { ArchemistDeploy } from "./Deploy.sol";

contract HookFeeReceiver {
    receive() external payable { }
}

/// @dev Stands in for ArchemistBuybackVault so the hook's trigger behaviour can be observed directly:
/// how often it fires, how much gas it was actually handed, and what happens when it misbehaves.
contract RecordingVault {
    uint256 public calls;
    uint256 public gasHandedToLastCall;
    bool public shouldRevert;
    bool public shouldBurnAllGas;

    function execute(address) external returns (uint256) {
        calls++;
        gasHandedToLastCall = gasleft();
        if (shouldBurnAllGas) {
            // Consume everything this frame was given, the way a real two-hop buyback would if it
            // outgrew its stipend. Without the hook's own {gas:} cap this is what would take the
            // trader's swap down with it.
            while (true) { }
        }
        if (shouldRevert) revert("vault unavailable");
        return 0;
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function setShouldBurnAllGas(bool value) external {
        shouldBurnAllGas = value;
    }

    receive() external payable { }
}

contract RejectingFeeReceiver {
    function claimFrom(ArchemistV4Locker locker) external {
        locker.claim(address(0), address(this));
    }

    receive() external payable {
        revert("reject native");
    }
}

contract ArchemistV4HookTest is Test {
    using SafeCast for uint256;

    uint160 internal constant REQUIRED_FLAGS = 0x28CC;
    address internal constant CREATOR = address(0xC0FFEE);

    IPoolManager internal manager;
    PoolSwapTest internal swapRouter;
    HookFeeReceiver internal treasury;
    RecordingVault internal buyback;
    ArchemistV4Launcher internal launcher;
    ArchemistV4Locker internal locker;
    ArchemistHolderRewards internal holderRewards;
    ArchemistV4Hook internal hook;
    ArchemistV4Token internal token;
    PoolKey internal key;
    PoolId internal poolId;

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        swapRouter = new PoolSwapTest(manager);
        treasury = new HookFeeReceiver();
        buyback = new RecordingVault();

        ArchemistPairRegistry registry = ArchemistDeploy.registry(address(this), address(0));
        registry.addPair(
            address(0),
            PairConfig({
                enabled: true,
                decimals: 18,
                defaultTick: 0,
                minTick: -120_000,
                maxTick: 120_000,
                tickSpacing: 60,
                flags: 1,
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
        (address tokenAddress, PoolId launchedPoolId) = launcher.createToken(_params(10_000, 100));
        token = ArchemistV4Token(tokenAddress);
        poolId = launchedPoolId;
        key = locker.getPoolKey(poolId);
    }

    function test_poolUsesZeroLpFeeAndMinedPermissions() public view {
        assertEq(key.fee, 0);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, REQUIRED_FLAGS);
    }

    function test_exactInputBuyChargesQuoteAndConservesSplit() public {
        vm.warp(block.timestamp + 121);
        uint256 beforeLiability = locker.totalClaimLiability(address(0));
        _buyExactInput(1 ether);
        assertEq(locker.totalClaimLiability(address(0)) - beforeLiability, 0.01 ether);
        _assertNewFeeSplit(beforeLiability);
    }

    function test_exactOutputBuyChargesQuoteAndConservesSplit() public {
        vm.warp(block.timestamp + 121);
        uint256 beforeLiability = locker.totalClaimLiability(address(0));
        vm.deal(address(this), 10 ether);
        swapRouter.swap{ value: 10 ether }(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: int256(1e15), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            _settings(),
            bytes("")
        );
        _assertNewFeeSplit(beforeLiability);
    }

    function test_exactInputSellChargesQuoteAndConservesSplit() public {
        vm.warp(block.timestamp + 121);
        _buyExactInput(1 ether);
        uint256 beforeLiability = locker.totalClaimLiability(address(0));
        uint256 sellAmount = token.balanceOf(address(this)) / 2;
        token.approve(address(swapRouter), sellAmount);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -sellAmount.toInt256(),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            _settings(),
            bytes("")
        );
        _assertNewFeeSplit(beforeLiability);
    }

    function test_exactOutputSellChargesQuoteAndConservesSplit() public {
        vm.warp(block.timestamp + 121);
        _buyExactInput(1 ether);
        uint256 beforeLiability = locker.totalClaimLiability(address(0));
        token.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: int256(0.1 ether), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            _settings(),
            bytes("")
        );
        assertEq(
            locker.totalClaimLiability(address(0)) - beforeLiability, uint256(0.1 ether) * 10_000 / (1_000_000 - 10_000)
        );
        _assertNewFeeSplit(beforeLiability);
    }

    function test_claimRedeemsPoolManagerClaimBeforeNativePayout() public {
        vm.warp(block.timestamp + 121);
        _buyExactInput(1 ether);
        uint256 amount = locker.claimable(CREATOR, address(0));
        uint256 claimBackingBefore = manager.balanceOf(address(locker), 0);
        uint256 recipientBefore = CREATOR.balance;

        vm.prank(CREATOR);
        locker.claim(address(0), CREATOR);

        assertEq(CREATOR.balance - recipientBefore, amount);
        assertEq(manager.balanceOf(address(locker), 0), claimBackingBefore - amount);
        assertEq(locker.erc6909Claimable(CREATOR, address(0)), 0);
    }

    function test_claimCombinesRealBalanceAndErc6909Backing() public {
        vm.warp(block.timestamp + 121);
        _buyExactInput(1 ether);
        uint256 hookCredit = locker.erc6909Claimable(CREATOR, address(0));

        PoolDonateTest donateRouter = new PoolDonateTest(manager);
        vm.deal(address(this), 1 ether);
        donateRouter.donate{ value: 1 ether }(key, 1 ether, 0, bytes(""));
        locker.collect(poolId);

        uint256 totalCredit = locker.claimable(CREATOR, address(0));
        assertGt(totalCredit, hookCredit);
        assertGt(address(locker).balance, 0);

        uint256 recipientBefore = CREATOR.balance;
        vm.prank(CREATOR);
        locker.claim(address(0), CREATOR);
        assertEq(CREATOR.balance - recipientBefore, totalCredit);
        assertEq(locker.claimable(CREATOR, address(0)), 0);
    }

    function test_revertingRecipientCannotCorruptClaimAccounting() public {
        RejectingFeeReceiver receiver = new RejectingFeeReceiver();
        locker.updateRecipientPayout(poolId, 0, address(receiver));
        vm.warp(block.timestamp + 121);
        _buyExactInput(1 ether);
        uint256 credit = locker.claimable(address(receiver), address(0));
        uint256 backing = manager.balanceOf(address(locker), 0);

        vm.expectRevert(ArchemistV4Locker.TransferFailed.selector);
        receiver.claimFrom(locker);

        assertEq(locker.claimable(address(receiver), address(0)), credit);
        assertEq(locker.erc6909Claimable(address(receiver), address(0)), credit);
        assertEq(manager.balanceOf(address(locker), 0), backing);
    }

    function test_nonHookCannotRecordUnbackedFee() public {
        vm.expectRevert(ArchemistV4Locker.NotAuthorized.selector);
        locker.recordHookFee(poolId, key.currency0, 1 ether, true);
    }

    function test_multiRecipientRoundingConservesCreatorShare() public {
        FeeRecipient[] memory recipients = new FeeRecipient[](2);
        address payout0 = address(0x1000);
        address payout1 = address(0x2000);
        recipients[0] = FeeRecipient({ admin: address(this), payout: payout0, bps: 3_333 });
        recipients[1] = FeeRecipient({ admin: address(this), payout: payout1, bps: 6_667 });
        ArchemistV4Launcher.LaunchParams memory params = _params(10_000, 100);
        params.name = "Split Token";
        params.symbol = "SPLIT";
        params.salt = keccak256("split-token");
        params.recipients = recipients;
        (, PoolId splitPoolId) = launcher.createToken(params);
        PoolKey memory splitKey = locker.getPoolKey(splitPoolId);

        vm.warp(block.timestamp + 121);
        vm.deal(address(this), 1 ether);
        swapRouter.swap{ value: 1 ether }(
            splitKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -uint256(1 ether).toInt256(),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            _settings(),
            bytes("")
        );

        uint256 fee = locker.totalClaimLiability(address(0));
        uint256 creatorTotal = fee * 7_000 / 10_000;
        uint256 payout0Credit = locker.erc6909Claimable(payout0, address(0));
        uint256 payout1Credit = locker.erc6909Claimable(payout1, address(0));
        assertEq(payout0Credit + payout1Credit, creatorTotal);
        assertEq(payout1Credit, creatorTotal * 6_667 / 10_000);
        assertEq(
            creatorTotal + locker.erc6909Claimable(address(buyback), address(0))
                + locker.erc6909Claimable(address(treasury), address(0)),
            fee
        );
    }

    function test_exactOutputBuyBlockedDuringAntiSnipeWindow() public {
        vm.deal(address(this), 10 ether);
        vm.expectRevert();
        swapRouter.swap{ value: 10 ether }(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: int256(1e15), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            _settings(),
            bytes("")
        );
    }

    function test_outsideLiquidityIsBlockedDuringAntiSnipeWindow() public {
        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(manager);
        vm.expectRevert();
        liquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(key.tickSpacing),
                tickUpper: -60_000,
                liquidityDelta: 1,
                salt: keccak256("outside")
            }),
            bytes("")
        );
    }

    function test_largeBuyExceedingSupplyCapRevertsWithoutFeeCredit() public {
        uint256 amount = 1e28;
        vm.deal(address(this), amount);
        vm.expectRevert();
        swapRouter.swap{ value: amount }(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -amount.toInt256(), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            _settings(),
            bytes("")
        );
        assertEq(locker.totalClaimLiability(address(0)), 0);
    }

    function test_partialExactInputBuyRevertsWithoutOvercharging() public {
        vm.warp(block.timestamp + 121);
        uint256 amount = 1e28;
        vm.deal(address(this), amount);
        vm.expectRevert();
        swapRouter.swap{ value: amount }(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -amount.toInt256(),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(-60)
            }),
            _settings(),
            bytes("")
        );
        assertEq(locker.totalClaimLiability(address(0)), 0);
    }

    function test_feeDecayIsQuadraticAndEndsAtOnePercent() public {
        (address secondToken, PoolId secondPoolId) = launcher.createToken(_params(300_000, 100));
        assertTrue(secondToken != address(0));
        uint256 start = block.timestamp;
        assertEq(hook.currentFee(secondPoolId), 300_000);

        vm.warp(start + 60);
        assertEq(hook.currentFee(secondPoolId), 82_500);
        vm.warp(start + 120);
        assertEq(hook.currentFee(secondPoolId), 10_000);
    }

    function test_feeDecayAllowsUpTo99PercentStart() public {
        (address thirdToken, PoolId thirdPoolId) = launcher.createToken(_params(990_000, 100));
        assertTrue(thirdToken != address(0));
        uint256 start = block.timestamp;
        assertEq(hook.currentFee(thirdPoolId), 990_000);

        // excess = 990_000 - 10_000 = 980_000; at the window's midpoint (60s of 120s),
        // remaining^2/duration^2 = 60^2/120^2 = 0.25, so fee = 10_000 + 980_000 * 0.25 = 255_000.
        vm.warp(start + 60);
        assertEq(hook.currentFee(thirdPoolId), 255_000);
        vm.warp(start + 120);
        assertEq(hook.currentFee(thirdPoolId), 10_000);
    }

    function test_directHookCallIsRejected() public {
        vm.expectRevert(ArchemistV4Hook.NotPoolManager.selector);
        hook.beforeInitialize(address(launcher), key, TickMath.getSqrtPriceAtTick(-60_000));
    }

    function _buyExactInput(uint256 amount) private returns (BalanceDelta delta) {
        vm.deal(address(this), amount);
        delta = swapRouter.swap{ value: amount }(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -amount.toInt256(), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            _settings(),
            bytes("")
        );
    }

    // --- Fee rate consistency across all four swap shapes (finding M-2) ---------------------------

    /// Every shape must charge 1% of the gross amount the trader actually parts with or receives.
    /// Exact-output buys used to be the odd one out at an effective 0.99%, because they applied the
    /// carve-out formula to an amount that excluded the fee.
    function test_exactOutputBuyChargesOnePercentOfWhatTheTraderPays() public {
        vm.warp(block.timestamp + 121);
        uint256 beforeLiability = locker.totalClaimLiability(address(0));
        vm.deal(address(this), 10 ether);
        uint256 balanceBefore = address(this).balance;
        swapRouter.swap{ value: 10 ether }(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: int256(1e15), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            _settings(),
            bytes("")
        );
        uint256 totalPaid = balanceBefore - address(this).balance;
        uint256 fee = locker.totalClaimLiability(address(0)) - beforeLiability;
        uint256 poolCharge = totalPaid - fee;

        // The exact relationship the gross-up is defined by: the fee is 1% of (pool charge + fee), so
        // it is 1/99 of the pool charge alone.
        assertEq(fee, poolCharge * 10_000 / (1_000_000 - 10_000), "fee must be grossed up, not carved out");
        // And the regression guard for M-2: the old carve-out formula would have produced strictly less
        // here, which is exactly how the effective rate had drifted to 0.99%.
        assertGt(fee, poolCharge * 10_000 / 1_000_000, "carve-out formula would undercharge this case");
    }

    function test_exactInputBuyChargesOnePercentOfWhatTheTraderPays() public {
        vm.warp(block.timestamp + 121);
        uint256 beforeLiability = locker.totalClaimLiability(address(0));
        _buyExactInput(1 ether);
        uint256 fee = locker.totalClaimLiability(address(0)) - beforeLiability;
        assertEq(fee, uint256(1 ether) / 100, "exact-input buy charges 1% of the specified input");
    }

    // --- Direction decides the destination of the 12.5% slice --------------------------------------

    function test_buyFundsBuybackAndSellFundsHolders() public {
        vm.warp(block.timestamp + 121);
        _buyExactInput(1 ether);

        uint256 buybackAfterBuy = locker.erc6909Claimable(address(buyback), address(0));
        uint256 rewardsAfterBuy = locker.erc6909Claimable(address(holderRewards), address(0));
        assertEq(buybackAfterBuy, uint256(1 ether) / 100 * 1_250 / 10_000, "buy funds the ARCH buyback");
        assertEq(rewardsAfterBuy, 0, "a buy must not credit holder rewards");

        uint256 liabilityBeforeSell = locker.totalClaimLiability(address(0));
        _sellExactInput(token.balanceOf(address(this)) / 2);
        uint256 sellFee = locker.totalClaimLiability(address(0)) - liabilityBeforeSell;

        assertEq(
            locker.erc6909Claimable(address(buyback), address(0)), buybackAfterBuy, "a sell must not touch buyback"
        );
        assertEq(
            locker.erc6909Claimable(address(holderRewards), address(0)),
            sellFee * 1_250 / 10_000,
            "sell funds this token's holders"
        );
    }

    function test_holderRewardAccrualMatchesTheSellFeeSlice() public {
        vm.warp(block.timestamp + 121);
        _buyExactInput(1 ether);
        uint256 liabilityBeforeSell = locker.totalClaimLiability(address(0));
        _sellExactInput(token.balanceOf(address(this)) / 2);
        uint256 sellFee = locker.totalClaimLiability(address(0)) - liabilityBeforeSell;

        // The seller is this contract, and it is the only eligible holder, so the whole holder slice
        // accrues to it. Off by at most one wei from the Q128 round trip.
        assertApproxEqAbs(
            holderRewards.earned(address(token), address(this)), sellFee * 1_250 / 10_000, 1, "sole holder earns it all"
        );
    }

    function test_swapFeeChargedCarriesDirection() public {
        vm.warp(block.timestamp + 121);

        vm.recordLogs();
        _buyExactInput(1 ether);
        assertTrue(_lastSwapFeeIsBuy(), "buy must be reported as a buy");

        vm.recordLogs();
        _sellExactInput(token.balanceOf(address(this)) / 2);
        assertFalse(_lastSwapFeeIsBuy(), "sell must be reported as a sell");
    }

    // --- The buyback trigger can never cost a trader their swap (finding H-1) ----------------------

    function test_buybackTriggerFiresOnBuyWithinItsStipend() public {
        vm.warp(block.timestamp + 121);
        _buyExactInput(1 ether);
        assertEq(buyback.calls(), 1, "a fee-paying buy triggers exactly one buyback attempt");
        assertLe(
            buyback.gasHandedToLastCall(),
            hook.BUYBACK_GAS_STIPEND(),
            "the vault must never be handed more than its stipend"
        );
        assertGe(buyback.gasHandedToLastCall(), hook.BUYBACK_MIN_GAS(), "and never less than a workable budget");
    }

    /// The buyback's budget comes out of what is spare, so a trader who provides plenty leaves plenty -
    /// and one who provides less simply hands over less, without either of them losing their trade.
    function test_buybackBudgetScalesWithTheGasTheTraderProvided() public {
        vm.warp(block.timestamp + 121);
        vm.deal(address(this), 2 ether);

        swapRouter.swap{ value: 1 ether, gas: 900_000 }(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            _settings(),
            bytes("")
        );
        uint256 modestBudget = buyback.gasHandedToLastCall();

        swapRouter.swap{ value: 1 ether, gas: 3_000_000 }(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            _settings(),
            bytes("")
        );
        uint256 generousBudget = buyback.gasHandedToLastCall();

        assertGt(generousBudget, modestBudget, "a bigger gas budget lends the buyback more");
        assertLe(generousBudget, hook.BUYBACK_GAS_STIPEND(), "but never more than the stipend");
    }

    function test_sellNeverTriggersBuyback() public {
        vm.warp(block.timestamp + 121);
        _buyExactInput(1 ether);
        uint256 callsAfterBuy = buyback.calls();
        _sellExactInput(token.balanceOf(address(this)) / 2);
        assertEq(buyback.calls(), callsAfterBuy, "sells fund holders, so there is nothing to buy back");
    }

    function test_revertingVaultNeverFailsTraderSwap() public {
        vm.warp(block.timestamp + 121);
        buyback.setShouldRevert(true);
        _buyExactInput(1 ether);
        // The attempt's own state changes are rolled back with its revert, which is the point: the
        // trader's swap settles regardless of what the vault did.
        assertEq(buyback.calls(), 0, "the vault's own bookkeeping rolled back with its revert");
        assertEq(locker.totalClaimLiability(address(0)), uint256(1 ether) / 100, "and the trade still settled");
    }

    /// The failure this whole guard exists for: a vault that burns everything it is given. Without the
    /// {gas:} cap the hook would be left with the EIP-150 1/64 remainder - not enough to finish the
    /// swap - and the trader's transaction would die even though the revert was caught.
    function test_gasBurningVaultNeverFailsTraderSwap() public {
        vm.warp(block.timestamp + 121);
        buyback.setShouldBurnAllGas(true);
        _buyExactInput(1 ether);
        assertEq(locker.totalClaimLiability(address(0)), uint256(1 ether) / 100, "trade settled anyway");
    }

    /// A trader who budgets gas for their trade and nothing more gets their trade, not a revert: with
    /// nothing meaningful to spare, the hook declines to start something it cannot afford to finish.
    function test_buybackSkippedWhenNothingIsSpare() public {
        vm.warp(block.timestamp + 121);
        vm.deal(address(this), 1 ether);
        swapRouter.swap{ value: 1 ether, gas: 620_000 }(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            _settings(),
            bytes("")
        );
        assertEq(buyback.calls(), 0, "no spare gas, no attempt");
        assertEq(locker.totalClaimLiability(address(0)), uint256(1 ether) / 100, "but the fee was still charged");
    }

    function _sellExactInput(uint256 amount) private {
        token.approve(address(swapRouter), amount);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -amount.toInt256(), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            _settings(),
            bytes("")
        );
    }

    function _lastSwapFeeIsBuy() private returns (bool isBuy) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("SwapFeeCharged(bytes32,address,uint256,uint24,bool)");
        for (uint256 i = logs.length; i > 0; --i) {
            Vm.Log memory entry = logs[i - 1];
            if (entry.topics[0] != topic) continue;
            (,, bool decoded) = abi.decode(entry.data, (uint256, uint24, bool));
            return decoded;
        }
        revert("no SwapFeeCharged event");
    }

    function _assertNewFeeSplit(uint256 beforeLiability) private view {
        uint256 totalFee = locker.totalClaimLiability(address(0)) - beforeLiability;
        assertGt(totalFee, 0);
        assertEq(manager.balanceOf(address(locker), 0), locker.totalClaimLiability(address(0)));

        uint256 creatorShare = locker.erc6909Claimable(CREATOR, address(0));
        uint256 buybackShare = locker.erc6909Claimable(address(buyback), address(0));
        uint256 rewardsShare = locker.erc6909Claimable(address(holderRewards), address(0));
        uint256 treasuryShare = locker.erc6909Claimable(address(treasury), address(0));
        assertEq(creatorShare + buybackShare + rewardsShare + treasuryShare, locker.totalClaimLiability(address(0)));
        assertEq(creatorShare, locker.totalClaimLiability(address(0)) * 7_000 / 10_000);
        // The 12.5% ecosystem slice is the same size in both directions - only its destination differs
        // (buyback on a buy, holder rewards on a sell) - so the combined figure is what stays invariant
        // across a mix of trades. Which bucket each direction fills is asserted on its own below.
        assertEq(buybackShare + rewardsShare, locker.totalClaimLiability(address(0)) * 1_250 / 10_000);
    }

    function _params(uint24 startHookFee, uint16 maxBuyBps)
        private
        view
        returns (ArchemistV4Launcher.LaunchParams memory params)
    {
        FeeRecipient[] memory recipients = new FeeRecipient[](1);
        recipients[0] = FeeRecipient({ admin: address(this), payout: CREATOR, bps: 10_000 });
        params = ArchemistV4Launcher.LaunchParams({
            name: startHookFee == 10_000 ? "Hook Token" : "Decay Token",
            symbol: startHookFee == 10_000 ? "HOOK" : "DECAY",
            salt: keccak256(abi.encode(startHookFee, maxBuyBps)),
            quote: address(0),
            targetFdvQuoteRaw: 1_000_000_000 ether,
            hook: address(hook),
            hookParams: abi.encode(
                AntiSnipeParams({ startHookFee: startHookFee, windowSeconds: 120, maxBuyBps: maxBuyBps })
            ),
            creatorShareBps: 7_000,
            recipients: recipients,
            creatorBuyAmount: 0,
            creatorBuyMinTokensOut: 0
        });
    }

    function _settings() private pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false });
    }

    receive() external payable { }
}
