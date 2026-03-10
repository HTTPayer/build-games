// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {APIIntegrityRegistry} from "../src/APIIntegrityRegistry.sol";
import {StakeManager} from "../src/StakeManager.sol";
import {ChallengeManager} from "../src/ChallengeManager.sol";
import {APIRegistryFactory} from "../src/APIRegistryFactory.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockUSDCSwap} from "../src/mocks/MockUSDCSwap.sol";

/**
 * @title DeployAll
 * @notice Full protocol deployment script.
 *
 *         Supports two modes via DEPLOY_MOCK_USDC env var:
 *
 *           DEPLOY_MOCK_USDC=true  — Deploys MockUSDC + MockUSDCSwap for testnet.
 *                                    Protocol contracts use MockUSDC.
 *                                    USDC env var is used as the realUSDC in the swap.
 *
 *           DEPLOY_MOCK_USDC=false — Uses USDC env var directly. No mock deployed.
 *                                    Intended for mainnet or when real USDC is available.
 *
 * Usage (Fuji testnet with mock):
 *   forge script script/DeployAll.s.sol \
 *     --rpc-url $AVALANCHE_FUJI_RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast \
 *     --verify
 */
contract DeployAll is Script {

    function run() external {

        // =====================================================================
        // LOAD ENVIRONMENT
        // =====================================================================

        address admin    = vm.envAddress("ADMIN");
        address treasury = vm.envAddress("TREASURY");

        address creForwarder = vm.envAddress("CRE_FORWARDER");

        uint256 minimumStake     = vm.envUint("MINIMUM_STAKE");
        uint256 treasuryBp       = vm.envUint("TREASURY_BP");
        uint256 protocolSlashBp  = vm.envUint("PROTOCOL_SLASH_BP");
        uint256 withdrawCooldown = vm.envUint("WITHDRAW_COOLDOWN");

        bool deployMockUsdc = vm.envOr("DEPLOY_MOCK_USDC", false);

        require(admin    != address(0), "ADMIN not set");
        require(treasury != address(0), "TREASURY not set");
        require(creForwarder != address(0), "CRE_FORWARDER not set");

        // =====================================================================
        // HEADER
        // =====================================================================

        console.log("=================================================");
        console.log("Composed Protocol - Full Deployment");
        console.log("=================================================");
        console.log("Admin:            ", admin);
        console.log("Treasury:         ", treasury);
        console.log("CRE Forwarder:    ", creForwarder);
        console.log("Minimum Stake:    ", minimumStake);
        console.log("Treasury BP:      ", treasuryBp);
        console.log("Protocol Slash BP:", protocolSlashBp);
        console.log("Withdraw Cooldown:", withdrawCooldown);
        console.log("Mock USDC:        ", deployMockUsdc);
        console.log("=================================================\n");

        vm.startBroadcast();

        // =====================================================================
        // MOCK USDC (testnet only)
        // =====================================================================

        address usdcAddress;
        MockUSDC    mockUsdc;
        MockUSDCSwap mockSwap;

        if (deployMockUsdc) {
            address realUsdc = vm.envAddress("USDC");
            require(realUsdc != address(0), "USDC not set");

            console.log("Deploying Mock USDC...\n");

            mockUsdc = new MockUSDC(admin);
            console.log("   -> MockUSDC deployed at:    ", address(mockUsdc));

            mockSwap = new MockUSDCSwap(IERC20(realUsdc), mockUsdc);
            console.log("   -> MockUSDCSwap deployed at:", address(mockSwap));

            // Grant swap contract permission to mint/burn MockUSDC
            mockUsdc.grantRole(mockUsdc.MINTER_ROLE(), address(mockSwap));
            console.log("   -> Granted MINTER_ROLE to MockUSDCSwap");

            usdcAddress = address(mockUsdc);
            console.log("\n   [OK] Mock USDC ready\n");
        } else {
            usdcAddress = vm.envAddress("USDC");
            require(usdcAddress != address(0), "USDC not set");
            console.log("Using real USDC at:", usdcAddress, "\n");
        }

        // =====================================================================
        // LAYER 0 — SECURITY / ENFORCEMENT
        // =====================================================================

        console.log("Deploying Layer 0 - Security & Enforcement...\n");

        // 1. APIIntegrityRegistry
        console.log("1/5 Deploying APIIntegrityRegistry...");
        APIIntegrityRegistry registry = new APIIntegrityRegistry(
            admin,
            minimumStake
        );
        console.log("   -> Registry:", address(registry));

        // 2. StakeManager
        console.log("2/5 Deploying StakeManager...");
        StakeManager stakeManager = new StakeManager(
            usdcAddress,
            address(registry),
            treasury,
            admin
        );
        console.log("   -> StakeManager:", address(stakeManager));

        // 3. ChallengeManager
        console.log("3/5 Deploying ChallengeManager...");
        ChallengeManager challengeManager = new ChallengeManager(
            usdcAddress,
            address(stakeManager),
            address(registry),
            creForwarder
        );
        console.log("   -> ChallengeManager:", address(challengeManager));

        // 4. Wire StakeManager into Registry (enables stake gating on registerProvider)
        console.log("4/5 Wiring StakeManager into Registry...");
        registry.setStakeManager(address(stakeManager));
        console.log("   -> Registry.stakeManager set to StakeManager");

        // 5. Grant roles
        console.log("5/5 Granting roles...");
        registry.grantRole(registry.CHECKER_ROLE(), address(challengeManager));
        console.log("   -> Granted CHECKER_ROLE  to ChallengeManager");

        stakeManager.grantRole(stakeManager.SLASHER_ROLE(), address(challengeManager));
        console.log("   -> Granted SLASHER_ROLE  to ChallengeManager");

        // Apply configurable StakeManager parameters
        stakeManager.setProtocolSlashBp(protocolSlashBp);
        stakeManager.setWithdrawCooldown(withdrawCooldown);
        console.log("   -> StakeManager parameters configured");

        console.log("\n   [OK] Layer 0 deployed\n");

        // =====================================================================
        // LAYER 1 — REVENUE TOKENIZATION
        // =====================================================================

        console.log("Deploying Layer 1 - Revenue Tokenization...\n");

        console.log("6/6 Deploying APIRegistryFactory...");
        APIRegistryFactory factory = new APIRegistryFactory(
            IERC20(usdcAddress),
            treasury,
            treasuryBp,
            address(registry)
        );
        console.log("   -> Factory:", address(factory));

        console.log("\n   [OK] Layer 1 deployed\n");

        vm.stopBroadcast();

        // =====================================================================
        // DEPLOYMENT SUMMARY
        // =====================================================================

        console.log("=================================================");
        console.log("DEPLOYMENT COMPLETE");
        console.log("=================================================\n");

        if (deployMockUsdc) {
            console.log("Mock Tokens:");
            console.log("  MockUSDC:     ", address(mockUsdc));
            console.log("  MockUSDCSwap: ", address(mockSwap));
            console.log("");
        }

        console.log("Layer 0 - Security:");
        console.log("  Registry:         ", address(registry));
        console.log("  StakeManager:     ", address(stakeManager));
        console.log("  ChallengeManager: ", address(challengeManager));
        console.log("");

        console.log("Layer 1 - Revenue:");
        console.log("  Factory:          ", address(factory));
        console.log("");

        console.log("Configuration:");
        console.log("  USDC:             ", usdcAddress);
        console.log("  Admin:            ", admin);
        console.log("  Treasury:         ", treasury);
        console.log("  Treasury BP:      ", treasuryBp);
        console.log("  Minimum Stake:    ", minimumStake);
        console.log("  Protocol Slash BP:", protocolSlashBp);
        console.log("  Withdraw Cooldown:", withdrawCooldown);
        console.log("");

        console.log("=================================================");
        console.log("NEXT STEPS:");
        console.log("=================================================");
        console.log("1. Create a Chainlink Functions subscription");
        console.log("   https://functions.chain.link");
        console.log("2. Fund subscription with LINK");
        console.log("3. Add ChallengeManager as a consumer:");
        console.log("  ", address(challengeManager));
        console.log("4. Update CL_SUB_ID in .env and redeploy, or");
        console.log("   call challengeManager.setSubscriptionId(subId)");
        console.log("5. Providers can now register via factory.deployProvider()");
        if (deployMockUsdc) {
            console.log("6. Mint test USDC via MockUSDC.mint() or");
            console.log("   swap real Fuji USDC via MockUSDCSwap.swapIn()");
        }
        console.log("=================================================\n");
    }
}
