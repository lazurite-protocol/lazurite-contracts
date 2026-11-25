// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IBarkSwapNonfungiblePositionManager } from "./interfaces/IBarkSwapNonfungiblePositionManager.sol";

/// @title V3LiquidityLocker
/// @notice Non-custodial locks for V3 / Algebra NFT liquidity positions.
/// @dev Only the original depositor can collect swap fees, extend the lock or
///      withdraw the NFT after the unlock time. There is no owner and no admin
///      path that can move a user's NFT.
contract V3LiquidityLocker is IERC721Receiver, ReentrancyGuard {
    uint256 public constant MAX_FEE = 1000 ether;

    uint256 public immutable lockFee;
    address payable public immutable feeReceiver;

    struct Lock {
        uint256 id;
        address owner;
        address nftManager;
        uint256 tokenId;
        uint64 createdAt;
        uint64 unlockTime;
        bool withdrawn;
    }

    Lock[] private _locks;
    mapping(address owner => uint256[] ids) private _lockIdsByOwner;

    event LockCreated(
        uint256 indexed lockId,
        address indexed owner,
        address indexed nftManager,
        uint256 tokenId,
        uint64 unlockTime
    );
    event FeesCollected(
        uint256 indexed lockId,
        address indexed owner,
        uint256 amount0,
        uint256 amount1
    );
    event LockExtended(uint256 indexed lockId, uint64 previousUnlockTime, uint64 newUnlockTime);
    event NFTWithdrawn(uint256 indexed lockId, address indexed owner, address indexed nftManager, uint256 tokenId);
    event LockFeePaid(address indexed payer, uint256 amount);

    error InvalidFeeReceiver();
    error FeeAboveMaximum();
    error IncorrectFee(uint256 expected, uint256 received);
    error FeeTransferFailed();
    error ZeroAddress();
    error NoContractCode();
    error UnlockTimeNotInFuture();
    error UnlockTimeTooLarge();
    error NotTokenOwner();
    error NFTNotReceived();
    error LockDoesNotExist();
    error NotLockOwner();
    error LockAlreadyWithdrawn();
    error LockNotUnlocked(uint64 unlockTime);
    error NewUnlockTimeNotLater(uint64 currentUnlockTime);
    error FeeCollectionFailed();

    constructor(address payable feeReceiver_, uint256 lockFee_) {
        if (feeReceiver_ == address(0)) revert InvalidFeeReceiver();
        if (lockFee_ > MAX_FEE) revert FeeAboveMaximum();
        feeReceiver = feeReceiver_;
        lockFee = lockFee_;
    }

    /// @notice Lock a V3 / Algebra NFT position.
    /// @param nftManager The NonfungiblePositionManager that owns the NFT.
    /// @param tokenId The position token id.
    /// @param unlockTime Unix timestamp when withdrawal becomes possible.
    function lockNFT(address nftManager, uint256 tokenId, uint256 unlockTime)
        external
        payable
        nonReentrant
        returns (uint256 lockId)
    {
        if (nftManager == address(0)) revert ZeroAddress();
        if (nftManager.code.length == 0) revert NoContractCode();
        if (unlockTime <= block.timestamp) revert UnlockTimeNotInFuture();
        if (unlockTime > type(uint64).max) revert UnlockTimeTooLarge();
        if (msg.value != lockFee) revert IncorrectFee(lockFee, msg.value);

        IERC721 nft = IERC721(nftManager);
        if (nft.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();

        nft.safeTransferFrom(msg.sender, address(this), tokenId);
        if (nft.ownerOf(tokenId) != address(this)) revert NFTNotReceived();

        lockId = _locks.length + 1;
        _locks.push(
            Lock({
                id: lockId,
                owner: msg.sender,
                nftManager: nftManager,
                tokenId: tokenId,
                createdAt: uint64(block.timestamp),
                unlockTime: uint64(unlockTime),
                withdrawn: false
            })
        );
        _lockIdsByOwner[msg.sender].push(lockId);

        emit LockCreated(lockId, msg.sender, nftManager, tokenId, uint64(unlockTime));

        if (msg.value > 0) {
            (bool sent,) = feeReceiver.call{ value: msg.value }("");
            if (!sent) revert FeeTransferFailed();
            emit LockFeePaid(msg.sender, msg.value);
        }
    }

    /// @notice Collect trading fees from the locked position without unlocking it.
    /// @dev The NFT remains in this contract; only the owner can call this.
    function collectFees(uint256 lockId, uint128 amount0Max, uint128 amount1Max)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        Lock storage lock = _lock(lockId);
        if (lock.withdrawn) revert LockAlreadyWithdrawn();
        if (msg.sender != lock.owner) revert NotLockOwner();

        (amount0, amount1) = IBarkSwapNonfungiblePositionManager(lock.nftManager).collect(
            IBarkSwapNonfungiblePositionManager.CollectParams({
                tokenId: lock.tokenId,
                recipient: lock.owner,
                amount0Max: amount0Max,
                amount1Max: amount1Max
            })
        );

        emit FeesCollected(lockId, lock.owner, amount0, amount1);
    }

    /// @notice Extend a lock. Only the owner may call, and the new time must be later.
    function extendLock(uint256 lockId, uint256 newUnlockTime) external {
        Lock storage lock = _lock(lockId);
        if (lock.withdrawn) revert LockAlreadyWithdrawn();
        if (msg.sender != lock.owner) revert NotLockOwner();
        if (newUnlockTime <= lock.unlockTime) revert NewUnlockTimeNotLater(lock.unlockTime);
        if (newUnlockTime > type(uint64).max) revert UnlockTimeTooLarge();

        uint64 previous = lock.unlockTime;
        lock.unlockTime = uint64(newUnlockTime);
        emit LockExtended(lockId, previous, uint64(newUnlockTime));
    }

    /// @notice Withdraw the NFT to its original owner after the unlock time.
    function withdrawNFT(uint256 lockId) external nonReentrant {
        Lock storage lock = _lock(lockId);
        if (lock.withdrawn) revert LockAlreadyWithdrawn();
        if (msg.sender != lock.owner) revert NotLockOwner();
        if (block.timestamp < lock.unlockTime) revert LockNotUnlocked(lock.unlockTime);

        lock.withdrawn = true;
        IERC721(lock.nftManager).safeTransferFrom(address(this), lock.owner, lock.tokenId);
        emit NFTWithdrawn(lockId, lock.owner, lock.nftManager, lock.tokenId);
    }

    function getLock(uint256 lockId) external view returns (Lock memory) {
        return _lock(lockId);
    }

    function getLocksCount() external view returns (uint256) {
        return _locks.length;
    }

    function getLocksByOwner(address owner) external view returns (uint256[] memory) {
        return _lockIdsByOwner[owner];
    }

    function getLocksPaginated(uint256 offset, uint256 limit)
        external
        view
        returns (Lock[] memory page)
    {
        uint256 total = _locks.length;
        if (offset >= total || limit == 0) return new Lock[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        page = new Lock[](end - offset);
        for (uint256 i = offset; i < end; i++) page[i - offset] = _locks[i];
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }

    function _lock(uint256 lockId) private view returns (Lock storage lock) {
        if (lockId == 0 || lockId > _locks.length) revert LockDoesNotExist();
        return _locks[lockId - 1];
    }
}