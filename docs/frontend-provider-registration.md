# Frontend Integration Guide — Provider Registration

Step-by-step guide for building a wagmi/React page that lets an API provider
register themselves on the HTTPayer protocol (Avalanche Fuji testnet).

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

## 5. Integrity hash verification — CORS & backend

The integrity hash is a SHA-256 of your endpoint's live x402 payment metadata.
The browser needs to read the `402` response (body or `PAYMENT-REQUIRED` header)
from your x402 server.

### When you don't need a backend

If your x402 server sets these CORS headers on 402 responses, the browser can
fetch directly:

```
Access-Control-Allow-Origin: *
Access-Control-Expose-Headers: payment-required
```

In that case use the client-side function from section 5a.

### When you need a backend proxy

Most x402 servers don't expose CORS on 402 responses by default. If the browser
gets a CORS error when fetching your endpoint, add a thin proxy route.

#### Option A — Next.js API route (recommended)

```ts
// app/api/verify-hash/route.ts
import { NextRequest, NextResponse } from 'next/server'
import { sha256 } from '@noble/hashes/sha256'

export async function GET(req: NextRequest) {
  const url = req.nextUrl.searchParams.get('url')
  if (!url) return NextResponse.json({ error: 'missing url' }, { status: 400 })

  try {
    const resp = await fetch(url, { headers: { Accept: 'application/json' } })

    let paymentData: any
    const paymentHeader = resp.headers.get('payment-required')
    if (paymentHeader) {
      paymentData = JSON.parse(Buffer.from(paymentHeader, 'base64').toString())
    } else {
      paymentData = await resp.json()
    }

    const entry = paymentData.accepts[0]
    const metadata = {
      amount:  String(entry.amount),
      asset:   String(entry.asset),
      network: String(entry.network),
      payTo:   String(entry.payTo).toLowerCase(),
      url:     String(paymentData.resource?.url ?? ''),
    }

    const sorted = Object.fromEntries(
      Object.keys(metadata).sort().map(k => [k, metadata[k as keyof typeof metadata]])
    )
    const dataString = JSON.stringify(sorted)
    const hashBytes  = sha256(new TextEncoder().encode(dataString))
    const hash = '0x' + Array.from(hashBytes).map(b => b.toString(16).padStart(2, '0')).join('')

    return NextResponse.json({ hash, metadata, dataString })
  } catch (err: any) {
    return NextResponse.json({ error: err.message }, { status: 500 })
  }
}
```

Call it from the frontend:

```ts
// lib/integrityHash.ts
export async function fetchIntegrityHash(endpointUrl: string): Promise<`0x${string}`> {
  // Try direct browser fetch first
  try {
    return await fetchHashDirect(endpointUrl)
  } catch {
    // Fall back to backend proxy if CORS blocks us
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
import { sha256 } from '@noble/hashes/sha256'

app.get('/api/verify-hash', async (req, res) => {
  const { url } = req.query as { url: string }
  if (!url) return res.status(400).json({ error: 'missing url' })

  const resp = await fetch(url, { headers: { Accept: 'application/json' } })
  let paymentData: any

  const header = resp.headers.get('payment-required')
  if (header) {
    paymentData = JSON.parse(Buffer.from(header, 'base64').toString())
  } else {
    paymentData = await resp.json()
  }

  const entry    = paymentData.accepts[0]
  const metadata = {
    amount:  String(entry.amount),
    asset:   String(entry.asset),
    network: String(entry.network),
    payTo:   String(entry.payTo).toLowerCase(),
    url:     String(paymentData.resource?.url ?? ''),
  }
  const sorted     = Object.fromEntries(Object.keys(metadata).sort().map(k => [k, metadata[k as keyof typeof metadata]]))
  const hashBytes  = sha256(new TextEncoder().encode(JSON.stringify(sorted)))
  const hash       = '0x' + Array.from(hashBytes).map(b => b.toString(16).padStart(2, '0')).join('')

  res.json({ hash, metadata })
})
```

### 5a. Client-side only (direct fetch, CORS must allow it)

```ts
// lib/integrityHash.ts
import { sha256 } from '@noble/hashes/sha256'

export async function fetchHashDirect(endpointUrl: string): Promise<`0x${string}`> {
  const resp = await fetch(endpointUrl, { headers: { Accept: 'application/json' } })

  let paymentData: any
  const paymentHeader = resp.headers.get('payment-required')
  if (paymentHeader) {
    paymentData = JSON.parse(atob(paymentHeader))
  } else {
    paymentData = await resp.json()
  }

  const entry    = paymentData.accepts[0]
  const metadata = {
    amount:  String(entry.amount),
    asset:   String(entry.asset),
    network: String(entry.network),
    payTo:   String(entry.payTo).toLowerCase(),
    url:     String(paymentData.resource?.url ?? ''),
  }

  const sorted     = Object.fromEntries(Object.keys(metadata).sort().map(k => [k, metadata[k as keyof typeof metadata]]))
  const hashBytes  = sha256(new TextEncoder().encode(JSON.stringify(sorted)))
  return ('0x' + Array.from(hashBytes).map(b => b.toString(16).padStart(2, '0')).join('')) as `0x${string}`
}
```

### Verify existing endpoint (compare live vs on-chain)

```ts
import { useReadContract } from 'wagmi'

async function verifyEndpoint(endpointId: `0x${string}`, endpointUrl: string) {
  // Read on-chain hash
  const endpoint = await readContract(config, {
    address: REGISTRY,
    abi: registryAbi,
    functionName: 'endpoints',
    args: [endpointId],
  })
  const onChainHash = endpoint.integrityHash  // bytes32 hex

  // Compute live hash
  const liveHash = await fetchIntegrityHash(endpointUrl)

  return {
    match:       liveHash.toLowerCase() === onChainHash.toLowerCase(),
    liveHash,
    onChainHash,
  }
}
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

## 8. Vault — deposit, redeem, open deposits

```tsx
// All vault addresses come from the ProviderDeployed event (step 2)

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

## 9. Splitter — read state & distribute

```tsx
const { data: pending = 0n }     = useReadContract({ address: splitterAddress, abi: splitterAbi, functionName: 'pendingDistribution' })
const { data: protocolBp = 0n }  = useReadContract({ address: splitterAddress, abi: splitterAbi, functionName: 'protocolTreasuryBp' })
const { data: vaultBp = 0n }     = useReadContract({ address: splitterAddress, abi: splitterAbi, functionName: 'vaultBp' })
const { data: providerBp = 0n }  = useReadContract({ address: splitterAddress, abi: splitterAbi, functionName: 'providerTreasuryBp' })

const { writeContract: distribute } = useWriteContract()
function handleDistribute() {
  distribute({ address: splitterAddress, abi: splitterAbi, functionName: 'distribute' })
}
```

---

## 10. Enumerate all endpoints (event-based)

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

## 11. Complete ABI reference

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

## 12. Utility helpers

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

## 13. Testnet USDC

The deployed contract uses a mock USDC (6 decimals). To get test USDC:
- Ask the protocol admin to run `uv run python admin_cli.py mint-usdc --to 0x... --amount 100000000`
- `100_000_000` raw units = 100 USDC

---

## 14. Complete flow summary

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
Factory.deployProvider(...) → read ProviderDeployed event → get splitter + providerId
      ↓
update x402 server: payTo = splitterAddress  (then redeploy/restart)
      ↓
GET /api/verify-hash?url=<your-endpoint>  → get integrityHash
      ↓
registry.registerEndpoint(providerId, url, method, integrityHash)
      ↓
endpoint live — CRE watcher auto-settles any incoming challenges
```
