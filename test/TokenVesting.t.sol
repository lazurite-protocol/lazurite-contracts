// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { TokenVesting } from "../src/TokenVesting.sol";
import { MockERC20, FeeOnTransferERC20 } from "./mocks/MockTokens.sol";

contract TokenVestingTest is Test {
    event VestingCreated(
        uint256 indexed scheduleId,
        address indexed beneficiary,
        address indexed token,
        uint256 amount,
        uint64 start,
        uint64 cliff,
        uint64 duration
    );
    event TokensReleased(
        uint256 indexed scheduleId, address indexed beneficiary, address indexed token, uint256 amount
    );

    TokenVesting internal vesting;
    MockERC20 internal token;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address payable internal feeReceiver = payable(makeAddr("feeReceiver"));

    uint256 internal constant TOTAL = 10_000 ether;
    uint256 internal constant FEE = 50 ether;
    uint64 internal start;
    uint64 internal cliff = 1_000;
    uint64 internal duration = 10_000;

    function setUp() public {
        vm.warp(1_700_000_000);
        vesting = new TokenVesting(feeReceiver, FEE);
        vm.deal(address(this), 1_000_000 ether);
        token = new MockERC20("Vesting Token", "VST", 18);
        token.mint(address(this), 10_000_000 ether);
        token.approve(address(vesting), type(uint256).max);
        start = uint64(block.timestamp + 100);
    }

    function _create(address beneficiary, uint256 amount) internal returns (uint256 id) {
        id = vesting.createVesting{ value: FEE }(beneficiary, address(token), amount, start, cliff, duration);
    }

    function testCreateVestingPullsTokensAndStoresSchedule() public {
        vm.expectEmit(true, true, true, true, address(vesting));
        emit VestingCreated(1, alice, address(token), TOTAL, start, cliff, duration);

        uint256 id = _create(alice, TOTAL);

        assertEq(id, 1);
        assertEq(vesting.getSchedulesCount(), 1);
        assertEq(token.balanceOf(address(vesting)), TOTAL);
        assertEq(token.balanceOf(address(this)), 10_000_000 ether - TOTAL);

        TokenVesting.VestingSchedule memory schedule = vesting.getSchedule(id);
        assertEq(schedule.id, id);
        assertEq(schedule.beneficiary, alice);
        assertEq(schedule.token, address(token));
        assertEq(schedule.totalAmount, TOTAL);
        assertEq(schedule.released, 0);
        assertEq(schedule.start, start);
        assertEq(schedule.cliff, cliff);
        assertEq(schedule.duration, duration);
        assertEq(schedule.createdAt, block.timestamp);

        uint256[] memory ids = vesting.getBeneficiaryScheduleIds(alice);
        assertEq(ids.length, 1);
        assertEq(ids[0], id);
        assertEq(vesting.getBeneficiarySchedules(alice).length, 1);
    }

    function testNothingVestsBeforeStartAndCliff() public {
        uint256 id = _create(alice, TOTAL);

        vm.warp(start - 1);
        assertEq(vesting.getVestedAmount(id), 0);
        assertEq(vesting.getReleasableAmount(id), 0);

        vm.warp(uint256(start) + cliff - 1);
        assertEq(vesting.getVestedAmount(id), 0);

        vm.prank(alice);
        vm.expectRevert(TokenVesting.NothingToRelease.selector);
        vesting.release(id);
    }

    function testLinearVestingAtCliffAndMidpoint() public {
        uint256 id = _create(alice, TOTAL);

        vm.warp(uint256(start) + cliff);
        assertEq(vesting.getVestedAmount(id), TOTAL / 10, "10% at 10% of duration");

        vm.warp(uint256(start) + duration / 2);
        assertEq(vesting.getVestedAmount(id), TOTAL / 2);

        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        uint256 released = vesting.release(id);

        assertEq(released, TOTAL / 2);
        assertEq(token.balanceOf(alice) - before, TOTAL / 2);
        assertEq(vesting.getSchedule(id).released, TOTAL / 2);
        assertEq(vesting.getReleasableAmount(id), 0);
    }

    function testReleaseTransfersOnlyUnreleasedVestedAmount() public {
        uint256 id = _create(alice, TOTAL);

        vm.warp(uint256(start) + 6_000);
        vm.prank(alice);
        uint256 first = vesting.release(id);
        assertEq(first, (TOTAL * 6_000) / duration);

        vm.warp(uint256(start) + 8_000);
        vm.prank(alice);
        uint256 second = vesting.release(id);
        assertEq(second, (TOTAL * 2_000) / duration);

        assertEq(vesting.getSchedule(id).released, (TOTAL * 8_000) / duration);
        assertEq(token.balanceOf(alice), (TOTAL * 8_000) / duration);
    }

    function testFullVestingAtDurationAndFinalRelease() public {
        uint256 id = _create(alice, TOTAL);

        vm.warp(start + duration);
        assertEq(vesting.getVestedAmount(id), TOTAL);

        vm.expectEmit(true, true, true, true, address(vesting));
        emit TokensReleased(id, alice, address(token), TOTAL);
        vm.prank(alice);
        vesting.release(id);

        assertEq(token.balanceOf(alice), TOTAL);
        assertEq(token.balanceOf(address(vesting)), 0);
        assertEq(vesting.getReleasableAmount(id), 0);

        vm.warp(start + duration + 365 days);
        vm.prank(alice);
        vm.expectRevert(TokenVesting.NothingToRelease.selector);
        vesting.release(id);
    }

    function testOnlyBeneficiaryCanRelease() public {
        uint256 id = _create(alice, TOTAL);
        vm.warp(start + duration);

        vm.prank(bob);
        vm.expectRevert(TokenVesting.NotBeneficiary.selector);
        vesting.release(id);
    }

    function testFeeOnTransferVestingUsesActualReceivedAmount() public {
        FeeOnTransferERC20 fot = new FeeOnTransferERC20("Fee Token", "FOT", 18, 1_000); // 10%
        fot.mint(address(this), 10_000 ether);
        fot.approve(address(vesting), type(uint256).max);

        vm.expectEmit(true, true, true, true, address(vesting));
        emit VestingCreated(1, alice, address(fot), 900 ether, start, cliff, duration);
        uint256 id = vesting.createVesting{ value: FEE }(alice, address(fot), 1_000 ether, start, cliff, duration);

        assertEq(vesting.getSchedule(id).totalAmount, 900 ether);
        assertEq(fot.balanceOf(address(vesting)), 900 ether);

        vm.warp(start + duration);
        vm.prank(alice);
        vesting.release(id);

        assertEq(fot.balanceOf(address(vesting)), 0);
        // A second 10% fee is charged on the outgoing transfer.
        assertEq(fot.balanceOf(alice), 810 ether);
    }

    function testWithOneHundredPercentFeeRevertsWithNoTokensReceived() public {
        FeeOnTransferERC20 fot = new FeeOnTransferERC20("All Fee", "AF", 18, 10_000);
        fot.mint(address(this), 100 ether);
        fot.approve(address(vesting), 100 ether);

        vm.expectRevert(TokenVesting.NoTokensReceived.selector);
        vesting.createVesting{ value: FEE }(alice, address(fot), 100 ether, start, cliff, duration);
    }

    function testPaginationAndBeneficiaryIndex() public {
        uint256 id1 = _create(alice, 1_000 ether);
        _create(bob, 2_000 ether);
        uint256 id3 = _create(alice, 3_000 ether);
        assertEq(vesting.getSchedulesCount(), 3);

        TokenVesting.VestingSchedule[] memory page = vesting.getSchedulesPaginated(0, 2);
        assertEq(page.length, 2);
        assertEq(page[0].id, id1);
        assertEq(page[1].beneficiary, bob);

        page = vesting.getSchedulesPaginated(2, 10);
        assertEq(page.length, 1);
        assertEq(page[0].id, id3);
        assertEq(page[0].totalAmount, 3_000 ether);

        assertEq(vesting.getSchedulesPaginated(3, 1).length, 0);
        assertEq(vesting.getSchedulesPaginated(0, 0).length, 0);

        uint256[] memory ids = vesting.getBeneficiaryScheduleIds(alice);
        assertEq(ids.length, 2);
        assertEq(ids[0], id1);
        assertEq(ids[1], id3);

        TokenVesting.VestingSchedule[] memory aliceSchedules = vesting.getBeneficiarySchedules(alice);
        assertEq(aliceSchedules.length, 2);
        assertEq(aliceSchedules[0].totalAmount, 1_000 ether);
        assertEq(aliceSchedules[1].id, id3);

        assertEq(vesting.getBeneficiarySchedules(address(0xCAFE)).length, 0);
    }

    function testMissingScheduleReverts() public {
        vm.expectRevert(TokenVesting.ScheduleDoesNotExist.selector);
        vesting.getSchedule(0);

        vm.expectRevert(TokenVesting.ScheduleDoesNotExist.selector);
        vesting.getSchedule(1);

        vm.expectRevert(TokenVesting.ScheduleDoesNotExist.selector);
        vesting.getVestedAmount(1);

        vm.expectRevert(TokenVesting.ScheduleDoesNotExist.selector);
        vesting.getReleasableAmount(1);

        vm.prank(alice);
        vm.expectRevert(TokenVesting.ScheduleDoesNotExist.selector);
        vesting.release(1);
    }

    function testCreateVestingValidation() public {
        vm.expectRevert(TokenVesting.ZeroAddress.selector);
        vesting.createVesting{ value: FEE }(address(0), address(token), TOTAL, start, cliff, duration);

        vm.expectRevert(TokenVesting.ZeroAddress.selector);
        vesting.createVesting{ value: FEE }(alice, address(0), TOTAL, start, cliff, duration);

        vm.expectRevert(TokenVesting.NoTokenCode.selector);
        vesting.createVesting{ value: FEE }(alice, bob, TOTAL, start, cliff, duration);

        vm.expectRevert(TokenVesting.ZeroAmount.selector);
        vesting.createVesting{ value: FEE }(alice, address(token), 0, start, cliff, duration);

        vm.expectRevert(TokenVesting.InvalidStart.selector);
        vesting.createVesting{ value: FEE }(alice, address(token), TOTAL, 0, cliff, duration);

        vm.expectRevert(TokenVesting.InvalidDuration.selector);
        vesting.createVesting{ value: FEE }(alice, address(token), TOTAL, start, cliff, 0);

        vm.expectRevert(TokenVesting.CliffNotBeforeEnd.selector);
        vesting.createVesting{ value: FEE }(alice, address(token), TOTAL, start, duration, duration);

        vm.expectRevert(TokenVesting.CliffNotBeforeEnd.selector);
        vesting.createVesting{ value: FEE }(alice, address(token), TOTAL, start, duration + 1, duration);
    }

    function testCliffIsOptional() public {
        uint256 id = vesting.createVesting{ value: FEE }(alice, address(token), TOTAL, start, 0, duration);
        vm.warp(start + duration / 4);
        assertEq(vesting.getVestedAmount(id), TOTAL / 4);
    }

    function testStartInPastIsSupportedAndVestsImmediately() public {
        uint64 pastStart = uint64(block.timestamp - 5_000);
        uint256 id = vesting.createVesting{ value: FEE }(alice, address(token), TOTAL, pastStart, cliff, duration);

        // First 0 seconds are fully in the past; cliff has already elapsed.
        assertEq(vesting.getVestedAmount(id), TOTAL / 2);
    }
}