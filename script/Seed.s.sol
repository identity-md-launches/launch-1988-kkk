// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {MockPaymentToken} from "../src/MockPaymentToken.sol";
import {RentalEscrow} from "../src/RentalEscrow.sol";

/// @title Seed
/// @notice Seeds a freshly deployed local escrow with a staff member, two policies, three items and
///         funds a demo renter. Must be broadcast from the escrow admin (who also holds the token supply
///         in the default local deployment).
contract Seed is Script {
    struct Config {
        RentalEscrow escrow;
        MockPaymentToken token;
        address staff; // granted staff permission
        address renter; // receives `renterFunding` tokens for the demo
        uint256 renterFunding; // in token base units (6 decimals)
    }

    struct Result {
        uint64 standardPolicy;
        uint64 premiumPolicy;
        uint256[3] itemIds;
    }

    address internal constant ANVIL_ACCOUNT_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address internal constant ANVIL_ACCOUNT_2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;

    /// @notice Seed logic. The caller (broadcaster or test prank) must be the escrow admin and must
    ///         hold at least `cfg.renterFunding` tokens.
    function seed(Config memory cfg) public returns (Result memory r) {
        cfg.escrow.setStaff(cfg.staff, true);

        // 50 dds deposit, 5 dds cancellation fee, 1 hour to check out.
        r.standardPolicy = cfg.escrow.createPolicy(50_000_000, 5_000_000, 1 hours);
        // 200 dds deposit, 20 dds cancellation fee, 30 minutes to check out.
        r.premiumPolicy = cfg.escrow.createPolicy(200_000_000, 20_000_000, 30 minutes);

        r.itemIds[0] = cfg.escrow.addItem(r.standardPolicy, "ipfs://demo/cordless-drill");
        r.itemIds[1] = cfg.escrow.addItem(r.standardPolicy, "ipfs://demo/pressure-washer");
        r.itemIds[2] = cfg.escrow.addItem(r.premiumPolicy, "ipfs://demo/mini-excavator");

        if (cfg.renterFunding > 0) {
            cfg.token.transfer(cfg.renter, cfg.renterFunding);
        }
    }

    /// @notice Environment-driven entry point.
    ///   ESCROW          RentalEscrow address (required)
    ///   TOKEN           MockPaymentToken address (required)
    ///   STAFF           staff address          (default: Anvil account 1)
    ///   RENTER          demo renter address    (default: Anvil account 2)
    ///   RENTER_FUNDING  base units to transfer (default: 1,000 dds)
    function run() external returns (Result memory r) {
        Config memory cfg;
        cfg.escrow = RentalEscrow(vm.envAddress("ESCROW"));
        cfg.token = MockPaymentToken(vm.envAddress("TOKEN"));
        cfg.staff = vm.envOr("STAFF", ANVIL_ACCOUNT_1);
        cfg.renter = vm.envOr("RENTER", ANVIL_ACCOUNT_2);
        cfg.renterFunding = vm.envOr("RENTER_FUNDING", uint256(1_000_000_000));

        vm.startBroadcast();
        r = seed(cfg);
        vm.stopBroadcast();

        console.log("standard policy id:", r.standardPolicy);
        console.log("premium policy id: ", r.premiumPolicy);
        console.log("item ids:", r.itemIds[0], r.itemIds[1], r.itemIds[2]);
        console.log("staff:", cfg.staff);
        console.log("renter funded:", cfg.renter, cfg.renterFunding);
    }
}
