// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {ProviderRevenueShare} from "../src/ProviderRevenueShare.sol";
import {APIRevenueStable} from "../src/l2/APIRevenueStable.sol";

contract DeployAPIRevenueStable is Script {
    function run() external {
        address revenueShare = vm.envAddress("STABLE_REVENUE_SHARE");
        address feeRecipient = vm.envAddress("STABLE_FEE_RECIPIENT");
        string memory name = vm.envString("STABLE_NAME");
        string memory symbol = vm.envString("STABLE_SYMBOL");

        require(revenueShare != address(0), "STABLE_REVENUE_SHARE not set");
        require(feeRecipient != address(0), "STABLE_FEE_RECIPIENT not set");

        console.log("=================================================");
        console.log("Deploying APIRevenueStable");
        console.log("=================================================");
        console.log("RevenueShare: ", revenueShare);
        console.log("FeeRecipient: ", feeRecipient);
        console.log("Name:         ", name);
        console.log("Symbol:       ", symbol);
        console.log("=================================================\n");

        vm.startBroadcast();

        APIRevenueStable stable = new APIRevenueStable(
            ProviderRevenueShare(revenueShare),
            feeRecipient,
            name,
            symbol
        );

        console.log("APIRevenueStable deployed at: ", address(stable));

        vm.stopBroadcast();

        console.log("\n=================================================");
        console.log("DEPLOYMENT COMPLETE");
        console.log("=================================================");
        console.log("APIRevenueStable: ", address(stable));
        console.log("=================================================\n");
    }
}
