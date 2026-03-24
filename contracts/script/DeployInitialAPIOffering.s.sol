// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IProviderRevenueShare} from "../src/interfaces/IProviderRevenueShare.sol";
import {InitialAPIOffering} from "../src/l2/InitialAPIOffering.sol";

contract DeployInitialAPIOffering is Script {
    function run() external {
        address usdc = vm.envAddress("IAO_USDC");
        address rs = vm.envAddress("IAO_RS");
        address provider = vm.envAddress("IAO_PROVIDER");
        uint256 fundingGoal = vm.envUint("IAO_FUNDING_GOAL");
        uint256 deadline = vm.envUint("IAO_DEADLINE");
        uint256 tokenPrice = vm.envUint("IAO_TOKEN_PRICE");
        uint256 rsAllocated = vm.envUint("IAO_RS_ALLOCATED");
        string memory name = vm.envString("IAO_NAME");
        string memory symbol = vm.envString("IAO_SYMBOL");

        require(usdc != address(0), "IAO_USDC not set");
        require(rs != address(0), "IAO_RS not set");
        require(provider != address(0), "IAO_PROVIDER not set");
        require(fundingGoal > 0, "IAO_FUNDING_GOAL not set");
        require(deadline > block.timestamp, "IAO_DEADLINE must be in the future");
        require(tokenPrice > 0, "IAO_TOKEN_PRICE not set");
        require(rsAllocated > 0, "IAO_RS_ALLOCATED not set");

        console.log("=================================================");
        console.log("Deploying InitialAPIOffering");
        console.log("=================================================");
        console.log("USDC:         ", usdc);
        console.log("RS:           ", rs);
        console.log("Provider:     ", provider);
        console.log("FundingGoal:  ", fundingGoal);
        console.log("Deadline:     ", deadline);
        console.log("TokenPrice:   ", tokenPrice);
        console.log("RSAllocated:  ", rsAllocated);
        console.log("Name:         ", name);
        console.log("Symbol:       ", symbol);
        console.log("=================================================\n");

        vm.startBroadcast();

        InitialAPIOffering iao = new InitialAPIOffering(
            IERC20(usdc),
            IProviderRevenueShare(rs),
            provider,
            fundingGoal,
            deadline,
            tokenPrice,
            rsAllocated,
            name,
            symbol
        );

        console.log("InitialAPIOffering deployed at: ", address(iao));

        vm.stopBroadcast();

        console.log("\n=================================================");
        console.log("DEPLOYMENT COMPLETE");
        console.log("=================================================");
        console.log("InitialAPIOffering: ", address(iao));
        console.log("=================================================\n");
    }
}
