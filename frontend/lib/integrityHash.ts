import { sha256 } from '@noble/hashes/sha256'

export type X402PaymentData = {
  accepts: Array<{
    amount:  string | number
    asset:   string
    network: string
    payTo:   string
  }>
  resource?: { url?: string }
  url?: string
}

export function computeIntegrityHash(paymentData: X402PaymentData): `0x${string}` {
  const entry = paymentData.accepts[0]

  const metadata: Record<string, string> = {
    amount:  String(entry.amount),
    asset:   String(entry.asset),
    network: String(entry.network),
    payTo:   String(entry.payTo).toLowerCase(),
    url:     String(paymentData.resource?.url ?? paymentData.url ?? ''),
  }

  // Sort keys alphabetically, stringify with no spaces
  const sorted     = Object.fromEntries(Object.keys(metadata).sort().map(k => [k, metadata[k]]))
  const dataString = JSON.stringify(sorted)

  const hashBytes = sha256(new TextEncoder().encode(dataString))
  return ('0x' + Array.from(hashBytes).map(b => b.toString(16).padStart(2, '0')).join('')) as `0x${string}`
}

export async function fetchPaymentData(endpointUrl: string): Promise<X402PaymentData> {
  const resp = await fetch(endpointUrl, { headers: { Accept: 'application/json' } })

  const paymentHeader = resp.headers.get('payment-required')
  if (paymentHeader) {
    return JSON.parse(atob(paymentHeader)) as X402PaymentData
  }
  return resp.json() as Promise<X402PaymentData>
}

export async function fetchIntegrityHashDirect(endpointUrl: string): Promise<`0x${string}`> {
  const paymentData = await fetchPaymentData(endpointUrl)
  return computeIntegrityHash(paymentData)
}

export async function fetchIntegrityHash(endpointUrl: string): Promise<`0x${string}`> {
  try {
    return await fetchIntegrityHashDirect(endpointUrl)
  } catch {
    const res = await fetch(`/api/verify-hash?url=${encodeURIComponent(endpointUrl)}`)
    if (!res.ok) throw new Error(await res.text())
    const { hash } = await res.json()
    return hash as `0x${string}`
  }
}
