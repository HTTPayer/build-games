# Composed Protocol

> Make API revenue investable for the first time — with onchain enforcement, not trust.

Built for the **Avalanche Build Games 2026 Hackathon** on **Avalanche Fuji** testnet.

---

## Market Moment

On February 11, 2026, Stripe launched native support for the [x402 protocol](https://docs.stripe.com/payments/machine/x402) — enabling AI agents to pay for API calls autonomously using USDC, with no accounts, no API keys, and no human in the loop. CoinGecko followed immediately with x402-powered endpoints at $0.01 USDC per request, accessible to any autonomous agent.

Stripe co-founder John Collison described what comes next:

> *"A torrent of AI agentic commerce powered by stablecoins."*

Stripe is building the payment settlement layer. **This protocol builds what comes after settlement** — turning the onchain revenue those payments generate into tokenized, investable, composable financial instruments.

The x402 market is no longer theoretical. The infrastructure question is now: once machine payments are flowing onchain at scale, what do you do with that revenue stream?

---

## The Problem

AI agents are generating a new category of API revenue — per-call, machine-to-machine, settled in stablecoins. That revenue has the same problem all API revenue has always had:

- **Invisible** — trapped inside companies, unobservable from outside
- **Illiquid** — you cannot invest in an API's revenue stream
- **Unverifiable** — you have to trust reported numbers

Onchain settlement via [x402](https://x402.org) flips all three. Every payment becomes a verifiable, auditable, programmable event. API revenue has always existed — it just was never investable before. x402 makes it routable. This protocol makes it investable.

---

## Architecture

The protocol is built in three composable layers. Each layer is independently useful and can be adopted without the layers above it.

```
┌─────────────────────────────────────────────────────────────────────┐
│  LAYER 2 — Financial Applications                                   │
│  Stablecoins · Futures · Index · IAO · CDP                          │
├─────────────────────────────────────────────────────────────────────┤
│  LAYER 1 — Revenue Tokenization                                     │
│  ProviderRevenueShare (royalty)                                     │
│  ProviderRevenueSplitter                                            │
├─────────────────────────────────────────────────────────────────────┤
│  LAYER 0 — Infrastructure & Enforcement                             │
│  APIIntegrityRegistry · StakeManager · ChallengeManager             │
└─────────────────────────────────────────────────────────────────────┘
                              ▲
                    x402 API payments (USDC)
```

---

## Layer 0 — Infrastructure & Enforcement

Permissionless cryptoeconomic enforcement of API payment integrity. Providers stake USDC as a bond; anyone can challenge an endpoint; **Chainlink CRE** (Compute Runtime Environment) independently fetches the live API, reads the x402 payment header, computes the integrity hash, and reports the result onchain.

| Contract | Description |
|---|---|
| `APIIntegrityRegistry` | Registers providers and API endpoints with integrity hashes. Tracks last-verified timestamps. |
| `StakeManager` | Providers bond USDC as collateral. Handles staking, slashing (20% default), and cooldown withdrawals. |
| `ChallengeManager` | Permissionless challenge flow. Listens for `ChallengeOpened` events via a Chainlink CRE log trigger. Each DON node fetches the endpoint independently, computes SHA-256 of the x402 metadata, and reaches consensus before calling `onReport()`. Invalid → provider slashed, challenger rewarded. |
| `APIRegistryFactory` | Deploys a matched `ProviderRevenueVault` + `ProviderRevenueSplitter` in one transaction. Handles genesis mint and ownership transfer. |

### Challenge flow

```
Challenger approves USDC → openChallenge(endpointId)
        ↓
ChallengeManager emits ChallengeOpened(id, endpointId, path, method, integrityHash)
        ↓
Chainlink CRE DON — each node independently:
  fetches endpoint → reads PAYMENT-REQUIRED header (x402 v2) or body (v1)
  computes SHA-256({ amount, asset, network, payTo, url })
  compares with on-chain integrityHash
        ↓
DON consensus → ChallengeManager.onReport(metadata, report)
        ↓
result=1 (Valid):   provider receives challengeFee
result=0 (Invalid): provider slashed, challenger refunded + slash share
```

---

## Layer 1 — Revenue Tokenization

The core primitive. Every x402 payment flows through the splitter into one or both tokenized revenue instruments. The provider chooses the split at deployment — it cannot be changed afterward.

| Contract | Description |
|---|---|
| `ProviderRevenueVault` | ERC4626 vault. Fixed share supply after genesis mint. Revenue arrives via direct USDC transfer, increasing `totalAssets()` without minting new shares — share price rises with every API call. To exit, holders redeem shares for USDC. |
| `ProviderRevenueShare` | Fixed-supply ERC20 royalty token. Represents a perpetual, proportional claim on all future revenue paid as USDC dividends. Holders call `claim()` to collect — shares are never burned. To exit, holders sell on a secondary market. Price reflects expected *future* revenue. |
| `ProviderRevenueSplitter` | Routes x402 USDC across: protocol treasury, optional provider treasury (direct operating income), optional revenue share contract, and the vault. All splits immutable after deployment. |

### Two instruments, two investment models

```
ProviderRevenueVault   — ERC4626, price appreciation model
                         share price = totalAssets / totalSupply
                         yield realised on redeem

ProviderRevenueShare   — ERC20 royalty trust model
                         revenuePerShare accumulator, claim() anytime
                         shares never burned — sell to exit
                         market price reflects future revenue expectations
```

Both can be deployed simultaneously. The provider sets `vaultBp` and `revenueShareBp` at deploy time — the splitter routes accordingly.

### Revenue split

```
protocolTreasuryBp   →  protocol treasury      (USDC)   [fixed by protocol]
providerTreasuryBp   →  provider treasury      (USDC)   [optional direct income]
revenueShareBp       →  ProviderRevenueShare   (USDC dividends to holders)
vaultBp              →  ProviderRevenueVault   (share price appreciation)
```

`vaultBp = 10,000 − protocolTreasuryBp − providerTreasuryBp − revenueShareBp`

### Genesis mint

Both contracts mint a fixed supply once at factory deployment with no USDC backing. The `genesisRecipient` can be any address: developer wallet, multisig, IAO contract, vesting contract. Share price / revenue-per-share both start at `0` and grow with API usage.

---

## Layer 2 — Financial Applications

Once vault shares exist and their price is driven by real API revenue, they become composable inputs for a full DeFi financial stack. All Layer 2 contracts are optional extensions.

### Stablecoins

| Contract | Mechanism | Yield Source |
|---|---|---|
| `RevShareStable` | Vault shares in / vault shares out. Exchange rate = vault USDC value / stable supply. | Direct vault share appreciation |
| `yAPIUSD` | USDC in / USDC out. Provider seeds contract with vault shares as the yield engine. | Vault share appreciation via treasury deposits |
| `wcAPIUSD` | USDC in / USDC out. Provider borrows deposited USDC against vault share collateral. Interest accrues to exchange rate. | Loan interest paid by provider, funded by API revenue |
| `APIUSD` | CDP stablecoin. Lock vault shares as collateral, mint APIUSD at 70% LTV. Liquidation at 80%. | — |

### Other instruments

**Wrappers:**

| Contract | Description |
|---|---|
| `WrappedRevenueShare` | ERC-20 wrapper for RS tokens. 1 wRS = 1 RS + accrued USDC yield. Deposit RS → receive wRS. USDC dividends accumulate via `harvest()`; holders redeem for RS + USDC. Chainlink Automation compatible + built-in price feed. |

**Other:**

| Contract | Description |
|---|---|
| `InitialAPIOffering` | Presell future API revenue before launch. Backers fund development; IAO tokens earn vault shares via MasterChef accumulator as revenue accrues. |
| `APIYieldIndex` | Weighted basket of vault shares from multiple providers, tradable as a single ERC20. Composable as DeFi collateral. |
| `APIRevenueFuture` | Revenue forward notes. Provider posts vault shares as collateral, receives purchase price USDC upfront. ⚠️ Proof of concept. |

---

## Repository layout

```
build-games/
├── contracts/                        Foundry project
│   ├── src/                         Solidity contracts
│   │   ├── ProviderRevenueShare.sol      Layer 1 - Revenue token (claim-based)
│   │   ├── ProviderRevenueShareV2.sol    Layer 1 - Revenue token (rebasing)
│   │   ├── ProviderRevenueSplitter.sol   Layer 1 - Routes revenue to tokens
│   │   ├── APIIntegrityRegistry.sol     Layer 0 - Endpoint registry
│   │   ├── StakeManager.sol             Layer 0 - Staking/bonding
│   │   ├── ChallengeManager.sol         Layer 0 - Challenge resolution
│   │   ├── APIRegistryFactory.sol        Layer 0 - Factory deployment
│   │   └── l2/                          Layer 2 - Financial applications
│   │       ├── WrappedRevenueShare.sol  wRS wrapper (1:1 mint)
│   │       ├── APIYieldIndex.sol        Index token
│   │       ├── APIRevenueStable.sol     Stablecoin
│   │       ├── RevShareStable.sol       Stablecoin
│   │       ├── APIUSD.sol               CDP stablecoin
│   │       ├── yAPIUSD.sol              Yield stablecoin
│   │       ├── wcAPIUSD.sol             Credit stablecoin
│   │       ├── InitialAPIOffering.sol   IAO
│   │       └── APIRevenueFuture.sol     Futures
│   ├── script/                       Deploy scripts
│   │   ├── DeployAll.s.sol             Deploy full protocol
│   │   ├── DeployWrappedRevenueShare.s.sol
│   │   └── Deploy*.s.sol               Individual L2 deployments
│   ├── broadcast/                    Deployed addresses
│   │   ├── DeployAll.s.sol/           Layer 0+1 deployments
│   │   └── DeployWrappedRevenueShare.s.sol/
│   ├── composed/                     Python SDK
│   │   ├── client.py                  ComposedClient
│   │   ├── _abis.py
│   │   └── _addresses.py
│   └── scripts/                      Python tooling
│       ├── cli.py                     Provider CLI (`composed`)
│       ├── admin_cli.py
│       ├── cre_watcher.py             Auto-settles challenges
│       ├── challenger_watcher.py     Monitors endpoints
│       ├── revenue_splitter_trigger.py  Cron job for distribution
│       └── utils.py
│
├── analytics/                       Protocol analytics
│   ├── pyproject.toml
│   ├── src/
│   │   ├── analytics_indexer.py
│   │   ├── analytics_api.py
│   │   ├── analytics_dashboard.py
│   │   └── utils.py
│   └── README.md
│
├── challenger_watcher/              Challenger bot
│   ├── pyproject.toml
│   ├── challenger_watcher.py
│   └── README.md
│
├── cre/                             Chainlink CRE workflow
│   ├── project.sample.yaml
│   ├── project.yaml
│   ├── .env
│   └── integrity-workflow/
│       ├── main.ts
│       ├── workflow.yaml
│       └── config.staging.json
│
├── servers/                         x402 server examples
│   └── src/server.ts
│
├── scripts/                         Standalone scripts
│   └── revenue_splitter_trigger.py  Revenue distribution cron
│
└── docs/
    ├── analytics.md
    ├── frontend-provider-registration.md
    └── OVERVIEW.md
```

---

## Deployed contracts (Avalanche Fuji — chain ID 43113)

### Layer 0 + 1 (Core Protocol)

| Contract | Address |
|---|---|
| `APIRegistryFactory` | `0x463aE25955A0D05202D5f75664E4BAF197e5cE8e` |
| `APIIntegrityRegistry` | `0x4714505eBF0cC0bE599614BB99F496b363946Eea` |
| `StakeManager` | `0xe047223300c43977e2Ac220982DC63A4969794a0` |
| `ChallengeManager` | `0xEBcD723f6d9cf6aBF783Ca2Cad7fA75645842dF9` |

### Layer 2 (Financial Applications)

| Contract | Address | Deploy Script |
|---|---|---|
| `WrappedRevenueShare` | `0x072e0f72167a4267cda41a09f5be7907a2e554aa` | `DeployWrappedRevenueShare.s.sol` |

> Note: Layer 2 contracts can be deployed independently using the scripts in `contracts/script/Deploy*.s.sol`

---

## Technology stack

| Layer | Technology |
|---|---|
| Smart contracts | Solidity 0.8.30 |
| Build / deploy | Foundry |
| Token standards | ERC20, ERC4626 |
| Security primitives | OpenZeppelin v5 (AccessControl, Pausable, ReentrancyGuard, SafeERC20) |
| Oracle / verification | **Chainlink CRE** (log trigger, DON consensus, `onReport` callback) |
| Payment protocol | x402 (HTTP 402 machine-payable) |
| Payment token | USDC (Avalanche Fuji) |
| Network | Avalanche Fuji (chainId 43113) |
| Tooling | Python / web3.py (scripts), TypeScript / viem (CRE workflow, servers) |

---

## Ways to interact

### `composed` CLI

A terminal-based interactive shell for providers. Stake, deploy, register endpoints, inspect vaults and splitters, open challenges — all from the command line.

```bash
cd contracts/scripts && uv sync
composed        # opens interactive shell
composed status # one-shot
```

See [`contracts/scripts/CLI.md`](contracts/scripts/CLI.md) for the full guide.

### Smart contracts (direct)

All contracts are verified on Snowscan. Call them directly from any wallet, script, or protocol — no SDK required. Deployed addresses are in the table below; ABIs are in [`abis/`](abis/).

---

### Python SDK (`composed`)

A typed Python client for building scripts, integrations, or custom tooling on top of the protocol. Install as a local package from `contracts/`.

```python
from composed import ComposedClient

client = ComposedClient(rpc_url="...", private_key="0x...")
client.stake()
deployed = client.deploy_provider(name="My API", symbol="MAPI", vault_bp=9800)
```

### Frontend app

A web dashboard for providers to manage their vault, splitter, and endpoints. Connect your wallet and interact with the protocol without a CLI.

**Live at [composed.httpayer.com](https://composed.httpayer.com/)**

To run locally:

```bash
cd frontend
npm install && npm run dev
```

---

## Quickstart

### 1. Deploy contracts

```bash
cd contracts
cp .env.sample .env
# Fill in PRIVATE_KEY, GATEWAY_URL (Alchemy RPC), CRE_FORWARDER

forge build
forge script script/DeployAll.s.sol \
  --rpc-url $AVALANCHE_FUJI_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast --verify
```

### 2. Register a provider and endpoint

```bash
cd contracts/scripts
cp .env.sample .env   # fill in PRIVATE_KEY, GATEWAY_URL
uv sync               # installs CLI entry point

composed stake
composed deploy-provider --name "My API" --symbol "MAPI"
# → note the splitter address, set it as payTo in your x402 server

# Verify what hash your server will register
composed hash-endpoint --url https://your-api.com/endpoint

composed register-endpoint \
  --provider-id 1 --splitter 0x<splitter> --url https://your-api.com/endpoint
```

### 3. Start the watchers

```bash
cd contracts/scripts

# Settles challenges automatically via CRE simulate
uv run python cre_watcher.py

# Monitors all endpoints and opens challenges on hash mismatches
uv run python challenger_watcher.py
```

### 4. Run the analytics dashboard

```bash
cd analytics
uv sync

# Sync historical events into SQLite
uv run python src/analytics_indexer.py --once

# Terminal 1 — API
uv run uvicorn src.analytics_api:app --port 8000

# Terminal 2 — Dashboard
uv run streamlit run src/analytics_dashboard.py
```

See `analytics/README.md` for full details.

### 5. Start the revenue distribution cron

```bash
cd scripts
uv sync
uv run python revenue_splitter_trigger.py
```

Or run once:

```bash
uv run python revenue_splitter_trigger.py --once
```

### 5. Settle challenges via CRE

The `cre_watcher.py` automatically detects `ChallengeOpened` events and runs the CRE workflow to settle them — no manual intervention needed.

```bash
cd contracts/scripts
uv run python cre_watcher.py
```

To trigger the CRE workflow manually for a specific challenge:

```bash
cd cre
cre workflow simulate integrity-workflow \
  --non-interactive \
  --trigger-index 0 \
  --evm-tx-hash 0x<openChallenge tx hash> \
  --evm-event-index 1 \
  --target staging-settings \
  --broadcast
```

See `cre/README.md` for the full CRE setup guide.

---

## Status

| Component | Status |
|---|---|
| Layer 0 contracts | Complete — deployed on Fuji |
| Layer 1 contracts | Complete — deployed on Fuji |
| Layer 2 contracts | Complete — WrappedRevenueShare deployed |
| Chainlink CRE workflow | Complete — simulated end-to-end |
| Provider CLI | Complete |
| Admin CLI | Complete |
| CRE challenge watcher | Complete |
| Challenger watcher | Complete |
| Revenue splitter trigger | Complete |
| Analytics (indexer, API, dashboard) | Complete |
| Python SDK (`composed`) | Complete |
| Frontend app | Live at [composed.httpayer.com](https://composed.httpayer.com/) |

---

## Avalanche Build Games 2026

Built for the Avalanche Build Games hackathon. The core thesis: API revenue is the largest untapped cash flow primitive in software — x402 makes it routable onchain, and this protocol makes it investable.
