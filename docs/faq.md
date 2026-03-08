# FAQ — Security, Fraud, and Attack Surface

Frequently asked questions about how the protocol handles adversarial behavior, fraudulent registrations, and payment routing security.

---

## Can someone register another provider's API endpoint without permission?

Yes — registration is permissionless. Anyone can call `registerEndpoint()` for any URL. However, this is economically self-defeating by design.

**What the attacker can do:**
- Post a bond and register `api.example.com/v1/pricing` before the real provider does
- Deploy their own vault and splitter, name it anything they like

**What the attacker cannot do:**
- Capture any revenue from that API
- Avoid getting slashed

**Why it's self-defeating:**
x402 payment routing is controlled by the 402 response the API server actually returns — not by anything in the registry. The API server returns `payTo = Bob's address`. Clients pay Bob directly. The attacker's splitter receives nothing.

Meanwhile, the attacker has locked up a bond. The Chainlink Functions verification in `ChallengeManager` checks that the live 402 response's `payTo` matches the registered splitter. Since it doesn't match (Bob's address ≠ attacker's splitter), any challenger can open a challenge and the attacker is slashed immediately.

**Net result:** Bond lost. Zero revenue captured. The attack is strictly negative EV.

---

## What if a fraudulent registrant uses the real provider's `payTo` address in their registration?

If the attacker registers with the correct `payTo` (the real provider's existing address, not their own splitter), the Chainlink Functions hash check will match the live 402 response — so they won't be slashed via `payTo` mismatch.

But this scenario is also economically irrational:

- The real provider still receives all payments (the 402 response points to them)
- The attacker's vault earns zero revenue — share price stays at 0
- Any investor can observe this on-chain: `totalAssets() == 0`, no `Distributed` events
- The attacker has locked up bond capital for a vault that is openly worthless

The primary residual risk is **investor confusion** — a vault named "OpenAI API Revenue" with no revenue could mislead unsophisticated investors. This is addressed by:
1. Frontend prominently displaying `sharePrice()`, `totalAssets()`, and historical `Distributed` events
2. ERC-8004 agent identity integration (future) — cross-referencing the registered `agentWallet` and declared endpoints against the vault's registered splitter

---

## Why isn't a registry-aware x402 client implemented? Wouldn't that prevent `payTo` fraud?

This approach was explicitly considered and rejected due to a **fraud inversion problem**.

**What a registry-aware client would do:**
Instead of paying the `payTo` address in the 402 response, the client looks up the registered splitter in `APIIntegrityRegistry` and pays that address directly, ignoring the 402 `payTo`.

**Why this creates a worse attack:**

Under vanilla x402 (current design):
```
Mallory registers api.example.com → splitter = Mallory's address
Client calls api.example.com → gets 402 with payTo = Bob's address
Client pays Bob (correct)
Challenge: payTo ≠ Mallory's splitter → Mallory slashed
```
Attack outcome: **Mallory loses bond, Bob gets paid, attack fails**

Under registry-aware client:
```
Mallory registers api.example.com → splitter = Mallory's address
Client calls api.example.com → gets 402 with payTo = Bob's address
Client IGNORES payTo, looks up registry → finds Mallory's splitter
Client pays Mallory (wrong)
Bob receives nothing
```
Attack outcome: **Mallory steals Bob's revenue. Attack succeeds.**

The registry-aware approach inverts the security model: what was a self-defeating attack becomes a profitable payment theft. The bond cost is now just a one-time cost to acquire a revenue stream, potentially profitable if the stolen revenue exceeds the bond.

**The correct division of responsibility:**
- **402 response** (`payTo`) → payment routing. Controlled by the API server. Auditable by watchers.
- **Registry** → integrity verification and revenue tokenization. Chainlink Functions verifies `payTo` matches the splitter. Fraud → slash.

The registry is not a payment router. It is an integrity oracle and investment primitive.

---

## What is the protocol treasury fee and why is it capped at 3%?

The `APIRegistryFactory` enforces `MAX_PROTOCOL_BP = 300` (3%) as a hard constant. The factory constructor reverts if a higher value is passed.

**Why cap it in the contract, not just in the deployment config?**

`protocolTreasuryBp` is immutable after factory deployment — it cannot be changed by the protocol operator after the fact. But providers need to trust that the *factory itself* can never be deployed with an abusive fee. Publishing `MAX_PROTOCOL_BP` as a readable constant lets any provider or investor verify this guarantee on-chain without trusting the deployer.

**Why 3%?**
- Stripe charges ~2.9% on card payments — a protocol fee on already-settled onchain revenue should be below that
- 1–3% leaves the vast majority of revenue in the vault, keeping vault shares attractive to investors
- The default deployment uses 2% (`TREASURY_BP=200`)

---

## What happens if the real provider wants to register their own endpoint but someone already squatted it?

The squatter's registration is economically worthless (no revenue flows to their vault — see above). But the real provider cannot re-register the same endpoint if the registry uses the URL as a unique key.

**Mitigation paths:**
1. **Challenge immediately** — if the squatter's registered `payTo` doesn't match the live 402 response, open a challenge. Squatter is slashed and registration can be invalidated.
2. **ERC-8004 integration (future)** — cross-referencing the endpoint URL against an ERC-8004 agent identity that the real provider controls would allow the registry to distinguish legitimate from fraudulent registrations at the time of registration, before any challenge is needed. See `docs/endpoint-ownership-verification.md`.
3. **`.well-known` domain verification (future)** — requiring a domain-controlled file at `/.well-known/api-integrity.json` as part of registration proves the registrant controls the web server at the endpoint's domain.

---

## Can a provider change their `payTo` address after registration?

The `payTo` address (i.e., the splitter) is set at registration time and enforced by the integrity hash. Changing the live 402 response to return a different `payTo` would immediately create a hash mismatch — any watcher or challenger can detect this and submit a challenge.

A provider who legitimately wants to migrate to a new splitter (e.g., after deploying an upgraded contract) should:
1. Deploy the new splitter via `APIRegistryFactory.deployProvider()`
2. Update their API server's 402 response to return the new splitter address
3. Re-register the endpoint (or use a timelock update flow if implemented)

The 7-day bond withdrawal cooldown ensures bond capital remains at risk during any transition window.

---

## Is Mode C (escrow deployer) still a valid enforcement model?

Yes. Mode C is unaffected by the Mode B fraud concern.

Mode B's problem was that registry-aware *clients* look up the registry and pay to the registered splitter — meaning a fraudulent registration redirects client payments to the attacker. Mode C doesn't change client behavior at all. Clients still pay whatever `payTo` the 402 response returns. Mode C only governs *who is allowed to change the on-chain configuration* — a third-party custodian (multisig or DAO) must approve any updates to the registered `payTo` or endpoint hash.

This is appropriate for institutional-grade deployments where large vault investors want a governance layer above the watcher/slash model: even if the resource server is compromised, a fraudulent `payTo` change cannot be finalized without custodian approval. The trust model shifts from "watchers will catch it within the challenge window" to "a human committee must approve any change."

---

## How is the required bond/stake calculated, and is it correct?

**Current implementation:** `minimumStakeRequired` is a flat global amount (default 1000 USDC) set at registry deployment. It applies equally to all providers regardless of API revenue or vault TVL. The slash percentage is 20% of total stake.

**The problem with a flat minimum:**
A fixed $1,000 bond is economically irrelevant for an API earning $50,000/week. A provider could redirect `payTo` for one week, capture the redirected revenue, and absorb the slash as an operating cost — net positive.

**Challenge math constraint:**
The bond must be large enough that challenges are economically rational for watchers:

```
challenger_profit = (bond × slash_pct × challenger_share) − challenge_fee > 0

With slash_pct = 20%, challenger_share = 90%, challenge_fee = 100 USDC:
Minimum rational bond ≈ 556 USDC
```

The 1,000 USDC minimum clears this bar, but it doesn't scale with stakes.

**Ideal design — TVL-linked floor:**

```
required_bond = max(MIN_STAKE, vault.totalAssets() × COVERAGE_RATIO)
```

- `MIN_STAKE` (e.g., 500 USDC) — anti-spam floor, makes Sybil registrations costly without capital
- `vault.totalAssets() × 10%` — scales with investor exposure. As the vault grows and takes on more capital, the provider's bond obligation grows proportionally, maintaining a meaningful coverage ratio
- Checked dynamically: when a provider calls `requestUnstake()`, the contract reads current vault TVL and rejects the withdrawal if the remaining bond would fall below the floor

This means a provider with a vault holding $100,000 in investor USDC must maintain at least $10,000 staked. The bond becomes a first-loss capital layer for investors — meaningful protection rather than a token gesture.

**For the hackathon demo:** the flat minimum is acceptable. The TVL-linked floor is the correct production direction and can be added to `StakeManager` as a future upgrade.

---

## Can a provider voluntarily withdraw their stake?

Yes. The current `StakeManager` implements a two-step voluntary withdrawal:

1. `requestUnstake(amount)` — starts the cooldown clock. Sets `unlockTimestamp = block.timestamp + withdrawCooldown` (default 7 days).
2. `withdraw(amount)` — callable only after `unlockTimestamp` has passed. Transfers USDC to the provider.

**The 7-day cooldown** exists so that watchers have time to detect and submit a `payTo` mismatch after a provider signals intent to exit. Without it, a provider could redirect `payTo`, immediately withdraw their stake, and exit before a challenge resolves. The cooldown window ensures the bond remains at risk during the challenge window.

**Partial withdrawal constraint:** After withdrawal, the remaining stake must be either zero or ≥ `minimumStakeRequired`. A provider cannot partially withdraw to below the minimum while keeping endpoints active — they must either maintain the minimum or exit fully.

**Voluntary unstake does not forfeit the bond.** Stake is only lost via the `slash()` path triggered by `ChallengeManager` after a successful challenge. A clean voluntary withdrawal returns the full staked amount.

---

## Is there a deprecation or shutdown process for an endpoint or provider?

**Current state:** Incomplete. The `Provider` and `Endpoint` structs both have `active` booleans, but no function currently exists to set them to `false`. Once registered, an endpoint is permanently active in the contract — there is no provider-initiated deactivation.

**What a clean deprecation flow should look like:**

| Step | Action | Effect |
|---|---|---|
| 1 | `deactivateEndpoint(endpointId)` | Sets `active = false`, stops Chainlink verification checks, signals clients |
| 2 | `deactivateProvider(providerId)` | Deactivates all endpoints under the provider |
| 3 | `requestUnstake()` | Starts 7-day cooldown |
| 4 | `withdraw()` after cooldown | Bond returned in full (minus any prior slashes) |

`deactivateEndpoint()` and `deactivateProvider()` are missing and should be added to `APIIntegrityRegistry`, callable only by the provider owner (`p.owner == msg.sender`).

**What happens if a provider just shuts down their API without deactivating:**
- Revenue stops flowing (no more x402 payments)
- The splitter and vault remain deployed indefinitely — this is correct
- Investors can redeem shares at any time via `vault.redeem()` at whatever the final share price is
- Shares do not expire; the vault does not need to be "closed"
- The provider's bond remains locked until they call `requestUnstake()` and wait out the cooldown

**What happens if the provider changes `payTo` without using the deprecation flow:**
- Hash mismatch → challengeable → stake slashed
- Bond is not returned; it goes to the challenger and protocol treasury
- This is the punitive path, not the graceful exit path

**The vault is indefinite by design.** If an API is shut down cleanly, revenue stops, `sharePrice()` stops rising, and existing holders redeem at the last accrued value. The ERC4626 `redeem()` function always works as long as there is USDC in the vault, regardless of whether the API is still running.

---

## Does the protocol work without Chainlink Functions?

Partially. Without Chainlink Functions:

- **Layer 0 (enforcement)** is degraded — challenges cannot be verified onchain, so the slash mechanism doesn't function
- **Layer 1 (revenue tokenization)** works fully — vault shares, splitter distributions, and share price appreciation are independent of Chainlink
- **Layer 2 (financial products)** works fully — all DeFi instruments operate on vault share price, which is driven purely by direct USDC transfers

The registry can still record endpoint metadata and integrity hashes; watchers can still observe mismatches off-chain. Chainlink Functions is required only for the permissionless on-chain challenge resolution step.

---

## Is the vault share supply fixed forever?

After genesis, yes — enforced at the contract level. `genesisMint()` can only be called once (`genesisComplete` flag) and is owner-only. `deposit()` and `mint()` are overridden to revert, so no new shares can ever be created after genesis regardless of who calls them.

Revenue flows in as direct USDC transfers from the splitter — `totalAssets()` grows, `totalSupply()` stays fixed, share price rises. Shares are acquired via genesis distribution (developer wallet, IAO, vesting contract, etc.) and traded on secondary markets only.

`redeem()` and `withdraw()` remain functional so existing holders can exit for their pro-rata USDC, and so Layer 2 contracts (`APIRevenueFuture`, `APIYieldIndex`, `RevShareStable`) can redeem vault shares at settlement.
