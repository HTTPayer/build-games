'use client'

import Link from 'next/link'
import Script from 'next/script'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Card, CardContent } from '@/components/ui/card'
import { motion } from 'framer-motion'
import {
  Hexagon,
  Eye,
  TrendingUp,
  Shield,
  Layers,
  ArrowRight,
  ExternalLink,
  CircleDollarSign,
  Bot,
  Lock,
  BarChart3,
  Globe,
  Coins,
  Workflow,
} from 'lucide-react'

/* ── Animations ─────────────────────────────────────────────── */

const fadeUp = {
  hidden: { opacity: 0, y: 30 },
  visible: (i: number) => ({
    opacity: 1,
    y: 0,
    transition: { delay: i * 0.1, duration: 0.6, ease: [0.25, 0.4, 0.25, 1] as const },
  }),
}

const stagger = {
  visible: { transition: { staggerChildren: 0.08 } },
}

/* ── Page ────────────────────────────────────────────────────── */

export default function LandingPage() {
  const jsonLd = {
    '@context': 'https://schema.org',
    '@type': 'SoftwareApplication',
    name: 'Composed Protocol',
    applicationCategory: 'FinanceApplication',
    operatingSystem: 'Web',
    url: 'https://composed.httpayer.com',
    description:
      'Onchain enforcement turns every API payment into a verifiable, tokenized financial instrument. Stake, tokenize, and invest in API revenue on Avalanche.',
    offers: {
      '@type': 'Offer',
      price: '0',
      priceCurrency: 'USD',
    },
    creator: {
      '@type': 'Organization',
      name: 'HTTPayer',
      url: 'https://httpayer.com',
    },
  }

  return (
    <main className="min-h-screen bg-background text-foreground overflow-hidden">
      <Script
        id="structured-data"
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }}
      />
      {/* ─── Nav ─────────────────────────────────────────────── */}
      <header className="sticky top-0 z-50 w-full border-b border-white/[0.06] bg-background/60 backdrop-blur-xl">
        <div className="mx-auto flex h-14 max-w-6xl items-center justify-between px-6">
          <div className="flex items-center gap-2.5">
            <div className="relative h-8 w-8 rounded-lg bg-primary/15 flex items-center justify-center border border-primary/20">
              <Hexagon className="h-4 w-4 text-primary" />
              <div className="absolute inset-0 rounded-lg bg-primary/10 blur-sm" />
            </div>
            <span className="font-semibold text-sm tracking-tight">
              Composed Protocol{' '}
              <a
                href="https://httpayer.com"
                target="_blank"
                rel="noopener noreferrer"
                className="text-muted-foreground hover:text-primary transition-colors"
              >
                by HTTPayer
              </a>
            </span>
          </div>
          <div className="flex items-center gap-4">
            <a
              href="https://github.com"
              target="_blank"
              rel="noopener noreferrer"
              className="text-xs text-muted-foreground hover:text-foreground transition-colors hidden sm:block"
            >
              Docs
            </a>
            <Link href="/dashboard">
              <Button size="sm" className="rounded-full px-5 glow-button">
                Launch App
              </Button>
            </Link>
          </div>
        </div>
      </header>

      {/* ─── Hero ────────────────────────────────────────────── */}
      <section className="relative min-h-[92vh] flex items-center justify-center">
        {/* 3D Perspective grid */}
        <div className="grid-3d-wrapper">
          <div className="grid-3d" />
        </div>

        {/* Subtle glow behind grid */}
        <div className="absolute top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 w-[600px] h-[400px] rounded-full bg-primary/[0.06] blur-[120px] pointer-events-none" />

        {/* Edges fade */}
        <div className="absolute inset-0 bg-[radial-gradient(ellipse_85%_75%_at_50%_50%,transparent_0%,hsl(var(--background))_80%)]" />
        <div className="absolute bottom-0 left-0 right-0 h-40 bg-gradient-to-t from-background to-transparent" />

        <div className="relative w-full max-w-4xl mx-auto px-6 text-center flex flex-col items-center">
          {/* Badge */}
          <motion.div
            initial={{ opacity: 0, y: -10 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.5 }}
          >
            <Badge
              variant="outline"
              className="hero-badge rounded-full px-4 py-1.5 text-xs font-medium mb-8"
            >
              <span className="inline-block h-1.5 w-1.5 rounded-full bg-emerald-400 mr-2 animate-pulse" />
              Live on Avalanche Fuji Testnet
            </Badge>
          </motion.div>

          {/* Title */}
          <motion.h1
            className="text-4xl sm:text-6xl lg:text-7xl font-bold tracking-tight leading-[1.08] text-center"
            initial={{ opacity: 0, y: 40 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.7, delay: 0.1 }}
          >
            Make API Revenue
            <br />
            <span className="hero-gradient-text">Investable</span>
          </motion.h1>

          {/* Subtitle */}
          <motion.p
            className="text-muted-foreground text-base sm:text-lg lg:text-xl max-w-xl mx-auto leading-relaxed mt-6 text-center"
            initial={{ opacity: 0, y: 30 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.6, delay: 0.25 }}
          >
            Onchain enforcement turns every API payment into a verifiable,
            tokenized financial instrument. No trust required.
          </motion.p>

          {/* CTAs */}
          <motion.div
            className="flex flex-col sm:flex-row items-center justify-center gap-3 sm:gap-4 mt-10"
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.5, delay: 0.4 }}
          >
            <Link href="/dashboard">
              <Button size="lg" className="rounded-full px-8 h-12 text-sm font-medium gap-2 glow-button w-full sm:w-auto">
                Launch App <ArrowRight className="h-4 w-4" />
              </Button>
            </Link>
            <a href="#what">
              <Button variant="outline" size="lg" className="rounded-full px-8 h-12 text-sm font-medium border-white/[0.1] bg-white/[0.02] hover:bg-white/[0.06] w-full sm:w-auto">
                Learn more
              </Button>
            </a>
          </motion.div>

          {/* Tech pills */}
          <motion.div
            className="flex flex-wrap items-center justify-center gap-2 sm:gap-3 mt-10"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            transition={{ duration: 0.6, delay: 0.55 }}
          >
            {['x402 Payments', 'Chainlink CRE', 'ERC 4626', 'USDC', 'Avalanche'].map((t) => (
              <span
                key={t}
                className="hero-pill px-3 py-1 rounded-full text-[11px] font-mono text-foreground/50 border border-white/[0.12] bg-white/[0.04]"
              >
                {t}
              </span>
            ))}
          </motion.div>
        </div>
      </section>

      {/* ─── What is this? ───────────────────────────────────── */}
      <section id="what" className="relative py-24 sm:py-32">
        <div className="mx-auto max-w-6xl px-6">
          <motion.div
            className="text-center space-y-4 mb-16 sm:mb-20"
            initial="hidden"
            whileInView="visible"
            viewport={{ once: true, margin: '-100px' }}
            variants={stagger}
          >
            <motion.div variants={fadeUp} custom={0}>
              <Badge variant="outline" className="section-badge mx-auto">The Idea</Badge>
            </motion.div>
            <motion.h2 variants={fadeUp} custom={1} className="text-3xl sm:text-5xl font-bold tracking-tight text-center">
              APIs make money.{' '}
              <span className="hero-gradient-text">Now you can invest in them.</span>
            </motion.h2>
            <motion.p variants={fadeUp} custom={2} className="text-muted-foreground text-base sm:text-lg max-w-2xl mx-auto text-center">
              AI agents already pay for API calls with crypto. We take that revenue
              stream and turn it into financial assets anyone can buy, hold, and trade.
            </motion.p>
          </motion.div>

          <motion.div
            className="grid gap-4 sm:gap-6 grid-cols-1 sm:grid-cols-2 lg:grid-cols-4"
            initial="hidden"
            whileInView="visible"
            viewport={{ once: true, margin: '-80px' }}
            variants={stagger}
          >
            {[
              {
                icon: Bot,
                title: 'AI agents pay for APIs',
                desc: 'Machines use the x402 protocol to pay per call in USDC. No human needed.',
              },
              {
                icon: CircleDollarSign,
                title: 'Revenue flows onchain',
                desc: 'Every payment is visible, verifiable, and programmable on Avalanche.',
              },
              {
                icon: Lock,
                title: 'Oracles keep it honest',
                desc: 'Chainlink nodes verify every endpoint. Cheaters get slashed automatically.',
              },
              {
                icon: BarChart3,
                title: 'You invest in revenue',
                desc: 'Buy vault shares or royalty tokens. Earn as the API earns.',
              },
            ].map(({ icon: Icon, title, desc }, i) => (
              <motion.div key={title} variants={fadeUp} custom={i}>
                <Card className="feature-card group relative h-full overflow-hidden border-white/[0.06] bg-white/[0.02] transition-all duration-500">
                  <div className="absolute inset-0 opacity-0 group-hover:opacity-100 transition-opacity duration-500 bg-gradient-to-br from-white/[0.03] to-transparent" />
                  <CardContent className="relative p-5 sm:p-6 space-y-4">
                    <Icon className="h-5 w-5 text-muted-foreground group-hover:text-foreground transition-colors duration-300" />
                    <h3 className="font-semibold text-[15px]">{title}</h3>
                    <p className="text-sm text-muted-foreground leading-relaxed">{desc}</p>
                  </CardContent>
                </Card>
              </motion.div>
            ))}
          </motion.div>
        </div>
      </section>

      {/* ─── The Business ────────────────────────────────────── */}
      <section className="relative py-24 sm:py-32 border-t border-white/[0.04]">
        <div className="mx-auto max-w-5xl px-6">
          <motion.div
            className="text-center space-y-4 mb-16"
            initial="hidden"
            whileInView="visible"
            viewport={{ once: true, margin: '-100px' }}
            variants={stagger}
          >
            <motion.div variants={fadeUp} custom={0}>
              <Badge variant="outline" className="section-badge mx-auto">The Business</Badge>
            </motion.div>
            <motion.h2 variants={fadeUp} custom={1} className="text-3xl sm:text-4xl font-bold tracking-tight text-center">
              A new asset class, powered by code
            </motion.h2>
            <motion.p variants={fadeUp} custom={2} className="text-muted-foreground text-base sm:text-lg max-w-2xl mx-auto text-center">
              Every SaaS company runs on API revenue. Until now, there was no way
              to invest in that cash flow directly. Composed changes that.
            </motion.p>
          </motion.div>

          <motion.div
            className="grid gap-4 sm:gap-6 grid-cols-1 md:grid-cols-3"
            initial="hidden"
            whileInView="visible"
            viewport={{ once: true, margin: '-60px' }}
            variants={stagger}
          >
            {[
              {
                icon: Globe,
                title: 'For API Providers',
                desc: 'Monetize your API instantly. Stake, register, and let the protocol handle payments, verification, and tokenization.',
                tag: 'Earn',
              },
              {
                icon: Coins,
                title: 'For Investors',
                desc: 'Buy vault shares or royalty tokens tied to real API revenue. Transparent, liquid, and verifiable onchain.',
                tag: 'Invest',
              },
              {
                icon: Workflow,
                title: 'For DeFi Builders',
                desc: 'Use tokenized API revenue as collateral for stablecoins, futures, indexes, and more. Composable by design.',
                tag: 'Build',
              },
            ].map(({ icon: Icon, title, desc, tag }, i) => (
              <motion.div key={title} variants={fadeUp} custom={i}>
                <Card className="feature-card group relative h-full overflow-hidden border-white/[0.06] bg-white/[0.02] transition-all duration-500">
                  <div className="absolute inset-0 opacity-0 group-hover:opacity-100 transition-opacity duration-700 bg-gradient-to-br from-white/[0.04] to-transparent" />
                  <CardContent className="relative p-5 sm:p-6 space-y-4">
                    <div className="flex items-center justify-between">
                      <Icon className="h-5 w-5 text-muted-foreground group-hover:text-foreground transition-colors duration-300" />
                      <span className="text-[10px] font-bold uppercase tracking-widest text-muted-foreground/40 group-hover:text-muted-foreground/60 transition-colors">
                        {tag}
                      </span>
                    </div>
                    <h3 className="font-semibold text-base">{title}</h3>
                    <p className="text-sm text-muted-foreground leading-relaxed">{desc}</p>
                  </CardContent>
                </Card>
              </motion.div>
            ))}
          </motion.div>

          {/* Stat strip */}
          <motion.div
            className="mt-12 sm:mt-16 grid grid-cols-2 sm:grid-cols-4 gap-4"
            initial="hidden"
            whileInView="visible"
            viewport={{ once: true, margin: '-40px' }}
            variants={stagger}
          >
            {[
              { value: '$0.01', label: 'per API call' },
              { value: 'USDC', label: 'settlement' },
              { value: 'ERC 4626', label: 'vault standard' },
              { value: '< 2s', label: 'finality' },
            ].map(({ value, label }, i) => (
              <motion.div
                key={label}
                variants={fadeUp}
                custom={i}
                className="stat-card text-center p-4 sm:p-5 rounded-2xl border border-white/[0.06] bg-white/[0.02]"
              >
                <p className="text-xl sm:text-2xl font-bold tracking-tight">{value}</p>
                <p className="text-[11px] sm:text-xs text-muted-foreground/60 mt-1 uppercase tracking-wider font-medium">{label}</p>
              </motion.div>
            ))}
          </motion.div>
        </div>
      </section>

      {/* ─── Before vs After ─────────────────────────────────── */}
      <section className="relative py-24 sm:py-32 border-t border-white/[0.04]">
        <div className="mx-auto max-w-5xl px-6">
          <motion.div
            className="text-center space-y-4 mb-16"
            initial="hidden"
            whileInView="visible"
            viewport={{ once: true, margin: '-100px' }}
            variants={stagger}
          >
            <motion.div variants={fadeUp} custom={0}>
              <Badge variant="outline" className="section-badge mx-auto">Before vs After</Badge>
            </motion.div>
            <motion.h2 variants={fadeUp} custom={1} className="text-3xl sm:text-4xl font-bold tracking-tight text-center">
              What changes with this protocol
            </motion.h2>
          </motion.div>

          <motion.div
            className="grid gap-4 sm:gap-5 grid-cols-1 sm:grid-cols-3"
            initial="hidden"
            whileInView="visible"
            viewport={{ once: true, margin: '-60px' }}
            variants={stagger}
          >
            {[
              {
                icon: Eye,
                title: 'Transparent',
                before: 'Revenue trapped inside companies',
                after: 'Every payment visible onchain',
              },
              {
                icon: TrendingUp,
                title: 'Investable',
                before: 'No way to invest in an API',
                after: 'Tokenized shares you can trade',
              },
              {
                icon: Shield,
                title: 'Enforced',
                before: 'Trust reported numbers',
                after: 'Oracles verify every payment',
              },
            ].map(({ icon: Icon, title, before, after }, i) => (
              <motion.div key={title} variants={fadeUp} custom={i}>
                <Card className="feature-card group relative h-full overflow-hidden border-white/[0.06] bg-white/[0.02] transition-all duration-500">
                  <div className="absolute inset-0 opacity-0 group-hover:opacity-100 transition-opacity duration-500 bg-gradient-to-br from-white/[0.03] to-transparent" />
                  <CardContent className="relative p-5 sm:p-6 space-y-5">
                    <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-primary/10 text-primary group-hover:bg-primary/20 group-hover:scale-110 transition-all duration-300">
                      <Icon className="h-5 w-5" />
                    </div>
                    <h3 className="font-semibold text-lg">{title}</h3>
                    <div className="space-y-3 text-sm">
                      <div className="flex items-start gap-3">
                        <span className="mt-1.5 block h-2 w-2 rounded-full bg-red-400/50 shrink-0 ring-2 ring-red-400/10" />
                        <p className="text-muted-foreground/70">{before}</p>
                      </div>
                      <div className="flex items-start gap-3">
                        <span className="mt-1.5 block h-2 w-2 rounded-full bg-emerald-400 shrink-0 ring-2 ring-emerald-400/20" />
                        <p className="text-foreground">{after}</p>
                      </div>
                    </div>
                  </CardContent>
                </Card>
              </motion.div>
            ))}
          </motion.div>
        </div>
      </section>

      {/* ─── Architecture ────────────────────────────────────── */}
      <section id="how-it-works" className="relative py-24 sm:py-32 border-t border-white/[0.04]">
        <div className="absolute top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 w-[500px] h-[500px] rounded-full bg-primary/4 blur-[120px] pointer-events-none" />

        <div className="relative mx-auto max-w-3xl px-6 space-y-16">
          <motion.div
            className="text-center space-y-4"
            initial="hidden"
            whileInView="visible"
            viewport={{ once: true, margin: '-100px' }}
            variants={stagger}
          >
            <motion.div variants={fadeUp} custom={0}>
              <Badge variant="outline" className="section-badge mx-auto">Architecture</Badge>
            </motion.div>
            <motion.h2 variants={fadeUp} custom={1} className="text-3xl sm:text-4xl font-bold tracking-tight text-center">
              Three layers, one protocol
            </motion.h2>
            <motion.p variants={fadeUp} custom={2} className="text-muted-foreground max-w-lg mx-auto text-center">
              Each layer is independent. Adopt only what you need.
            </motion.p>
          </motion.div>

          <motion.div
            className="space-y-4"
            initial="hidden"
            whileInView="visible"
            viewport={{ once: true, margin: '-40px' }}
            variants={stagger}
          >
            {[
              {
                layer: '0',
                label: 'Enforce',
                color: 'emerald',
                desc: 'Providers stake USDC. Anyone can challenge. Chainlink oracles verify payment integrity. Invalid providers get slashed.',
              },
              {
                layer: '1',
                label: 'Tokenize',
                color: 'blue',
                desc: 'Revenue flows into ERC 4626 vaults (price goes up) and royalty tokens (USDC dividends). Invest in any API.',
              },
              {
                layer: '2',
                label: 'Compose',
                color: 'violet',
                desc: 'Vault shares become DeFi primitives. Stablecoins, futures, indexes, and CDPs backed by real API cash flow.',
              },
            ].map(({ layer, label, color, desc }, i) => (
              <motion.div key={layer} variants={fadeUp} custom={i}>
                <Card className={`feature-card group border-white/[0.06] bg-white/[0.02] transition-all duration-500 layer-card-${color}`}>
                  <CardContent className="p-5 sm:p-6 flex items-start gap-4 sm:gap-5">
                    <div className="flex flex-col items-center gap-1.5 pt-0.5 shrink-0">
                      <div className={`h-10 w-10 rounded-xl flex items-center justify-center layer-icon-${color} group-hover:scale-110 transition-transform duration-300`}>
                        <Layers className="h-4.5 w-4.5" />
                      </div>
                      <span className={`text-[10px] font-bold uppercase tracking-widest layer-text-${color}`}>
                        L{layer}
                      </span>
                    </div>
                    <div className="space-y-1.5 min-w-0">
                      <h3 className={`font-semibold text-lg layer-text-${color}`}>{label}</h3>
                      <p className="text-sm text-muted-foreground leading-relaxed">{desc}</p>
                    </div>
                  </CardContent>
                </Card>
              </motion.div>
            ))}
          </motion.div>
        </div>
      </section>

      {/* ─── CTA ─────────────────────────────────────────────── */}
      <section className="relative py-24 sm:py-32 border-t border-white/[0.04]">
        <div className="absolute inset-0 bg-[radial-gradient(ellipse_at_bottom,hsl(var(--primary)/0.04),transparent_60%)]" />

        <motion.div
          className="relative mx-auto max-w-3xl px-6 text-center flex flex-col items-center"
          initial="hidden"
          whileInView="visible"
          viewport={{ once: true, margin: '-80px' }}
          variants={stagger}
        >
          <motion.h2 variants={fadeUp} custom={0} className="text-3xl sm:text-5xl font-bold tracking-tight text-center">
            Start building now
          </motion.h2>
          <motion.p variants={fadeUp} custom={1} className="text-muted-foreground text-base sm:text-lg max-w-md mx-auto mt-6 text-center">
            Register as a provider, stake USDC, and tokenize your API revenue
            on Avalanche Fuji.
          </motion.p>

          <motion.div variants={fadeUp} custom={2} className="flex flex-col sm:flex-row items-center justify-center gap-3 sm:gap-4 mt-10">
            <Link href="/dashboard">
              <Button size="lg" className="rounded-full px-8 h-12 text-sm font-medium gap-2 glow-button">
                Launch App <ArrowRight className="h-4 w-4" />
              </Button>
            </Link>
            <a
              href="https://github.com"
              target="_blank"
              rel="noopener noreferrer"
            >
              <Button variant="outline" size="lg" className="rounded-full px-8 h-12 text-sm font-medium border-white/[0.1] bg-white/[0.02] hover:bg-white/[0.06] gap-2">
                GitHub <ExternalLink className="h-3.5 w-3.5" />
              </Button>
            </a>
          </motion.div>

          <motion.div variants={fadeUp} custom={3} className="pt-12 space-y-3">
            <p className="text-xs text-muted-foreground/50 font-mono">
              Deployed on Avalanche Fuji (43113)
            </p>
            <div className="flex flex-wrap justify-center gap-x-6 gap-y-1.5 text-[11px] font-mono text-muted-foreground/40">
              <span>Registry 0xaF25...936A</span>
              <span>Stake 0x3401...Dd69</span>
              <span>Challenge 0x6082...A44b</span>
            </div>
          </motion.div>
        </motion.div>
      </section>

      {/* ─── Footer ──────────────────────────────────────────── */}
      <footer className="border-t border-white/[0.04]">
        <div className="mx-auto max-w-6xl px-6 py-6 flex flex-col sm:flex-row items-center justify-between gap-3 text-xs text-muted-foreground/50">
          <div className="flex items-center gap-2.5">
            <div className="relative h-6 w-6 rounded-md bg-primary/15 flex items-center justify-center border border-primary/20">
              <Hexagon className="h-3 w-3 text-primary" />
            </div>
            <span>Composed Protocol <span className="text-muted-foreground/30">· HTTPayer</span></span>
          </div>
          <span>Avalanche Build Games 2026</span>
        </div>
      </footer>
    </main>
  )
}
