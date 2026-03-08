# Deployment Guide

Full step-by-step guide for deploying the API Integrity Protocol to Avalanche Fuji testnet.

---

## Prerequisites

### 1. Install Foundry

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### 2. Install dependencies

```bash
cd contracts
forge install
```

### 3. Get testnet funds

- **Fuji AVAX** (gas): https://faucet.avax.network
- **Fuji USDC** (for staking + testing): https://faucet.circle.com — select Avalanche Fuji, USDC

---

## Environment Setup

```bash
cp .env.example .env
```

Fill in `.env`:

```bash
# Your deployer/admin wallet
ADMIN=0xYourAddress
TREASURY=0xYourTreasuryAddress
PRIVATE_KEY=0xYourPrivateKey

# Leave as-is for Fuji testnet
AVALANCHE_FUJI_RPC_URL=https://api.avax-test.network/ext/bc/C/rpc
USDC=0x5425890298aed601595a70AB815c96711a31Bc65

# Enable MockUSDC for testnet (recommended)
DEPLOY_MOCK_USDC=true

# Chainlink (Fuji values — leave CL_SUB_ID=0 until Step 4)
CL_ROUTER=0xA9d587a00A31A52Ed70D6026794a8FC5E2F5dCb0
CL_DON_ID=0x66756e2d6176616c616e6368652d66756a692d31000000000000000000000000
CL_SUB_ID=0

# Protocol parameters (defaults are fine for testnet)
MINIMUM_STAKE=1000000000     # 1,000 USDC
TREASURY_BP=200              # 2% protocol cut (max 300)
PROTOCOL_SLASH_BP=1000       # 10% of slash to protocol treasury
WITHDRAW_COOLDOWN=604800     # 7 days

# Snowtrace API key for contract verification
SNOWTRACE_API_KEY=your_key_here
```

---

## Step 1 — Build

```bash
forge build
```

All contracts should compile with no errors.

---

## Step 2 — Deploy Protocol

```bash
source .env

forge script script/DeployAll.s.sol \
  --rpc-url $AVALANCHE_FUJI_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  -vvvv
```

The script will deploy in order:

| # | Contract | Notes |
|---|---|---|
| 1 | `MockUSDC` | Only if `DEPLOY_MOCK_USDC=true` |
| 2 | `MockUSDCSwap` | Only if `DEPLOY_MOCK_USDC=true`. Grants itself MINTER_ROLE on MockUSDC |
| 3 | `APIIntegrityRegistry` | Layer 0 — endpoint registry |
| 4 | `StakeManager` | Layer 0 — provider bond management |
| 5 | `ChallengeManager` | Layer 0 — Chainlink Functions integrity verification |
| 6 | `APIRegistryFactory` | Layer 1 — deploys vault + splitter pairs per provider |

**Save the output addresses.** Example output:

```
Mock Tokens:
  MockUSDC:      0xAbc...
  MockUSDCSwap:  0xDef...

Layer 0 — Security:
  Registry:          0x...
  StakeManager:      0x...
  ChallengeManager:  0x...

Layer 1 — Revenue:
  Factory:           0x...
```

---

## Step 3 — Chainlink Functions Subscription

The `ChallengeManager` needs a funded Chainlink Functions subscription to verify endpoint integrity.

1. Go to https://functions.chain.link and connect your wallet (switch to Fuji)
2. Click **Create Subscription**
3. Fund with LINK — minimum 5 LINK recommended
   - Fuji LINK faucet: https://faucets.chain.link/fuji
4. Add `ChallengeManager` as a consumer using its deployed address
5. Note the **Subscription ID**

Update `ChallengeManager` with the subscription ID:

```bash
cast send $CHALLENGE_MANAGER_ADDRESS \
  "setSubscriptionId(uint64)" $CL_SUB_ID \
  --rpc-url $AVALANCHE_FUJI_RPC_URL \
  --private-key $PRIVATE_KEY
```

Or redeploy with `CL_SUB_ID` set in `.env`.

---

## Step 4 — Register a Provider (Demo Flow)

This is the flow a provider runs after the protocol is deployed.

### End-to-end payment flow

```
x402 client pays → splitter address (payTo in x402 server)
  → splitter.distribute()
      ├── protocolTreasuryBp  →  protocol treasury  (USDC)
      ├── providerTreasuryBp  →  provider treasury  (USDC, optional)
      └── remainder           →  ProviderRevenueVault (USDC, raises share price)

ProviderRevenueVault
  └── vault share holders redeem shares for proportional USDC
```

The **splitter address** (deployed in step 4c) is what goes into `payTo` in your x402 server config — not your wallet. Every payment automatically splits and routes without any manual action.

The **registry** (steps 4d) is the on-chain record that challengers use to verify your endpoint. The `integrityHash` stored there is what Chainlink Functions checks against your live 402 response when a challenge is opened.

```
deployProvider()      → vault + splitter deployed, splitter address known
registerProvider()    → splitter address stored in registry
registerEndpoint()    → integrity hash stored in registry
x402 server payTo     → splitter address
```

---

### 4a. Get MockUSDC (if using mock)

Option A — swap real Fuji USDC for MockUSDC:
```bash
# Approve swap contract
cast send $REAL_USDC_ADDRESS \
  "approve(address,uint256)" $MOCK_USDC_SWAP_ADDRESS 1000000000 \
  --rpc-url $AVALANCHE_FUJI_RPC_URL \
  --private-key $PROVIDER_KEY

# Swap 1,000 USDC in
cast send $MOCK_USDC_SWAP_ADDRESS \
  "swapIn(uint256)" 1000000000 \
  --rpc-url $AVALANCHE_FUJI_RPC_URL \
  --private-key $PROVIDER_KEY
```

Option B — admin mints MockUSDC directly:
```bash
cast send $MOCK_USDC_ADDRESS \
  "mint(address,uint256)" $PROVIDER_ADDRESS 2000000000 \
  --rpc-url $AVALANCHE_FUJI_RPC_URL \
  --private-key $PRIVATE_KEY
```

### 4b. Stake bond

```bash
# Approve StakeManager
cast send $MOCK_USDC_ADDRESS \
  "approve(address,uint256)" $STAKE_MANAGER_ADDRESS 1000000000 \
  --rpc-url $AVALANCHE_FUJI_RPC_URL \
  --private-key $PROVIDER_KEY

# Stake 1,000 USDC
cast send $STAKE_MANAGER_ADDRESS \
  "stake(uint256)" 1000000000 \
  --rpc-url $AVALANCHE_FUJI_RPC_URL \
  --private-key $PROVIDER_KEY
```

### 4c. Deploy vault + splitter via factory

`deployProvider()` parameters:

| Parameter | Description |
|---|---|
| `vaultName` | ERC20 name for vault shares (e.g. `"My API Revenue Vault"`) |
| `vaultSymbol` | ERC20 symbol (e.g. `"rvAPI"`) |
| `genesisShares` | Shares to mint at genesis. Recommended: `1000000000000` (1M shares at 6 dec). Set 0 to skip. |
| `genesisRecipient` | Who receives genesis shares — your wallet, IAO contract, multisig, etc. |
| `genesisDeposit` | Optional USDC to seed the vault at genesis (for APIs with existing revenue). Set 0 for new APIs. |
| `providerTreasury` | Address for direct USDC income. Use zero address if `providerTreasuryBp == 0`. |
| `providerTreasuryBp` | Provider's USDC cut in basis points. 0 routes all non-protocol revenue to vault. |

```bash
# Optional: approve factory for genesis deposit (skip if genesisDeposit=0)
cast send $MOCK_USDC_ADDRESS \
  "approve(address,uint256)" $FACTORY_ADDRESS 500000000 \
  --rpc-url $AVALANCHE_FUJI_RPC_URL \
  --private-key $PROVIDER_KEY

# Deploy vault + splitter
cast send $FACTORY_ADDRESS \
  "deployProvider(string,string,uint256,address,uint256,address,uint256)" \
  "My API Revenue Vault" \
  "rvAPI" \
  1000000000000 \
  $PROVIDER_ADDRESS \
  500000000 \
  $PROVIDER_TREASURY_ADDRESS \
  500 \
  --rpc-url $AVALANCHE_FUJI_RPC_URL \
  --private-key $PROVIDER_KEY
```

Read vault and splitter addresses from the `ProviderDeployed` event in the tx receipt.

### 4d. Register provider and endpoint

```bash
# Register provider
cast send $REGISTRY_ADDRESS \
  "registerProvider(string,address,address)" \
  "ipfs://QmYourMetadataHash" \
  $PROVIDER_ADDRESS \
  $SPLITTER_ADDRESS \
  --rpc-url $AVALANCHE_FUJI_RPC_URL \
  --private-key $PROVIDER_KEY

# Compute integrity hash off-chain (keccak256 of your 402 response metadata)
# Then register endpoint
cast send $REGISTRY_ADDRESS \
  "registerEndpoint(uint256,string,string,bytes32)" \
  1 \
  "https://api.example.com/v1/pricing" \
  "GET" \
  $INTEGRITY_HASH \
  --rpc-url $AVALANCHE_FUJI_RPC_URL \
  --private-key $PROVIDER_KEY
```

---

## Step 5 — Verify Deployment

```bash
# Provider count
cast call $REGISTRY_ADDRESS "providerCount()" \
  --rpc-url $AVALANCHE_FUJI_RPC_URL

# Provider stake
cast call $STAKE_MANAGER_ADDRESS \
  "stakes(address)" $PROVIDER_ADDRESS \
  --rpc-url $AVALANCHE_FUJI_RPC_URL

# Vault share price (0 before any revenue)
cast call $VAULT_ADDRESS "sharePrice()" \
  --rpc-url $AVALANCHE_FUJI_RPC_URL

# Factory protocol cut
cast call $FACTORY_ADDRESS "protocolTreasuryBp()" \
  --rpc-url $AVALANCHE_FUJI_RPC_URL
```

---

## Step 6 — Simulate Revenue (Demo)

```bash
# Send MockUSDC directly to splitter (simulates an x402 payment)
cast send $MOCK_USDC_ADDRESS \
  "transfer(address,uint256)" $SPLITTER_ADDRESS 10000000 \
  --rpc-url $AVALANCHE_FUJI_RPC_URL \
  --private-key $PRIVATE_KEY

# Distribute — routes to protocol treasury, provider treasury, and vault
cast send $SPLITTER_ADDRESS \
  "distribute()" \
  --rpc-url $AVALANCHE_FUJI_RPC_URL \
  --private-key $PRIVATE_KEY

# Check vault share price has risen
cast call $VAULT_ADDRESS "sharePrice()" \
  --rpc-url $AVALANCHE_FUJI_RPC_URL
```

---

## Challenge Flow

```bash
# Approve challenge fee (100 USDC default)
cast send $MOCK_USDC_ADDRESS \
  "approve(address,uint256)" $CHALLENGE_MANAGER_ADDRESS 100000000 \
  --rpc-url $AVALANCHE_FUJI_RPC_URL \
  --private-key $CHALLENGER_KEY

# Open challenge — Chainlink Functions verifies live 402 response
cast send $CHALLENGE_MANAGER_ADDRESS \
  "openChallenge(bytes32)" $ENDPOINT_ID \
  --rpc-url $AVALANCHE_FUJI_RPC_URL \
  --private-key $CHALLENGER_KEY

# Chainlink resolves automatically (~60s)
# Valid   → challenger refunded, endpoint lastCheckedAt updated
# Invalid → provider slashed 20%, challenger rewarded 90% of slash
```

---

## Mainnet Checklist

- [ ] Security audit completed
- [ ] `DEPLOY_MOCK_USDC=false`
- [ ] `USDC=0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E` (Avalanche mainnet USDC)
- [ ] `AVALANCHE_MAINNET_RPC_URL` set as `--rpc-url`
- [ ] `TREASURY_BP` ≤ 300 (enforced by contract)
- [ ] Chainlink Functions subscription funded with sufficient LINK
- [ ] Admin key secured (multisig recommended)
- [ ] `MINIMUM_STAKE` reviewed relative to expected vault TVL

```bash
forge script script/DeployAll.s.sol \
  --rpc-url $AVALANCHE_MAINNET_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

---

## Troubleshooting

**`forge build` fails**
- Run `forge install` to ensure all dependencies are present

**Verification fails on Snowtrace**
```bash
forge verify-contract \
  --chain-id 43113 \
  --compiler-version v0.8.30 \
  --etherscan-api-key $SNOWTRACE_API_KEY \
  --watch \
  $CONTRACT_ADDRESS \
  src/APIIntegrityRegistry.sol:APIIntegrityRegistry
```

**Chainlink challenge times out**
- Confirm `ChallengeManager` is added as a consumer on the subscription
- Confirm subscription has LINK balance > 2
- Check Functions source code is correctly uploaded

**`distribute()` reverts with "no balance"**
- Send USDC to the splitter address first — it only distributes what it holds

**`deployProvider()` reverts**
- If `genesisDeposit > 0`, ensure factory is approved for that USDC amount first
- If `providerTreasuryBp > 0`, ensure `providerTreasury != address(0)`
- Combined `protocolTreasuryBp + providerTreasuryBp` must be < 10,000
