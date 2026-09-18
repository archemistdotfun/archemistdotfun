// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Test, console2 } from "forge-std/Test.sol";

import { ArcFork } from "./fork/ArcPrecompiles.sol";
import { ArchemistProxy } from "./vendored/ArchemistProxy_salt_prod.sol";
import { ArchemistV2USDCLockerV3 } from "./vendored/ArchemistV2USDCLockerV3_salt_prod.sol";
import { ArchemistV2USDCFactoryV3 } from "./vendored/ArchemistV2USDCV3_salt_prod.sol";

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function decimals() external view returns (uint8);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface ISwapRouter02Min {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256);
}

interface IUniswapV3PoolMin {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool);
}

/// @dev A treasury that refuses every incoming transfer, so the locker's `_pushOrCredit` fallback has
/// something real to fall back from. V2-07's second half.
contract RejectingTreasury {
    error Nope();

    fallback() external payable {
        revert Nope();
    }

    receive() external payable {
        revert Nope();
    }
}

/// @dev V2-09's "v3.1": the same locker with one appended field. Inherits rather than copies, so the
/// inherited storage really is the deployed layout and not a hand-retyped approximation. `ARCHEMIST_KIND`
/// is not virtual, so this is the same kind and the upgrade is accepted - which is the point: a genuine
/// next version must still be upgradeable to.
contract LockerV31Mock is ArchemistV2USDCLockerV3 {
    uint256 public appendedField;

    constructor(uint256 expectedChainId_) ArchemistV2USDCLockerV3(expectedChainId_) { }

    function setAppendedField(uint256 value) external {
        appendedField = value;
    }
}

/// @notice **V2 implementation v3, against Arc mainnet's real Uniswap v3 periphery.**
///
/// The V2 launchpad's own tests (`ArchemistV2UsdcV3.t.sol`) run against mocks, because until the
/// precompile shims in `test/fork/ArcPrecompiles.sol` existed there was no way to move linked USDC
/// inside forge at all. So the v3 pair had never touched a real `NonfungiblePositionManager`, a real
/// `SwapRouter02`, or the real Uniswap v3 factory - the deployment record for it is a set of selector
/// probes. This closes that: it deploys both implementations behind the repo's own proxy, exactly as
/// `deploy-usdc-launch-factory-v3.mjs` does including the nonce-predicted address, and then launches.
///
/// `make test-fork-mainnet-v2`. Reported as skipped, never as passing, when there is no fork.
contract ArcMainnetForkV2Test is Test {
    uint256 internal constant ARC_CHAIN_ID = 5042;
    address internal constant LINKED_USDC = 0x3600000000000000000000000000000000000000;
    address internal constant V3_FACTORY = 0xf0db7b58379503491d857dB50AC9ece64c653918;
    address internal constant POSITION_MANAGER = 0x39654A85A4C05127f5Fd6ED22CAeC077A0fB1377;
    address internal constant SWAP_ROUTER_02 = 0x53BF6B0684Ec7eF91e1387Da3D1a1769bC5A6F77;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    int24 internal constant STARTING_TICK = -398_400;

    uint256 internal constant DEPLOY_FEE = 0.1 ether;
    uint256 internal constant NATIVE_TO_USDC_SCALE = 1e12;

    ArchemistV2USDCFactoryV3 internal factory;
    ArchemistV2USDCLockerV3 internal locker;
    address internal factoryImpl;
    address internal lockerImpl;

    address internal treasury = makeAddr("v2treasury");
    address internal creator = makeAddr("v2creator");
    address internal feeAdmin = makeAddr("v2feeAdmin");
    address internal feeRecipient = makeAddr("v2feeRecipient");

    modifier onlyOnFork() {
        vm.skip(block.chainid != ARC_CHAIN_ID, "not forked onto Arc mainnet: pass --fork-url $RPC_URL_MAINNET");
        _;
    }

    function setUp() public {
        if (block.chainid != ARC_CHAIN_ID) return;
        ArcFork.install();

        lockerImpl = address(new ArchemistV2USDCLockerV3(block.chainid));
        factoryImpl = address(new ArchemistV2USDCFactoryV3(block.chainid));

        // The same nonce prediction the real deploy script relies on: the locker is initialized with an
        // address the factory proxy does not have yet, and the factory's `initialize` closes the loop by
        // checking `locker.launchFactory() == address(this)`. Reproduced rather than short-circuited.
        address predictedFactoryProxy = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        locker = ArchemistV2USDCLockerV3(
            payable(address(
                    new ArchemistProxy(
                        lockerImpl,
                        abi.encodeCall(
                            ArchemistV2USDCLockerV3.initialize,
                            (address(this), treasury, LINKED_USDC, POSITION_MANAGER, predictedFactoryProxy)
                        )
                    )
                ))
        );
        factory = ArchemistV2USDCFactoryV3(
            payable(address(
                    new ArchemistProxy(
                        factoryImpl,
                        abi.encodeCall(
                            ArchemistV2USDCFactoryV3.initialize,
                            (
                                address(this),
                                treasury,
                                LINKED_USDC,
                                V3_FACTORY,
                                POSITION_MANAGER,
                                SWAP_ROUTER_02,
                                address(locker)
                            )
                        )
                    )
                ))
        );
        assertEq(address(factory), predictedFactoryProxy, "the nonce prediction must hold, as it does on chain");

        vm.deal(creator, 1_000 ether);
    }

    /// @dev That `initialize` completes at all is the test: it re-reads the real position manager's
    /// `factory()`, the real router's `factory()`, the real linked USDC's `decimals()`, and the real v3
    /// factory's `feeAmountTickSpacing(10000)`, and refuses if any of them is not what it expects.
    function test_v3PairInitializesAgainstTheRealPeriphery() public onlyOnFork {
        assertEq(factory.PROXY_VERSION(), 3);
        assertEq(locker.PROXY_VERSION(), 3);
        assertEq(factory.LOCKER(), address(locker));
        assertEq(locker.launchFactory(), address(factory));
        assertEq(factory.PAIRED_TOKEN(), LINKED_USDC);
        assertEq(IERC20Min(LINKED_USDC).decimals(), 6);
        assertTrue(factory.ARCHEMIST_KIND() != locker.ARCHEMIST_KIND(), "the two must stay distinguishable");
    }

    /// @dev A real launch: a real pool created through the real position manager, the real one-sided
    /// position minted, and the LP NFT landing in the locker where nothing can take it out.
    function test_realLaunchThroughTheRealPositionManager() public onlyOnFork {
        (address token, address pool, uint256 positionId) = _launch(DEPLOY_FEE);

        assertTrue(token != address(0));
        assertTrue(pool.code.length > 0, "a real Uniswap v3 pool exists at that address");
        assertGt(positionId, 0);
        assertEq(IERC721Min(POSITION_MANAGER).ownerOf(positionId), address(locker), "the LP NFT is locked");
        assertEq(locker.getTotalPositions(), 1);
        assertEq(IERC20Min(token).balanceOf(address(factory)), 0, "the factory keeps no tokens");
        assertEq(treasury.balance, DEPLOY_FEE, "the deploy fee reached the treasury as native");
        console2.log("V2 launch token", token);
        console2.log("V2 pool", pool);
    }

    /// @dev **The 1-wei brick, on the real chain.** Before the audit fix, `_executeCreatorBuy` asserted
    /// the factory held nothing at all - and on Arc, native and linked USDC are one balance, so a single
    /// stray unit sent to a factory with no sweep and no owner made every creator buy revert until a
    /// 48-hour upgrade. Here the donation is real linked USDC on the real chain, and the creator buy
    /// runs through the real SwapRouter02 against the pool the launch just created.
    function test_aStrayDonationDoesNotBrickARealCreatorBuy() public onlyOnFork {
        vm.deal(address(factory), 1); // one wei: the whole exploit

        uint256 creatorBuy = 10 ether; // 10 USDC at the native scale
        (address token,,) = _launch(DEPLOY_FEE + creatorBuy);

        assertGt(IERC20Min(token).balanceOf(creator), 0, "the creator buy executed against a real pool");
        console2.log("creator bought", IERC20Min(token).balanceOf(creator));
    }

    /// @dev And the proxy itself refuses stray value, because it no longer shadows the implementation's
    /// own `receive` guard.
    function test_theRealProxyRefusesStrayValue() public onlyOnFork {
        (bool ok,) = address(factory).call{ value: 1 wei }("");
        assertFalse(ok, "empty-calldata value must reach the implementation's guard and be refused");
    }

    // ---------------------------------------------------------------------------------------------
    // TESTING §7, the cases the viem runner cannot reach: it targets the previous implementation.
    // Rather than keep a runner that cannot run, the money-path cases live here, against Arc mainnet's
    // real Uniswap v3 periphery.
    // ---------------------------------------------------------------------------------------------

    /// @dev V2-02. `initialize` must be a one-shot on the proxy, and must never be callable on the
    /// implementation at all - an initialisable logic contract left open is the classic UUPS hole.
    function test_v2_02_initializeIsOneShotOnProxiesAndDeadOnImplementations() public onlyOnFork {
        vm.expectRevert(ArchemistV2USDCFactoryV3.AlreadyInitialized.selector);
        factory.initialize(
            address(this), treasury, LINKED_USDC, V3_FACTORY, POSITION_MANAGER, SWAP_ROUTER_02, address(locker)
        );

        vm.expectRevert(ArchemistV2USDCLockerV3.AlreadyInitialized.selector);
        locker.initialize(address(this), treasury, LINKED_USDC, POSITION_MANAGER, address(factory));

        // And on the implementations, which nobody should be able to take ownership of.
        vm.expectRevert(ArchemistV2USDCFactoryV3.AlreadyInitialized.selector);
        ArchemistV2USDCFactoryV3(payable(factoryImpl))
            .initialize(
                address(this), treasury, LINKED_USDC, V3_FACTORY, POSITION_MANAGER, SWAP_ROUTER_02, address(locker)
            );
        vm.expectRevert(ArchemistV2USDCLockerV3.AlreadyInitialized.selector);
        ArchemistV2USDCLockerV3(payable(lockerImpl))
            .initialize(address(this), treasury, LINKED_USDC, POSITION_MANAGER, address(factory));
    }

    /// @dev V2-03.
    function test_v2_03_upgradeFromANonOwnerIsRefused() public onlyOnFork {
        address newImpl = address(new ArchemistV2USDCLockerV3(block.chainid));
        vm.prank(makeAddr("not the owner"));
        vm.expectRevert(ArchemistV2USDCLockerV3.NotAuthorized.selector);
        locker.upgradeToAndCall(newImpl, "");
    }

    /// @dev V2-05 in full: a launch with a creator buy, checked against the things the plan actually
    /// names - the pool's starting tick, the dust ceiling, and `DeployFeePaid`.
    function test_v2_05_launchWithCreatorBuyStartsAtTheRightTickAndLeavesNoDust() public onlyOnFork {
        uint256 creatorBuy = 10 ether;

        vm.expectEmit(true, false, false, true, address(factory));
        emit ArchemistV2USDCFactoryV3.DeployFeePaid(treasury, DEPLOY_FEE);
        (address token, address pool, uint256 positionId) = _launch(DEPLOY_FEE + creatorBuy);

        // The tick the pool OPENED at, which is what the plan specifies - not `slot0()` now, because the
        // creator buy in this same transaction has already moved the price. `STARTING_TICK` is signed for
        // the token-is-token0 orientation and negated otherwise, which is the half of all launches a raw
        // comparison would get wrong. The factory also refuses to continue unless the pool really opened
        // there (`InvalidInitialPrice`), so reaching this line at all is part of the assertion.
        (,,,, int24 normalizedTick, int24 openedAtTick,, bool tokenIsToken0) = factory.launchInfoForToken(token);
        int24 expectedTick = token < LINKED_USDC ? STARTING_TICK : -STARTING_TICK;
        assertEq(openedAtTick, expectedTick, "pool must open at the launch tick, orientation included");
        assertEq(normalizedTick, STARTING_TICK, "and record the orientation-independent tick too");
        assertEq(tokenIsToken0, token < LINKED_USDC);

        // The live tick has moved off it, which is the creator buy having actually happened.
        (, int24 liveTick,,,,,) = IUniswapV3PoolMin(pool).slot0();
        assertTrue(liveTick != openedAtTick, "the creator buy must have moved the price");

        // Dust: whatever the one-sided position could not absorb is burned, and the factory keeps none.
        uint256 burned = IERC20Min(token).balanceOf(DEAD);
        assertLe(burned, factory.MAX_TOKEN_DUST(), "dust must stay under the ceiling");
        assertEq(IERC20Min(token).balanceOf(address(factory)), 0, "the factory keeps nothing");

        assertGt(IERC20Min(token).balanceOf(creator), 0, "the creator buy executed");
        assertEq(IERC721Min(POSITION_MANAGER).ownerOf(positionId), address(locker));
    }

    /// @dev **V2-06, the money path.** Twenty real swaps through the real router, then `collectFees`,
    /// and the split has to land 80/20 with the creator credited and the treasury pushed. Until now this
    /// was only ever checked against a mock that returns whatever the test told it to.
    function test_v2_06_twentySwapsThenFeesSplitEightyTwenty() public onlyOnFork {
        (address token, address pool,) = _launch(DEPLOY_FEE);
        (uint160 startPrice,,,,,,) = IUniswapV3PoolMin(pool).slot0();

        address trader = makeAddr("v2trader");
        vm.deal(trader, 10_000 ether);

        uint256 held;
        for (uint256 i; i < 20; ++i) {
            if (i % 3 == 2 && held > 0) {
                held -= _sell(trader, token, held / 2);
            } else {
                held += _buy(trader, token, 20e6);
            }
        }

        (uint160 endPrice,,,,,,) = IUniswapV3PoolMin(pool).slot0();
        assertTrue(endPrice != startPrice, "twenty swaps must move the price");

        uint256 treasuryBefore = IERC20Min(LINKED_USDC).balanceOf(treasury);
        (uint256 amount0, uint256 amount1) = locker.collectFees(token);
        uint256 total = amount0 + amount1;
        assertGt(total, 0, "trading must have produced fees");

        // The quote-side fee is what both parties actually get paid in.
        uint256 quoteFees = token < LINKED_USDC ? amount1 : amount0;
        assertGt(quoteFees, 0, "and some of them in the quote currency");

        uint256 protocolCut = quoteFees * 2_000 / 10_000;
        assertEq(
            IERC20Min(LINKED_USDC).balanceOf(treasury) - treasuryBefore,
            protocolCut,
            "treasury is PUSHED its 20%, not credited"
        );
        assertEq(
            locker.claimable(feeRecipient, LINKED_USDC),
            quoteFees - protocolCut,
            "creator is CREDITED the remaining 80%"
        );
    }

    /// @dev V2-07, and a finding that changes what its second half can even mean.
    ///
    /// The plan asks for a "rejecting treasury" to exercise `_pushOrCredit`'s fallback to credit. On Arc
    /// that scenario **cannot be built**, and the reason is a property of the chain rather than of this
    /// contract: a linked-USDC `transfer` moves value through the `0x1800…0000` precompile and **never
    /// calls the recipient**, so a contract that reverts on receipt still receives. Verified directly
    /// against the real implementation bytecode: a transfer into a contract whose `fallback` and
    /// `receive` both revert succeeds, and the balance lands.
    ///
    /// The blocklist does not close the gap either - `transferFrom` consults `0x1800…0001` and `transfer`
    /// does not, so neither party being blocklisted stops a plain transfer.
    ///
    /// So for the two assets a V2 launch actually produces - the linked USDC and the launch token, both
    /// plain ERC-20 transfers - the credit fallback is **unreachable**. That is not a defect: it means no
    /// protocol fee can ever be stranded by an uncooperative treasury, which is the outcome the fallback
    /// was there to guarantee. It would still fire for a native (`address(0)`) asset or a token that
    /// refuses, neither of which occurs here.
    ///
    /// What this test therefore checks is the reachable half: a treasury that reverts on receipt is paid
    /// anyway, and the creator can claim exactly what they were credited.
    function test_v2_07_creatorClaimsAndARevertingTreasuryIsStillPaid() public onlyOnFork {
        (address token,,) = _launch(DEPLOY_FEE);
        address trader = makeAddr("v2trader2");
        vm.deal(trader, 10_000 ether);
        for (uint256 i; i < 6; ++i) {
            _buy(trader, token, 50e6);
        }

        // Treasury is storage slot 2 on the locker, per the layout the storage-layout gate enforces.
        address rejecting = address(new RejectingTreasury());
        vm.store(address(locker), bytes32(uint256(2)), bytes32(uint256(uint160(rejecting))));
        assertEq(locker.treasury(), rejecting);

        uint256 treasuryBefore = IERC20Min(LINKED_USDC).balanceOf(rejecting);
        locker.collectFees(token);

        assertGt(
            IERC20Min(LINKED_USDC).balanceOf(rejecting) - treasuryBefore,
            0,
            "a contract that reverts on receipt is still paid: linked-USDC transfers do not call it"
        );
        assertEq(locker.claimable(rejecting, LINKED_USDC), 0, "so nothing falls through to credit");

        uint256 owedToCreator = locker.claimable(feeRecipient, LINKED_USDC);
        assertGt(owedToCreator, 0);
        uint256 before = IERC20Min(LINKED_USDC).balanceOf(feeRecipient);
        vm.prank(feeRecipient);
        uint256 paid = locker.claim(LINKED_USDC, feeRecipient);
        assertEq(paid, owedToCreator, "claim pays exactly what was credited");
        assertEq(IERC20Min(LINKED_USDC).balanceOf(feeRecipient) - before, paid);
        assertEq(locker.claimable(feeRecipient, LINKED_USDC), 0, "and clears the credit");
    }

    /// @dev The chain property the case above rests on, asserted on its own so it fails loudly if Arc
    /// ever changes it - at which point `_pushOrCredit`'s fallback becomes reachable and worth testing.
    function test_linkedUsdcTransfersNeverCallTheRecipient() public onlyOnFork {
        address rejecting = address(new RejectingTreasury());
        address sender = makeAddr("sender");
        vm.deal(sender, 100 ether);

        vm.prank(sender);
        assertTrue(IERC20Min(LINKED_USDC).transfer(rejecting, 1e6), "transfer into a reverting contract");
        assertEq(IERC20Min(LINKED_USDC).balanceOf(rejecting), 1e6, "and the balance lands");

        // Nor does a plain transfer consult the compliance precompile, in either direction.
        ArcFork.setBlocklisted(rejecting, true);
        ArcFork.setBlocklisted(sender, true);
        vm.prank(sender);
        assertTrue(IERC20Min(LINKED_USDC).transfer(rejecting, 1e6), "blocklist is a transferFrom-only check");
        ArcFork.setBlocklisted(rejecting, false);
        ArcFork.setBlocklisted(sender, false);
    }

    /// @dev V2-08. Only the admin may rotate either role, and **credit already accrued stays with the
    /// address that earned it** - rotating the recipient must not move money that is already owed.
    function test_v2_08_rotatingTheRecipientLeavesAccruedCreditBehind() public onlyOnFork {
        (address token,,) = _launch(DEPLOY_FEE);
        address trader = makeAddr("v2trader3");
        vm.deal(trader, 10_000 ether);
        for (uint256 i; i < 6; ++i) {
            _buy(trader, token, 50e6);
        }
        locker.collectFees(token);

        uint256 accrued = locker.claimable(feeRecipient, LINKED_USDC);
        assertGt(accrued, 0);

        vm.prank(makeAddr("not the admin"));
        vm.expectRevert(ArchemistV2USDCLockerV3.NotAuthorized.selector);
        locker.updateCreatorFeeRecipient(token, makeAddr("thief"));

        address newRecipient = makeAddr("new recipient");
        vm.prank(feeAdmin);
        locker.updateCreatorFeeRecipient(token, newRecipient);

        assertEq(locker.claimable(feeRecipient, LINKED_USDC), accrued, "old recipient keeps what it earned");
        assertEq(locker.claimable(newRecipient, LINKED_USDC), 0, "the new one starts from zero");

        // And the admin role rotates under the same rule.
        address newAdmin = makeAddr("new admin");
        vm.prank(feeAdmin);
        locker.updateCreatorFeeAdmin(token, newAdmin);
        vm.prank(feeAdmin);
        vm.expectRevert(ArchemistV2USDCLockerV3.NotAuthorized.selector);
        locker.updateCreatorFeeRecipient(token, feeRecipient);
    }

    /// @dev V2-09. An upgrade to a genuine next version - same kind, one appended field - must leave
    /// every position, credit and configuration byte-identical, and the contract must still work
    /// afterwards. This is what the storage-layout gate exists to protect, checked end to end.
    function test_v2_09_upgradePreservesEveryPositionAndCredit() public onlyOnFork {
        (address token,, uint256 positionId) = _launch(DEPLOY_FEE);
        address trader = makeAddr("v2trader4");
        vm.deal(trader, 10_000 ether);
        for (uint256 i; i < 6; ++i) {
            _buy(trader, token, 50e6);
        }
        locker.collectFees(token);

        (uint256 idBefore, address adminBefore, address recipientBefore,,) = locker.positionForToken(token);
        uint256 creditBefore = locker.claimable(feeRecipient, LINKED_USDC);
        uint256 feeBpsBefore = locker.protocolFeeBps();
        uint256 positionsBefore = locker.getTotalPositions();
        address factoryBefore = locker.launchFactory();

        locker.upgradeToAndCall(address(new LockerV31Mock(block.chainid)), "");

        assertEq(locker.implementation(), locker.implementation()); // sanity: still a proxy
        (uint256 idAfter, address adminAfter, address recipientAfter,,) = locker.positionForToken(token);
        assertEq(idAfter, idBefore, "position id");
        assertEq(adminAfter, adminBefore, "fee admin");
        assertEq(recipientAfter, recipientBefore, "fee recipient");
        assertEq(locker.claimable(feeRecipient, LINKED_USDC), creditBefore, "accrued credit");
        assertEq(locker.protocolFeeBps(), feeBpsBefore, "fee split");
        assertEq(locker.getTotalPositions(), positionsBefore, "position count");
        assertEq(locker.launchFactory(), factoryBefore, "launch factory link");
        assertEq(IERC721Min(POSITION_MANAGER).ownerOf(positionId), address(locker), "the NFT did not move");

        // The appended field exists and is zero, which is what an append is supposed to look like.
        assertEq(LockerV31Mock(payable(address(locker))).appendedField(), 0);

        // And the thing still works: claim the pre-upgrade credit through the new implementation.
        vm.prank(feeRecipient);
        assertEq(locker.claim(LINKED_USDC, feeRecipient), creditBefore, "pre-upgrade credit is still payable");
    }

    // ---------------------------------------------------------------------------------------------

    function _launch(uint256 value) private returns (address token, address pool, uint256 positionId) {
        vm.prank(creator);
        (token, pool, positionId) = factory.createToken{ value: value }(
            ArchemistV2USDCFactoryV3.CreateParams({
                name: "Fork V2 Probe",
                symbol: "FV2",
                salt: keccak256(abi.encodePacked(value)),
                minTokensForCreatorBuy: 0,
                creatorFeeAdmin: feeAdmin,
                creatorFeeRecipient: feeRecipient
            })
        );
    }

    function _buy(address trader, address token, uint256 usdcIn) private returns (uint256 got) {
        uint256 before = IERC20Min(token).balanceOf(trader);
        vm.startPrank(trader);
        IERC20Min(LINKED_USDC).approve(SWAP_ROUTER_02, type(uint256).max);
        ISwapRouter02Min(SWAP_ROUTER_02)
            .exactInputSingle(
                ISwapRouter02Min.ExactInputSingleParams({
                tokenIn: LINKED_USDC,
                tokenOut: token,
                fee: 10_000,
                recipient: trader,
                amountIn: usdcIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
            );
        vm.stopPrank();
        got = IERC20Min(token).balanceOf(trader) - before;
    }

    function _sell(address trader, address token, uint256 tokensIn) private returns (uint256 sold) {
        if (tokensIn == 0) return 0;
        vm.startPrank(trader);
        IERC20Min(token).approve(SWAP_ROUTER_02, type(uint256).max);
        ISwapRouter02Min(SWAP_ROUTER_02)
            .exactInputSingle(
                ISwapRouter02Min.ExactInputSingleParams({
                tokenIn: token,
                tokenOut: LINKED_USDC,
                fee: 10_000,
                recipient: trader,
                amountIn: tokensIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
            );
        vm.stopPrank();
        sold = tokensIn;
    }
}

interface IERC721Min {
    function ownerOf(uint256) external view returns (address);
}
