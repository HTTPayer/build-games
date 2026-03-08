# Frontend Integration Guide — Provider Registration

Step-by-step guide for building a wagmi/React page that lets an API provider
register themselves on the HTTPayer protocol (Avalanche Fuji testnet).

| | Section |
|---|---|
| **Required** | Setup · Stake USDC · Deploy provider · Integrity hash · Register endpoint · ChallengeManager · Enumerate endpoints |
| **Optional** | Snowscan verification · Vault interactions · Splitter interactions |

---

# Required

---

## Deployed contracts (Avalanche Fuji — chain ID 43113)

| Contract | Address |
|---|---|
| `APIRegistryFactory` | `0xbDC41cf3E17D5FA19e41A3Fb02C8AcB9B9927e5B` |
| `APIIntegrityRegistry` | `0xaF2596CCF591831d8af6b463dc5760C156C5936A` |
| `StakeManager` | `0x3401eE39d686d6B93A97Bd04A244f3bBa1e7dD69` |
| `ChallengeManager` | `0x60825231973f0e9d441A85021dACA8AaE473A44b` |
| `USDC (mock)` | call `APIRegistryFactory.USDC()` to get address |

Deploy block: `52477983` (use as `fromBlock` when querying events)

---

## 1. Setup

```bash
npm install wagmi viem @tanstack/react-query @rainbow-me/rainbowkit @noble/hashes
```

### wagmi config

```ts
// lib/wagmi.ts
import { createConfig, http } from 'wagmi'
import { avalancheFuji } from 'wagmi/chains'
import { injected, metaMask } from 'wagmi/connectors'

export const config = createConfig({
  chains: [avalancheFuji],
  connectors: [injected(), metaMask()],
  transports: {
    [avalancheFuji.id]: http('https://api.avax-fuji.network/ext/bc/C/rpc'),
  },
})
```

### App wrapper

```tsx
// app/layout.tsx  (Next.js 14 app dir)
import { WagmiProvider } from 'wagmi'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { RainbowKitProvider } from '@rainbow-me/rainbowkit'
import { config } from '@/lib/wagmi'

const queryClient = new QueryClient()

export default function RootLayout({ children }) {
  return (
    <WagmiProvider config={config}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider>{children}</RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  )
}
```

---

## 2. Registration flow overview

```
1. Stake USDC          →  StakeManager.stake(amount)
2. Deploy provider     →  APIRegistryFactory.deployProvider(...)
3. Update x402 server  →  set payTo = splitter address from step 2
4. Verify live hash    →  fetch endpoint → compute SHA-256 (see section 5)
5. Register endpoint   →  APIIntegrityRegistry.registerEndpoint(...)
```

Steps 1 and 2 require USDC approvals first. Step 4 may require a backend
proxy depending on your x402 server's CORS configuration (see section 5).

---

## 3. Step 1 — Stake USDC

```tsx
import { useAccount, useReadContract, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { useEffect } from 'react'

const STAKE_MANAGER = '0x3401eE39d686d6B93A97Bd04A244f3bBa1e7dD69' as const
const REGISTRY      = '0xaF2596CCF591831d8af6b463dc5760C156C5936A' as const

export function StakePanel({ usdcAddress }: { usdcAddress: `0x${string}` }) {
  const { address } = useAccount()

  // ── Reads ──────────────────────────────────────────────────────────────
  const { data: minimumStake = 0n } = useReadContract({
    address: REGISTRY,
    abi: registryAbi,
    functionName: 'minimumStakeRequired',
  })

  const { data: stakeInfo } = useReadContract({
    address: STAKE_MANAGER,
    abi: stakeManagerAbi,
    functionName: 'stakes',
    args: [address!],
    query: { enabled: !!address },
  })
  const [staked = 0n, unlocksAt = 0n] = stakeInfo ?? []

  const { data: usdcBalance = 0n } = useReadContract({
    address: usdcAddress,
    abi: erc20Abi,
    functionName: 'balanceOf',
    args: [address!],
    query: { enabled: !!address },
  })

  const shortfall = minimumStake > staked ? minimumStake - staked : 0n

  // ── Approve ────────────────────────────────────────────────────────────
  const { writeContract: approve, data: approveTxHash } = useWriteContract()
  const { isSuccess: approveConfirmed } = useWaitForTransactionReceipt({ hash: approveTxHash })

  // ── Stake ──────────────────────────────────────────────────────────────
  const { writeContract: stake, data: stakeTxHash, isPending: staking } = useWriteContract()
  const { isSuccess: stakeConfirmed } = useWaitForTransactionReceipt({ hash: stakeTxHash })

  useEffect(() => {
    if (approveConfirmed && shortfall > 0n) {
      stake({
        address: STAKE_MANAGER,
        abi: stakeManagerAbi,
        functionName: 'stake',
        args: [shortfall],
      })
    }
  }, [approveConfirmed])

  function handleStake() {
    if (shortfall === 0n) return
    approve({
      address: usdcAddress,
      abi: erc20Abi,
      functionName: 'approve',
      args: [STAKE_MANAGER, shortfall],
    })
  }

  return (
    <div>
      <p>Minimum stake: {formatUsdc(minimumStake)} USDC</p>
      <p>Your stake:    {formatUsdc(staked)} USDC</p>
      <p>USDC balance:  {formatUsdc(usdcBalance)} USDC</p>
      {shortfall > 0n && (
        <button onClick={handleStake} disabled={staking}>
          Stake {formatUsdc(shortfall)} USDC
        </button>
      )}
      {stakeConfirmed && <p>Staked successfully</p>}
    </div>
  )
}
```

### Unstake / withdraw (after cooldown)

```tsx
const { data: cooldown = 0n } = useReadContract({
  address: STAKE_MANAGER,
  abi: stakeManagerAbi,
  functionName: 'withdrawCooldown',
})

// Request unstake (starts cooldown timer)
const { writeContract: requestUnstake } = useWriteContract()
function handleRequestUnstake(amount: bigint) {
  requestUnstake({
    address: STAKE_MANAGER,
    abi: stakeManagerAbi,
    functionName: 'requestUnstake',
    args: [amount],
  })
}

// Withdraw (only callable after unlocksAt timestamp has passed)
const { writeContract: withdraw } = useWriteContract()
const canWithdraw = unlocksAt > 0n && BigInt(Math.floor(Date.now() / 1000)) >= unlocksAt

function handleWithdraw(amount: bigint) {
  withdraw({
    address: STAKE_MANAGER,
    abi: stakeManagerAbi,
    functionName: 'withdraw',
    args: [amount],
  })
}
```

---

## 4. Step 2 — Deploy provider

`deployProvider` deploys your vault, splitter, and registers your provider ID
in a single transaction. Parse the addresses from the emitted events.

```tsx
import { decodeEventLog, parseAbiItem } from 'viem'

const FACTORY = '0xbDC41cf3E17D5FA19e41A3Fb02C8AcB9B9927e5B' as const
const ZERO    = '0x0000000000000000000000000000000000000000' as const

export function DeployProviderPanel({ usdcAddress }: { usdcAddress: `0x${string}` }) {
  const { writeContract: deployProvider, data: deployTxHash } = useWriteContract()
  const { data: receipt } = useWaitForTransactionReceipt({ hash: deployTxHash })

  // Extract splitter + providerId from receipt logs
  const deployed = receipt
    ? (() => {
        for (const log of receipt.logs) {
          try {
            const event = decodeEventLog({ abi: factoryAbi, ...log })
            if (event.eventName === 'ProviderDeployed') return event.args
          } catch {}
        }
        return null
      })()
    : null

  // splitter = deployed?.splitter  (set this as your x402 server's payTo)
  // providerId = deployed?.providerId

  function handleDeploy({
    name,
    symbol,
    vaultBp = 9800n,
    genesisDeposit = 0n,
  }: {
    name: string
    symbol: string
    vaultBp?: bigint
    genesisDeposit?: bigint
  }) {
    const deploy = () =>
      deployProvider({
        address: FACTORY,
        abi: factoryAbi,
        functionName: 'deployProvider',
        args: [
          name,           // vault token name
          symbol,         // vault token symbol
          vaultBp,        // basis points to vault  (max: 10000 - protocolBp)
          0n,             // genesisShares
          ZERO,           // genesisRecipient
          genesisDeposit, // USDC to seed vault (raw units, 0 = skip)
          ZERO,           // providerTreasury  (optional direct cut)
          0n,             // revenueShareBp
          0n,             // rsShares
          ZERO,           // rsRecipient
          '',             // metadataURI
        ],
      })

    if (genesisDeposit > 0n) {
      // approve factory to pull genesis deposit, then deploy
      approve({
        address: usdcAddress,
        abi: erc20Abi,
        functionName: 'approve',
        args: [FACTORY, genesisDeposit],
      })
      // call deploy() in the approveConfirmed useEffect (same pattern as stake)
    } else {
      deploy()
    }
  }

  return (
    <div>
      {deployed && (
        <>
          <p>Provider ID: {deployed.providerId.toString()}</p>
          <p>Splitter:    {deployed.splitter}</p>
          <p>Vault:       {deployed.vault}</p>
          <p>Set your x402 server payTo = {deployed.splitter}</p>
        </>
      )}
    </div>
  )
}

// Update provider (name/splitter/payout — owner only)
const { writeContract: updateProvider } = useWriteContract()
function handleUpdateProvider(
  providerId: bigint,
  metadataURI: string,
  payoutAddress: `0x${string}`,
  revenueSplitter: `0x${string}`,
) {
  updateProvider({
    address: REGISTRY,
    abi: registryAbi,
    functionName: 'updateProvider',
    args: [providerId, metadataURI, payoutAddress, revenueSplitter],
  })
}
```

---

## 5. Integrity hash — algorithm & verification

### What the hash is

The integrity hash is a **SHA-256 fingerprint of your endpoint's x402 payment
terms** stored on-chain when you call `registerEndpoint`. The Chainlink CRE DON
recomputes it live against your running server every time a challenge is opened.
If the hashes don't match, your stake is slashed.

### Algorithm (exact)

```
Input fields (from the 402 response):
  amount   — payment amount as a string  (e.g. "10000")
  asset    — USDC contract address       (checksummed or not)
  network  — chain identifier string     (e.g. "eip155:43113")
  payTo    — your splitter address       LOWERCASED
  url      — full endpoint URL           (from paymentData.resource.url)

Step 1 — Normalise payTo to lowercase
Step 2 — Build an object with exactly these 5 keys
Step 3 — Sort keys alphabetically:  amount, asset, network, payTo, url
Step 4 — JSON.stringify with NO spaces and NO extra keys
Step 5 — SHA-256 of the UTF-8 bytes of that string
Step 6 — Hex-encode → prefix with "0x"

Result: 0x<64 hex chars>  (bytes32)
```

Example input JSON string (step 4 output):
```
{"amount":"10000","asset":"0xf3de3C0d654FDa6E8F4AB04DB5b0e6Ed30CE7a04","network":"eip155:43113","payTo":"0xabc...def","url":"https://api.example.com/data"}
```

### TypeScript implementation

```ts
// lib/integrityHash.ts
import { sha256 } from '@noble/hashes/sha256'

export type X402PaymentData = {
  accepts: Array<{
    amount:  string | number
    asset:   string
    network: string
    payTo:   string
  }>
  resource?: { url?: string }
  // x402 v1 may use top-level url field
  url?: string
}

export function computeIntegrityHash(paymentData: X402PaymentData): `0x${string}` {
  const entry = paymentData.accepts[0]

  // Canonical fields — exactly these 5, payTo lowercased
  const metadata: Record<string, string> = {
    amount:  String(entry.amount),
    asset:   String(entry.asset),
    network: String(entry.network),
    payTo:   String(entry.payTo).toLowerCase(),
    url:     String(paymentData.resource?.url ?? paymentData.url ?? ''),
  }

  // Sort keys alphabetically, stringify with no spaces
  const sorted     = Object.fromEntries(Object.keys(metadata).sort().map(k => [k, metadata[k]]))
  const dataString = JSON.stringify(sorted)   // compact — no spaces

  const hashBytes = sha256(new TextEncoder().encode(dataString))
  return ('0x' + Array.from(hashBytes).map(b => b.toString(16).padStart(2, '0')).join('')) as `0x${string}`
}
```

### Fetching x402 metadata from your server

Your x402 server returns payment terms in the 402 response. Two formats:

| Version | Location | Encoding |
|---|---|---|
| x402 v2 | `PAYMENT-REQUIRED` response header | base64-encoded JSON |
| x402 v1 | Response body (JSON) | plain JSON |

```ts
export async function fetchPaymentData(endpointUrl: string): Promise<X402PaymentData> {
  const resp = await fetch(endpointUrl, { headers: { Accept: 'application/json' } })
  // 402 expected — don't throw on non-200

  const paymentHeader = resp.headers.get('payment-required')
  if (paymentHeader) {
    // x402 v2 — header is base64 JSON
    return JSON.parse(atob(paymentHeader)) as X402PaymentData
  }
  // x402 v1 — body is JSON
  return resp.json() as Promise<X402PaymentData>
}

export async function fetchIntegrityHashDirect(endpointUrl: string): Promise<`0x${string}`> {
  const paymentData = await fetchPaymentData(endpointUrl)
  return computeIntegrityHash(paymentData)
}
```

### Verify live hash vs on-chain before registering

Always confirm the live hash before calling `registerEndpoint`. A mismatch on
registration means your endpoint will be immediately challengeable.

```ts
import { readContract } from '@wagmi/core'

export async function preflightCheck(
  endpointUrl:  string,
  endpointId:   `0x${string}`,   // only needed if re-registering an existing endpoint
  config:       ReturnType<typeof import('wagmi').createConfig>,
): Promise<{ hash: `0x${string}`; onChainHash?: `0x${string}`; match?: boolean }> {
  const liveHash = await fetchIntegrityHash(endpointUrl)  // uses proxy fallback from section 5

  // If checking against an already-registered endpoint:
  let onChainHash: `0x${string}` | undefined
  let match: boolean | undefined
  if (endpointId) {
    const endpoint = await readContract(config, {
      address: REGISTRY,
      abi:     registryAbi,
      functionName: 'endpoints',
      args:    [endpointId],
    })
    onChainHash = endpoint.integrityHash as `0x${string}`
    match       = liveHash.toLowerCase() === onChainHash.toLowerCase()
  }

  return { hash: liveHash, onChainHash, match }
}
```

### Hash debugging checklist

If your hash doesn't match the on-chain value:

1. **payTo case** — must be fully lowercase. `entry.payTo.toLowerCase()`.
2. **Key order** — must be `amount, asset, network, payTo, url` (alphabetical).
3. **No extra keys** — never include `maxTimeoutSeconds`, `extra`, or other fields.
4. **Exact string values** — `amount` is a decimal string, not a number. `String(entry.amount)`.
5. **url source** — use `paymentData.resource.url`, not the URL you fetched from. They may differ (path vs full URL, trailing slash, etc.).
6. **JSON format** — `JSON.stringify` with no replacer and no space argument. Never `JSON.stringify(obj, null, 2)`.

### Matching the Python implementation (for cross-checking)

The CLI watchers and `x402_metadata.py` produce the same hash:

```python
import json, hashlib

def compute_integrity_hash(entry: dict, resource_url: str) -> str:
    metadata = {
        "amount":  str(entry["amount"]),
        "asset":   str(entry["asset"]),
        "network": str(entry["network"]),
        "payTo":   str(entry["payTo"]).lower(),
        "url":     resource_url,
    }
    data = json.dumps(metadata, sort_keys=True, separators=(',', ':'))
    digest = hashlib.sha256(data.encode()).hexdigest()
    return "0x" + digest
```

Both `json.dumps(sort_keys=True, separators=(',',':'))` and the TypeScript
`JSON.stringify(sorted)` with pre-sorted keys produce identical compact JSON.

---

## 5a. CORS & backend proxy

If your x402 server sets these CORS headers on 402 responses, the browser can
fetch directly:

```
Access-Control-Allow-Origin: *
Access-Control-Expose-Headers: payment-required
```

Otherwise add a thin backend proxy — the browser will hit CORS errors on 402 responses.

### When you need a backend proxy

Most x402 servers don't expose CORS on 402 responses by default. If the browser
gets a CORS error when fetching your endpoint, add a thin proxy route.

#### Option A — Next.js API route (recommended)

```ts
// app/api/verify-hash/route.ts
import { NextRequest, NextResponse } from 'next/server'
import { fetchPaymentData, computeIntegrityHash } from '@/lib/integrityHash'

export async function GET(req: NextRequest) {
  const url = req.nextUrl.searchParams.get('url')
  if (!url) return NextResponse.json({ error: 'missing url' }, { status: 400 })

  try {
    const paymentData = await fetchPaymentData(url)
    const hash        = computeIntegrityHash(paymentData)
    return NextResponse.json({ hash })
  } catch (err: any) {
    return NextResponse.json({ error: err.message }, { status: 500 })
  }
}
```

Add the proxy-aware fetcher to `lib/integrityHash.ts`:

```ts
// Add to lib/integrityHash.ts (alongside computeIntegrityHash and fetchPaymentData from section 5)
export async function fetchIntegrityHash(endpointUrl: string): Promise<`0x${string}`> {
  try {
    // Try direct browser fetch first (works if CORS allows it)
    return await fetchIntegrityHashDirect(endpointUrl)
  } catch {
    // Fall back to backend proxy
    const res = await fetch(`/api/verify-hash?url=${encodeURIComponent(endpointUrl)}`)
    if (!res.ok) throw new Error(await res.text())
    const { hash } = await res.json()
    return hash as `0x${string}`
  }
}
```

#### Option B — Express endpoint (standalone server)

```ts
// Add to servers/src/server.ts
import { fetchPaymentData, computeIntegrityHash } from './integrityHash'

app.get('/api/verify-hash', async (req, res) => {
  const { url } = req.query as { url: string }
  if (!url) return res.status(400).json({ error: 'missing url' })

  const paymentData = await fetchPaymentData(url)
  const hash        = computeIntegrityHash(paymentData)
  res.json({ hash })
})
```

---

## 6. Step 4 — Register endpoint

```tsx
const { writeContract: registerEndpoint, data: regTxHash, isPending } = useWriteContract()
const { isSuccess: registered, data: regReceipt } = useWaitForTransactionReceipt({ hash: regTxHash })

async function handleRegisterEndpoint(
  providerId: bigint,
  url: string,
  method: string = 'GET',
) {
  const integrityHash = await fetchIntegrityHash(url)

  registerEndpoint({
    address: REGISTRY,
    abi: registryAbi,
    functionName: 'registerEndpoint',
    args: [providerId, url, method, integrityHash],
  })
}

// Parse endpointId from receipt
const endpointId = regReceipt
  ? (() => {
      for (const log of regReceipt.logs) {
        try {
          const event = decodeEventLog({ abi: registryAbi, ...log })
          if (event.eventName === 'EndpointRegistered') return event.args.endpointId
        } catch {}
      }
      return null
    })()
  : null
```

---

## 7. ChallengeManager — open & read challenges

```tsx
const CHALLENGE_MANAGER = '0x60825231973f0e9d441A85021dACA8AaE473A44b' as const

// Read protocol params
const { data: challengeFee = 0n } = useReadContract({
  address: CHALLENGE_MANAGER,
  abi: challengeManagerAbi,
  functionName: 'challengeFee',
})

const { data: slashBp = 0n } = useReadContract({
  address: CHALLENGE_MANAGER,
  abi: challengeManagerAbi,
  functionName: 'slashBp',
})

// Read a challenge by ID
const { data: challenge } = useReadContract({
  address: CHALLENGE_MANAGER,
  abi: challengeManagerAbi,
  functionName: 'challenges',
  args: [challengeId],
  query: { enabled: challengeId !== undefined },
})
// challenge = [challenger, endpointId, status]  status: 0=Pending 1=Valid 2=Invalid
const STATUS = ['Pending', 'Valid', 'Invalid'] as const

// Open a challenge (approve fee first)
const { writeContract: approveFee, data: approveTxHash } = useWriteContract()
const { isSuccess: feeApproved } = useWaitForTransactionReceipt({ hash: approveTxHash })

const { writeContract: openChallenge, data: challengeTxHash } = useWriteContract()
const { data: challengeReceipt } = useWaitForTransactionReceipt({ hash: challengeTxHash })

const openedChallengeId = challengeReceipt
  ? (() => {
      for (const log of challengeReceipt.logs) {
        try {
          const event = decodeEventLog({ abi: challengeManagerAbi, ...log })
          if (event.eventName === 'ChallengeOpened') return event.args.id
        } catch {}
      }
      return null
    })()
  : null

function handleOpenChallenge(endpointId: `0x${string}`, usdcAddress: `0x${string}`) {
  approveFee({
    address: usdcAddress,
    abi: erc20Abi,
    functionName: 'approve',
    args: [CHALLENGE_MANAGER, challengeFee],
  })
}

useEffect(() => {
  if (feeApproved && endpointIdToChallenge) {
    openChallenge({
      address: CHALLENGE_MANAGER,
      abi: challengeManagerAbi,
      functionName: 'openChallenge',
      args: [endpointIdToChallenge],
    })
  }
}, [feeApproved])
```

---

## 8. Enumerate all endpoints (event-based)

Reading `endpoints()` requires a `bytes32` ID. To list all endpoints, read
`EndpointRegistered` events using viem's `getLogs`:

```ts
import { createPublicClient, http, parseAbiItem } from 'viem'
import { avalancheFuji } from 'wagmi/chains'

const client = createPublicClient({
  chain: avalancheFuji,
  transport: http(),
})

const DEPLOY_BLOCK = 52477983n

async function getAllEndpoints() {
  const logs = await client.getLogs({
    address: '0xaF2596CCF591831d8af6b463dc5760C156C5936A',
    event: parseAbiItem(
      'event EndpointRegistered(bytes32 indexed endpointId, address indexed provider, uint256 indexed providerId)'
    ),
    fromBlock: DEPLOY_BLOCK,
    toBlock:   'latest',
  })

  return Promise.all(
    logs.map(async log => {
      const endpoint = await client.readContract({
        address: '0xaF2596CCF591831d8af6b463dc5760C156C5936A',
        abi: registryAbi,
        functionName: 'endpoints',
        args: [log.args.endpointId!],
      })
      return { endpointId: log.args.endpointId, ...endpoint }
    })
  )
}
```

---

## 9. Complete ABI reference

```ts
// lib/abis.ts

export const erc20Abi = [
  { name: 'approve',   type: 'function', stateMutability: 'nonpayable',
    inputs: [{ name: 'spender', type: 'address' }, { name: 'amount', type: 'uint256' }],
    outputs: [{ type: 'bool' }] },
  { name: 'balanceOf', type: 'function', stateMutability: 'view',
    inputs: [{ name: 'account', type: 'address' }], outputs: [{ type: 'uint256' }] },
  { name: 'allowance', type: 'function', stateMutability: 'view',
    inputs: [{ name: 'owner', type: 'address' }, { name: 'spender', type: 'address' }],
    outputs: [{ type: 'uint256' }] },
] as const

export const stakeManagerAbi = [
  { name: 'stake',            type: 'function', stateMutability: 'nonpayable',
    inputs: [{ name: 'amount', type: 'uint256' }], outputs: [] },
  { name: 'requestUnstake',   type: 'function', stateMutability: 'nonpayable',
    inputs: [{ name: 'amount', type: 'uint256' }], outputs: [] },
  { name: 'withdraw',         type: 'function', stateMutability: 'nonpayable',
    inputs: [{ name: 'amount', type: 'uint256' }], outputs: [] },
  { name: 'stakes',           type: 'function', stateMutability: 'view',
    inputs: [{ name: '', type: 'address' }],
    outputs: [{ name: 'amount', type: 'uint256' }, { name: 'unlocksAt', type: 'uint256' }] },
  { name: 'withdrawCooldown', type: 'function', stateMutability: 'view',
    inputs: [], outputs: [{ type: 'uint256' }] },
  { name: 'treasury',         type: 'function', stateMutability: 'view',
    inputs: [], outputs: [{ type: 'address' }] },
  { name: 'protocolSlashBp',  type: 'function', stateMutability: 'view',
    inputs: [], outputs: [{ type: 'uint256' }] },
] as const

export const registryAbi = [
  { name: 'minimumStakeRequired', type: 'function', stateMutability: 'view',
    inputs: [], outputs: [{ type: 'uint256' }] },
  { name: 'providerCount',        type: 'function', stateMutability: 'view',
    inputs: [], outputs: [{ type: 'uint256' }] },
  { name: 'stakeManager',         type: 'function', stateMutability: 'view',
    inputs: [], outputs: [{ type: 'address' }] },
  { name: 'providers', type: 'function', stateMutability: 'view',
    inputs: [{ name: 'id', type: 'uint256' }],
    outputs: [
      { name: 'owner',           type: 'address' },
      { name: 'metadataURI',     type: 'string'  },
      { name: 'payoutAddress',   type: 'address' },
      { name: 'revenueSplitter', type: 'address' },
      { name: 'active',          type: 'bool'    },
      { name: 'createdAt',       type: 'uint256' },
    ] },
  { name: 'endpoints', type: 'function', stateMutability: 'view',
    inputs: [{ name: 'endpointId', type: 'bytes32' }],
    outputs: [
      { name: 'endpointId',    type: 'bytes32' },
      { name: 'provider',      type: 'address' },
      { name: 'path',          type: 'string'  },
      { name: 'method',        type: 'string'  },
      { name: 'integrityHash', type: 'bytes32' },
      { name: 'version',       type: 'uint256' },
      { name: 'active',        type: 'bool'    },
      { name: 'checkedAt',     type: 'uint256' },
      { name: 'createdAt',     type: 'uint256' },
    ] },
  { name: 'registerEndpoint', type: 'function', stateMutability: 'nonpayable',
    inputs: [
      { name: 'providerId',    type: 'uint256' },
      { name: 'path',          type: 'string'  },
      { name: 'method',        type: 'string'  },
      { name: 'integrityHash', type: 'bytes32' },
    ], outputs: [] },
  { name: 'updateProvider', type: 'function', stateMutability: 'nonpayable',
    inputs: [
      { name: 'id',              type: 'uint256' },
      { name: 'metadataURI',     type: 'string'  },
      { name: 'payoutAddress',   type: 'address' },
      { name: 'revenueSplitter', type: 'address' },
    ], outputs: [] },
  { name: 'EndpointRegistered', type: 'event',
    inputs: [
      { name: 'endpointId', type: 'bytes32', indexed: true  },
      { name: 'provider',   type: 'address', indexed: true  },
      { name: 'providerId', type: 'uint256', indexed: true  },
    ] },
  { name: 'ProviderRegistered', type: 'event',
    inputs: [
      { name: 'id',    type: 'uint256', indexed: true },
      { name: 'owner', type: 'address', indexed: true },
    ] },
] as const

export const factoryAbi = [
  { name: 'USDC',               type: 'function', stateMutability: 'view',
    inputs: [], outputs: [{ type: 'address' }] },
  { name: 'registry',           type: 'function', stateMutability: 'view',
    inputs: [], outputs: [{ type: 'address' }] },
  { name: 'protocolTreasuryBp', type: 'function', stateMutability: 'view',
    inputs: [], outputs: [{ type: 'uint256' }] },
  { name: 'providerCount',      type: 'function', stateMutability: 'view',
    inputs: [], outputs: [{ type: 'uint256' }] },
  { name: 'deployProvider', type: 'function', stateMutability: 'nonpayable',
    inputs: [
      { name: 'name',             type: 'string'  },
      { name: 'symbol',           type: 'string'  },
      { name: 'vaultBp',          type: 'uint256' },
      { name: 'genesisShares',    type: 'uint256' },
      { name: 'genesisRecipient', type: 'address' },
      { name: 'genesisDeposit',   type: 'uint256' },
      { name: 'providerTreasury', type: 'address' },
      { name: 'revenueShareBp',   type: 'uint256' },
      { name: 'rsShares',         type: 'uint256' },
      { name: 'rsRecipient',      type: 'address' },
      { name: 'metadataURI',      type: 'string'  },
    ], outputs: [] },
  { name: 'ProviderDeployed', type: 'event',
    inputs: [
      { name: 'providerId',   type: 'uint256', indexed: true  },
      { name: 'owner',        type: 'address', indexed: true  },
      { name: 'vault',        type: 'address', indexed: false },
      { name: 'splitter',     type: 'address', indexed: false },
      { name: 'revenueShare', type: 'address', indexed: false },
    ] },
] as const

export const challengeManagerAbi = [
  { name: 'challengeFee',   type: 'function', stateMutability: 'view',
    inputs: [], outputs: [{ type: 'uint256' }] },
  { name: 'slashBp',        type: 'function', stateMutability: 'view',
    inputs: [], outputs: [{ type: 'uint256' }] },
  { name: 'challengeCount', type: 'function', stateMutability: 'view',
    inputs: [], outputs: [{ type: 'uint256' }] },
  { name: 'forwarder',      type: 'function', stateMutability: 'view',
    inputs: [], outputs: [{ type: 'address' }] },
  { name: 'challenges', type: 'function', stateMutability: 'view',
    inputs: [{ name: 'id', type: 'uint256' }],
    outputs: [
      { name: 'challenger',  type: 'address' },
      { name: 'endpointId',  type: 'bytes32' },
      { name: 'status',      type: 'uint8'   },
    ] },
  { name: 'openChallenge', type: 'function', stateMutability: 'nonpayable',
    inputs: [{ name: 'endpointId', type: 'bytes32' }], outputs: [] },
  { name: 'ChallengeOpened', type: 'event',
    inputs: [
      { name: 'id',             type: 'uint256', indexed: true  },
      { name: 'endpointId',     type: 'bytes32', indexed: true  },
      { name: 'path',           type: 'string',  indexed: false },
      { name: 'method',         type: 'string',  indexed: false },
      { name: 'integrityHash',  type: 'bytes32', indexed: false },
    ] },
  { name: 'ChallengeResolved', type: 'event',
    inputs: [
      { name: 'id',     type: 'uint256', indexed: true },
      { name: 'status', type: 'uint8',   indexed: false },
    ] },
] as const

export const vaultAbi = [
  { name: 'totalSupply',      type: 'function', stateMutability: 'view',
    inputs: [], outputs: [{ type: 'uint256' }] },
  { name: 'totalAssets',      type: 'function', stateMutability: 'view',
    inputs: [], outputs: [{ type: 'uint256' }] },
  { name: 'depositsEnabled',  type: 'function', stateMutability: 'view',
    inputs: [], outputs: [{ type: 'bool' }] },
  { name: 'genesisComplete',  type: 'function', stateMutability: 'view',
    inputs: [], outputs: [{ type: 'bool' }] },
  { name: 'balanceOf',        type: 'function', stateMutability: 'view',
    inputs: [{ name: 'account', type: 'address' }], outputs: [{ type: 'uint256' }] },
  { name: 'convertToAssets',  type: 'function', stateMutability: 'view',
    inputs: [{ name: 'shares', type: 'uint256' }], outputs: [{ type: 'uint256' }] },
  { name: 'openDeposits', type: 'function', stateMutability: 'nonpayable',
    inputs: [], outputs: [] },
  { name: 'deposit', type: 'function', stateMutability: 'nonpayable',
    inputs: [{ name: 'assets', type: 'uint256' }, { name: 'receiver', type: 'address' }],
    outputs: [{ type: 'uint256' }] },
  { name: 'redeem', type: 'function', stateMutability: 'nonpayable',
    inputs: [
      { name: 'shares',   type: 'uint256' },
      { name: 'receiver', type: 'address' },
      { name: 'owner',    type: 'address' },
    ], outputs: [{ type: 'uint256' }] },
] as const

export const splitterAbi = [
  { name: 'pendingDistribution', type: 'function', stateMutability: 'view',
    inputs: [], outputs: [{ type: 'uint256' }] },
  { name: 'protocolTreasuryBp',  type: 'function', stateMutability: 'view',
    inputs: [], outputs: [{ type: 'uint256' }] },
  { name: 'providerTreasuryBp',  type: 'function', stateMutability: 'view',
    inputs: [], outputs: [{ type: 'uint256' }] },
  { name: 'revenueShareBp',      type: 'function', stateMutability: 'view',
    inputs: [], outputs: [{ type: 'uint256' }] },
  { name: 'vaultBp',             type: 'function', stateMutability: 'view',
    inputs: [], outputs: [{ type: 'uint256' }] },
  { name: 'vault',               type: 'function', stateMutability: 'view',
    inputs: [], outputs: [{ type: 'address' }] },
  { name: 'protocolTreasury',    type: 'function', stateMutability: 'view',
    inputs: [], outputs: [{ type: 'address' }] },
  { name: 'providerTreasury',    type: 'function', stateMutability: 'view',
    inputs: [], outputs: [{ type: 'address' }] },
  { name: 'distribute', type: 'function', stateMutability: 'nonpayable',
    inputs: [], outputs: [] },
] as const
```

---

## 10. Utility helpers

```ts
// lib/utils.ts
export const ZERO = '0x0000000000000000000000000000000000000000' as const

/** Format raw USDC (6 decimals) to human-readable string */
export function formatUsdc(raw: bigint, decimals = 2): string {
  return (Number(raw) / 1e6).toFixed(decimals)
}

/** Format basis points to percentage string */
export function formatBp(bp: bigint): string {
  return `${(Number(bp) / 100).toFixed(2)}%`
}

/** Format Unix timestamp to locale string */
export function formatTimestamp(ts: bigint): string {
  return ts === 0n ? 'never' : new Date(Number(ts) * 1000).toLocaleString()
}
```

---

## 11. Testnet USDC

The deployed contract uses a mock USDC (6 decimals). To get test USDC:
- Ask the protocol admin to run `uv run python admin_cli.py mint-usdc --to 0x... --amount 100000000`
- `100_000_000` raw units = 100 USDC

---

## 12. Complete flow summary

```
connect wallet → switch to Avalanche Fuji (chain ID 43113)
      ↓
read factory.USDC() → get USDC address
      ↓
check StakeManager.stakes(address) vs registry.minimumStakeRequired()
      ↓ if shortfall:
ERC20.approve(StakeManager, shortfall) → StakeManager.stake(shortfall)
      ↓
ERC20.approve(Factory, genesisDeposit) [if seeding vault]
Factory.deployProvider(...) → read ProviderDeployed event → get vault + splitter + revenueShare + providerId
      ↓
update x402 server: payTo = splitterAddress  (then redeploy/restart)
      ↓
fetchIntegrityHash(your-endpoint) → computeIntegrityHash(paymentData) → bytes32 hash
      ↓
registry.registerEndpoint(providerId, url, method, integrityHash)
      ↓
endpoint live — CRE watcher auto-settles any incoming challenges
```

---

# Optional

> Not required for the hackathon demo. Implement these to expose the full protocol surface (token economics, investor UX, contract transparency).

---

## A. Verify deployed contracts on Snowscan

After `deployProvider` you have three new contracts on-chain (vault, splitter, and
optionally revenueShare). Verifying them on [Snowscan](https://testnet.snowscan.xyz)
makes the source code publicly readable and builds trust with investors.

### Option 1 — CLI (recommended)

If you used `cli.py deploy-provider`, verification runs automatically provided
`ETHERSCAN_API_KEY` is set in `contracts/scripts/.env` (Snowscan uses the Etherscan-compatible API).
Nothing else to do.

### Option 2 — Backend API route

The Snowscan API requires the **Solidity standard JSON input**, which is generated
by Foundry. Expose a backend endpoint that calls `forge` and submits the result.

```ts
// app/api/verify-contract/route.ts  (Next.js — runs server-side with Foundry installed)
import { NextRequest, NextResponse } from 'next/server'
import { execSync } from 'child_process'
import { encodeAbiParameters, parseAbiParameters } from 'viem'

const SNOWSCAN_API  = 'https://api.etherscan.io/v2/api?chainid=43113'
const CONTRACTS_DIR = process.env.CONTRACTS_DIR!  // absolute path to contracts/
const API_KEY       = process.env.ETHERSCAN_API_KEY!  // Snowscan uses Etherscan-compatible API

function getStandardJson(contractName: string): string {
  // requires forge in PATH
  const relPath = `src/${contractName}.sol`
  const out = execSync(
    `forge verify-contract 0x0000000000000000000000000000000000000000 ${relPath}:${contractName} --show-standard-json-input`,
    { cwd: CONTRACTS_DIR, encoding: 'utf8' }
  )
  return out.trim()
}

function getCompilerVersion(contractName: string): string {
  const artifact = require(`${CONTRACTS_DIR}/out/${contractName}.sol/${contractName}.json`)
  const meta = typeof artifact.metadata === 'string' ? JSON.parse(artifact.metadata) : artifact.metadata
  const v = meta?.compiler?.version ?? ''
  return v.startsWith('v') ? v : `v${v}`
}

export async function POST(req: NextRequest) {
  const { contractName, address, ctorArgs } = await req.json()
  // ctorArgs: hex string (no 0x prefix)

  const sourceCode      = getStandardJson(contractName)
  const compilerVersion = getCompilerVersion(contractName)

  const body = new URLSearchParams({
    module:               'contract',
    action:               'verifysourcecode',
    apikey:               API_KEY,
    contractaddress:      address,
    sourceCode,
    codeformat:           'solidity-standard-json-input',
    contractname:         `${contractName}.sol:${contractName}`,
    compilerversion:      compilerVersion,
    constructorArguments: ctorArgs ?? '',
    licenseType:          '3',   // MIT
  })

  const resp = await fetch(SNOWSCAN_API, { method: 'POST', body })
  const data = await resp.json()
  return NextResponse.json(data)
}
```

### Encoding constructor arguments

Use viem's `encodeAbiParameters` to produce the ABI-encoded hex for each contract.
Read the factory inputs from your `ProviderDeployed` event + the factory's
`USDC()` and `protocolTreasury()` reads.

```ts
import { encodeAbiParameters, parseAbiParameters } from 'viem'

// ProviderRevenueVault(address usdc, string name, string symbol, address owner)
function encodeVaultArgs(usdc: `0x${string}`, name: string, symbol: string, owner: `0x${string}`) {
  return encodeAbiParameters(
    parseAbiParameters('address, string, string, address'),
    [usdc, name, symbol, owner]
  ).slice(2)   // strip 0x
}

// ProviderRevenueShare(address usdc, string name, string symbol, address owner)
// Note: factory appends " Revenue Share" to name and "RS" to symbol
function encodeRevenueShareArgs(usdc: `0x${string}`, name: string, symbol: string, owner: `0x${string}`) {
  return encodeAbiParameters(
    parseAbiParameters('address, string, string, address'),
    [usdc, `${name} Revenue Share`, `${symbol}RS`, owner]
  ).slice(2)
}

// ProviderRevenueSplitter(
//   address usdc, address protocolTreasury, uint256 protocolBp,
//   address providerTreasury, uint256 providerBp,
//   address revenueShare, uint256 revenueShareBp, address vault
// )
function encodeSplitterArgs(args: {
  usdc:             `0x${string}`
  protocolTreasury: `0x${string}`
  protocolBp:       bigint
  providerTreasury: `0x${string}`
  providerBp:       bigint
  revenueShare:     `0x${string}`
  revenueShareBp:   bigint
  vault:            `0x${string}`
}) {
  return encodeAbiParameters(
    parseAbiParameters('address, address, uint256, address, uint256, address, uint256, address'),
    [
      args.usdc, args.protocolTreasury, args.protocolBp,
      args.providerTreasury, args.providerBp,
      args.revenueShare, args.revenueShareBp, args.vault,
    ]
  ).slice(2)
}
```

### Calling it from the frontend

After the `ProviderDeployed` event is parsed (section 4), read the remaining
factory parameters and submit:

```ts
async function verifyDeployedContracts(
  deployed: { vault: `0x${string}`; splitter: `0x${string}`; revenueShare: `0x${string}` },
  name: string,
  symbol: string,
  vaultBp: bigint,
  revenueShareBp: bigint,
) {
  const [usdc, protocolTreasury, protocolBp] = await Promise.all([
    readContract(config, { address: FACTORY, abi: factoryAbi, functionName: 'USDC' }),
    readContract(config, { address: FACTORY, abi: factoryAbi, functionName: 'protocolTreasury' }),
    readContract(config, { address: FACTORY, abi: factoryAbi, functionName: 'protocolTreasuryBp' }),
  ])

  const ZERO = '0x0000000000000000000000000000000000000000' as const
  const owner = FACTORY   // factory transfers ownership to itself then to caller; use deployer address

  await Promise.all([
    fetch('/api/verify-contract', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        contractName: 'ProviderRevenueVault',
        address:      deployed.vault,
        ctorArgs:     encodeVaultArgs(usdc, name, symbol, owner),
      }),
    }),
    fetch('/api/verify-contract', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        contractName: 'ProviderRevenueShare',
        address:      deployed.revenueShare,
        ctorArgs:     encodeRevenueShareArgs(usdc, name, symbol, owner),
      }),
    }),
    fetch('/api/verify-contract', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        contractName: 'ProviderRevenueSplitter',
        address:      deployed.splitter,
        ctorArgs:     encodeSplitterArgs({
          usdc,
          protocolTreasury,
          protocolBp,
          providerTreasury: ZERO,
          providerBp:       0n,
          revenueShare:     deployed.revenueShare,
          revenueShareBp,
          vault:            deployed.vault,
        }),
      }),
    }),
  ])
}
```

> **Note:** If `revenueShareBp` is 0 and no revenue share was deployed, the
> `revenueShare` address in the splitter constructor will be `address(0)`.
> Only submit the `ProviderRevenueShare` verification if `deployed.revenueShare !== ZERO`.

---

## B. Vault — deposit, redeem, open deposits

```tsx
// All vault addresses come from the ProviderDeployed event (section 4)

const { data: totalSupply = 0n }  = useReadContract({ address: vaultAddress, abi: vaultAbi, functionName: 'totalSupply' })
const { data: totalAssets = 0n }  = useReadContract({ address: vaultAddress, abi: vaultAbi, functionName: 'totalAssets' })
const { data: depositsEnabled }   = useReadContract({ address: vaultAddress, abi: vaultAbi, functionName: 'depositsEnabled' })
const { data: myShares = 0n }     = useReadContract({ address: vaultAddress, abi: vaultAbi, functionName: 'balanceOf', args: [address!], query: { enabled: !!address } })
const { data: redeemable = 0n }   = useReadContract({ address: vaultAddress, abi: vaultAbi, functionName: 'convertToAssets', args: [myShares], query: { enabled: myShares > 0n } })

const sharePrice = totalSupply > 0n ? (totalAssets * 10n ** 18n) / totalSupply : 0n

// Owner only: open deposits
const { writeContract: openDeposits } = useWriteContract()
function handleOpenDeposits() {
  openDeposits({ address: vaultAddress, abi: vaultAbi, functionName: 'openDeposits' })
}

// Deposit USDC (approve vault first)
const { writeContract: deposit } = useWriteContract()
function handleDeposit(amount: bigint) {
  deposit({
    address: vaultAddress,
    abi: vaultAbi,
    functionName: 'deposit',
    args: [amount, address!],
  })
}

// Redeem shares for USDC
const { writeContract: redeem } = useWriteContract()
function handleRedeem(shares: bigint) {
  redeem({
    address: vaultAddress,
    abi: vaultAbi,
    functionName: 'redeem',
    args: [shares, address!, address!],
  })
}
```

---

## C. Splitter — read state & distribute

```tsx
const { data: pending = 0n }    = useReadContract({ address: splitterAddress, abi: splitterAbi, functionName: 'pendingDistribution' })
const { data: protocolBp = 0n } = useReadContract({ address: splitterAddress, abi: splitterAbi, functionName: 'protocolTreasuryBp' })
const { data: vaultBp = 0n }    = useReadContract({ address: splitterAddress, abi: splitterAbi, functionName: 'vaultBp' })
const { data: providerBp = 0n } = useReadContract({ address: splitterAddress, abi: splitterAbi, functionName: 'providerTreasuryBp' })

const { writeContract: distribute } = useWriteContract()
function handleDistribute() {
  distribute({ address: splitterAddress, abi: splitterAbi, functionName: 'distribute' })
}
```
