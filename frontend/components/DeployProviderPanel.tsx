'use client'

import { useWriteContract, useWaitForTransactionReceipt } from 'wagmi'
import { decodeEventLog } from 'viem'
import { useEffect, useState } from 'react'
import { factoryAbi, erc20Abi } from '@/lib/abis'
import { FACTORY, ZERO, shortAddr } from '@/lib/utils'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert'
import { CheckCircle2, Copy, Check } from 'lucide-react'

type DeployedInfo = {
  providerId: bigint
  vault:      `0x${string}`
  splitter:   `0x${string}`
  revenueShare: `0x${string}`
}

interface Props {
  usdcAddress: `0x${string}`
  onDeployed:  (info: DeployedInfo) => void
  initialDeployedInfo?: DeployedInfo | null
}

export function DeployProviderPanel({ usdcAddress, onDeployed, initialDeployedInfo }: Props) {
  const [name,           setName]           = useState('')
  const [symbol,         setSymbol]         = useState('')
  const [vaultBp,        setVaultBp]        = useState('9800')
  const [genesisDeposit, setGenesisDeposit] = useState('0')
  const [deployed,       setDeployed]       = useState<DeployedInfo | null>(initialDeployedInfo ?? null)

  // Sync from parent when on-chain lookup resolves
  useEffect(() => {
    if (initialDeployedInfo && !deployed) {
      setDeployed(initialDeployedInfo)
    }
  }, [initialDeployedInfo, deployed])

  // Approve genesis deposit
  const { writeContract: approve, data: approveTxHash } = useWriteContract()
  const { isSuccess: approveConfirmed } = useWaitForTransactionReceipt({ hash: approveTxHash })

  // Deploy provider
  const { writeContract: deployProvider, data: deployTxHash, isPending: deploying } = useWriteContract()
  const { data: receipt } = useWaitForTransactionReceipt({ hash: deployTxHash })

  const pendingDeploy = { name, symbol, vaultBp, genesisDeposit }

  // After approval, trigger deploy
  useEffect(() => {
    if (!approveConfirmed) return
    triggerDeploy(pendingDeploy)
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [approveConfirmed])

  // Parse receipt
  useEffect(() => {
    if (!receipt) return
    for (const log of receipt.logs) {
      try {
        const event = decodeEventLog({ abi: factoryAbi, ...log })
        if (event.eventName === 'ProviderDeployed') {
          const info: DeployedInfo = {
            providerId:   event.args.providerId,
            vault:        event.args.vault,
            splitter:     event.args.splitter,
            revenueShare: event.args.revenueShare,
          }
          setDeployed(info)
          onDeployed(info)
          return
        }
      } catch {}
    }
  }, [receipt, onDeployed])

  function triggerDeploy({ name, symbol, vaultBp, genesisDeposit }: typeof pendingDeploy) {
    deployProvider({
      address: FACTORY,
      abi: factoryAbi,
      functionName: 'deployProvider',
      args: [
        name,
        symbol,
        BigInt(vaultBp),
        0n,
        ZERO,
        BigInt(Math.round(parseFloat(genesisDeposit || '0') * 1e6)),
        ZERO,
        0n,
        0n,
        ZERO,
        '',
      ],
    })
  }

  function handleDeploy() {
    if (!name || !symbol) return
    const genesis = parseFloat(genesisDeposit || '0')
    if (genesis > 0) {
      approve({
        address: usdcAddress,
        abi: erc20Abi,
        functionName: 'approve',
        args: [FACTORY, BigInt(Math.round(genesis * 1e6))],
      })
    } else {
      triggerDeploy({ name, symbol, vaultBp, genesisDeposit })
    }
  }

  if (deployed) {
    return (
      <div className="space-y-4">
        <Alert variant="success">
          <CheckCircle2 className="h-4 w-4" />
          <AlertTitle>Provider deployed</AlertTitle>
        </Alert>
        <div className="rounded-md bg-muted p-4 space-y-2 font-mono text-sm">
          <Row label="Provider ID" value={deployed.providerId.toString()} />
          <Row label="Vault"       value={deployed.vault} copy />
          <Row label="Splitter"    value={deployed.splitter} copy />
          {deployed.revenueShare !== ZERO && (
            <Row label="Revenue Share" value={deployed.revenueShare} copy />
          )}
        </div>
        <p className="text-xs text-muted-foreground">✓ Provider deployed — proceed to step 3 below.</p>
      </div>
    )
  }

  return (
    <div className="space-y-4">
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <div className="space-y-2">
          <Label>Vault token name</Label>
          <Input placeholder="My API Vault" value={name} onChange={e => setName(e.target.value)} />
        </div>
        <div className="space-y-2">
          <Label>Vault token symbol</Label>
          <Input placeholder="MAPIV" value={symbol} onChange={e => setSymbol(e.target.value)} />
        </div>
      </div>
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <div className="space-y-2">
          <Label>Vault basis points <span className="text-muted-foreground">(max 10000 − protocol fee)</span></Label>
          <Input type="number" min="0" max="10000" value={vaultBp} onChange={e => setVaultBp(e.target.value)} />
        </div>
        <div className="space-y-2">
          <Label>Genesis deposit (USDC) <span className="text-muted-foreground">optional</span></Label>
          <Input type="number" min="0" step="0.01" value={genesisDeposit} onChange={e => setGenesisDeposit(e.target.value)} />
        </div>
      </div>
      <Button
        className="w-full"
        onClick={handleDeploy}
        disabled={deploying || !name || !symbol}
      >
        {deploying ? 'Deploying…' : 'Deploy Provider'}
      </Button>
    </div>
  )
}

function Row({ label, value, copy }: { label: string; value: string; copy?: boolean }) {
  const [copied, setCopied] = useState(false)
  return (
    <div className="flex justify-between items-center gap-2">
      <span className="text-muted-foreground shrink-0">{label}</span>
      <span className="text-foreground break-all text-right flex items-center gap-1.5">
        {copy ? shortAddr(value) : value}
        {copy && (
          <button
            className="inline-flex items-center justify-center rounded-md h-6 w-6 hover:bg-accent transition-colors"
            onClick={() => { navigator.clipboard.writeText(value); setCopied(true); setTimeout(() => setCopied(false), 1500) }}
          >
            {copied ? <Check className="h-3 w-3 text-emerald-400" /> : <Copy className="h-3 w-3 text-muted-foreground" />}
          </button>
        )}
      </span>
    </div>
  )
}
