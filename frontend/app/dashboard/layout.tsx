import type { Metadata } from 'next'

export const metadata: Metadata = {
  title: 'Dashboard — Stake, Deploy & Manage Your API',
  description:
    'Manage your API provider status on Composed Protocol. Stake USDC, deploy revenue vaults, register endpoints, and monitor challenges on Avalanche Fuji.',
  openGraph: {
    title: 'Dashboard | Composed Protocol',
    description:
      'Stake USDC, deploy ERC 4626 vaults, register API endpoints, and invest in tokenized API revenue.',
    url: 'https://composed.httpayer.com/dashboard',
  },
  twitter: {
    title: 'Dashboard | Composed Protocol',
    description:
      'Stake USDC, deploy ERC 4626 vaults, register API endpoints, and invest in tokenized API revenue.',
  },
  alternates: {
    canonical: 'https://composed.httpayer.com/dashboard',
  },
}

export default function DashboardLayout({ children }: { children: React.ReactNode }) {
  return children
}
