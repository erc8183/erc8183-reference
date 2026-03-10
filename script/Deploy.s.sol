// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ACPCore} from "../contracts/ACPCore.sol";
import {ReputationGate} from "../contracts/hooks/ReputationGate.sol";
import {BiddingHook} from "../contracts/hooks/BiddingHook.sol";

contract Deploy is Script {
    // USDC on Base Mainnet
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        // Deploy core contract
        ACPCore core = new ACPCore(USDC);
        console.log("ACPCore deployed at:", address(core));

        // Deploy example hooks
        ReputationGate reputationGate = new ReputationGate(10); // minimum score = 10
        console.log("ReputationGate deployed at:", address(reputationGate));

        BiddingHook biddingHook = new BiddingHook();
        console.log("BiddingHook deployed at:", address(biddingHook));

        vm.stopBroadcast();
    }
}
