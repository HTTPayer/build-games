import { ImageResponse } from 'next/og'

export const runtime = 'edge'
export const alt = 'Composed Protocol — Make API Revenue Investable'
export const size = { width: 1200, height: 630 }
export const contentType = 'image/png'

export default async function OGImage() {
  return new ImageResponse(
    (
      <div
        style={{
          width: '100%',
          height: '100%',
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          justifyContent: 'center',
          background: 'linear-gradient(135deg, #0a0a0a 0%, #111111 40%, #0a0a0a 100%)',
          fontFamily: 'Inter, system-ui, sans-serif',
          position: 'relative',
          overflow: 'hidden',
        }}
      >
        {/* Grid pattern overlay */}
        <div
          style={{
            position: 'absolute',
            inset: 0,
            backgroundImage:
              'linear-gradient(rgba(255,255,255,0.03) 1px, transparent 1px), linear-gradient(90deg, rgba(255,255,255,0.03) 1px, transparent 1px)',
            backgroundSize: '60px 60px',
          }}
        />

        {/* Gradient accent */}
        <div
          style={{
            position: 'absolute',
            top: '-120px',
            right: '-80px',
            width: '500px',
            height: '500px',
            borderRadius: '50%',
            background: 'radial-gradient(circle, rgba(168,85,247,0.15), transparent 70%)',
          }}
        />
        <div
          style={{
            position: 'absolute',
            bottom: '-100px',
            left: '-60px',
            width: '400px',
            height: '400px',
            borderRadius: '50%',
            background: 'radial-gradient(circle, rgba(59,130,246,0.1), transparent 70%)',
          }}
        />

        {/* Badge */}
        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: '8px',
            padding: '8px 20px',
            borderRadius: '100px',
            border: '1px solid rgba(255,255,255,0.1)',
            background: 'rgba(255,255,255,0.05)',
            marginBottom: '32px',
          }}
        >
          <div
            style={{
              width: '8px',
              height: '8px',
              borderRadius: '50%',
              background: '#34d399',
            }}
          />
          <span style={{ color: 'rgba(255,255,255,0.6)', fontSize: '16px', fontWeight: 500 }}>
            Live on Avalanche
          </span>
        </div>

        {/* Logo / Icon */}
        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            gap: '16px',
            marginBottom: '24px',
          }}
        >
          <div
            style={{
              width: '56px',
              height: '56px',
              borderRadius: '16px',
              background: 'rgba(168,85,247,0.15)',
              border: '1px solid rgba(168,85,247,0.3)',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              fontSize: '28px',
            }}
          >
            ⬡
          </div>
        </div>

        {/* Title */}
        <h1
          style={{
            fontSize: '64px',
            fontWeight: 700,
            color: '#ffffff',
            lineHeight: 1.1,
            textAlign: 'center',
            margin: 0,
            letterSpacing: '-2px',
          }}
        >
          Make API Revenue
        </h1>
        <h1
          style={{
            fontSize: '64px',
            fontWeight: 700,
            lineHeight: 1.1,
            textAlign: 'center',
            margin: 0,
            letterSpacing: '-2px',
            background: 'linear-gradient(135deg, #a855f7, #6366f1, #3b82f6)',
            backgroundClip: 'text',
            color: 'transparent',
          }}
        >
          Investable
        </h1>

        {/* Subtitle */}
        <p
          style={{
            fontSize: '22px',
            color: 'rgba(255,255,255,0.5)',
            textAlign: 'center',
            maxWidth: '700px',
            lineHeight: 1.5,
            marginTop: '24px',
          }}
        >
          Onchain enforcement turns every API payment into a verifiable, tokenized financial instrument.
        </p>

        {/* Tech pills */}
        <div
          style={{
            display: 'flex',
            gap: '12px',
            marginTop: '36px',
          }}
        >
          {['x402', 'Chainlink CRE', 'ERC 4626', 'USDC', 'Avalanche'].map((t) => (
            <div
              key={t}
              style={{
                padding: '6px 16px',
                borderRadius: '100px',
                border: '1px solid rgba(255,255,255,0.1)',
                background: 'rgba(255,255,255,0.04)',
                color: 'rgba(255,255,255,0.45)',
                fontSize: '13px',
                fontFamily: 'monospace',
              }}
            >
              {t}
            </div>
          ))}
        </div>

        {/* Bottom bar */}
        <div
          style={{
            position: 'absolute',
            bottom: '32px',
            display: 'flex',
            alignItems: 'center',
            gap: '12px',
          }}
        >
          <span style={{ color: 'rgba(255,255,255,0.35)', fontSize: '16px', fontWeight: 600 }}>
            Composed Protocol
          </span>
          <span style={{ color: 'rgba(255,255,255,0.15)', fontSize: '16px' }}>·</span>
          <span style={{ color: 'rgba(255,255,255,0.25)', fontSize: '15px' }}>
            composed.httpayer.com
          </span>
        </div>
      </div>
    ),
    { ...size }
  )
}
