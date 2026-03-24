// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {APIRevenueFuture} from "../src/l2/APIRevenueFuture.sol";

contract DeployAPIRevenueFuture is Script {
    function run() external {
        address usdc = vm.envAddress("FUTURE_USDC");

        require(usdc != address(0), "FUTURE_USDC not set");

        console.log("=================================================");
        console.log("Deploying APIRevenueFuture");
        console.log("=================================================");
        console.log("USDC: ", usdc);
        console.log("=================================================\n");

        vm.startBroadcast();

        APIRevenueFuture future = new APIRevenueFuture(IERC20(usdc));

        console.log("APIRevenueFuture deployed at: ", address(future));

        vm.stopBroadcast();

        console.log("\n=================================================");
        console.log("DEPLOYMENT COMPLETE");
        console.log("=================================================");
        console.log("APIRevenueFuture: ", address(future));
        console.log("=================================================\n");
    }
}
