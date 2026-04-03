# Build Games - Composed Protocol

## Overview

This is a **DeFi protocol** built for the **Avalanche Build Games 2026 Hackathon** that makes API revenue investable via x402 micropayments. Built on Avalanche Fuji testnet.

## Tech Stack
- **Smart Contracts**: Solidity 0.8.30 + Foundry
- **Oracle/Security**: Chainlink CRE (Compute Runtime Environment)
- **Payments**: x402 protocol (USDC)
- **Scripts**: Python (web3.py), TypeScript (viem)
- **Frontend**: Next.js + TypeScript

## Project Structure
```
├── contracts/          Foundry project (Layer 0-2 DeFi contracts)
│   ├── src/            Solidity contracts
│   ├── script/         Deploy scripts
│   ├── broadcast/      Deployed contract addresses
│   ├── composed/       Python SDK
│   └── scripts/        CLI, watchers, automation
├── analytics/          Protocol analytics (Streamlit dashboard)
├── frontend/           Web dashboard (Next.js)
├── cre/                Chainlink CRE workflow
├── servers/            x402 server examples
└── scripts/            Standalone automation scripts
```

## Deployed Contracts (Avalanche Fuji - 43113)
| Contract | Address |
|---|---|
| APIRegistryFactory | `0x463aE25955A0D05202D5f75664E4BAF197e5cE8e` |
| APIIntegrityRegistry | `0x4714505eBF0cC0bE599614BB99F496b363946Eea` |
| StakeManager | `0xe047223300c43977e2Ac220982DC63A4969794a0` |
| ChallengeManager | `0xEBcD723f6d9cf6aBF783Ca2Cad7fA75645842dF9` |
| WrappedRevenueShare | `0x072e0f72167a4267cda41a09f5be7907a2e554aa` |

## Status
- [x] Layer 0 contracts - Deployed
- [x] Layer 1 contracts - Deployed
- [x] Layer 2 contracts - Deployed
- [x] Chainlink CRE workflow - Complete
- [x] Provider CLI - Complete
- [x] Analytics dashboard - Complete
- [x] Frontend app - Live

## TODO
- [ ] Add comprehensive test coverage
- [ ] Mainnet deployment preparation
- [ ] Security audit
- [ ] Additional Layer 2 instruments (more stablecoins)
- [ ] Integration tests between all components
