// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { V3LiquidityLocker } from "../src/V3LiquidityLocker.sol";
import { IBarkSwapNonfungiblePositionManager } from "../src/interfaces/IBarkSwapNonfungiblePositionManager.sol";

contract MockNonfungiblePositionManager is ERC721 {
    uint256 public lastTokenId;
    address public lastRecipient;
    uint128 public lastAmount0Max;
    uint128 public lastAmount1Max;
    uint256 public collectCalls;

    constructor() ERC721("Mock Algebra Position", "MOCK-V3") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }

    function collect(IBarkSwapNonfungiblePositionManager.CollectParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1)
    {
        lastTokenId = params.tokenId;
        lastRecipient = params.recipient;
        lastAmount0Max = params.amount0Max;
        lastAmount1Max = params.amount1Max;
        collectCalls++;
        return (11 ether, 22 ether);
    }
}

contract V3LiquidityLockerTest is Test {
    V3LiquidityLocker internal locker;
    MockNonfungiblePositionManager internal manager;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address payable internal feeReceiver = payable(makeAddr("feeReceiver"));

    uint256 internal constant FEE = 0.0005 ether;
    uint256 internal unlockTime;

    function setUp() public {
        manager = new MockNonfungiblePositionManager();
        locker = new V3LiquidityLocker(feeReceiver, FEE);
        manager.mint(alice, 1);
        vm.prank(alice);
        manager.setApprovalForAll(address(locker), true);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        unlockTime = block.timestamp + 30 days;
    }

    function _lock() internal returns (uint256 id) {
        vm.prank(alice);
        id = locker.lockNFT{ value: FEE }(address(manager), 1, unlockTime);
    }

    function testLocksNFTAndForwardsFee() public {
        uint256 beforeFee = feeReceiver.balance;
        uint256 id = _lock();

        assertEq(id, 1);
        assertEq(manager.ownerOf(1), address(locker));
        assertEq(feeReceiver.balance, beforeFee + FEE);
        assertEq(locker.getLocksCount(), 1);

        V3LiquidityLocker.Lock memory record = locker.getLock(id);
        assertEq(record.id, id);
        assertEq(record.owner, alice);
        assertEq(record.nftManager, address(manager));
        assertEq(record.tokenId, 1);
        assertEq(record.unlockTime, unlockTime);
        assertFalse(record.withdrawn);
        assertEq(locker.getLocksByOwner(alice).length, 1);
    }

    function testLockRejectsWrongFeeAndNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(V3LiquidityLocker.IncorrectFee.selector, FEE, 0));
        locker.lockNFT(address(manager), 1, unlockTime);

        vm.prank(bob);
        vm.expectRevert(V3LiquidityLocker.NotTokenOwner.selector);
        locker.lockNFT{ value: FEE }(address(manager), 1, unlockTime);
    }

    function testLockRejectsPastUnlockAndInvalidManager() public {
        uint256 past = block.timestamp - 1;
        vm.prank(alice);
        vm.expectRevert(V3LiquidityLocker.UnlockTimeNotInFuture.selector);
        locker.lockNFT{ value: FEE }(address(manager), 1, past);

        vm.prank(alice);
        vm.expectRevert(V3LiquidityLocker.NoContractCode.selector);
        locker.lockNFT{ value: FEE }(address(0xBEEF), 1, unlockTime);
    }

    function testCollectFeesOnlyOwnerAndDoesNotUnlock() public {
        uint256 id = _lock();
        vm.prank(alice);
        (uint256 amount0, uint256 amount1) = locker.collectFees(id, type(uint128).max, type(uint128).max);

        assertEq(amount0, 11 ether);
        assertEq(amount1, 22 ether);
        assertEq(manager.lastTokenId(), 1);
        assertEq(manager.lastRecipient(), alice);
        assertEq(manager.lastAmount0Max(), type(uint128).max);
        assertEq(manager.lastAmount1Max(), type(uint128).max);
        assertEq(manager.ownerOf(1), address(locker));
        assertFalse(locker.getLock(id).withdrawn);

        vm.prank(bob);
        vm.expectRevert(V3LiquidityLocker.NotLockOwner.selector);
        locker.collectFees(id, 1, 1);
    }

    function testExtendOnlyOwnerAndOnlyLater() public {
        uint256 id = _lock();
        uint256 later = unlockTime + 30 days;

        vm.prank(alice);
        locker.extendLock(id, later);
        assertEq(locker.getLock(id).unlockTime, later);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(V3LiquidityLocker.NewUnlockTimeNotLater.selector, later));
        locker.extendLock(id, later);

        vm.prank(bob);
        vm.expectRevert(V3LiquidityLocker.NotLockOwner.selector);
        locker.extendLock(id, later + 1 days);
    }

    function testWithdrawOnlyAfterUnlockAndOnlyOwner() public {
        uint256 id = _lock();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(V3LiquidityLocker.LockNotUnlocked.selector, unlockTime));
        locker.withdrawNFT(id);

        vm.prank(bob);
        vm.expectRevert(V3LiquidityLocker.NotLockOwner.selector);
        locker.withdrawNFT(id);

        vm.warp(unlockTime);
        vm.prank(alice);
        locker.withdrawNFT(id);
        assertEq(manager.ownerOf(1), alice);
        assertTrue(locker.getLock(id).withdrawn);

        vm.prank(alice);
        vm.expectRevert(V3LiquidityLocker.LockAlreadyWithdrawn.selector);
        locker.withdrawNFT(id);

        vm.prank(alice);
        vm.expectRevert(V3LiquidityLocker.LockAlreadyWithdrawn.selector);
        locker.collectFees(id, 1, 1);
    }

    function testPaginationAndMissingLock() public {
        _lock();
        manager.mint(alice, 2);
        vm.prank(alice);
        manager.setApprovalForAll(address(locker), true);
        vm.prank(alice);
        uint256 second = locker.lockNFT{ value: FEE }(address(manager), 2, unlockTime);
        assertEq(second, 2);
        assertEq(locker.getLocksPaginated(0, 10).length, 2);
        assertEq(locker.getLocksPaginated(1, 1).length, 1);
        assertEq(locker.getLock(2).id, 2);

        vm.expectRevert(V3LiquidityLocker.LockDoesNotExist.selector);
        locker.getLock(3);
    }

    function testConstructorBounds() public {
        vm.expectRevert(V3LiquidityLocker.InvalidFeeReceiver.selector);
        new V3LiquidityLocker(payable(address(0)), FEE);

        vm.expectRevert(V3LiquidityLocker.FeeAboveMaximum.selector);
        new V3LiquidityLocker(feeReceiver, 1000 ether + 1);

        V3LiquidityLocker freeLocker = new V3LiquidityLocker(feeReceiver, 0);
        assertEq(freeLocker.lockFee(), 0);
    }
}