'use client'

import { useEffect, useState } from 'react'
import { createPublicClient, http, parseAbiItem, type Log } from 'viem'
import { avalancheFuji } from 'wagmi/chains'
import { registryAbi } from '@/lib/abis'
import { REGISTRY, DEPLOY_BLOCK, RPC_URL, formatTimestamp, shortAddr } from '@/lib/utils'
import { Badge } from '@/components/ui/badge'
import { Loader2 } from 'lucide-react'

type EndpointInfo = {
  endpointId:    `0x${string}`
  provider:      `0x${string}`
  path:          string
  method:        string
  integrityHash: `0x${string}`
  version:       bigint
  active:        boolean
  checkedAt:     bigint
  createdAt:     bigint
}

const CHUNK_SIZE = 2048n

const publicClient = createPublicClient({
  chain: avalancheFuji,
  transport: http(RPC_URL),
})

/** Fetch logs in chunks of CHUNK_SIZE blocks to respect RPC limits */
async function getLogsChunked(
  fromBlock: bigint,
  toBlock: bigint,
) {
  const allLogs: Log[] = []
  let start = fromBlock
  while (start <= toBlock) {
    const end = start + CHUNK_SIZE - 1n > toBlock ? toBlock : start + CHUNK_SIZE - 1n
    const logs = await publicClient.getLogs({
      address: REGISTRY,
      event: parseAbiItem(
        'event EndpointRegistered(bytes32 indexed endpointId, address indexed provider, uint256 indexed providerId)'
      ),
      fromBlock: start,
      toBlock: end,
    })
    allLogs.push(...logs)
    start = end + 1n
  }
  return allLogs
}

export function EndpointList({ refreshKey }: { refreshKey?: number }) {
  const [endpoints, setEndpoints] = useState<EndpointInfo[]>([])
  const [loading,   setLoading]   = useState(false)
  const [error,     setError]     = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    async function load() {
      setLoading(true)
      setError(null)
      try {
        const latestBlock = await publicClient.getBlockNumber()
        const logs = await getLogsChunked(DEPLOY_BLOCK, latestBlock)

        const results = await Promise.all(
          logs.map(async log => {
            const args = (log as unknown as { args: { endpointId: `0x${string}` } }).args
            const data = await publicClient.readContract({
              address: REGISTRY,
              abi: registryAbi,
              functionName: 'endpoints',
              args: [args.endpointId],
            })
            return data as unknown as EndpointInfo
          })
        )
        if (!cancelled) setEndpoints(results.reverse())
      } catch (e: unknown) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e))
      } finally {
        if (!cancelled) setLoading(false)
      }
    }
    load()
    return () => { cancelled = true }
  }, [refreshKey])

  if (loading) {
    return (
      <div className="flex items-center gap-2 text-muted-foreground text-sm py-4 justify-center">
        <Loader2 className="h-4 w-4 animate-spin" />
        <span>Loading endpoints…</span>
      </div>
    )
  }
  if (error) return <p className="text-destructive text-sm">Error: {error}</p>
  if (endpoints.length === 0) return <p className="text-muted-foreground text-sm text-center py-4">No endpoints registered yet.</p>

  return (
    <div className="space-y-2">
      {endpoints.map(ep => (
        <div key={ep.endpointId} className="rounded-md border bg-muted/50 p-3 text-sm space-y-2">
          <div className="flex items-center justify-between">
            <span className="font-mono text-xs text-muted-foreground">{shortAddr(ep.endpointId)}</span>
            <div className="flex items-center gap-2">
              <Badge variant={ep.active ? 'success' : 'destructive'}>
                {ep.active ? 'active' : 'inactive'}
              </Badge>
              <Badge variant="secondary">{ep.method}</Badge>
            </div>
          </div>
          <p className="text-foreground break-all">{ep.path}</p>
          <div className="flex flex-wrap gap-x-4 gap-y-1 text-xs text-muted-foreground">
            <span>Provider: {shortAddr(ep.provider)}</span>
            <span>Created: {formatTimestamp(ep.createdAt)}</span>
            {ep.checkedAt > 0n && <span>Last checked: {formatTimestamp(ep.checkedAt)}</span>}
          </div>
          <details className="text-xs">
            <summary className="text-muted-foreground cursor-pointer hover:text-foreground transition-colors">Integrity hash</summary>
            <code className="block mt-1 text-primary break-all">{ep.integrityHash}</code>
          </details>
        </div>
      ))}
    </div>
  )
}
