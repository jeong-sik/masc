// Activity graph visualization — Canvas 2D force-directed graph
// Fetches from /api/v1/activity/graph, renders nodes as circles and edges as lines
// Supports hover (tooltip), click (detail panel), and semantic weight sizing.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect, useRef } from 'preact/hooks'
import { layoutGraph } from './activity-graph-layout'
import { statusLabel } from '../lib/status-label'
import type { ActivityGraphResponse, ActivityGraphNode, ActivityGraphEdge } from '../types'

const hoveredNodeId = signal<string | null>(null)
export const selectedNodeId = signal<string | null>(null)
export const highlightedAgentId = signal<string | null>(null)

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

// Edge color by actual backend edge kind
function edgeColor(kind: string, active: boolean): string {
  if (!active) return 'rgba(100, 116, 139, 0.15)'
  switch (kind) {
    case 'works_on': return 'rgba(251, 191, 36, 0.5)'
    case 'creates': return 'rgba(74, 222, 128, 0.4)'
    case 'broadcasts': return 'rgba(34, 211, 238, 0.35)'
    case 'mentions': return 'rgba(34, 211, 238, 0.55)'
    case 'hands_off_to': return 'rgba(167, 139, 250, 0.5)'
    case 'posts': return 'rgba(244, 114, 182, 0.4)'
    case 'comments_on': return 'rgba(244, 114, 182, 0.3)'
    case 'votes_on': return 'rgba(167, 139, 250, 0.35)'
    case 'opens': return 'rgba(167, 139, 250, 0.4)'
    case 'governs': return 'rgba(251, 146, 60, 0.4)'
    case 'operates_on': return 'rgba(74, 222, 128, 0.45)'
    case 'participates_in': return 'rgba(251, 191, 36, 0.35)'
    case 'belongs_to': return 'rgba(148, 163, 184, 0.12)'
    default: return 'rgba(148, 163, 184, 0.25)'
  }
}

function nodeRadius(node: ActivityGraphNode): number {
  const w = node.semantic_weight ?? node.weight
  return Math.max(6, Math.min(24, 6 + Math.log1p(w) * 3))
}

function kindLabel(kind: string): string {
  switch (kind) {
    case 'agent': return '에이전트'
    case 'task': return '작업'
    case 'decision': return '결정'
    case 'operation': return '작전'
    case 'debate': return '토론'
    case 'post': return '게시글'
    case 'room': return '룸'
    default: return kind
  }
}

function edgeKindLabel(kind: string): string {
  switch (kind) {
    case 'works_on': return '작업 중'
    case 'creates': return '생성'
    case 'broadcasts': return '브로드캐스트'
    case 'mentions': return '멘션'
    case 'hands_off_to': return '핸드오프'
    case 'posts': return '게시'
    case 'comments_on': return '댓글'
    case 'votes_on': return '투표'
    case 'belongs_to': return '소속'
    case 'opens': return '열기'
    case 'governs': return '거버넌스'
    case 'operates_on': return '운영'
    case 'participates_in': return '참여'
    default: return kind
  }
}

interface GraphViewProps {
  data: ActivityGraphResponse
}

function hitTest(
  nodes: ActivityGraphNode[],
  positions: Map<string, { x: number; y: number }>,
  mx: number,
  my: number,
): string | null {
  for (const node of nodes) {
    const pos = positions.get(node.id)
    if (!pos) continue
    const r = nodeRadius(node)
    const dx = mx - pos.x
    const dy = my - pos.y
    if (dx * dx + dy * dy <= (r + 4) * (r + 4)) return node.id
  }
  return null
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
      data.nodes.map(n => ({ id: n.id, weight: n.semantic_weight ?? n.weight })),
      data.edges.map(e => ({ source: e.source, target: e.target, weight: e.weight })),
      width,
      height,
      150,
    )

    const positions = layout.positions
    const hovered = hoveredNodeId.value
    const selected = selectedNodeId.value
    const highlightedAgent = highlightedAgentId.value

    // Background
    ctx.fillStyle = '#0f1117'
    ctx.fillRect(0, 0, width, height)

    // Draw edges
    for (const edge of data.edges ?? []) {
      const sp = positions.get(edge.source)
      const tp = positions.get(edge.target)
      if (!sp || !tp) continue

      const isConnected = selected === edge.source || selected === edge.target
        || hovered === edge.source || hovered === edge.target
      const lineWidth = isConnected
        ? Math.max(1, Math.min(4, 1 + edge.weight * 0.5))
        : Math.max(0.5, Math.min(2, 0.5 + edge.weight * 0.3))

      ctx.beginPath()
      ctx.moveTo(sp.x, sp.y)
      ctx.lineTo(tp.x, tp.y)
      ctx.strokeStyle = isConnected
        ? edgeColor(edge.kind, edge.active).replace(/[\d.]+\)$/, '0.7)')
        : edgeColor(edge.kind, edge.active)
      ctx.lineWidth = lineWidth
      ctx.stroke()
    }

    // Draw nodes
    for (const node of data.nodes ?? []) {
      const pos = positions.get(node.id)
      if (!pos) continue

      const r = nodeRadius(node)
      const isHovered = hovered === node.id
      const isSelected = selected === node.id
      const isHighlightedAgent = highlightedAgent !== null && node.id === 'agent:' + highlightedAgent
      const color = nodeColor(node.kind, node.status)

      // Glow for selected or highlighted agent (distinct from hover)
      if (isSelected || isHighlightedAgent) {
        ctx.beginPath()
        ctx.arc(pos.x, pos.y, r + 8, 0, Math.PI * 2)
        ctx.fillStyle = 'rgba(251, 191, 36, 0.15)'
        ctx.fill()
      } else if (isHovered) {
        ctx.beginPath()
        ctx.arc(pos.x, pos.y, r + 6, 0, Math.PI * 2)
        ctx.fillStyle = color.replace(')', ', 0.2)').replace('rgb', 'rgba')
        ctx.fill()
      }

      ctx.beginPath()
      ctx.arc(pos.x, pos.y, r, 0, Math.PI * 2)
      ctx.fillStyle = color
      ctx.fill()

      // Border — selected/highlighted gets gold, hovered gets white
      ctx.strokeStyle = (isSelected || isHighlightedAgent) ? '#fbbf24' : isHovered ? '#fff' : 'rgba(255,255,255,0.15)'
      ctx.lineWidth = (isSelected || isHighlightedAgent) ? 2.5 : isHovered ? 2 : 1
      ctx.stroke()

      // Label for larger, hovered, selected, or highlighted nodes
      if (r >= 10 || isHovered || isSelected || isHighlightedAgent) {
        ctx.fillStyle = (isSelected || isHighlightedAgent) ? '#fbbf24' : '#e2e8f0'
        ctx.font = `${isHovered || isSelected || isHighlightedAgent ? 11 : 9}px system-ui, sans-serif`
        ctx.textAlign = 'center'
        ctx.fillText(node.label, pos.x, pos.y + r + 12)
      }
    }

    // Mouse interaction
    function handleMouse(event: MouseEvent) {
      const canvasEl = canvasRef.current
      if (!canvasEl) return
      const canvasRect = canvasEl.getBoundingClientRect()
      const mx = event.clientX - canvasRect.left
      const my = event.clientY - canvasRect.top
      const found = hitTest(data.nodes, positions, mx, my)
      if (hoveredNodeId.value !== found) hoveredNodeId.value = found
      canvasEl.style.cursor = found ? 'pointer' : 'crosshair'
    }

    function handleClick(event: MouseEvent) {
      const canvasEl = canvasRef.current
      if (!canvasEl) return
      const canvasRect = canvasEl.getBoundingClientRect()
      const mx = event.clientX - canvasRect.left
      const my = event.clientY - canvasRect.top
      const found = hitTest(data.nodes, positions, mx, my)
      selectedNodeId.value = found
      if (found && found.startsWith('agent:')) {
        highlightedAgentId.value = found.slice(6)
      } else {
        highlightedAgentId.value = null
      }
    }

    canvas.addEventListener('mousemove', handleMouse)
    canvas.addEventListener('click', handleClick)
    return () => {
      canvas.removeEventListener('mousemove', handleMouse)
      canvas.removeEventListener('click', handleClick)
    }
  }, [data, hoveredNodeId.value, selectedNodeId.value, highlightedAgentId.value])

  const hoveredNode = hoveredNodeId.value
    ? data.nodes.find(n => n.id === hoveredNodeId.value)
    : null

  const selectedNode = selectedNodeId.value
    ? data.nodes.find(n => n.id === selectedNodeId.value)
    : null

  // Edges connected to selected node
  const connectedEdges: Array<{ edge: ActivityGraphEdge; otherLabel: string }> = []
  if (selectedNode) {
    for (const edge of data.edges ?? []) {
      if (edge.source === selectedNode.id || edge.target === selectedNode.id) {
        const otherId = edge.source === selectedNode.id ? edge.target : edge.source
        const otherNode = data.nodes.find(n => n.id === otherId)
        if (edge.kind !== 'belongs_to') {
          connectedEdges.push({ edge, otherLabel: otherNode?.label ?? otherId })
        }
      }
    }
  }

  return html`
    <div ref=${containerRef} class="relative w-full overflow-hidden bg-[#0f1117] my-3 rounded-xl">
      <canvas ref=${canvasRef} class="block w-full cursor-crosshair" />
      ${hoveredNode && !selectedNode ? html`
        <div class="absolute bottom-3 left-3 flex items-center gap-3 py-2 px-3.5 rounded-[10px] bg-[rgba(15,23,42,0.92)] border border-[var(--slate-gray-20)] text-[13px] text-[var(--text-slate-light)] pointer-events-none">
          <strong class="text-base text-[var(--text-near-white)]">${hoveredNode.label}</strong>
          <span class="py-0.5 px-[7px] bg-[var(--slate-gray-15)] text-[11px] text-[var(--text-slate)] rounded-md">${kindLabel(hoveredNode.kind)}</span>
          <span>중요도 ${(hoveredNode.semantic_weight ?? hoveredNode.weight).toFixed(1)}</span>
          <span class="${hoveredNode.status === 'active' ? 'text-[var(--ok)]' : hoveredNode.status === 'offline' ? 'text-[var(--text-muted)]' : ''}">${statusLabel(hoveredNode.status)}</span>
        </div>
      ` : null}
    </div>
    <div class="flex flex-wrap gap-x-4 gap-y-1 mt-1 px-1">
      ${[
        { label: '에이전트', color: '#22d3ee' },
        { label: '작업', color: '#fbbf24' },
        { label: '결정', color: '#a78bfa' },
        { label: '작전', color: '#4ade80' },
        { label: '게시글', color: '#f472b6' },
      ].map(({ label, color }) => html`
        <div class="flex items-center gap-1.5 text-[11px] text-[var(--text-muted)]" key=${label}>
          <span class="w-2.5 h-2.5 rounded-full inline-block" style="background:${color}"></span>
          ${label}
        </div>
      `)}
    </div>

    ${selectedNode ? html`
      <div class="rounded-xl border border-[var(--card-border)] bg-[var(--card)] p-4 mt-2">
        <div class="flex items-center gap-3 mb-3">
          <strong class="text-lg text-[var(--text-near-white)]">${selectedNode.label}</strong>
          <span class="py-0.5 px-2 bg-[var(--slate-gray-15)] text-[11px] text-[var(--text-slate)] rounded-md">${kindLabel(selectedNode.kind)}</span>
          <span class="py-0.5 px-2 rounded-md text-[11px] ${selectedNode.status === 'active' || selectedNode.status === 'done' ? 'text-[var(--ok)] bg-[var(--ok-10)]' : selectedNode.status === 'offline' || selectedNode.status === 'retired' ? 'text-[var(--text-slate)] bg-[var(--slate-gray-10)]' : 'text-[var(--text-slate-light)] bg-[var(--slate-gray-10)]'}">${statusLabel(selectedNode.status)}</span>
          <button type="button" class="ml-auto text-[var(--text-muted)] hover:text-[var(--text-slate-light)] text-sm cursor-pointer bg-transparent border-none" onClick=${() => { selectedNodeId.value = null }}>닫기</button>
        </div>
        <div class="grid grid-cols-3 gap-3 mb-3">
          <div class="text-center">
            <div class="text-[10px] text-[var(--text-muted)] uppercase tracking-[0.08em]">중요도</div>
            <div class="text-xl font-bold text-[var(--text-near-white)] tabular-nums">${(selectedNode.semantic_weight ?? selectedNode.weight).toFixed(1)}</div>
          </div>
          <div class="text-center">
            <div class="text-[10px] text-[var(--text-muted)] uppercase tracking-[0.08em]">빈도</div>
            <div class="text-xl font-bold text-[var(--text-slate-light)] tabular-nums">${selectedNode.weight}</div>
          </div>
          <div class="text-center">
            <div class="text-[10px] text-[var(--text-muted)] uppercase tracking-[0.08em]">연결</div>
            <div class="text-xl font-bold text-[var(--text-slate-light)] tabular-nums">${connectedEdges.length}</div>
          </div>
        </div>
        ${connectedEdges.length > 0 ? html`
          <div class="border-t border-[var(--slate-gray-10)] pt-3">
            <div class="text-[10px] text-[var(--text-muted)] uppercase tracking-[0.08em] mb-2">연결된 관계</div>
            <div class="flex flex-col gap-1.5 max-h-[160px] overflow-y-auto">
              ${connectedEdges.slice(0, 20).map(({ edge, otherLabel }) => html`
                <div class="flex items-center gap-2 text-[13px] py-1 px-2 rounded-lg bg-[rgba(15,23,42,0.4)]" key=${edge.id ?? `${edge.source}-${edge.kind}-${edge.target}`}>
                  <span class="text-[var(--text-slate-light)]">${otherLabel}</span>
                  <span class="text-[11px] text-[var(--text-muted)]">${edgeKindLabel(edge.kind)}</span>
                  ${edge.active ? html`<span class="w-1.5 h-1.5 rounded-full bg-[var(--ok)]"></span>` : null}
                </div>
              `)}
            </div>
          </div>
        ` : null}
      </div>
    ` : null}
  `
}
