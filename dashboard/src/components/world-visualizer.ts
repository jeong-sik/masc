import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import * as Y from 'yjs'
import { WebsocketProvider } from 'y-websocket'

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

// Global Yjs setup for the telemetry
const ydoc = new Y.Doc()
// In production, this would use a dynamic host, but for now we hardcode localhost:1234
// @ts-ignore
const wsProvider = new WebsocketProvider('ws://localhost:1234', 'masc-telemetry', ydoc)
const yKeepers = ydoc.getMap('keepers')
const yTraces = ydoc.getArray('traces')

export function WorldVisualizer() {
  const [keepers, setKeepers] = useState<KeeperState[]>([])
  const [traces, setTraces] = useState<Trace[]>([])
  const canvasRef = useRef<HTMLCanvasElement>(null)

  useEffect(() => {
    const observer = () => {
      const parsedKeepers = Array.from(yKeepers.values()) as KeeperState[]
      const parsedTraces = yTraces.toArray() as Trace[]
      setKeepers(parsedKeepers)
      setTraces(parsedTraces)
    }

    yKeepers.observe(observer)
    yTraces.observe(observer)
    
    // Initial sync
    observer()

    return () => {
      yKeepers.unobserve(observer)
      yTraces.unobserve(observer)
    }
  }, [])

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return
    const ctx = canvas.getContext('2d')
    if (!ctx) return

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
      ctx.fillStyle = 'rgba(0, 255, 128, 0.4)'
      ctx.fill()
    })

    // Draw Keepers
    keepers.forEach((keeper, index) => {
      ctx.beginPath()
      const angle = (index / Math.max(1, keepers.length)) * 2 * Math.PI
      const radius = 150 + Math.sin(keeper.position) * 20
      const x = centerX + Math.cos(angle) * radius
      const y = centerY + Math.sin(angle) * radius

      if (keeper.state === 'active') {
        ctx.fillStyle = '#00FF00'
      } else {
        ctx.fillStyle = '#FF0000'
      }

      ctx.arc(x, y, 8, 0, 2 * Math.PI)
      ctx.fill()
      ctx.fillStyle = '#FFF'
      ctx.font = '10px monospace'
      ctx.fillText(keeper.name, x + 12, y + 4)
      
      // Local Sight lines
      traces.slice(-6).forEach(trace => {
        const tx = centerX + Math.cos(trace.position) * (trace.position % 100)
        const ty = centerY + Math.sin(trace.position) * (trace.position % 100)
        ctx.beginPath()
        ctx.moveTo(x, y)
        ctx.lineTo(tx, ty)
        ctx.strokeStyle = 'rgba(0, 255, 128, 0.1)'
        ctx.stroke()
      })
    })
  }, [keepers, traces])

  return html`
    <div style=${{ padding: '20px', background: '#111', color: '#FFF', borderRadius: '8px', marginBottom: '20px' }}>
      <h2 style=${{ margin: 0, paddingBottom: '10px' }}>Dream IDE: 7 Physical Laws Visualization</h2>
      <p style=${{ fontSize: '12px', color: '#AAA' }}>Stigmergy Intensity • Local Sight (Max 6) • Active Inference</p>
      <canvas 
        ref=${canvasRef} 
        width=${800} 
        height=${300} 
        style=${{ border: '1px solid #333', background: '#000', display: 'block', margin: '0 auto' }} 
      />
    </div>
  `
}
