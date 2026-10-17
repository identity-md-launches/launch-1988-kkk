// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EscrowTestBase} from "./utils/EscrowTestBase.sol";
import {RentalEscrow} from "../src/RentalEscrow.sol";

contract RentalEscrowFuzzTest is EscrowTestBase {
    uint256 internal constant MAX_DEPOSIT = 1_000_000_000; // 1,000 dds, well under renter funding

    function _policyWith(uint256 deposit, uint256 fee, uint64 window) internal returns (uint64 pid) {
        vm.prank(admin);
        pid = escrow.createPolicy(deposit, fee, window);
        vm.prank(admin);
        escrow.setItemPolicy(itemId, pid);
    }

    /// Reserve takes exactly the deposit, snapshots the policy and nothing else moves.
    function testFuzz_reserve_exactDepositAndSnapshot(uint256 deposit, uint256 fee, uint64 window, bytes32 ref) public {
        deposit = bound(deposit, 1, MAX_DEPOSIT);
        fee = bound(fee, 0, deposit);
        window = uint64(bound(window, 1, 365 days));
        vm.assume(ref != bytes32(0));
        uint64 pid = _policyWith(deposit, fee, window);

        uint256 before = token.balanceOf(renter);
        vm.prank(renter);
        uint256 id = escrow.reserve(itemId, pid, ref);

        assertEq(token.balanceOf(renter), before - deposit);
        assertEq(token.balanceOf(address(escrow)), deposit);
        assertEq(escrow.totalEscrowed(), deposit);
        RentalEscrow.Reservation memory r = escrow.getReservation(id);
        assertEq(r.deposit, deposit);
        assertEq(r.cancellationFee, fee);
        assertEq(r.policyId, pid);
        assertEq(r.expiresAt, uint64(block.timestamp) + window);
        assertEq(escrow.reservationByRef(renter, ref), id);
        _assertConservation();
    }

    /// Exactly one of cancel/expire is possible at any time, split at `expiresAt`, with identical credit.
    function testFuzz_expiryBoundary_cancelVsExpire(uint256 deposit, uint256 fee, uint64 window, uint64 elapsed)
        public
    {
        deposit = bound(deposit, 1, MAX_DEPOSIT);
        fee = bound(fee, 0, deposit);
        window = uint64(bound(window, 1, 30 days));
        elapsed = uint64(bound(elapsed, 0, 60 days));
        uint64 pid = _policyWith(deposit, fee, window);
        uint256 id = _reserve(renter, itemId, REF_A);
        uint64 expiresAt = escrow.getReservation(id).expiresAt;

        vm.warp(block.timestamp + elapsed);

        if (elapsed < window) {
            vm.expectRevert(abi.encodeWithSelector(RentalEscrow.ReservationNotExpired.selector, id, expiresAt));
            escrow.expire(id);
            vm.prank(renter);
            escrow.cancel(id);
            assertEq(uint8(escrow.getReservation(id).status), uint8(RentalEscrow.ReservationStatus.Cancelled));
        } else {
            vm.prank(renter);
            vm.expectRevert(abi.encodeWithSelector(RentalEscrow.ReservationExpiredAlready.selector, id, expiresAt));
            escrow.cancel(id);
            vm.prank(staff);
            vm.expectRevert(abi.encodeWithSelector(RentalEscrow.ReservationExpiredAlready.selector, id, expiresAt));
            escrow.checkOut(id);
            vm.prank(stranger);
            escrow.expire(id);
            assertEq(uint8(escrow.getReservation(id).status), uint8(RentalEscrow.ReservationStatus.Expired));
        }

        assertEq(escrow.refundCreditOf(renter), deposit - fee);
        assertEq(escrow.accruedFees(), fee);
        assertEq(escrow.totalEscrowed(), 0);
        assertEq(uint8(escrow.getItem(itemId).state), uint8(RentalEscrow.ItemState.Available));
        _assertConservation();
        // the policy id is still what was snapshotted
        assertEq(escrow.getReservation(id).policyId, pid);
    }

    /// Checkout before expiry makes the reservation immune to expiry forever and returns the full deposit.
    function testFuzz_rentedNeverExpires(uint256 deposit, uint256 fee, uint64 window, uint64 later) public {
        deposit = bound(deposit, 1, MAX_DEPOSIT);
        fee = bound(fee, 0, deposit);
        window = uint64(bound(window, 1, 30 days));
        later = uint64(bound(later, 0, 1000 days));
        _policyWith(deposit, fee, window);
        uint256 id = _reserve(renter, itemId, REF_A);

        vm.warp(block.timestamp + window - 1);
        vm.prank(staff);
        escrow.checkOut(id);

        vm.warp(block.timestamp + later);
        vm.expectRevert(
            abi.encodeWithSelector(
                RentalEscrow.InvalidReservationStatus.selector, id, RentalEscrow.ReservationStatus.Rented
            )
        );
        escrow.expire(id);

        vm.prank(staff);
        escrow.confirmReturn(id);
        assertEq(escrow.refundCreditOf(renter), deposit, "full deposit, no fee on return");
        assertEq(escrow.accruedFees(), 0);
        _assertConservation();
    }

    /// Whatever policy is set after a reservation exists, settlement uses the snapshot.
    function testFuzz_policyChangeDoesNotLeak(
        uint256 deposit,
        uint256 fee,
        uint64 window,
        uint256 newDeposit,
        uint256 newFee,
        uint64 newWindow,
        bool cancelPath
    ) public {
        deposit = bound(deposit, 1, MAX_DEPOSIT);
        fee = bound(fee, 0, deposit);
        window = uint64(bound(window, 2, 30 days));
        newDeposit = bound(newDeposit, 1, MAX_DEPOSIT);
        newFee = bound(newFee, 0, newDeposit);
        newWindow = uint64(bound(newWindow, 1, 30 days));

        _policyWith(deposit, fee, window);
        uint256 id = _reserve(renter, itemId, REF_A);
        uint64 originalExpiry = escrow.getReservation(id).expiresAt;

        uint64 pNew = _policyWith(newDeposit, newFee, newWindow);

        RentalEscrow.Reservation memory r = escrow.getReservation(id);
        assertEq(r.deposit, deposit);
        assertEq(r.cancellationFee, fee);
        assertEq(r.expiresAt, originalExpiry);

        if (cancelPath) {
            vm.warp(originalExpiry - 1);
            vm.prank(renter);
            escrow.cancel(id);
        } else {
            vm.warp(originalExpiry);
            escrow.expire(id);
        }
        assertEq(escrow.refundCreditOf(renter), deposit - fee);
        assertEq(escrow.accruedFees(), fee);

        // Next reservation picks up the new policy.
        vm.prank(renter2);
        uint256 id2 = escrow.reserve(itemId, pNew, REF_B);
        RentalEscrow.Reservation memory r2 = escrow.getReservation(id2);
        assertEq(r2.deposit, newDeposit);
        assertEq(r2.cancellationFee, newFee);
        assertEq(r2.expiresAt, uint64(block.timestamp) + newWindow);
        _assertConservation();
    }

    /// Two arbitrary renters compete for one item: exactly one reservation, exactly one deposit.
    function testFuzz_competingReservations(address a, address b, bytes32 refA, bytes32 refB) public {
        vm.assume(a != b && a != address(0) && b != address(0));
        vm.assume(a != address(escrow) && b != address(escrow) && a != address(token) && b != address(token));
        vm.assume(a.code.length == 0 && b.code.length == 0);
        vm.assume(refA != bytes32(0) && refB != bytes32(0));

        deal(address(token), a, DEPOSIT);
        deal(address(token), b, DEPOSIT);
        vm.prank(a);
        token.approve(address(escrow), DEPOSIT);
        vm.prank(b);
        token.approve(address(escrow), DEPOSIT);

        vm.prank(a);
        uint256 id = escrow.reserve(itemId, policyId, refA);
        vm.prank(b);
        vm.expectRevert(abi.encodeWithSelector(RentalEscrow.ItemNotAvailable.selector, itemId, id));
        escrow.reserve(itemId, policyId, refB);

        assertEq(escrow.reservationCount(), 1);
        assertEq(token.balanceOf(a), 0);
        assertEq(token.balanceOf(b), DEPOSIT);
        assertEq(escrow.totalEscrowed(), DEPOSIT);
        assertEq(escrow.reservationByRef(b, refB), 0);
    }

    /// With no intervening settlements, a refund is paid once and subsequent calls revert.
    function testFuzz_refundRetries(uint8 retries, bool viaReturn) public {
        uint256 id = _reserve(renter, itemId, REF_A);
        uint256 expected;
        if (viaReturn) {
            vm.prank(staff);
            escrow.checkOut(id);
            vm.prank(staff);
            escrow.confirmReturn(id);
            expected = DEPOSIT;
        } else {
            vm.prank(renter);
            escrow.cancel(id);
            expected = DEPOSIT - FEE;
        }

        uint256 before = token.balanceOf(renter);
        vm.prank(renter);
        assertEq(escrow.withdrawRefund(), expected);
        for (uint256 i = 0; i < retries; i++) {
            vm.prank(renter);
            vm.expectRevert(RentalEscrow.NothingToWithdraw.selector);
            escrow.withdrawRefund();
        }
        assertEq(token.balanceOf(renter), before + expected);
        assertEq(escrow.totalRefundCredits(), 0);
        _assertConservation();
    }

    /// Duplicate state transitions never settle twice, whatever order and timing they are attempted in.
    function testFuzz_duplicateActionsSettleOnce(uint8 path, uint64 elapsed) public {
        path = uint8(bound(path, 0, 2));
        elapsed = uint64(bound(elapsed, 0, 3 * WINDOW));
        uint256 id = _reserve(renter, itemId, REF_A);
        uint64 expiresAt = escrow.getReservation(id).expiresAt;

        if (path == 0) {
            vm.prank(renter);
            escrow.cancel(id);
        } else if (path == 1) {
            vm.warp(expiresAt);
            escrow.expire(id);
        } else {
            vm.prank(staff);
            escrow.checkOut(id);
            vm.prank(staff);
            escrow.confirmReturn(id);
        }
        uint256 credit = escrow.refundCreditOf(renter);
        uint256 fees = escrow.accruedFees();

        vm.warp(block.timestamp + elapsed);
        vm.prank(renter);
        vm.expectRevert();
        escrow.cancel(id);
        vm.expectRevert();
        escrow.expire(id);
        vm.prank(staff);
        vm.expectRevert();
        escrow.checkOut(id);
        vm.prank(staff);
        vm.expectRevert();
        escrow.confirmReturn(id);

        assertEq(escrow.refundCreditOf(renter), credit);
        assertEq(escrow.accruedFees(), fees);
        assertEq(escrow.totalEscrowed(), 0);
        assertEq(escrow.totalLiabilities(), DEPOSIT);
        _assertConservation();
    }

    /// Fee withdrawals are capped at accrued fees no matter how much the contract holds.
    function testFuzz_feeWithdrawalBounded(uint256 amount, uint8 cancelled, uint8 held) public {
        cancelled = uint8(bound(cancelled, 0, 10));
        held = uint8(bound(held, 0, 10));
        // `cancelled` settled reservations produce fees; `held` live reservations keep deposits escrowed.
        vm.startPrank(admin);
        uint256[] memory items = new uint256[](held);
        for (uint256 i = 0; i < held; i++) {
            items[i] = escrow.addItem(policyId, "");
        }
        vm.stopPrank();
        for (uint256 i = 0; i < cancelled; i++) {
            uint256 id = _reserve(renter, itemId, keccak256(abi.encode("c", i)));
            vm.prank(renter);
            escrow.cancel(id);
        }
        for (uint256 i = 0; i < held; i++) {
            _reserve(renter2, items[i], keccak256(abi.encode("h", i)));
        }
        uint256 fees = uint256(cancelled) * FEE;
        assertEq(escrow.accruedFees(), fees);
        uint256 balance = token.balanceOf(address(escrow));
        assertEq(balance, uint256(cancelled) * DEPOSIT + uint256(held) * DEPOSIT);

        amount = bound(amount, 1, balance + 1);
        vm.prank(admin);
        if (amount > fees) {
            vm.expectRevert(abi.encodeWithSelector(RentalEscrow.InsufficientFees.selector, amount, fees));
            escrow.withdrawFees(REF_A, admin, amount);
        } else {
            escrow.withdrawFees(REF_A, admin, amount);
            assertEq(escrow.accruedFees(), fees - amount);
        }
        _assertConservation();
    }

    /// Unauthorized callers can never move a reservation forward, in any status.
    function testFuzz_unauthorizedCallersRejected(address caller, uint8 stage) public {
        vm.assume(caller != renter && caller != staff && caller != admin);
        stage = uint8(bound(stage, 0, 1));
        uint256 id = _reserve(renter, itemId, REF_A);
        if (stage == 1) {
            vm.prank(staff);
            escrow.checkOut(id);
        }

        vm.startPrank(caller);
        vm.expectRevert(RentalEscrow.NotRenter.selector);
        escrow.cancel(id);
        vm.expectRevert(RentalEscrow.NotStaff.selector);
        escrow.checkOut(id);
        vm.expectRevert(RentalEscrow.NotStaff.selector);
        escrow.confirmReturn(id);
        vm.expectRevert(RentalEscrow.NotAdmin.selector);
        escrow.setStaff(caller, true);
        vm.expectRevert(RentalEscrow.NotAdmin.selector);
        escrow.withdrawFees(REF_A, caller, 1);
        vm.expectRevert(RentalEscrow.NotAdmin.selector);
        escrow.createPolicy(1, 0, 1);
        vm.expectRevert(RentalEscrow.NotAdmin.selector);
        escrow.setItemPolicy(itemId, policyId);
        vm.expectRevert(RentalEscrow.NotAdmin.selector);
        escrow.setItemListed(itemId, false);
        vm.expectRevert(RentalEscrow.NotAdmin.selector);
        escrow.addItem(policyId, "");
        vm.expectRevert(RentalEscrow.NotAdmin.selector);
        escrow.transferAdmin(caller);
        vm.expectRevert(RentalEscrow.NotPendingAdmin.selector);
        escrow.acceptAdmin();
        vm.stopPrank();

        assertEq(escrow.totalEscrowed(), DEPOSIT);
        assertEq(escrow.admin(), admin);
    }
}
