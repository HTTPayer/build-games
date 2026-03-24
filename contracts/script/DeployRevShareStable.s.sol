// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IProviderRevenueShare} from "../src/interfaces/IProviderRevenueShare.sol";
import {RevShareStable} from "../src/l2/RevShareStable.sol";

contract DeployRevShareStable is Script {
    function run() external {
        address rs = vm.envAddress("RSS_RS");
        address usdc = vm.envAddress("RSS_USDC");
        address feeRecipient = vm.envAddress("RSS_FEE_RECIPIENT");

        require(rs != address(0), "RSS_RS not set");
        require(usdc != address(0), "RSS_USDC not set");
        require(feeRecipient != address(0), "RSS_FEE_RECIPIENT not set");

        console.log("=================================================");
        console.log("Deploying RevShareStable");
        console.log("=================================================");
        console.log("RS:           ", rs);
        console.log("USDC:         ", usdc);
        console.log("FeeRecipient: ", feeRecipient);
        console.log("=================================================\n");

        vm.startBroadcast();

        RevShareStable rss = new RevShareStable(
            IProviderRevenueShare(rs),
            IERC20(usdc),
            feeRecipient
        );

        console.log("RevShareStable deployed at: ", address(rss));

        vm.stopBroadcast();

        console.log("\n=================================================");
        console.log("DEPLOYMENT COMPLETE");
        console.log("=================================================");
        console.log("RevShareStable: ", address(rss));
        console.log("=================================================\n");
    }
}
