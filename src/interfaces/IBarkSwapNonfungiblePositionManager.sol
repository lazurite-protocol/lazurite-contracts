// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal BarkSwap / Algebra NonfungiblePositionManager surface used by the locker.
/// @dev BarkSwap on DogeOS uses the Algebra concentrated-liquidity position manager.
///      The locker only needs ERC-721 ownership plus collect, so this interface is
///      intentionally narrow and does not expose mint/increase/decrease operations.
interface IBarkSwapNonfungiblePositionManager {
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    /// @notice Collects fees owed to a position. The position stays in the locker
    ///         until withdrawNFT is called.
    function collect(CollectParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);
}
