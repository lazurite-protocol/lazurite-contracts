// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { LiquidityAndTokenLocker } from "../src/LiquidityAndTokenLocker.sol";
import { MockERC20, FeeOnTransferERC20, RejectingFeeReceiver } from "./mocks/MockTokens.sol";

contract LiquidityAndTokenLockerTest is Test {
    event LockCreated(
        uint256 indexed lockId,
        address indexed owner,
        address indexed token,
        uint256 amount,
        uint64 unlockTime
    );
    event LockExtended(uint256 indexed lockId, uint64 previousUnlockTime, uint64 newUnlockTime);
    event LockOwnershipTransferred(
        uint256 indexed lockId, address indexed previousOwner, address indexed newOwner
    );
    event Withdrawn(uint256 indexed lockId, address indexed owner, address indexed token, uint256 amount);

    LiquidityAndTokenLocker internal locker;
    MockERC20 internal token;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address payable internal feeReceiver;

    uint256 internal constant LOCK_FEE = 0.0005 ether;
    uint64 internal unlockTime;

    function setUp() public {
        vm.warp(1_700_000_000);
        feeReceiver = payable(makeAddr("lockFeeReceiver"));
        locker = new LiquidityAndTokenLocker(feeReceiver, LOCK_FEE);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(carol, 10 ether);
        token = new MockERC20("Liquidity Token", "LQ", 18);
        token.mint(alice, 1_000 ether);
        token.mint(bob, 1_000 ether);
        token.mint(carol, 1_000 ether);
        unlockTime = uint64(block.timestamp + 30 days);

        vm.prank(alice);
        token.approve(address(locker), type(uint256).max);
        vm.prank(bob);
        token.approve(address(locker), type(uint256).max);
        vm.prank(carol);
        token.approve(address(locker), type(uint256).max);
    }

    function _lockAs(address user, uint256 amount, uint64 when) internal returns (uint256 id) {
        vm.prank(user);
        id = locker.createLock{ value: LOCK_FEE }(address(token), amount, when);
    }

    function testCreateLockCustodiesTokensAndRecordsMetadata() public {
        uint256 before = token.balanceOf(alice);

        vm.expectEmit(true, true, true, true, address(locker));
        emit LockCreated(1, alice, address(token), 100 ether, unlockTime);
        vm.prank(alice);
        uint256 id = locker.createLock{ value: LOCK_FEE }(address(token), 100 ether, unlockTime);

        assertEq(id, 1);
        assertEq(locker.getLocksCount(), 1);
        assertEq(token.balanceOf(alice), before - 100 ether);
        assertEq(token.balanceOf(address(locker)), 100 ether);

        LiquidityAndTokenLocker.Lock memory lock = locker.getLock(1);
        assertEq(lock.id, 1);
        assertEq(lock.owner, alice);
        assertEq(lock.token, address(token));
        assertEq(lock.amount, 100 ether);
        assertEq(lock.createdAt, block.timestamp);
        assertEq(lock.unlockTime, unlockTime);
        assertFalse(lock.withdrawn);

        uint256[] memory ids = locker.getUserLockIds(alice);
        assertEq(ids.length, 1);
        assertEq(ids[0], 1);

        LiquidityAndTokenLocker.Lock[] memory own = locker.getUserLocks(alice);
        assertEq(own.length, 1);
        assertEq(own[0].id, 1);
    }

    function testWithdrawRevertsBeforeUnlock() public {
        uint256 id = _lockAs(alice, 100 ether, unlockTime);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LiquidityAndTokenLocker.LockNotUnlocked.selector, unlockTime));
        locker.withdraw(id);
    }

    function testOnlyLockOwnerCanWithdraw() public {
        uint256 id = _lockAs(alice, 100 ether, unlockTime);
        vm.warp(unlockTime);

        vm.prank(bob);
        vm.expectRevert(LiquidityAndTokenLocker.NotLockOwner.selector);
        locker.withdraw(id);
    }

    function testWithdrawAtUnlockTimeReturnsFullAmountAndIsNotRepeatable() public {
        uint256 startBalance = token.balanceOf(alice);
        uint256 id = _lockAs(alice, 100 ether, unlockTime);
        vm.warp(unlockTime);

        vm.prank(alice);
        locker.withdraw(id);

        assertEq(token.balanceOf(alice), startBalance);
        assertEq(token.balanceOf(address(locker)), 0);
        assertTrue(locker.getLock(id).withdrawn);
        assertEq(locker.getLock(id).amount, 100 ether, "history amount is preserved");

        vm.prank(alice);
        vm.expectRevert(LiquidityAndTokenLocker.LockAlreadyWithdrawn.selector);
        locker.withdraw(id);
    }

    function testWithdrawAfterUnlockTime() public {
        uint256 id = _lockAs(alice, 100 ether, unlockTime);
        vm.warp(uint256(unlockTime) + 31 days);

        vm.prank(alice);
        locker.withdraw(id);
        assertEq(token.balanceOf(alice), 1_000 ether);
    }

    function testExtendLockOnlyIncreasesAndOnlyOwner() public {
        uint256 id = _lockAs(alice, 100 ether, unlockTime);
        uint64 newUnlock = unlockTime + 30 days;

        vm.prank(bob);
        vm.expectRevert(LiquidityAndTokenLocker.NotLockOwner.selector);
        locker.extendLock(id, newUnlock);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(LiquidityAndTokenLocker.NewUnlockTimeNotLater.selector, unlockTime)
        );
        locker.extendLock(id, unlockTime);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(LiquidityAndTokenLocker.NewUnlockTimeNotLater.selector, unlockTime)
        );
        locker.extendLock(id, unlockTime - 1);

        vm.expectEmit(true, false, false, true, address(locker));
        emit LockExtended(id, unlockTime, newUnlock);
        vm.prank(alice);
        locker.extendLock(id, newUnlock);

        assertEq(locker.getLock(id).unlockTime, newUnlock);

        vm.warp(unlockTime);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LiquidityAndTokenLocker.LockNotUnlocked.selector, newUnlock));
        locker.withdraw(id);

        vm.warp(newUnlock);
        vm.prank(alice);
        locker.withdraw(id);
    }

    function testExtendRevertsForWithdrawnOrMissingLock() public {
        uint256 id = _lockAs(alice, 100 ether, unlockTime);
        vm.warp(unlockTime);
        vm.prank(alice);
        locker.withdraw(id);

        vm.prank(alice);
        vm.expectRevert(LiquidityAndTokenLocker.LockAlreadyWithdrawn.selector);
        locker.extendLock(id, unlockTime + 1 days);

        vm.prank(alice);
        vm.expectRevert(LiquidityAndTokenLocker.LockDoesNotExist.selector);
        locker.extendLock(999, unlockTime + 1 days);
    }

    function testTransferLockOwnershipMovesRightsAndLists() public {
        uint256 id = _lockAs(alice, 100 ether, unlockTime);

        vm.prank(bob);
        vm.expectRevert(LiquidityAndTokenLocker.NotLockOwner.selector);
        locker.transferLockOwnership(id, bob);

        vm.prank(alice);
        vm.expectRevert(LiquidityAndTokenLocker.ZeroAddress.selector);
        locker.transferLockOwnership(id, address(0));

        vm.prank(alice);
        vm.expectRevert(LiquidityAndTokenLocker.SameOwner.selector);
        locker.transferLockOwnership(id, alice);

        vm.expectEmit(true, true, true, false, address(locker));
        emit LockOwnershipTransferred(id, alice, bob);
        vm.prank(alice);
        locker.transferLockOwnership(id, bob);

        assertEq(locker.getLock(id).owner, bob);
        assertEq(locker.getUserLocks(alice).length, 0);
        assertEq(locker.getUserLocks(bob).length, 1);

        vm.prank(alice);
        vm.expectRevert(LiquidityAndTokenLocker.NotLockOwner.selector);
        locker.withdraw(id);

        vm.prank(bob);
        locker.extendLock(id, unlockTime + 1 days);
        vm.warp(unlockTime + 1 days);
        vm.prank(bob);
        locker.withdraw(id);
        assertEq(token.balanceOf(bob), 1_100 ether);
    }

    function testTransferRevertsAfterWithdrawalAndForMissingLock() public {
        uint256 id = _lockAs(alice, 100 ether, unlockTime);
        vm.warp(unlockTime);
        vm.prank(alice);
        locker.withdraw(id);

        vm.prank(alice);
        vm.expectRevert(LiquidityAndTokenLocker.LockAlreadyWithdrawn.selector);
        locker.transferLockOwnership(id, bob);

        vm.prank(alice);
        vm.expectRevert(LiquidityAndTokenLocker.LockDoesNotExist.selector);
        locker.transferLockOwnership(0, bob);
    }

    function testTransferBackDoesNotDuplicateUserLocks() public {
        uint256 id = _lockAs(alice, 100 ether, unlockTime);

        vm.prank(alice);
        locker.transferLockOwnership(id, bob);
        vm.prank(bob);
        locker.transferLockOwnership(id, alice);

        uint256[] memory ids = locker.getUserLockIds(alice);
        assertEq(ids.length, 1);
        assertEq(ids[0], id);
        assertEq(locker.getUserLocks(bob).length, 0);
    }

    function testFeeOnTransferDepositUsesActualReceivedAmount() public {
        FeeOnTransferERC20 fot = new FeeOnTransferERC20("Fee Token", "FOT", 18, 1_000); // 10%
        fot.mint(alice, 10_000 ether);
        vm.prank(alice);
        fot.approve(address(locker), type(uint256).max);

        vm.expectEmit(true, true, true, true, address(locker));
        emit LockCreated(1, alice, address(fot), 900 ether, unlockTime);
        vm.prank(alice);
        uint256 id = locker.createLock{ value: LOCK_FEE }(address(fot), 1_000 ether, unlockTime);

        LiquidityAndTokenLocker.Lock memory lock = locker.getLock(id);
        assertEq(lock.amount, 900 ether);
        assertEq(fot.balanceOf(address(locker)), 900 ether);

        vm.warp(unlockTime);
        vm.prank(alice);
        locker.withdraw(id);

        assertEq(fot.balanceOf(address(locker)), 0);
        // The token also charges 10% on withdrawal, so 810 tokens arrive.
        assertEq(fot.balanceOf(alice), 9_000 ether + 810 ether);
    }

    function testFeeOnTransferWithFullFeeRevertsAfterMeasuringBalance() public {
        FeeOnTransferERC20 fot = new FeeOnTransferERC20("All Fee", "AF", 18, 10_000);
        fot.mint(alice, 100 ether);
        vm.prank(alice);
        fot.approve(address(locker), 100 ether);

        vm.prank(alice);
        vm.expectRevert(LiquidityAndTokenLocker.NoTokensReceived.selector);
        locker.createLock{ value: LOCK_FEE }(address(fot), 100 ether, unlockTime);

        assertEq(locker.getLocksCount(), 0);
    }

    function testPaginationReturnsCorrectSlices() public {
        _lockAs(alice, 1 ether, unlockTime);
        _lockAs(bob, 2 ether, unlockTime + 1);
        _lockAs(carol, 3 ether, unlockTime + 2);
        _lockAs(alice, 4 ether, unlockTime + 3);

        assertEq(locker.getLocksCount(), 4);

        LiquidityAndTokenLocker.Lock[] memory page = locker.getLocksPaginated(0, 2);
        assertEq(page.length, 2);
        assertEq(page[0].id, 1);
        assertEq(page[1].owner, bob);

        page = locker.getLocksPaginated(2, 10);
        assertEq(page.length, 2);
        assertEq(page[0].id, 3);
        assertEq(page[1].amount, 4 ether);

        assertEq(locker.getLocksPaginated(4, 2).length, 0);
        assertEq(locker.getLocksPaginated(0, 0).length, 0);
    }

    function testUserLocksIncludeHistoryAndPaginate() public {
        _lockAs(alice, 1 ether, unlockTime);
        _lockAs(bob, 2 ether, unlockTime);
        _lockAs(alice, 3 ether, unlockTime);

        LiquidityAndTokenLocker.Lock[] memory aliceLocks = locker.getUserLocks(alice);
        assertEq(aliceLocks.length, 2);
        assertEq(aliceLocks[0].id, 1);
        assertEq(aliceLocks[1].id, 3);

        LiquidityAndTokenLocker.Lock[] memory page = locker.getUserLocksPaginated(alice, 1, 5);
        assertEq(page.length, 1);
        assertEq(page[0].id, 3);
        assertEq(locker.getUserLocksPaginated(alice, 2, 5).length, 0);
        assertEq(locker.getUserLocksPaginated(alice, 0, 0).length, 0);
    }

    function testCreateLockValidation() public {
        vm.prank(alice);
        vm.expectRevert(LiquidityAndTokenLocker.ZeroAddress.selector);
        locker.createLock(address(0), 1 ether, unlockTime);

        vm.prank(alice);
        vm.expectRevert(LiquidityAndTokenLocker.NoTokenCode.selector);
        locker.createLock(bob, 1 ether, unlockTime);

        vm.prank(alice);
        vm.expectRevert(LiquidityAndTokenLocker.ZeroAmount.selector);
        locker.createLock(address(token), 0, unlockTime);

        vm.prank(alice);
        vm.expectRevert(LiquidityAndTokenLocker.UnlockTimeNotInFuture.selector);
        locker.createLock(address(token), 1 ether, uint64(block.timestamp));

        vm.prank(alice);
        vm.expectRevert(LiquidityAndTokenLocker.UnlockTimeNotInFuture.selector);
        locker.createLock(address(token), 1 ether, uint64(block.timestamp - 1));
    }

    function testGetMissingLockReverts() public {
        vm.expectRevert(LiquidityAndTokenLocker.LockDoesNotExist.selector);
        locker.getLock(0);

        vm.expectRevert(LiquidityAndTokenLocker.LockDoesNotExist.selector);
        locker.getLock(1);
    }

    function testLockFeeIsForwardedAndContractKeepsNoNativeValue() public {
        uint256 before = feeReceiver.balance;

        uint256 id = _lockAs(alice, 10 ether, unlockTime);

        assertEq(feeReceiver.balance - before, LOCK_FEE);
        assertEq(address(locker).balance, 0);
        assertEq(locker.lockFee(), LOCK_FEE);
        assertEq(locker.getLock(id).amount, 10 ether);
    }

    function testIncorrectLockFeeReverts() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(LiquidityAndTokenLocker.IncorrectFee.selector, LOCK_FEE, LOCK_FEE - 1)
        );
        locker.createLock{ value: LOCK_FEE - 1 }(address(token), 1 ether, unlockTime);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(LiquidityAndTokenLocker.IncorrectFee.selector, LOCK_FEE, LOCK_FEE + 1)
        );
        locker.createLock{ value: LOCK_FEE + 1 }(address(token), 1 ether, unlockTime);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LiquidityAndTokenLocker.IncorrectFee.selector, LOCK_FEE, 0));
        locker.createLock(address(token), 1 ether, unlockTime);
    }

    function testLockerFeeConfigurationBoundsAndZeroFee() public {
        vm.expectRevert(LiquidityAndTokenLocker.InvalidFeeReceiver.selector);
        new LiquidityAndTokenLocker(payable(address(0)), LOCK_FEE);

        vm.expectRevert(LiquidityAndTokenLocker.FeeAboveMaximum.selector);
        new LiquidityAndTokenLocker(feeReceiver, 1000 ether + 1);

        LiquidityAndTokenLocker freeLocker = new LiquidityAndTokenLocker(feeReceiver, 0);
        vm.prank(alice);
        token.approve(address(freeLocker), 1 ether);
        vm.prank(alice);
        uint256 id = freeLocker.createLock(address(token), 1 ether, unlockTime);
        assertEq(freeLocker.getLock(id).amount, 1 ether);
        assertEq(address(freeLocker).balance, 0);
    }

    function testRejectingFeeReceiverRevertsEntireLock() public {
        RejectingFeeReceiver rejector = new RejectingFeeReceiver();
        LiquidityAndTokenLocker rejectingLocker =
            new LiquidityAndTokenLocker(payable(address(rejector)), LOCK_FEE);
        uint256 tokenBefore = token.balanceOf(alice);
        vm.prank(alice);
        token.approve(address(rejectingLocker), 1 ether);

        vm.prank(alice);
        vm.expectRevert(LiquidityAndTokenLocker.FeeTransferFailed.selector);
        rejectingLocker.createLock{ value: LOCK_FEE }(address(token), 1 ether, unlockTime);

        assertEq(token.balanceOf(alice), tokenBefore);
        assertEq(token.balanceOf(address(rejectingLocker)), 0);
        assertEq(rejectingLocker.getLocksCount(), 0);
    }
}
