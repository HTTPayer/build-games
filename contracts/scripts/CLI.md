# Composed Protocol CLI

Interactive shell and one-shot CLI for provider operations on Avalanche Fuji.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| **Python 3.10+** | Check with `python --version` |
| **uv** | Install: `pip install uv` or `curl -Lsf https://astral.sh/uv/install.sh \| sh` |
| **Avalanche Fuji RPC** | Free endpoint: `https://api.avax-test.network/ext/bc/C/rpc` — or use an Alchemy/Infura Fuji URL for higher rate limits |
| **Funded wallet** | You need testnet AVAX (for gas) and testnet USDC (for staking + challenge fees) on Fuji |
| **Testnet AVAX** | Fuji faucet: https://faucet.avax.network/ |
| **Testnet USDC** | Ask the admin to mint via `admin_cli.py mint-usdc` |

---

## Installation

All commands run from `contracts/scripts/`:

```bash
cd contracts/scripts
```

### 1. Install dependencies

```bash
uv sync
```

This installs all Python dependencies and registers the `composed` entry point in the local virtual environment.

### 2. Create your `.env` file

```bash
cp .env.sample .env
```

Edit `.env` with your credentials:

```env
# Required
GATEWAY_URL=https://api.avax-test.network/ext/bc/C/rpc
PRIVATE_KEY=0x...

# Optional — falls back to PRIVATE_KEY if not set
PROVIDER_PRIVATE_KEY=0x...

# Optional — for contract verification on Snowscan
ETHERSCAN_API_KEY=...
```

To use a different signer, update `PROVIDER_PRIVATE_KEY` in `.env` or pass it inline:

```bash
PROVIDER_PRIVATE_KEY=0x... composed status
```

### 3. Verify the installation

```bash
composed status
```

You should see your signer address, USDC balance, and current stake.

---

## Interactive shell

Running `composed` with no arguments opens an interactive REPL:

```bash
composed
```

```
Composed Protocol CLI  —  signer: 0xYourAddress
Type a command or 'help'. Press Ctrl-C or type 'exit' to quit.

composed> status
composed> vault
composed> splitter --distribute
composed> exit
```

All commands below work identically in the shell and as one-shot CLI calls.

---

## Full Provider Setup Flow

### 1. Check status

```bash
composed status
```

Shows your signer address, USDC balance, current stake, and stats for all your deployed providers (vault TVL, share price, splitter balance, RS claimable).

---

### 2. Stake

The registry requires a minimum USDC stake before you can register as a provider. This command checks your current stake and automatically tops it up if needed.

```bash
composed stake
```

- If already staked to the minimum → prints `✓ stake sufficient` and exits
- If short → approves the StakeManager and stakes the difference

To unstake (starts a cooldown period):

```bash
composed unstake
composed unstake --amount 10000000   # partial unstake (raw USDC units)
```

To withdraw after cooldown expires:

```bash
composed withdraw
composed withdraw --amount 10000000
```

---

### 3. Deploy provider

Deploys your revenue vault + splitter in a single transaction, registers you in the registry, and submits the contracts for verification on Snowscan.

```bash
composed deploy-provider \
  --name   "Weather API Vault" \
  --symbol "wAPI" \
  --vault-bp 9800
```

**Revenue split** — you set explicit basis points (out of 10,000); the remainder goes directly to your treasury:

| Flag | Description | Default |
|------|-------------|---------|
| `--vault-bp` | % routed to the investor vault | 9800 |
| `--revenue-share-bp` | % routed to revenue share dividends | 0 |
| _(protocol cut)_ | fixed at factory deploy (e.g. 2%) | — |
| _(remainder)_ | goes directly to `--provider-treasury` | auto |

**Example splits** (assuming 2% protocol fee):

```bash
# Vault only — 98% to investors, 0% direct to you
--vault-bp 9800

# Revenue share only — 98% founder dividends
--vault-bp 0 --revenue-share-bp 9800 --rs-shares 1000000000000

# Two-tier — 78% vault + 20% RS, 0% direct
--vault-bp 7800 --revenue-share-bp 2000 --rs-shares 1000000000000

# Three-way — 50% vault + 20% RS + 28% direct to you
--vault-bp 5000 --revenue-share-bp 2000 --rs-shares 1000000000000 \
  --provider-treasury 0xYourAddress
```

**Optional vault seeding** — mint genesis shares and seed with USDC so share price is non-zero before investors deposit:

```bash
--genesis-shares 1000000000000 \   # 1M shares (6 decimals)
--genesis-deposit 1000000           # 1 USDC (raw units)
```

**Output:**

```
  ✓ vault        : 0xABC...
  ✓ splitter     : 0xDEF...
  ✓ provider id  : 1

  ┌─────────────────────────────────────────────────────────┐
  │  Next: update your x402 server                          │
  │  payTo = 0xDEF...                                       │
  └─────────────────────────────────────────────────────────┘

  Then register your endpoints:
  composed register-endpoint \
    --provider-id 1 --splitter 0xDEF... \
    --url <your-endpoint-url>
```

---

### 4. Update your x402 server

Set `payTo` in your server to the **splitter address** printed above.

In `servers/src/server.ts`:

```ts
const payTo = "0xDEF...";  // ← splitter address from deploy-provider
```

Redeploy or restart your server, then confirm it's live before continuing.

---

### 5. Preview the integrity hash (optional)

Before registering, verify what hash your live server will produce:

```bash
composed hash-endpoint --url http://your-server.com/weather
```

This fetches the x402 metadata from the server and prints the hash — no transaction sent.

---

### 6. Register endpoint

Fetches the x402 payment metadata from your live server, computes the integrity hash, and registers the endpoint on-chain. The `--splitter` flag validates that the server's `payTo` matches — it will error before submitting if there's a mismatch.

```bash
composed register-endpoint \
  --provider-id 1 \
  --splitter    0xDEF... \
  --url         http://your-server.com/weather
```

By default uses `GET`. For other methods:

```bash
--method POST
```

**If the server isn't updated yet**, you'll see:

```
ValueError: payTo mismatch — server has '0xOLD...' but expected '0xDEF...'.
  Update your x402 server's payTo to the splitter address first.
```

**To skip the live fetch** and provide a pre-computed hash directly:

```bash
composed register-endpoint \
  --provider-id 1 \
  --splitter    0xDEF... \
  --url         http://your-server.com/weather \
  --hash        0xabc123...
```

**Output:**

```
  ✓ endpointId : 0x7f3a...
```

---

### 7. Update endpoint hash

When you change your x402 payment terms (e.g. new price), the on-chain integrity hash needs to match. This bumps the hash and increments the endpoint version.

```bash
# Re-fetch from the live server automatically
composed update-endpoint --endpoint-id 0x7f3a...

# Or provide the new hash directly
composed update-endpoint --endpoint-id 0x7f3a... --hash 0xnew...
```

If the live hash already matches what's on-chain, the command exits without sending a transaction.

**Output:**

```
  current hash  : 0xold...  (v1)
  new hash      : 0xnew...
  ✓ hash updated to 0xnew...  (v2)
```

---

## Other commands

### Update provider metadata

Update your registry entry's metadata URI, payout address, or splitter address.

```bash
composed update-provider \
  --provider-id 1 \
  --payout   0xNewPayout \
  --splitter 0xNewSplitter \
  --metadata-uri "https://example.com/metadata.json"
```

Omit any flag to keep the existing value.

---

### Open a challenge

Challenge a registered endpoint's integrity. The Chainlink CRE DON independently fetches the endpoint and verifies the hash. A challenge fee (in USDC) is required and is refunded if the endpoint is valid.

```bash
# By endpoint ID
composed challenge --endpoint-id 0x7f3a...

# By URL + provider ID (derives the endpoint ID)
composed challenge \
  --url         http://your-server.com/weather \
  --provider-id 1
```

**Output:**

```
  challenge id : 42
  Check status:  composed challenge-status --id 42
```

---

### Check challenge status

```bash
composed challenge-status --id 42
```

Status is one of `Pending`, `Valid` (endpoint OK), or `Invalid` (provider slashed).

---

### Registry

List all registered providers and their endpoints.

```bash
# All providers + all endpoints
composed registry

# Only endpoints registered by your signer
composed registry --address

# Only endpoints registered by a specific address
composed registry --address 0xABC...
```

---

### Vault inspection

Inspect a vault's state, open deposits, deposit USDC, or redeem shares. `--vault` is auto-detected if you have one deployed provider.

```bash
# Read-only inspection (auto-detect)
composed vault

# Explicit address
composed vault --vault 0xABC...

# Open deposits (owner only)
composed vault --open-deposits

# Deposit 10 USDC
composed vault --deposit 10000000

# Redeem 5 shares
composed vault --redeem 5000000
```

### Revenue share inspection

Inspect a revenue share contract — supply, lifetime EPS, APR, and your claimable USDC. `--rs` is auto-detected if you have one deployed.

```bash
# Read-only (auto-detect)
composed revenue-share

# Explicit address
composed revenue-share --rs 0xGHI...

# Claim all accrued USDC dividends
composed revenue-share --claim
```

---

### Splitter inspection

Inspect a splitter's routing config and pending balance, or trigger a distribution.

If you only have one deployed provider, `--splitter` can be omitted and the address is auto-detected from on-chain events.

```bash
# Inspect only (auto-detect splitter)
composed splitter

# Inspect only (explicit address)
composed splitter --splitter 0xDEF...

# Distribute pending USDC to all buckets
composed splitter --distribute
composed splitter --splitter 0xDEF... --distribute
```

If you have multiple deployed providers the command will list them and ask you to specify one explicitly.

---

## Reference

### All flags

```
stake
  (no flags)

unstake
  --amount    Raw USDC units to unstake (default: full stake)

withdraw
  --amount    Raw USDC units to withdraw (default: full stake)

deploy-provider
  --name                Vault token name               (required)
  --symbol              Vault token symbol             (required)
  --vault-bp            Basis points to vault          (default: 9800)
  --revenue-share-bp    Basis points to revenue share  (default: 0)
  --rs-shares           Genesis shares for RS contract
  --rs-recipient        RS genesis recipient           (default: signer)
  --genesis-shares      Vault genesis shares to mint   (default: 0)
  --genesis-deposit     USDC raw units to seed vault   (default: 0)
  --genesis-recipient   Vault genesis recipient        (default: signer)
  --provider-treasury   Address for remainder direct cut
  --metadata-uri        Metadata URI for registry

hash-endpoint
  --url                 Full endpoint URL              (required)
  --method              HTTP method                    (default: GET)

register-endpoint
  --provider-id         Registry provider ID           (required)
  --splitter            Splitter address               (required)
  --url                 Full endpoint URL              (required)
  --method              HTTP method                    (default: GET)
  --hash                Pre-computed integrity hash    (skips live fetch)

update-endpoint
  --endpoint-id         Endpoint ID (bytes32 hex)      (required)
  --hash                New integrity hash             (omit to re-fetch live)

update-provider
  --provider-id         Provider ID to update          (required)
  --metadata-uri        New metadata URI               (keep existing if omitted)
  --payout              New payout address             (keep existing if omitted)
  --splitter            New splitter address           (keep existing if omitted)

challenge
  --endpoint-id         Endpoint ID (bytes32 hex)      (mutually exclusive with --url)
  --url                 Endpoint URL                   (requires --provider-id)
  --provider-id         Provider ID                    (used with --url)
  --method              HTTP method                    (default: GET)

challenge-status
  --id                  Challenge ID                   (required)

vault
  --vault               Vault address                  (auto-detected if omitted)
  --open-deposits       Call openDeposits() (owner only)
  --deposit             Deposit USDC raw units
  --redeem              Redeem shares (raw units)

revenue-share
  --rs                  Revenue share address          (auto-detected if omitted)
  --claim               Claim all accrued USDC dividends

splitter
  --splitter            Splitter address               (auto-detected if omitted)
  --distribute          Call distribute() if balance > 0

registry
  --address             Filter by address (omit = all, flag alone = signer)

status
  (no flags)
```

### USDC raw units

All USDC amounts use 6 decimals:

| Human | Raw units |
|-------|-----------|
| 0.001 USDC | 1,000 |
| 1 USDC | 1,000,000 |
| 10 USDC | 10,000,000 |
| 100 USDC | 100,000,000 |
