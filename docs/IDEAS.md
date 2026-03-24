# Ideas Backlog

Concepts worth exploring in future versions. Not planned for the current build.

---

## Self-Funding Bond via Revenue Split

Instead of requiring manual bond top-ups as vault TVL grows, a portion of API revenue is automatically routed to the provider's stake via a fourth splitter recipient:

```
protocolTreasuryBp  →  protocol treasury       (USDC)
providerTreasuryBp  →  provider treasury        (USDC, optional)
bondBp              →  StakeManager.stakeFor()  (auto top-up)
vaultBp             →  vault direct transfer    (remainder)
```

Set at deployment alongside the other splits — immutable after. Every `distribute()` call grows the bond proportionally to revenue volume. As the API earns more, the bond grows. As vault TVL grows (driven by the same revenue), the bond keeps pace automatically. No manual monitoring or top-up required.

**Why it works:** the bond is funded by the thing it's securing. A high-revenue API naturally maintains a high bond. Coverage ratio stays roughly stable without intervention.

**Implementation changes needed:**
- `StakeManager` needs `stakeFor(address provider, uint256 amount)` — accepts a direct USDC transfer and credits `stakes[provider]`. Splitter sends USDC and calls in one step; no approval needed.
- `ProviderRevenueSplitter` gets two new immutables: `stakeManager` address and `provider` address (known at factory deploy time).
- `ProviderRevenueSplitter` constructor and `distribute()` updated to handle the fourth recipient when `bondBp > 0`.
- `APIRegistryFactory.deployProvider()` gets `bondBp` param; passes `stakeManager` and `msg.sender` as provider to the splitter.
- `bondBp` validation: `protocolBp + providerBp + bondBp + vaultBp == 10_000` (vaultBp is the remainder).

**Interaction with TVL-linked bond floor:** combines naturally. The floor sets the target; the auto-top-up continuously moves toward it. A new API starts below the floor (small TVL, small bond), but as revenue flows and the bond accumulates, coverage improves organically without any action from the provider.

---

## Yield-Bearing Stake

Instead of USDC sitting idle in `StakeManager`, the bonded capital is deployed into a yield-generating protocol. The provider earns yield on their locked bond, partially offsetting the opportunity cost of posting collateral.

**Mechanism:**
```
provider stakes USDC
  → StakeManager deposits into ERC4626 yield vault (Aave, Benqi, etc.)
  → records vault shares on behalf of provider

clean exit
  → redeem shares → USDC + accrued yield returned to provider

slash event
  → redeem slashBp% of shares → USDC (principal + yield) split to challenger + protocol
```

**Target yield sources on Avalanche:**
- Benqi (`qiUSDC`) — Avalanche-native, Fuji testnet deployed, ERC4626-compatible
- Aave V3 (`aUSDC`) — on Avalanche mainnet

**Provider economics with yield-bearing stake:**
```
API revenue    → vault share appreciation    (primary upside)
Bond yield     → Aave/Benqi APY             (opportunity cost offset)
Bond principal → returned on clean exit     (recoverable)
Bond total     → slashed on fraud           (deterrent, stronger than principal-only)
```

**Slash mechanics:** slash the full position (principal + accrued yield). Provider earns yield for honest participation; loses everything including earned yield on fraud. Stronger deterrent than principal-only slash.

**Composability note:** A future version could let providers stake into each other's `ProviderRevenueVaults` — staking earns API revenue yield and simultaneously secures the protocol. Creates mutual alignment between providers. Introduces correlation risk if a staked vault's API also fails.

**Implementation:** `StakeManager` takes an additional constructor param `yieldVault` (ERC4626). On `stake()`, deposit USDC into yield vault and record shares. On `withdraw()` and `slash()`, redeem shares first. Backward-compatible if `yieldVault == address(0)` (skip yield wrapping).

---

## Revenue-Linked Bond Floor

Replace the flat `minimumStakeRequired` with a dynamic floor that scales with API revenue volume. Since revenue now flows pass-through via `ProviderRevenueSplitter` (no vault TVL), the bond should scale with revenue velocity rather than locked capital.

```
required_bond = max(MIN_STAKE, trailing_volume × COVERAGE_RATIO)
```

- `MIN_STAKE` (e.g., 500 USDC) — anti-spam floor
- `COVERAGE_RATIO` (e.g., 10–20%) — bond as first-loss layer for dividend holders

### What "at-risk" amount should the bond cover?

Three approaches, depending on how we measure economic exposure:

#### Option 1: Unclaimed Balance
```
at_risk = revenueShare.totalPending() × COVERAGE_RATIO
```

Directly measures what's owed to holders right now. Pro: measurable on-chain. Con: depends on holder claim behavior; new APIs with few holders have near-zero unclaimed → tiny bond even if revenue is high.

#### Option 2: Rolling Volume (recommended)
```
at_risk = trailing_N_volume × COVERAGE_RATIO
```

Uses trailing revenue as a proxy for expected future claims. More stable than unclaimed balance; directly tied to revenue velocity. High-volume APIs naturally maintain larger bonds.

**Window choice:** The trailing window (N days) should approximate average holder claim inertia. Unknown at this point — options:
- **O1:** Default 30 days, allow governance to adjust
- **O2:** 7d/30d hybrid (0.7 × 7d_sum + 0.3 × 30d_sum) — balances stability + responsiveness
- **O3:** Make it a protocol parameter — let each deployment decide based on expected holder behavior

#### Option 3: Rolling Volume with Rate Snapshots

Same as Option 2, but computed from `ProviderRevenueShare.rateSnapshots()` instead of storing a separate running sum. The `revenuePerShare` snapshots already track cumulative revenue over time — a 30-day lookback on snapshots gives the trailing volume without additional storage.

### Implementation approaches

**Splitter stores running sum:** Add a rolling buffer in `ProviderRevenueSplitter` that accumulates `totalDistributed` per distribution call. Truncate entries older than N days on each `distribute()`.

**On-demand from events:** Off-chain oracles (e.g. Chainlink Automation) scan `Distributed` events and compute the trailing sum off-chain, posting the result on-chain. Avoids storage costs; more trust assumptions.

**From RevenueShare snapshots:** Read `revenuePerShare` snapshots from `ProviderRevenueShare` directly. No splitter changes needed. Con: requires knowing share supply at each snapshot to back out volume.

### Enforcement

Enforced at `requestUnstake()` time — provider cannot unstake below the required floor. Optionally enforced at `openChallenge()` to gate challenge opening when provider is underbonded (prevents challenges against already-vulnerable providers).

**Provider top-up:** Could be automated via Chainlink Automation — an upkeep monitors `isAdequatelyBonded()` and calls `stake()` from a pre-funded provider wallet when the bond dips below threshold.

---

## Automated Bond Top-Up via Chainlink Automation

Rather than requiring manual monitoring and top-up, a provider registers a Chainlink Automation upkeep:

```
checkUpkeep: return !stakeManager.isAdequatelyBonded(provider)
performUpkeep: stakeManager.stake(topUpAmount) from pre-approved wallet
```

Provider pre-approves a USDC allowance for the top-up. Upkeep fires whenever bond coverage drops below threshold. No manual intervention required.

---

## ERC-8004 Agent Identity Integration

Cross-reference endpoint registrations against an ERC-8004 on-chain agent identity:

1. Provider registers their API agent in ERC-8004 with `agentWallet = splitter` and endpoint URL in declared services
2. `registerEndpoint()` accepts optional `agentId` param
3. Registry verifies: `ownerOf(agentId) == msg.sender`, `agentWallet(agentId) == splitter`, endpoint URL declared in identity
4. Endpoint marked as "identity-verified" on-chain

Prevents first-mover squatting at the registration stage rather than relying solely on the challenge/slash flow. ERC-8004 Reputation Registry can also aggregate x402 payment proofs as quality signals for vault share investors.

See `docs/endpoint-ownership-verification.md` for full analysis.

---

## Vault Deposit Gating on Bond Adequacy

`ProviderRevenueVault.deposit()` checks `stakeManager.isAdequatelyBonded(provider)` before accepting new investor capital. If underbonded, deposits revert with a clear message.

Prevents new investors from buying into vaults where the provider's bond no longer covers a meaningful fraction of TVL. Existing investors are unaffected — `redeem()` always works.

Requires a link between `ProviderRevenueVault` and `StakeManager` at deployment time (passed via factory).

---

## Mutual Provider Staking

Providers stake USDC into each other's `ProviderRevenueVaults` instead of a neutral yield protocol. Staked USDC earns API revenue yield; the vault shares held by `StakeManager` are slashable on fraud.

Creates a mutual accountability network: providers have direct financial exposure to each other's behavior. Introduces correlation risk — if an API fails, the providers staked there also take a hit. More suitable once the ecosystem has many independent providers.

---

## Underbonded Grace Period + Freeze Flow

Full underbonded state machine for production:

```
TVL grows beyond bond coverage
  → endpoint enters WARNING state (14-day grace period, informational only)

Grace period expires without top-up
  → endpoint enters UNDERBONDED state
  → new vault deposits blocked
  → Chainlink verification continues (fraud still detectable and slashable)
  → frontend prominently warns existing investors

Provider tops up bond
  → endpoint returns to ACTIVE state

Provider never tops up
  → can still call requestUnstake() + 7-day cooldown → full bond returned
  → must deactivate all endpoints before bond can drop to zero
  → existing investors can always redeem; revenue still flows if API is running
```

---

## Mode C — Escrow Deployer for Institutional Grade

A third-party custodian (multisig or DAO) controls the registered `payTo` configuration. Any change to the endpoint's splitter address requires custodian approval. Clients still pay whatever the 402 response returns — Mode C only governs who can update the on-chain record.

Appropriate for institutional investors requiring a human governance layer on top of the watcher/slash economic model. Could be implemented as a separate registry contract that wraps `APIIntegrityRegistry` and gates `registerEndpoint()` / endpoint update calls behind a multisig.

---

## Challenge Grace Period

Add a cooldown on `openChallenge()` based on `endpoint.lastCheckedAt` so a provider has time to get their endpoint live before it can be challenged.

```
require(block.timestamp - endpoint.lastCheckedAt >= CHALLENGE_GRACE_PERIOD, "grace period active");
```

`lastCheckedAt` is set to `block.timestamp` at registration and reset on every successful Chainlink resolution, so this covers both new registrations and post-check windows. A passing check also creates a cooldown before the next challenge — prevents spam challenges against healthy endpoints.

**Suggested values:** 1 hour on testnet, 24 hours on mainnet.

**Side effect:** also prevents a challenger from immediately re-challenging after a valid resolution, which is desirable — there's no new information yet.

---

## Disable Redemption (Closed-End Fund Model)

Override `redeem()` and `withdraw()` to revert, making vault shares non-redeemable via the primary market. Investors exit exclusively via secondary market (DEX, OTC transfer).

**Rationale:** redemption is neutral at the moment it happens (exchange rate preserved) but beneficial to remaining holders going forward — future revenue flows to a smaller `totalSupply`, so each remaining share claims a larger slice of all future payments. Large redemptions don't harm current holders but do reduce the long-run yield for those who stay. Closing redemption prevents this dynamic entirely and aligns the vault more closely with a closed-end fund: shares trade at market-discovered prices reflecting expected future revenue, not just realized NAV.

**Tradeoff:** removes the liquidity of last resort. Investors must trust that a secondary market exists. Appropriate once the secondary market (AMM, orderbook) is live.

---

## Redemption Fee (Liquidity Tax)

Allow redemption but charge a fee (e.g. 1–5%) that stays inside the vault rather than going to the redeemer. Fee is distributed proportionally to remaining holders via the standard ERC4626 share price mechanism.

**Rationale:** prices the externality correctly. A redeemer receives immediate USDC liquidity; the fee compensates remaining holders for the reduced future revenue share they would otherwise get for free. Makes redemption available without making it free.

**Implementation:** override `_withdraw()` in `ProviderRevenueVault`, deduct `fee = assets * feeBp / 10_000` before transfer, leave the fee in the vault (it automatically accrues to remaining shares via `totalAssets`). `feeBp` set at construction, immutable.

---

## Secondary Market for Vault Shares

Vault shares are already ERC20-transferable. A thin AMM or orderbook for vault shares would let investors exit without waiting for revenue to accumulate — price discovery on expected API growth rather than just realized yield.

Pairs naturally with `APIRevenueFuture` — futures create a price signal for expected growth; spot market for shares reflects realized + expected value.

---

## Vault Revenue Recovery After Zero Supply

If all vault shares are redeemed (totalSupply → 0), any USDC that subsequently arrives via `ProviderRevenueSplitter.distribute()` is permanently stuck — there are no shares to claim it and `deposit()`/`mint()` are disabled.

Mitigation: at genesis, the factory mints a small number of "dead shares" to `address(0)` alongside the provider allocation. `address(0)` is the zero address (`0x000…000`) — no one holds its private key, so those shares can never be redeemed. `totalSupply` can therefore never reach zero regardless of how many holders exit.

```
genesis mint:
  1,000,000,000,000 shares → provider wallet   (redeemable)
              1,000 shares → address(0)         (permanently locked)

totalSupply floor = 1,000 forever
```

At 1 trillion total shares, 1000 locked shares is 0.0000001% dilution — negligible. The factory handles it automatically so providers don't need to remember to do it themselves. No changes needed to the splitter or vault logic.
