# HTTPayer Provider CLI

All commands run from `contracts/test/`:

```bash
cd contracts/test
```

Requires a `.env` file in `contracts/test/` with:

```env
GATEWAY_URL=https://api.avax-test.network/ext/bc/C/rpc
PRIVATE_KEY=0x...
PROVIDER_PRIVATE_KEY=0x...   # optional, falls back to PRIVATE_KEY
ETHERSCAN_API_KEY=...         # for contract verification on Snowscan
X402_ENDPOINT=http://...      # your live server URL (used by register-endpoint)
```

---

## Full Provider Setup Flow

### 1. Check status

```bash
uv run python cli.py status
```

Shows your signer address, USDC balance, current stake, and how many providers are deployed.

---

### 2. Stake

The registry requires a minimum USDC stake before you can register as a provider. This command checks your current stake and automatically tops it up if needed.

```bash
uv run python cli.py stake
```

- If already staked to the minimum → prints `✓ stake sufficient` and exits
- If short → approves the StakeManager and stakes the difference

---

### 3. Deploy provider

Deploys your revenue vault + splitter in a single transaction, registers you in the APIIntegrityRegistry, and submits the contracts for verification on Snowscan.

```bash
uv run python cli.py deploy-provider \
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
  uv run python cli.py register-endpoint \
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

### 5. Register endpoint

Fetches the x402 payment metadata from your live server, computes the integrity hash, and registers the endpoint on-chain. The `--splitter` flag is used to validate that the server's `payTo` matches — it will error before submitting if there's a mismatch.

```bash
uv run python cli.py register-endpoint \
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
uv run python cli.py register-endpoint \
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

## Reference

### All flags

```
deploy-provider
  --name                Vault token name               (required)
  --symbol              Vault token symbol             (required)
  --vault-bp            Basis points to vault          (default: 9800)
  --revenue-share-bp    Basis points to revenue share  (default: 0)
  --rs-shares           Genesis shares for RS contract (required if --revenue-share-bp > 0)
  --rs-recipient        RS genesis recipient           (default: signer)
  --genesis-shares      Vault genesis shares to mint   (default: 0)
  --genesis-deposit     USDC raw units to seed vault   (default: 0)
  --genesis-recipient   Vault genesis recipient        (default: signer)
  --provider-treasury   Address for remainder direct cut
  --metadata-uri        Metadata URI for registry

register-endpoint
  --provider-id         Registry provider ID           (required)
  --splitter            Splitter address               (required)
  --url                 Full endpoint URL              (required)
  --method              HTTP method                    (default: GET)
  --hash                Pre-computed integrity hash    (skips live fetch)
```

### USDC raw units

All USDC amounts use 6 decimals:

| Human | Raw units |
|-------|-----------|
| 0.001 USDC | 1,000 |
| 1 USDC | 1,000,000 |
| 10 USDC | 10,000,000 |
