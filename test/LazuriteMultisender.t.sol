// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { LazuriteMultisender } from "../src/LazuriteMultisender.sol";

contract MockMultisendToken is ERC20 {
    constructor() ERC20("Multisend Token", "MSEND") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract NativeSender {
    receive() external payable {}

    function run(address target, address[] calldata recipients, uint256[] calldata amounts)
        external
        payable
    {
        (bool ok,) = target.call{ value: msg.value }(
            abi.encodeWithSignature("disperseNative(address[],uint256[])", recipients, amounts)
        );
        require(ok, "native call failed");
    }
}

contract LazuriteMultisenderTest is Test {
    LazuriteMultisender internal sender;
    MockMultisendToken internal token;

    address payable internal feeReceiver = payable(makeAddr("feeReceiver"));
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint256 internal constant FEE = 0.0005 ether;

    function setUp() public {
        sender = new LazuriteMultisender(feeReceiver, FEE);
        token = new MockMultisendToken();
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
        token.mint(alice, 1_000 ether);
        vm.prank(alice);
        token.approve(address(sender), type(uint256).max);
    }

    function _nativeArrays() internal view returns (address[] memory recipients, uint256[] memory amounts) {
        recipients = new address[](2);
        amounts = new uint256[](2);
        recipients[0] = bob;
        recipients[1] = carol;
        amounts[0] = 1 ether;
        amounts[1] = 2 ether;
    }

    function testNativeDisperseCollectsFeeAndRefundsExcess() public {
        address[] memory recipients;
        uint256[] memory amounts;
        (recipients, amounts) = _nativeArrays();
        NativeSender caller = new NativeSender();
        vm.deal(address(caller), 10 ether);

        uint256 feeBefore = feeReceiver.balance;
        caller.run{ value: 4 ether }(address(sender), recipients, amounts);

        assertEq(bob.balance, 101 ether);
        assertEq(carol.balance, 102 ether);
        assertEq(feeReceiver.balance, feeBefore + FEE);
        assertEq(address(caller).balance, 10 ether + 4 ether - 3 ether - FEE);
        assertEq(address(sender).balance, 0);
    }

    function testNativeRevertsForMismatchEmptyAndLargeBatch() public {
        address[] memory recipients = new address[](2);
        uint256[] memory amounts = new uint256[](1);
        recipients[0] = bob;
        recipients[1] = carol;
        amounts[0] = 1 ether;

        vm.prank(alice);
        vm.expectRevert(LazuriteMultisender.ArrayLengthMismatch.selector);
        sender.disperseNative(recipients, amounts);

        address[] memory empty;
        uint256[] memory emptyAmounts;
        vm.prank(alice);
        vm.expectRevert(LazuriteMultisender.EmptyBatch.selector);
        sender.disperseNative(empty, emptyAmounts);

        address[] memory tooMany = new address[](251);
        uint256[] memory tooManyAmounts = new uint256[](251);
        for (uint256 i; i < 251; ++i) {
            tooMany[i] = address(uint160(i + 1000));
            tooManyAmounts[i] = 0;
        }
        vm.prank(alice);
        vm.expectRevert(LazuriteMultisender.BatchTooLarge.selector);
        sender.disperseNative{ value: FEE }(tooMany, tooManyAmounts);
    }

    function testNativeRevertsForInsufficientFeeAndInvalidRecipient() public {
        address[] memory recipients;
        uint256[] memory amounts;
        (recipients, amounts) = _nativeArrays();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LazuriteMultisender.InsufficientFee.selector, 3 ether + FEE, 3 ether));
        sender.disperseNative{ value: 3 ether }(recipients, amounts);

        recipients[0] = address(0);
        vm.prank(alice);
        vm.expectRevert(LazuriteMultisender.InvalidRecipient.selector);
        sender.disperseNative{ value: 3 ether + FEE }(recipients, amounts);
    }

    function testTokenDisperseCollectsOnceAndRefundsExcess() public {
        address[] memory recipients = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        recipients[0] = bob;
        recipients[1] = carol;
        amounts[0] = 100 ether;
        amounts[1] = 250 ether;

        uint256 feeBefore = feeReceiver.balance;
        vm.prank(alice);
        sender.disperseToken{ value: 2 ether }(address(token), recipients, amounts);

        assertEq(token.balanceOf(bob), 100 ether);
        assertEq(token.balanceOf(carol), 250 ether);
        assertEq(token.balanceOf(alice), 650 ether);
        assertEq(feeReceiver.balance, feeBefore + FEE);
        assertEq(address(sender).balance, 0);
    }

    function testTokenRejectsMissingFeeAndMismatch() public {
        address[] memory recipients = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        recipients[0] = bob;
        amounts[0] = 1 ether;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LazuriteMultisender.InsufficientFee.selector, FEE, 0));
        sender.disperseToken(address(token), recipients, amounts);

        uint256[] memory moreAmounts = new uint256[](2);
        vm.prank(alice);
        vm.expectRevert(LazuriteMultisender.ArrayLengthMismatch.selector);
        sender.disperseToken{ value: FEE }(address(token), recipients, moreAmounts);
    }

    function testTokenRejectsZeroAddress() public {
        address[] memory recipients = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        recipients[0] = bob;
        amounts[0] = 1 ether;

        vm.prank(alice);
        vm.expectRevert(LazuriteMultisender.InvalidToken.selector);
        sender.disperseToken{ value: FEE }(address(0), recipients, amounts);
    }

    function testConstructorBounds() public {
        vm.expectRevert(LazuriteMultisender.InvalidFeeReceiver.selector);
        new LazuriteMultisender(payable(address(0)), FEE);

        vm.expectRevert(LazuriteMultisender.FeeAboveMaximum.selector);
        new LazuriteMultisender(feeReceiver, 1000 ether + 1);
    }
}