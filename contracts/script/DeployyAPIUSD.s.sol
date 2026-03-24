// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IProviderRevenueShare} from "../src/interfaces/IProviderRevenueShare.sol";
import {yAPIUSD} from "../src/l2/yAPIUSD.sol";

contract DeployyAPIUSD is Script {
    function run() external {
        address rs = vm.envAddress("YAPI_RS");
        address usdc = vm.envAddress("YAPI_USDC");
        address initialTreasury = vm.envAddress("YAPI_INITIAL_TREASURY");
        address feeRecipient = vm.envAddress("YAPI_FEE_RECIPIENT");

        require(rs != address(0), "YAPI_RS not set");
        require(usdc != address(0), "YAPI_USDC not set");
        require(initialTreasury != address(0), "YAPI_INITIAL_TREASURY not set");
        require(feeRecipient != address(0), "YAPI_FEE_RECIPIENT not set");

        console.log("=================================================");
        console.log("Deploying yAPIUSD");
        console.log("=================================================");
        console.log("RS:               ", rs);
        console.log("USDC:             ", usdc);
        console.log("InitialTreasury:  ", initialTreasury);
        console.log("FeeRecipient:     ", feeRecipient);
        console.log("=================================================\n");

        vm.startBroadcast();

        yAPIUSD yapi = new yAPIUSD(
            IProviderRevenueShare(rs),
            IERC20(usdc),
            initialTreasury,
            feeRecipient
        );

        console.log("yAPIUSD deployed at: ", address(yapi));

        vm.stopBroadcast();

        console.log("\n=================================================");
        console.log("DEPLOYMENT COMPLETE");
        console.log("=================================================");
        console.log("yAPIUSD: ", address(yapi));
        console.log("=================================================\n");
    }
}
