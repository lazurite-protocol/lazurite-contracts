// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { LazuriteMultisender } from "../src/LazuriteMultisender.sol";

/// @notice Deploy the immutable Lazurite Multisender.
contract DeployMultisender is Script {
    function run() external returns (LazuriteMultisender multisender) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        uint256 expectedChainId = vm.envOr("CHAIN_ID", uint256(6281971));
        require(block.chainid == expectedChainId, "Unexpected chain ID");

        address payable feeReceiver = payable(
            vm.envOr("FEE_RECEIVER", address(0x8d836630E6FA80B353D4C7B4D50C9f6B3D68cB57))
        );
        uint256 fee = vm.envOr("MULTISEND_FEE_WEI", uint256(500000000000000));

        vm.startBroadcast(privateKey);
        multisender = new LazuriteMultisender(feeReceiver, fee);
        vm.stopBroadcast();

        console2.log("LazuriteMultisender:", address(multisender));
        console2.log("Fee receiver:", feeReceiver);
        console2.log("Multisend fee (wei):", fee);
    }
}
