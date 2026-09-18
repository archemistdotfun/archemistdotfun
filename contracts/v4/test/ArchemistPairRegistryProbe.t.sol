// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { ArchemistPairRegistry } from "../src/ArchemistPairRegistry.sol";
import { PairConfig } from "../src/ArchemistV4Types.sol";
import { ArchemistDeploy } from "./Deploy.sol";
import {
    MockAllowlistToken,
    MockFeeOnTransferToken,
    MockNoReturnToken,
    MockPausableToken,
    MockProbeLauncher,
    MockStandardQuote
} from "./mocks/ProbeMocks.sol";

/// @dev Covers the ERC-20 quote safety probe added to ArchemistPairRegistry: transfer/approve
/// round-trips against the real LOCKER/TREASURY/BUYBACK_VAULT/HOLDER_REWARDS addresses, run at addPair time once
/// probing is switched on via configureProbeRecipients. See docs/PROTOCOL_MECHANISM.md for the
/// specification this implements a
/// registry-level version of.
contract ArchemistPairRegistryProbeTest is Test {
    uint256 internal constant PROBE_AMOUNT = 3_000_000; // 3.000000 units @ 6 decimals, leg = 1e6

    ArchemistPairRegistry internal registry;
    address internal locker = makeAddr("locker");
    address internal treasury = makeAddr("treasury");
    address internal vault = makeAddr("vault");
    address internal rewards = makeAddr("rewards");
    MockProbeLauncher internal probeLauncher;

    function setUp() public {
        registry = ArchemistDeploy.registry(address(this), address(0));
        probeLauncher = new MockProbeLauncher(locker, treasury, vault, rewards);
    }

    function test_probeIsInactiveUntilRecipientsAreConfigured() public {
        MockStandardQuote quote = new MockStandardQuote(6);
        // No mint, no approval - if the probe ran, the pull would revert. It shouldn't run.
        registry.addPair(address(quote), _erc20Config(6, 0), 1_000_000, false);

        PairConfig memory stored = registry.getPair(address(quote));
        assertTrue(stored.enabled);
        assertEq(stored.flags, 0);
    }

    /// skipProbe lets the admin register a pair without ever holding or approving the quote token -
    /// e.g. a real third-party asset the admin can't freely acquire. No funds move; declared
    /// config.flags/enabled are trusted as-is, and PairProbeSkipped fires instead of PairProbed so a
    /// skipped pair stays distinguishable on-chain from a probed one.
    function test_skipProbeRegistersWithoutTouchingAnyFunds() public {
        registry.configureProbeRecipients(address(probeLauncher));
        MockAllowlistToken quote = new MockAllowlistToken(6); // admin holds none, nothing allowlisted

        vm.expectEmit(true, false, false, true);
        emit ArchemistPairRegistry.PairProbeSkipped(address(quote));
        registry.addPair(address(quote), _erc20Config(6, 0), 0, true);

        PairConfig memory stored = registry.getPair(address(quote));
        assertTrue(stored.enabled, "declared enabled is trusted as-is when the probe is skipped");
        assertEq(stored.flags, 0, "declared flags are trusted as-is when the probe is skipped");
        assertEq(quote.balanceOf(locker), 0);
        assertEq(quote.balanceOf(treasury), 0);
        assertEq(quote.balanceOf(vault), 0);
        assertEq(quote.balanceOf(rewards), 0);
    }

    function test_configureProbeRecipientsIsOneTimeAndRequiresFullyWiredLauncher() public {
        MockProbeLauncher incomplete = new MockProbeLauncher(address(0), treasury, vault, rewards);
        vm.expectRevert(ArchemistPairRegistry.InvalidInfrastructure.selector);
        registry.configureProbeRecipients(address(incomplete));

        registry.configureProbeRecipients(address(probeLauncher));
        assertEq(registry.LAUNCHER(), address(probeLauncher));

        vm.expectRevert(ArchemistPairRegistry.AlreadyConfigured.selector);
        registry.configureProbeRecipients(address(probeLauncher));
    }

    function test_happyPathProbePassesAndFundsAllFourRecipients() public {
        registry.configureProbeRecipients(address(probeLauncher));
        MockStandardQuote quote = _fundedQuote(6, PROBE_AMOUNT);

        registry.addPair(address(quote), _erc20Config(6, 0), PROBE_AMOUNT, false);

        PairConfig memory stored = registry.getPair(address(quote));
        assertEq(stored.flags, 0, "clean token must observe zero flags");
        assertTrue(stored.enabled);
        uint256 leg = PROBE_AMOUNT / 4;
        assertEq(quote.balanceOf(locker), leg);
        assertEq(quote.balanceOf(treasury), leg);
        assertEq(quote.balanceOf(vault), leg);
        assertEq(quote.balanceOf(rewards), leg);
    }

    /// @dev **F14.** The probe used to pull its tokens from `msg.sender`, which is fine while the owner
    /// is an EOA and awkward the moment it becomes a `TimelockController`: listing one quote currency
    /// would need the timelock to hold the token and to have an `approve` scheduled and executed
    /// against it - three timelocked operations to run a safety check, with `skipProbe = true` sitting
    /// right there as the easy way out. A safety net nobody uses is not a safety net.
    ///
    /// Pre-funding the registry is an ordinary transfer from anybody, so listing stays one operation.
    function test_probeSpendsAPreFundedBalanceWithNoApprovalFromTheOwner() public {
        registry.configureProbeRecipients(address(probeLauncher));

        // Nobody approves anything. A passer-by simply sends the registry the probe amount.
        MockStandardQuote quote = new MockStandardQuote(6);
        address benefactor = makeAddr("benefactor");
        quote.mint(benefactor, PROBE_AMOUNT);
        vm.prank(benefactor);
        quote.transfer(address(registry), PROBE_AMOUNT);

        // The owner - a timelock in production - holds none of it and has approved nothing.
        assertEq(quote.balanceOf(address(this)), 0);
        assertEq(quote.allowance(address(this), address(registry)), 0);

        registry.addPair(address(quote), _erc20Config(6, 0), PROBE_AMOUNT, false);

        PairConfig memory stored = registry.getPair(address(quote));
        assertEq(stored.flags, 0, "a clean token must still observe zero flags");
        assertTrue(stored.enabled, "and must still be enabled by the probe, not by assertion");
        uint256 leg = PROBE_AMOUNT / 4;
        assertEq(quote.balanceOf(locker), leg, "the probe really moved the pre-funded tokens");
        assertEq(quote.balanceOf(treasury), leg);
        assertEq(quote.balanceOf(vault), leg);
        assertEq(quote.balanceOf(rewards), leg);
    }

    /// @dev And the fallback is intact: with nothing pre-funded, it still pulls from the caller, which
    /// is what an EOA-owned registry has always done.
    function test_probeStillPullsFromTheCallerWhenNothingIsPreFunded() public {
        registry.configureProbeRecipients(address(probeLauncher));
        MockStandardQuote quote = _fundedQuote(6, PROBE_AMOUNT);
        assertEq(quote.balanceOf(address(registry)), 0, "nothing pre-funded");

        registry.addPair(address(quote), _erc20Config(6, 0), PROBE_AMOUNT, false);

        assertTrue(registry.getPair(address(quote)).enabled);
        assertEq(quote.balanceOf(address(this)), 0, "the caller's tokens were the ones spent");
    }

    function test_pausedTokenFailsProbePullOutright() public {
        registry.configureProbeRecipients(address(probeLauncher));
        MockPausableToken quote = new MockPausableToken(6);
        quote.mint(address(this), PROBE_AMOUNT);
        quote.approve(address(registry), PROBE_AMOUNT);
        quote.setPaused(true);

        vm.expectRevert(ArchemistPairRegistry.ProbePullFailed.selector);
        registry.addPair(address(quote), _erc20Config(6, 0), PROBE_AMOUNT, false);
        assertFalse(_pairRecorded(address(quote)));
    }

    function test_pausableCapabilityIsFlaggedButNotBlocking() public {
        registry.configureProbeRecipients(address(probeLauncher));
        MockPausableToken quote = new MockPausableToken(6);
        quote.mint(address(this), PROBE_AMOUNT);
        quote.approve(address(registry), PROBE_AMOUNT);
        // Not paused right now - only the paused() killswitch capability should be observed.

        registry.addPair(address(quote), _erc20Config(6, 0), PROBE_AMOUNT, false);

        PairConfig memory stored = registry.getPair(address(quote));
        assertEq(stored.flags, registry.FLAG_PAUSABLE());
        assertTrue(stored.enabled, "pausable capability alone must not force disabled");
    }

    function test_restrictedRecipientDisablesPair() public {
        registry.configureProbeRecipients(address(probeLauncher));
        MockAllowlistToken quote = new MockAllowlistToken(6);
        quote.mint(address(this), PROBE_AMOUNT);
        quote.approve(address(registry), PROBE_AMOUNT);
        quote.setAllowed(address(registry), true);
        quote.setAllowed(locker, true);
        quote.setAllowed(treasury, true);
        quote.setAllowed(rewards, true);
        // vault deliberately left off the allowlist.

        registry.addPair(address(quote), _erc20Config(6, 0), PROBE_AMOUNT, false);

        PairConfig memory stored = registry.getPair(address(quote));
        assertEq(stored.flags, registry.FLAG_TRANSFER_RESTRICTED());
        assertFalse(stored.enabled, "any blocked recipient must disable the pair");
        assertEq(quote.balanceOf(vault), 0);
        assertEq(quote.balanceOf(locker), PROBE_AMOUNT / 4, "recipients before the blocked one still get funded");
    }

    function test_restrictedRecipientCheckCoversAllFourAddresses() public {
        registry.configureProbeRecipients(address(probeLauncher));

        MockAllowlistToken blockingLocker = new MockAllowlistToken(6);
        blockingLocker.mint(address(this), PROBE_AMOUNT);
        blockingLocker.approve(address(registry), PROBE_AMOUNT);
        blockingLocker.setAllowed(address(registry), true);
        blockingLocker.setAllowed(treasury, true);
        blockingLocker.setAllowed(vault, true);
        blockingLocker.setAllowed(rewards, true);
        registry.addPair(address(blockingLocker), _erc20Config(6, 0), PROBE_AMOUNT, false);
        assertFalse(registry.getPair(address(blockingLocker)).enabled, "blocked LOCKER must disable");

        MockAllowlistToken blockingTreasury = new MockAllowlistToken(6);
        blockingTreasury.mint(address(this), PROBE_AMOUNT);
        blockingTreasury.approve(address(registry), PROBE_AMOUNT);
        blockingTreasury.setAllowed(address(registry), true);
        blockingTreasury.setAllowed(locker, true);
        blockingTreasury.setAllowed(vault, true);
        blockingTreasury.setAllowed(rewards, true);
        registry.addPair(address(blockingTreasury), _erc20Config(6, 0), PROBE_AMOUNT, false);
        assertFalse(registry.getPair(address(blockingTreasury)).enabled, "blocked TREASURY must disable");

        MockAllowlistToken blockingRewards = new MockAllowlistToken(6);
        blockingRewards.mint(address(this), PROBE_AMOUNT);
        blockingRewards.approve(address(registry), PROBE_AMOUNT);
        blockingRewards.setAllowed(address(registry), true);
        blockingRewards.setAllowed(locker, true);
        blockingRewards.setAllowed(treasury, true);
        blockingRewards.setAllowed(vault, true);
        registry.addPair(address(blockingRewards), _erc20Config(6, 0), PROBE_AMOUNT, false);
        assertFalse(registry.getPair(address(blockingRewards)).enabled, "blocked HOLDER_REWARDS must disable");
    }

    function test_feeOnTransferDisablesPairEvenAtOneBps() public {
        registry.configureProbeRecipients(address(probeLauncher));
        MockFeeOnTransferToken quote = new MockFeeOnTransferToken(6, 1); // 0.01%
        quote.mint(address(this), PROBE_AMOUNT);
        quote.approve(address(registry), PROBE_AMOUNT);

        registry.addPair(address(quote), _erc20Config(6, 0), PROBE_AMOUNT, false);

        PairConfig memory stored = registry.getPair(address(quote));
        assertEq(stored.flags, registry.FLAG_FEE_ON_TRANSFER());
        assertFalse(stored.enabled);
    }

    function test_nonStandardReturnIsFlaggedButAllowed() public {
        registry.configureProbeRecipients(address(probeLauncher));
        MockNoReturnToken quote = new MockNoReturnToken(6);
        quote.mint(address(this), PROBE_AMOUNT);
        quote.approve(address(registry), PROBE_AMOUNT);

        registry.addPair(address(quote), _erc20Config(6, 0), PROBE_AMOUNT, false);

        PairConfig memory stored = registry.getPair(address(quote));
        assertEq(stored.flags, registry.FLAG_NON_STANDARD_RETURN());
        assertTrue(stored.enabled, "non-standard return alone must not block listing");
        uint256 leg = PROBE_AMOUNT / 4;
        assertEq(quote.balanceOf(locker), leg);
        assertEq(quote.balanceOf(treasury), leg);
        assertEq(quote.balanceOf(vault), leg);
        assertEq(quote.balanceOf(rewards), leg);
    }

    function test_probeAmountBelowFourReverts() public {
        registry.configureProbeRecipients(address(probeLauncher));
        MockStandardQuote quote = _fundedQuote(6, 10);

        vm.expectRevert(ArchemistPairRegistry.ProbeAmountTooSmall.selector);
        registry.addPair(address(quote), _erc20Config(6, 0), 3, false);
    }

    function test_reprobeAndExplicitEnableRecoverFromRisk() public {
        registry.configureProbeRecipients(address(probeLauncher));
        MockAllowlistToken quote = new MockAllowlistToken(6);
        quote.mint(address(this), 2 * PROBE_AMOUNT);
        quote.approve(address(registry), 2 * PROBE_AMOUNT);
        quote.setAllowed(address(registry), true);
        quote.setAllowed(locker, true);
        quote.setAllowed(treasury, true);
        quote.setAllowed(rewards, true);
        // vault blocked at first.
        registry.addPair(address(quote), _erc20Config(6, 0), PROBE_AMOUNT, false);
        assertFalse(registry.getPair(address(quote)).enabled);

        vm.expectRevert(
            abi.encodeWithSelector(ArchemistPairRegistry.PairFlaggedRisky.selector, registry.FLAG_TRANSFER_RESTRICTED())
        );
        registry.setPairEnabled(address(quote), true);

        quote.setAllowed(vault, true);
        registry.reprobePair(address(quote), PROBE_AMOUNT);
        assertEq(registry.getPair(address(quote)).flags, 0);
        assertFalse(registry.getPair(address(quote)).enabled, "clean reprobe still requires explicit enable");

        registry.setPairEnabled(address(quote), true);
        assertTrue(registry.getPair(address(quote)).enabled);
    }

    function test_updatePairCannotLaunderProbeDerivedFlags() public {
        registry.configureProbeRecipients(address(probeLauncher));
        MockNoReturnToken quote = new MockNoReturnToken(6);
        quote.mint(address(this), PROBE_AMOUNT);
        quote.approve(address(registry), PROBE_AMOUNT);
        registry.addPair(address(quote), _erc20Config(6, 0), PROBE_AMOUNT, false);
        assertEq(registry.getPair(address(quote)).flags, registry.FLAG_NON_STANDARD_RETURN());

        PairConfig memory declaredClean = _erc20Config(6, 0);
        declaredClean.tickSpacing = 200;
        declaredClean.defaultTick = -60_000;
        declaredClean.minTick = -120_000;
        declaredClean.maxTick = -200;
        registry.updatePair(address(quote), declaredClean);

        assertEq(registry.getPair(address(quote)).flags, registry.FLAG_NON_STANDARD_RETURN(), "flags are probe-owned");
        assertEq(registry.getPair(address(quote)).tickSpacing, 200, "non-flag fields still update");
    }

    function _fundedQuote(uint8 decimals_, uint256 amount) private returns (MockStandardQuote quote) {
        quote = new MockStandardQuote(decimals_);
        quote.mint(address(this), amount);
        quote.approve(address(registry), amount);
    }

    function _pairRecorded(address quote) private view returns (bool) {
        try registry.getPair(quote) returns (PairConfig memory) {
            return true;
        } catch {
            return false;
        }
    }

    function _erc20Config(uint8 decimals_, uint16 flags) private pure returns (PairConfig memory) {
        return PairConfig({
            enabled: true,
            decimals: decimals_,
            defaultTick: -60_000,
            minTick: -120_000,
            maxTick: -60,
            tickSpacing: 60,
            flags: flags,
            buybackRoute: address(0),
            buybackRouteIsV4: false,
            buybackRouteFee: 0,
            buybackRouteTickSpacing: 0,
            minCreatorBps: 5_000,
            maxCreatorBps: 8_000
        });
    }
}
