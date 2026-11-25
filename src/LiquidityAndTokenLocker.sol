// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title LiquidityAndTokenLocker
/// @notice Non-custodial time locks for standard ERC-20 tokens and ERC-20 DEX LP
///         tokens such as BarkSwap pool tokens. NFT positions (ERC-721) are not
///         accepted by this locker.
/// @dev Non-upgradeable and ownerless. The only way tokens leave this contract is
///      a withdrawal by the current lock owner after unlockTime. There is no
///      admin withdrawal function. Fee-on-transfer tokens are accounted for by
///      measuring the contract balance before and after each transfer.
contract LiquidityAndTokenLocker is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Absolute upper bound for the per-lock fee.
    uint256 public constant MAX_FEE = 1000 ether;

    /// @notice Flat fee charged per lock, in wei of the native token (DOGE).
    ///         Collected only for the locker service and forwarded immediately.
    uint256 public immutable lockFee;

    /// @notice Address that receives lock fees.
    address payable public immutable feeReceiver;

    /// @notice A single lock. amount is the amount actually received by this
    ///         contract (which can be lower than the requested amount for
    ///         fee-on-transfer tokens).
    struct Lock {
        uint256 id;
        address owner;
        address token;
        uint256 amount;
        uint64 createdAt;
        uint64 unlockTime;
        bool withdrawn;
    }

    Lock[] private _locks;
    mapping(address owner => uint256[] lockIds) private _lockIdsByOwner;

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
    event LockFeePaid(address indexed payer, uint256 amount);

    error InvalidFeeReceiver();
    error FeeAboveMaximum();
    error IncorrectFee(uint256 expected, uint256 received);
    error FeeTransferFailed();
    error ZeroAddress();
    error ZeroAmount();
    error NoTokenCode();
    error UnlockTimeNotInFuture();
    error NoTokensReceived();
    error LockDoesNotExist();
    error NotLockOwner();
    error LockAlreadyWithdrawn();
    error LockNotUnlocked(uint64 unlockTime);
    error NewUnlockTimeNotLater(uint64 currentUnlockTime);
    error SameOwner();

    constructor(address payable feeReceiver_, uint256 lockFee_) {
        if (feeReceiver_ == address(0)) revert InvalidFeeReceiver();
        if (lockFee_ > MAX_FEE) revert FeeAboveMaximum();
        feeReceiver = feeReceiver_;
        lockFee = lockFee_;
    }

    /// @notice Lock amount of token. For fee-on-transfer tokens the stored amount
    ///         is the balance increase actually received by this contract.
    /// @param token ERC-20 or ERC-20 LP token address.
    /// @param amount Nominal amount to pull from the caller.
    /// @param unlockTime Unix timestamp (seconds) when withdrawal becomes possible.
    /// @return lockId Identifier of the new lock, starting from 1.
    function createLock(address token, uint256 amount, uint64 unlockTime)
        external
        payable
        nonReentrant
        returns (uint256 lockId)
    {
        if (token == address(0)) revert ZeroAddress();
        if (token.code.length == 0) revert NoTokenCode();
        if (amount == 0) revert ZeroAmount();
        if (unlockTime <= block.timestamp) revert UnlockTimeNotInFuture();
        if (msg.value != lockFee) revert IncorrectFee(lockFee, msg.value);

        IERC20 asset = IERC20(token);
        uint256 balanceBefore = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = asset.balanceOf(address(this)) - balanceBefore;

        if (received == 0) revert NoTokensReceived();

        lockId = _locks.length + 1;
        _locks.push(
            Lock({
                id: lockId,
                owner: msg.sender,
                token: token,
                amount: received,
                createdAt: uint64(block.timestamp),
                unlockTime: unlockTime,
                withdrawn: false
            })
        );
        _lockIdsByOwner[msg.sender].push(lockId);

        emit LockCreated(lockId, msg.sender, token, received, unlockTime);

        if (msg.value > 0) {
            (bool sent,) = feeReceiver.call{ value: msg.value }("");
            if (!sent) revert FeeTransferFailed();
            emit LockFeePaid(msg.sender, msg.value);
        }
    }

    /// @notice Withdraw the full locked amount after unlockTime.
    /// @dev Only the current lock owner can call this. State is updated before
    ///      the external transfer and protected by nonReentrant.
    function withdraw(uint256 lockId) external nonReentrant {
        Lock storage lock = _requireLock(lockId);
        if (msg.sender != lock.owner) revert NotLockOwner();
        if (lock.withdrawn) revert LockAlreadyWithdrawn();
        if (block.timestamp < lock.unlockTime) revert LockNotUnlocked(lock.unlockTime);

        lock.withdrawn = true;
        uint256 amount = lock.amount;
        address token = lock.token;
        address owner = lock.owner;

        IERC20(token).safeTransfer(owner, amount);

        emit Withdrawn(lockId, owner, token, amount);
    }

    /// @notice Extend a lock. Only increases are allowed; the unlock time can
    ///         never be shortened.
    function extendLock(uint256 lockId, uint64 newUnlockTime) external {
        Lock storage lock = _requireLock(lockId);
        if (msg.sender != lock.owner) revert NotLockOwner();
        if (lock.withdrawn) revert LockAlreadyWithdrawn();
        if (newUnlockTime <= lock.unlockTime) revert NewUnlockTimeNotLater(lock.unlockTime);

        uint64 previous = lock.unlockTime;
        lock.unlockTime = newUnlockTime;

        emit LockExtended(lockId, previous, newUnlockTime);
    }

    /// @notice Transfer ownership of an active lock. The new owner gains the
    ///         exclusive right to extend or withdraw it.
    function transferLockOwnership(uint256 lockId, address newOwner) external {
        if (newOwner == address(0)) revert ZeroAddress();
        Lock storage lock = _requireLock(lockId);
        if (msg.sender != lock.owner) revert NotLockOwner();
        if (lock.withdrawn) revert LockAlreadyWithdrawn();
        if (newOwner == msg.sender) revert SameOwner();

        address previousOwner = lock.owner;
        _removeLockId(previousOwner, lockId);
        lock.owner = newOwner;
        _lockIdsByOwner[newOwner].push(lockId);

        emit LockOwnershipTransferred(lockId, previousOwner, newOwner);
    }

    /// @notice Total number of locks ever created. IDs are consecutive from 1.
    function getLocksCount() external view returns (uint256) {
        return _locks.length;
    }

    /// @notice Read one lock by ID.
    function getLock(uint256 lockId) external view returns (Lock memory) {
        return _requireLock(lockId);
    }

    /// @notice Paginated read of every lock, including withdrawn history.
    /// @param offset Zero-based index in the internal lock array.
    /// @param limit Maximum number of locks to return.
    function getLocksPaginated(uint256 offset, uint256 limit) external view returns (Lock[] memory page) {
        uint256 total = _locks.length;
        if (limit == 0 || offset >= total) return new Lock[](0);

        uint256 end = offset + limit;
        if (end > total) end = total;

        page = new Lock[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            page[i - offset] = _locks[i];
        }
    }

    /// @notice Lock IDs currently owned by an address (withdrawn locks included
    ///         so they remain visible in account history).
    function getUserLockIds(address user) external view returns (uint256[] memory) {
        return _lockIdsByOwner[user];
    }

    /// @notice Locks currently owned by an address, including withdrawn history.
    function getUserLocks(address user) external view returns (Lock[] memory locks) {
        uint256[] storage ids = _lockIdsByOwner[user];
        locks = new Lock[](ids.length);
        for (uint256 i = 0; i < ids.length; ++i) {
            locks[i] = _locks[ids[i] - 1];
        }
    }

    /// @notice Paginated version of getUserLocks for wallets with many locks.
    function getUserLocksPaginated(address user, uint256 offset, uint256 limit)
        external
        view
        returns (Lock[] memory page)
    {
        uint256[] storage ids = _lockIdsByOwner[user];
        uint256 total = ids.length;
        if (limit == 0 || offset >= total) return new Lock[](0);

        uint256 end = offset + limit;
        if (end > total) end = total;

        page = new Lock[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            page[i - offset] = _locks[ids[i] - 1];
        }
    }

    function _requireLock(uint256 lockId) private view returns (Lock storage lock) {
        if (lockId == 0 || lockId > _locks.length) revert LockDoesNotExist();
        lock = _locks[lockId - 1];
    }

    function _removeLockId(address owner, uint256 lockId) private {
        uint256[] storage ids = _lockIdsByOwner[owner];
        uint256 length = ids.length;
        for (uint256 i = 0; i < length; ++i) {
            if (ids[i] == lockId) {
                ids[i] = ids[length - 1];
                ids.pop();
                return;
            }
        }
    }
}