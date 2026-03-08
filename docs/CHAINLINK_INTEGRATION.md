# Chainlink Integration Guide

## Overview

The API Integrity Protocol uses **two Chainlink services**:

1. **Chainlink Functions** - Offchain computation to verify endpoint integrity
2. **Chainlink Automation** - Periodic automated challenges for continuous monitoring

This guide covers complete setup and integration.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Challenge Flow                           │
└─────────────────────────────────────────────────────────────┘

1. Challenger calls ChallengeManager.openChallenge(endpointId)
   ↓
2. ChallengeManager sends request to Chainlink Functions
   ↓
3. Functions executes JavaScript offchain:
   - Fetches endpoint URL
   - Parses 402 response (payTo, apiId, etc.)
   - Computes integrity hash
   - Compares to expected hash
   - Returns boolean
   ↓
4. Functions calls ChallengeManager.fulfillRequest()
   ↓
5. ChallengeManager:
   - If valid: refund challenger fee to provider
   - If invalid: slash provider, reward challenger
   - Update lastCheckedAt

┌─────────────────────────────────────────────────────────────┐
│                  Automation Flow (Optional)                 │
└─────────────────────────────────────────────────────────────┘

1. Chainlink Automation calls checkUpkeep()
   ↓
2. Returns list of stale endpoints (lastCheckedAt > interval)
   ↓
3. Automation calls performUpkeep()
   ↓
4. Triggers openChallenge() for each stale endpoint
   ↓
5. Flows into standard challenge flow above
```

---

## Part 1: Chainlink Functions Setup

### What It Does

Chainlink Functions executes JavaScript code offchain to:
- Fetch an API endpoint
- Parse the 402 payment response
- Verify the `payTo` address matches what's registered
- Return true (valid) or false (invalid)

This provides **deterministic offchain verification** without trusting any single party.

---

### Step 1: Create Subscription

Visit [Chainlink Functions](https://functions.chain.link/) and connect wallet.

#### On Avalanche Fuji:

1. Click "Create Subscription"
2. Fund with minimum **5 LINK**
3. Note the **Subscription ID** (you'll need this)

Example:
```
Subscription ID: 1234
```

Update your `.env`:
```bash
CL_SUB_ID=1234
```

---

### Step 2: Write Functions Source Code

Create file: `chainlink/functions-source.js`

```javascript
// Chainlink Functions Source Code
// Verifies API endpoint integrity by fetching and hashing response metadata

// ============================================================================
// ARGUMENTS (passed from smart contract)
// ============================================================================
// args[0] = endpoint URL (string)
// args[1] = endpoint method (string) - "GET", "POST", etc.
// args[2] = expected integrity hash (bytes32 as hex string)

const endpointUrl = args[0];
const method = args[1];
const expectedHash = args[2];

// ============================================================================
// STEP 1: Fetch the endpoint
// ============================================================================

console.log(`Fetching: ${method} ${endpointUrl}`);

const response = await Functions.makeHttpRequest({
  url: endpointUrl,
  method: method,
  timeout: 5000,
  headers: {
    "Accept": "application/json"
  }
});

// We expect a 402 Payment Required response
if (response.status !== 402) {
  console.error(`Expected 402, got ${response.status}`);
  return Functions.encodeUint256(0); // Invalid
}

// ============================================================================
// STEP 2: Parse payment metadata
// ============================================================================

const paymentData = response.data;

if (!paymentData || !paymentData.payTo) {
  console.error("Missing payTo in 402 response");
  return Functions.encodeUint256(0); // Invalid
}

// Extract relevant fields
const payTo = paymentData.payTo;
const apiId = paymentData.apiId || "";
const amount = paymentData.amount || "";
const currency = paymentData.currency || "";

console.log(`payTo: ${payTo}`);
console.log(`apiId: ${apiId}`);

// ============================================================================
// STEP 3: Compute integrity hash
// ============================================================================

// Create deterministic string representation
const dataString = JSON.stringify({
  payTo: payTo.toLowerCase(), // Normalize address case
  apiId: apiId,
  amount: amount,
  currency: currency
});

console.log(`Data string: ${dataString}`);

// Hash the data (using ethers.js keccak256)
const encoder = new TextEncoder();
const data = encoder.encode(dataString);

// Convert to hex string
let hexString = "0x";
for (let i = 0; i < data.length; i++) {
  hexString += data[i].toString(16).padStart(2, '0');
}

// Compute keccak256 hash using built-in
const actualHash = Functions.keccak256(hexString);

console.log(`Expected hash: ${expectedHash}`);
console.log(`Actual hash: ${actualHash}`);

// ============================================================================
// STEP 4: Compare hashes and return result
// ============================================================================

const isValid = actualHash.toLowerCase() === expectedHash.toLowerCase();

console.log(`Validation result: ${isValid}`);

// Return 1 for valid, 0 for invalid
return Functions.encodeUint256(isValid ? 1 : 0);
```

---

### Step 3: Upload Source to IPFS (Optional but Recommended)

For production, store the source code on IPFS for transparency:

```bash
# Install IPFS CLI or use Pinata
ipfs add chainlink/functions-source.js

# Output:
# QmXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
```

Store the CID for reference in your documentation.

---

### Step 4: Add ChallengeManager as Consumer

In the Chainlink Functions UI:

1. Go to your subscription
2. Click "Add Consumer"
3. Enter your `ChallengeManager` contract address
4. Confirm transaction

---

### Step 5: Configure Functions in ChallengeManager

The source code is sent with each request. You can update it without redeploying contracts.

**Option A: Store source onchain** (costs gas but ensures it can't change):

```solidity
// Add to ChallengeManager
string public functionsSource = "..."; // Full JS source

function updateFunctionsSource(string calldata newSource)
    external
    onlyRole(DEFAULT_ADMIN_ROLE)
{
    functionsSource = newSource;
}
```

**Option B: Pass source with each challenge** (more flexible):

The current implementation sends the source code with each request. To update, you'd pass it to `openChallenge()`.

---

### Step 6: Test Functions Locally

Use Chainlink Functions Playground:

1. Visit https://functions.chain.link/playground
2. Paste your JavaScript code
3. Add test arguments:
   ```
   ["https://api.example.com/v1/pricing", "GET", "0xabc123..."]
   ```
4. Click "Run"
5. Verify output is `0` or `1`

---

## Part 2: Chainlink Automation Setup

### What It Does

Chainlink Automation monitors the protocol and automatically opens challenges for stale endpoints.

- Checks which endpoints haven't been verified recently
- Calls `openChallenge()` for stale endpoints
- Runs on a schedule (e.g., daily)

This provides **continuous automated integrity monitoring**.

---

### Current Implementation Status

⚠️ **The Automation logic is currently stubbed out.**

`ChallengeManager.sol` has:
```solidity
function checkUpkeep(bytes calldata)
    external
    view
    override
    returns (bool upkeepNeeded, bytes memory performData)
{
    // TODO: Implement endpoint checking logic
    upkeepNeeded = true;
    performData = "";
}

function performUpkeep(bytes calldata)
    external
    override
{
    // TODO: Implement challenge triggering
}
```

---

### Implementing Automation (Required for Production)

#### Option 1: Simple Single-Endpoint Check

Add state to track endpoints:

```solidity
// Add to ChallengeManager
bytes32[] public registeredEndpoints;
uint256 public nextCheckIndex;

function registerEndpointForMonitoring(bytes32 endpointId) external {
    registeredEndpoints.push(endpointId);
}

function checkUpkeep(bytes calldata)
    external
    view
    override
    returns (bool upkeepNeeded, bytes memory performData)
{
    if (registeredEndpoints.length == 0) {
        return (false, "");
    }

    bytes32 endpointId = registeredEndpoints[nextCheckIndex];

    (
        ,
        ,
        ,
        ,
        ,
        ,
        bool active,
        ,
        uint256 lastCheckedAt
    ) = registry.endpoints(endpointId);

    // Check if endpoint needs verification
    if (active && block.timestamp - lastCheckedAt > checkInterval) {
        upkeepNeeded = true;
        performData = abi.encode(endpointId);
    } else {
        upkeepNeeded = false;
        performData = "";
    }
}

function performUpkeep(bytes calldata performData)
    external
    override
{
    bytes32 endpointId = abi.decode(performData, (bytes32));

    // Open challenge (requires funding this contract with USDC for challenge fee)
    openChallenge(endpointId);

    // Move to next endpoint in round-robin fashion
    nextCheckIndex = (nextCheckIndex + 1) % registeredEndpoints.length;
}
```

#### Option 2: Batch Check Multiple Endpoints

More gas-efficient for large deployments:

```solidity
function checkUpkeep(bytes calldata)
    external
    view
    override
    returns (bool upkeepNeeded, bytes memory performData)
{
    bytes32[] memory staleEndpoints = new bytes32[](10); // Max 10 per batch
    uint256 count = 0;

    for (uint256 i = 0; i < registeredEndpoints.length && count < 10; i++) {
        bytes32 endpointId = registeredEndpoints[i];

        (
            ,
            ,
            ,
            ,
            ,
            ,
            bool active,
            ,
            uint256 lastCheckedAt
        ) = registry.endpoints(endpointId);

        if (active && block.timestamp - lastCheckedAt > checkInterval) {
            staleEndpoints[count] = endpointId;
            count++;
        }
    }

    if (count > 0) {
        // Resize array to actual count
        bytes32[] memory result = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = staleEndpoints[i];
        }

        upkeepNeeded = true;
        performData = abi.encode(result);
    } else {
        upkeepNeeded = false;
        performData = "";
    }
}

function performUpkeep(bytes calldata performData)
    external
    override
{
    bytes32[] memory endpointIds = abi.decode(performData, (bytes32[]));

    for (uint256 i = 0; i < endpointIds.length; i++) {
        openChallenge(endpointIds[i]);
    }
}
```

#### Option 3: Off-Chain Endpoint List (Most Efficient)

Use an off-chain indexer to build the list:

```solidity
function checkUpkeep(bytes calldata checkData)
    external
    view
    override
    returns (bool upkeepNeeded, bytes memory performData)
{
    // Decode endpoint list passed from off-chain keeper
    bytes32[] memory endpointIds = abi.decode(checkData, (bytes32[]));

    bytes32[] memory staleEndpoints = new bytes32[](endpointIds.length);
    uint256 count = 0;

    for (uint256 i = 0; i < endpointIds.length; i++) {
        (
            ,
            ,
            ,
            ,
            ,
            ,
            bool active,
            ,
            uint256 lastCheckedAt
        ) = registry.endpoints(endpointIds[i]);

        if (active && block.timestamp - lastCheckedAt > checkInterval) {
            staleEndpoints[count] = endpointIds[i];
            count++;
        }
    }

    if (count > 0) {
        bytes32[] memory result = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = staleEndpoints[i];
        }

        upkeepNeeded = true;
        performData = abi.encode(result);
    } else {
        upkeepNeeded = false;
    }
}
```

Then run an off-chain service that:
1. Queries all registered endpoints from Registry events
2. Passes the list to `checkUpkeep(bytes)`
3. Automation only pays gas for verification, not enumeration

---

### Step 7: Register Automation Upkeep

1. Visit [Chainlink Automation](https://automation.chain.link/)
2. Click "Register New Upkeep"
3. Configure:
   - **Target contract:** `ChallengeManager` address
   - **Upkeep name:** "API Integrity Monitor"
   - **Gas limit:** 500,000 (adjust based on batch size)
   - **Check frequency:** Time-based (e.g., every 1 hour)
   - **Starting balance:** 5 LINK minimum
4. Confirm transaction

---

### Step 8: Fund Automation Contract

The Automation contract needs USDC to pay challenge fees:

```bash
# Send USDC to ChallengeManager for automation
cast send $USDC \
  "transfer(address,uint256)" \
  $CHALLENGE_MANAGER \
  1000000000 \
  --rpc-url $AVALANCHE_FUJI_RPC_URL \
  --private-key $ADMIN_KEY
```

Or add a funding function:

```solidity
// Add to ChallengeManager
function fundAutomation(uint256 amount) external {
    USDC.transferFrom(msg.sender, address(this), amount);
}
```

---

## Part 3: Integration Checklist

### Pre-Deployment

- [ ] Write Functions source code (`chainlink/functions-source.js`)
- [ ] Test Functions in playground
- [ ] Implement Automation logic (`checkUpkeep` + `performUpkeep`)
- [ ] Test Automation with Foundry tests

### Post-Deployment

- [ ] Create Chainlink Functions subscription
- [ ] Fund subscription with LINK (5+ LINK)
- [ ] Add ChallengeManager as consumer
- [ ] Test opening a manual challenge
- [ ] Register Chainlink Automation upkeep
- [ ] Fund upkeep with LINK (5+ LINK)
- [ ] Fund ChallengeManager with USDC for automation fees
- [ ] Monitor first automated challenge

---

## Part 4: Testing

### Test Functions Locally

```solidity
// test/ChainlinkFunctions.t.sol
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "../src/ChallengeManager.sol";

contract ChainlinkFunctionsTest is Test {
    ChallengeManager challengeManager;

    function setUp() public {
        // Deploy contracts
        challengeManager = new ChallengeManager(...);
    }

    function testOpenChallenge() public {
        // Mock endpoint
        bytes32 endpointId = 0x123...;

        // Open challenge
        challengeManager.openChallenge(endpointId);

        // Verify challenge created
        (address challenger, , ) = challengeManager.challenges(1);
        assertEq(challenger, address(this));
    }

    function testFulfillRequest() public {
        // Open challenge
        challengeManager.openChallenge(endpointId);

        // Simulate oracle callback
        vm.prank(ORACLE_ADDRESS);
        challengeManager.fulfillRequest(
            requestId,
            abi.encode(true), // Valid
            ""
        );

        // Verify challenge resolved
        (, , Status status) = challengeManager.challenges(1);
        assertEq(uint256(status), uint256(Status.Valid));
    }
}
```

### Test Automation

```solidity
function testAutomationCheckUpkeep() public {
    // Register endpoint
    registry.registerEndpoint(...);

    // Wait for interval to pass
    vm.warp(block.timestamp + 1 days + 1);

    // Check upkeep
    (bool upkeepNeeded, bytes memory performData) =
        challengeManager.checkUpkeep("");

    assertTrue(upkeepNeeded);
}

function testAutomationPerformUpkeep() public {
    // Setup stale endpoint
    bytes32 endpointId = setupStaleEndpoint();

    // Perform upkeep
    bytes memory performData = abi.encode(endpointId);
    challengeManager.performUpkeep(performData);

    // Verify challenge was opened
    assertEq(challengeManager.challengeCount(), 1);
}
```

---

## Part 5: Monitoring & Maintenance

### Monitor Functions Usage

```bash
# Check Functions subscription balance
cast call $SUBSCRIPTION_CONTRACT \
  "getSubscription(uint64)(uint96,uint96,address)" \
  $CL_SUB_ID \
  --rpc-url $AVALANCHE_FUJI_RPC_URL
```

### Monitor Automation

Visit the Automation dashboard to see:
- Upkeep balance
- Last execution time
- Gas usage
- Success/failure rate

### Top Up Subscriptions

```bash
# Add LINK to Functions subscription
# (Use Chainlink UI)

# Add LINK to Automation upkeep
# (Use Chainlink UI)
```

### Update Functions Source

```bash
# If source is onchain:
cast send $CHALLENGE_MANAGER \
  "updateFunctionsSource(string)" \
  "$(cat chainlink/functions-source.js)" \
  --rpc-url $AVALANCHE_FUJI_RPC_URL \
  --private-key $ADMIN_KEY
```

---

## Part 6: Cost Estimates

### Functions Cost per Challenge

- **LINK cost:** ~0.1-0.5 LINK per request
- **Gas cost:** ~200k gas for fulfillment
- **Total:** ~$0.50-2.00 per challenge (varies with LINK price)

### Automation Cost

- **LINK cost:** ~0.01-0.05 LINK per execution
- **Frequency:** Configurable (hourly, daily, etc.)
- **Monthly cost (daily checks):** ~0.3-1.5 LINK/month

### Recommendations

- **Testnet:** Start with 10 LINK for testing
- **Production:** Budget 50+ LINK for first month
- **Set up alerts** when balance drops below 5 LINK

---

## Part 7: Security Considerations

### Functions Security

1. **Source code transparency** - Store on IPFS
2. **Deterministic hashing** - Use consistent normalization
3. **Timeout handling** - Functions timeout after 5 seconds
4. **Error handling** - Return 0 (invalid) on any error

### Automation Security

1. **Funding** - Only fund with necessary USDC
2. **Rate limiting** - Automation prevents spam
3. **Gas limits** - Set appropriate limits to prevent griefing
4. **Admin controls** - Only admin can update intervals

---

## Part 8: Troubleshooting

### Functions Not Executing

**Symptoms:** Challenge stays in Pending status

**Solutions:**
- Check subscription has LINK balance
- Verify ChallengeManager is added as consumer
- Check Functions router address is correct
- Verify DON ID matches network

### Automation Not Triggering

**Symptoms:** No automated challenges

**Solutions:**
- Verify upkeep is registered and funded
- Check `checkUpkeep()` returns `upkeepNeeded = true`
- Ensure ChallengeManager has USDC for fees
- Check Automation dashboard for errors

### Invalid Hash Comparison

**Symptoms:** All challenges return invalid

**Solutions:**
- Verify hash normalization (lowercase addresses)
- Check JSON.stringify ordering is consistent
- Test hash generation locally first
- Verify endpoint returns correct 402 format

---

## Summary

### Required for MVP

✅ **Must Have:**
- Chainlink Functions subscription
- Functions source code
- Add ChallengeManager as consumer
- Manual challenge testing

⏳ **Nice to Have:**
- Chainlink Automation (can add later)
- Automated monitoring
- Batch processing

### Integration Timeline

1. **Day 1:** Create subscriptions, write Functions code
2. **Day 2:** Deploy contracts, add consumers
3. **Day 3:** Test manual challenges
4. **Day 4:** Implement Automation logic
5. **Day 5:** Register Automation, test automated flow

**The protocol works without Automation** - challengers can open challenges manually. Automation just makes it trustless and continuous.

---

## Resources

- [Chainlink Functions Docs](https://docs.chain.link/chainlink-functions)
- [Chainlink Automation Docs](https://docs.chain.link/chainlink-automation)
- [Avalanche Network Config](https://docs.chain.link/chainlink-functions/supported-networks)
- [Functions Playground](https://functions.chain.link/playground)

---

## Next Steps

1. Review and customize `functions-source.js` for your needs
2. Test the Functions code in the playground
3. Deploy contracts following `DEPLOYMENT.md`
4. Follow this guide to integrate Chainlink services
5. Test manually before enabling Automation

Good luck! 🚀
