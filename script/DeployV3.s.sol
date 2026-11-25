// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { V3LiquidityLocker } from "../src/V3LiquidityLocker.sol";

/// @notice Deploy the V3/Algebra NFT liquidity locker to DogeOS Chikyū.
contract DeployV3 is Script {
    function run() external returns (V3LiquidityLocker v3Locker) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        require(block.chainid == 6281971, "Expected DogeOS Chikyu Testnet");

        address payable feeReceiver = payable(vm.envOr("FEE_RECEIVER", deployer));
        uint256 lockFee = vm.envOr("LOCK_FEE_WEI", uint256(500000000000000));

        vm.startBroadcast(privateKey);
        v3Locker = new V3LiquidityLocker(feeReceiver, lockFee);
        vm.stopBroadcast();

        console2.log("Network: DogeOS Chikyu Testnet");
        console2.log("Deployer:", deployer);
        console2.log("Fee receiver:", feeReceiver);
        console2.log("V3 lock fee (wei):", lockFee);
        console2.log("V3LiquidityLocker:", address(v3Locker));
        console2.log("NEXT_PUBLIC_V3_LOCKER_ADDRESS=", address(v3Locker));
    }
}