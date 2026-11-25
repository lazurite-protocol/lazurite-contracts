// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title TokenVesting
/// @notice Non-upgradeable linear token vesting with a cliff for teams and
///         investors. Each schedule is fully funded at creation.
/// @dev Ownerless: schedules cannot be revoked, shortened, or redirected. Once
///      funded, tokens can only ever be released to the named beneficiary.
///      Fee-on-transfer deposits are measured by actual balance delta.
contract TokenVesting is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Absolute upper bound for the vesting creation fee.
    uint256 public constant MAX_FEE = 1000 ether;

    /// @notice Flat fee charged when a vesting schedule is created, in wei of
    ///         the native token (DOGE on DogeOS).
    uint256 public immutable vestingFee;

    /// @notice Address that receives vesting creation fees.
    address payable public immutable feeReceiver;

    /// @notice A vesting schedule. totalAmount is the amount actually received
    ///         by this contract (after any transfer fee).
    struct VestingSchedule {
        uint256 id;
        address beneficiary;
        address token;
        uint256 totalAmount;
        uint256 released;
        uint64 start;
        uint64 cliff;
        uint64 duration;
        uint64 createdAt;
    }

    VestingSchedule[] private _schedules;
    mapping(address beneficiary => uint256[] ids) private _scheduleIdsByBeneficiary;

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
    event VestingFeePaid(address indexed payer, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error NoTokenCode();
    error InvalidStart();
    error InvalidDuration();
    error CliffNotBeforeEnd();
    error NoTokensReceived();
    error ScheduleDoesNotExist();
    error NotBeneficiary();
    error NothingToRelease();
    error InvalidFeeReceiver();
    error FeeAboveMaximum();
    error IncorrectFee(uint256 expected, uint256 received);
    error FeeTransferFailed();

    constructor(address payable feeReceiver_, uint256 vestingFee_) {
        if (feeReceiver_ == address(0)) revert InvalidFeeReceiver();
        if (vestingFee_ > MAX_FEE) revert FeeAboveMaximum();
        feeReceiver = feeReceiver_;
        vestingFee = vestingFee_;
    }

    /// @notice Fund and create a vesting schedule.
    /// @dev Linearity starts at start; nothing is vested before start + cliff.
    ///      After the cliff, the vested amount is total * (now - start) / duration.
    ///      At start + duration, 100% is vested.
    /// @param beneficiary Address that can release and receive vested tokens.
    /// @param token ERC-20 token being vested.
    /// @param amount Nominal amount to pull; actual received amount is recorded.
    /// @param start Unix timestamp at which linear vesting begins.
    /// @param cliff Seconds to wait after start before any release is possible.
    /// @param duration Total vesting duration in seconds from start.
    /// @return scheduleId Identifier of the new schedule, starting at 1.
    function createVesting(
        address beneficiary,
        address token,
        uint256 amount,
        uint64 start,
        uint64 cliff,
        uint64 duration
    ) external payable nonReentrant returns (uint256 scheduleId) {
        if (beneficiary == address(0) || token == address(0)) revert ZeroAddress();
        if (token.code.length == 0) revert NoTokenCode();
        if (amount == 0) revert ZeroAmount();
        if (start == 0) revert InvalidStart();
        if (duration == 0) revert InvalidDuration();
        if (cliff >= duration) revert CliffNotBeforeEnd();
        if (msg.value != vestingFee) revert IncorrectFee(vestingFee, msg.value);

        IERC20 asset = IERC20(token);
        uint256 balanceBefore = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = asset.balanceOf(address(this)) - balanceBefore;

        if (received == 0) revert NoTokensReceived();

        scheduleId = _schedules.length + 1;
        _schedules.push(
            VestingSchedule({
                id: scheduleId,
                beneficiary: beneficiary,
                token: token,
                totalAmount: received,
                released: 0,
                start: start,
                cliff: cliff,
                duration: duration,
                createdAt: uint64(block.timestamp)
            })
        );
        _scheduleIdsByBeneficiary[beneficiary].push(scheduleId);

        emit VestingCreated(scheduleId, beneficiary, token, received, start, cliff, duration);

        if (msg.value > 0) {
            (bool sent,) = feeReceiver.call{ value: msg.value }("");
            if (!sent) revert FeeTransferFailed();
            emit VestingFeePaid(msg.sender, msg.value);
        }
    }

    /// @notice Release all currently vested but unreleased tokens to the beneficiary.
    /// @dev Callable only by the beneficiary. Tokens are sent directly to them.
    /// @return amount Amount transferred (nominal token units).
    function release(uint256 scheduleId) external nonReentrant returns (uint256 amount) {
        if (scheduleId == 0 || scheduleId > _schedules.length) revert ScheduleDoesNotExist();
        VestingSchedule storage schedule = _schedules[scheduleId - 1];
        if (msg.sender != schedule.beneficiary) revert NotBeneficiary();

        amount = _releasable(schedule);
        if (amount == 0) revert NothingToRelease();

        schedule.released += amount;
        IERC20(schedule.token).safeTransfer(schedule.beneficiary, amount);

        emit TokensReleased(scheduleId, schedule.beneficiary, schedule.token, amount);
    }

    /// @notice Total number of schedules ever created.
    function getSchedulesCount() external view returns (uint256) {
        return _schedules.length;
    }

    /// @notice Read one schedule by ID.
    function getSchedule(uint256 scheduleId) external view returns (VestingSchedule memory) {
        if (scheduleId == 0 || scheduleId > _schedules.length) revert ScheduleDoesNotExist();
        return _schedules[scheduleId - 1];
    }

    /// @notice Amount already vested at the current timestamp.
    function getVestedAmount(uint256 scheduleId) public view returns (uint256) {
        if (scheduleId == 0 || scheduleId > _schedules.length) revert ScheduleDoesNotExist();
        return _vested(_schedules[scheduleId - 1], block.timestamp);
    }

    /// @notice Amount that can be released right now.
    function getReleasableAmount(uint256 scheduleId) external view returns (uint256) {
        if (scheduleId == 0 || scheduleId > _schedules.length) revert ScheduleDoesNotExist();
        return _releasable(_schedules[scheduleId - 1]);
    }

    /// @notice Paginated read of the global schedule registry.
    function getSchedulesPaginated(uint256 offset, uint256 limit)
        external
        view
        returns (VestingSchedule[] memory page)
    {
        uint256 total = _schedules.length;
        if (limit == 0 || offset >= total) return new VestingSchedule[](0);

        uint256 end = offset + limit;
        if (end > total) end = total;

        page = new VestingSchedule[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            page[i - offset] = _schedules[i];
        }
    }

    /// @notice Schedule IDs belonging to a beneficiary.
    function getBeneficiaryScheduleIds(address beneficiary) external view returns (uint256[] memory) {
        return _scheduleIdsByBeneficiary[beneficiary];
    }

    /// @notice All schedules belonging to a beneficiary.
    function getBeneficiarySchedules(address beneficiary)
        external
        view
        returns (VestingSchedule[] memory schedules)
    {
        uint256[] storage ids = _scheduleIdsByBeneficiary[beneficiary];
        schedules = new VestingSchedule[](ids.length);
        for (uint256 i = 0; i < ids.length; ++i) {
            schedules[i] = _schedules[ids[i] - 1];
        }
    }

    function _vested(VestingSchedule storage schedule, uint256 timestamp) private view returns (uint256) {
        uint256 start = schedule.start;
        uint256 cliffEnd = start + schedule.cliff;
        uint256 end = start + schedule.duration;

        if (timestamp < cliffEnd) return 0;
        if (timestamp >= end) return schedule.totalAmount;

        uint256 elapsed = timestamp - start;
        return Math.mulDiv(schedule.totalAmount, elapsed, schedule.duration);
    }

    function _releasable(VestingSchedule storage schedule) private view returns (uint256) {
        uint256 vested = _vested(schedule, block.timestamp);
        return vested - schedule.released;
    }
}