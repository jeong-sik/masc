import { html } from 'htm/preact'
import { Card } from './common/card'
import {
  socialGraph,
  socialGraphError,
  socialGraphLoading,
  socialNodes,
  socialEdges,
  socialStats,
  socialStreamConnected,
  socialStreamEventCount,
  socialTimeline,
} from '../social-store'
import type { SocialEvent, SocialGraphNode } from '../types'

type Point = { x: number; y: number }

const VIEWBOX_WIDTH = 960
const VIEWBOX_HEIGHT = 620

function kindColor(kind: string): string {
  if (kind === 'room') return '#f4f1de'
  if (kind === 'agent') return '#2a9d8f'
  if (kind === 'task') return '#e76f51'
  if (kind === 'decision') return '#e9c46a'
  if (kind === 'operation') return '#577590'
  if (kind === 'unit') return '#8d99ae'
  return '#94a3b8'
}

function edgeColor(kind: string): string {
  if (kind === 'hands_off_to') return '#f28482'
  if (kind === 'works_on') return '#e76f51'
  if (kind === 'votes_on') return '#e9c46a'
  if (kind === 'mentions') return '#2a9d8f'
  if (kind === 'operates_on') return '#577590'
  return 'rgba(148, 163, 184, 0.55)'
}

function groupCenter(kind: string): Point {
  if (kind === 'room') return { x: 0.48, y: 0.52 }
  if (kind === 'agent') return { x: 0.24, y: 0.52 }
  if (kind === 'task') return { x: 0.75, y: 0.34 }
  if (kind === 'decision') return { x: 0.54, y: 0.17 }
  if (kind === 'operation') return { x: 0.72, y: 0.74 }
  if (kind === 'unit') return { x: 0.38, y: 0.8 }
  return { x: 0.14, y: 0.2 }
}

function layoutNodes(nodes: SocialGraphNode[]): Map<string, Point> {
  const groups = new Map<string, SocialGraphNode[]>()
  for (const node of nodes) {
    const list = groups.get(node.kind) ?? []
    list.push(node)
    groups.set(node.kind, list)
  }

  const positions = new Map<string, Point>()
  for (const [kind, list] of groups.entries()) {
    const center = groupCenter(kind)
    const cx = center.x * VIEWBOX_WIDTH
    const cy = center.y * VIEWBOX_HEIGHT
    const radius = kind === 'room' ? 0 : 64 + Math.min(list.length, 8) * 10

    list.forEach((node, index) => {
      if (kind === 'room') {
        positions.set(node.id, { x: cx, y: cy })
        return
      }
      const theta = (Math.PI * 2 * index) / Math.max(list.length, 1)
      positions.set(node.id, {
        x: cx + Math.cos(theta) * radius,
        y: cy + Math.sin(theta) * radius,
      })
    })
  }

  return positions
}

function nodeRadius(node: SocialGraphNode): number {
  return Math.max(10, Math.min(26, 10 + node.weight * 1.4))
}

function statusTone(status: string): string {
  if (status === 'active' || status === 'running' || status === 'autonomy') return 'good'
  if (status === 'claimed' || status === 'compacting' || status === 'handoff') return 'warn'
  if (status === 'offline' || status === 'retired' || status === 'cancelled') return 'bad'
  return 'idle'
}

function summarizeEvent(event: SocialEvent): string {
  const payload = (event.payload && typeof event.payload === 'object') ? event.payload as Record<string, unknown> : null
  if (payload?.title && typeof payload.title === 'string') return payload.title
  if (payload?.topic && typeof payload.topic === 'string') return payload.topic
  if (payload?.action && typeof payload.action === 'string') return payload.action
  if (payload?.content && typeof payload.content === 'string') return payload.content
  return event.kind
}

function entityLabel(event: SocialEvent, side: 'actor' | 'subject'): string {
  const ref = side === 'actor' ? event.actor : event.subject
  if (!ref) return side === 'actor' ? 'system' : 'none'
  return `${ref.kind}:${ref.id}`
}

function timeLabel(value?: string): string {
  if (!value) return ''
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  return new Intl.DateTimeFormat('ko-KR', {
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  }).format(date)
}

export function Social() {
  const snapshot = socialGraph.value
  const nodes = socialNodes.value
  const edges = socialEdges.value
  const stats = socialStats.value
  const timeline = socialTimeline.value.slice(0, 14)
  const positions = layoutNodes(nodes)

  return html`
    <div class="social-surface">
      <div class="social-header">
        <div>
          <h2>사회 움직임</h2>
          <p>에이전트, 태스크, 결정, 작전이 서로 어떻게 얽혀 움직였는지 한 장에서 봅니다.</p>
        </div>
        <div class="social-header-badges">
          <span class="social-chip ${socialStreamConnected.value ? 'connected' : 'disconnected'}">
            ${socialStreamConnected.value ? 'stream live' : 'stream reconnecting'}
          </span>
          <span class="social-chip">events ${socialStreamEventCount.value}</span>
          <span class="social-chip">nodes ${stats?.node_count ?? nodes.length}</span>
          <span class="social-chip">edges ${stats?.edge_count ?? edges.length}</span>
        </div>
      </div>

      ${socialGraphError.value
        ? html`<div class="social-error">${socialGraphError.value}</div>`
        : null}

      <div class="social-layout">
        <${Card} class="social-graph-card" title="Social Graph">
          ${socialGraphLoading.value && !snapshot
            ? html`<div class="social-loading">사회 그래프를 불러오는 중...</div>`
            : html`
                <div class="social-graph-meta">
                  <div class="social-metric-stack">
                    <span><strong>${stats?.active_agents ?? 0}</strong> active agents</span>
                    <span><strong>${stats?.task_count ?? 0}</strong> tasks</span>
                    <span><strong>${stats?.decision_count ?? 0}</strong> decisions</span>
                    <span><strong>${stats?.operation_count ?? 0}</strong> operations</span>
                  </div>
                  <div class="social-generated-at">
                    ${snapshot?.generated_at ? `snapshot ${timeLabel(snapshot.generated_at)}` : 'snapshot pending'}
                  </div>
                </div>

                <svg class="social-graph-canvas" viewBox=${`0 0 ${VIEWBOX_WIDTH} ${VIEWBOX_HEIGHT}`}>
                  <defs>
                    <radialGradient id="socialGlow" cx="50%" cy="50%" r="50%">
                      <stop offset="0%" stop-color="rgba(255,255,255,0.55)" />
                      <stop offset="100%" stop-color="rgba(255,255,255,0)" />
                    </radialGradient>
                  </defs>

                  <circle class="social-graph-halo" cx="460" cy="314" r="168" />
                  ${edges.map(edge => {
                    const source = positions.get(edge.source)
                    const target = positions.get(edge.target)
                    if (!source || !target) return null
                    return html`
                      <line
                        key=${edge.id}
                        class=${`social-edge ${edge.active ? 'active' : ''}`}
                        x1=${source.x}
                        y1=${source.y}
                        x2=${target.x}
                        y2=${target.y}
                        stroke=${edgeColor(edge.kind)}
                        stroke-width=${Math.max(1.5, Math.min(5, 1 + edge.weight * 0.7))}
                      />
                    `
                  })}

                  ${nodes.map(node => {
                    const point = positions.get(node.id)
                    if (!point) return null
                    const radius = nodeRadius(node)
                    return html`
                      <g key=${node.id} transform=${`translate(${point.x}, ${point.y})`}>
                        <circle class="social-node-glow" r=${radius + 12} fill="url(#socialGlow)" />
                        <circle
                          class=${`social-node ${statusTone(node.status)}`}
                          r=${radius}
                          fill=${kindColor(node.kind)}
                        />
                        <text class="social-node-label" x="0" y=${radius + 18} text-anchor="middle">
                          ${node.label}
                        </text>
                        <text class="social-node-meta" x="0" y=${radius + 32} text-anchor="middle">
                          ${node.kind} · ${node.status}
                        </text>
                      </g>
                    `
                  })}
                </svg>
              `}
        </${Card}>

        <div class="social-side-column">
          <${Card} class="social-timeline-card" title="Movement Feed">
            <div class="social-timeline-list">
              ${timeline.map(event => html`
                <div class="social-timeline-item" key=${event.seq}>
                  <div class="social-timeline-topline">
                    <span class="social-kind">${event.kind}</span>
                    <span class="social-time">${timeLabel(event.ts_iso)}</span>
                  </div>
                  <div class="social-actor-line">
                    <strong>${entityLabel(event, 'actor')}</strong>
                    <span>→</span>
                    <span>${entityLabel(event, 'subject')}</span>
                  </div>
                  <div class="social-summary">${summarizeEvent(event)}</div>
                </div>
              `)}
            </div>
          </${Card}>

          <${Card} class="social-stats-card" title="Pressure">
            <div class="social-pressure-grid">
              <div class="social-pressure-cell">
                <span>event pulse</span>
                <strong>${stats?.event_count ?? timeline.length}</strong>
              </div>
              <div class="social-pressure-cell">
                <span>agent field</span>
                <strong>${stats?.agent_count ?? 0}</strong>
              </div>
              <div class="social-pressure-cell">
                <span>task tension</span>
                <strong>${stats?.task_count ?? 0}</strong>
              </div>
              <div class="social-pressure-cell">
                <span>governance load</span>
                <strong>${stats?.decision_count ?? 0}</strong>
              </div>
            </div>
          </${Card}>
        </div>
      </div>
    </div>
  `
}
