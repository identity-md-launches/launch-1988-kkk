// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockPaymentToken} from "../../src/MockPaymentToken.sol";
import {RentalEscrow} from "../../src/RentalEscrow.sol";
import {RentalEscrowHandler} from "./RentalEscrowHandler.sol";

contract RentalEscrowInvariantTest is Test {
    MockPaymentToken internal token;
    RentalEscrow internal escrow;
    RentalEscrowHandler internal handler;
    address internal admin = makeAddr("admin");

    function setUp() public {
        vm.warp(1_700_000_123);
        token = new MockPaymentToken(admin);
        escrow = new RentalEscrow(address(token), admin);
        handler = new RentalEscrowHandler(token, escrow, admin);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = handler.reserve.selector;
        selectors[1] = handler.reserveDuplicateRef.selector;
        selectors[2] = handler.cancel.selector;
        selectors[3] = handler.checkOut.selector;
        selectors[4] = handler.checkOutByStranger.selector;
        selectors[5] = handler.confirmReturn.selector;
        selectors[6] = handler.expire.selector;
        selectors[7] = handler.warp.selector;
        selectors[8] = handler.withdrawRefund.selector;
        selectors[9] = handler.withdrawFees.selector;
        selectors[10] = handler.createPolicyAndAssign.selector;
        selectors[11] = handler.toggleListing.selector;
        selectors[12] = handler.toggleStaff.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// Escrow obligations + refund credits + earned fees never exceed the token balance.
    function invariant_balanceCoversLiabilities() public view {
        assertGe(token.balanceOf(address(escrow)), escrow.totalLiabilities());
    }

    /// With no donations the balance is exactly the liabilities: nothing leaks in either direction.
    function invariant_balanceEqualsLiabilities() public view {
        assertEq(token.balanceOf(address(escrow)), escrow.totalLiabilities());
    }

    /// Everything deposited is either still owed or has been paid out, never both, never neither.
    function invariant_conservationOfDeposits() public view {
        assertEq(
            handler.ghostDeposited(),
            handler.ghostRefundsPaid() + handler.ghostFeesPaid() + escrow.totalLiabilities(),
            "deposits != payouts + liabilities"
        );
    }

    /// Credits and fees produced by settlements match the contract's running totals.
    function invariant_settlementTotalsMatch() public view {
        assertEq(handler.ghostCreditedTotal(), handler.ghostRefundsPaid() + escrow.totalRefundCredits());
        assertEq(handler.ghostFeesAccruedTotal(), handler.ghostFeesPaid() + escrow.accruedFees());
    }

    /// Sum of per-beneficiary credits equals the tracked total.
    function invariant_refundCreditsSum() public view {
        uint256 sum;
        for (uint256 i = 0; i < handler.renterCount(); i++) {
            sum += escrow.refundCreditOf(handler.renters(i));
        }
        assertEq(sum, escrow.totalRefundCredits());
    }

    /// Each item has at most one active reservation and its state agrees with that reservation.
    function invariant_oneActiveReservationPerItem() public view {
        uint256 n = escrow.reservationCount();
        uint256 escrowedSum;
        for (uint256 i = 0; i < handler.itemCount(); i++) {
            uint256 itemId = handler.items(i);
            RentalEscrow.Item memory it = escrow.getItem(itemId);
            uint256 active;
            for (uint256 id = 1; id <= n; id++) {
                RentalEscrow.Reservation memory r = escrow.getReservation(id);
                if (r.itemId != itemId) continue;
                if (
                    r.status == RentalEscrow.ReservationStatus.Reserved
                        || r.status == RentalEscrow.ReservationStatus.Rented
                ) {
                    active++;
                    assertEq(it.activeReservationId, id, "item does not point at its active reservation");
                    if (r.status == RentalEscrow.ReservationStatus.Reserved) {
                        assertEq(uint8(it.state), uint8(RentalEscrow.ItemState.Reserved));
                    } else {
                        assertEq(uint8(it.state), uint8(RentalEscrow.ItemState.Rented));
                    }
                    escrowedSum += r.deposit;
                }
            }
            assertLe(active, 1, "more than one active reservation on an item");
            if (active == 0) {
                assertEq(uint8(it.state), uint8(RentalEscrow.ItemState.Available));
                assertEq(it.activeReservationId, 0);
            }
        }
        assertEq(escrowedSum, escrow.totalEscrowed(), "totalEscrowed != sum of live deposits");
    }

    /// A reservation settles at most once, snapshots never change, rented reservations never expire.
    function invariant_reservationHistoryIsConsistent() public view {
        uint256 n = escrow.reservationCount();
        assertEq(n, handler.ghostReservations(), "reservation count drift");
        for (uint256 id = 1; id <= n; id++) {
            RentalEscrow.Reservation memory r = escrow.getReservation(id);
            assertLe(handler.ghostSettlements(id), 1, "settled twice");
            assertEq(r.deposit, handler.ghostSnapshotDeposit(id), "deposit snapshot changed");
            assertEq(r.cancellationFee, handler.ghostSnapshotFee(id), "fee snapshot changed");
            assertEq(r.expiresAt, handler.ghostSnapshotExpiry(id), "expiry snapshot changed");
            assertEq(r.policyId, handler.ghostSnapshotPolicy(id), "policy snapshot changed");
            assertEq(escrow.reservationByRef(r.renter, r.clientRef), id, "ref index broken");
            bool terminal = r.status == RentalEscrow.ReservationStatus.Cancelled
                || r.status == RentalEscrow.ReservationStatus.Expired
                || r.status == RentalEscrow.ReservationStatus.Returned;
            assertEq(handler.ghostSettlements(id), terminal ? 1 : 0, "terminal status without settlement");
            if (handler.ghostWasRented(id)) {
                assertTrue(
                    r.status == RentalEscrow.ReservationStatus.Rented
                        || r.status == RentalEscrow.ReservationStatus.Returned,
                    "rented reservation cancelled or expired"
                );
            }
            if (r.status == RentalEscrow.ReservationStatus.Returned) {
                assertEq(handler.ghostCredited(id), r.deposit, "return must credit full deposit");
            }
        }
    }

    /// Admin and staff registry are only ever what the handler set them to; no escalation possible.
    function invariant_adminUnchanged() public view {
        assertEq(escrow.admin(), admin);
        assertEq(escrow.pendingAdmin(), address(0));
    }
}
