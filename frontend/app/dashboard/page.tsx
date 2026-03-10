'use client'

import { ConnectButton } from '@rainbow-me/rainbowkit'
import { useAccount, useReadContract, useChainId, useSwitchChain, usePublicClient } from 'wagmi'
import { avalancheFuji } from 'wagmi/chains'
import { useState, useEffect, useCallback } from 'react'
import { factoryAbi, registryAbi, stakeManagerAbi } from '@/lib/abis'
import { FACTORY, REGISTRY, STAKE_MANAGER, RPC_URL, ZERO } from '@/lib/utils'
import { StakePanel }            from '@/components/StakePanel'
import { DeployProviderPanel }   from '@/components/DeployProviderPanel'
import { RegisterEndpointPanel } from '@/components/RegisterEndpointPanel'
import { ChallengePanel }        from '@/components/ChallengePanel'
import { EndpointList }          from '@/components/EndpointList'
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '@/components/ui/card'
import { Button } from '@/components/ui/button'
import { Alert, AlertDescription } from '@/components/ui/alert'
import { CheckCircle2, AlertTriangle, Zap, Shield, List, RefreshCw } from 'lucide-react'
import Link from 'next/link'

const DEBUG = false

type DeployedInfo = {
  providerId:   bigint
  vault:        `0x${string}`
  splitter:     `0x${string}`
  revenueShare: `0x${string}`
}

export default function Dashboard() {
  const { address, isConnected } = useAccount()
  const chainId = useChainId()
  const { switchChain } = useSwitchChain()

  const [deployedInfo,   setDeployedInfo]   = useState<DeployedInfo | null>(null)
  const [endpointListKey, setEndpointListKey] = useState(0)
  const publicClient = usePublicClient()

  const wrongNetwork = isConnected && chainId !== avalancheFuji.id

  // Look up on-chain if the wallet already deployed a provider
  const handleDeployed = useCallback((info: DeployedInfo) => setDeployedInfo(info), [])

  useEffect(() => {
    if (!address || !publicClient || wrongNetwork) return
    let cancelled = false
    const walletAddress = address

    async function lookupProvider() {
      try {
        // Read providerCount from registry, then check each provider for our address
        const count = await publicClient!.readContract({
          address: REGISTRY,
          abi: registryAbi,
          functionName: 'providerCount',
        }) as bigint

        console.log('[Dashboard] providerCount:', count.toString())

        // Iterate backwards (most recent first) to find our provider
        for (let i = count; i >= 1n; i--) {
          if (cancelled) return
          const provider = await publicClient!.readContract({
            address: REGISTRY,
            abi: registryAbi,
            functionName: 'providers',
            args: [i],
          }) as [string, string, string, string, boolean, bigint]

          const [owner, , , revenueSplitter] = provider

          if (owner.toLowerCase() === walletAddress.toLowerCase()) {
            console.log('[Dashboard] Found provider:', { id: i.toString(), owner, revenueSplitter })
            if (!cancelled) {
              setDeployedInfo({
                providerId:   i,
                vault:        revenueSplitter as `0x${string}`, // vault not available from registry, use splitter as placeholder
                splitter:     revenueSplitter as `0x${string}`,
                revenueShare: ZERO as `0x${string}`,
              })
            }
            return
          }
        }
        console.log('[Dashboard] No provider found for', walletAddress)
      } catch (err) {
        console.error('[Dashboard] Failed to look up provider:', err)
      }
    }

    lookupProvider()
    return () => { cancelled = true }
  }, [address, publicClient, wrongNetwork])

  // Read USDC address from factory
  const { data: usdcAddress, error: usdcError, isLoading: usdcLoading, status: usdcStatus, fetchStatus: usdcFetchStatus } = useReadContract({
    address: FACTORY,
    abi: factoryAbi,
    functionName: 'USDC',
    query: { enabled: isConnected && !wrongNetwork },
  })

  // Read stake info for progress indicator
  const { data: minimumStake = 0n, error: minStakeError } = useReadContract({
    address: REGISTRY,
    abi: registryAbi,
    functionName: 'minimumStakeRequired',
    query: { enabled: isConnected && !wrongNetwork },
  })
  const { data: stakeInfo, error: stakeError } = useReadContract({
    address: STAKE_MANAGER,
    abi: stakeManagerAbi,
    functionName: 'stakes',
    args: [address!],
    query: { enabled: !!address && !wrongNetwork },
  })

  // Debug logging
  console.log('[DEBUG] Contract reads:', {
    isConnected,
    chainId,
    wrongNetwork,
    address,
    FACTORY,
    REGISTRY,
    STAKE_MANAGER,
    RPC_URL: process.env.NEXT_PUBLIC_FUJI_RPC_URL,
    usdcAddress,
    usdcError: usdcError?.message,
    usdcStatus,
    usdcFetchStatus,
    usdcLoading,
    minimumStake,
    minStakeError: minStakeError?.message,
    stakeInfo,
    stakeError: stakeError?.message,
  })
  const staked       = stakeInfo?.[0] ?? 0n
  const stakeMet     = staked >= minimumStake && minimumStake > 0n
  const providerMet  = !!deployedInfo

  return (
    <main className="min-h-screen bg-background">
      {/* Header */}
      <header className="sticky top-0 z-50 w-full border-b bg-background/95 backdrop-blur supports-backdrop-filter:bg-background/60">
        <div className="max-w-4xl mx-auto flex h-14 items-center justify-between px-4 gap-2">
          <div className="flex items-center gap-2 min-w-0">
            <Link href="/" className="flex items-center gap-2 hover:opacity-80 transition-opacity min-w-0">
              <Zap className="h-5 w-5 text-primary shrink-0" />
              <div className="min-w-0">
                <h1 className="text-sm sm:text-base font-bold leading-tight truncate">API Integrity Protocol</h1>
                <p className="text-[10px] sm:text-xs text-muted-foreground truncate">Provider Dashboard · Avalanche Fuji</p>
              </div>
            </Link>
          </div>
          <div className="shrink-0">
            <ConnectButton chainStatus="icon" showBalance={false} />
          </div>
        </div>
      </header>

      <div className="max-w-4xl mx-auto px-3 sm:px-4 py-6 sm:py-8 space-y-4 sm:space-y-6">
        {/* Wrong network banner */}
        {wrongNetwork && (
          <Alert variant="warning">
            <AlertTriangle className="h-4 w-4" />
            <AlertDescription className="flex items-center justify-between">
              <span>Switch to <strong>Avalanche Fuji</strong> to continue.</span>
              <Button
                variant="outline"
                size="sm"
                onClick={() => switchChain({ chainId: avalancheFuji.id })}
              >
                Switch network
              </Button>
            </AlertDescription>
          </Alert>
        )}

        {/* Debug panel – flip DEBUG to true to show */}
        {DEBUG && isConnected && (
          <Card className="border-orange-500/40 bg-orange-500/5">
            <CardHeader className="pb-2">
              <CardTitle className="text-sm font-mono text-orange-400 flex items-center gap-2">
                <AlertTriangle className="h-4 w-4" /> Debug: Contract reads
              </CardTitle>
            </CardHeader>
            <CardContent className="font-mono text-xs space-y-1">
              <p>Chain ID: <span className="text-orange-300">{chainId}</span> (expected: {avalancheFuji.id})</p>
              <p>Wrong network: <span className={wrongNetwork ? 'text-red-400' : 'text-green-400'}>{String(wrongNetwork)}</span></p>
              <p>Wallet: <span className="text-orange-300">{address ?? 'N/A'}</span></p>
              <p>Factory: <span className="text-orange-300">{FACTORY}</span></p>
              <p>Registry: <span className="text-orange-300">{REGISTRY}</span></p>
              <p>RPC URL: <span className="text-orange-300">{RPC_URL}</span></p>
              <hr className="border-orange-500/20 my-2" />
              <p>USDC status: <span className="text-orange-300">{usdcStatus}</span> | fetch: <span className="text-orange-300">{usdcFetchStatus}</span></p>
              <p>USDC address: <span className={usdcAddress ? 'text-green-400' : 'text-red-400'}>{usdcAddress ?? 'undefined'}</span></p>
              {usdcError && <p className="text-red-400">USDC error: {usdcError.message}</p>}
              {minStakeError && <p className="text-red-400">MinStake error: {minStakeError.message}</p>}
              {stakeError && <p className="text-red-400">Stake error: {stakeError.message}</p>}
              <p>MinStake: <span className="text-orange-300">{String(minimumStake)}</span></p>
              <p>Staked: <span className="text-orange-300">{String(stakeInfo?.[0] ?? 'N/A')}</span></p>
            </CardContent>
          </Card>
        )}

        {!isConnected ? (
          <Card className="border-dashed">
            <CardContent className="flex flex-col items-center justify-center py-16 space-y-4">
              <p className="text-muted-foreground text-lg">Connect your wallet to register as an API provider</p>
              <ConnectButton />
            </CardContent>
          </Card>
        ) : (
          <>
            {/* Progress bar */}
            <Card>
              <CardHeader className="pb-3">
                <CardTitle className="text-sm font-medium text-muted-foreground">Registration progress</CardTitle>
              </CardHeader>
              <CardContent>
                <div className="flex flex-col sm:flex-row gap-2">
                  {[
                    { label: 'Stake', done: stakeMet },
                    { label: 'Deploy', done: providerMet },
                    { label: 'Register endpoint', done: false },
                  ].map((step, i) => (
                    <div
                      key={i}
                      className={`flex-1 rounded-md p-2.5 text-center text-xs font-medium transition-colors ${
                        step.done
                          ? 'bg-emerald-500/15 text-emerald-400 border border-emerald-500/25'
                          : 'bg-muted text-muted-foreground'
                      }`}
                    >
                      {step.done ? '✓ ' : `${i + 1}. `}{step.label}
                    </div>
                  ))}
                </div>
              </CardContent>
            </Card>

            {/* Step 1: Stake */}
            <Card>
              <CardHeader>
                <div className="flex items-center gap-3">
                  <div className={`flex h-8 w-8 items-center justify-center rounded-full text-sm font-bold ${
                    stakeMet ? 'bg-emerald-500/15 text-emerald-400' : 'bg-primary text-primary-foreground'
                  }`}>
                    {stakeMet ? <CheckCircle2 className="h-4 w-4" /> : '1'}
                  </div>
                  <div>
                    <CardTitle>Stake USDC</CardTitle>
                    <CardDescription>Meet the minimum stake requirement to register endpoints</CardDescription>
                  </div>
                </div>
              </CardHeader>
              <CardContent>
                {usdcAddress ? (
                  <StakePanel usdcAddress={usdcAddress} />
                ) : (
                  <p className="text-muted-foreground text-sm">Loading contract data…</p>
                )}
              </CardContent>
            </Card>

            {/* Step 2: Deploy provider */}
            <Card>
              <CardHeader>
                <div className="flex items-center gap-3">
                  <div className={`flex h-8 w-8 items-center justify-center rounded-full text-sm font-bold ${
                    providerMet ? 'bg-emerald-500/15 text-emerald-400' : 'bg-primary text-primary-foreground'
                  }`}>
                    {providerMet ? <CheckCircle2 className="h-4 w-4" /> : '2'}
                  </div>
                  <div>
                    <CardTitle>Deploy Provider</CardTitle>
                    <CardDescription>Create your vault, splitter, and register your provider ID</CardDescription>
                  </div>
                </div>
              </CardHeader>
              <CardContent>
                {usdcAddress ? (
                  <DeployProviderPanel
                    usdcAddress={usdcAddress}
                    onDeployed={handleDeployed}
                    initialDeployedInfo={deployedInfo}
                  />
                ) : (
                  <p className="text-muted-foreground text-sm">Loading contract data…</p>
                )}
              </CardContent>
            </Card>

            {/* Step 3: Register endpoint */}
            <Card className={!deployedInfo ? 'opacity-50 pointer-events-none' : ''}>
              <CardHeader>
                <div className="flex items-center gap-3">
                  <div className="flex h-8 w-8 items-center justify-center rounded-full bg-primary text-primary-foreground text-sm font-bold">3</div>
                  <div>
                    <CardTitle>Register Endpoint</CardTitle>
                    <CardDescription>Update your server, compute integrity hash, and register on-chain</CardDescription>
                  </div>
                </div>
              </CardHeader>
              <CardContent>
                {!deployedInfo ? (
                  <p className="text-muted-foreground text-sm">Complete steps 1 and 2 first.</p>
                ) : (
                  <RegisterEndpointPanel
                    providerId={deployedInfo.providerId}
                    splitterAddress={deployedInfo.splitter}
                    onRegistered={() => setEndpointListKey(k => k + 1)}
                  />
                )}
              </CardContent>
            </Card>

            {/* ChallengeManager */}
            <Card>
              <CardHeader>
                <div className="flex items-center gap-3">
                  <div className="flex h-8 w-8 items-center justify-center rounded-full bg-secondary text-secondary-foreground text-sm font-bold">
                    <Shield className="h-4 w-4" />
                  </div>
                  <div>
                    <CardTitle>Challenge Manager</CardTitle>
                    <CardDescription>Open or inspect endpoint challenges</CardDescription>
                  </div>
                </div>
              </CardHeader>
              <CardContent>
                {usdcAddress ? (
                  <ChallengePanel usdcAddress={usdcAddress} />
                ) : (
                  <p className="text-muted-foreground text-sm">Loading…</p>
                )}
              </CardContent>
            </Card>

            {/* All endpoints */}
            <Card>
              <CardHeader>
                <div className="flex items-center justify-between">
                  <div className="flex items-center gap-3">
                    <div className="flex h-8 w-8 items-center justify-center rounded-full bg-secondary text-secondary-foreground text-sm font-bold">
                      <List className="h-4 w-4" />
                    </div>
                    <CardTitle>All registered endpoints</CardTitle>
                  </div>
                  <Button
                    variant="outline"
                    size="sm"
                    onClick={() => setEndpointListKey(k => k + 1)}
                  >
                    <RefreshCw className="mr-2 h-3 w-3" />
                    Refresh
                  </Button>
                </div>
              </CardHeader>
              <CardContent>
                <EndpointList refreshKey={endpointListKey} />
              </CardContent>
            </Card>
          </>
        )}
      </div>
    </main>
  )
}
