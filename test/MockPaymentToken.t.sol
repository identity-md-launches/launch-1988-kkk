// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockPaymentToken} from "../src/MockPaymentToken.sol";

contract MockPaymentTokenTest is Test {
    address internal holder = makeAddr("holder");
    MockPaymentToken internal token;

    function setUp() public {
        token = new MockPaymentToken(holder);
    }

    function test_metadata() public view {
        assertEq(token.name(), "kkk");
        assertEq(token.symbol(), "dds");
        assertEq(token.decimals(), 6);
    }

    function test_fixedSupplyMintedToHolder() public view {
        assertEq(token.totalSupply(), 1_000_000 * 1e6);
        assertEq(token.totalSupply(), 1_000_000_000_000);
        assertEq(token.balanceOf(holder), token.totalSupply());
    }

    function test_rejectsZeroHolder() public {
        vm.expectRevert(MockPaymentToken.ZeroAddress.selector);
        new MockPaymentToken(address(0));
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != holder);
        amount = bound(amount, 0, token.totalSupply());
        vm.prank(holder);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(holder) + token.balanceOf(to), token.totalSupply());
    }
}
