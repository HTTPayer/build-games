'use client'

import { useReadContract, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { decodeEventLog } from 'viem'
import { useEffect, useState } from 'react'
import { challengeManagerAbi, erc20Abi } from '@/lib/abis'
import { CHALLENGE_MANAGER, formatUsdc, shortAddr } from '@/lib/utils'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Badge } from '@/components/ui/badge'
import { Alert, AlertDescription } from '@/components/ui/alert'
import { CheckCircle2, Loader2, Search } from 'lucide-react'

const CHALLENGE_STATUS = ['Pending', 'Valid', 'Invalid'] as const

interface Props {
  usdcAddress: `0x${string}`
}

export function ChallengePanel({ usdcAddress }: Props) {
  const [endpointId,      setEndpointId]      = useState('')
  const [challengeIdRead, setChallengeIdRead] = useState('')
  const [openedId,        setOpenedId]        = useState<bigint | null>(null)

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

  const { data: challengeCount = 0n } = useReadContract({
    address: CHALLENGE_MANAGER,
    abi: challengeManagerAbi,
    functionName: 'challengeCount',
  })

  const { data: challenge } = useReadContract({
    address: CHALLENGE_MANAGER,
    abi: challengeManagerAbi,
    functionName: 'challenges',
    args: [challengeIdRead ? BigInt(challengeIdRead) : 0n],
    query: { enabled: !!challengeIdRead },
  })

  // Approve fee → open challenge
  const { writeContract: approveFee, data: approveTxHash } = useWriteContract()
  const { isSuccess: feeApproved } = useWaitForTransactionReceipt({ hash: approveTxHash })

  const { writeContract: openChallenge, data: challengeTxHash, isPending: opening } = useWriteContract()
  const { data: challengeReceipt } = useWaitForTransactionReceipt({ hash: challengeTxHash })

  useEffect(() => {
    if (!feeApproved || !endpointId) return
    openChallenge({
      address: CHALLENGE_MANAGER,
      abi: challengeManagerAbi,
      functionName: 'openChallenge',
      args: [endpointId as `0x${string}`],
    })
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [feeApproved])

  useEffect(() => {
    if (!challengeReceipt) return
    for (const log of challengeReceipt.logs) {
      try {
        const event = decodeEventLog({ abi: challengeManagerAbi, ...log })
        if (event.eventName === 'ChallengeOpened') {
          setOpenedId(event.args.id)
          return
        }
      } catch {}
    }
  }, [challengeReceipt])

  function handleOpenChallenge() {
    if (!endpointId || !challengeFee) return
    approveFee({ address: usdcAddress, abi: erc20Abi, functionName: 'approve', args: [CHALLENGE_MANAGER, challengeFee] })
  }

  const challengeData = challenge as [string, string, number] | undefined
  const statusLabel   = challengeData ? CHALLENGE_STATUS[challengeData[2]] ?? 'Unknown' : null
  const statusVariant = statusLabel === 'Valid' ? 'destructive' as const : statusLabel === 'Invalid' ? 'success' as const : 'warning' as const

  return (
    <div className="space-y-4">
      {/* Protocol stats */}
      <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
        <div className="rounded-md bg-muted p-3 text-center">
          <div className="text-xs text-muted-foreground mb-1">Challenge fee</div>
          <div className="font-mono font-semibold text-foreground">{formatUsdc(challengeFee)} USDC</div>
        </div>
        <div className="rounded-md bg-muted p-3 text-center">
          <div className="text-xs text-muted-foreground mb-1">Slash basis points</div>
          <div className="font-mono font-semibold text-foreground">{slashBp.toString()} bp</div>
        </div>
        <div className="rounded-md bg-muted p-3 text-center">
          <div className="text-xs text-muted-foreground mb-1">Total challenges</div>
          <div className="font-mono font-semibold text-foreground">{challengeCount.toString()}</div>
        </div>
      </div>

      {/* Open a challenge */}
      <div className="rounded-lg border p-4 space-y-3">
        <h3 className="text-sm font-medium">Open a challenge</h3>
        <div className="space-y-2">
          <Label>Endpoint ID (bytes32)</Label>
          <Input
            className="font-mono text-xs"
            placeholder="0x..."
            value={endpointId}
            onChange={e => setEndpointId(e.target.value)}
          />
        </div>
        <Button
          variant="destructive"
          className="w-full"
          onClick={handleOpenChallenge}
          disabled={opening || !endpointId || !challengeFee}
        >
          {opening && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
          {opening ? 'Opening…' : `Open Challenge (fee: ${formatUsdc(challengeFee)} USDC)`}
        </Button>
        {openedId !== null && (
          <Alert variant="success">
            <CheckCircle2 className="h-4 w-4" />
            <AlertDescription>Challenge #{openedId.toString()} opened</AlertDescription>
          </Alert>
        )}
      </div>

      {/* Read a challenge */}
      <div className="rounded-lg border p-4 space-y-3">
        <div className="flex items-center gap-2">
          <Search className="h-4 w-4 text-muted-foreground" />
          <h3 className="text-sm font-medium">Look up challenge</h3>
        </div>
        <div className="space-y-2">
          <Label>Challenge ID</Label>
          <Input
            type="number"
            min="0"
            placeholder="0"
            value={challengeIdRead}
            onChange={e => setChallengeIdRead(e.target.value)}
          />
        </div>
        {challengeData && (
          <div className="rounded-md bg-muted p-4 text-sm space-y-2">
            <div className="flex justify-between items-center">
              <span className="text-muted-foreground">Status</span>
              <Badge variant={statusVariant}>{statusLabel}</Badge>
            </div>
            <div className="flex justify-between">
              <span className="text-muted-foreground">Challenger</span>
              <span className="font-mono text-foreground">{shortAddr(challengeData[0])}</span>
            </div>
            <div className="flex justify-between items-start gap-2">
              <span className="text-muted-foreground shrink-0">Endpoint</span>
              <span className="font-mono text-xs break-all text-right text-foreground">{shortAddr(challengeData[1])}</span>
            </div>
          </div>
        )}
      </div>
    </div>
  )
}
