// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EscrowTestBase} from "./utils/EscrowTestBase.sol";
import {RentalEscrow} from "../src/RentalEscrow.sol";
import {MockPaymentToken} from "../src/MockPaymentToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract RentalEscrowTest is EscrowTestBase {
    // ---------------------------------------------------------------------
    // Construction & administration
    // ---------------------------------------------------------------------

    function test_constructor_setsTokenAndAdmin() public view {
        assertEq(address(escrow.token()), address(token));
        assertEq(escrow.admin(), admin);
        assertEq(escrow.pendingAdmin(), address(0));
    }

    function test_constructor_revertsOnZeroAddresses() public {
        vm.expectRevert(RentalEscrow.ZeroAddress.selector);
        new RentalEscrow(address(0), admin);
        vm.expectRevert(RentalEscrow.ZeroAddress.selector);
        new RentalEscrow(address(token), address(0));
    }

    function test_adminHandover_twoStep() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(stranger);
        vm.expectRevert(RentalEscrow.NotAdmin.selector);
        escrow.transferAdmin(newAdmin);

        vm.prank(admin);
        vm.expectEmit(true, true, false, true);
        emit RentalEscrow.AdminTransferStarted(admin, newAdmin);
        escrow.transferAdmin(newAdmin);
        assertEq(escrow.admin(), admin, "admin unchanged until accepted");

        vm.prank(stranger);
        vm.expectRevert(RentalEscrow.NotPendingAdmin.selector);
        escrow.acceptAdmin();

        vm.prank(newAdmin);
        vm.expectEmit(true, true, false, true);
        emit RentalEscrow.AdminTransferred(admin, newAdmin);
        escrow.acceptAdmin();
        assertEq(escrow.admin(), newAdmin);
        assertEq(escrow.pendingAdmin(), address(0));

        // Old admin has lost its powers.
        vm.prank(admin);
        vm.expectRevert(RentalEscrow.NotAdmin.selector);
        escrow.setStaff(stranger, true);
    }

    function test_adminHandover_cancelPending() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        escrow.transferAdmin(newAdmin);
        vm.prank(admin);
        escrow.transferAdmin(address(0));
        vm.prank(newAdmin);
        vm.expectRevert(RentalEscrow.NotPendingAdmin.selector);
        escrow.acceptAdmin();
    }

    function test_setStaff_onlyAdmin() public {
        vm.prank(staff);
        vm.expectRevert(RentalEscrow.NotAdmin.selector);
        escrow.setStaff(stranger, true);

        vm.prank(admin);
        vm.expectRevert(RentalEscrow.ZeroAddress.selector);
        escrow.setStaff(address(0), true);

        vm.prank(admin);
        vm.expectEmit(true, false, false, true);
        emit RentalEscrow.StaffUpdated(stranger, true);
        escrow.setStaff(stranger, true);
        assertTrue(escrow.isStaff(stranger));
    }

    function test_createPolicy_validation() public {
        vm.startPrank(admin);
        vm.expectRevert(RentalEscrow.InvalidPolicy.selector);
        escrow.createPolicy(0, 0, WINDOW);
        vm.expectRevert(RentalEscrow.InvalidPolicy.selector);
        escrow.createPolicy(DEPOSIT, DEPOSIT + 1, WINDOW);
        vm.expectRevert(RentalEscrow.InvalidPolicy.selector);
        escrow.createPolicy(DEPOSIT, FEE, 0);

        // fee == deposit and fee == 0 are both allowed
        uint64 p2 = escrow.createPolicy(DEPOSIT, DEPOSIT, 1);
        uint64 p3 = escrow.createPolicy(1, 0, 1);
        vm.stopPrank();

        assertEq(p2, 2);
        assertEq(p3, 3);
        RentalEscrow.Policy memory p = escrow.getPolicy(p2);
        assertEq(p.deposit, DEPOSIT);
        assertEq(p.cancellationFee, DEPOSIT);
        assertEq(p.reservationWindow, 1);

        vm.prank(stranger);
        vm.expectRevert(RentalEscrow.NotAdmin.selector);
        escrow.createPolicy(DEPOSIT, FEE, WINDOW);

        vm.expectRevert(abi.encodeWithSelector(RentalEscrow.PolicyNotFound.selector, uint64(0)));
        escrow.getPolicy(0);
        vm.expectRevert(abi.encodeWithSelector(RentalEscrow.PolicyNotFound.selector, uint64(99)));
        escrow.getPolicy(99);
    }

    function test_items_adminManagement() public {
        vm.prank(stranger);
        vm.expectRevert(RentalEscrow.NotAdmin.selector);
        escrow.addItem(policyId, "x");

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(RentalEscrow.PolicyNotFound.selector, uint64(7)));
        escrow.addItem(7, "x");

        vm.expectEmit(true, true, false, true);
        emit RentalEscrow.ItemAdded(2, policyId, "ipfs://item-2");
        uint256 id2 = escrow.addItem(policyId, "ipfs://item-2");
        assertEq(id2, 2);

        RentalEscrow.Item memory it = escrow.getItem(id2);
        assertTrue(it.exists);
        assertTrue(it.listed);
        assertEq(uint8(it.state), uint8(RentalEscrow.ItemState.Available));
        assertEq(it.policyId, policyId);
        assertEq(it.activeReservationId, 0);
        assertEq(it.metadataURI, "ipfs://item-2");

        escrow.setItemMetadata(id2, "ipfs://item-2b");
        assertEq(escrow.getItem(id2).metadataURI, "ipfs://item-2b");

        vm.expectEmit(true, false, false, true);
        emit RentalEscrow.ItemListingUpdated(id2, false);
        escrow.setItemListed(id2, false);
        assertFalse(escrow.getItem(id2).listed);

        vm.expectRevert(abi.encodeWithSelector(RentalEscrow.ItemNotFound.selector, 42));
        escrow.setItemListed(42, true);
        vm.expectRevert(abi.encodeWithSelector(RentalEscrow.ItemNotFound.selector, 42));
        escrow.setItemPolicy(42, policyId);
        vm.expectRevert(abi.encodeWithSelector(RentalEscrow.PolicyNotFound.selector, uint64(9)));
        escrow.setItemPolicy(id2, 9);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(RentalEscrow.ItemNotFound.selector, 0));
        escrow.getItem(0);
    }

    // ---------------------------------------------------------------------
    // reserve
    // ---------------------------------------------------------------------

    function test_reserve_happyPath() public {
        uint256 renterBefore = token.balanceOf(renter);
        uint64 expectedExpiry = uint64(block.timestamp) + WINDOW;

        vm.prank(renter);
        vm.expectEmit(true, true, true, true);
        emit RentalEscrow.ReservationCreated(1, itemId, renter, policyId, DEPOSIT, FEE, expectedExpiry, REF_A);
        uint256 id = escrow.reserve(itemId, policyId, REF_A);

        assertEq(id, 1);
        assertEq(token.balanceOf(renter), renterBefore - DEPOSIT);
        assertEq(token.balanceOf(address(escrow)), DEPOSIT);
        assertEq(escrow.totalEscrowed(), DEPOSIT);
        assertEq(escrow.totalLiabilities(), DEPOSIT);
        assertEq(escrow.reservationByRef(renter, REF_A), 1);

        RentalEscrow.Reservation memory r = escrow.getReservation(1);
        assertEq(r.itemId, itemId);
        assertEq(r.renter, renter);
        assertEq(r.policyId, policyId);
        assertEq(r.createdAt, uint64(block.timestamp));
        assertEq(r.expiresAt, expectedExpiry);
        assertEq(uint8(r.status), uint8(RentalEscrow.ReservationStatus.Reserved));
        assertEq(r.deposit, DEPOSIT);
        assertEq(r.cancellationFee, FEE);
        assertEq(r.clientRef, REF_A);

        RentalEscrow.Item memory it = escrow.getItem(itemId);
        assertEq(uint8(it.state), uint8(RentalEscrow.ItemState.Reserved));
        assertEq(it.activeReservationId, 1);
        _assertConservation();
    }

    function test_reserve_competing_secondRenterRejected() public {
        _reserve(renter, itemId, REF_A);

        vm.prank(renter2);
        vm.expectRevert(abi.encodeWithSelector(RentalEscrow.ItemNotAvailable.selector, itemId, 1));
        escrow.reserve(itemId, policyId, REF_A);

        // Nothing was taken from the loser.
        assertEq(token.balanceOf(renter2), FUNDING);
        assertEq(escrow.reservationCount(), 1);
        assertEq(escrow.reservationByRef(renter2, REF_A), 0);
    }

    function test_reserve_retryWithSameRefRevertsAndNamesReservation() public {
        uint256 id = _reserve(renter, itemId, REF_A);

        vm.prank(renter);
        vm.expectRevert(abi.encodeWithSelector(RentalEscrow.ClientRefAlreadyUsed.selector, REF_A, id));
        escrow.reserve(itemId, policyId, REF_A);

        // Even after the item is free again the same ref cannot be reused: the retry is dead for good.
        vm.prank(renter);
        escrow.cancel(id);
        vm.prank(renter);
        vm.expectRevert(abi.encodeWithSelector(RentalEscrow.ClientRefAlreadyUsed.selector, REF_A, id));
        escrow.reserve(itemId, policyId, REF_A);

        // A fresh ref works and only one deposit was ever taken per reservation.
        uint256 id2 = _reserve(renter, itemId, REF_B);
        assertEq(id2, 2);
        assertEq(token.balanceOf(renter), FUNDING - 2 * DEPOSIT);
        assertEq(escrow.totalEscrowed(), DEPOSIT);
    }

    function test_reserve_sameRefDifferentRentersAreIndependent() public {
        vm.prank(admin);
        uint256 item2 = escrow.addItem(policyId, "ipfs://item-2");
        uint256 a = _reserve(renter, itemId, REF_A);
        uint256 b = _reserve(renter2, item2, REF_A);
        assertEq(escrow.reservationByRef(renter, REF_A), a);
        assertEq(escrow.reservationByRef(renter2, REF_A), b);
    }

    function test_reserve_rejectsZeroRef() public {
        vm.prank(renter);
        vm.expectRevert(RentalEscrow.ClientRefRequired.selector);
        escrow.reserve(itemId, policyId, bytes32(0));
    }

    function test_reserve_rejectsUnknownOrDelistedItem() public {
        vm.prank(renter);
        vm.expectRevert(abi.encodeWithSelector(RentalEscrow.ItemNotFound.selector, 99));
        escrow.reserve(99, policyId, REF_A);

        vm.prank(admin);
        escrow.setItemListed(itemId, false);
        vm.prank(renter);
        vm.expectRevert(abi.encodeWithSelector(RentalEscrow.ItemNotListed.selector, itemId));
        escrow.reserve(itemId, policyId, REF_A);
        assertEq(token.balanceOf(renter), FUNDING);
    }

    function test_reserve_rejectsStalePolicyQuote() public {
        vm.prank(admin);
        uint64 p2 = escrow.createPolicy(DEPOSIT * 2, FEE, WINDOW);
        vm.prank(admin);
        escrow.setItemPolicy(itemId, p2);

        vm.prank(renter);
        vm.expectRevert(abi.encodeWithSelector(RentalEscrow.PolicyMismatch.selector, policyId, p2));
        escrow.reserve(itemId, policyId, REF_A);
    }

    function test_reserve_insufficientAllowanceOrBalanceTakesNothing() public {
        address poor = makeAddr("poor");
        vm.prank(poor);
        token.approve(address(escrow), type(uint256).max);
        vm.prank(poor);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, poor, 0, DEPOSIT));
        escrow.reserve(itemId, policyId, REF_A);

        address noApproval = makeAddr("noApproval");
        vm.prank(admin);
        token.transfer(noApproval, DEPOSIT);
        vm.prank(noApproval);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(escrow), 0, DEPOSIT)
        );
        escrow.reserve(itemId, policyId, REF_A);

        // Failed attempts leave no trace: the item is still free and no refs are consumed.
        assertEq(escrow.reservationCount(), 0);
        assertEq(escrow.reservationByRef(poor, REF_A), 0);
        assertEq(escrow.reservationByRef(noApproval, REF_A), 0);
        assertEq(uint8(escrow.getItem(itemId).state), uint8(RentalEscrow.ItemState.Available));
        assertEq(escrow.totalEscrowed(), 0);
    }

    function test_reserve_feeOnTransferTokenIsRejected() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        RentalEscrow e2 = new RentalEscrow(address(fot), admin);
        vm.startPrank(admin);
        uint64 p = e2.createPolicy(DEPOSIT, FEE, WINDOW);
        uint256 it = e2.addItem(p, "");
        vm.stopPrank();
        fot.mint(renter, DEPOSIT * 2);
        vm.prank(renter);
        fot.approve(address(e2), type(uint256).max);

        vm.prank(renter);
        vm.expectRevert(abi.encodeWithSelector(RentalEscrow.DepositMismatch.selector, DEPOSIT, DEPOSIT - 1));
        e2.reserve(it, p, REF_A);
        assertEq(e2.totalEscrowed(), 0);
        assertEq(e2.reservationCount(), 0);
    }

    // ---------------------------------------------------------------------
    // cancel
    // ---------------------------------------------------------------------

    function test_cancel_creditsDepositMinusFee() public {
        uint256 id = _reserve(renter, itemId, REF_A);

        vm.prank(renter);
        vm.expectEmit(true, true, false, true);
        emit RentalEscrow.RefundCredited(renter, id, DEPOSIT - FEE);
        vm.expectEmit(true, true, true, true);
        emit RentalEscrow.ReservationCancelled(id, itemId, renter, DEPOSIT - FEE, FEE);
        escrow.cancel(id);

        assertEq(uint8(escrow.getReservation(id).status), uint8(RentalEscrow.ReservationStatus.Cancelled));
        assertEq(uint8(escrow.getItem(itemId).state), uint8(RentalEscrow.ItemState.Available));
        assertEq(escrow.getItem(itemId).activeReservationId, 0);
        assertEq(escrow.refundCreditOf(renter), DEPOSIT - FEE);
        assertEq(escrow.totalRefundCredits(), DEPOSIT - FEE);
        assertEq(escrow.accruedFees(), FEE);
        assertEq(escrow.totalEscrowed(), 0);
        assertEq(escrow.totalLiabilities(), DEPOSIT);
        assertEq(token.balanceOf(address(escrow)), DEPOSIT, "tokens stay in escrow until withdrawn");
        _assertConservation();
    }

    function test_cancel_onlyRenter() public {
        uint256 id = _reserve(renter, itemId, REF_A);
        vm.prank(renter2);
        vm.expectRevert(RentalEscrow.NotRenter.selector);
        escrow.cancel(id);
        vm.prank(staff);
        vm.expectRevert(RentalEscrow.NotRenter.selector);
        escrow.cancel(id);
        vm.prank(admin);
        vm.expectRevert(RentalEscrow.NotRenter.selector);
        escrow.cancel(id);
    }

    function test_cancel_twiceReverts() public {
        uint256 id = _reserve(renter, itemId, REF_A);
        vm.prank(renter);
        escrow.cancel(id);
        vm.prank(renter);
        vm.expectRevert(
            abi.encodeWithSelector(
                RentalEscrow.InvalidReservationStatus.selector, id, RentalEscrow.ReservationStatus.Cancelled
            )
        );
        escrow.cancel(id);
        assertEq(escrow.refundCreditOf(renter), DEPOSIT - FEE, "credited exactly once");
    }

    function test_cancel_unknownReservation() public {
        vm.prank(renter);
        vm.expectRevert(abi.encodeWithSelector(RentalEscrow.ReservationNotFound.selector, 5));
        escrow.cancel(5);
    }

    function test_cancel_afterCheckoutReverts() public {
        uint256 id = _reserve(renter, itemId, REF_A);
        vm.prank(staff);
        escrow.checkOut(id);
        vm.prank(renter);
        vm.expectRevert(
            abi.encodeWithSelector(
                RentalEscrow.InvalidReservationStatus.selector, id, RentalEscrow.ReservationStatus.Rented
            )
        );
        escrow.cancel(id);
    }

    function test_cancel_boundary_lastSecondOkExactExpiryRejected() public {
        uint256 id = _reserve(renter, itemId, REF_A);
        uint64 expiresAt = escrow.getReservation(id).expiresAt;

        // One second before expiry: still cancellable (checked with a snapshot so we can test both sides).
        uint256 snap = vm.snapshotState();
        vm.warp(expiresAt - 1);
        vm.prank(renter);
        escrow.cancel(id);
        assertEq(escrow.refundCreditOf(renter), DEPOSIT - FEE);
        vm.revertToState(snap);

        // Exactly at expiry: cancel is no longer allowed...
        vm.warp(expiresAt);
        vm.prank(renter);
        vm.expectRevert(abi.encodeWithSelector(RentalEscrow.ReservationExpiredAlready.selector, id, expiresAt));
        escrow.cancel(id);
        // ...and the renter is no worse off: expire gives the same credit.
        vm.prank(renter);
        escrow.expire(id);
        assertEq(escrow.refundCreditOf(renter), DEPOSIT - FEE);
    }

    function test_cancel_withZeroFeePolicyCreditsEverything() public {
        vm.prank(admin);
        uint64 p0 = escrow.createPolicy(DEPOSIT, 0, WINDOW);
        vm.prank(admin);
        escrow.setItemPolicy(itemId, p0);
        uint256 id = _reserve(renter, itemId, REF_A);
        vm.prank(renter);
        escrow.cancel(id);
        assertEq(escrow.refundCreditOf(renter), DEPOSIT);
        assertEq(escrow.accruedFees(), 0);
    }

    function test_cancel_withFullFeePolicyCreditsNothing() public {
        vm.prank(admin);
        uint64 pFull = escrow.createPolicy(DEPOSIT, DEPOSIT, WINDOW);
        vm.prank(admin);
        escrow.setItemPolicy(itemId, pFull);
        uint256 id = _reserve(renter, itemId, REF_A);
        vm.prank(renter);
        escrow.cancel(id);
        assertEq(escrow.refundCreditOf(renter), 0);
        assertEq(escrow.totalRefundCredits(), 0);
        assertEq(escrow.accruedFees(), DEPOSIT);
        vm.prank(renter);
        vm.expectRevert(RentalEscrow.NothingToWithdraw.selector);
        escrow.withdrawRefund();
    }

    // ---------------------------------------------------------------------
    // checkOut
    // ---------------------------------------------------------------------

    function test_checkOut_byStaff() public {
        uint256 id = _reserve(renter, itemId, REF_A);
        vm.prank(staff);
        vm.expectEmit(true, true, true, true);
        emit RentalEscrow.ItemCheckedOut(id, itemId, staff);
        escrow.checkOut(id);
        assertEq(uint8(escrow.getReservation(id).status), uint8(RentalEscrow.ReservationStatus.Rented));
        assertEq(uint8(escrow.getItem(itemId).state), uint8(RentalEscrow.ItemState.Rented));
        assertEq(escrow.getItem(itemId).activeReservationId, id);
        assertEq(escrow.totalEscrowed(), DEPOSIT, "deposit stays escrowed while rented");
    }

    function test_checkOut_unauthorizedCallers() public {
        uint256 id = _reserve(renter, itemId, REF_A);
        vm.prank(renter);
        vm.expectRevert(RentalEscrow.NotStaff.selector);
        escrow.checkOut(id);
        vm.prank(stranger);
        vm.expectRevert(RentalEscrow.NotStaff.selector);
        escrow.checkOut(id);
        // admin is not automatically staff
        vm.prank(admin);
        vm.expectRevert(RentalEscrow.NotStaff.selector);
        escrow.checkOut(id);
    }

    function test_checkOut_twiceReverts() public {
        uint256 id = _reserve(renter, itemId, REF_A);
        vm.prank(staff);
        escrow.checkOut(id);
        vm.prank(staff);
        vm.expectRevert(
            abi.encodeWithSelector(
                RentalEscrow.InvalidReservationStatus.selector, id, RentalEscrow.ReservationStatus.Rented
            )
        );
        escrow.checkOut(id);
    }

    function test_checkOut_boundary_rejectedAtExpiry() public {
        uint256 id = _reserve(renter, itemId, REF_A);
        uint64 expiresAt = escrow.getReservation(id).expiresAt;

        uint256 snap = vm.snapshotState();
        vm.warp(expiresAt - 1);
        vm.prank(staff);
        escrow.checkOut(id);
        assertEq(uint8(escrow.getReservation(id).status), uint8(RentalEscrow.ReservationStatus.Rented));
        vm.revertToState(snap);

        vm.warp(expiresAt);
        vm.prank(staff);
        vm.expectRevert(abi.encodeWithSelector(RentalEscrow.ReservationExpiredAlready.selector, id, expiresAt));
        escrow.checkOut(id);
    }

    function test_checkOut_afterCancelReverts() public {
        uint256 id = _reserve(renter, itemId, REF_A);
        vm.prank(renter);
        escrow.cancel(id);
        vm.prank(staff);
        vm.expectRevert(
            abi.encodeWithSelector(
                RentalEscrow.InvalidReservationStatus.selector, id, RentalEscrow.ReservationStatus.Cancelled
            )
        );
        escrow.checkOut(id);
    }

    // ---------------------------------------------------------------------
    // staff revocation
    // ---------------------------------------------------------------------

    function test_staffRevocation_isImmediate() public {
        uint256 id = _reserve(renter, itemId, REF_A);
        vm.prank(admin);
        escrow.setStaff(staff, false);
        assertFalse(escrow.isStaff(staff));

        vm.prank(staff);
        vm.expectRevert(RentalEscrow.NotStaff.selector);
        escrow.checkOut(id);

        // Re-grant and the same call succeeds.
        vm.prank(admin);
        escrow.setStaff(staff, true);
        vm.prank(staff);
        escrow.checkOut(id);

        // Revoke again: the rental cannot be returned by the revoked member.
        vm.prank(admin);
        escrow.setStaff(staff, false);
        vm.prank(staff);
        vm.expectRevert(RentalEscrow.NotStaff.selector);
        escrow.confirmReturn(id);

        // Another staff member can.
        address staff2 = makeAddr("staff2");
        vm.prank(admin);
        escrow.setStaff(staff2, true);
        vm.prank(staff2);
        escrow.confirmReturn(id);
        assertEq(escrow.refundCreditOf(renter), DEPOSIT);
    }

    // ---------------------------------------------------------------------
    // expire
    // ---------------------------------------------------------------------

    function test_expire_byAnyoneAtExpiry() public {
        uint256 id = _reserve(renter, itemId, REF_A);
        uint64 expiresAt = escrow.getReservation(id).expiresAt;

        vm.warp(expiresAt - 1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RentalEscrow.ReservationNotExpired.selector, id, expiresAt));
        escrow.expire(id);

        vm.warp(expiresAt);
        vm.prank(stranger);
        vm.expectEmit(true, true, true, true);
        emit RentalEscrow.ReservationExpired(id, itemId, renter, stranger, DEPOSIT - FEE, FEE);
        escrow.expire(id);

        assertEq(uint8(escrow.getReservation(id).status), uint8(RentalEscrow.ReservationStatus.Expired));
        assertEq(uint8(escrow.getItem(itemId).state), uint8(RentalEscrow.ItemState.Available));
        assertEq(escrow.refundCreditOf(renter), DEPOSIT - FEE, "credit goes to the renter, not the caller");
        assertEq(escrow.refundCreditOf(stranger), 0);
        assertEq(escrow.accruedFees(), FEE);
        assertEq(escrow.totalEscrowed(), 0);
        _assertConservation();

        // The item can be reserved again by someone else.
        uint256 id2 = _reserve(renter2, itemId, REF_A);
        assertEq(id2, 2);
    }

    function test_expire_longAfterExpiryStillWorksOnce() public {
        uint256 id = _reserve(renter, itemId, REF_A);
        vm.warp(block.timestamp + 365 days);
        escrow.expire(id);
        vm.expectRevert(
            abi.encodeWithSelector(
                RentalEscrow.InvalidReservationStatus.selector, id, RentalEscrow.ReservationStatus.Expired
            )
        );
        escrow.expire(id);
        assertEq(escrow.refundCreditOf(renter), DEPOSIT - FEE);
    }

    function test_expire_rentedItemsNeverExpire() public {
        uint256 id = _reserve(renter, itemId, REF_A);
        vm.prank(staff);
        escrow.checkOut(id);
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(
            abi.encodeWithSelector(
                RentalEscrow.InvalidReservationStatus.selector, id, RentalEscrow.ReservationStatus.Rented
            )
        );
        escrow.expire(id);
        assertEq(escrow.totalEscrowed(), DEPOSIT);
    }

    function test_expire_cancelledOrUnknownReverts() public {
        uint256 id = _reserve(renter, itemId, REF_A);
        vm.prank(renter);
        escrow.cancel(id);
        vm.warp(block.timestamp + WINDOW);
        vm.expectRevert(
            abi.encodeWithSelector(
                RentalEscrow.InvalidReservationStatus.selector, id, RentalEscrow.ReservationStatus.Cancelled
            )
        );
        escrow.expire(id);
        vm.expectRevert(abi.encodeWithSelector(RentalEscrow.ReservationNotFound.selector, 77));
        escrow.expire(77);
    }

    // ---------------------------------------------------------------------
    // confirmReturn
    // ---------------------------------------------------------------------

    function test_confirmReturn_creditsFullDeposit() public {
        uint256 id = _reserve(renter, itemId, REF_A);
        vm.prank(staff);
        escrow.checkOut(id);
        vm.warp(block.timestamp + 10 days); // long after expiry: irrelevant once rented

        vm.prank(staff);
        vm.expectEmit(true, true, false, true);
        emit RentalEscrow.RefundCredited(renter, id, DEPOSIT);
        vm.expectEmit(true, true, true, true);
        emit RentalEscrow.ItemReturned(id, itemId, staff, DEPOSIT);
        escrow.confirmReturn(id);

        assertEq(uint8(escrow.getReservation(id).status), uint8(RentalEscrow.ReservationStatus.Returned));
        assertEq(uint8(escrow.getItem(itemId).state), uint8(RentalEscrow.ItemState.Available));
        assertEq(escrow.getItem(itemId).activeReservationId, 0);
        assertEq(escrow.refundCreditOf(renter), DEPOSIT);
        assertEq(escrow.accruedFees(), 0);
        assertEq(escrow.totalEscrowed(), 0);
        _assertConservation();
    }

    function test_confirmReturn_requiresRentedStatus() public {
        uint256 id = _reserve(renter, itemId, REF_A);
        vm.prank(staff);
        vm.expectRevert(
            abi.encodeWithSelector(
                RentalEscrow.InvalidReservationStatus.selector, id, RentalEscrow.ReservationStatus.Reserved
            )
        );
        escrow.confirmReturn(id);
    }

    function test_confirmReturn_twiceReverts_singleCredit() public {
        uint256 id = _reserve(renter, itemId, REF_A);
        vm.prank(staff);
        escrow.checkOut(id);
        vm.prank(staff);
        escrow.confirmReturn(id);
        vm.prank(staff);
        vm.expectRevert(
            abi.encodeWithSelector(
                RentalEscrow.InvalidReservationStatus.selector, id, RentalEscrow.ReservationStatus.Returned
            )
        );
        escrow.confirmReturn(id);
        assertEq(escrow.refundCreditOf(renter), DEPOSIT);
        assertEq(escrow.totalRefundCredits(), DEPOSIT);
    }

    function test_confirmReturn_unauthorized() public {
        uint256 id = _reserve(renter, itemId, REF_A);
        vm.prank(staff);
        escrow.checkOut(id);
        vm.prank(renter);
        vm.expectRevert(RentalEscrow.NotStaff.selector);
        escrow.confirmReturn(id);
        vm.prank(admin);
        vm.expectRevert(RentalEscrow.NotStaff.selector);
        escrow.confirmReturn(id);
    }

    // ---------------------------------------------------------------------
    // withdrawRefund
    // ---------------------------------------------------------------------

    function test_withdrawRefund_paysOnceOnly() public {
        uint256 id = _reserve(renter, itemId, REF_A);
        vm.prank(renter);
        escrow.cancel(id);

        uint256 before = token.balanceOf(renter);
        vm.prank(renter);
        vm.expectEmit(true, false, false, true);
        emit RentalEscrow.RefundWithdrawn(renter, DEPOSIT - FEE);
        uint256 paid = escrow.withdrawRefund();
        assertEq(paid, DEPOSIT - FEE);
        assertEq(token.balanceOf(renter), before + DEPOSIT - FEE);
        assertEq(escrow.refundCreditOf(renter), 0);
        assertEq(escrow.totalRefundCredits(), 0);
        assertEq(token.balanceOf(address(escrow)), FEE);

        // Retry: nothing more to pay.
        vm.prank(renter);
        vm.expectRevert(RentalEscrow.NothingToWithdraw.selector);
        escrow.withdrawRefund();
        assertEq(token.balanceOf(renter), before + DEPOSIT - FEE);
        _assertConservation();
    }

    function test_withdrawRefund_isPerBeneficiary() public {
        uint256 id = _reserve(renter, itemId, REF_A);
        vm.prank(renter);
        escrow.cancel(id);
        vm.prank(renter2);
        vm.expectRevert(RentalEscrow.NothingToWithdraw.selector);
        escrow.withdrawRefund();
        vm.prank(stranger);
        vm.expectRevert(RentalEscrow.NothingToWithdraw.selector);
        escrow.withdrawRefund();
    }

    function test_withdrawRefund_accumulatesAcrossReservations() public {
        uint256 a = _reserve(renter, itemId, REF_A);
        vm.prank(renter);
        escrow.cancel(a);
        uint256 b = _reserve(renter, itemId, REF_B);
        vm.prank(staff);
        escrow.checkOut(b);
        vm.prank(staff);
        escrow.confirmReturn(b);
        assertEq(escrow.refundCreditOf(renter), (DEPOSIT - FEE) + DEPOSIT);
        vm.prank(renter);
        assertEq(escrow.withdrawRefund(), (DEPOSIT - FEE) + DEPOSIT);
        assertEq(token.balanceOf(renter), FUNDING - FEE);
    }

    // ---------------------------------------------------------------------
    // withdrawFees
    // ---------------------------------------------------------------------

    function test_withdrawFees_adminOnlyAndBounded() public {
        uint256 id = _reserve(renter, itemId, REF_A);
        vm.prank(renter);
        escrow.cancel(id);
        address treasury = makeAddr("treasury");

        vm.prank(staff);
        vm.expectRevert(RentalEscrow.NotAdmin.selector);
        escrow.withdrawFees(treasury, FEE);

        vm.startPrank(admin);
        vm.expectRevert(RentalEscrow.ZeroAddress.selector);
        escrow.withdrawFees(address(0), FEE);
        vm.expectRevert(RentalEscrow.ZeroAmount.selector);
        escrow.withdrawFees(treasury, 0);
        // The contract holds DEPOSIT, but only FEE is withdrawable: refund credits are untouchable.
        vm.expectRevert(abi.encodeWithSelector(RentalEscrow.InsufficientFees.selector, FEE + 1, FEE));
        escrow.withdrawFees(treasury, FEE + 1);
        vm.expectRevert(abi.encodeWithSelector(RentalEscrow.InsufficientFees.selector, DEPOSIT, FEE));
        escrow.withdrawFees(treasury, DEPOSIT);

        vm.expectEmit(true, false, false, true);
        emit RentalEscrow.FeesWithdrawn(treasury, FEE - 1);
        escrow.withdrawFees(treasury, FEE - 1);
        escrow.withdrawFees(treasury, 1);
        vm.expectRevert(abi.encodeWithSelector(RentalEscrow.InsufficientFees.selector, 1, 0));
        escrow.withdrawFees(treasury, 1);
        vm.stopPrank();

        assertEq(token.balanceOf(treasury), FEE);
        assertEq(escrow.accruedFees(), 0);
        // Renter can still withdraw their full credit afterwards.
        vm.prank(renter);
        assertEq(escrow.withdrawRefund(), DEPOSIT - FEE);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_withdrawFees_cannotReachEscrowedDeposits() public {
        _reserve(renter, itemId, REF_A);
        assertEq(token.balanceOf(address(escrow)), DEPOSIT);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(RentalEscrow.InsufficientFees.selector, 1, 0));
        escrow.withdrawFees(admin, 1);
    }

    // ---------------------------------------------------------------------
    // policy changes during an existing reservation
    // ---------------------------------------------------------------------

    function test_policyChange_doesNotAffectExistingReservation() public {
        uint256 id = _reserve(renter, itemId, REF_A);

        vm.startPrank(admin);
        uint64 p2 = escrow.createPolicy(DEPOSIT * 4, DEPOSIT * 2, 10 minutes);
        vm.expectEmit(true, true, true, true);
        emit RentalEscrow.ItemPolicyUpdated(itemId, policyId, p2);
        escrow.setItemPolicy(itemId, p2);
        vm.stopPrank();

        RentalEscrow.Reservation memory r = escrow.getReservation(id);
        assertEq(r.policyId, policyId);
        assertEq(r.deposit, DEPOSIT);
        assertEq(r.cancellationFee, FEE);
        assertEq(r.expiresAt, uint64(block.timestamp) + WINDOW);

        // After the new 10-minute window would have expired, the old reservation is still live.
        vm.warp(block.timestamp + 11 minutes);
        vm.expectRevert(abi.encodeWithSelector(RentalEscrow.ReservationNotExpired.selector, id, r.expiresAt));
        escrow.expire(id);

        // Cancel applies the OLD fee.
        vm.prank(renter);
        escrow.cancel(id);
        assertEq(escrow.refundCreditOf(renter), DEPOSIT - FEE);
        assertEq(escrow.accruedFees(), FEE);

        // The next reservation uses the NEW policy.
        (uint64 pid, RentalEscrow.Policy memory p) = escrow.quote(itemId);
        assertEq(pid, p2);
        assertEq(p.deposit, DEPOSIT * 4);
        vm.prank(renter2);
        uint256 id2 = escrow.reserve(itemId, p2, REF_A);
        RentalEscrow.Reservation memory r2 = escrow.getReservation(id2);
        assertEq(r2.deposit, DEPOSIT * 4);
        assertEq(r2.cancellationFee, DEPOSIT * 2);
        assertEq(r2.expiresAt, uint64(block.timestamp) + 10 minutes);
        assertEq(token.balanceOf(renter2), FUNDING - DEPOSIT * 4);
    }

    function test_delistingDuringReservation_doesNotBreakLifecycle() public {
        uint256 id = _reserve(renter, itemId, REF_A);
        vm.prank(admin);
        escrow.setItemListed(itemId, false);
        vm.prank(staff);
        escrow.checkOut(id);
        vm.prank(staff);
        escrow.confirmReturn(id);
        assertEq(escrow.refundCreditOf(renter), DEPOSIT);
        // but no new reservation while delisted
        vm.prank(renter2);
        vm.expectRevert(abi.encodeWithSelector(RentalEscrow.ItemNotListed.selector, itemId));
        escrow.reserve(itemId, policyId, REF_A);
    }

    // ---------------------------------------------------------------------
    // full lifecycle & reuse
    // ---------------------------------------------------------------------

    function test_fullLifecycle_itemReusedAcrossManyRentals() public {
        for (uint256 i = 1; i <= 5; i++) {
            bytes32 ref = keccak256(abi.encode("cycle", i));
            address who = i % 2 == 0 ? renter : renter2;
            uint256 id = _reserve(who, itemId, ref);
            assertEq(id, i);
            vm.prank(staff);
            escrow.checkOut(id);
            vm.warp(block.timestamp + 2 days);
            vm.prank(staff);
            escrow.confirmReturn(id);
            _assertConservation();
        }
        vm.prank(renter);
        escrow.withdrawRefund();
        vm.prank(renter2);
        escrow.withdrawRefund();
        assertEq(token.balanceOf(renter), FUNDING);
        assertEq(token.balanceOf(renter2), FUNDING);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(escrow.totalLiabilities(), 0);
    }

    function test_views_revertOnUnknownReservation() public {
        vm.expectRevert(abi.encodeWithSelector(RentalEscrow.ReservationNotFound.selector, 0));
        escrow.getReservation(0);
        vm.expectRevert(abi.encodeWithSelector(RentalEscrow.ReservationNotFound.selector, 1));
        escrow.getReservation(1);
    }
}

/// @dev Minimal token that burns 1 base unit of every transfer, to prove the exact-deposit check.
contract FeeOnTransferToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - 1; // 1 unit "fee" burned
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount - 1;
        return true;
    }
}
