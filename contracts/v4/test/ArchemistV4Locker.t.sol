// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { PoolManager } from "@uniswap/v4-core/src/PoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";

import { ArchemistHolderRewards } from "../src/ArchemistHolderRewards.sol";
import { ArchemistV4Locker } from "../src/ArchemistV4Locker.sol";
import { ArchemistV4Token } from "../src/ArchemistV4Token.sol";
import { FeeRecipient } from "../src/ArchemistV4Types.sol";
import { ArchemistDeploy } from "./Deploy.sol";

contract MockLockerLauncher {
    IPoolManager public immutable POOL_MANAGER;
    address public immutable TREASURY;
    address public immutable BUYBACK_VAULT;
    address public HOLDER_REWARDS;
    ArchemistV4Locker public locker;
    mapping(address => bool) public isKnownHook;

    constructor(IPoolManager manager_, address treasury_, address buybackVault_) {
        POOL_MANAGER = manager_;
        TREASURY = treasury_;
        BUYBACK_VAULT = buybackVault_;
        // These tests exercise the locker's position and fee mechanics against a plain hookless pool, so
        // the stub vouches for address(0). The real launcher never can - `registerHook` rejects
        // address(0) outright - which is how D1 ("every launch is hooked") reaches the locker.
        // `test_seedRequiresKnownHook` flips this off to prove the locker's own check is load-bearing.
        isKnownHook[address(0)] = true;
    }

    function setKnownHook(address hook, bool known) external {
        isKnownHook[hook] = known;
    }

    function setLocker(ArchemistV4Locker locker_) external {
        locker = locker_;
    }

    function setRewards(address rewards_) external {
        HOLDER_REWARDS = rewards_;
    }

    /// @dev Mirrors the real launcher's token lifecycle: register the address, deploy it, hand the
    /// whole supply to the locker. Doing it from here (rather than from the test contract) is what
    /// keeps the rewards contract's eligible-supply invariant intact - the minter must be an excluded
    /// address, and in production that is always the launcher.
    function deployToken(string calldata name_, string calldata symbol_, address quote)
        external
        returns (ArchemistV4Token deployed)
    {
        deployed = new ArchemistV4Token(
            name_, symbol_, 1_000_000_000 ether, HOLDER_REWARDS, address(locker), address(POOL_MANAGER)
        );
        ArchemistHolderRewards(payable(HOLDER_REWARDS)).register(address(deployed), quote);
        deployed.transfer(address(locker), deployed.totalSupply());
    }

    function seed(
        address token,
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint16 creatorShareBps,
        FeeRecipient[] calldata recipients
    ) external returns (PoolId, uint128, uint256) {
        return locker.seedPosition(token, key, tickLower, tickUpper, creatorShareBps, recipients);
    }
}

contract ArchemistV4LockerTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    bytes32 internal constant POSITION_SALT = keccak256("ARCHEMIST_V4_LOCKED_POSITION");
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant INITIAL_TICK = -60_000;

    address internal constant CREATOR = address(0x2000);
    address internal constant TREASURY = address(0x3000);
    address internal constant BUYBACK = address(0x3500);

    IPoolManager internal manager;
    PoolSwapTest internal swapRouter;
    MockLockerLauncher internal launcher;
    ArchemistV4Locker internal locker;
    ArchemistHolderRewards internal holderRewards;
    ArchemistV4Token internal token;
    PoolKey internal key;
    PoolId internal poolId;

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        swapRouter = new PoolSwapTest(manager);
        launcher = new MockLockerLauncher(manager, TREASURY, BUYBACK);
        locker = ArchemistDeploy.locker(manager, address(this), address(launcher));
        launcher.setLocker(locker);
        holderRewards = ArchemistDeploy.rewards(address(this), address(launcher), address(locker));
        launcher.setRewards(address(holderRewards));

        token = launcher.deployToken("Test", "TEST", address(0));
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: 3_000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        poolId = key.toId();
        manager.initialize(key, TickMath.getSqrtPriceAtTick(INITIAL_TICK));

        FeeRecipient[] memory recipients = new FeeRecipient[](1);
        recipients[0] = FeeRecipient({ admin: address(this), payout: CREATOR, bps: 10_000 });
        launcher.seed(address(token), key, TickMath.minUsableTick(TICK_SPACING), INITIAL_TICK, 7_000, recipients);
    }

    function test_seedOwnsDirectPoolManagerPosition() public view {
        ArchemistV4Locker.PositionInfo memory _pi = locker.positionInfo(poolId);
        address storedToken = _pi.token;
        int24 tickLower = _pi.tickLower;
        int24 tickUpper = _pi.tickUpper;
        uint128 liquidity = _pi.liquidity;
        bool exists = _pi.exists;
        (uint128 poolLiquidity,,) =
            manager.getPositionInfo(poolId, address(locker), tickLower, tickUpper, POSITION_SALT);

        assertTrue(exists);
        assertEq(storedToken, address(token));
        assertGt(liquidity, 0);
        assertEq(poolLiquidity, liquidity);
        assertLt(token.balanceOf(address(locker)), 1e12, "only boundary-rounding dust may remain");
    }

    /// @dev LK-02. The locker asks the launcher whether it has ever heard of the pool's hook, and a hook
    /// it has not heard of - address(0) included - can never back a position.
    function test_seedRequiresKnownHook() public {
        launcher.setKnownHook(address(0), false);
        ArchemistV4Token fresh = launcher.deployToken("Unknown Hook", "UNK", address(0));
        PoolKey memory freshKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(fresh)),
            fee: 3_000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        FeeRecipient[] memory recipients = new FeeRecipient[](1);
        recipients[0] = FeeRecipient({ admin: address(this), payout: CREATOR, bps: 10_000 });

        vm.expectRevert(ArchemistV4Locker.InvalidPool.selector);
        launcher.seed(address(fresh), freshKey, TickMath.minUsableTick(TICK_SPACING), INITIAL_TICK, 7_000, recipients);
    }

    /// @dev LK-01/LK-03. `recordHookFee` is reachable only by a hook the launcher knows AND only for the
    /// pool that hook is actually bound to - and even then only for a fee genuinely backed by ERC-6909
    /// claims this locker holds. That last check is the one boundary that makes an open hook registry
    /// safe, so it is asserted against a hook the registry does know.
    function test_recordHookFeeFromKnownHooksOnly() public {
        address rogue = address(0xF00DBEEF);
        vm.prank(rogue);
        vm.expectRevert(ArchemistV4Locker.NotAuthorized.selector);
        locker.recordHookFee(poolId, Currency.wrap(address(0)), 1 ether, true);

        launcher.setKnownHook(rogue, true);
        vm.prank(rogue);
        // Known now, but this pool's key names address(0) as its hook, not `rogue`.
        vm.expectRevert(ArchemistV4Locker.NotAuthorized.selector);
        locker.recordHookFee(poolId, Currency.wrap(address(0)), 1 ether, true);
    }

    function test_backingCheckStopsRogueHook() public {
        // A hook the registry knows AND that this pool is bound to, recording a fee it never minted.
        vm.prank(address(0));
        vm.expectRevert(ArchemistV4Locker.UnexpectedDelta.selector);
        locker.recordHookFee(poolId, Currency.wrap(address(0)), 1 ether, true);
    }

    function test_nonLauncherCannotSeed() public {
        FeeRecipient[] memory recipients = new FeeRecipient[](1);
        recipients[0] = FeeRecipient({ admin: address(this), payout: CREATOR, bps: 10_000 });

        vm.expectRevert(ArchemistV4Locker.NotAuthorized.selector);
        locker.seedPosition(address(token), key, TickMath.minUsableTick(TICK_SPACING), INITIAL_TICK, 7_000, recipients);
    }

    function test_seedRejectsCreatorShareOutsideHardBounds() public {
        (ArchemistV4Token freshToken, PoolKey memory freshKey,) = _freshPool("Fresh1", "FRESH1");
        FeeRecipient[] memory recipients = new FeeRecipient[](1);
        recipients[0] = FeeRecipient({ admin: address(this), payout: CREATOR, bps: 10_000 });

        vm.expectRevert(ArchemistV4Locker.InvalidFeeSplit.selector);
        launcher.seed(
            address(freshToken), freshKey, TickMath.minUsableTick(TICK_SPACING), INITIAL_TICK, 4_999, recipients
        );

        vm.expectRevert(ArchemistV4Locker.InvalidFeeSplit.selector);
        launcher.seed(
            address(freshToken), freshKey, TickMath.minUsableTick(TICK_SPACING), INITIAL_TICK, 8_001, recipients
        );
    }

    function test_creatorShareBpsControlsActualSplit() public {
        (ArchemistV4Token freshToken, PoolKey memory freshKey,) = _freshPool("Fresh2", "FRESH2");
        FeeRecipient[] memory recipients = new FeeRecipient[](1);
        recipients[0] = FeeRecipient({ admin: address(this), payout: CREATOR, bps: 10_000 });
        (PoolId freshPoolId,,) = launcher.seed(
            address(freshToken), freshKey, TickMath.minUsableTick(TICK_SPACING), INITIAL_TICK, 8_000, recipients
        );

        vm.deal(address(this), 1 ether);
        swapRouter.swap{ value: 1 ether }(
            freshKey,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );

        (uint256 amount0,) = locker.collect(freshPoolId);
        assertGt(amount0, 0);
        assertEq(locker.claimable(CREATOR, address(0)), amount0 * 8_000 / 10_000, "80% creator share honored");
        assertEq(locker.claimable(BUYBACK, address(0)), amount0 * 1_250 / 10_000, "buyback bps stays fixed");
    }

    function _freshPool(string memory name_, string memory symbol_)
        private
        returns (ArchemistV4Token freshToken, PoolKey memory freshKey, PoolId freshPoolId)
    {
        freshToken = launcher.deployToken(name_, symbol_, address(0));
        freshKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(freshToken)),
            fee: 3_000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        freshPoolId = freshKey.toId();
        manager.initialize(freshKey, TickMath.getSqrtPriceAtTick(INITIAL_TICK));
    }

    function test_collectSplitsAndClaimsNativeFees() public {
        vm.deal(address(this), 10 ether);
        swapRouter.swap{ value: 1 ether }(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );

        (uint256 amount0,) = locker.collect(poolId);
        assertGt(amount0, 0);

        uint256 creatorClaim = locker.claimable(CREATOR, address(0));
        uint256 buybackClaim = locker.claimable(BUYBACK, address(0));
        uint256 protocolClaim = locker.claimable(TREASURY, address(0));
        assertEq(creatorClaim + buybackClaim + protocolClaim, amount0);
        assertEq(creatorClaim, amount0 * 7_000 / 10_000);
        assertEq(buybackClaim, amount0 * 1_250 / 10_000);
        assertEq(locker.totalLiability(address(0)), amount0);
        assertEq(address(locker).balance, amount0);

        uint256 beforeBalance = CREATOR.balance;
        vm.prank(CREATOR);
        locker.claim(address(0), CREATOR);
        assertEq(CREATOR.balance - beforeBalance, creatorClaim);
        assertEq(locker.claimable(CREATOR, address(0)), 0);
        assertEq(locker.totalLiability(address(0)), buybackClaim + protocolClaim);
    }

    function test_collectAccountsForFeesInBothCurrencies() public {
        uint256 lockedDust = token.balanceOf(address(locker));
        vm.deal(address(this), 2 ether);
        swapRouter.swap{ value: 1 ether }(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
        locker.collect(poolId);

        uint256 tokensToSell = token.balanceOf(address(this)) / 2;
        assertGt(tokensToSell, 0);
        assertTrue(token.approve(address(swapRouter), tokensToSell));
        // Safe: launch supply is 1e27, far below int256.max.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 exactTokenInput = -int256(tokensToSell);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: exactTokenInput, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
        (, uint256 amount1) = locker.collect(poolId);

        assertGt(amount1, 0);
        assertEq(token.balanceOf(address(locker)), locker.totalLiability(address(token)) + lockedDust);
        assertEq(
            locker.claimable(CREATOR, address(token)) + locker.claimable(BUYBACK, address(token))
                + locker.claimable(TREASURY, address(token)),
            amount1
        );
    }

    function test_recipientPayoutChangeDoesNotMoveExistingCredit() public {
        address newPayout = address(0x4000);
        _swapAndCollect(1 ether);
        uint256 oldCredit = locker.claimable(CREATOR, address(0));
        assertGt(oldCredit, 0);

        locker.updateRecipientPayout(poolId, 0, newPayout);
        _swapAndCollect(1 ether);

        assertEq(locker.claimable(CREATOR, address(0)), oldCredit);
        assertGt(locker.claimable(newPayout, address(0)), 0);
    }

    function testFuzz_feeSplitConserves(uint96 swapAmount) public {
        uint256 amount = bound(uint256(swapAmount), 1e12, 2 ether);
        _swapAndCollect(amount);
        assertEq(
            address(locker).balance,
            locker.totalLiability(address(0)),
            "native liabilities must remain fully collateralized"
        );
    }

    function _swapAndCollect(uint256 amount) private {
        vm.deal(address(this), amount);
        // Safe: fuzz bounds cap `amount` at 2 ether, far below int256.max.
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 exactInput = -int256(amount);
        swapRouter.swap{ value: amount }(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: exactInput, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({ takeClaims: false, settleUsingBurn: false }),
            bytes("")
        );
        locker.collect(poolId);
    }

    receive() external payable { }

    /// @dev **LK-08.** `ArchemistV4Locker`'s own NatSpec promises that "there is no function on this
    /// contract, reachable by anyone including the owner, that decreases `positionInfo.liquidity` or
    /// transfers the position out", and says *this test* enumerates the ABI to prove it. The test did
    /// not exist. Raised in review, along with the observation that a promise a reader is told is
    /// tested is worse than one they are told to check themselves.
    ///
    /// So it enumerates for real: every state-changing entry in the compiled ABI must appear on the
    /// list below. Adding any new mutating function to the locker fails this test until someone puts it
    /// on the list, which is the moment to ask whether it can move a position. A name-by-name check for
    /// `withdraw`/`release`/`transferFrom` would only ever catch the spellings somebody thought of.
    ///
    /// The list itself is the argument, so it is annotated rather than just enumerated:
    ///   - `seedPosition` only ever ADDS liquidity, and only the launcher may call it;
    ///   - `collect` takes FEES from the position manager; it cannot decrease liquidity;
    ///   - `claim`, `recordHookFee`, `updateRecipientPayout`, `transferRecipientAdmin`,
    ///     `acceptRecipientAdmin` touch the fee ledger, never the position;
    ///   - `unlockCallback` is PoolManager's callback into the frame this contract itself opened;
    ///   - `initialize`, `transferOwnership`, `acceptOwnership`, `upgradeToAndCall` are lifecycle.
    ///
    /// `upgradeToAndCall` is the honest caveat and is stated in the contract too: an upgrade can do
    /// anything, including adding a withdrawal. What bounds it is that the owner is a 48-hour
    /// TimelockController and the proposal is public the whole time - not that it is impossible.
    function test_lockerHasNoWithdrawalPathForLiquidity() public view {
        string[12] memory allowed = [
            "acceptOwnership",
            "acceptRecipientAdmin",
            "claim",
            "collect",
            "initialize",
            "recordHookFee",
            "seedPosition",
            "transferOwnership",
            "transferRecipientAdmin",
            "unlockCallback",
            "updateRecipientPayout",
            "upgradeToAndCall"
        ];

        string memory artifact = vm.readFile("out/ArchemistV4Locker.sol/ArchemistV4Locker.json");
        uint256 i;
        uint256 mutating;
        while (vm.keyExistsJson(artifact, string.concat(".abi[", vm.toString(i), "]"))) {
            string memory at = string.concat(".abi[", vm.toString(i), "]");
            ++i;
            require(i < 512, "implausible ABI");
            if (!_eqStr(vm.parseJsonString(artifact, string.concat(at, ".type")), "function")) continue;

            string memory mutability = vm.parseJsonString(artifact, string.concat(at, ".stateMutability"));
            if (_eqStr(mutability, "view") || _eqStr(mutability, "pure")) continue;

            string memory name = vm.parseJsonString(artifact, string.concat(at, ".name"));
            bool listed;
            for (uint256 k; k < allowed.length; ++k) {
                if (_eqStr(name, allowed[k])) listed = true;
            }
            assertTrue(
                listed,
                string.concat(
                    "ArchemistV4Locker grew a state-changing function that this test has never seen: ",
                    name,
                    ". Decide whether it can move a locked position, then add it to the list."
                )
            );
            ++mutating;
        }

        // And the list is not stale in the other direction either - a check that enumerates nothing
        // passes vacuously, which is exactly the failure this whole test exists to replace.
        assertEq(mutating, allowed.length, "the allow-list and the ABI must describe the same surface");
    }

    function _eqStr(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
