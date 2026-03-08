# Endpoint Ownership Verification — Future Considerations

## Context

The current protocol (Layer 0) already enforces that `payTo` in a live 402 response matches the registered splitter address via Chainlink Functions. This makes it economically irrational to register an endpoint you don't control — your bond is slashable the moment a challenge is opened.

The options below are **additional layers** of ownership proof worth considering for future versions. None are required for the core protocol to function — they primarily address UX trust signals (e.g. a "verified owner" badge in the frontend) and edge cases around impersonation or first-mover squatting.

---

## Option 2 — `.well-known` Domain Ownership Proof

**Mechanism:**
Require the registrant to publish a JSON file at a well-known path on their domain:

```
GET https://api.example.com/.well-known/api-integrity.json
```

```json
{
  "vault": "0xabc...",
  "splitter": "0xdef...",
  "chainId": 43113,
  "registrant": "0x123..."
}
```

Chainlink Functions fetches this file as part of registration or challenge verification. If the file exists and the addresses match the registry, the endpoint is marked "domain-verified."

**Pros:**
- Zero new on-chain standards required
- Familiar pattern — identical to ACME/Let's Encrypt, Google Search Console, and ENS domain verification
- Human-readable and auditable
- Easy to display as a "verified" badge in the frontend

**Cons:**
- Off-chain dependency — the file can be removed after registration
- Does not prove the registrant controls the private key behind the `payTo` address, only that they control the web server
- Subject to DNS hijacking (same risk as HTTPS generally)
- Chainlink Functions needs to handle HTTPS + JSON parsing reliably

**Implementation path:**
Extend the Chainlink Functions source to fetch `.well-known/api-integrity.json` alongside the 402 response check. Add a `domainVerified` boolean to the `APIIntegrityRegistry` endpoint struct. Frontend shows a shield/checkmark badge when true.

---

## Option 3 — EIP-712 Signed Registration

**Mechanism:**
The address that appears as `payTo` in the live 402 response must sign an EIP-712 structured message at registration time:

```
struct EndpointRegistration {
  string  endpointUrl;
  address splitter;
  address vault;
  uint256 chainId;
  uint256 nonce;
  uint256 expiry;
}
```

The `registerEndpoint()` call includes this signature. The registry verifies it on-chain: `ecrecover(hash, sig) == payToAddress`.

**Pros:**
- Fully on-chain verification — no Chainlink or off-chain dependency for this specific check
- Proves the entity receiving x402 payments explicitly authorized the on-chain registration
- Signature includes chainId and nonce — replay-safe across chains and registrations
- Natural fit with EIP-712 wallets (MetaMask, hardware wallets, smart contract wallets via EIP-1271)

**Cons:**
- Adds friction to registration UX — provider must sign before submitting the tx
- The `payTo` private key must be available at registration time (may be a hot wallet concern for large providers)
- Doesn't prove ongoing control — key could be rotated after signing
- Smart contract wallets need EIP-1271 support added to the registry

**Implementation path:**
Add `bytes signature` parameter to `registerEndpoint()`. Add `_verifyOwnershipSignature(endpointUrl, splitter, vault, payTo, signature)` internal function using OpenZeppelin `SignatureChecker` (handles both EOA and EIP-1271). Emit `EndpointOwnershipVerified(endpointId, payTo)`.

---

## Option 4 — On-Chain DNS TXT Record Verification

**Mechanism:**
The registrant publishes a DNS TXT record at a subdomain of their API's domain:

```
_api-integrity.example.com  TXT  "vault=0xabc...;splitter=0xdef...;chain=43113"
```

Chainlink Functions resolves this DNS record as part of registration or challenge. If the TXT record matches the registered vault and splitter, the endpoint is marked "DNS-verified."

**Pros:**
- DNS control = domain ownership — stronger than a web file (requires registrar access, not just server access)
- Familiar to operators — same pattern used by email (SPF/DKIM), Google Workspace, and GitHub Pages
- Persistent — DNS records are harder to quietly remove than a web file
- No smart contract changes required — purely a Chainlink Functions source extension

**Cons:**
- DNS is still off-chain and centralized (ICANN, registrars)
- DNS propagation delays (TTL) create a lag between publishing and verification
- Chainlink Functions DNS resolution support may vary by DON configuration
- Does not prove control of the `payTo` private key, only control of the domain

**Implementation path:**
Extend the Chainlink Functions source to issue a DNS TXT query for `_api-integrity.<domain>` and parse the response. Parse `vault` and `splitter` from TXT value and assert they match the registered addresses. Store result in a `dnsVerified` boolean on the endpoint struct alongside `domainVerified`.

---

## Option 5 — ERC-8004 Agent Identity Registry

**What ERC-8004 is:**
A trustless on-chain agent identity standard with three composable registries:
- **Identity Registry** (ERC-721) — each agent is an NFT with a URI pointing to a registration file, plus a designated `agentWallet` payment address
- **Reputation Registry** — standardized on-chain feedback signals from clients
- **Validation Registry** — validator-submitted verification results (stake, ZK proofs, TEE attestation)

**Why it fits:**

The `agentWallet` field on an ERC-8004 identity is defined as the "reserved, immutable address for payment receipt" — requiring EIP-712 signed proof to update. This is the canonical `payTo` equivalent for autonomous agents. The identity's registration file also includes a service endpoints array listing the agent's API URLs.

x402 payment proofs are explicitly referenced in the ERC-8004 spec as enrichment signals in off-chain feedback files — the two standards are designed to compose.

**The integration:**

1. API provider registers their agent in ERC-8004 Identity Registry:
   - `agentWallet = splitter address`
   - Service endpoints array includes the API URL
   - Domain verification via `.well-known/agent-registration.json` (native to ERC-8004)

2. When calling `registerEndpoint()` on `APIIntegrityRegistry`, provider passes their ERC-8004 `agentId`

3. Registry performs three cross-reference checks:
   ```
   identityRegistry.ownerOf(agentId) == msg.sender          // NFT ownership proves control
   identityRegistry.agentWallet(agentId) == splitter         // payment address matches
   registrationFile.endpoints.includes(endpointUrl)          // URL is declared by identity
   ```

4. No challenge needed for this check — it's a pure on-chain read at registration time

**Additional composability:**
- ERC-8004 Reputation Registry can aggregate x402 payment proofs as quality signals for each API agent
- ERC-8004 Validation Registry can serve as an alternative or complement to Chainlink Functions for endpoint integrity verification
- Agent NFT is transferable — when transferred, `agentWallet` clears and requires re-verification by new owner, keeping splitter ownership honest
- Protocol frontend can display ERC-8004 reputation scores alongside vault share price for richer investor signal

**Pros:**
- Strongest ownership proof — NFT ownership + EIP-712 `agentWallet` + declared endpoint URL, all on-chain
- No off-chain Chainlink dependency for the ownership check specifically
- `.well-known` domain verification is native to ERC-8004 (Option 2 included for free)
- Ecosystem alignment — any tooling built around ERC-8004 (explorers, agent marketplaces) benefits this protocol automatically
- x402 payment proofs are already part of the ERC-8004 data model

**Cons:**
- Requires providers to maintain an ERC-8004 identity (additional registration step)
- ERC-8004 is new — ecosystem tooling is nascent
- Registry contract addresses needed at `APIIntegrityRegistry` deployment time

**Implementation path:**
Add optional `agentId` parameter to `registerEndpoint()`. If provided, call into the ERC-8004 Identity Registry to assert `ownerOf(agentId) == msg.sender` and `agentWallet(agentId) == splitter`. Store `agentId` on the endpoint struct. Emit `EndpointLinkedToAgent(endpointId, agentId)`. Frontend shows ERC-8004 identity metadata and reputation score alongside vault data.

---

## Recommendation Priority

| Option | Trust Signal | On-chain | Complexity | Recommended For |
|---|---|---|---|---|
| `.well-known` (2) | Domain control | No | Low | Short-term — easy badge, no contract changes |
| EIP-712 sig (3) | Key control | Yes | Medium | Medium-term — strongest cryptographic proof |
| DNS TXT (4) | Domain control | No | Low | Alternative to `.well-known` for DNS-first operators |
| ERC-8004 (5) | NFT ownership + agentWallet + endpoint URL | Yes | Low (if adopted) | Long-term — strongest proof, ecosystem alignment |

Options 2 and 4 are complementary (web vs. DNS) and can be implemented together. Option 3 is the strongest standalone proof and requires no off-chain dependencies after registration.
