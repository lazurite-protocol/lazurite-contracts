// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { TokenFactory } from "../src/TokenFactory.sol";
import { LiquidityAndTokenLocker } from "../src/LiquidityAndTokenLocker.sol";
import { TokenVesting } from "../src/TokenVesting.sol";

/// @title Deploy
/// @notice Deploys the complete Lazurite toolchain to DogeOS Chikyu Testnet (chain ID 6281971).
/// @dev Required env: PRIVATE_KEY. Optional env: FEE_RECEIVER, FLAT_FEE_WEI,
///      LOCK_FEE_WEI, VESTING_FEE_WEI, CHAIN_ID.
///      Run:
///        forge script script/Deploy.s.sol:Deploy \
///          --rpc-url https://rpc.testnet.dogeos.com \
///          --broadcast -vvv
contract Deploy is Script {
    uint256 internal constant DOGEOS_CHIKYU_CHAIN_ID = 6281971;
    uint256 internal constant DEFAULT_FLAT_FEE = 30 ether;
    uint256 internal constant DEFAULT_LOCK_FEE = 75 ether;
    uint256 internal constant DEFAULT_VESTING_FEE = 50 ether;

    function run()
        external
        returns (TokenFactory factory, LiquidityAndTokenLocker locker, TokenVesting vesting)
    {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        uint256 expectedChainId = vm.envOr("CHAIN_ID", DOGEOS_CHIKYU_CHAIN_ID);
        require(block.chainid == expectedChainId, "Unexpected chain ID: set CHAIN_ID to override");

        address payable feeReceiver = payable(vm.envOr("FEE_RECEIVER", deployer));
        uint256 flatFee = vm.envOr("FLAT_FEE_WEI", DEFAULT_FLAT_FEE);
        uint256 lockFee = vm.envOr("LOCK_FEE_WEI", DEFAULT_LOCK_FEE);
        uint256 vestingFee = vm.envOr("VESTING_FEE_WEI", DEFAULT_VESTING_FEE);

        vm.startBroadcast(privateKey);
        factory = new TokenFactory(feeReceiver, flatFee);
        locker = new LiquidityAndTokenLocker(feeReceiver, lockFee);
        vesting = new TokenVesting(feeReceiver, vestingFee);
        vm.stopBroadcast();

        console2.log("Lazurite deployment complete");
        console2.log("Network: DogeOS Chikyu Testnet");
        console2.log("Chain ID:", block.chainid);
        console2.log("Deployer:", deployer);
        console2.log("Fee receiver:", feeReceiver);
        console2.log("Flat token creation fee (wei):", flatFee);
        console2.log("Flat liquidity lock fee (wei):", lockFee);
        console2.log("Flat vesting creation fee (wei):", vestingFee);
        console2.log("TokenFactory:", address(factory));
        console2.log("LiquidityAndTokenLocker:", address(locker));
        console2.log("TokenVesting:", address(vesting));
        console2.log("");
        console2.log("Add these to frontend/.env.local:");
        console2.log("NEXT_PUBLIC_TOKEN_FACTORY_ADDRESS=", address(factory));
        console2.log("NEXT_PUBLIC_LOCKER_ADDRESS=", address(locker));
        console2.log("NEXT_PUBLIC_VESTING_ADDRESS=", address(vesting));

        _writeDeploymentJson(
            deployer,
            feeReceiver,
            flatFee,
            lockFee,
            vestingFee,
            address(factory),
            address(locker),
            address(vesting)
        );
    }

    function _writeDeploymentJson(
        address deployer,
        address feeReceiver,
        uint256 flatFee,
        uint256 lockFee,
        uint256 vestingFee,
        address factory,
        address locker,
        address vesting
    ) private {
        string memory objectKey = "lazurite";
        vm.serializeUint(objectKey, "chainId", block.chainid);
        vm.serializeString(objectKey, "network", "DogeOS Chikyu Testnet");
        vm.serializeAddress(objectKey, "deployer", deployer);
        vm.serializeAddress(objectKey, "feeReceiver", feeReceiver);
        vm.serializeUint(objectKey, "flatFeeWei", flatFee);
        vm.serializeUint(objectKey, "lockFeeWei", lockFee);
        vm.serializeUint(objectKey, "vestingFeeWei", vestingFee);
        vm.serializeAddress(objectKey, "tokenFactory", factory);
        vm.serializeAddress(objectKey, "liquidityAndTokenLocker", locker);
        vm.serializeAddress(objectKey, "tokenVesting", vesting);
        string memory json = vm.serializeUint(objectKey, "deployedAt", block.timestamp);

        vm.createDir("./deployments", true);
        vm.writeJson(json, "./deployments/6281971.json");
    }
}
