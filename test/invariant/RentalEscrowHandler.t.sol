// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockPaymentToken} from "../../src/MockPaymentToken.sol";
import {RentalEscrow} from "../../src/RentalEscrow.sol";
import {RentalEscrowHandler} from "./RentalEscrowHandler.sol";

contract RentalEscrowHandlerTest is Test {
    /// Reproduces the verifier seed's original two-action failure in the harness, before escrow is called.
    function test_cancel_maximumSeedDoesNotOverflowHandler() public {
        address admin = makeAddr("admin");
        MockPaymentToken token = new MockPaymentToken(admin);
        RentalEscrow escrow = new RentalEscrow(address(token), admin);
        RentalEscrowHandler handler = new RentalEscrowHandler(token, escrow, admin);
        vm.warp(1_700_000_123);
        handler.reserve(1_700_000_123, 1_700_000_123, false);
        assertEq(escrow.reservationCount(), 1);
        handler.cancel(type(uint256).max, false);
        // This seed selects a different renter: the escrow must reject cancellation without a credit.
        assertEq(uint8(escrow.getReservation(1).status), uint8(RentalEscrow.ReservationStatus.Reserved));
        assertEq(handler.ghostSettlements(1), 0);
        assertEq(escrow.totalRefundCredits(), 0);
    }
}
