// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockPaymentToken} from "../../src/MockPaymentToken.sol";
import {RentalEscrow} from "../../src/RentalEscrow.sol";

/// @dev Bounded random driver for the invariant suite. Every public function here is a candidate
///      action; the fuzzer picks the sequence. Each escrow call that may legitimately revert is wrapped
///      in try/catch, and the run is configured with fail_on_revert = true, so a revert escaping the
///      handler (including any failed assertion below) fails the invariant test. Ghost variables track
///      what *should* have happened so the invariants can compare.
contract RentalEscrowHandler is Test {
    MockPaymentToken public token;
    RentalEscrow public escrow;

    address public admin;
    address[] public staffMembers;
    address[] public renters;
    uint256[] public items;

    // --- ghost accounting ---
    uint256 public ghostDeposited; // total pulled into escrow by successful reserves
    uint256 public ghostRefundsPaid; // total paid out by withdrawRefund
    uint256 public ghostFeesPaid; // total paid out by withdrawFees
    uint256 public ghostReservations; // successful reserves
    mapping(uint256 => uint8) public ghostSettlements; // reservationId => number of terminal settlements
    mapping(uint256 => bool) public ghostWasRented; // reservationId => was ever checked out
    mapping(uint256 => uint256) public ghostSnapshotDeposit;
    mapping(uint256 => uint256) public ghostSnapshotFee;
    mapping(uint256 => uint64) public ghostSnapshotExpiry;
    mapping(uint256 => uint64) public ghostSnapshotPolicy;
    mapping(uint256 => uint256) public ghostCredited; // reservationId => credit produced on settlement
    uint256 public ghostCreditedTotal;
    uint256 public ghostFeesAccruedTotal;

    // --- call counters, for sanity reporting ---
    mapping(bytes32 => uint256) public calls;

    uint256 internal refNonce;

    constructor(MockPaymentToken token_, RentalEscrow escrow_, address admin_) {
        token = token_;
        escrow = escrow_;
        admin = admin_;

        for (uint256 i = 0; i < 2; i++) {
            address s = makeAddr(string(abi.encodePacked("staff", i)));
            staffMembers.push(s);
            vm.prank(admin);
            escrow.setStaff(s, true);
        }
        for (uint256 i = 0; i < 4; i++) {
            address r = makeAddr(string(abi.encodePacked("renter", i)));
            renters.push(r);
            vm.prank(admin);
            token.transfer(r, 50_000_000_000); // 50,000 dds each
            vm.prank(r);
            token.approve(address(escrow), type(uint256).max);
        }
        vm.startPrank(admin);
        uint64 p1 = escrow.createPolicy(50_000_000, 5_000_000, 1 hours);
        uint64 p2 = escrow.createPolicy(200_000_000, 200_000_000, 10 minutes);
        uint64 p3 = escrow.createPolicy(1, 0, 1);
        items.push(escrow.addItem(p1, "a"));
        items.push(escrow.addItem(p1, "b"));
        items.push(escrow.addItem(p2, "c"));
        items.push(escrow.addItem(p3, "d"));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    function renterCount() external view returns (uint256) {
        return renters.length;
    }

    function itemCount() external view returns (uint256) {
        return items.length;
    }

    function staffCount() external view returns (uint256) {
        return staffMembers.length;
    }

    function _renter(uint256 seed) internal view returns (address) {
        return renters[seed % renters.length];
    }

    function _staff(uint256 seed) internal view returns (address) {
        return staffMembers[seed % staffMembers.length];
    }

    function _item(uint256 seed) internal view returns (uint256) {
        return items[seed % items.length];
    }

    function _reservation(uint256 seed) internal view returns (uint256) {
        uint256 n = escrow.reservationCount();
        if (n == 0) return 0;
        return (seed % n) + 1;
    }

    function _count(string memory name) internal {
        calls[keccak256(bytes(name))]++;
    }

    // ------------------------------------------------------------------
    // actions
    // ------------------------------------------------------------------

    function reserve(uint256 renterSeed, uint256 itemSeed, bool staleQuote) external {
        _count("reserve");
        address r = _renter(renterSeed);
        uint256 item = _item(itemSeed);
        (uint64 pid, RentalEscrow.Policy memory policy) = escrow.quote(item);
        if (staleQuote) pid = pid + 1;
        bytes32 ref = keccak256(abi.encode("ref", r, ++refNonce));

        uint256 before = token.balanceOf(address(escrow));
        vm.prank(r);
        try escrow.reserve(item, pid, ref) returns (uint256 id) {
            ghostDeposited += policy.deposit;
            ghostReservations++;
            ghostSnapshotDeposit[id] = policy.deposit;
            ghostSnapshotFee[id] = policy.cancellationFee;
            ghostSnapshotExpiry[id] = uint64(block.timestamp) + policy.reservationWindow;
            ghostSnapshotPolicy[id] = pid;
            assertEq(token.balanceOf(address(escrow)), before + policy.deposit, "handler: deposit not exact");
        } catch {
            assertEq(token.balanceOf(address(escrow)), before, "handler: failed reserve moved tokens");
        }
    }

    /// Replays an already used clientRef: must never succeed.
    function reserveDuplicateRef(uint256 reservationSeed) external {
        _count("reserveDuplicateRef");
        uint256 id = _reservation(reservationSeed);
        if (id == 0) return;
        RentalEscrow.Reservation memory r = escrow.getReservation(id);
        (uint64 pid,) = escrow.quote(r.itemId);
        uint256 before = token.balanceOf(address(escrow));
        vm.prank(r.renter);
        try escrow.reserve(r.itemId, pid, r.clientRef) {
            revert("handler: duplicate clientRef accepted");
        } catch {}
        assertEq(token.balanceOf(address(escrow)), before, "handler: duplicate ref moved tokens");
    }

    function cancel(uint256 reservationSeed, bool asRenter) external {
        _count("cancel");
        uint256 id = _reservation(reservationSeed);
        if (id == 0) return;
        RentalEscrow.Reservation memory r = escrow.getReservation(id);
        address caller = asRenter ? r.renter : _renter(reservationSeed + 1);
        vm.prank(caller);
        try escrow.cancel(id) {
            assertEq(caller, r.renter, "handler: non-renter cancelled");
            _recordSettlement(id, r.deposit - r.cancellationFee, r.cancellationFee);
        } catch {}
    }

    function checkOut(uint256 reservationSeed, uint256 staffSeed) external {
        _count("checkOut");
        uint256 id = _reservation(reservationSeed);
        if (id == 0) return;
        address s = _staff(staffSeed);
        vm.prank(s);
        try escrow.checkOut(id) {
            assertTrue(escrow.isStaff(s), "handler: non-staff checked out");
            ghostWasRented[id] = true;
        } catch {}
    }

    function checkOutByStranger(uint256 reservationSeed) external {
        _count("checkOutByStranger");
        uint256 id = _reservation(reservationSeed);
        if (id == 0) return;
        vm.prank(_renter(reservationSeed));
        try escrow.checkOut(id) {
            revert("handler: renter was allowed to check out");
        } catch {}
    }

    function confirmReturn(uint256 reservationSeed, uint256 staffSeed) external {
        _count("confirmReturn");
        uint256 id = _reservation(reservationSeed);
        if (id == 0) return;
        RentalEscrow.Reservation memory r = escrow.getReservation(id);
        address s = _staff(staffSeed);
        vm.prank(s);
        try escrow.confirmReturn(id) {
            assertTrue(escrow.isStaff(s), "handler: non-staff confirmed return");
            _recordSettlement(id, r.deposit, 0);
        } catch {}
    }

    function expire(uint256 reservationSeed, uint256 callerSeed) external {
        _count("expire");
        uint256 id = _reservation(reservationSeed);
        if (id == 0) return;
        RentalEscrow.Reservation memory r = escrow.getReservation(id);
        vm.prank(_renter(callerSeed));
        try escrow.expire(id) {
            assertGe(block.timestamp, r.expiresAt, "handler: expired early");
            assertFalse(ghostWasRented[id], "handler: rented reservation expired");
            _recordSettlement(id, r.deposit - r.cancellationFee, r.cancellationFee);
        } catch {}
    }

    function warp(uint64 delta) external {
        _count("warp");
        delta = uint64(bound(delta, 0, 2 hours));
        vm.warp(block.timestamp + delta);
    }

    function withdrawRefund(uint256 renterSeed) external {
        _count("withdrawRefund");
        address r = _renter(renterSeed);
        uint256 credit = escrow.refundCreditOf(r);
        uint256 before = token.balanceOf(r);
        vm.prank(r);
        try escrow.withdrawRefund() returns (uint256 paid) {
            assertEq(paid, credit, "handler: paid != credit");
            assertGt(paid, 0, "handler: zero payout succeeded");
            ghostRefundsPaid += paid;
            assertEq(token.balanceOf(r), before + paid);
        } catch {
            assertEq(credit, 0, "handler: refund with credit reverted");
        }
    }

    function withdrawFees(uint256 amountSeed) external {
        _count("withdrawFees");
        uint256 fees = escrow.accruedFees();
        uint256 balance = token.balanceOf(address(escrow));
        uint256 amount = bound(amountSeed, 0, balance + 1);
        vm.prank(admin);
        try escrow.withdrawFees(admin, amount) {
            assertTrue(amount > 0 && amount <= fees, "handler: over-withdrew fees");
            ghostFeesPaid += amount;
        } catch {
            assertTrue(amount == 0 || amount > fees, "handler: valid fee withdrawal reverted");
        }
    }

    function createPolicyAndAssign(uint256 deposit, uint256 fee, uint64 window, uint256 itemSeed) external {
        _count("createPolicyAndAssign");
        deposit = bound(deposit, 1, 2_000_000_000);
        fee = bound(fee, 0, deposit);
        window = uint64(bound(window, 1, 3 hours));
        vm.startPrank(admin);
        uint64 pid = escrow.createPolicy(deposit, fee, window);
        escrow.setItemPolicy(_item(itemSeed), pid);
        vm.stopPrank();
    }

    function toggleListing(uint256 itemSeed, bool listed) external {
        _count("toggleListing");
        vm.prank(admin);
        escrow.setItemListed(_item(itemSeed), listed);
    }

    function toggleStaff(uint256 staffSeed, bool enabled) external {
        _count("toggleStaff");
        vm.prank(admin);
        escrow.setStaff(_staff(staffSeed), enabled);
    }

    // ------------------------------------------------------------------
    // internal ghost bookkeeping
    // ------------------------------------------------------------------

    function _recordSettlement(uint256 id, uint256 credit, uint256 fee) internal {
        ghostSettlements[id] += 1;
        ghostCredited[id] = credit;
        ghostCreditedTotal += credit;
        ghostFeesAccruedTotal += fee;
    }
}
