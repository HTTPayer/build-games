import { clsx, type ClassValue } from 'clsx'
import { twMerge } from 'tailwind-merge'

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs))
}

export const ZERO = '0x0000000000000000000000000000000000000000' as const

export const FACTORY           = (process.env.NEXT_PUBLIC_FACTORY ?? '0xbDC41cf3E17d5Fa19e41a3fb02c8ACb9B9927E5b') as `0x${string}`
export const REGISTRY          = (process.env.NEXT_PUBLIC_REGISTRY ?? '0xAf2596cCf591831d8aF6b463Dc5760C156C5936A') as `0x${string}`
export const STAKE_MANAGER     = (process.env.NEXT_PUBLIC_STAKE_MANAGER ?? '0x3401eE39d686d6B93a97bD04A244f3BbA1e7Dd69') as `0x${string}`
export const CHALLENGE_MANAGER = (process.env.NEXT_PUBLIC_CHALLENGE_MANAGER ?? '0x60825231973f0e9d441A85021dACA8AaE473A44b') as `0x${string}`
export const DEPLOY_BLOCK      = BigInt(process.env.NEXT_PUBLIC_DEPLOY_BLOCK ?? '52477983')

export const RPC_URL = process.env.NEXT_PUBLIC_FUJI_RPC_URL ?? 'https://api.avax-test.network/ext/bc/C/rpc'

export function formatUsdc(raw: bigint, decimals = 2): string {
  return (Number(raw) / 1e6).toFixed(decimals)
}

export function formatBp(bp: bigint): string {
  return `${(Number(bp) / 100).toFixed(2)}%`
}

export function formatTimestamp(ts: bigint): string {
  return ts === 0n ? 'never' : new Date(Number(ts) * 1000).toLocaleString()
}

export function shortAddr(addr: string): string {
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`
}
