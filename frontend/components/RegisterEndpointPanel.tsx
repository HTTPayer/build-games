'use client'

import { useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { decodeEventLog } from 'viem'
import { useEffect, useState } from 'react'
import { registryAbi } from '@/lib/abis'
import { REGISTRY, shortAddr } from '@/lib/utils'
import { fetchIntegrityHash } from '@/lib/integrityHash'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select } from '@/components/ui/select'
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert'
import { CheckCircle2, Hash, Loader2, Copy, Check, ExternalLink, Server, Terminal } from 'lucide-react'

const CLI_REPO_URL = 'https://github.com/AvalancheAI/x402-cli'

interface Props {
  providerId: bigint
  splitterAddress: `0x${string}`
  onRegistered?: (endpointId: `0x${string}`) => void
}

export function RegisterEndpointPanel({ providerId, splitterAddress, onRegistered }: Props) {
  const [url,           setUrl]           = useState('')
  const [method,        setMethod]        = useState('GET')
  const [integrityHash, setIntegrityHash] = useState('')
  const [liveHash,      setLiveHash]      = useState<`0x${string}` | null>(null)
  const [hashError,     setHashError]     = useState<string | null>(null)
  const [fetchingHash,  setFetchingHash]  = useState(false)
  const [endpointId,    setEndpointId]    = useState<`0x${string}` | null>(null)
  const [copied,        setCopied]        = useState(false)

  const { writeContract: registerEndpoint, data: regTxHash, isPending } = useWriteContract()
  const { isSuccess: registered, data: regReceipt } = useWaitForTransactionReceipt({ hash: regTxHash })

  // The hash to use: manual input takes priority, then auto-fetched
  const resolvedHash = (integrityHash.startsWith('0x') && integrityHash.length === 66
    ? integrityHash as `0x${string}`
    : liveHash) ?? null

  useEffect(() => {
    if (!regReceipt) return
    for (const log of regReceipt.logs) {
      try {
        const event = decodeEventLog({ abi: registryAbi, ...log })
        if (event.eventName === 'EndpointRegistered') {
          const id = event.args.endpointId as `0x${string}`
          setEndpointId(id)
          onRegistered?.(id)
          return
        }
      } catch {}
    }
  }, [regReceipt, onRegistered])

  function copyToClipboard(text: string) {
    navigator.clipboard.writeText(text)
    setCopied(true)
    setTimeout(() => setCopied(false), 1500)
  }

  async function handleFetchHash() {
    if (!url) return
    setFetchingHash(true)
    setHashError(null)
    setLiveHash(null)
    try {
      const hash = await fetchIntegrityHash(url)
      setLiveHash(hash)
      setIntegrityHash(hash)
    } catch (e: unknown) {
      setHashError(e instanceof Error ? e.message : String(e))
    } finally {
      setFetchingHash(false)
    }
  }

  function handleRegister() {
    if (!url || !resolvedHash) return
    registerEndpoint({
      address: REGISTRY,
      abi: registryAbi,
      functionName: 'registerEndpoint',
      args: [providerId, url, method, resolvedHash],
    })
  }

  if (endpointId) {
    return (
      <div className="space-y-4">
        <Alert variant="success">
          <CheckCircle2 className="h-4 w-4" />
          <AlertTitle>Endpoint registered!</AlertTitle>
        </Alert>
        <div className="rounded-md bg-muted p-4 font-mono text-sm space-y-2">
          <div className="flex justify-between">
            <span className="text-muted-foreground">Endpoint ID</span>
            <span className="text-foreground break-all text-right">{shortAddr(endpointId)}</span>
          </div>
          <div className="flex justify-between">
            <span className="text-muted-foreground">URL</span>
            <span className="text-foreground break-all text-right">{url}</span>
          </div>
        </div>
      </div>
    )
  }

  return (
    <div className="space-y-5">
      {/* Sub-step A: Update payTo */}
      <div className="rounded-lg border border-yellow-500/25 p-4 space-y-3">
        <div className="flex items-center gap-2">
          <Server className="h-4 w-4 text-yellow-400" />
          <span className="text-sm font-medium">A. Update your server&apos;s payTo address</span>
        </div>
        <p className="text-xs text-muted-foreground">
          Set your x402 server <code className="rounded bg-muted px-1 py-0.5 text-primary font-mono text-xs">payTo</code> to
          the Revenue Splitter below, then restart your server.
        </p>
        <div className="rounded-md bg-muted p-3 font-mono text-sm flex items-center justify-between gap-2">
          <code className="text-yellow-400 break-all text-xs">{splitterAddress}</code>
          <button
            className="shrink-0 inline-flex items-center justify-center rounded-md h-7 w-7 hover:bg-accent transition-colors"
            onClick={() => copyToClipboard(splitterAddress)}
          >
            {copied ? <Check className="h-3.5 w-3.5 text-emerald-400" /> : <Copy className="h-3.5 w-3.5 text-muted-foreground" />}
          </button>
        </div>
      </div>

      {/* Sub-step B: Compute integrity hash */}
      <div className="rounded-lg border p-4 space-y-3">
        <div className="flex items-center gap-2">
          <Terminal className="h-4 w-4 text-muted-foreground" />
          <span className="text-sm font-medium">B. Compute the integrity hash</span>
        </div>
        <p className="text-xs text-muted-foreground">
          After updating your server, compute the integrity hash using the{' '}
          <a href={CLI_REPO_URL} target="_blank" rel="noopener noreferrer" className="text-primary underline underline-offset-2 inline-flex items-center gap-0.5">
            CLI / SDK <ExternalLink className="h-3 w-3" />
          </a>{' '}
          or let us try to auto-fetch it from your live endpoint.
        </p>

        <div className="space-y-2">
          <Label>Integrity hash <span className="text-muted-foreground font-normal">(0x…)</span></Label>
          <Input
            placeholder="0x… (paste hash from CLI or auto-fetch below)"
            value={integrityHash}
            onChange={e => setIntegrityHash(e.target.value)}
            className="font-mono text-xs"
          />
        </div>

        <div className="flex items-center gap-2">
          <div className="h-px flex-1 bg-border" />
          <span className="text-xs text-muted-foreground">or</span>
          <div className="h-px flex-1 bg-border" />
        </div>

        <div className="flex items-center justify-between">
          <p className="text-xs text-muted-foreground">Auto-fetch from live endpoint:</p>
          <Button
            variant="outline"
            size="sm"
            onClick={handleFetchHash}
            disabled={fetchingHash || !url}
          >
            {fetchingHash && <Loader2 className="mr-2 h-3 w-3 animate-spin" />}
            {fetchingHash ? 'Fetching…' : 'Fetch hash'}
          </Button>
        </div>
        {hashError && (
          <p className="text-sm text-destructive">Error: {hashError}</p>
        )}
        {liveHash && !integrityHash && (
          <div className="rounded-md bg-muted p-3">
            <p className="text-xs text-muted-foreground mb-1">Fetched hash</p>
            <code className="text-xs text-emerald-400 break-all">{liveHash}</code>
          </div>
        )}
      </div>

      {/* Sub-step C: Register */}
      <div className="rounded-lg border p-4 space-y-3">
        <div className="flex items-center gap-2">
          <Hash className="h-4 w-4 text-muted-foreground" />
          <span className="text-sm font-medium">C. Register on-chain</span>
        </div>

        <div className="space-y-2">
          <Label>Endpoint URL</Label>
          <Input
            placeholder="https://api.example.com/data"
            value={url}
            onChange={e => setUrl(e.target.value)}
          />
        </div>
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <div className="space-y-2">
            <Label>HTTP method</Label>
            <Select value={method} onChange={e => setMethod(e.target.value)}>
              {['GET', 'POST', 'PUT', 'PATCH', 'DELETE'].map(m => (
                <option key={m} value={m}>{m}</option>
              ))}
            </Select>
          </div>
          <div className="space-y-2">
            <Label>Provider ID</Label>
            <Input disabled value={providerId.toString()} />
          </div>
        </div>

        {resolvedHash && (
          <div className="rounded-md bg-muted p-3">
            <p className="text-xs text-muted-foreground mb-1">Hash to register</p>
            <code className="text-xs text-emerald-400 break-all">{resolvedHash}</code>
          </div>
        )}

        <Button
          className="w-full"
          onClick={handleRegister}
          disabled={isPending || !resolvedHash || !url}
        >
          {isPending && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
          {isPending ? 'Registering…' : 'Register Endpoint'}
        </Button>
      </div>

      {registered && (
        <Alert variant="success">
          <CheckCircle2 className="h-4 w-4" />
          <AlertDescription>Endpoint registered on-chain!</AlertDescription>
        </Alert>
      )}
    </div>
  )
}
