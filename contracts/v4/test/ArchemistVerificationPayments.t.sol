// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { ArchemistVerificationPayments } from "../src/ArchemistVerificationPayments.sol";

/// @dev A recipient that refuses native transfers, to exercise the credit-and-claim fallback.
contract RejectingRecipient {
    receive() external payable {
        revert("no");
    }
}

/// @dev A recipient whose fallback costs more than the push gas stipend, but which succeeds when it is
/// given the whole transaction's gas. This is the case the stipend exists for: an expensive-but-honest
/// recipient must not be paid on the settlement path, and must still be able to collect afterwards.
contract GasHungryRecipient {
    uint256[] private junk;

    receive() external payable {
        for (uint256 i = 0; i < 40; i++) {
            junk.push(i);
        }
    }
}

/// @dev A payer that refuses refunds, to prove its own overpayment cannot revert its purchase.
contract RejectingPayer {
    function pay(ArchemistVerificationPayments target, address token, bytes32 requestId, uint256 amount) external {
        target.pay{ value: amount }(token, requestId);
    }

    receive() external payable {
        revert("no");
    }
}

contract ArchemistVerificationPaymentsTest is Test {
    uint256 internal constant CHAIN_ID = 5042;
    uint256 internal constant PRICE = 150e6;
    uint256 internal constant FEE = 99e6;

    address internal constant OWNER = address(0xA11CE);
    address internal constant TREASURY = address(0x7EA);
    address internal constant BLOCKSCOUT = address(0xB10C);
    address internal constant SETTLER = address(0x5E77);
    address internal constant CREATOR = address(0xC0FFEE);
    address internal constant TOKEN = address(0x70CE);

    bytes32 internal constant REQUEST = keccak256("request-1");

    ArchemistVerificationPayments internal payments;

    function setUp() public {
        vm.chainId(CHAIN_ID);
        payments = new ArchemistVerificationPayments(OWNER, TREASURY, BLOCKSCOUT, SETTLER, PRICE, FEE, CHAIN_ID);
        vm.deal(CREATOR, 1000e6);
    }

    // ------------------------------------------------------------------- paying

    function test_payEscrowsAndPaysNobody() public {
        vm.prank(CREATOR);
        payments.pay{ value: PRICE }(TOKEN, REQUEST);

        assertEq(address(payments).balance, PRICE, "funds must stay escrowed");
        assertEq(TREASURY.balance, 0, "treasury paid too early");
        assertEq(BLOCKSCOUT.balance, 0, "blockscout paid too early");

        (address payer, address token, ArchemistVerificationPayments.Status status, uint256 amount, uint256 fee,) =
            payments.paymentOf(REQUEST);
        assertEq(payer, CREATOR);
        assertEq(token, TOKEN);
        assertEq(uint8(status), uint8(ArchemistVerificationPayments.Status.Escrowed));
        assertEq(amount, PRICE);
        assertEq(fee, FEE);
    }

    function test_payRejectsDuplicateRequestId() public {
        vm.startPrank(CREATOR);
        payments.pay{ value: PRICE }(TOKEN, REQUEST);
        vm.expectRevert(ArchemistVerificationPayments.DuplicateRequest.selector);
        payments.pay{ value: PRICE }(TOKEN, REQUEST);
        vm.stopPrank();
    }

    function test_payRejectsUnderpayment() public {
        vm.prank(CREATOR);
        vm.expectRevert(ArchemistVerificationPayments.InvalidAmount.selector);
        payments.pay{ value: PRICE - 1 }(TOKEN, REQUEST);
    }

    function test_payReturnsOverpaymentAndEscrowsOnlyThePrice() public {
        uint256 before = CREATOR.balance;
        vm.prank(CREATOR);
        payments.pay{ value: PRICE + 25e6 }(TOKEN, REQUEST);

        assertEq(address(payments).balance, PRICE, "only the price is escrowed");
        assertEq(CREATOR.balance, before - PRICE, "excess must come straight back");
    }

    function test_overpayingPayerThatRejectsRefundsStillBuys() public {
        RejectingPayer payer = new RejectingPayer();
        vm.deal(address(payer), PRICE + 10e6);

        payer.pay(payments, TOKEN, REQUEST, PRICE + 10e6);

        assertEq(address(payments).balance, PRICE + 10e6, "excess is credited, not lost");
        assertEq(payments.claimable(address(payer)), 10e6, "excess owed back to the payer");
        (,, ArchemistVerificationPayments.Status status,,,) = payments.paymentOf(REQUEST);
        assertEq(uint8(status), uint8(ArchemistVerificationPayments.Status.Escrowed), "purchase must survive");
    }

    function test_payRejectsZeroToken() public {
        vm.prank(CREATOR);
        vm.expectRevert(ArchemistVerificationPayments.InvalidAddress.selector);
        payments.pay{ value: PRICE }(address(0), REQUEST);
    }

    function test_payRejectsZeroRequestId() public {
        vm.prank(CREATOR);
        vm.expectRevert(ArchemistVerificationPayments.UnknownRequest.selector);
        payments.pay{ value: PRICE }(TOKEN, bytes32(0));
    }

    function test_payRevertsOnTheWrongChain() public {
        vm.chainId(1);
        vm.prank(CREATOR);
        vm.expectRevert(ArchemistVerificationPayments.WrongChain.selector);
        payments.pay{ value: PRICE }(TOKEN, REQUEST);
    }

    // ---------------------------------------------------------------- settlement

    function test_settleSplitsFeeAndRemainder() public {
        _escrow(REQUEST);

        vm.prank(SETTLER);
        payments.settle(REQUEST);

        assertEq(BLOCKSCOUT.balance, FEE, "blockscout gets the wholesale fee");
        assertEq(TREASURY.balance, PRICE - FEE, "archemist keeps the margin");
        assertEq(address(payments).balance, 0, "nothing left behind");
    }

    function test_settleIsOnceOnly() public {
        _escrow(REQUEST);
        vm.startPrank(SETTLER);
        payments.settle(REQUEST);
        vm.expectRevert(ArchemistVerificationPayments.AlreadyResolved.selector);
        payments.settle(REQUEST);
        vm.stopPrank();
    }

    function test_settledPaymentCannotBeRefunded() public {
        _escrow(REQUEST);
        vm.startPrank(SETTLER);
        payments.settle(REQUEST);
        vm.expectRevert(ArchemistVerificationPayments.AlreadyResolved.selector);
        payments.refund(REQUEST);
        vm.stopPrank();
    }

    function test_settleRejectsUnknownRequest() public {
        vm.prank(SETTLER);
        vm.expectRevert(ArchemistVerificationPayments.UnknownRequest.selector);
        payments.settle(keccak256("never-paid"));
    }

    function test_onlySettlerOrOwnerCanSettle() public {
        _escrow(REQUEST);
        vm.prank(CREATOR);
        vm.expectRevert(ArchemistVerificationPayments.NotAuthorized.selector);
        payments.settle(REQUEST);

        vm.prank(OWNER);
        payments.settle(REQUEST);
        assertEq(BLOCKSCOUT.balance, FEE);
    }

    /// @dev The point of snapshotting the fee: a price change must not reach back into money already paid.
    function test_priceChangeDoesNotAlterAnEscrowedPayment() public {
        _escrow(REQUEST);

        vm.prank(OWNER);
        payments.setPricing(300e6, 250e6);

        vm.prank(SETTLER);
        payments.settle(REQUEST);

        assertEq(BLOCKSCOUT.balance, FEE, "old terms, old fee");
        assertEq(TREASURY.balance, PRICE - FEE);
    }

    function test_settlementSurvivesAnUnreachableBlockscoutAddress() public {
        RejectingRecipient rejecting = new RejectingRecipient();
        vm.prank(OWNER);
        payments.setBlockscoutRecipient(address(rejecting));

        _escrow(REQUEST);
        vm.prank(SETTLER);
        payments.settle(REQUEST);

        assertEq(TREASURY.balance, PRICE - FEE, "archemist's share still lands");
        assertEq(payments.claimable(address(rejecting)), FEE, "blockscout's share is credited, not lost");
        assertEq(address(payments).balance, FEE);
    }

    // ------------------------------------------------------------------ refunds

    function test_refundReturnsEverythingToThePayer() public {
        uint256 before = CREATOR.balance;
        _escrow(REQUEST);

        vm.prank(SETTLER);
        payments.refund(REQUEST);

        assertEq(CREATOR.balance, before, "creator made whole");
        assertEq(address(payments).balance, 0);
        assertEq(BLOCKSCOUT.balance, 0, "a refunded record never pays blockscout");
    }

    function test_refundIsOnceOnly() public {
        _escrow(REQUEST);
        vm.startPrank(SETTLER);
        payments.refund(REQUEST);
        vm.expectRevert(ArchemistVerificationPayments.AlreadyResolved.selector);
        payments.refund(REQUEST);
        vm.stopPrank();
    }

    function test_refundedPaymentCannotBeSettled() public {
        _escrow(REQUEST);
        vm.startPrank(SETTLER);
        payments.refund(REQUEST);
        vm.expectRevert(ArchemistVerificationPayments.AlreadyResolved.selector);
        payments.settle(REQUEST);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------- claims

    function test_expensiveRecipientIsCreditedThenClaimsInFull() public {
        GasHungryRecipient hungry = new GasHungryRecipient();
        vm.prank(OWNER);
        payments.setTreasury(address(hungry));

        _escrow(REQUEST);
        vm.prank(SETTLER);
        payments.settle(REQUEST);

        assertEq(payments.claimable(address(hungry)), PRICE - FEE, "stipend too small: credited instead");
        assertEq(address(hungry).balance, 0);

        uint256 claimed = payments.claim(address(hungry));

        assertEq(claimed, PRICE - FEE);
        assertEq(address(hungry).balance, PRICE - FEE, "full gas lets it through");
        assertEq(payments.claimable(address(hungry)), 0, "credit cleared");
    }

    function test_claimKeepsTheCreditWhenTheRecipientStillRefuses() public {
        RejectingRecipient rejecting = new RejectingRecipient();
        vm.prank(OWNER);
        payments.setTreasury(address(rejecting));

        _escrow(REQUEST);
        vm.prank(SETTLER);
        payments.settle(REQUEST);
        assertEq(payments.claimable(address(rejecting)), PRICE - FEE);

        vm.expectRevert(ArchemistVerificationPayments.NothingToClaim.selector);
        payments.claim(address(rejecting));
        assertEq(payments.claimable(address(rejecting)), PRICE - FEE, "a failed claim must not burn the credit");
    }

    function test_claimRejectsAnEmptyBalance() public {
        vm.expectRevert(ArchemistVerificationPayments.NothingToClaim.selector);
        payments.claim(CREATOR);
    }

    // --------------------------------------------------------------------- admin

    function test_pauseStopsNewPaymentsButNeverTrapsEscrow() public {
        _escrow(REQUEST);

        vm.prank(OWNER);
        payments.setPaused(true);

        vm.prank(CREATOR);
        vm.expectRevert(ArchemistVerificationPayments.Paused.selector);
        payments.pay{ value: PRICE }(TOKEN, keccak256("request-2"));

        vm.prank(SETTLER);
        payments.settle(REQUEST);
        assertEq(BLOCKSCOUT.balance, FEE, "paused must not block settlement of money already taken");
    }

    function test_ownerCanChangeThePriceAlone() public {
        vm.prank(OWNER);
        payments.setPrice(200e6);
        assertEq(payments.price(), 200e6);
        assertEq(payments.blockscoutFee(), FEE, "the wholesale fee is untouched");

        vm.deal(CREATOR, 200e6);
        vm.prank(CREATOR);
        payments.pay{ value: 200e6 }(TOKEN, REQUEST);
        vm.prank(SETTLER);
        payments.settle(REQUEST);
        assertEq(BLOCKSCOUT.balance, FEE, "blockscout still gets exactly its fee");
        assertEq(TREASURY.balance, 200e6 - FEE, "the whole increase goes to archemist");
    }

    function test_ownerCanChangeTheFeeAlone() public {
        vm.prank(OWNER);
        payments.setBlockscoutFee(120e6);
        assertEq(payments.blockscoutFee(), 120e6);
        assertEq(payments.price(), PRICE, "the retail price is untouched");
    }

    function test_setPriceRejectsAPriceBelowTheFee() public {
        vm.prank(OWNER);
        vm.expectRevert(ArchemistVerificationPayments.InvalidFee.selector);
        payments.setPrice(FEE - 1);
    }

    function test_setBlockscoutFeeRejectsAFeeAboveThePrice() public {
        vm.prank(OWNER);
        vm.expectRevert(ArchemistVerificationPayments.InvalidFee.selector);
        payments.setBlockscoutFee(PRICE + 1);
    }

    function test_settlerCannotChangeThePrice() public {
        vm.startPrank(SETTLER);
        vm.expectRevert(ArchemistVerificationPayments.NotAuthorized.selector);
        payments.setPrice(1e6);
        vm.expectRevert(ArchemistVerificationPayments.NotAuthorized.selector);
        payments.setBlockscoutFee(0);
        vm.stopPrank();
    }

    function test_setPricingRejectsAFeeAboveThePrice() public {
        vm.prank(OWNER);
        vm.expectRevert(ArchemistVerificationPayments.InvalidFee.selector);
        payments.setPricing(100e6, 101e6);
    }

    function test_setPricingRejectsAZeroPrice() public {
        vm.prank(OWNER);
        vm.expectRevert(ArchemistVerificationPayments.InvalidAmount.selector);
        payments.setPricing(0, 0);
    }

    /// @dev The security claim of the two-role split: the hot key moves outcomes, never destinations.
    function test_settlerCannotRedirectPayouts() public {
        vm.startPrank(SETTLER);
        vm.expectRevert(ArchemistVerificationPayments.NotAuthorized.selector);
        payments.setTreasury(SETTLER);
        vm.expectRevert(ArchemistVerificationPayments.NotAuthorized.selector);
        payments.setBlockscoutRecipient(SETTLER);
        vm.expectRevert(ArchemistVerificationPayments.NotAuthorized.selector);
        payments.setPricing(1, 0);
        vm.expectRevert(ArchemistVerificationPayments.NotAuthorized.selector);
        payments.setSettler(SETTLER);
        vm.stopPrank();
    }

    function test_ownershipTransferIsTwoStep() public {
        vm.prank(OWNER);
        payments.transferOwnership(CREATOR);
        assertEq(payments.owner(), OWNER, "not until it is accepted");

        vm.prank(CREATOR);
        payments.acceptOwnership();
        assertEq(payments.owner(), CREATOR);
        assertEq(payments.pendingOwner(), address(0));
    }

    // ------------------------------------------------------------------- invariant

    /// @dev Every escrowed payment is either fully settled or fully refunded, and the contract never
    /// holds less than it owes.
    function testFuzz_escrowIsConservedAcrossMixedOutcomes(uint8 count, uint256 settleMask) public {
        count = uint8(bound(count, 1, 32));
        vm.deal(CREATOR, uint256(count) * PRICE);

        for (uint256 i = 0; i < count; i++) {
            vm.prank(CREATOR);
            payments.pay{ value: PRICE }(TOKEN, keccak256(abi.encode("req", i)));
        }
        assertEq(address(payments).balance, uint256(count) * PRICE);

        uint256 settled;
        for (uint256 i = 0; i < count; i++) {
            bytes32 id = keccak256(abi.encode("req", i));
            vm.prank(SETTLER);
            if ((settleMask >> i) & 1 == 1) {
                payments.settle(id);
                settled++;
            } else {
                payments.refund(id);
            }
        }

        assertEq(BLOCKSCOUT.balance, settled * FEE, "blockscout is paid exactly once per published record");
        assertEq(TREASURY.balance, settled * (PRICE - FEE));
        assertEq(address(payments).balance, 0, "nothing stranded");
    }

    function _escrow(bytes32 requestId) internal {
        vm.prank(CREATOR);
        payments.pay{ value: PRICE }(TOKEN, requestId);
    }
}
