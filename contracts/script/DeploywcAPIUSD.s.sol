// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IProviderRevenueShare} from "../src/interfaces/IProviderRevenueShare.sol";
import {wcAPIUSD} from "../src/l2/wcAPIUSD.sol";

contract DeploywcAPIUSD is Script {
    function run() external {
        address rs = vm.envAddress("WCI_RS");
        address usdc = vm.envAddress("WCI_USDC");
        address borrower = vm.envAddress("WCI_BORROWER");
        address feeRecipient = vm.envAddress("WCI_FEE_RECIPIENT");

        require(rs != address(0), "WCI_RS not set");
        require(usdc != address(0), "WCI_USDC not set");
        require(borrower != address(0), "WCI_BORROWER not set");
        require(feeRecipient != address(0), "WCI_FEE_RECIPIENT not set");

        console.log("=================================================");
        console.log("Deploying wcAPIUSD");
        console.log("=================================================");
        console.log("RS:            ", rs);
        console.log("USDC:          ", usdc);
        console.log("Borrower:      ", borrower);
        console.log("FeeRecipient:  ", feeRecipient);
        console.log("=================================================\n");

        vm.startBroadcast();

        wcAPIUSD wci = new wcAPIUSD(
            IProviderRevenueShare(rs),
            IERC20(usdc),
            borrower,
            feeRecipient
        );

        console.log("wcAPIUSD deployed at: ", address(wci));

        vm.stopBroadcast();

        console.log("\n=================================================");
        console.log("DEPLOYMENT COMPLETE");
        console.log("=================================================");
        console.log("wcAPIUSD: ", address(wci));
        console.log("=================================================\n");
    }
}
