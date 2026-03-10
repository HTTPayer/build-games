import { ImageResponse } from 'next/og'

export const runtime = 'edge'
export const alt = 'Composed Protocol — Make API Revenue Investable'
export const size = { width: 1200, height: 630 }
export const contentType = 'image/png'

export default async function TwitterImage() {
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
        {/* Grid overlay */}
        <div
          style={{
            position: 'absolute',
            inset: 0,
            backgroundImage:
              'linear-gradient(rgba(255,255,255,0.03) 1px, transparent 1px), linear-gradient(90deg, rgba(255,255,255,0.03) 1px, transparent 1px)',
            backgroundSize: '60px 60px',
          }}
        />

        {/* Accent glows */}
        <div
          style={{
            position: 'absolute',
            top: '-100px',
            right: '-60px',
            width: '450px',
            height: '450px',
            borderRadius: '50%',
            background: 'radial-gradient(circle, rgba(168,85,247,0.18), transparent 70%)',
          }}
        />
        <div
          style={{
            position: 'absolute',
            bottom: '-80px',
            left: '-40px',
            width: '350px',
            height: '350px',
            borderRadius: '50%',
            background: 'radial-gradient(circle, rgba(59,130,246,0.12), transparent 70%)',
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
            marginBottom: '28px',
          }}
        >
          <div style={{ width: '8px', height: '8px', borderRadius: '50%', background: '#34d399' }} />
          <span style={{ color: 'rgba(255,255,255,0.6)', fontSize: '15px', fontWeight: 500 }}>
            Built on Avalanche · by HTTPayer
          </span>
        </div>

        {/* Icon */}
        <div
          style={{
            width: '52px',
            height: '52px',
            borderRadius: '14px',
            background: 'rgba(168,85,247,0.15)',
            border: '1px solid rgba(168,85,247,0.3)',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            fontSize: '26px',
            marginBottom: '20px',
          }}
        >
          ⬡
        </div>

        {/* Title */}
        <h1
          style={{
            fontSize: '58px',
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
            fontSize: '58px',
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
            fontSize: '20px',
            color: 'rgba(255,255,255,0.5)',
            textAlign: 'center',
            maxWidth: '650px',
            lineHeight: 1.5,
            marginTop: '20px',
          }}
        >
          Tokenized API revenue · Onchain enforcement · Chainlink verified
        </p>

        {/* Bottom */}
        <div
          style={{
            position: 'absolute',
            bottom: '30px',
            display: 'flex',
            alignItems: 'center',
            gap: '10px',
          }}
        >
          <span style={{ color: 'rgba(255,255,255,0.35)', fontSize: '15px', fontWeight: 600 }}>
            composed.httpayer.com
          </span>
        </div>
      </div>
    ),
    { ...size }
  )
}
