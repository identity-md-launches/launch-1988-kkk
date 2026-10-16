// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {MockPaymentToken} from "../src/MockPaymentToken.sol";
import {RentalEscrow} from "../src/RentalEscrow.sol";

/// @title Deploy
/// @notice Deploys the mock payment token and the rental escrow for a local Anvil chain.
/// @dev `run()` reads its configuration from the environment and hands it to `deploy`, which the
///      tests call directly with explicit values. Nothing here depends on who broadcasts.
contract Deploy is Script {
    struct Config {
        address admin; // RentalEscrow administrator
        address tokenHolder; // receives the whole fixed token supply
    }

    struct Deployment {
        MockPaymentToken token;
        RentalEscrow escrow;
    }

    /// @dev Anvil's default first account. Used only as the local-demo fallback for `run()`.
    address internal constant ANVIL_ACCOUNT_0 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    /// @notice Pure deployment logic. Call inside a broadcast (scripts) or directly (tests).
    function deploy(Config memory cfg) public returns (Deployment memory d) {
        require(cfg.admin != address(0), "Deploy: admin is zero");
        require(cfg.tokenHolder != address(0), "Deploy: tokenHolder is zero");
        d.token = new MockPaymentToken(cfg.tokenHolder);
        d.escrow = new RentalEscrow(address(d.token), cfg.admin);
    }

    /// @notice Environment-driven entry point.
    ///   ESCROW_ADMIN   administrator address   (default: Anvil account 0)
    ///   TOKEN_HOLDER   initial token holder    (default: ESCROW_ADMIN)
    function run() external returns (Deployment memory d) {
        Config memory cfg;
        cfg.admin = vm.envOr("ESCROW_ADMIN", ANVIL_ACCOUNT_0);
        cfg.tokenHolder = vm.envOr("TOKEN_HOLDER", cfg.admin);

        vm.startBroadcast();
        d = deploy(cfg);
        vm.stopBroadcast();

        console.log("MockPaymentToken:", address(d.token));
        console.log("RentalEscrow:    ", address(d.escrow));
        console.log("admin:           ", cfg.admin);
        console.log("token holder:    ", cfg.tokenHolder);
    }
}
