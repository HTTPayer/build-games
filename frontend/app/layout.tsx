import type { Metadata, Viewport } from 'next'
import { Inter } from 'next/font/google'
import { Providers } from './providers'
import './globals.css'

const inter = Inter({ subsets: ['latin'] })

const SITE_URL = 'https://composed.httpayer.com'
const SITE_NAME = 'Composed Protocol'
const SITE_TITLE = 'Composed Protocol by HTTPayer — Make API Revenue Investable'
const SITE_DESCRIPTION =
  'Onchain enforcement turns every API payment into a verifiable, tokenized financial instrument. Stake, tokenize, and invest in API revenue on Avalanche.'

export const metadata: Metadata = {
  metadataBase: new URL(SITE_URL),
  title: {
    default: SITE_TITLE,
    template: '%s | Composed Protocol',
  },
  description: SITE_DESCRIPTION,
  applicationName: SITE_NAME,
  authors: [{ name: 'HTTPayer', url: 'https://httpayer.com' }],
  generator: 'Next.js',
  keywords: [
    'API revenue',
    'tokenized finance',
    'DeFi',
    'Avalanche',
    'ERC 4626',
    'USDC',
    'x402 payments',
    'Chainlink',
    'API monetization',
    'onchain payments',
    'vault shares',
    'royalty tokens',
    'AI agents',
    'crypto API',
    'Composed Protocol',
    'HTTPayer',
  ],
  creator: 'HTTPayer',
  publisher: 'HTTPayer',
  robots: {
    index: true,
    follow: true,
    googleBot: {
      index: true,
      follow: true,
      'max-video-preview': -1,
      'max-image-preview': 'large',
      'max-snippet': -1,
    },
  },
  alternates: {
    canonical: SITE_URL,
  },
  openGraph: {
    type: 'website',
    locale: 'en_US',
    url: SITE_URL,
    siteName: SITE_NAME,
    title: SITE_TITLE,
    description: SITE_DESCRIPTION,
    images: [
      {
        url: '/opengraph-image',
        width: 1200,
        height: 630,
        alt: 'Composed Protocol — Make API Revenue Investable',
        type: 'image/png',
      },
    ],
  },
  twitter: {
    card: 'summary_large_image',
    title: SITE_TITLE,
    description: SITE_DESCRIPTION,
    images: ['/twitter-image'],
    creator: '@HTTPayer',
    site: '@HTTPayer',
  },
  manifest: '/manifest.json',
  icons: {
    icon: '/icon',
    apple: '/icon',
  },
  category: 'finance',
}

export const viewport: Viewport = {
  themeColor: [
    { media: '(prefers-color-scheme: dark)', color: '#0a0a0a' },
    { media: '(prefers-color-scheme: light)', color: '#ffffff' },
  ],
  width: 'device-width',
  initialScale: 1,
  maximumScale: 5,
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className="dark">
      <head>
        <link rel="canonical" href={SITE_URL} />
        <meta name="theme-color" content="#0a0a0a" />
      </head>
      <body className={inter.className}>
        <Providers>{children}</Providers>
      </body>
    </html>
  )
}
