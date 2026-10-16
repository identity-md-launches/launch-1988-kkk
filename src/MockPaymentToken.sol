// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockPaymentToken
/// @notice Six-decimal ERC-20 used as the payment token of the local equipment-rental demo.
/// @dev Name "kkk", symbol "dds", fixed supply of 1,000,000 tokens (1_000_000 * 10^6 base units)
///      minted once to `initialHolder`. There is no mint, burn, pause or owner: it is a plain
///      token meant for Anvil and the test-suite, not for a public launch.
contract MockPaymentToken is ERC20 {
    /// @notice Token decimals (USDC-style).
    uint8 public constant DECIMALS = 6;

    /// @notice Total supply in base units: 1,000,000 whole tokens.
    uint256 public constant TOTAL_SUPPLY = 1_000_000 * 10 ** uint256(DECIMALS);

    error ZeroAddress();

    /// @param initialHolder Address that receives the whole fixed supply.
    constructor(address initialHolder) ERC20("kkk", "dds") {
        if (initialHolder == address(0)) revert ZeroAddress();
        _mint(initialHolder, TOTAL_SUPPLY);
    }

    /// @inheritdoc ERC20
    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }
}
