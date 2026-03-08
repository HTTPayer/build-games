# API Integrity Protocol — CRE Workflow

Chainlink CRE workflow that verifies registered API endpoints are serving honest
x402 payment metadata. Replaces Chainlink Functions (which can't read 4xx response
headers) with a full compute environment that has unrestricted HTTP access.

## How it works

```
Challenger
 |  approve(USDC) + openChallenge(endpointId)
 v
ChallengeManager                          Avalanche Fuji
 |  escrows challengeFee
 |  emits ChallengeOpened(id, endpointId, path, method, integrityHash)
 v
Chainlink CRE — log trigger
 |  each DON node independently fetches the endpoint
 |  reads PAYMENT-REQUIRED header (x402 v2) or body (v1)
 |  computes SHA-256 of { amount, asset, network, payTo, url }
 |  compares with on-chain integrityHash
 v
CRE consensus — all nodes must agree on result
 v
ChallengeManager.onReport()               Avalanche Fuji
 |  result=1 (valid):   provider receives challengeFee
 |  result=0 (invalid): provider slashed, challenger refunded
 v
ChallengeResolved event
```

## Repository layout

```
onchain-router/
  project.yaml                   CRE project config (RPCs, experimental chains)
  integrity-workflow/
    main.ts                      CRE workflow — log trigger + hash verification
    workflow.yaml                Workflow targets (staging / production)
    config.staging.json          Addresses and chain config for staging
    package.json
    tsconfig.json
```

---

## Setup

### 1. Install dependencies

```bash
cd onchain-router/integrity-workflow
bun install
```

### 2. Deploy contracts

From `contracts/`:

```bash
# Set env vars
export ADMIN=0x...
export TREASURY=0x...
export CRE_FORWARDER=0x...       # CRE forwarder on Avalanche Fuji (see below)
export USDC=0x5425890298aed601595a70AB815c96711a31Bc65
export DEPLOY_MOCK_USDC=true
export MINIMUM_STAKE=10000000    # 10 USDC
export TREASURY_BP=200
export PROTOCOL_SLASH_BP=2000
export WITHDRAW_COOLDOWN=86400
export AVALANCHE_FUJI_RPC_URL=https://avax-fuji.g.alchemy.com/v2/...
export PRIVATE_KEY=0x...

forge script script/DeployAll.s.sol \
  --rpc-url $AVALANCHE_FUJI_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

Note the deployed `ChallengeManager` address from the output.

### 3. Get the CRE forwarder address for Fuji

The CRE forwarder is the address that calls `onReport()` on your contract.
Get it from:
- Chainlink hackathon support channel, or
- `cre chain list` (if Fuji is in the supported chains list)

Set it in `ChallengeManager` via:
```bash
# contracts/test/
python -c "from challenge_manager import set_forwarder; set_forwarder('0xForwarderAddress')"
```

Or pass it at deploy time via `CRE_FORWARDER` env var.

### 4. Fill in config

Edit `integrity-workflow/config.staging.json`:
```json
{
  "challengeManagerAddress": "0x<deployed ChallengeManager>",
  "chainSelectorName": "avalanche-testnet-fuji",
  "gasLimit": "500000"
}
```

Edit `project.yaml` — fill in the `forwarder` under `experimental-chains` if Fuji
is not yet an official CRE chain:
```yaml
experimental-chains:
  - chain-selector: 14767482510784806043
    rpc-url: "https://avax-fuji.g.alchemy.com/v2/..."
    forwarder: "0x<CRE forwarder on Fuji>"
```

---

## Running a challenge end-to-end

### Step 1 — Register a provider and endpoint

```bash
cd contracts/test
uv run python api_registry_factory.py
```

Note the `endpointId` printed after `registerEndpoint`.

### Step 2 — Open a challenge and get the tx hash

```bash
uv run python challenge_manager.py
```

Uncomment in `__main__`:
```python
cid = open_challenge("0x<endpointId>")
```

From the output, note the transaction hash printed by `send_tx`:
```
[openChallenge] tx:  https://testnet.snowtrace.io/tx/0xABC...
```

Copy `0xABC...` — this is the tx hash you pass to the CRE simulator.

### Step 3 — Simulate the CRE workflow

From `onchain-router/`:

```bash
cre workflow simulate integrity-workflow \
  --non-interactive \
  --trigger-index 0 \
  --evm-tx-hash 0xABC... \
  --evm-event-index 0 \
  --target staging-settings \
  --broadcast
```

`--evm-event-index 0` selects the first log in the transaction (the `ChallengeOpened` event).
If there are multiple logs, find the right index from the Snowtrace tx page.

### Step 4 — Check the result

```bash
uv run python challenge_manager.py
# or
python -c "from challenge_manager import print_challenge; print_challenge(<cid>)"
```

Status transitions:
- `Pending` → waiting for CRE
- `Valid`   → hashes matched, provider was honest, challenger lost fee
- `Invalid` → hash mismatch, provider was slashed, challenger refunded

---

## Register the workflow (production / live trigger)

Once the simulation works, register the workflow so it runs automatically:

```bash
cd onchain-router/integrity-workflow

# Register and activate
cre workflow deploy --target staging-settings
```

After registration, any `openChallenge()` call on-chain will automatically
trigger the DON to run the workflow and call back `onReport()`.

---

## Dry-run the hash locally (before challenging)

Before opening a challenge, verify the hash matches using `dry-run.js`:

```bash
cd contracts
node chainlink/dry-run.js <endpoint-url> <stored-integrityHash>
```

Should print `PASS - hash matches`. If it prints `FAIL`, the stored hash is
stale — re-register the endpoint before challenging.
