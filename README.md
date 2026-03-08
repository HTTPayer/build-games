# API Integrity Protocol

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
│  ProviderRevenueVault (ERC4626) · ProviderRevenueSplitter           │
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

The core primitive. Every x402 payment flows through the splitter and directly into the vault as a USDC transfer — increasing `totalAssets()` without minting new shares. Existing share holders earn yield purely through share price appreciation.

| Contract | Description |
|---|---|
| `ProviderRevenueVault` | ERC4626 vault. Fixed share supply after genesis mint. Revenue arrives via direct USDC transfer, so share price rises with every API call settled onchain. |
| `ProviderRevenueSplitter` | Routes x402 USDC revenue across three recipients: protocol treasury, optional provider treasury (operating income), and the vault (share appreciation). All splits are immutable after deployment. |

### Revenue split

```
protocolTreasuryBp   →  protocol treasury  (USDC)         [fixed by protocol]
providerTreasuryBp   →  provider treasury  (USDC, opt.)   [set at deployment]
vaultBp              →  vault direct transfer              [remainder]
```

`vaultBp = 10,000 - protocolTreasuryBp - providerTreasuryBp`

Setting `providerTreasuryBp = 0` routes all non-protocol revenue to vault share appreciation. Setting it higher gives the developer direct USDC operating income. The developer decides at deployment — it cannot be changed afterward.

### Genesis mint

Vault shares are minted once at factory deployment with no USDC backing. The `genesisRecipient` can be any address: developer wallet, multisig, IAO contract, vesting contract. Share price starts at `0` and rises with API usage.

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
│   ├── src/                          Solidity contracts (Layer 0, 1, 2)
│   ├── script/DeployAll.s.sol        Deploy script
│   ├── broadcast/                    Deployed addresses (source of truth)
│   ├── scripts/                      Python tooling
│   │   ├── cli.py                    Provider CLI (stake, deploy, register, challenge)
│   │   ├── admin_cli.py              Admin CLI (set-forwarder, mint-usdc, etc.)
│   │   ├── cre_watcher.py            Auto-settles challenges via CRE simulate
│   │   ├── challenger_watcher.py     Monitors endpoints, challenges mismatches
│   │   ├── utils.py                  Shared web3 helpers
│   │   ├── x402_metadata.py          Hash computation
│   │   └── verify.py                 Snowtrace contract verification
│   └── chainlink/
│       ├── compute-hash.js           Manual hash dry-run
│       └── dry-run.js                Verify hash before challenging
│
├── cre/                              Chainlink CRE workflow
│   ├── project.yaml                  CRE project config (RPC, experimental chains)
│   └── integrity-workflow/
│       ├── main.ts                   Log trigger → hash verify → onReport
│       ├── workflow.yaml             Staging / production targets
│       └── config.staging.json       ChallengeManager address + chain selector
│
├── servers/                          x402 server examples
│   └── src/server.ts                 Reference implementation
│
└── docs/
    ├── frontend-provider-registration.md   Wagmi integration guide
    └── OVERVIEW.md
```

---

## Deployed contracts (Avalanche Fuji — chain ID 43113)

| Contract | Address |
|---|---|
| `APIRegistryFactory` | `0xbDC41cf3E17D5FA19e41A3Fb02C8AcB9B9927e5B` |
| `APIIntegrityRegistry` | `0xaF2596CCF591831d8af6b463dc5760C156C5936A` |
| `StakeManager` | `0x3401eE39d686d6B93A97Bd04A244f3bBa1e7dD69` |
| `ChallengeManager` | `0x60825231973f0e9d441A85021dACA8AaE473A44b` |

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
cp .env.sample .env   # fill in keys

uv run python cli.py stake
uv run python cli.py deploy-provider --name "My API" --symbol "MAPI"
# → note the splitter address, set it as payTo in your x402 server

uv run python cli.py register-endpoint \
  --provider-id 1 --splitter 0x<splitter> --url https://your-api.com/endpoint
```

### 3. Start the watchers

```bash
# Settles challenges automatically via CRE simulate
uv run python cre_watcher.py

# Monitors all endpoints and opens challenges on hash mismatches
uv run python challenger_watcher.py
```

### 4. Simulate the CRE workflow manually

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
| Layer 2 contracts | Complete (not deployed — demo scope is Layer 0+1) |
| Chainlink CRE workflow | Complete — simulated end-to-end |
| Provider CLI | Complete |
| Admin CLI | Complete |
| CRE challenge watcher | Complete |
| Challenger watcher | Complete |
| Frontend guide | Complete (`docs/frontend-provider-registration.md`) |
| Frontend app | Planned |

---

## Avalanche Build Games 2026

Built for the Avalanche Build Games hackathon. The core thesis: API revenue is the largest untapped cash flow primitive in software — x402 makes it routable onchain, and this protocol makes it investable.
