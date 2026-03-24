// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {APIYieldIndex} from "../src/l2/APIYieldIndex.sol";

contract DeployAPIYieldIndex is Script {
    function run() external {
        address usdc = vm.envAddress("INDEX_USDC");
        string memory name = vm.envString("INDEX_NAME");
        string memory symbol = vm.envString("INDEX_SYMBOL");

        require(usdc != address(0), "INDEX_USDC not set");

        console.log("=================================================");
        console.log("Deploying APIYieldIndex");
        console.log("=================================================");
        console.log("USDC:   ", usdc);
        console.log("Name:   ", name);
        console.log("Symbol: ", symbol);
        console.log("=================================================\n");

        vm.startBroadcast();

        APIYieldIndex index = new APIYieldIndex(IERC20(usdc), name, symbol);

        console.log("APIYieldIndex deployed at: ", address(index));

        vm.stopBroadcast();

        console.log("\n=================================================");
        console.log("DEPLOYMENT COMPLETE");
        console.log("=================================================");
        console.log("APIYieldIndex: ", address(index));
        console.log("=================================================\n");
    }
}
