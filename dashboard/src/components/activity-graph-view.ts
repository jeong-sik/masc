// Activity graph visualization — Canvas 2D force-directed graph
// Fetches from /api/v1/activity/graph, renders nodes as circles and edges as lines

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect, useRef } from 'preact/hooks'
import { layoutGraph } from './activity-graph-layout'
import type { ActivityGraphResponse } from '../types'

const hoveredNodeId = signal<string | null>(null)

// Node color by kind
function nodeColor(kind: string, status: string): string {
  if (status === 'offline' || status === 'retired') return '#64748b'
  switch (kind) {
    case 'agent': return '#22d3ee'
    case 'task': return '#fbbf24'
    case 'decision': return '#a78bfa'
    case 'operation': return '#4ade80'
    case 'debate': return '#fb923c'
    case 'post': return '#f472b6'
    default: return '#94a3b8'
  }
}

// Edge color by kind
function edgeColor(kind: string, active: boolean): string {
  if (!active) return 'rgba(100, 116, 139, 0.2)'
  switch (kind) {
    case 'mention': return 'rgba(34, 211, 238, 0.4)'
    case 'assigned': return 'rgba(74, 222, 128, 0.4)'
    case 'voted': return 'rgba(167, 139, 250, 0.4)'
    case 'commented': return 'rgba(244, 114, 182, 0.4)'
    case 'collaborated': return 'rgba(251, 191, 36, 0.4)'
    default: return 'rgba(148, 163, 184, 0.3)'
  }
}

function nodeRadius(weight: number): number {
  return Math.max(6, Math.min(24, 6 + Math.log1p(weight) * 3))
}

interface GraphViewProps {
  data: ActivityGraphResponse
}

export function GraphView({ data }: GraphViewProps) {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const containerRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const canvas = canvasRef.current
    const container = containerRef.current
    if (!canvas || !container || !data.nodes.length) return

    const rect = container.getBoundingClientRect()
    const width = Math.max(rect.width, 400)
    const height = 480
    const dpr = window.devicePixelRatio || 1

    canvas.width = width * dpr
    canvas.height = height * dpr
    canvas.style.width = `${width}px`
    canvas.style.height = `${height}px`

    const ctx = canvas.getContext('2d')
    if (!ctx) return
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)

    const layout = layoutGraph(
      data.nodes.map(n => ({ id: n.id, weight: n.weight })),
      data.edges.map(e => ({ source: e.source, target: e.target, weight: e.weight })),
      width,
      height,
      150,
    )

    const positions = layout.positions
    const hovered = hoveredNodeId.value

    // Background
    ctx.fillStyle = '#0f1117'
    ctx.fillRect(0, 0, width, height)

    // Draw edges
    for (const edge of data.edges) {
      const sp = positions.get(edge.source)
      const tp = positions.get(edge.target)
      if (!sp || !tp) continue

      const isHighlighted = hovered === edge.source || hovered === edge.target
      const lineWidth = isHighlighted
        ? Math.max(1, Math.min(4, 1 + edge.weight * 0.5))
        : Math.max(0.5, Math.min(2, 0.5 + edge.weight * 0.3))

      ctx.beginPath()
      ctx.moveTo(sp.x, sp.y)
      ctx.lineTo(tp.x, tp.y)
      ctx.strokeStyle = isHighlighted
        ? edgeColor(edge.kind, edge.active).replace(/[\d.]+\)$/, '0.7)')
        : edgeColor(edge.kind, edge.active)
      ctx.lineWidth = lineWidth
      ctx.stroke()
    }

    // Draw nodes
    for (const node of data.nodes) {
      const pos = positions.get(node.id)
      if (!pos) continue

      const r = nodeRadius(node.weight)
      const isHovered = hovered === node.id
      const color = nodeColor(node.kind, node.status)

      // Glow for hovered
      if (isHovered) {
        ctx.beginPath()
        ctx.arc(pos.x, pos.y, r + 6, 0, Math.PI * 2)
        ctx.fillStyle = color.replace(')', ', 0.2)').replace('rgb', 'rgba')
        ctx.fill()
      }

      ctx.beginPath()
      ctx.arc(pos.x, pos.y, r, 0, Math.PI * 2)
      ctx.fillStyle = color
      ctx.fill()

      // Border
      ctx.strokeStyle = isHovered ? '#fff' : 'rgba(255,255,255,0.15)'
      ctx.lineWidth = isHovered ? 2 : 1
      ctx.stroke()

      // Label for larger or hovered nodes
      if (r >= 10 || isHovered) {
        ctx.fillStyle = '#e2e8f0'
        ctx.font = `${isHovered ? 11 : 9}px system-ui, sans-serif`
        ctx.textAlign = 'center'
        ctx.fillText(node.label, pos.x, pos.y + r + 12)
      }
    }

    // Mouse interaction for hover
    function handleMouse(event: MouseEvent) {
      const canvasEl = canvasRef.current
      if (!canvasEl) return
      const canvasRect = canvasEl.getBoundingClientRect()
      const mx = event.clientX - canvasRect.left
      const my = event.clientY - canvasRect.top

      let found: string | null = null
      for (const node of data.nodes) {
        const pos = positions.get(node.id)
        if (!pos) continue
        const r = nodeRadius(node.weight)
        const dx = mx - pos.x
        const dy = my - pos.y
        if (dx * dx + dy * dy <= (r + 4) * (r + 4)) {
          found = node.id
          break
        }
      }
      if (hoveredNodeId.value !== found) {
        hoveredNodeId.value = found
      }
    }

    canvas.addEventListener('mousemove', handleMouse)
    return () => canvas.removeEventListener('mousemove', handleMouse)
  }, [data, hoveredNodeId.value])

  const hoveredNode = hoveredNodeId.value
    ? data.nodes.find(n => n.id === hoveredNodeId.value)
    : null

  return html`
    <div ref=${containerRef} class="relative w-full overflow-hidden bg-[#0f1117] my-3 rounded-xl">
      <canvas ref=${canvasRef} class="block w-full cursor-crosshair" />
      ${hoveredNode ? html`
        <div class="absolute bottom-3 left-3 flex items-center gap-2.5 py-2 px-3.5 rounded-[10px] bg-[rgba(15,23,42,0.92)] border border-[var(--slate-gray-20)] text-[13px] text-[var(--text-slate-light)] pointer-events-none">
          <strong class="text-sm text-[var(--text-near-white)]">${hoveredNode.label}</strong>
          <span class="py-0.5 px-[7px] bg-[var(--slate-gray-15)] text-[11px] text-[var(--text-slate)] rounded-md">${hoveredNode.kind}</span>
          <span>weight ${hoveredNode.weight}</span>
          <span>status ${hoveredNode.status}</span>
        </div>
      ` : null}
    </div>
  `
}
