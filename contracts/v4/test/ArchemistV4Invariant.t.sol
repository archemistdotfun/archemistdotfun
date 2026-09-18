// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";

import { PoolManager } from "@uniswap/v4-core/src/PoolManager.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { SafeCast } from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolDonateTest } from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
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

contract InvariantReceiver {
    receive() external payable { }
}

contract ArchemistV4Handler is Test {
    using SafeCast for uint256;

    PoolSwapTest public immutable swapRouter;
    PoolDonateTest public immutable donateRouter;
    ArchemistV4Locker public immutable locker;
    ArchemistV4Token public immutable token;
    ArchemistHolderRewards public immutable rewards;
    PoolKey public key;
    PoolId public poolId;

    /// @dev Extra holders, so eligible supply is split across several accounts rather than sitting
    /// entirely with the handler - that is the case where a pro-rata bug would actually show up.
    address[3] public peers;

    uint256 public ghostSuccessfulSwaps;
    uint256 public ghostClaims;
    uint256 public ghostRewardPayouts;

    constructor(
        IPoolManager manager,
        ArchemistV4Locker locker_,
        ArchemistV4Token token_,
        ArchemistHolderRewards rewards_,
        PoolKey memory key_,
        PoolId poolId_
    ) {
        locker = locker_;
        token = token_;
        rewards = rewards_;
        key = key_;
        poolId = poolId_;
        swapRouter = new PoolSwapTest(manager);
        donateRouter = new PoolDonateTest(manager);
        token_.approve(address(swapRouter), type(uint256).max);
        for (uint256 i; i < 3; ++i) {
            peers[i] = address(new InvariantReceiver());
        }
    }

    function transferToken(uint96 seed, uint8 peerSeed) external {
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) return;
        address peer = peers[peerSeed % 3];
        try token.transfer(peer, _boundSeed(uint256(seed), 1, balance)) { } catch { }
    }

    function transferTokenBack(uint96 seed, uint8 peerSeed) external {
        address peer = peers[peerSeed % 3];
        uint256 balance = token.balanceOf(peer);
        if (balance == 0) return;
        vm.prank(peer);
        try token.transfer(address(this), _boundSeed(uint256(seed), 1, balance)) { } catch { }
    }

    function claimHolderReward() external {
        if (rewards.earned(address(token), address(this)) == 0) return;
        try rewards.claim(address(token), address(this)) returns (uint256 paid) {
            ghostRewardPayouts += paid;
        } catch { }
    }

    function pushHolderRewards() external {
        address[] memory list = new address[](4);
        list[0] = address(this);
        for (uint256 i; i < 3; ++i) {
            list[i + 1] = peers[i];
        }
        try rewards.claimFor(address(token), list) returns (uint256 paid) {
            ghostRewardPayouts += paid;
        } catch { }
    }

    function buyExactInput(uint96 seed) external {
        uint256 amount = _boundSeed(uint256(seed), 1e12, 0.1 ether);
        if (address(this).balance < amount) return;
        try swapRouter.swap{ value: amount }(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -amount.toInt256(), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            _settings(),
            bytes("")
        ) {
            ++ghostSuccessfulSwaps;
        } catch { }
    }

    function buyExactOutput(uint80 seed) external {
        uint256 tokenOut = _boundSeed(uint256(seed), 1e9, 1e17);
        uint256 value = 0.1 ether;
        if (address(this).balance < value) return;
        try swapRouter.swap{ value: value }(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: tokenOut.toInt256(), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            _settings(),
            bytes("")
        ) {
            ++ghostSuccessfulSwaps;
        } catch { }
    }

    function sellExactInput(uint96 seed) external {
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) return;
        uint256 amount = _boundSeed(uint256(seed), 1, balance);
        try swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -amount.toInt256(), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            _settings(),
            bytes("")
        ) {
            ++ghostSuccessfulSwaps;
        } catch { }
    }

    function sellExactOutput(uint64 seed) external {
        if (token.balanceOf(address(this)) == 0) return;
        uint256 quoteOut = _boundSeed(uint256(seed), 1, 1e15);
        try swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: quoteOut.toInt256(), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            _settings(),
            bytes("")
        ) {
            ++ghostSuccessfulSwaps;
        } catch { }
    }

    function claim() external {
        if (locker.claimable(address(this), address(0)) == 0) return;
        try locker.claim(address(0), address(this)) {
            ++ghostClaims;
        } catch { }
    }

    function donateAndCollect(uint80 seed) external {
        uint256 amount = _boundSeed(uint256(seed), 1, 1e14);
        if (address(this).balance < amount) return;
        try donateRouter.donate{ value: amount }(key, amount, 0, bytes("")) {
            try locker.collect(poolId) { } catch { }
        } catch { }
    }

    function advanceTime(uint16 seed) external {
        vm.warp(block.timestamp + _boundSeed(uint256(seed), 1, 180));
    }

    function _settings() private pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false });
    }

    function _boundSeed(uint256 value, uint256 minimum, uint256 maximum) private pure returns (uint256) {
        return minimum + value % (maximum - minimum + 1);
    }

    receive() external payable { }
}

contract ArchemistV4InvariantTest is StdInvariant, Test {
    uint160 internal constant REQUIRED_FLAGS = 0x28CC;

    IPoolManager internal manager;
    InvariantReceiver internal treasury;
    InvariantReceiver internal buyback;
    ArchemistV4Locker internal locker;
    ArchemistHolderRewards internal holderRewards;
    ArchemistV4Handler internal handler;
    ArchemistV4Launcher internal launcher;
    ArchemistV4Token internal token;

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        treasury = new InvariantReceiver();
        buyback = new InvariantReceiver();
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

        bytes memory args = abi.encode(manager, address(launcher), address(locker), address(buyback));
        (, bytes32 salt) = HookMiner.find(address(this), REQUIRED_FLAGS, type(ArchemistV4Hook).creationCode, args);
        ArchemistV4Hook hook =
            new ArchemistV4Hook{ salt: salt }(manager, address(launcher), address(locker), address(buyback));
        launcher.configureSystemOnce(address(locker), address(buyback), address(holderRewards));
        launcher.registerHook(address(hook));
        launcher.enableCreate();

        FeeRecipient[] memory recipients = new FeeRecipient[](1);
        recipients[0] = FeeRecipient({ admin: address(this), payout: address(this), bps: 10_000 });
        ArchemistV4Launcher.LaunchParams memory params = ArchemistV4Launcher.LaunchParams({
            name: "Invariant Token",
            symbol: "INV",
            salt: keccak256("invariant"),
            quote: address(0),
            targetFdvQuoteRaw: 1_000_000_000 ether,
            hook: address(hook),
            hookParams: abi.encode(AntiSnipeParams({ startHookFee: 30_000, windowSeconds: 120, maxBuyBps: 100 })),
            creatorShareBps: 7_000,
            recipients: recipients,
            creatorBuyAmount: 0,
            creatorBuyMinTokensOut: 0
        });
        (address tokenAddress, PoolId poolId) = launcher.createToken(params);
        token = ArchemistV4Token(tokenAddress);
        PoolKey memory key = locker.getPoolKey(poolId);
        handler = new ArchemistV4Handler(manager, locker, token, holderRewards, key, poolId);
        locker.updateRecipientPayout(poolId, 0, address(handler));
        vm.deal(address(handler), 100 ether);
        targetContract(address(handler));
    }

    function invariant_nativeLiabilitiesRemainFullyBacked() public view {
        uint256 claimBacking = manager.balanceOf(address(locker), 0);
        uint256 claimLiability = locker.totalClaimLiability(address(0));
        uint256 realLiability = locker.totalLiability(address(0)) - claimLiability;
        assertEq(claimBacking, claimLiability);
        assertGe(address(locker).balance, realLiability);
    }

    function invariant_beneficiaryCreditsConserveTotalLiability() public view {
        uint256 sum = locker.claimable(address(handler), address(0)) + locker.claimable(address(buyback), address(0))
            + locker.claimable(address(treasury), address(0)) + locker.claimable(address(holderRewards), address(0));
        assertEq(sum, locker.totalLiability(address(0)));
    }

    /// @dev The one assumption every reward calculation rests on: the denominator really is the float.
    /// Stated as "total supply minus everything held by an excluded address" so it stays exact without
    /// having to enumerate holders.
    function invariant_eligibleSupplyMatchesCirculatingFloat() public view {
        (,, uint256 eligibleSupply,) = holderRewards.getTokenState(address(token));
        uint256 excludedHeld = token.balanceOf(address(manager)) + token.balanceOf(address(locker))
            + token.balanceOf(address(launcher)) + token.balanceOf(address(holderRewards))
            + token.balanceOf(address(token));
        assertEq(eligibleSupply, token.totalSupply() - excludedHeld);
    }

    /// @dev Solvency: what holders are collectively entitled to can never exceed what has actually been
    /// set aside for them. Rounding leaves dust on the contract's side of this inequality, never the
    /// holders' side.
    function invariant_holderEntitlementsStayBacked() public view {
        uint256 owedToHolders = holderRewards.earned(address(token), address(handler));
        for (uint256 i; i < 3; ++i) {
            owedToHolders += holderRewards.earned(address(token), handler.peers(i));
        }
        uint256 backing = locker.claimable(address(holderRewards), address(0)) + address(holderRewards).balance;
        assertLe(owedToHolders, backing);
    }

    function invariant_claimBackedCreditNeverExceedsTotalCredit() public view {
        assertLe(locker.erc6909Claimable(address(handler), address(0)), locker.claimable(address(handler), address(0)));
        assertLe(locker.erc6909Claimable(address(buyback), address(0)), locker.claimable(address(buyback), address(0)));
        assertLe(
            locker.erc6909Claimable(address(treasury), address(0)), locker.claimable(address(treasury), address(0))
        );
        assertLe(
            locker.erc6909Claimable(address(holderRewards), address(0)),
            locker.claimable(address(holderRewards), address(0))
        );
    }
}
