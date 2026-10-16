// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockPaymentToken} from "../../src/MockPaymentToken.sol";
import {RentalEscrow} from "../../src/RentalEscrow.sol";

/// @dev Shared fixture: token + escrow + one policy + one item, funded renters with approvals.
abstract contract EscrowTestBase is Test {
    MockPaymentToken internal token;
    RentalEscrow internal escrow;

    address internal admin = makeAddr("admin");
    address internal staff = makeAddr("staff");
    address internal renter = makeAddr("renter");
    address internal renter2 = makeAddr("renter2");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant DEPOSIT = 50_000_000; // 50 dds
    uint256 internal constant FEE = 5_000_000; // 5 dds
    uint64 internal constant WINDOW = 1 hours;
    uint256 internal constant FUNDING = 10_000_000_000; // 10,000 dds per renter

    uint64 internal policyId;
    uint256 internal itemId;

    bytes32 internal constant REF_A = keccak256("ref-a");
    bytes32 internal constant REF_B = keccak256("ref-b");

    function setUp() public virtual {
        token = new MockPaymentToken(admin);
        escrow = new RentalEscrow(address(token), admin);

        vm.startPrank(admin);
        escrow.setStaff(staff, true);
        policyId = escrow.createPolicy(DEPOSIT, FEE, WINDOW);
        itemId = escrow.addItem(policyId, "ipfs://item-1");
        token.transfer(renter, FUNDING);
        token.transfer(renter2, FUNDING);
        vm.stopPrank();

        vm.prank(renter);
        token.approve(address(escrow), type(uint256).max);
        vm.prank(renter2);
        token.approve(address(escrow), type(uint256).max);

        // Start from a non-zero, non-round timestamp so boundary tests are meaningful.
        vm.warp(1_700_000_123);
    }

    function _reserve(address who, uint256 item, bytes32 ref) internal returns (uint256 id) {
        (uint64 pid,) = escrow.quote(item);
        vm.prank(who);
        id = escrow.reserve(item, pid, ref);
    }

    function _assertConservation() internal view {
        assertGe(token.balanceOf(address(escrow)), escrow.totalLiabilities(), "liabilities exceed balance");
    }
}
