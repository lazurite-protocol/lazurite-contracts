// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { TokenFactory } from "../src/TokenFactory.sol";
import { StandardERC20 } from "../src/StandardERC20.sol";
import { RejectingFeeReceiver } from "./mocks/MockTokens.sol";

contract TokenFactoryTest is Test {
    event TokenCreated(
        uint256 indexed tokenIndex,
        address indexed token,
        address indexed creator,
        string name,
        string symbol,
        uint8 decimals,
        uint256 initialSupply,
        uint256 feePaid
    );

    TokenFactory internal factory;

    address payable internal feeReceiver;
    address internal alice;
    address internal bob;

    uint256 internal constant FLAT_FEE = 0.001 ether;
    uint256 internal constant SUPPLY = 1_000_000 ether;

    function setUp() public {
        vm.warp(1_700_000_000);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        feeReceiver = payable(makeAddr("feeReceiver"));
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);

        factory = new TokenFactory(feeReceiver, FLAT_FEE);
    }

    function _createAs(address user, string memory name, string memory symbol, uint8 decimals)
        internal
        returns (address token)
    {
        vm.prank(user);
        token = factory.createToken{ value: FLAT_FEE }(name, symbol, decimals, SUPPLY);
    }

    function testConstructorStoresImmutableFeeConfiguration() public view {
        assertEq(factory.flatFee(), FLAT_FEE);
        assertEq(factory.feeReceiver(), feeReceiver);
        assertEq(factory.MAX_FEE(), 1000 ether);
        assertEq(factory.getTokensCount(), 0);
    }

    function testCreateTokenDeploysRegistersAndForwardsFee() public {
        uint256 balanceBefore = feeReceiver.balance;

        address token = _createAs(alice, "Zen Launch Token", "ZLT", 18);

        assertEq(factory.getTokensCount(), 1);
        assertEq(feeReceiver.balance - balanceBefore, FLAT_FEE);
        assertEq(address(factory).balance, 0);

        StandardERC20 created = StandardERC20(token);
        assertEq(created.name(), "Zen Launch Token");
        assertEq(created.symbol(), "ZLT");
        assertEq(created.decimals(), 18);
        assertEq(created.totalSupply(), SUPPLY);
        assertEq(created.balanceOf(alice), SUPPLY);

        TokenFactory.TokenInfo[] memory page = factory.getTokensPaginated(0, 10);
        assertEq(page.length, 1);
        assertEq(page[0].token, token);
        assertEq(page[0].creator, alice);
        assertEq(page[0].name, "Zen Launch Token");
        assertEq(page[0].symbol, "ZLT");
        assertEq(page[0].decimals, 18);
        assertEq(page[0].initialSupply, SUPPLY);
        assertEq(page[0].createdAt, block.timestamp);
    }

    function testCreateTokenEmitsIndexedTokenCreatedEvent() public {
        vm.recordLogs();
        address token = _createAs(alice, "Event Token", "EVT", 6);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(factory)
                    && logs[i].topics[0]
                        == keccak256(
                            "TokenCreated(uint256,address,address,string,string,uint8,uint256,uint256)"
                        )
            ) {
                found = true;
                assertEq(logs[i].topics.length, 4);
                assertEq(uint256(logs[i].topics[1]), 0);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), token);
                assertEq(address(uint160(uint256(logs[i].topics[3]))), alice);
            }
        }
        assertTrue(found, "TokenCreated event missing");
    }

    function testCreateTokenSupportsCustomDecimals() public {
        address token = _createAs(bob, "Six Decimals", "SIX", 6);
        assertEq(StandardERC20(token).decimals(), 6);
        assertEq(StandardERC20(token).balanceOf(bob), SUPPLY);
    }

    function testRevertsWhenFeeIsTooLow() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TokenFactory.IncorrectFee.selector, FLAT_FEE, FLAT_FEE - 1));
        factory.createToken{ value: FLAT_FEE - 1 }("Name", "SYM", 18, SUPPLY);
    }

    function testRevertsWhenFeeIsTooHigh() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TokenFactory.IncorrectFee.selector, FLAT_FEE, FLAT_FEE + 1));
        factory.createToken{ value: FLAT_FEE + 1 }("Name", "SYM", 18, SUPPLY);
    }

    function testRevertsWithoutFee() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TokenFactory.IncorrectFee.selector, FLAT_FEE, 0));
        factory.createToken("Name", "SYM", 18, SUPPLY);
    }

    function testDelegateValidationIsEnforcedByToken() public {
        vm.prank(alice);
        vm.expectRevert(StandardERC20.ZeroInitialSupply.selector);
        factory.createToken{ value: FLAT_FEE }("Name", "SYM", 18, 0);
    }

    function testFeeReceiverCannotRejectAndLeaveRegistryDirty() public {
        RejectingFeeReceiver rejector = new RejectingFeeReceiver();
        TokenFactory rejectingFactory = new TokenFactory(payable(address(rejector)), FLAT_FEE);

        vm.prank(alice);
        vm.expectRevert(TokenFactory.FeeTransferFailed.selector);
        rejectingFactory.createToken{ value: FLAT_FEE }("Name", "SYM", 18, SUPPLY);

        assertEq(rejectingFactory.getTokensCount(), 0);
        assertEq(address(rejectingFactory).balance, 0);
    }

    function testDeploymentRevertsForAboveCapFee() public {
        uint256 max = 1000 ether;
        vm.expectRevert(TokenFactory.FeeAboveMaximum.selector);
        new TokenFactory(feeReceiver, max + 1);
    }

    function testDeploymentAcceptsExactCapAndZeroFee() public {
        TokenFactory maxFactory = new TokenFactory(feeReceiver, 1000 ether);
        assertEq(maxFactory.flatFee(), 1000 ether);

        TokenFactory freeFactory = new TokenFactory(feeReceiver, 0);
        vm.prank(alice);
        address token = freeFactory.createToken("Free", "FREE", 18, 1e18);
        assertEq(StandardERC20(token).balanceOf(alice), 1e18);
        assertEq(feeReceiver.balance, 0);
    }

    function testDeploymentRevertsForZeroFeeReceiver() public {
        vm.expectRevert(TokenFactory.InvalidFeeReceiver.selector);
        new TokenFactory(payable(address(0)), FLAT_FEE);
    }

    function testOnlyNativeFeeIsTransferredAndContractKeepsNothing() public {
        _createAs(alice, "A", "A", 18);
        _createAs(bob, "B", "B", 18);

        assertEq(address(factory).balance, 0);
        assertEq(feeReceiver.balance, FLAT_FEE * 2);
    }

    function testPaginationAndCreatorIndex() public {
        _createAs(alice, "One", "ONE", 18);
        _createAs(bob, "Two", "TWO", 18);
        _createAs(alice, "Three", "THREE", 18);

        TokenFactory.TokenInfo[] memory page = factory.getTokensPaginated(0, 2);
        assertEq(page.length, 2);
        assertEq(page[0].symbol, "ONE");
        assertEq(page[1].symbol, "TWO");

        page = factory.getTokensPaginated(2, 2);
        assertEq(page.length, 1);
        assertEq(page[0].symbol, "THREE");

        page = factory.getTokensPaginated(3, 2);
        assertEq(page.length, 0);

        page = factory.getTokensPaginated(0, 0);
        assertEq(page.length, 0);

        page = factory.getTokensPaginated(0, 100);
        assertEq(page.length, 3);

        TokenFactory.TokenInfo[] memory aliceTokens = factory.getTokensByCreator(alice);
        assertEq(aliceTokens.length, 2);
        assertEq(aliceTokens[0].symbol, "ONE");
        assertEq(aliceTokens[1].symbol, "THREE");

        TokenFactory.TokenInfo[] memory alicePage = factory.getTokensByCreatorPaginated(alice, 1, 1);
        assertEq(alicePage.length, 1);
        assertEq(alicePage[0].symbol, "THREE");

        assertEq(factory.getTokensByCreatorPaginated(alice, 2, 1).length, 0);
        assertEq(factory.getTokensByCreatorPaginated(bob, 0, 0).length, 0);
    }
}
