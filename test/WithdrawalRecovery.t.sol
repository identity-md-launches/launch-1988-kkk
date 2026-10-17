// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EscrowTestBase} from "./utils/EscrowTestBase.sol";
import {RentalEscrow} from "../src/RentalEscrow.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

contract WithdrawalRecoveryTest is EscrowTestBase {
    bytes32 internal constant REQUEST_A = keccak256("fee-request-a");
    bytes32 internal constant REQUEST_B = keccak256("fee-request-b");
    address internal treasury = makeAddr("treasury");

    function _earnFee(bytes32 ref) internal {
        uint256 id = _reserve(renter, itemId, ref);
        vm.prank(renter);
        escrow.cancel(id);
    }

    function _assertResult(bytes32 requestId, address recipient, uint256 amount, bool completed) internal view {
        (address storedRecipient, uint256 storedAmount, bool storedCompleted) = escrow.feeWithdrawalById(requestId);
        assertEq(storedRecipient, recipient);
        assertEq(storedAmount, amount);
        assertEq(storedCompleted, completed);
    }

    function _expectCompleted(bytes32 requestId, address recipient, uint256 amount) internal {
        vm.expectRevert(
            abi.encodeWithSelector(RentalEscrow.FeeWithdrawalAlreadyCompleted.selector, requestId, recipient, amount)
        );
    }

    function test_feeLookup_unusedRequest() public view {
        _assertResult(REQUEST_A, address(0), 0, false);
    }

    function test_feeWithdrawal_requiresNonzeroId() public {
        _earnFee(REF_A);
        vm.prank(admin);
        vm.expectRevert(RentalEscrow.FeeWithdrawalIdRequired.selector);
        escrow.withdrawFees(bytes32(0), treasury, FEE);
        _assertResult(bytes32(0), address(0), 0, false);
        assertEq(escrow.accruedFees(), FEE);
        assertEq(token.balanceOf(treasury), 0);
    }

    function test_feeRetry_tenEarnedFiveRequestedPaysOnce_newIdPaysRemainder() public {
        _earnFee(REF_A);
        _earnFee(REF_B);
        assertEq(escrow.accruedFees(), 10_000_000);
        vm.prank(admin);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit RentalEscrow.FeesWithdrawn(REQUEST_A, treasury, 5_000_000);
        escrow.withdrawFees(REQUEST_A, treasury, 5_000_000);
        _assertResult(REQUEST_A, treasury, FEE, true);

        // Separate calls need protection even while enough fees remain to pay again.
        vm.roll(block.number + 1);
        vm.recordLogs();
        vm.prank(admin);
        _expectCompleted(REQUEST_A, treasury, FEE);
        escrow.withdrawFees(REQUEST_A, treasury, FEE);
        assertEq(vm.getRecordedLogs().length, 0, "replay must not emit a second payment event");
        assertEq(token.balanceOf(treasury), FEE);
        assertEq(escrow.accruedFees(), FEE);
        assertEq(escrow.totalRefundCredits(), 2 * (DEPOSIT - FEE));
        assertEq(token.balanceOf(address(escrow)), 2 * DEPOSIT - FEE);

        vm.prank(admin);
        escrow.withdrawFees(REQUEST_B, treasury, FEE);
        _assertResult(REQUEST_B, treasury, FEE, true);
        _assertResult(REQUEST_A, treasury, FEE, true);
        assertEq(token.balanceOf(treasury), 2 * FEE);
        assertEq(escrow.accruedFees(), 0);

        // The replay response is durable even after all fees have been withdrawn.
        vm.prank(admin);
        _expectCompleted(REQUEST_A, treasury, FEE);
        escrow.withdrawFees(REQUEST_A, treasury, FEE);
        _assertConservation();
    }

    function test_feeRetry_conflictingRecipientRejected() public {
        _earnFee(REF_A);
        _earnFee(REF_B);
        vm.prank(admin);
        escrow.withdrawFees(REQUEST_A, treasury, FEE);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(RentalEscrow.FeeWithdrawalConflict.selector, REQUEST_A, treasury, FEE));
        escrow.withdrawFees(REQUEST_A, stranger, FEE);
        _assertResult(REQUEST_A, treasury, FEE, true);
        assertEq(token.balanceOf(stranger), 0);
        assertEq(token.balanceOf(treasury), FEE);
        assertEq(escrow.accruedFees(), FEE);
    }

    function test_feeRetry_conflictingAmountRejected() public {
        _earnFee(REF_A);
        _earnFee(REF_B);
        vm.prank(admin);
        escrow.withdrawFees(REQUEST_A, treasury, FEE);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(RentalEscrow.FeeWithdrawalConflict.selector, REQUEST_A, treasury, FEE));
        escrow.withdrawFees(REQUEST_A, treasury, FEE - 1);
        _assertResult(REQUEST_A, treasury, FEE, true);
        assertEq(token.balanceOf(treasury), FEE);
        assertEq(escrow.accruedFees(), FEE);
    }

    function test_feeRetry_oldIdProtectedAfterNewFeesAccrue() public {
        _earnFee(REF_A);
        vm.prank(admin);
        escrow.withdrawFees(REQUEST_A, treasury, FEE);
        _earnFee(REF_B);
        vm.prank(admin);
        _expectCompleted(REQUEST_A, treasury, FEE);
        escrow.withdrawFees(REQUEST_A, treasury, FEE);
        assertEq(escrow.accruedFees(), FEE);
        assertEq(token.balanceOf(treasury), FEE);
        _assertResult(REQUEST_A, treasury, FEE, true);
    }

    function test_feeWithdrawal_falseTransferRollsBackAndSameIdCanRetry() public {
        _failedTransferCanRetry(false);
    }

    function test_feeWithdrawal_revertedTransferRollsBackAndSameIdCanRetry() public {
        _failedTransferCanRetry(true);
    }

    function _failedTransferCanRetry(bool revertTransfer) internal {
        _earnFee(REF_A);
        // Leave another live deposit as well as the first renter's refund credit protected.
        _reserve(renter2, itemId, REF_A);
        bytes memory callData = abi.encodeCall(IERC20.transfer, (treasury, FEE));
        bytes memory failure = abi.encodeWithSignature("TokenTransferBlocked()");
        if (revertTransfer) {
            vm.mockCallRevert(address(token), callData, failure);
        } else {
            vm.mockCall(address(token), callData, abi.encode(false));
            failure = abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token));
        }
        vm.prank(admin);
        vm.expectRevert(failure);
        escrow.withdrawFees(REQUEST_A, treasury, FEE);
        _assertResult(REQUEST_A, address(0), 0, false);
        assertEq(escrow.accruedFees(), FEE);
        assertEq(escrow.totalEscrowed(), DEPOSIT);
        assertEq(escrow.totalRefundCredits(), DEPOSIT - FEE);
        assertEq(escrow.refundCreditOf(renter), DEPOSIT - FEE);
        assertEq(token.balanceOf(address(escrow)), 2 * DEPOSIT);
        assertEq(token.balanceOf(treasury), 0);

        vm.clearMockedCalls();
        vm.prank(admin);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit RentalEscrow.FeesWithdrawn(REQUEST_A, treasury, FEE);
        escrow.withdrawFees(REQUEST_A, treasury, FEE);
        _assertResult(REQUEST_A, treasury, FEE, true);
        assertEq(escrow.accruedFees(), 0);
        assertEq(token.balanceOf(treasury), FEE);
        vm.prank(renter);
        assertEq(escrow.withdrawRefund(), DEPOSIT - FEE);
        assertEq(token.balanceOf(address(escrow)), DEPOSIT);
        _assertConservation();
    }

    function test_feeWithdrawal_insufficientFeesDoesNotConsumeId() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(RentalEscrow.InsufficientFees.selector, FEE, 0));
        escrow.withdrawFees(REQUEST_A, treasury, FEE);
        _assertResult(REQUEST_A, address(0), 0, false);
        _earnFee(REF_A);
        vm.prank(admin);
        escrow.withdrawFees(REQUEST_A, treasury, FEE);
        _assertResult(REQUEST_A, treasury, FEE, true);
        assertEq(token.balanceOf(treasury), FEE);
    }

    function test_feeRetry_survivesAdminHandover() public {
        _earnFee(REF_A);
        _earnFee(REF_B);
        vm.prank(admin);
        escrow.withdrawFees(REQUEST_A, treasury, FEE);
        vm.prank(admin);
        escrow.transferAdmin(stranger);
        vm.prank(stranger);
        vm.expectRevert(RentalEscrow.NotAdmin.selector);
        escrow.withdrawFees(REQUEST_B, treasury, FEE);
        vm.prank(stranger);
        escrow.acceptAdmin();

        vm.prank(admin);
        vm.expectRevert(RentalEscrow.NotAdmin.selector);
        escrow.withdrawFees(REQUEST_A, treasury, FEE);
        vm.prank(admin);
        vm.expectRevert(RentalEscrow.NotAdmin.selector);
        escrow.withdrawFees(REQUEST_B, treasury, FEE);
        vm.prank(stranger);
        _expectCompleted(REQUEST_A, treasury, FEE);
        escrow.withdrawFees(REQUEST_A, treasury, FEE);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(RentalEscrow.FeeWithdrawalConflict.selector, REQUEST_A, treasury, FEE));
        escrow.withdrawFees(REQUEST_A, stranger, FEE);
        assertEq(token.balanceOf(treasury), FEE);
        assertEq(escrow.accruedFees(), FEE);
        _assertResult(REQUEST_A, treasury, FEE, true);

        vm.prank(stranger);
        escrow.withdrawFees(REQUEST_B, treasury, FEE);
        assertEq(token.balanceOf(treasury), 2 * FEE);
        _assertResult(REQUEST_A, treasury, FEE, true);
        _assertResult(REQUEST_B, treasury, FEE, true);
        _assertConservation();
    }

    function test_feeWithdrawal_legacySelectorCannotBypassRequestId() public {
        _earnFee(REF_A);
        vm.prank(admin);
        (bool success,) = address(escrow).call(abi.encodeWithSignature("withdrawFees(address,uint256)", treasury, FEE));
        assertFalse(success);
        assertEq(token.balanceOf(treasury), 0);
        assertEq(escrow.accruedFees(), FEE);
    }

    function test_refundRecovery_interveningSettlementPaysOnlyNewAggregateCredit() public {
        vm.recordLogs();
        _earnFee(REF_A); // first credit: 45 dds
        vm.prank(renter);
        assertEq(escrow.withdrawRefund(), DEPOSIT - FEE); // receipt may be unknown to the app
        assertEq(escrow.refundCreditOf(renter), 0);
        assertEq(token.balanceOf(renter), FUNDING - FEE);

        // A different reservation creates credit before the application submits another transaction.
        uint256 second = _reserve(renter, itemId, REF_B);
        vm.prank(staff);
        escrow.checkOut(second);
        vm.prank(staff);
        escrow.confirmReturn(second); // new credit: 50 dds, not evidence of a failed earlier payout
        assertEq(escrow.refundCreditOf(renter), DEPOSIT);
        vm.prank(renter);
        assertEq(escrow.withdrawRefund(), DEPOSIT);
        assertEq(token.balanceOf(renter), FUNDING - FEE);
        assertEq(escrow.refundCreditOf(renter), 0);
        assertEq(escrow.totalRefundCredits(), 0);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 paid;
        uint256 credited;
        uint256 withdrawals;
        uint256 credits;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(escrow)) continue;
            if (logs[i].topics[0] == keccak256("RefundCredited(address,uint256,uint256)")) {
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(renter))));
                assertEq(uint256(logs[i].topics[2]), ++credits);
                credited += abi.decode(logs[i].data, (uint256));
            } else if (logs[i].topics[0] == keccak256("RefundWithdrawn(address,uint256)")) {
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(renter))));
                uint256 amount = abi.decode(logs[i].data, (uint256));
                assertEq(amount, withdrawals++ == 0 ? DEPOSIT - FEE : DEPOSIT);
                paid += amount;
            }
        }
        assertEq(credits, 2);
        assertEq(withdrawals, 2);
        assertEq(paid, credited, "each credit paid exactly once across both calls");
        vm.prank(renter);
        vm.expectRevert(RentalEscrow.NothingToWithdraw.selector);
        escrow.withdrawRefund();
        _assertConservation();
    }

    function testFuzz_feeRetry_arbitraryIdAmountAndConflictingPayload(
        bytes32 requestId,
        uint256 amount,
        uint256 changedAmount,
        address changedRecipient
    ) public {
        vm.assume(requestId != bytes32(0));
        vm.assume(changedRecipient != treasury);
        _earnFee(REF_A);
        _earnFee(REF_B);
        amount = bound(amount, 1, FEE); // enough remains to pay twice if replay protection breaks
        vm.assume(changedAmount != amount);
        vm.prank(admin);
        escrow.withdrawFees(requestId, treasury, amount);
        vm.prank(admin);
        _expectCompleted(requestId, treasury, amount);
        escrow.withdrawFees(requestId, treasury, amount);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(RentalEscrow.FeeWithdrawalConflict.selector, requestId, treasury, amount)
        );
        escrow.withdrawFees(requestId, changedRecipient, amount);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(RentalEscrow.FeeWithdrawalConflict.selector, requestId, treasury, amount)
        );
        escrow.withdrawFees(requestId, treasury, changedAmount);
        _assertResult(requestId, treasury, amount, true);
        assertEq(token.balanceOf(treasury), amount);
        assertEq(escrow.accruedFees(), 2 * FEE - amount);
        _assertConservation();
    }
}
