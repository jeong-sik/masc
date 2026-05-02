import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import * as Y from 'yjs'
import { WebsocketProvider } from 'y-websocket'
import { runningUnderVitest } from '../lib/test-env'

interface KeeperState {
  id: string
  name: string
  state: 'active' | 'paused'
  energy: number
  position: number
}

interface Trace {
  id: string
  author: string
  position: number
}

type YjsLocation = Pick<Location, 'host' | 'protocol'>

export function resolveYjsWebsocketUrl(
  configuredUrl: string | undefined,
  dev: boolean,
  location: YjsLocation | null,
): string | null {
  const configured = configuredUrl?.trim()
  if (configured) return configured
  if (!dev || !location?.host) return null
  const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:'
  return `${protocol}//${location.host}/yjs`
}

function yjsWebsocketUrl(): string | null {
  if (runningUnderVitest()) return null
  const location = typeof window === 'undefined' ? null : window.location
  return resolveYjsWebsocketUrl(
    import.meta.env?.VITE_MASC_YJS_WS_URL,
    import.meta.env?.DEV === true,
    location,
  )
}

/** Cached CSS custom property resolver for Canvas 2D. Invalidated on theme change. */
const cssVarCache = new Map<string, string>()

function cssVar(prop: string): string {
  if (typeof window === 'undefined' || typeof document === 'undefined') return 'CanvasText'
  const cached = cssVarCache.get(prop)
  if (cached !== undefined) return cached
  const value = getComputedStyle(document.documentElement).getPropertyValue(prop).trim()
  if (!value) {
    console.warn(`WorldVisualizer missing CSS token ${prop}; using CanvasText fallback`)
    cssVarCache.set(prop, 'CanvasText')
    return 'CanvasText'
  }
  cssVarCache.set(prop, value)
  return value
}

export function WorldVisualizer() {
  const [keepers, setKeepers] = useState<KeeperState[]>([])
  const [traces, setTraces] = useState<Trace[]>([])
  const [paletteVersion, setPaletteVersion] = useState(0)
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const providerRef = useRef<WebsocketProvider | null>(null)

  useEffect(() => {
    if (typeof window === 'undefined' || typeof WebSocket === 'undefined') return
    const url = yjsWebsocketUrl()
    if (!url) return

    const ydoc = new Y.Doc()
    let provider: WebsocketProvider
    try {
      provider = new WebsocketProvider(url, 'masc-telemetry', ydoc)
    } catch (err) {
      console.warn('[world-visualizer] WebSocket init failed:', err)
      ydoc.destroy()
      return
    }
    const yKeepers = ydoc.getMap<KeeperState>('keepers')
    const yTraces = ydoc.getArray<Trace>('traces')
    providerRef.current = provider

    const observer = () => {
      setKeepers(Array.from(yKeepers.values()))
      setTraces(yTraces.toArray())
    }

    yKeepers.observe(observer)
    yTraces.observe(observer)

    // Initial sync
    observer()

    return () => {
      yKeepers.unobserve(observer)
      yTraces.unobserve(observer)
      if (providerRef.current === provider) providerRef.current = null
      provider.destroy()
      ydoc.destroy()
    }
  }, [])

  useEffect(() => {
    if (typeof document === 'undefined' || typeof MutationObserver === 'undefined') {
      return undefined
    }

    const refreshPalette = () => {
      cssVarCache.clear()
      setPaletteVersion(version => version + 1)
    }

    const observer = new MutationObserver(refreshPalette)
    observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ['class', 'data-theme', 'style'],
    })
    return () => observer.disconnect()
  }, [])

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return
    const ctx = canvas.getContext('2d')
    if (!ctx) return

    // Resolve design tokens for canvas rendering (Cockpit SPEC compliance)
    const activeColor = cssVar('--color-status-ok')
    const pausedColor = cssVar('--color-status-err')
    const traceColor = cssVar('--agent-working')
    const textColor = cssVar('--fg-1')

    // Clear canvas
    ctx.clearRect(0, 0, canvas.width, canvas.height)

    const centerX = canvas.width / 2
    const centerY = canvas.height / 2

    // Draw Stigmergy Traces
    traces.forEach(trace => {
      ctx.beginPath()
      const x = centerX + Math.cos(trace.position) * (trace.position % 100)
      const y = centerY + Math.sin(trace.position) * (trace.position % 100)
      ctx.arc(x, y, 3, 0, 2 * Math.PI)
      ctx.globalAlpha = 0.4
      ctx.fillStyle = traceColor
      ctx.fill()
      ctx.globalAlpha = 1.0
    })

    // Draw Keepers
    keepers.forEach((keeper, index) => {
      ctx.beginPath()
      const angle = (index / Math.max(1, keepers.length)) * 2 * Math.PI
      const radius = 150 + Math.sin(keeper.position) * 20
      const x = centerX + Math.cos(angle) * radius
      const y = centerY + Math.sin(angle) * radius

      ctx.fillStyle = keeper.state === 'active' ? activeColor : pausedColor

      ctx.arc(x, y, 8, 0, 2 * Math.PI)
      ctx.fill()
      ctx.fillStyle = textColor
      ctx.font = '10px monospace'
      ctx.fillText(keeper.name, x + 12, y + 4)

      // Local Sight lines
      traces.slice(-6).forEach(trace => {
        const tx = centerX + Math.cos(trace.position) * (trace.position % 100)
        const ty = centerY + Math.sin(trace.position) * (trace.position % 100)
        ctx.beginPath()
        ctx.moveTo(x, y)
        ctx.lineTo(tx, ty)
        ctx.globalAlpha = 0.1
        ctx.strokeStyle = traceColor
        ctx.stroke()
        ctx.globalAlpha = 1.0
      })
    })
  }, [keepers, traces, paletteVersion])

  return html`
    <div style=${{ padding: '20px', background: 'var(--bg-0)', color: 'var(--fg-1)', borderRadius: '8px', marginBottom: '20px' }}>
      <h2 style=${{ margin: 0, paddingBottom: '10px' }}>Dream IDE: 7 Physical Laws Visualization</h2>
      <p style=${{ fontSize: '12px', color: 'var(--fg-3)' }}>Stigmergy Intensity · Local Sight (Max 6) · Active Inference</p>
      <canvas
        ref=${canvasRef}
        width=${800}
        height=${300}
        style=${{ border: '1px solid var(--line-1)', background: 'var(--bg-0)', display: 'block', margin: '0 auto' }}
      />
    </div>
  `
}
