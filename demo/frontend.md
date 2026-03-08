# Frontend Demo Plan

## Overview

A single-page web app on Avalanche Fuji testnet. Connect a wallet, interact with the protocol in real time. No backend — all reads/writes go directly to deployed contracts via viem/wagmi.

**Stack:** Next.js + wagmi + viem + shadcn/ui
**Network:** Avalanche Fuji (chainId 43113)
**Token:** Testnet USDC (faucet link in UI)

---

## Global Header

- Connect wallet button (RainbowKit or ConnectKit)
- Network indicator — warn if not on Fuji, one-click switch
- Live stats bar: total providers registered · total USDC in vaults · total challenges opened

---

## Tab Layout

```
[ Layer 0: Integrity ] [ Layer 1: Revenue Vault ] [ Layer 2: Financial Products ]
```

---

## Layer 0 — Integrity

> Register APIs, post stake, and challenge endpoint integrity onchain.

### Register Endpoint

**UI Flow:**

1. Form:
   - API endpoint URL (e.g. `https://api.example.com/v1/pricing`)
   - HTTP method (GET / POST)
   - Revenue token name + symbol (e.g. `API Yield Token`, `AYT`)
   - Genesis shares to mint (raw units, 6 decimals)
   - Genesis recipient address (defaults to connected wallet)
   - Provider treasury address (optional — leave blank for 0)
   - Provider treasury cut % (0–100%, displayed as basis points; 0 routes all to vault)
   - Stake amount (USDC — must meet protocol minimum)

2. "Compute Integrity Hash" — runs hash logic client-side, displays `bytes32` for user verification before submitting

3. Transaction sequence:
   - `usdc.approve(stakeManager, stakeAmount)`
   - `factory.deployProvider(name, symbol, genesisShares, genesisRecipient, providerTreasury, providerTreasuryBp)` → returns vault + splitter addresses
   - `stakeManager.stake(amount)`
   - `registry.registerProvider(metadataURI, payoutAddress, splitterAddress)`
   - `registry.registerEndpoint(providerId, path, method, hash)`

4. Success card: vault address · splitter address · endpoint ID · shareable link to Layer 1 vault view

**Edge cases:**
- Validate URL format before hash computation
- Show faucet link if USDC balance < minimum stake
- Spinner between each tx step with step indicator

---

### Stake Manager

- Current stake balance for connected wallet
- "Add Stake" / "Request Withdrawal" buttons
- 7-day cooldown countdown if withdrawal pending
- Minimum stake threshold displayed

| Action | Contract | Function |
|---|---|---|
| Deploy vault + splitter | `APIRegistryFactory` | `deployProvider(name, symbol, genesisShares, genesisRecipient, providerTreasury, providerTreasuryBp)` |
| Register provider | `APIIntegrityRegistry` | `registerProvider(uri, payout, splitter)` |
| Register endpoint | `APIIntegrityRegistry` | `registerEndpoint(providerId, path, method, hash)` |
| Stake USDC | `StakeManager` | `stake(amount)` |
| Request withdrawal | `StakeManager` | `requestWithdrawal(amount)` |

---

### Challenge an Endpoint

**UI Flow:**

1. Endpoint picker — search by URL or endpoint ID, shows:
   - Last verified timestamp
   - Registered integrity hash
   - Provider stake bonded (USDC)

2. Challenge fee display — pulled from `challengeManager.challengeFee()`

3. "Open Challenge" button:
   - `usdc.approve(challengeManager, fee)`
   - `challengeManager.openChallenge(endpointId)`
   - Pending state: "Chainlink Functions is verifying the endpoint..."

4. Poll for `ChallengeResolved`:
   - **Valid** — green checkmark, challenger refunded, hash confirmed
   - **Invalid** — red alert, provider slashed, challenger rewarded; shows slash amount
   - Chainlink Functions request ID + link to Functions explorer

5. Challenge history table: endpoint · challenger · outcome · reward earned

| Action | Contract | Function |
|---|---|---|
| Open challenge | `ChallengeManager` | `openChallenge(endpointId)` |

---

## Layer 1 — Revenue Vault

> Invest in an API's revenue stream. Every x402 payment increases share price.

### Vault Explorer

Left panel — vault selector (search by name/symbol/address):
- Share price (`sharePrice()`) — displayed in USDC per share, 6 decimal formatted
- Market cap — `sharePrice() × totalSupply()`
- Total assets (USDC in vault)
- Total supply (shares outstanding)
- Provider treasury split % / protocol treasury split %
- Genesis shares minted to whom

Right panel — live activity feed:
- Recent `Distributed` events from the splitter: timestamp · total amount · vault portion · protocol cut · provider cut
- Share price sparkline (pulled from `Distributed` event history)

---

### Invest (Buy Vault Shares)

1. USDC amount input
   - Preview: "You will receive X vault shares at current price of Y USDC/share"

2. Transaction:
   - `usdc.approve(vault, amount)`
   - `vault.deposit(amount, receiver)`

3. Position card post-deposit:
   - Share balance · current value (USDC) · unrealised yield since deposit

---

### Trigger Distribution

Any visitor can distribute pending revenue:

- Shows `splitter.pendingDistribution()` — undistributed USDC sitting in the splitter
- "Distribute" button → `splitter.distribute()`
- After tx: shows how much went to vault, protocol treasury, provider treasury

---

### My Vault Positions

- Table of all vaults where connected wallet holds shares
- Per vault: share balance · current USDC value · entry price (computed from deposit events) · unrealised yield
- "Redeem" button per vault → `vault.redeem(shares, receiver, owner)`

| Action | Contract | Function |
|---|---|---|
| Deposit USDC | `ProviderRevenueVault` | `deposit(assets, receiver)` |
| Redeem shares | `ProviderRevenueVault` | `redeem(shares, receiver, owner)` |
| Distribute revenue | `ProviderRevenueSplitter` | `distribute()` |

---

## Layer 2 — Financial Products

> DeFi instruments built on vault shares. Each sub-section is its own panel within the tab.

### CDP Stablecoin (APIUSD)

Deposit vault shares as collateral → mint APIUSD at 70% LTV.

**Mint flow:**
1. Select vault shares (shows balance + current USDC value)
2. Enter collateral amount → auto-preview max mintable at 70% LTV
3. Enter APIUSD amount — health factor displayed in real time (color: green > 1.5, yellow 1.0–1.5, red < 1.0)
4. `apiusd.open(collateralShares, mintAmount)`

**Manage position:**
- Health factor live gauge
- Add collateral / remove collateral / mint more / repay buttons
- Liquidation price shown

**Repay:**
- `usdc.approve(apiusd, amount)` → `apiusd.repay(amount)` → `apiusd.close()` to reclaim shares

| Action | Contract | Function |
|---|---|---|
| Open CDP | `APIUSD` | `open(collateral, mintAmount)` |
| Add collateral | `APIUSD` | `addCollateral(amount)` |
| Repay | `APIUSD` | `repay(amount)` |
| Close position | `APIUSD` | `close()` |

---

### Yield-Bearing Stablecoins

Three flavours — panel toggle to switch between them:

| Stable | Mechanism | Panel shows |
|---|---|---|
| `RevShareStable` | Vault shares in/out. Rate = vault USDC value / supply. | Exchange rate · APR (7d) · redeem for vault shares |
| `yAPIUSD` | USDC in/out. Provider-seeded with vault shares. | Exchange rate · USDC deposited · vault shares held · APR |
| `wcAPIUSD` | USDC in/out. Provider borrowed against share collateral. | Exchange rate · loan health · interest rate · APR |

**Common UI per stable:**
- Exchange rate (1 stable = X USDC)
- Total supply · Total backing value
- Mint / Redeem inputs with preview
- APR computed from `calculateAPR()` (or rate snapshots)

---

### Initial API Offering (IAO)

**Browse tab:** Table of active IAOs — API name · goal · raised · deadline · status (FUNDRAISING / ACTIVE / CANCELLED)

**Contribute flow:**
1. Select IAO
2. Enter USDC amount — preview IAO tokens to receive at current `tokenPrice`
3. `usdc.approve(iao, amount)` → `iao.contribute(amount)`

**Claim flow (after IAO goes ACTIVE):**
- `iao.harvest()` — deposits accumulated USDC into vault (callable by anyone)
- `iao.claim()` — claim accrued vault shares for IAO token balance

**My IAOs panel:**
- IAO token balance · pending vault shares (`claimable()`) · Claim button

| Action | Contract | Function |
|---|---|---|
| Contribute | `InitialAPIOffering` | `contribute(amount)` |
| Harvest to vault | `InitialAPIOffering` | `harvest()` |
| Claim shares | `InitialAPIOffering` | `claim()` |

---

### API Yield Index

A weighted basket of vault shares tradable as a single ERC20.

**Index dashboard:**
- Current components (vault name · weight % · current share price)
- Index price per token (`pricePerShare()`)
- Total index value

**Deposit flow:**
1. Enter target USDC value
2. `index.quote(usdcTarget)` → shows required shares per component
3. Approve each vault token → `index.deposit(sharesIn[])`

**Redeem flow:**
- Enter index token amount → preview pro-rata component shares received
- `index.redeem(indexAmount)`

| Action | Contract | Function |
|---|---|---|
| Quote inputs | `APIYieldIndex` | `quote(usdcTarget)` |
| Deposit | `APIYieldIndex` | `deposit(sharesIn[])` |
| Redeem | `APIYieldIndex` | `redeem(indexAmount)` |

---

### API Revenue Futures

Revenue forward notes — provider locks collateral, buyer receives face value at expiry.

**Browse notes:** Table — API · face value · purchase price · implied discount rate · expiry · status

**Buy a note:**
- Select Open note
- See: face value · purchase price · implied discount rate (annualised YTM) · collateralisation ratio · expiry
- `usdc.approve(future, purchasePrice)` → `future.purchaseNote(noteId)`

**Settle at expiry:**
- Mature notes show "Settle" button (permissionless)
- `future.settle(noteId)` — buyer receives face value (or all collateral if short)

**Create a note (provider):**
- Enter vault to use · face value · purchase price · term · collateral shares
- Collateralisation ratio preview (must be ≥ 120%)
- `vault.approve(future, collateralShares)` → `future.createNote(...)`

| Action | Contract | Function |
|---|---|---|
| Create note | `APIRevenueFuture` | `createNote(vault, faceValue, purchasePrice, term, collateral)` |
| Purchase note | `APIRevenueFuture` | `purchaseNote(noteId)` |
| Settle | `APIRevenueFuture` | `settle(noteId)` |

---

## Demo Mode (Guided Tour)

A "Demo Mode" button visible on all tabs walks judges through a pre-funded scenario:

1. **Layer 0** — show pre-registered endpoint `api.demo.xyz/v1/price` with stake posted
2. **Layer 0** — open a challenge → Chainlink resolves as valid (~60s)
3. **Layer 1** — trigger `distribute()` → watch share price tick up in real time
4. **Layer 1** — deposit 100 USDC → receive vault shares
5. **Layer 2** — mint 50 APIUSD against the shares (CDP)
6. **Layer 2** — view same vault shares inside the IAO and Yield Index panels

Each step highlights the active UI element with an explanatory callout. Progress indicator shows which act of the demo is active.

---

## What Still Needs to Be Built

| Item | Notes |
|---|---|
| Next.js app scaffold | wagmi + viem + shadcn/ui, Fuji chain config |
| Contract ABIs + addresses | After Fuji deployment via `DeployAll.s.sol` |
| Demo x402 API server | Node.js server returning 402 with splitter as `payTo`; simulates revenue |
| APY calculation | Rolling `Distributed` event aggregation (7-day window) |
| Share price sparkline | Pull from `GenesisMint` + `Distributed` event history |
| Chainlink Functions subscription | Required before challenge flow works |
