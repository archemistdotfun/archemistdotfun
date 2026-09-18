// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { ArchemistPairRegistry } from "../src/ArchemistPairRegistry.sol";
import { PairConfig } from "../src/ArchemistV4Types.sol";
import { ArchemistUpgradeable } from "../src/upgradeability/ArchemistUpgradeable.sol";
import { ArchemistDeploy } from "./Deploy.sol";

contract MockPairAsset {
    uint8 public immutable decimals;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }
}

contract ArchemistPairRegistryTest is Test {
    address internal constant ALIAS = address(0x3600);
    address internal constant ROUTE = address(0xB0B);

    ArchemistPairRegistry internal registry;
    MockPairAsset internal usdc;

    function setUp() public {
        registry = ArchemistDeploy.registry(address(this), ALIAS);
        usdc = new MockPairAsset(6);
    }

    function test_adminAddsPairAndEnumerationIsExact() public {
        PairConfig memory config = _erc20Config(6);
        vm.expectEmit(true, true, false, true);
        emit ArchemistPairRegistry.PairAdded(address(usdc), 6, 60, 0, ROUTE);
        registry.addPair(address(usdc), config, 0, false);

        PairConfig memory stored = registry.getPair(address(usdc));
        assertEq(stored.enabled, config.enabled);
        assertEq(stored.decimals, config.decimals);
        assertEq(stored.defaultTick, config.defaultTick);
        assertEq(stored.minTick, config.minTick);
        assertEq(stored.maxTick, config.maxTick);
        assertEq(stored.tickSpacing, config.tickSpacing);
        assertEq(stored.flags, config.flags);
        assertEq(stored.buybackRoute, config.buybackRoute);
        assertEq(registry.pairCount(), 1);
        assertEq(registry.pairAt(0), address(usdc));
    }

    function test_nonAdminCannotAddOrDisablePair() public {
        address attacker = address(0xBAD);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ArchemistUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        registry.addPair(address(usdc), _erc20Config(6), 0, false);

        registry.addPair(address(usdc), _erc20Config(6), 0, false);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(ArchemistUpgradeable.OwnableUnauthorizedAccount.selector, attacker));
        registry.setPairEnabled(address(usdc), false);
        assertTrue(registry.getPair(address(usdc)).enabled);
    }

    function test_duplicatePairAndUnknownPairRevert() public {
        registry.addPair(address(usdc), _erc20Config(6), 0, false);
        vm.expectRevert(abi.encodeWithSelector(ArchemistPairRegistry.PairExists.selector, address(usdc)));
        registry.addPair(address(usdc), _erc20Config(6), 0, false);

        address unknown = address(0x1234);
        vm.expectRevert(abi.encodeWithSelector(ArchemistPairRegistry.PairNotRegistered.selector, unknown));
        registry.getPair(unknown);
    }

    function test_disablePreservesRecordAndEnumeration() public {
        registry.addPair(address(usdc), _erc20Config(6), 0, false);
        registry.setPairEnabled(address(usdc), false);
        assertFalse(registry.getPair(address(usdc)).enabled);
        assertEq(registry.pairCount(), 1);
        assertEq(registry.pairAt(0), address(usdc));
    }

    function test_updatePreservesEnabledAndDecimals() public {
        registry.addPair(address(usdc), _erc20Config(6), 0, false);
        registry.setPairEnabled(address(usdc), false);
        PairConfig memory updated = _erc20Config(6);
        updated.enabled = true;
        updated.tickSpacing = 200;
        updated.defaultTick = -60_000;
        updated.minTick = -120_000;
        updated.maxTick = -200;
        registry.updatePair(address(usdc), updated);

        PairConfig memory stored = registry.getPair(address(usdc));
        assertFalse(stored.enabled, "enable changes require the explicit setter");
        assertEq(stored.decimals, 6);
        assertEq(stored.tickSpacing, 200);

        updated.decimals = 18;
        vm.expectRevert(ArchemistPairRegistry.DecimalsImmutable.selector);
        registry.updatePair(address(usdc), updated);
    }

    function test_rejectsWrongDecimalsNoCodeUnknownFlagsAndBadTicks() public {
        vm.expectRevert(abi.encodeWithSelector(ArchemistPairRegistry.DecimalsMismatch.selector, 6, 18));
        registry.addPair(address(usdc), _erc20Config(18), 0, false);

        vm.expectRevert(abi.encodeWithSelector(ArchemistPairRegistry.InvalidPair.selector, address(0xCAFE)));
        registry.addPair(address(0xCAFE), _erc20Config(6), 0, false);

        PairConfig memory config = _erc20Config(6);
        config.flags = 1 << 15;
        vm.expectRevert(abi.encodeWithSelector(ArchemistPairRegistry.InvalidPair.selector, address(usdc)));
        registry.addPair(address(usdc), config, 0, false);

        config = _erc20Config(6);
        config.defaultTick = -60_001;
        vm.expectRevert(abi.encodeWithSelector(ArchemistPairRegistry.InvalidPair.selector, address(usdc)));
        registry.addPair(address(usdc), config, 0, false);
    }

    function test_creatorShareRangeMustSitWithinHardBoundsAndBeOrdered() public {
        PairConfig memory belowHardMin = _erc20Config(6);
        belowHardMin.minCreatorBps = 4_999;
        vm.expectRevert(abi.encodeWithSelector(ArchemistPairRegistry.InvalidCreatorShareRange.selector, 4_999, 8_000));
        registry.addPair(address(usdc), belowHardMin, 0, false);

        PairConfig memory aboveHardMax = _erc20Config(6);
        aboveHardMax.maxCreatorBps = 8_001;
        vm.expectRevert(abi.encodeWithSelector(ArchemistPairRegistry.InvalidCreatorShareRange.selector, 5_000, 8_001));
        registry.addPair(address(usdc), aboveHardMax, 0, false);

        PairConfig memory inverted = _erc20Config(6);
        inverted.minCreatorBps = 7_000;
        inverted.maxCreatorBps = 6_000;
        vm.expectRevert(abi.encodeWithSelector(ArchemistPairRegistry.InvalidCreatorShareRange.selector, 7_000, 6_000));
        registry.addPair(address(usdc), inverted, 0, false);

        // A pair class may narrow the band (e.g. a regulated tokenized-equity pair) without reverting.
        PairConfig memory narrowed = _erc20Config(6);
        narrowed.minCreatorBps = 6_000;
        narrowed.maxCreatorBps = 6_500;
        registry.addPair(address(usdc), narrowed, 0, false);
        PairConfig memory stored = registry.getPair(address(usdc));
        assertEq(stored.minCreatorBps, 6_000);
        assertEq(stored.maxCreatorBps, 6_500);
    }

    function test_nativeAndCanonicalAliasCannotBothBeRegistered() public {
        PairConfig memory nativeConfig = PairConfig({
            enabled: true,
            decimals: 18,
            defaultTick: -60_000,
            minTick: -120_000,
            maxTick: -60,
            tickSpacing: 60,
            flags: registry.FLAG_NATIVE(),
            buybackRoute: address(0),
            buybackRouteIsV4: false,
            buybackRouteFee: 0,
            buybackRouteTickSpacing: 0,
            minCreatorBps: 5_000,
            maxCreatorBps: 8_000
        });
        registry.addPair(address(0), nativeConfig, 0, false);
        MockPairAsset aliasImplementation = new MockPairAsset(6);
        vm.etch(ALIAS, address(aliasImplementation).code);

        vm.expectRevert(abi.encodeWithSelector(ArchemistPairRegistry.CanonicalConflict.selector, address(0)));
        registry.addPair(ALIAS, _erc20Config(6), 0, false);
    }

    function test_ownershipTransferIsTwoStep() public {
        address nextOwner = address(0xBEEF);
        registry.transferOwnership(nextOwner);
        assertEq(registry.owner(), address(this), "nothing changes until the new owner accepts");
        vm.expectRevert(abi.encodeWithSelector(ArchemistUpgradeable.OwnableUnauthorizedAccount.selector, address(this)));
        registry.acceptOwnership();
        vm.prank(nextOwner);
        registry.acceptOwnership();
        assertEq(registry.owner(), nextOwner);
    }

    function _erc20Config(uint8 decimals_) private pure returns (PairConfig memory) {
        return PairConfig({
            enabled: true,
            decimals: decimals_,
            defaultTick: -60_000,
            minTick: -120_000,
            maxTick: -60,
            tickSpacing: 60,
            flags: 0,
            buybackRoute: ROUTE,
            buybackRouteIsV4: false,
            buybackRouteFee: 0,
            buybackRouteTickSpacing: 0,
            minCreatorBps: 5_000,
            maxCreatorBps: 8_000
        });
    }
}
