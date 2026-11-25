// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title StandardERC20
/// @notice A deliberately minimal, non-upgradeable ERC-20. The entire supply is
///         minted exactly once, at deployment, to the chosen initial holder.
/// @dev There is no owner, no mint function and no burn function. This contract
///      cannot be upgraded or modified after deployment.
contract StandardERC20 is ERC20 {
    /// @notice Custom decimals used by this token.
    uint8 private immutable _customDecimals;

    error EmptyName();
    error EmptySymbol();
    error InvalidDecimals();
    error ZeroInitialSupply();
    error ZeroInitialHolder();

    /// @param name_ Human-readable token name.
    /// @param symbol_ Human-readable token symbol.
    /// @param decimals_ Number of decimals (0-36 is supported by most tooling).
    /// @param initialSupply Entire supply expressed in the smallest token unit.
    /// @param initialHolder Address that receives 100% of the initial supply.
    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        uint256 initialSupply,
        address initialHolder
    ) ERC20(name_, symbol_) {
        if (bytes(name_).length == 0) revert EmptyName();
        if (bytes(symbol_).length == 0) revert EmptySymbol();
        if (decimals_ > 36) revert InvalidDecimals();
        if (initialSupply == 0) revert ZeroInitialSupply();
        if (initialHolder == address(0)) revert ZeroInitialHolder();

        _customDecimals = decimals_;
        _mint(initialHolder, initialSupply);
    }

    /// @inheritdoc ERC20
    function decimals() public view override returns (uint8) {
        return _customDecimals;
    }
}
