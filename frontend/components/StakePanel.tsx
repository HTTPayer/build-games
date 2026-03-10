'use client'

import { useAccount, useReadContract, useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { useEffect, useState } from 'react'
import { erc20Abi, stakeManagerAbi, registryAbi } from '@/lib/abis'
import { STAKE_MANAGER, REGISTRY, formatUsdc, formatTimestamp } from '@/lib/utils'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Alert, AlertDescription } from '@/components/ui/alert'
import { CheckCircle2, AlertTriangle } from 'lucide-react'

export function StakePanel({ usdcAddress }: { usdcAddress: `0x${string}` }) {
  const { address } = useAccount()
  const [unstakeAmount, setUnstakeAmount] = useState('')

  const { data: minimumStake = 0n } = useReadContract({
    address: REGISTRY,
    abi: registryAbi,
    functionName: 'minimumStakeRequired',
  })

  const { data: stakeInfo, refetch: refetchStake } = useReadContract({
    address: STAKE_MANAGER,
    abi: stakeManagerAbi,
    functionName: 'stakes',
    args: [address!],
    query: { enabled: !!address },
  })
  const staked    = stakeInfo?.[0] ?? 0n
  const unlocksAt = stakeInfo?.[1] ?? 0n

  const { data: usdcBalance = 0n } = useReadContract({
    address: usdcAddress,
    abi: erc20Abi,
    functionName: 'balanceOf',
    args: [address!],
    query: { enabled: !!address },
  })

  const { data: cooldown = 0n } = useReadContract({
    address: STAKE_MANAGER,
    abi: stakeManagerAbi,
    functionName: 'withdrawCooldown',
  })

  const shortfall = minimumStake > staked ? minimumStake - staked : 0n

  // Approve + Stake
  const { writeContract: approve, data: approveTxHash } = useWriteContract()
  const { isSuccess: approveConfirmed } = useWaitForTransactionReceipt({ hash: approveTxHash })
  const { writeContract: stake, data: stakeTxHash, isPending: staking } = useWriteContract()
  const { isSuccess: stakeConfirmed } = useWaitForTransactionReceipt({ hash: stakeTxHash })

  useEffect(() => {
    if (approveConfirmed && shortfall > 0n) {
      stake({ address: STAKE_MANAGER, abi: stakeManagerAbi, functionName: 'stake', args: [shortfall] })
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [approveConfirmed])

  useEffect(() => { if (stakeConfirmed) refetchStake() }, [stakeConfirmed, refetchStake])

  function handleStake() {
    if (shortfall === 0n) return
    approve({ address: usdcAddress, abi: erc20Abi, functionName: 'approve', args: [STAKE_MANAGER, shortfall] })
  }

  // Request unstake
  const { writeContract: requestUnstake, data: requestTxHash, isPending: requesting } = useWriteContract()
  const { isSuccess: requestConfirmed } = useWaitForTransactionReceipt({ hash: requestTxHash })
  useEffect(() => { if (requestConfirmed) refetchStake() }, [requestConfirmed, refetchStake])

  // Withdraw
  const { writeContract: withdraw, data: withdrawTxHash, isPending: withdrawing } = useWriteContract()
  const { isSuccess: withdrawConfirmed } = useWaitForTransactionReceipt({ hash: withdrawTxHash })
  useEffect(() => { if (withdrawConfirmed) refetchStake() }, [withdrawConfirmed, refetchStake])

  const canWithdraw = unlocksAt > 0n && BigInt(Math.floor(Date.now() / 1000)) >= unlocksAt
  const meetsMinimum = staked >= minimumStake && minimumStake > 0n

  return (
    <div className="space-y-4">
      <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
        <div className="rounded-md bg-muted p-3 text-center">
          <div className="text-xs text-muted-foreground mb-1">Minimum required</div>
          <div className="font-mono font-semibold text-foreground text-sm sm:text-base">{formatUsdc(minimumStake)} USDC</div>
        </div>
        <div className="rounded-md bg-muted p-3 text-center">
          <div className="text-xs text-muted-foreground mb-1">Your stake</div>
          <div className="font-mono font-semibold text-foreground text-sm sm:text-base">{formatUsdc(staked)} USDC</div>
        </div>
        <div className="rounded-md bg-muted p-3 text-center">
          <div className="text-xs text-muted-foreground mb-1">Wallet balance</div>
          <div className="font-mono font-semibold text-foreground text-sm sm:text-base">{formatUsdc(usdcBalance)} USDC</div>
        </div>
      </div>

      {meetsMinimum ? (
        <Alert variant="success">
          <CheckCircle2 className="h-4 w-4" />
          <AlertDescription>Stake meets minimum requirement</AlertDescription>
        </Alert>
      ) : (
        <Alert variant="warning">
          <AlertTriangle className="h-4 w-4" />
          <AlertDescription className="flex flex-col sm:flex-row items-start sm:items-center justify-between gap-2">
            <span>Shortfall: <strong>{formatUsdc(shortfall)} USDC</strong></span>
            <Button
              size="sm"
              onClick={handleStake}
              disabled={staking || !address || usdcBalance < shortfall}
            >
              {staking ? 'Staking…' : `Stake ${formatUsdc(shortfall)} USDC`}
            </Button>
          </AlertDescription>
        </Alert>
      )}

      {stakeConfirmed && (
        <Alert variant="success">
          <CheckCircle2 className="h-4 w-4" />
          <AlertDescription>Staked successfully</AlertDescription>
        </Alert>
      )}

      {/* Unstake section */}
      {staked > 0n && (
        <div className="border-t pt-4 space-y-3">
          <p className="text-sm text-muted-foreground">
            Cooldown period: <span className="text-foreground">{Number(cooldown) / 86400} days</span>
            {unlocksAt > 0n && (
              <span className="ml-2">· Unlocks: {formatTimestamp(unlocksAt)}</span>
            )}
          </p>
          <div className="flex flex-col sm:flex-row gap-2">
            <Input
              placeholder="Amount to unstake (USDC)"
              value={unstakeAmount}
              onChange={e => setUnstakeAmount(e.target.value)}
            />
            <Button
              variant="secondary"
              className="whitespace-nowrap w-full sm:w-auto"
              disabled={requesting || !unstakeAmount}
              onClick={() => {
                const raw = BigInt(Math.round(parseFloat(unstakeAmount) * 1e6))
                requestUnstake({ address: STAKE_MANAGER, abi: stakeManagerAbi, functionName: 'requestUnstake', args: [raw] })
              }}
            >
              {requesting ? 'Requesting…' : 'Request unstake'}
            </Button>
          </div>
          {canWithdraw && (
            <Button
              variant="destructive"
              disabled={withdrawing}
              onClick={() => withdraw({ address: STAKE_MANAGER, abi: stakeManagerAbi, functionName: 'withdraw', args: [staked] })}
            >
              {withdrawing ? 'Withdrawing…' : `Withdraw ${formatUsdc(staked)} USDC`}
            </Button>
          )}
          {withdrawConfirmed && (
            <Alert variant="success">
              <CheckCircle2 className="h-4 w-4" />
              <AlertDescription>Withdrawn successfully</AlertDescription>
            </Alert>
          )}
        </div>
      )}
    </div>
  )
}
