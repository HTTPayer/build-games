import { createConfig, http } from 'wagmi'
import { avalancheFuji } from 'wagmi/chains'
import { injected } from 'wagmi/connectors'
import { RPC_URL } from '@/lib/utils'

export const config = createConfig({
  chains: [avalancheFuji],
  connectors: [injected()],
  transports: {
    [avalancheFuji.id]: http(RPC_URL),
  },
  ssr: true,
})
