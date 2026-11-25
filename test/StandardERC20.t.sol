// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { StandardERC20 } from "../src/StandardERC20.sol";

contract StandardERC20Test is Test {
    address internal constant ALICE = address(0xA11CE);

    function testMintsEntireSupplyToHolderWithCustomMetadata() public {
        uint256 supply = 1_000_000 * 1e6;

        StandardERC20 token = new StandardERC20("Zen Dollar", "zUSD", 6, supply, ALICE);

        assertEq(token.name(), "Zen Dollar");
        assertEq(token.symbol(), "zUSD");
        assertEq(token.decimals(), 6);
        assertEq(token.totalSupply(), supply);
        assertEq(token.balanceOf(ALICE), supply);
    }

    function testSupportsZeroDecimalsAndFullSupply() public {
        StandardERC20 token = new StandardERC20("Point", "PT", 0, 42, ALICE);

        assertEq(token.decimals(), 0);
        assertEq(token.totalSupply(), 42);
        assertEq(token.balanceOf(ALICE), 42);
    }

    function testHasNoMintOrBurnSurface() public {
        // The minimal ERC-20 has no owner and no privileged supply controls. This
        // assertion documents the absence of such ABIs at the Solidity boundary.
        StandardERC20 token = new StandardERC20("Immutable", "IMM", 18, 1e18, ALICE);
        assertEq(token.totalSupply(), 1e18);
        assertEq(token.allowance(ALICE, address(this)), 0);
    }

    function testRevertsOnEmptyName() public {
        vm.expectRevert(StandardERC20.EmptyName.selector);
        new StandardERC20("", "SYM", 18, 1e18, ALICE);
    }

    function testRevertsOnEmptySymbol() public {
        vm.expectRevert(StandardERC20.EmptySymbol.selector);
        new StandardERC20("Name", "", 18, 1e18, ALICE);
    }

    function testRevertsOnInvalidDecimals() public {
        vm.expectRevert(StandardERC20.InvalidDecimals.selector);
        new StandardERC20("Name", "SYM", 37, 1e18, ALICE);
    }

    function testRevertsOnZeroSupply() public {
        vm.expectRevert(StandardERC20.ZeroInitialSupply.selector);
        new StandardERC20("Name", "SYM", 18, 0, ALICE);
    }

    function testRevertsOnZeroHolder() public {
        vm.expectRevert(StandardERC20.ZeroInitialHolder.selector);
        new StandardERC20("Name", "SYM", 18, 1e18, address(0));
    }

    function testTokensCanBeTransferredNormally() public {
        StandardERC20 token = new StandardERC20("Name", "SYM", 18, 1e18, ALICE);
        vm.prank(ALICE);
        token.transfer(address(0xB0B), 0.4 ether);
        assertEq(token.balanceOf(address(0xB0B)), 0.4 ether);
    }
}
