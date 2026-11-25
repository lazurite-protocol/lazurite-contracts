// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Plain ERC-20 used by tests. Ownerless mint is intentional and test-only.
contract MockERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @notice ERC-20 that takes a fee on every non-mint/non-burn transfer.
contract FeeOnTransferERC20 is ERC20 {
    uint256 public immutable feeBps;
    uint8 private immutable _decimals;
    address public constant SINK = address(0xdead);

    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint256 feeBps_)
        ERC20(name_, symbol_)
    {
        require(feeBps_ <= 10_000, "fee too high");
        feeBps = feeBps_;
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }

        uint256 fee = (value * feeBps) / 10_000;
        if (fee > 0) super._update(from, SINK, fee);
        super._update(from, to, value - fee);
    }
}

/// @notice A receiver that rejects native value, used to test the fee-forwarding path.
contract RejectingFeeReceiver {
    receive() external payable {
        revert("NO_ZTC");
    }
}

/// @notice A receiver that accepts native value.
contract AcceptingFeeReceiver {
    receive() external payable { }
}
