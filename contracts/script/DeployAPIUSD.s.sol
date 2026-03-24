// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IProviderRevenueShare} from "../src/interfaces/IProviderRevenueShare.sol";
import {APIUSD} from "../src/l2/APIUSD.sol";

contract DeployAPIUSD is Script {
    function run() external {
        address rs = vm.envAddress("APIUSD_RS");
        address usdc = vm.envAddress("APIUSD_USDC");
        address feeRecipient = vm.envAddress("APIUSD_FEE_RECIPIENT");

        require(rs != address(0), "APIUSD_RS not set");
        require(usdc != address(0), "APIUSD_USDC not set");
        require(feeRecipient != address(0), "APIUSD_FEE_RECIPIENT not set");

        console.log("=================================================");
        console.log("Deploying APIUSD");
        console.log("=================================================");
        console.log("RS:            ", rs);
        console.log("USDC:          ", usdc);
        console.log("FeeRecipient:  ", feeRecipient);
        console.log("=================================================\n");

        vm.startBroadcast();

        APIUSD apiusd = new APIUSD(
            IProviderRevenueShare(rs),
            IERC20(usdc),
            feeRecipient
        );

        console.log("APIUSD deployed at: ", address(apiusd));

        vm.stopBroadcast();

        console.log("\n=================================================");
        console.log("DEPLOYMENT COMPLETE");
        console.log("=================================================");
        console.log("APIUSD: ", address(apiusd));
        console.log("=================================================\n");
    }
}
