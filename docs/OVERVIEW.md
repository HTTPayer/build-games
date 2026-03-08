# Revenue Token Pricing Considerations

[Benefit to Providers](https://www.notion.so/Benefit-to-Providers-30c6597ad8d98071b32bcc1ecc437f52?pvs=21)

---

# Tokenized API Cash Flow — Full Overview

## The One-Line Pitch

> Make API revenue investable for the first time — with onchain enforcement, not trust.
> 

---

## What Problem This Solves

APIs generate real cash flow. That cash flow has historically been:

- **Invisible** — trapped inside companies, not observable externally
- **Illiquid** — you cannot invest in Stripe’s API revenue
- **Unverifiable** — you have to trust reported numbers

Onchain settlement flips all three. Every payment becomes a verifiable, auditable, programmable event. API revenue has always existed — it just was never investable before. The registry and splitter make it so.

---

## The Infrastructure Primitive

A primitive in DeFi is something composable — a building block that other financial constructs are built on top of. Lending, AMMs, and stablecoins are primitives. They are not products; they are infrastructure others stack on.

The registry + splitter combination has that property. Once API revenue is routed through a verifiable onchain contract with enforceable payment destination, it becomes composable input for a financial stack. Revenue token issuance is an optional extension on top of that infrastructure — not the core.

| Layer | What It Is | Role |
| --- | --- | --- |
| **Layer 0** | `APIIntegrityRegistry` + `RevenueSplitter` — onchain routing and enforcement | Infrastructure primitive |
| **Layer 1** | `EndpointRevenueToken` — per-endpoint ERC-20 yield claims | Financial primitive (optional) |
| **Layer 2** | Stablecoins, futures, indexes, lending, IAOs built on Layer 1 | Applications (optional) |

**Layer 0 is the infrastructure primitive.** It makes API revenue routable, verifiable, and enforceable onchain. Valuable on its own — even without any token issuance.

**Layer 1 is the financial primitive.** Once revenue flows through the splitter, it can be tokenized into tradable yield claims. This is genuinely new: per-endpoint revenue participation tokens did not exist as an onchain instrument before. Not a new asset class — a new type of cash flow instrument. The distinction matters for credibility.

Revenue token issuance is opt-in. Operators can use the registry + splitter purely for payment enforcement with no tokenization at all. The financial layer activates only when the operator chooses it.

---

## What Is Already Built

One core contract already exists and can be reused directly:

**`RevenueSplitter.sol`** — A USDC-based, pull-model revenue splitter. x402 facilitators send USDC to this contract; anyone (or Chainlink Automation) calls `distribute()` to forward shares to configured recipients using basis points (BPS). Supports arbitrary recipient addresses — developer wallets, token contracts, yield vaults, or any other onchain address. Chainlink Automation compatible. This contract is the `payTo` address in x402 payment instructions.

The new work is the factory, the per-endpoint token, and the registry.

---

## The Architecture

### Per-Endpoint Token Model

Each API endpoint gets its own token and its own splitter. There is no shared vault — every endpoint is an isolated, independently investable asset.

When a developer calls `registerEndpoint()` on the factory:

```
EndpointFactory.registerEndpoint(
    apiUrl,           // The endpoint being monetized
    developerAddress, // Developer's wallet — receives their BPS cut
    tokenSupply,      // Total supply of revenue tokens to mint
    splits[]          // BPS allocations: developer / token holders / any address
)
```

The factory deploys two contracts:

**1. `RevenueSplitter`** (reused)
- Configured with BPS recipients: developer wallet + RevenueToken contract + any additional addresses
- This contract’s address becomes the `payTo` in x402 payment instructions
- Every USDC payment from x402 lands here and is split automatically

**2. `EndpointRevenueToken`** (new)
- ERC-20 representing fractional yield claims on this specific endpoint
- Token holders are recipients in the RevenueSplitter at their allocated BPS
- Transferable and tradable — holders can exit by selling tokens

The factory also registers the endpoint in the `APIIntegrityRegistry`, committing the `RevenueSplitter` address as the canonical `payTo`.

**Example:**

```
Endpoint: api.example.com/v1/pricing
Token: YIELD-PRICING-2026
Total supply: 1,000,000 tokens

BPS split:
  Developer wallet      — 7000 BPS (70%)
  RevenueToken contract — 3000 BPS (30%) → distributed to token holders
```

- API charges $0.01 USDC per call
- 10,000 calls/day = $100 USDC/day
- $70 → developer, $30 → token holders (pro-rata)
- Chainlink Automation triggers `distribute()` on a schedule
- Token holders receive yield automatically, proportional to tokens held

Additional BPS recipients (e.g. a yield vault, a DAO treasury, a stablecoin protocol) can be added at registration — the RevenueSplitter supports arbitrary addresses. This is how Layer 2 products like a yield-bearing stablecoin plug in — as a BPS recipient, not as a core dependency.

---

## The Three Components

### 1. HTTPayer Settlement

APIs charge per-call via the x402 protocol. Every payment settles in USDC on Avalanche. The x402 facilitator sends USDC directly to the endpoint’s `RevenueSplitter` contract (the `payTo` address). The splitter emits:

```
RevenueRecorded(apiId, amount, block)
```

This creates a verifiable, tamper-resistant ledger of API revenue. No trust in the operator required — the chain is the record.

### 2. EndpointFactory + RevenueSplitter + RevenueToken

Each registered endpoint is a self-contained financial instrument:

- `registerEndpoint()` deploys a fresh `RevenueSplitter` and `EndpointRevenueToken`
- The `RevenueSplitter` address is the `payTo` — no off-ramp, no manual routing
- BPS splits are set at registration and locked (changes require a timelock via the registry)
- `distribute()` is callable by anyone or triggered by Chainlink Automation
- Token holders receive USDC yield proportional to their share of the token supply

Transparent usage dashboards show real-time revenue, yield %, token price, and distribution history per endpoint.

### 3. APIIntegrityRegistry

The trust layer that makes this investable rather than speculative.

When an API opts into revenue tokenization, the deployer must commit onchain:

```
apiId
canonicalPayTo
bondAmount
commitmentTimestamp
```

**Watcher Network — Optimistic + Economic:**
Anyone can run a watcher. Watchers periodically call the API, read the returned `payTo`, and compare it to the committed address. If a mismatch is detected, they submit a report onchain.

Important: HTTP is not deterministic. A watcher cannot cryptographically prove on-chain that an API returned a specific response — responses can vary by caller, geography, or time. This is an **optimistic model**: the report triggers a challenge window. If the deployer does not dispute within the window, the bond is slashed. Economic incentives do the work that cryptographic proof cannot.

This is honest. Mode A enforcement is optimistic and economic — not cryptographic. That is fine and well-precedented in DeFi (optimistic rollups, UMA, etc.). Do not oversell it as something stronger.

**Dual Bonding:**

| Actor | Bond | Outcome if wrong |
| --- | --- | --- |
| **Deployer** | Large bond | Slashed on verified mismatch |
| **Watcher** | Small bond | Slashed if report is fraudulent |

**Slashing Distribution:**
- 70% → affected revenue vault (compensates token holders)
- 20% → watcher (rewards honest monitoring)
- 10% → burned (deflationary pressure, token-dependent)

**Timelocked Updates:**
Deployers can propose a `payTo` change with a 48-hour delay. Watchers monitor during the window. If no valid challenge → change finalizes. This creates a transparent migration path with economic accountability.

Without bonding, it is a dashboard. With bonding, it is an economically enforced commitment.

---

### Bond Token — Three Pathways

The registry requires a bond, but the denomination is a design decision with meaningful tradeoffs. Three viable paths exist:

---

**Pathway A — Bond in AVAX (Native)**

Deployers post bonds in AVAX. Slashing burns AVAX directly.

| **Pros** | No new token required. Simplest path. Slashing creates measurable burn pressure. Revenue settles in USDC via x402; bonds in AVAX keep the bond layer Avalanche-native while settlement stays stablecoin-denominated. |
| --- | --- |
| **Cons** | AVAX is volatile. A 500 AVAX bond worth $10k today could be worth $5k next month, weakening the investor protection guarantee. |

**Mitigation:** Enforce a USD-equivalent minimum at registration via price oracle. If `bondAmount * avaxPrice < minimumUsdValue`, the deployer must top up to stay registered. This creates an ongoing economic relationship — not just a one-time deposit — and keeps the effective guarantee stable regardless of AVAX price swings.

Best fit for: hackathon demo, Avalanche-native narrative, judge-friendly burn metrics.

---

**Pathway B — Bond in USDC / Stablecoin**

Deployers post bonds in USDC or another stablecoin. Bond value is fixed in dollar terms.

| **Pros** | Stable guarantee — investors know exactly what protection they have at all times. More institutional-friendly, aligns with Avalanche’s RWA and tokenization push. Easier to reason about bond coverage ratios. |
| --- | --- |
| **Cons** | Loses the AVAX burn story. Less Avalanche-native feel. Adds stablecoin integration. Slashing distributes stablecoin to vault holders rather than the native token, which reduces composability. |

Best fit for: institutional positioning, production-grade deployments, RWA narrative alignment.

---

**Pathway C — New Protocol Token**

A purpose-built token governs the registry: staked for bonding, used for watcher rewards, and governance voting on registry parameters.

| **Pros** | Creates a governance layer. Token value is tied directly to registry growth and API ecosystem health. Can be used for voting on bond minimums, challenge windows, and slashing ratios. Enables protocol-owned liquidity. |
| --- | --- |
| **Cons** | Requires bootstrapping liquidity from zero. Adds significant regulatory surface area. Far more complex to design and launch. Token speculation can obscure the underlying utility. Wrong scope for a hackathon. |

Best fit for: long-term protocol ambition, post-launch governance layer, v2+ roadmap item.

---

**Default Path: Pathway A — AVAX with USD-floor enforcement.**

Bond denomination is a contract parameter, not hardcoded. This means:
- Launch with AVAX bonds (Pathway A)
- Add USDC bond support post-competition without a contract rewrite (Pathway B)
- Layer governance token on top if the protocol earns that scale (Pathway C)

All three doors stay open. Only one needs to be walked through first.

---

## What Gets Built on Top (Layer 2)

### GLUSD-Style Yield Stablecoin

A basket of API revenue tokens backing a yield-bearing stablecoin. Stable face value, real utility revenue inside. Similar to GLUSD’s model (yield from Galaksio compute revenue) but generalized across any API on Avalanche. The stablecoin earns yield not from speculation but from actual per-call software usage.

### Initial API Offering (IAO)

The most novel product in the stack.

A developer builds an API and presells a % of future revenue before launch:

- Raises capital to fund infrastructure costs
- Backers receive revenue tokens
- If the API succeeds, backers earn yield
- Success is verifiable onchain — calls equal revenue equal distribution

This is Kickstarter + equity crowdfunding + DeFi yield, but for software APIs specifically. The key structural advantage over ICOs: there is an underlying cash flow. The smart contract is the proof. No trust, no audit, no reported numbers.

### API Yield Index

A weighted basket of top API revenue tokens, tradable as a single asset. Composable as DeFi collateral. Market makers can bootstrap liquidity. This turns API usage into a legitimate index asset class — investable exposure to Avalanche’s API economy as a whole.

### API Revenue Futures

Tradable contracts on expected future API yield. Developers can lock in a fixed payout rate. Investors speculate on adoption. Creates a price discovery market for API growth expectations — closer to a finance primitive than a product.

### API-Backed Lending

Use revenue tokens as collateral to borrow against projected cash flow. If your API earns $100 USDC/day and you hold tokens representing 20% of that, you have a provable income stream — a legitimate collateral basis for a loan.

---

## Why This Is Avalanche-Native

Avalanche’s properties are not incidental to this design — they are load-bearing:

- **Fast finality** → real-time revenue distribution is viable
- **Low fees** → frequent per-call settlements are economically practical
- **Burn-based fee model** → every API call contributes measurable deflationary pressure
- **RWA narrative** → Avalanche is already tokenizing CLOs, T-bills, and institutional assets. Tokenized API cash flow is the same primitive applied to software.
- **Retro9000 alignment** → AVAX burned per API is a quantifiable contribution metric

APIs can be ranked by burn contribution. Judges can see measurable onchain impact. That is not a side feature — it is a core alignment with where Avalanche is going.

---

## The Viral Surface

A public dashboard showing:

### Top Avalanche APIs by Revenue

| API | Revenue | Yield % | Bond | Integrity | 7d Growth |
| --- | --- | --- | --- | --- | --- |
| AI Trading API | $240 USDC/day | 8.2% | 500 AVAX | ✓ Clean | +34% |
| NFT Analytics API | $180 USDC/day | 6.1% | 300 AVAX | ✓ Clean | +12% |
| DeFi Liquidation Bot | $95 USDC/day | 11.4% | 200 AVAX | ✓ Clean | +58% |

APIs become investable and discoverable. Investors compare yield. Builders compete for ranking. People share dashboards. Integrity scores become reputational signals.

> “This API has 500 AVAX bonded and zero mismatches in 90 days.”
> 

That is financial reputation, onchain.

---

## How This Relates to HTTPayer

HTTPayer is a payer server — client-side infrastructure that handles payment signing and submission on behalf of the client. It is one implementation of an x402 client, not the settlement layer.

The system is deliberately x402-agnostic: any compliant payer client and any compliant facilitator work with a registered endpoint, because the RevenueSplitter is just the `payTo` address. No modification to HTTPayer or any specific facilitator is required.

Where HTTPayer fits: it is a natural client for users interacting with registered endpoints, and as a registry-aware client (see dual-mode enforcement below) it can provide stronger routing guarantees than vanilla clients. But it is not a dependency — the system works without it.

---

## Enforcement Models

Three distinct enforcement models are available. They represent different points on the trust, friction, and institutional comfort spectrum. Operators choose the model that fits their context — or combine them.

---

### The 402 Response

A registered endpoint returns:

```
HTTP/1.1 402 Payment Required
X-PAYMENT-REQUIRED: {
  "payTo": "0xRevenueSplitterAddress",   // canonical address — vanilla clients use this
  "apiId": "api.example.com/pricing",    // registry key — registry-aware clients use this
  "amount": "1000000",
  "currency": "USDC",
  "chain": "avalanche"
}
```

`payTo` is already the `RevenueSplitter` address (set by the resource server at registration). `apiId` is an optional extension field. Vanilla clients ignore it. Registry-aware clients use it to verify independently.

---

### Mode A — Vanilla SDK (Economic Enforcement)

No client or facilitator modification required.

```
Client → 402 response → signs payment to payTo (RevenueSplitter) → facilitator settles → done
```

The resource server is responsible for keeping `payTo` pointed at the RevenueSplitter. Watchers enforce this:

- Watchers call the API periodically, read the returned `payTo`
- If `payTo` != `registry.getCanonicalPayTo(apiId)` → mismatch submitted onchain
- Deployer bond is slashed → token holders compensated

**Security model:** economic deterrence. Funds can be misdirected if the operator is willing to lose their bond. Appropriate for lower-value endpoints or early-stage adoption where friction matters most.

---

### Mode B — Registry-Aware Client + Facilitator (Cryptographic Enforcement)

> ⚠️ **Not implemented.** Mode B has a critical fraud inversion problem: if a malicious actor fraudulently registers a legitimate provider’s endpoint with their own splitter as the canonical address, a registry-aware client would look up the registry and pay the attacker — bypassing the real provider’s 402 `payTo` entirely. Under Mode A (vanilla), this attack is self-defeating: the client pays the 402 response directly (real provider gets paid), and the fraudulent registration is immediately slashable via challenge. Under Mode B, the same attack becomes payment theft. The registry is the right layer for integrity verification and revenue tokenization; payment routing belongs to the 402 response from the actual API server. See `docs/faq.md` for full analysis.

Requires a registry-aware payer client (e.g. HTTPayer with registry support) and a registry-aware facilitator used by the resource server.

**Client side:**

```
Client sees apiId in 402 response
  → looks up registry.getCanonicalPayTo(apiId)
  → signs payment to canonical address
  → ignores payTo field entirely
```

**Facilitator side:**

```
Facilitator receives signed payment instruction
  → checks payment destination == registry.getCanonicalPayTo(apiId)
  → if match: settles onchain
  → if mismatch: rejects payment, returns error
```

Even if the resource server returns a fraudulent `payTo` in the 402, the client signs to the registry address and the facilitator refuses to settle anywhere else. Funds cannot reach an unregistered address by any server-side config change.

**Security model:** cryptographic prevention. No trust in the resource server required. Appropriate for higher-value endpoints, institutional investors, or operators who want to advertise maximum trustlessness.

---

### Mode C — Escrow Deployer (Custodial Enforcement)

A third model that operates at the server deployment layer rather than the payment layer. Instead of enforcing revenue routing after the fact (Mode A) or at payment time (Mode B), Mode C prevents the operator from ever being able to change routing unilaterally in the first place.

**How it works:**

The API server is deployed through a controlled deployer contract. The `RevenueSplitter` address is hardcoded at deploy time. The operator cannot modify revenue routing without approval from a custodian — a multisig, a DAO, or a governance contract.

The operator retains control of the API logic but surrenders unilateral control of revenue routing. Revenue routing is institutionally governed.

```markdown
Operator wants to change payTo
  → submits proposal to escrow deployer contract
  → requires multisig / DAO / governance approval
  → timelock window for token holders to react
  → change executes only if approved
```

---

### Comparison

|  | Mode A (Vanilla) | Mode B (Registry-Aware) | Mode C (Escrow Deployer) |
| --- | --- | --- | --- |
| **Client requirement** | Any x402 client | Registry-aware client | Any x402 client |
| **Facilitator requirement** | Any x402 facilitator | Registry-aware facilitator | Any x402 facilitator |
| **Enforcement type** | Optimistic + economic (post-fact) | Cryptographic (pre-fact) | Third-party custodian |
| **Trust in resource server** | Required (watcher-enforced) | Not required | Only trust in custodian |
| **Adoption friction** | None | Moderate | High (best for institutional-grade financialization) |
| **Watcher relevance** | Primary enforcement | Secondary / observability | Secondary / observability |

---

### How They Coexist

A single registered endpoint supports both modes simultaneously. A vanilla client pays Mode A. A registry-aware client pays Mode B. Both settle to the same RevenueSplitter. The resource server serves one 402 response format and both client types handle it correctly according to their capability. Mode C is most relevant for institutional-grade security, where API ETFs and other products are being traded.

Over time, as registry-aware clients and facilitators become more common, the ecosystem naturally upgrades from economic to cryptographic enforcement without any migration or breaking change.

---

## Future Implications

Once tokenized API cash flow exists as a primitive, three directions become possible that each represent distinct financial product categories.

### API Yield Index

Rather than investing in a single API’s revenue token, an index token tracks the **top API revenue assets across Avalanche** — weighted by usage volume, rebalanced automatically.

- Tradable as a single ERC-20
- Composable as DeFi collateral
- Market makers can bootstrap liquidity against the index
- Exposure to Avalanche’s API economy as a whole, not single-API concentration risk

This is the ETF equivalent for API yield. Someone who doesn’t want to pick winning APIs can hold the index and earn diversified yield from the ecosystem’s aggregate usage. The index also creates a benchmark — a “API Economy Index” price that becomes a reference point for the entire category.

### Composable API Credits Pools

This flips the model entirely — rather than revenue flowing *out* to token holders, value flows *in* from communities.

**Shared API credits pools:**
- Developers and communities deposit AVAX or stablecoins into a pool
- Users draw from the pool to make API calls (access is socialized)
- Usage activity generates yield that flows back into the pool
- Communities can vote on which APIs their pool supports

This creates an **onchain commons economy** for API access. Instead of pay-per-call being an individual transaction, it becomes a community resource. A DAO could fund access to a critical AI inference API for all its members. A protocol could subsidize usage of its own APIs to drive adoption.

The viral hook: pools compete for community backing. APIs that earn more yield attract more pool deposits. High-usage APIs see their pools grow. Low-usage APIs lose backing. That is a market signal for API quality — without any centralized curation.

### API Revenue Futures & Dynamic Yield Markets

Rather than holding a revenue token that earns actual yield, futures let participants trade **expectations of future yield**.

- Issue API revenue contracts that pay out based on future usage
- Price them dynamically based on anticipated demand
- Developers can sell forward their future revenue at a locked rate (predictable income)
- Investors speculate on adoption trajectories

This creates a price discovery market for API growth. If you believe an AI inference API will 10x its call volume in 6 months, you buy its futures. If a developer wants guaranteed revenue regardless of adoption, they sell futures to lock in a floor.

Compare to ICOs: pure speculation on token price. API futures are speculation on *software adoption* — grounded in verifiable onchain usage data. The futures price is publicly discoverable, which itself becomes a signal. A rising futures price means the market believes in the API’s growth — that attracts more users, which confirms the thesis.

This is closer to a finance primitive than a product. It is the last piece of the stack that makes API yield a fully liquid, speculative, and hedgeable asset class.

---

## Hackathon Deliverables

The competition runs 6 weeks across three stages. Everything below is scoped to be achievable by a small team within that window. Deliverables are split by category and labeled by priority: **must-have** (required for a competitive submission) and **strong** (meaningfully improves the score).

### Summary

| # | Deliverable | Category | Priority | Status |
| --- | --- | --- | --- | --- |
| — | `RevenueSplitter.sol` | Smart Contract | must-have | Already built |
| 1 | `EndpointFactory.sol` | Smart Contract | must-have | New |
| 2 | `EndpointRevenueToken.sol` | Smart Contract | must-have | New |
| 3 | `APIIntegrityRegistry.sol` | Smart Contract | must-have | New |
| 4 | `APIRegistry.sol` | Smart Contract | strong | New |
| 5 | Mode A: Vanilla x402 support | x402 | must-have | By design |
| 6 | Mode B: Registry-aware client | x402 | strong | New |
| 7 | Mode B: Registry-aware facilitator | x402 | strong | New |
| 8 | Watcher CLI / script | Backend | must-have | New |
| 9 | Public API dashboard | Frontend | must-have | New |
| 10 | Developer onboarding flow | Frontend | strong | New |
| 11 | Investor token purchase flow | Frontend | strong | New |

---

### Smart Contracts

**Already built — reuse directly:**

**`RevenueSplitter.sol` — done**
Existing contract. USDC-based, BPS-split, Chainlink Automation compatible, supports arbitrary recipient addresses. This becomes the `payTo` address for each registered endpoint. Needs one addition: emit a `RevenueRecorded(apiId, amount, block)` event on `distribute()` for the dashboard indexer.

---

**New contracts to build:**

**1. `EndpointFactory.sol` — must-have**
The central registration contract. Key functions:
- `registerEndpoint(apiUrl, developerAddress, tokenSupply, splits[])` — deploys a `RevenueSplitter` and `EndpointRevenueToken`, registers both in the `APIIntegrityRegistry`, emits `EndpointRegistered(apiId, splitterAddress, tokenAddress)`
- `getEndpoint(apiId)` — returns splitter address, token address, registry entry
- `getAllEndpoints()` — returns full list for dashboard indexing

**2. `EndpointRevenueToken.sol` — must-have**
Per-endpoint ERC-20 yield token. Key properties:
- Minted at registration with fixed supply to the developer (who can sell/distribute)
- Registered as a BPS recipient in the endpoint’s `RevenueSplitter`
- On `distribute()`, the token contract’s USDC balance grows — holders can claim proportionally
- Transferable and tradable; holder list is onchain for distribution calculation
- Emits `YieldAccrued(amount)` and `YieldClaimed(holder, amount)`

**3. `APIIntegrityRegistry.sol` — must-have**
The trust and bonding layer. Key functions:
- `register(apiId, canonicalPayTo, bondAmount)` — called by factory on endpoint registration; deployer posts bond and commits the `RevenueSplitter` address as canonical `payTo`
- `submitMismatch(apiId, observedPayTo, proof)` — watcher submits dispute
- `challenge(mismatchId)` — deployer responds within window
- `finalize(mismatchId)` — if unchallenged, slashes bond; distributes to vault, watcher, burn
- `proposePayToChange(apiId, newAddress)` — begins 48-hour timelock
- `finalizePayToChange(apiId)` — commits change if unchallenged
- Bond denomination: AVAX with USD-floor enforced via Chainlink price feed (default path)

---

### x402 Enforcement — Dual Mode

**5. Mode A: Vanilla SDK support — by design, no deliverable required**

The RevenueSplitter is the `payTo` address. The resource server configures their 402 response to return it. Any vanilla x402 client and any vanilla facilitator settles USDC directly to that contract. No client or facilitator changes needed.

The resource server also includes `apiId` as an optional extension field in the 402 response:

```json
{
  "payTo": "0xRevenueSplitterAddress",
  "apiId": "api.example.com/pricing",
  "amount": "1000000",
  "currency": "USDC",
  "chain": "avalanche"
}
```

Vanilla clients ignore `apiId`. Registry-aware clients use it. One response, both modes.

---

**6. Mode B: Registry-Aware Client — ⚠️ Not implemented (see fraud note in Mode B section above and `docs/faq.md`)**

An extension to HTTPayer (or a standalone library) that upgrades payment routing when `apiId` is present in the 402 response:

- Detects `apiId` in the 402 response
- Queries `APIIntegrityRegistry.getCanonicalPayTo(apiId)` onchain
- Signs payment to the canonical address — ignores `payTo` from the 402 response entirely
- Falls back to `payTo` if `apiId` is absent or not in registry (vanilla behavior preserved)

This makes HTTPayer a drop-in upgrade — existing x402 flows continue working, and registered endpoints automatically get cryptographic enforcement with no operator changes.

---

**7. Mode B: Registry-Aware Facilitator — strong**

A facilitator server that verifies payment destination against the registry before broadcasting:

- Receives signed payment instruction from client
- If `apiId` present: checks `payment.to == registry.getCanonicalPayTo(apiId)`
- If match: settles onchain normally
- If mismatch: rejects payment, returns error — funds never move to wrong address
- If `apiId` absent: standard facilitator behavior (vanilla passthrough)

Resource servers that want cryptographic enforcement point to this facilitator. Those who want vanilla compatibility use any standard facilitator. Both are valid configurations for registered endpoints.

---

### Watcher Node

**8. Watcher CLI / Script — must-have**

The primary enforcement mechanism for Mode A (vanilla SDK) endpoints. A lightweight Node.js or Python process that:

- Reads all registered endpoints from `APIIntegrityRegistry`
- Periodically calls each API endpoint
- Parses the returned `payTo` and `apiId` from the 402 response
- Compares `payTo` against `registry.getCanonicalPayTo(apiId)`
- If mismatch: submits `submitMismatch()` to the registry contract

For Mode A endpoints, watchers are what keeps the resource server honest — they are not optional observability, they are the enforcement layer. For Mode B endpoints, watchers serve as a secondary observability and redundancy check.

For the demo, one watcher instance running locally is sufficient. The design goal is permissionless — anyone can run one, the network self-organizes around economic incentives.

---

### Frontend Dashboard

**9. Public API Dashboard — must-have**
The viral surface. A single-page app showing:

| Column | Source |
| --- | --- |
| API name | Registry |
| Revenue (USDC/day) | Splitter events, indexed |
| Yield % | Tokens outstanding / vault inflow |
| Bond amount | Registry |
| Integrity status | Registry (clean / disputed / slashed) |
| 7-day growth | Indexed vault events |

Clicking an API opens a detail view: full revenue history, token holders, distribution events, bond status, and a “buy tokens” flow.

**10. Developer Onboarding Flow — strong**
A simple wizard that lets a developer:
1. Connect wallet
2. Register their API URL and payTo address
3. Post a bond
4. Optionally deploy a vault and tokenize a % of revenue
5. Get a shareable API profile link

This makes the system feel like a product rather than a set of contracts.

**11. Investor Token Purchase Flow — strong**
On the API detail page: a “Buy Yield Tokens” button that:
- Shows current token price (derived from revenue rate and outstanding supply)
- Executes a token purchase against the vault
- Displays estimated yield based on current revenue run rate

Keep this simple — it does not need an AMM. A direct vault purchase at a fixed price is sufficient for the demo.

---

### Demo Script (Live Showcase)

The final stage requires a live judge demo. Recommended sequence:

**Step 1 — Mode A: vanilla payment flow**
Make a live API call using a standard x402 client. Show the 402 response with `payTo` = RevenueSplitter and `apiId` in the response. Show USDC settling directly to the RevenueSplitter — no custom client, no custom facilitator. Show the `RevenueRecorded` event on the block explorer.

**Step 2 — Mode B: registry-aware payment flow**
Repeat the same call using HTTPayer with registry-aware mode enabled. Show it detecting `apiId`, querying the registry, and signing to the canonical address — ignoring the `payTo` field entirely. Show the same RevenueSplitter receiving funds. Two clients, one contract, same result.

**Step 3 — Vault distributing**
Trigger `distribute()` on the RevenueSplitter. Show USDC flowing to the developer wallet and token holder wallets automatically. Show the dashboard updating in real time.

**Step 4 — Token yield reaction**
Simulate a usage spike (a script making rapid calls). Show vault inflow increasing. Show yield % and token value updating on the dashboard.

**Step 5 — Integrity enforcement (Mode A)**
Show a watcher running. Temporarily change the `payTo` on the demo API to a non-registry address. Show the watcher catching the mismatch and submitting proof onchain. Show the slash executing — funds flowing to vault holders, AVAX burned, integrity score updating to “Disputed.”

**Step 6 — Dashboard as punchline**
End on the dashboard. Multiple APIs ranked by revenue, yield, bond size, and integrity status. Enforcement mode visible per endpoint (vanilla / registry-aware). Live onchain, no mockups.

---

### What Is Explicitly Out of Scope

These are v2 items. Do not build them for the competition. Reference them in the pitch to show long-term depth.

| Out of Scope | Why |
| --- | --- |
| IAO / presale mechanism | High legal sensitivity, high complexity |
| API Yield Index token | Requires aggregation layer and liquidity bootstrapping |
| Revenue futures market | AMM or orderbook infrastructure — separate project |
| Yield stablecoin (e.g. GLUSD-style) | Layer 2 product — out of scope for 6 weeks |
| Watcher bonding / dual-bond model | Optimistic proof model without watcher bonds is sufficient for demo |
| Multi-token bond support | AVAX only for competition; contract parameterized for later |
| Production security audit | Note as pre-launch requirement, do not attempt in scope |
| Decentralized facilitator network | Single registry-aware facilitator instance sufficient for demo |

---

## Applicability to AI Agents

This system is a natural fit for the agentic economy. An AI agent exposed as an HTTP endpoint is structurally identical to any other API — it has a URL, it responds to requests, and it can return a 402 requiring payment before serving a response. Every component of this architecture applies directly.

---

### Agent as Resource Server (Earning Revenue)

An AI agent registered as an endpoint in the `APIIntegrityRegistry`:

- Exposes itself via HTTP with x402 payment enforcement
- Sets `payTo` to its `RevenueSplitter` contract
- Charges per inference, per signal, per tool call, or per any unit of output
- Revenue flows to the splitter → developer wallet + token holders automatically

The agent’s revenue stream becomes onchain-verifiable and investable. Token holders are effectively backing a specific agent’s adoption. If the agent sees usage growth, yield increases. This turns agent deployment into a capital formation event — not just a product launch.

**Examples:**
- AI trading signal agent — charges per signal, investors buy yield tokens representing 20% of future revenue
- AI inference endpoint — pay-per-prompt, revenue distributed to backers automatically
- Specialized AI tool (code review, document analysis) — per-call pricing, investable from day one

---

### Agent as Client (Paying for APIs)

An autonomous agent with a wallet can use x402 to pay for API calls without human intervention:

- Agent holds a wallet funded with USDC
- Makes API calls to registered endpoints
- Payment is handled automatically via payer server (HTTPayer)
- With registry-aware mode, agent verifies canonical `payTo` before signing — trustless machine-to-machine payment

Agents consuming paid APIs are first-class participants in this system. No human approval loop required. The economic relationship between agents — one agent paying another — is fully automated and onchain.

---

### Multi-Agent Pipelines

In a multi-agent system where agents call other agents:

```
Client → Agent A (orchestrator) → Agent B (tool) → Agent C (inference)
              ↓ pays                    ↓ pays
         RevenueSplitter A        RevenueSplitter B
```

Each agent in the pipeline has its own registered endpoint, its own splitter, and optionally its own revenue token. Revenue flows through the chain automatically. Investors can back individual agents within a pipeline or the orchestrator that drives traffic to all of them.

This is infrastructure for the **agentic economy** — where autonomous software earns, pays, and generates verifiable cash flows without human mediation.

---

### Why This Matters for the Pitch

AI agents are the fastest-growing category of API producers and consumers. x402 was designed in part for machine-to-machine payments. The registry + splitter system turns every agent endpoint into:

- An economically autonomous unit with verifiable revenue
- An investable asset (with optional token issuance)
- A participant in a composable financial stack

The narrative expands from “tokenized API revenue” to “infrastructure for the agentic economy.” Both are true. The second lands harder with judges in 2025-2026.

---

## Competition Positioning (Build Games)

| Judging Criterion | How This Maps |
| --- | --- |
| **Innovation** | API revenue made investable for the first time — registry + splitter as enforceable infrastructure |
| **Impact** | Capital formation primitive for Avalanche API builders |
| **Execution** | 3 new contracts + dual-mode x402 enforcement + watcher + dashboard in 6 weeks (2 contracts already built) |
| **Usability** | Public dashboard, clear flows for dev and investor |
| **Long-term potential** | Layer 0 for IAOs, index tokens, stablecoins, lending |

### Stage 1 Pitch Anchors (keep it tight)

1. The infrastructure — registry + splitter makes API revenue investable for the first time
2. The enforcement — optimistic + economic (Mode A) or cryptographic (Mode B); be honest about the distinction
3. The token layer — optional extension on top of the infrastructure; keeps regulatory surface manageable

Everything else (futures, index, lending, GLUSD) is v2 narrative. Mention it to show depth. Do not build it for the demo.

### Demo That Wins

1. Show API earning revenue per call — USDC settling to RevenueSplitter onchain
2. Show splitter distributing to developer wallet and token holders automatically
3. Show watcher catching a `payTo` mismatch — bond slash executing, integrity score updating
4. Show Mode B: registry-aware client ignoring a fraudulent `payTo`, paying canonical address
5. End on the dashboard — revenue, yield, bond, integrity status live

Lead with the infrastructure. Token yield is the hook, not the headline.

---

## Risks and Honest Caveats

| Risk | Mitigation |
| --- | --- |
| APIs need real usage to matter | Demo shows structure, not scale. Judges evaluate viability. |
| Onchain HTTP verification is not deterministic | Mode A is explicitly optimistic + economic, not cryptographic — be clear about this distinction, don’t oversell |
| Legal framing of revenue tokens | Frame as revenue participation tokens, not equity. For demo purposes this is conceptual. |
| Vault contract security | Scope is demo-grade. Production would require audit. |

Technically: very achievable. Narratively: genuinely novel. Competitively: strong.

---

## Legal Implications and Recommendations

This is not legal advice. The following is a structural analysis of the regulatory surface area this system touches and how to navigate it responsibly at each stage.

---

### The Core Risk: Securities Classification

Revenue tokens — ERC-20 claims on a percentage of future API cash flow — could be interpreted as securities under the Howey Test in the US:

1. Investment of money ✓
2. In a common enterprise ✓
3. With expectation of profit ✓
4. Derived from the efforts of others — **this is the contested point**

If the API’s revenue is entirely dependent on the deployer’s continued effort (running the API, marketing it, maintaining it), then token holders are profiting from someone else’s work. That is the Howey threshold. The SEC has applied this framing to yield-bearing tokens before.

**This does not mean you cannot build it.** It means you need to frame it carefully and structure accordingly.

---

### Framing Recommendations

**Use “revenue participation tokens” — not equity, not securities, not shares.**

The key distinction to maintain:
- Token holders have no ownership stake in the API or the developer’s business
- Token holders have no governance rights over the API
- Token holders have no claim in bankruptcy or dissolution
- The smart contract is the entire scope of entitlement — nothing more

This positions the token closer to a **contractual cash flow instrument** than to equity. Similar to royalty financing (artists selling future streaming royalties) or revenue-based financing — neither of which is automatically classified as a security.

---

### Jurisdiction-by-Jurisdiction Exposure

| Jurisdiction | Risk Level | Notes |
| --- | --- | --- |
| **United States** | High | SEC is aggressive on yield-bearing tokens. Howey Test applies. Avoid marketing to US persons in early stages. |
| **European Union** | Medium | MiCA framework is live. Revenue tokens may fall under “asset-referenced tokens” or utility token exemptions depending on structure. |
| **Switzerland** | Low-Medium | FINMA has clearer utility token guidance. Revenue participation tokens have precedent. |
| **UAE / ADGM** | Low | Progressive crypto regulation, explicit token categories, more favorable for structured instruments. |
| **Singapore** | Low-Medium | MAS has clear guidelines. Utility tokens with contractual cash flows have navigated successfully. |

---

### Structural Mitigations

**1. No investment language.** Never describe tokens as an “investment.” Use “participation,” “access,” “allocation,” or “entitlement.”

**2. Accredited investor gating (US).** If targeting US persons, gate token sales behind accredited investor verification. This does not eliminate securities risk but significantly reduces enforcement priority.

**3. Utility framing for Credits Pools.** The Composable API Credits Pool variant (communities pool AVAX to access APIs) has a much cleaner legal profile — it resembles a prepaid service credit, not an investment instrument. This is the lowest-risk product in the stack.

**4. Non-US entity deployment.** Deploying the protocol from a Swiss, Cayman, or UAE entity with explicit geographic restrictions on US persons is standard practice for DeFi protocols in this category.

**5. No profit guarantee.** Contracts should not guarantee yield. They distribute whatever revenue flows in — if the API earns nothing, token holders receive nothing. Make this explicit onchain and in any documentation.

**6. Decentralization over time.** The more the protocol decentralizes (permissionless watchers, onchain governance, no admin key), the weaker the “efforts of others” prong of Howey becomes. Build toward decentralization intentionally.

---

### What the IAO Framing Adds

Initial API Offerings — preselling future yield before the API launches — are the highest-risk product in the stack. Selling future cash flow from an asset that does not yet generate revenue, where proceeds fund the builder, is close to the textbook securities definition.

**Recommendation:** For the competition, frame IAOs as a conceptual extension. Do not build or demo them as a token sale mechanism. Post-competition, if pursuing IAOs seriously, engage legal counsel before launch and consider limiting to accredited investors in compliant jurisdictions.

---

### For the Hackathon Specifically

For Build Games, this is a **demo and proof-of-concept**. No real capital is at risk, no tokens are being publicly sold, and no investment is being solicited. That context insulates the project entirely from securities enforcement. Judges are evaluating the architecture, not the legality of a live product.

The right framing for the pitch:

> “We are aware of the regulatory considerations around revenue participation tokens. We are building the technical primitive. Compliant deployment pathways exist — accredited investor gating, non-US entity structure, and utility framing for the credits pool variant — and we would engage legal counsel before any public token issuance.”
> 

That answer demonstrates maturity. It does not undermine the pitch; it strengthens it.

---

## Summary

This is two primitives, stacked.

---

**Layer 0 — Infrastructure Primitive**

The `APIIntegrityRegistry` + `RevenueSplitter` make API revenue routable, verifiable, and enforceable onchain for the first time. Any x402-enabled API — including AI agent endpoints — can register, receive payment to a canonical onchain address, and distribute revenue automatically. Vanilla x402 clients and facilitators work without modification. Registry-aware clients and facilitators upgrade enforcement from optimistic + economic to cryptographic.

This layer has value independently of any token. An operator can use it purely for payment enforcement and automated revenue splitting with no tokenization at all.

---

**Layer 1 — Financial Primitive**

Once revenue flows through the splitter, it can optionally be tokenized. `EndpointRevenueToken` is a per-endpoint ERC-20 representing a yield claim against a specific API’s revenue stream. This is a new type of cash flow instrument — not a governance token, not a speculative asset, not equity. A contractual, onchain entitlement to a share of real software usage revenue.

Token issuance is opt-in. The operator chooses whether to tokenize and what percentage. The smart contract is the entire scope of entitlement. Revenue flows automatically — no trust required.

---

**Layer 2 — Applications**

Once per-endpoint revenue tokens exist, they become composable inputs: yield-bearing stablecoins, revenue futures, API yield indexes, lending collateral, Initial API Offerings. These are not core deliverables — they are the long-term narrative that demonstrates why the infrastructure matters.

---

**Why AI Agents Change the Scale**

AI agents exposed as HTTP endpoints are the fastest-growing category of API producers. Every inference, every tool call, every signal is a billable unit. x402 was built for machine-to-machine payments. This system turns every deployed agent into an economically autonomous unit with verifiable revenue — and optionally, an investable one.

The infrastructure primitive enables the agentic economy. The financial primitive makes individual agents backable.

---

**The honest framing for judges:**

- The registry + splitter is infrastructure. It solves a real problem (verifiable payment routing) without requiring any tokenization.
- Revenue tokens are a financial primitive layered on top. Novel, useful, legally sensitive — handle with care.
- Mode A enforcement is optimistic + economic. Mode B is cryptographic. Both are valid; be clear about which is which.
- This is not a new asset class. It is API revenue made investable for the first time.