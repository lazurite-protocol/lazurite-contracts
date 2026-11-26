// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title LazuriteMultisender
/// @notice Immutable, non-custodial batch sender for native coins and ERC-20 tokens.
/// @dev There is no owner, rescue function, proxy, or admin withdrawal path.
contract LazuriteMultisender is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_BATCH = 250;
    uint256 public constant MAX_FEE = 1000 ether;

    address payable public immutable feeReceiver;
    uint256 public immutable fee;

    error ArrayLengthMismatch();
    error EmptyBatch();
    error BatchTooLarge();
    error InsufficientFee(uint256 required, uint256 received);
    error TransferFailed();
    error InvalidRecipient();
    error InvalidToken();
    error InvalidFeeReceiver();
    error FeeAboveMaximum();

    event NativeDispersed(address indexed sender, uint256 recipients, uint256 total, uint256 fee);
    event TokenDispersed(address indexed sender, address indexed token, uint256 recipients, uint256 total, uint256 fee);

    constructor(address payable feeReceiver_, uint256 fee_) {
        if (feeReceiver_ == address(0)) revert InvalidFeeReceiver();
        if (fee_ > MAX_FEE) revert FeeAboveMaximum();
        feeReceiver = feeReceiver_;
        fee = fee_;
    }

    /// @notice Send native coins to many recipients in one transaction.
    /// @dev msg.value must cover total + fee. Any excess is returned to msg.sender.
    function disperseNative(address[] calldata recipients, uint256[] calldata amounts)
        external
        payable
        nonReentrant
    {
        _validate(recipients.length, amounts.length);
        uint256 total;
        for (uint256 i; i < recipients.length; ++i) {
            if (recipients[i] == address(0)) revert InvalidRecipient();
            total += amounts[i];
        }

        uint256 required = total + fee;
        if (msg.value < required) revert InsufficientFee(required, msg.value);
        uint256 excess = msg.value - required;

        if (fee > 0) _send(feeReceiver, fee);
        for (uint256 i; i < recipients.length; ++i) {
            if (amounts[i] > 0) _send(payable(recipients[i]), amounts[i]);
        }
        if (excess > 0) _send(payable(msg.sender), excess);

        emit NativeDispersed(msg.sender, recipients.length, total, fee);
    }

    /// @notice Send ERC-20 tokens to many recipients after one approve.
    /// @dev A fixed native protocol fee is charged once. Any excess native value is returned.
    function disperseToken(
        address token,
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external payable nonReentrant {
        if (token == address(0)) revert InvalidToken();
        _validate(recipients.length, amounts.length);
        if (msg.value < fee) revert InsufficientFee(fee, msg.value);

        uint256 excess = msg.value - fee;
        if (fee > 0) _send(feeReceiver, fee);

        IERC20 asset = IERC20(token);
        uint256 total;
        for (uint256 i; i < recipients.length; ++i) {
            if (recipients[i] == address(0)) revert InvalidRecipient();
            if (amounts[i] == 0) continue;
            total += amounts[i];
            asset.safeTransferFrom(msg.sender, recipients[i], amounts[i]);
        }
        if (excess > 0) _send(payable(msg.sender), excess);

        emit TokenDispersed(msg.sender, token, recipients.length, total, fee);
    }

    function _validate(uint256 recipientCount, uint256 amountCount) private pure {
        if (recipientCount != amountCount) revert ArrayLengthMismatch();
        if (recipientCount == 0) revert EmptyBatch();
        if (recipientCount > MAX_BATCH) revert BatchTooLarge();
    }

    function _send(address payable recipient, uint256 amount) private {
        (bool ok,) = recipient.call{ value: amount }("");
        if (!ok) revert TransferFailed();
    }
}
