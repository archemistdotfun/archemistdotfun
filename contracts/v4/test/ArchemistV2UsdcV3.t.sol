// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { MockPairedToken, MockPositionManager, MockSwapRouter02, MockV3Factory } from "./mocks/V2Mocks.sol";
import { ArchemistProxy } from "./vendored/ArchemistProxy_salt_prod.sol";
import { ArchemistV2USDCLockerV3 } from "./vendored/ArchemistV2USDCLockerV3_salt_prod.sol";
import { ArchemistV2USDCFactoryV3, V3USDCLaunchTickMathV3 } from "./vendored/ArchemistV2USDCV3_salt_prod.sol";

/// @notice **The V2 launchpad's first executable tests.**
///
/// Implementation v3 of the V2 (Uniswap v3) launchpad went to testnet with deploy transcripts and
/// selector probes and nothing else: no Foundry suite existed for V2 at all, and the viem e2e runner
/// targets the previous implementation. Everything v3 claims - that the 80/20 split is a constant
/// rather than a deploy argument, that the proxies refuse each other, that a launch still works end to
/// end - rested on reading the diff. Raised in review as the single largest gap. This file is the answer.
///
/// The sources are the **live files**, reached through symlinks in `test/vendored/`, not copies: a copy
/// would drift, and the thing worth testing is what actually gets compiled and deployed by
/// `contracts/v2`. `foundry.toml` keeps `forge fmt` away from them for the same reason.
///
/// ## The one place this is not Arc
///
/// On Arc, native currency and the linked USDC at `0x3600…` are one balance at two decimal scales, so
/// `msg.value` arriving at the factory *is* paired-token balance. Foundry has no such aliasing, so the
/// creator-buy tests mint the equivalent paired amount to the factory to stand in for it, and the
/// native side is left as the non-increase check it is. Stated here rather than buried, because it is
/// the one behaviour these tests approximate instead of reproducing.
contract ArchemistV2UsdcV3Test is Test {
    uint256 internal constant INITIAL_SUPPLY = 1_000_000_000 ether;
    uint256 internal constant DEPLOY_FEE = 0.1 ether;
    uint256 internal constant NATIVE_TO_USDC_SCALE = 1e12;
    int24 internal constant STARTING_TICK = -398_400;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    MockPairedToken internal usdc;
    MockV3Factory internal v3Factory;
    MockPositionManager internal positionManager;
    MockSwapRouter02 internal router;

    ArchemistV2USDCFactoryV3 internal factory;
    ArchemistV2USDCLockerV3 internal locker;
    address internal factoryImpl;
    address internal lockerImpl;

    address internal treasury = makeAddr("treasury");
    address internal creator = makeAddr("creator");
    address internal creatorFeeRecipient = makeAddr("creatorFeeRecipient");
    address internal creatorFeeAdmin = makeAddr("creatorFeeAdmin");

    function setUp() public {
        usdc = new MockPairedToken(6);
        v3Factory = new MockV3Factory();
        positionManager = new MockPositionManager(v3Factory);
        router = new MockSwapRouter02(address(v3Factory));
        positionManager.setRouter(address(router));

        // The pool must report the exact tick the factory asked for, or `InvalidInitialPrice` fires.
        positionManager.setTickForPrice(V3USDCLaunchTickMathV3.getSqrtRatioAtTick(STARTING_TICK), STARTING_TICK);
        positionManager.setTickForPrice(V3USDCLaunchTickMathV3.getSqrtRatioAtTick(-STARTING_TICK), -STARTING_TICK);

        lockerImpl = address(new ArchemistV2USDCLockerV3(block.chainid));
        factoryImpl = address(new ArchemistV2USDCFactoryV3(block.chainid));

        // The locker is initialized with a PREDICTED factory-proxy address, and the factory's own
        // `initialize` closes the loop by checking `locker.launchFactory() == address(this)`. Reproduced
        // here rather than short-circuited, because that mutual check is a deploy-time safety property.
        address predictedFactoryProxy = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        locker = ArchemistV2USDCLockerV3(
            payable(address(
                    new ArchemistProxy(
                        lockerImpl,
                        abi.encodeCall(
                            ArchemistV2USDCLockerV3.initialize,
                            (address(this), treasury, address(usdc), address(positionManager), predictedFactoryProxy)
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
                                address(usdc),
                                address(v3Factory),
                                address(positionManager),
                                address(router),
                                address(locker)
                            )
                        )
                    )
                ))
        );
        assertEq(address(factory), predictedFactoryProxy, "nonce prediction must hold, as it does on chain");

        vm.deal(creator, 100 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // V2-01 / V2-02 - a launch still works, end to end
    // ---------------------------------------------------------------------------------------------

    function test_launchCreatesPoolMintsPositionAndLocksIt() public {
        (address token, address pool, uint256 positionId) = _launch(DEPLOY_FEE, 0);

        assertTrue(token != address(0));
        assertTrue(pool != address(0));
        assertGt(positionId, 0);
        assertEq(positionManager.ownerOf(positionId), address(locker), "the LP NFT must land in the locker");
        assertEq(locker.getTotalPositions(), 1);
        assertEq(factory.allTokens(0), token);
        assertEq(treasury.balance, DEPLOY_FEE, "the deploy fee is forwarded, not retained");
    }

    /// @dev The whole supply goes into the one-sided position; whatever the position could not absorb is
    /// burned rather than left with the factory, which has no sweep.
    function test_launchLeavesNoTokensWithTheFactory() public {
        (address token,,) = _launch(DEPLOY_FEE, 0);
        assertEq(_erc20BalanceOf(token, address(factory)), 0, "the factory keeps nothing");
        assertEq(
            _erc20BalanceOf(token, address(positionManager)) + _erc20BalanceOf(token, DEAD),
            INITIAL_SUPPLY,
            "every token is either in the position or burned"
        );
    }

    /// @dev An attacker who front-runs the launch by creating the pool at the same CREATE2 address must
    /// not be able to hand the launch a pool they control, whatever its price.
    function test_launchRefusesAPoolThatAlreadyExists() public {
        bytes32 salt = keccak256("preexisting");
        address predictedToken = _predictToken(salt);
        bool tokenIsToken0 = predictedToken < address(usdc);
        (address token0, address token1) =
            tokenIsToken0 ? (predictedToken, address(usdc)) : (address(usdc), predictedToken);
        v3Factory.record(token0, token1, 10_000, address(0xBADBAD));

        vm.prank(creator);
        vm.expectRevert(ArchemistV2USDCFactoryV3.PoolAlreadyExists.selector);
        factory.createToken{ value: DEPLOY_FEE }(_params(salt, 0));
    }

    // ---------------------------------------------------------------------------------------------
    // V2-05 - the fee split is a constant, and the locker pays it
    // ---------------------------------------------------------------------------------------------

    function test_feeSplitIsEightyTwentyAndIsNotADeployArgument() public view {
        assertEq(locker.PROTOCOL_FEE_BPS(), 2_000);
        assertEq(locker.CREATOR_FEE_BPS(), 8_000);
        assertEq(locker.CREATOR_FEE_BPS() + locker.PROTOCOL_FEE_BPS(), locker.BPS_DENOMINATOR());
        // Storage was seeded from the constant, so the getter the indexer already reads still works.
        assertEq(locker.protocolFeeBps(), 2_000);
    }

    function test_collectedFeesSplitEightyTwenty() public {
        (address token,, uint256 positionId) = _launch(DEPLOY_FEE, 0);

        // 1,000 USDC of fees waiting on the position.
        uint256 fees = 1_000e6;
        usdc.mint(address(positionManager), fees);
        positionManager.setOwed(positionId, _isToken0(token) ? 0 : fees, _isToken0(token) ? fees : 0);

        locker.collectFees(token);

        assertEq(locker.claimable(creatorFeeRecipient, address(usdc)), fees * 8_000 / 10_000, "creator 80%");
        // The treasury is an EOA here, so the locker pushes rather than crediting.
        assertEq(usdc.balanceOf(treasury), fees * 2_000 / 10_000, "treasury 20%");
    }

    /// @dev The locker has no path that moves an LP NFT out. The position is registered, fees are
    /// collected against it, and it stays - there is deliberately nothing else.
    function test_lockerHasNoWithdrawalPathForTheLpPosition() public {
        (address token,, uint256 positionId) = _launch(DEPLOY_FEE, 0);

        bytes[4] memory attempts = [
            abi.encodeWithSignature("withdrawPosition(uint256)", positionId),
            abi.encodeWithSignature("transferPosition(address,uint256)", address(this), positionId),
            abi.encodeWithSignature("releasePosition(uint256)", positionId),
            abi.encodeWithSignature(
                "safeTransferFrom(address,address,uint256)", address(locker), address(this), positionId
            )
        ];
        for (uint256 i; i < attempts.length; ++i) {
            (bool ok,) = address(locker).call(attempts[i]);
            assertFalse(ok, "no selector may move the position");
        }
        assertEq(positionManager.ownerOf(positionId), address(locker));
        assertTrue(token != address(0));
    }

    // ---------------------------------------------------------------------------------------------
    // V2-09 / F5 - the upgrade path, and the proxies refusing each other
    // ---------------------------------------------------------------------------------------------

    /// @dev `PROXY_VERSION() != 0` and the chain id are satisfied by BOTH implementations, so before the
    /// `ARCHEMIST_KIND` tag this cross-upgrade succeeded and the proxy came back speaking the wrong ABI
    /// over the right storage. The two are deployed seconds apart by one script.
    function test_neitherProxyAcceptsTheOtherImplementation() public {
        vm.expectRevert(ArchemistV2USDCFactoryV3.InvalidImplementation.selector);
        factory.upgradeToAndCall(lockerImpl, "");

        vm.expectRevert(ArchemistV2USDCLockerV3.InvalidImplementation.selector);
        locker.upgradeToAndCall(factoryImpl, "");

        assertTrue(factory.ARCHEMIST_KIND() != locker.ARCHEMIST_KIND(), "the tags must differ");
    }

    function test_eachProxyStillAcceptsAFreshImplementationOfItsOwnKind() public {
        address newFactoryImpl = address(new ArchemistV2USDCFactoryV3(block.chainid));
        address newLockerImpl = address(new ArchemistV2USDCLockerV3(block.chainid));

        factory.upgradeToAndCall(newFactoryImpl, "");
        locker.upgradeToAndCall(newLockerImpl, "");

        assertEq(factory.implementation(), newFactoryImpl);
        assertEq(locker.implementation(), newLockerImpl);
        // State survived: the launch registered before the upgrade is still there.
        assertEq(locker.launchFactory(), address(factory));
        assertEq(factory.LOCKER(), address(locker));
    }

    function test_upgradePreservesLaunchState() public {
        (address token,, uint256 positionId) = _launch(DEPLOY_FEE, 0);

        factory.upgradeToAndCall(address(new ArchemistV2USDCFactoryV3(block.chainid)), "");
        locker.upgradeToAndCall(address(new ArchemistV2USDCLockerV3(block.chainid)), "");

        assertEq(factory.allTokens(0), token);
        assertEq(locker.getTotalPositions(), 1);
        (uint256 storedId, address admin, address recipient,,) = locker.positionForToken(token);
        assertEq(storedId, positionId);
        assertEq(admin, creatorFeeAdmin);
        assertEq(recipient, creatorFeeRecipient);
    }

    function test_onlyTheOwnerMayUpgradeAndOwnershipIsTwoStep() public {
        address newOwner = makeAddr("timelock");

        // Deployed OUTSIDE the prank: a `new` in the argument list is evaluated first and would consume
        // it, leaving the upgrade to run as the owner and pass.
        address rejected = address(new ArchemistV2USDCFactoryV3(block.chainid));
        vm.prank(address(0xBEEF));
        vm.expectRevert(ArchemistV2USDCFactoryV3.NotAuthorized.selector);
        factory.upgradeToAndCall(rejected, "");

        factory.transferOwnership(newOwner);
        assertEq(factory.owner(), address(this), "still ours until accepted");
        assertEq(factory.pendingOwner(), newOwner);

        vm.prank(newOwner);
        factory.acceptOwnership();
        assertEq(factory.owner(), newOwner);
        assertEq(factory.pendingOwner(), address(0));
    }

    // ---------------------------------------------------------------------------------------------
    // F6 - the 1-wei brick
    // ---------------------------------------------------------------------------------------------

    /// @dev The proxy must not shadow the implementation's `receive` guard. With its own
    /// `receive() payable {}`, every empty-calldata transfer was accepted at the proxy and the
    /// implementation's `if (msg.sender != _swapRouter02) revert` never ran.
    function test_theProxyDoesNotAcceptStrayValue() public {
        (bool ok,) = address(factory).call{ value: 1 wei }("");
        assertFalse(ok, "empty-calldata value must reach the implementation's own guard and be refused");
        assertEq(address(factory).balance, 0);
    }

    /// @dev And the deeper half: even if value does get in, a launch with a creator buy must still work.
    /// The old check asserted `balanceOf(this) == 0 && address(this).balance == 0` in absolute terms, so
    /// on a chain where the factory has no sweep and no owner, a single stray unit bricked every
    /// `createToken` with `creatorBuyAmount > 0` until a 48-hour timelocked upgrade fixed it.
    function test_aStrayDonationDoesNotBrickCreatorBuys() public {
        usdc.mint(address(factory), 1); // 1 unit of paired token, unsolicited, unrecoverable
        vm.deal(address(factory), 1 wei); // and the native-side equivalent

        (address token,,) = _launch(DEPLOY_FEE + 1 ether, 1);
        assertGt(_erc20BalanceOf(token, creator), 0, "the creator buy must still have executed");
        assertEq(usdc.balanceOf(address(factory)), 1, "the donation is still there, inert");
    }

    // ---------------------------------------------------------------------------------------------

    function _launch(uint256 value, uint256 minTokens)
        private
        returns (address token, address pool, uint256 positionId)
    {
        uint256 creatorBuyNative = value - DEPLOY_FEE;
        if (creatorBuyNative > 0) {
            // Arc's native/linked-USDC aliasing, stood in for. See the contract NatSpec.
            usdc.mint(address(factory), creatorBuyNative / NATIVE_TO_USDC_SCALE);
            router.setTokenSource(address(positionManager));
        }
        vm.prank(creator);
        (token, pool, positionId) = factory.createToken{ value: value }(_params(keccak256("salt"), minTokens));
    }

    function _params(bytes32 salt, uint256 minTokens)
        private
        view
        returns (ArchemistV2USDCFactoryV3.CreateParams memory)
    {
        return ArchemistV2USDCFactoryV3.CreateParams({
            name: "Mock Launch",
            symbol: "MOCK",
            salt: salt,
            minTokensForCreatorBuy: minTokens,
            creatorFeeAdmin: creatorFeeAdmin,
            creatorFeeRecipient: creatorFeeRecipient
        });
    }

    function _predictToken(bytes32 salt) private view returns (address) {
        bytes32 actualSalt = keccak256(abi.encodePacked(creator, salt));
        bytes memory initCode = abi.encodePacked(
            vm.getCode("ArchemistV2USDCV3_salt_prod.sol:V3USDCLaunchTokenV3"),
            abi.encode("Mock Launch", "MOCK", INITIAL_SUPPLY)
        );
        return vm.computeCreate2Address(actualSalt, keccak256(initCode), address(factory));
    }

    function _isToken0(address token) private view returns (bool) {
        return token < address(usdc);
    }

    function _erc20BalanceOf(address token, address account) private view returns (uint256) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", account));
        require(ok, "balanceOf failed");
        return abi.decode(data, (uint256));
    }
}
