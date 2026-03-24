# Composed Protocol — Go-to-Market

---

## 1. Product Vision

Composed is building **the financial substrate for the autonomous API economy** — a future where APIs, AI agents, and services do real economic work and get paid in a trustless, programmable, onchain way.

Today, APIs are monetized with subscriptions, quotas, and manual billing — models designed for humans, not software. With x402 payments, software (especially AI agents) can autonomously pay for API consumption in USDC without human intervention, unlocking usage-native monetization at machine scale.

**Long-term, we are building toward:**

- APIs as **programmable revenue primitives** — not just services, but assets that generate yield, collateralize credit, and create tradable financial products
- Developers able to **raise capital against real usage-driven cash flows**, transforming how SaaS and API businesses are funded
- AI agents and autonomous software that interact with APIs seamlessly, with zero payment friction
- Revenue flows that are **trustless, auditable, and composable** — integrating directly with DeFi protocols, stablecoins, and cross-chain liquidity layers

This is not just about monetization. It's about creating a vibrant economic layer beneath the autonomous internet that can scale to trillions of dollars in API consumption, with onchain capital markets built directly on usage data.

---

## 1.1 Core Primitive — ProviderRevenueShare (RS Token)

The closest tradfi analog to API revenue is a **royalty trust**: a fixed number of units outstanding, external cashflow distributed pro-rata to unitholders, no redemption mechanism, secondary-market price discovery.

`ProviderRevenueShare` implements this directly:

- Fixed supply minted once at genesis — no inflation, no redemption
- Revenue credited via a per-share accumulator (MasterChef pattern)
- Holders call `claim()` to withdraw earned USDC without burning shares
- Transfer hooks settle both parties so buyers never claim revenue earned before they held shares
- `cumulativeRevenuePerShare()` provides a clean, lifetime EPS figure

**Why not ERC4626?** ERC4626 is built for endogenous yield — yield generated *by* deposited capital. API revenue is exogenous: it arrives from outside, completely unrelated to any deposited capital. This breaks the share price formula at genesis, makes redemption semantically incorrect, and causes incorrect valuations in any L2 contract that calls `deposit()`, `withdraw()`, or `redeem()`. `ProviderRevenueShare` is the right primitive — it directly represents what API revenue actually is: a perpetual, proportional claim on a future cashflow stream.

---

## 2. Milestones & Roadmap

### Next 3–6 Months — MVP / Early Adoption

- **Yield integration for staked assets** — deploy provider stake into yield-bearing protocols to eliminate opportunity cost on idle collateral
- **Typescript and Go SDKs** — reduce integration friction for API providers, agent developers, and backends
- **Custodied server deployments** — hosted deployment patterns where the `payTo` configuration is immutable by default unless changed via onchain state, another layer to prevent silent fund redirection
- **Improved analytics dashboard** — real-time revenue metrics, bond coverage ratios, and per-endpoint integrity status
- **Live integrations with AI platforms** — active partnerships with Bankr, OpenServ, and trustless AI frameworks to demonstrate real usage and revenue

### 6–12 Months — Growth / Network Effects

- **Cross-chain revenue settlement** — integrate with Meridian so clients pay on any network while revenue settles on Avalanche
- **Automated verification tooling** — Chainlink Automation for re-staking, bond top-ups, and integrity monitoring without manual scripts
- **Per-endpoint revenue shares** — migrate from per-provider to per-endpoint `ProviderRevenueShare` tokens for cleaner investor exposure

### 12–24 Months — Ecosystem & Scale

- **Governance and token-based incentives** — decentralized governance with token incentives for verifiers, stewards, and integrators
- **Institutional-grade deployments** — custodian patterns and escrow overseers for high-value API providers
- **Revenue-backed financial products** — API revenue futures, revenue indices, and secondary market infrastructure

### 6-Month Success Metrics

- 10+ active provider integrations with live RS tokens issued
- $50k+ cumulative USDC volume routed through revenue splitters
- 3+ AI agent platforms (Bankr, OpenServ, etc.) with native Composed integration
- First cross-chain settlement via Meridian live on mainnet

---

## 3. User Acquisition Strategy

**Cold start — first providers**
- **Dogfood it** — HTTPayer is itself an x402 provider. Register it as the first Composed provider: real revenue, real RS tokens, real proof of concept
- **Hackathon-to-hackathon** — Build Games participants building x402-enabled APIs are warm leads; offer white-glove onboarding and early fee waivers
- **Bankr / OpenServ integrations** — these platforms already have agents consuming APIs; one integration means multiple provider APIs automatically flowing through Composed
- **Custodied deployment as the hook** — offer free custodied deployments to early providers; the security guarantee (immutable `payTo`) is the pitch, not the revenue split

**Developer evangelism**
- Publish tutorials, integration examples, and hackathon content focused on AI-native monetization and usage-based revenue
- Engage Web3 developer communities on Discord, GitHub, and at hackathons
- Providers can upcharge their APIs slightly so net margin is unchanged — the delta flows directly into Composed, making adoption cost-neutral

**Partnership integrations**
- Direct SDK integrations with x402 providers and AI agent launchpads (Bankr, OpenServ)
- Partnership with [Meridian](https://docs.mrdn.finance/) for cross-chain x402 facilitation — client pays on network A, all payments settle on Avalanche to the revenue splitters
- Integration with ERC-8004 agent identity standard — Composed-registered endpoints are automatically surfaced in agent marketplaces and explorers that support ERC-8004, turning the identity ecosystem into a passive distribution channel

**Content and thought leadership**
- Whitepapers, revenue growth playbooks, and case studies around usage monetization, agency-driven demand, and API financialization

---

## 4. Community Strategy

**Discord + Builders Community**
- Channels for product feedback, developer support, integrations, and revenue monetization workshops
- Dedicated `#revenue-share` channel where providers post their live RS token addresses and earnings — organic social proof built into the community structure

**"First 100 Providers" program**
- Public leaderboard of top-earning providers by cumulative USDC revenue, creating visibility and organic competition among early adopters

**Ambassador program**
- Identify and empower core builders, integrators, and early revenue generators as ambassadors with protocol incentives

**Events and governance**
- Weekly office hours for developers integrating x402 + Composed, hosted by the core team
- Regular community calls, AMA sessions with partners, and governance discussions once token governance is enabled
- Publish protocol upgrade proposals publicly from day one and invite community comment — sets an open governance culture before a token exists

---

## 5. Revenue and Sustainability Model

**Protocol fees**
A share of all distributed x402 revenue (basis points per payment) flows to the protocol treasury.

**Custodied deployment fees**
Charge providers for hosted server deployments that lock `payTo` configuration — preventing silent fund redirection without onchain state changes. Optional integration with institutional custodians (e.g., BitGo) for enterprise-grade assurance.

**Yield on staked collateral**
Provider bonds are deployed into yield-bearing protocols. The protocol captures a share of yield on collateral it holds.

**Premium tooling**
Enterprise analytics, revenue forecasting, and SLA-backed deployment packages for high-value API businesses.


---

## 6. Competitive Landscape

| Competitor | What They Do | Why Composed Wins |
|---|---|---|
| **RapidAPI / proxy402** | API pricing and per-use billing | No onchain verification, no investable revenue flows, no capital formation |
| **xMCPKit / payment SDKs** | Payment layers for API monetization | Lack onchain revenue tokenization, challenge/slash enforcement, and financial primitives |
| **ChaosChain x402 facilitator** | Decentralized payment facilitation | Focused on payments only — no financialization, no revenue instruments, no investor infrastructure |

**Why users choose Composed:**
Composed uniquely combines AI-native payment settlement, onchain revenue instruments (`ProviderRevenueShare`), verification enforcement (bond/stake + CRE challenges), and capital markets infrastructure. This creates a new asset class — investable API revenue — rather than just payment plumbing.
