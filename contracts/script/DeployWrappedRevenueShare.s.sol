// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ProviderRevenueShare} from "../src/ProviderRevenueShare.sol";
import {WrappedRevenueShare} from "../src/l2/WrappedRevenueShare.sol";

contract DeployWrappedRevenueShare is Script {
    function run() external {
        address revenueShare = vm.envAddress("WRS_REVENUE_SHARE");
        address treasury = vm.envAddress("WRS_TREASURY");
        string memory name = vm.envString("WRS_NAME");
        string memory symbol = vm.envString("WRS_SYMBOL");

        require(revenueShare != address(0), "WRS_REVENUE_SHARE not set");
        require(treasury != address(0), "WRS_TREASURY not set");

        console.log("=================================================");
        console.log("Deploying WrappedRevenueShare");
        console.log("=================================================");
        console.log("RevenueShare: ", revenueShare);
        console.log("Treasury:     ", treasury);
        console.log("Name:         ", name);
        console.log("Symbol:       ", symbol);
        console.log("=================================================\n");

        vm.startBroadcast();

        WrappedRevenueShare wrs = new WrappedRevenueShare(
            ProviderRevenueShare(revenueShare),
            treasury,
            name,
            symbol
        );

        console.log("WrappedRevenueShare deployed at: ", address(wrs));

        vm.stopBroadcast();

        console.log("\n=================================================");
        console.log("DEPLOYMENT COMPLETE");
        console.log("=================================================");
        console.log("WrappedRevenueShare: ", address(wrs));
        console.log("=================================================\n");
    }
}
