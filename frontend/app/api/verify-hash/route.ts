import { NextRequest, NextResponse } from 'next/server'
import { fetchPaymentData, computeIntegrityHash } from '@/lib/integrityHash'

export async function GET(req: NextRequest) {
  const url = req.nextUrl.searchParams.get('url')
  if (!url) return NextResponse.json({ error: 'missing url' }, { status: 400 })

  try {
    const paymentData = await fetchPaymentData(url)
    const hash        = computeIntegrityHash(paymentData)
    return NextResponse.json({ hash })
  } catch (err: unknown) {
    const message = err instanceof Error ? err.message : String(err)
    return NextResponse.json({ error: message }, { status: 500 })
  }
}
