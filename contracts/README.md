# Composed Protocol

> **Permissionless adversarial verification protocol for API integrity on Avalanche**

Turn API revenue into investable, onchain assets with cryptoeconomic enforcement.

---

## 🎯 What It Does

The Composed Protocol enables:

1. **Verifiable API Revenue** - Every payment settles onchain via x402 protocol
2. **Economic Enforcement** - Providers stake USDC; get slashed if they misdirect payments
3. **Permissionless Challenges** - Anyone can verify endpoint integrity for a fee
4. **Revenue Tokenization** - RS-native model: fixed-supply dividend tokens represent perpetual revenue rights

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     SECURITY LAYER                          │
│                                                             │
│  ┌─────────────────┐  ┌──────────────┐  ┌──────────────┐ │
│  │ APIIntegrity    │  │ Stake        │  │ Challenge    │ │
│  │ Registry        │◄─┤ Manager      │◄─┤ Manager      │ │
│  │                 │  │              │  │              │ │
│  │ • Providers     │  │ • Bond USDC  │  │ • Open       │ │
│  │ • Endpoints     │  │ • Slash on   │  │   challenges │ │
│  │ • Integrity     │  │   mismatch   │  │ • Oracle     │ │
│  │   hash          │  │ • Cooldowns  │  │   verified   │ │
│  └─────────────────┘  └──────────────┘  └──────────────┘ │
│                                                             │
│            Chainlink Functions ◄──┐                        │
│            Chainlink Automation ◄─┘                        │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                     REVENUE LAYER                           │
│                                                             │
│  ┌─────────────────┐  ┌──────────────┐  ┌──────────────┐ │
│  │ APIRegistry     │  │ Provider     │  │ Provider     │ │
│  │ Factory         │─►│ Revenue      │  │ Revenue      │ │
│  │                 │  │ Splitter     │  │ Share        │ │
│  │ • Deploy RS +  │  │              │  │              │ │
│  │   splitter      │  │ • USDC split │  │ • Fixed      │ │
│  │ • Per-provider  │  │ • Treasury % │  │   supply     │ │
│  │   instances     │  │ • RS %       │  │ • Dividends  │ │
│  └─────────────────┘  └──────────────┘  └──────────────┘ │
│                              ▲                              │
│                              │ x402 payments                │
│                              │ (USDC)                       │
└──────────────────────────────┼──────────────────────────────┘
                               │
                        ┌──────┴──────┐
                        │   Clients   │
                        │ (HTTPayer)  │
                        └─────────────┘
```

---

## ⚡ Key Features

### Permissionless Challenges
- **No watcher role** - anyone can challenge an endpoint
- **Economic incentives** - challengers earn rewards for finding violations
- **Oracle-verified** - Chainlink Functions provides deterministic offchain compute

### Economic Security
- **Staking required** - providers must bond USDC to participate
- **Partial slashing** - BPS-based slashing (e.g., 20% of stake)
- **Cooldown periods** - 7-day withdrawal delay after unstake request

### Revenue Tokenization (RS-Native)
- **Fixed-supply RS tokens** - minted once at genesis, never diluted
- **Perpetual dividend rights** - holders claim USDC without burning shares
- **Secondary market tradeable** - fair value derived from trailing revenue

### Production-Grade
- **OpenZeppelin contracts** - battle-tested security primitives
- **Role-based access** - granular permissions (ADMIN, CHECKER, SLASHER)
- **Pausable** - emergency stop functionality
- **Reentrancy protection** - guards on all critical functions

---

## 📦 Smart Contracts

| Contract | Description | LOC |
|----------|-------------|-----|
| **APIIntegrityRegistry** | Provider & endpoint registration, integrity commitments | 125 |
| **StakeManager** | Staking, slashing, withdrawal with cooldowns | 164 |
| **ChallengeManager** | Permissionless challenges, Chainlink Functions integration | 192 |
| **APIRegistryFactory** | Deploys RS token + splitter per provider | 64 |
| **ProviderRevenueShare** | Fixed-supply dividend accumulator | 200+ |
| **ProviderRevenueSplitter** | Splits USDC between protocol, provider treasury, and RS | 117 |

**Total:** ~850 LOC core protocol

---

## 🚀 Quick Start

### 1. Clone & Install

```bash
git clone <repo>
cd contracts
forge install
```

### 2. Configure

```bash
cp .env.example .env
# Edit .env with your configuration
```

### 3. Build

```bash
./build.sh
```

This runs `forge build` and then extracts ABIs to the `abis/` directory (used by SDK and scripts).

### 4. Test

```bash
forge test -vv
```

### 5. Deploy to Fuji

```bash
source .env
forge script script/DeployAll.s.sol \
  --rpc-url $AVALANCHE_FUJI_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

---

## 🚀 Deploying L2 Contracts

Each L2 product has its own deploy script. Set the required environment variables in `.env` before running.

### WrappedRevenueShare

```bash
# .env
WRS_REVENUE_SHARE=0x...  # ProviderRevenueShare contract address
WRS_TREASURY=0x...       # Treasury address
WRS_NAME="Wrapped Revenue Share"
WRS_SYMBOL="wRS"

forge script script/DeployWrappedRevenueShare.s.sol \
  --rpc-url $AVALANCHE_FUJI_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

### APIYieldIndex

```bash
# .env
INDEX_USDC=0x...    # USDC token address
INDEX_NAME="API Yield Index"
INDEX_SYMBOL="AYI"

forge script script/DeployAPIYieldIndex.s.sol \
  --rpc-url $AVALANCHE_FUJI_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

### APIRevenueFuture

```bash
# .env
FUTURE_USDC=0x...  # USDC token address

forge script script/DeployAPIRevenueFuture.s.sol \
  --rpc-url $AVALANCHE_FUJI_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

### APIRevenueStable

```bash
# .env
STABLE_REVENUE_SHARE=0x...  # ProviderRevenueShare contract address
STABLE_FEE_RECIPIENT=0x... # Fee recipient address
STABLE_NAME="API Revenue Stable"
STABLE_SYMBOL="ARS"

forge script script/DeployAPIRevenueStable.s.sol \
  --rpc-url $AVALANCHE_FUJI_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

### APIUSD

```bash
# .env
APIUSD_RS=0x...            # ProviderRevenueShare address
APIUSD_USDC=0x...          # USDC token address
APIUSD_FEE_RECIPIENT=0x... # Fee recipient address

forge script script/DeployAPIUSD.s.sol \
  --rpc-url $AVALANCHE_FUJI_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

### yAPIUSD

```bash
# .env
YAPI_RS=0x...               # ProviderRevenueShare address
YAPI_USDC=0x...             # USDC token address
YAPI_INITIAL_TREASURY=0x... # Initial treasury address
YAPI_FEE_RECIPIENT=0x...   # Fee recipient address

forge script script/DeployyAPIUSD.s.sol \
  --rpc-url $AVALANCHE_FUJI_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

### wcAPIUSD

```bash
# .env
WCI_RS=0x...            # ProviderRevenueShare address
WCI_USDC=0x...          # USDC token address
WCI_BORROWER=0x...      # Borrower address
WCI_FEE_RECIPIENT=0x... # Fee recipient address

forge script script/DeploywcAPIUSD.s.sol \
  --rpc-url $AVALANCHE_FUJI_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

### RevShareStable

```bash
# .env
RSS_RS=0x...            # ProviderRevenueShare address
RSS_USDC=0x...         # USDC token address
RSS_FEE_RECIPIENT=0x... # Fee recipient address

forge script script/DeployRevShareStable.s.sol \
  --rpc-url $AVALANCHE_FUJI_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

### InitialAPIOffering

```bash
# .env
IAO_USDC=0x...           # USDC token address
IAO_RS=0x...             # ProviderRevenueShare address
IAO_PROVIDER=0x...       # Provider address (receives raised USDC)
IAO_FUNDING_GOAL=1000000 # Funding goal in USDC (6 decimals)
IAO_DEADLINE=...         # Unix timestamp for deadline
IAO_TOKEN_PRICE=100      # Token price in USDC (6 decimals)
IAO_RS_ALLOCATED=...     # RS tokens allocated to this IAO
IAO_NAME="Initial API Offering"
IAO_SYMBOL="IAO"

forge script script/DeployInitialAPIOffering.s.sol \
  --rpc-url $AVALANCHE_FUJI_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify
```

---

See [DEPLOYMENT.md](./DEPLOYMENT.md) for complete deployment guide.

### ⚠️ Post-Deployment: Update CRE Config

After deploying, update the CRE workflow config with the new ChallengeManager address:

```bash
# Get the new ChallengeManager address from the broadcast file
cat broadcast/DeployAll.s.sol/43113/run-latest.json | grep ChallengeManager

# Update cre/integrity-workflow/config.staging.json with the new address
```

The CRE workflow (`cre/integrity-workflow/config.staging.json`) stores the ChallengeManager address and must match your deployed contract. After any contract redeployment, update this file to point to the new ChallengeManager address.

---

## 📖 Documentation

- [**DEPLOYMENT.md**](./DEPLOYMENT.md) - Complete deployment guide
- [**CLEANUP_PLAN.md**](./CLEANUP_PLAN.md) - Architecture decisions & cleanup notes
- [**IDEA.md**](../IDEA.md) - Original concept & rationale
- [**OVERVIEW.md**](../OVERVIEW.md) - Detailed technical architecture

---

## 🔧 Development

### Run Tests

```bash
forge test                    # Run all tests
forge test -vvv              # Verbose output
forge test --match-test testStake  # Run specific test
```

### Coverage

```bash
forge coverage
```

### Gas Snapshots

```bash
forge snapshot
```

### Lint

```bash
forge fmt                    # Format code
forge lint                   # Run linter
```

---

## 🛡️ Security

### Audits

⚠️ **This code has NOT been audited.** Do not use in production without a professional security audit.

### Bug Bounty

We welcome responsible disclosure. Please report security issues to [security@yourprotocol.com].

### Known Limitations

1. **Chainlink dependency** - Oracle verification relies on Chainlink Functions availability
2. **Optimistic model** - Challenge resolution has a delay window
3. **USDC dependency** - All staking/payments use USDC (not AVAX)

---

## 🤝 Contributing

Contributions welcome! Please:

1. Fork the repo
2. Create a feature branch
3. Add tests for new functionality
4. Ensure `forge test` passes
5. Submit a pull request

---

## 📜 License

MIT License - see [LICENSE](./LICENSE) for details.

---

## 🎓 Learn More

### What is x402?

The [x402 protocol](https://github.com/httpayer/x402) enables machine-payable HTTP APIs. Clients receive a `402 Payment Required` response with payment instructions, sign a payment, and retry with proof.

### Why Avalanche?

- **Fast finality** - Real-time revenue distribution
- **Low fees** - Per-call settlements are economically viable
- **Burn-based model** - Measurable network value
- **RWA focus** - Tokenizing cash flows aligns with Avalanche's institutional narrative

### Why Chainlink?

- **Deterministic verification** - Functions provide reliable offchain compute
- **Automation** - Background endpoint checks without manual intervention
- **Battle-tested** - Production-grade oracle network

---

## 📊 Status

- ✅ Core contracts implemented
- ✅ Compilation successful
- ✅ Deployment scripts complete
- ✅ Documentation comprehensive
- ⏳ Tests in progress
- ⏳ Chainlink Automation logic (basic implementation)
- ⏳ Frontend dashboard (separate repo)
- ⏳ Security audit (pre-mainnet requirement)

---

## 🌐 Links

- **Avalanche Fuji Explorer**: https://testnet.snowtrace.io/
- **Chainlink Functions**: https://functions.chain.link/
- **Chainlink Automation**: https://automation.chain.link/
- **x402 Protocol**: https://github.com/httpayer/x402

---

## 💬 Contact

- GitHub: [@yourhandle](https://github.com/yourhandle)
- Twitter: [@yourhandle](https://twitter.com/yourhandle)
- Discord: [Join our server](https://discord.gg/yourserver)

---

**Built for Avalanche Build Games Hackathon 2026**
