// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {Seed} from "../script/Seed.s.sol";
import {RentalEscrow} from "../src/RentalEscrow.sol";

/// @dev Exercises the script logic directly (no environment, no broadcast) so the same code that
///      runs against Anvil is covered by the suite.
contract ScriptsTest is Test {
    address internal admin = makeAddr("admin");
    address internal staffAddr = makeAddr("staff");
    address internal renterAddr = makeAddr("renter");

    function test_deploy_wiresTokenAndEscrow() public {
        Deploy d = new Deploy();
        Deploy.Deployment memory out = d.deploy(Deploy.Config({admin: admin, tokenHolder: admin}));

        assertEq(address(out.escrow.token()), address(out.token));
        assertEq(out.escrow.admin(), admin);
        assertEq(out.token.balanceOf(admin), out.token.TOTAL_SUPPLY());
        assertEq(out.token.decimals(), 6);
    }

    function test_deploy_rejectsZeroConfig() public {
        Deploy d = new Deploy();
        vm.expectRevert(bytes("Deploy: admin is zero"));
        d.deploy(Deploy.Config({admin: address(0), tokenHolder: admin}));
        vm.expectRevert(bytes("Deploy: tokenHolder is zero"));
        d.deploy(Deploy.Config({admin: admin, tokenHolder: address(0)}));
    }

    function test_seed_createsDemoStateAndFundsRenter() public {
        // In a broadcast the script's calls come from the broadcaster; here the Seed contract itself
        // plays the admin/token-holder role so its calls into the escrow carry the right sender.
        Seed s = new Seed();
        Deploy d = new Deploy();
        Deploy.Deployment memory out = d.deploy(Deploy.Config({admin: address(s), tokenHolder: address(s)}));

        Seed.Config memory cfg = Seed.Config({
            escrow: out.escrow, token: out.token, staff: staffAddr, renter: renterAddr, renterFunding: 1_000_000_000
        });

        // Run from any other sender the escrow rejects the seed outright.
        Seed notAdmin = new Seed();
        vm.expectRevert(RentalEscrow.NotAdmin.selector);
        notAdmin.seed(cfg);

        Seed.Result memory r = s.seed(cfg);

        assertEq(r.standardPolicy, 1);
        assertEq(r.premiumPolicy, 2);
        assertEq(r.itemIds[0], 1);
        assertEq(r.itemIds[1], 2);
        assertEq(r.itemIds[2], 3);
        assertTrue(out.escrow.isStaff(staffAddr));
        assertEq(out.escrow.getItem(3).policyId, 2);
        assertEq(out.escrow.getPolicy(2).deposit, 200_000_000);
        assertEq(out.token.balanceOf(renterAddr), 1_000_000_000);

        // The seeded state supports the full flow.
        vm.prank(renterAddr);
        out.token.approve(address(out.escrow), 50_000_000);
        vm.prank(renterAddr);
        uint256 id = out.escrow.reserve(1, 1, keccak256("demo"));
        vm.prank(staffAddr);
        out.escrow.checkOut(id);
        vm.prank(staffAddr);
        out.escrow.confirmReturn(id);
        vm.prank(renterAddr);
        assertEq(out.escrow.withdrawRefund(), 50_000_000);
    }
}
