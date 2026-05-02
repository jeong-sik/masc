import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { ActionButton } from './common/button'
import { StatusDot } from './common/status-dot'
import { useEffect, useRef } from 'preact/hooks'
import { Network } from 'vis-network'
import 'vis-network/styles/vis-network.css'
import { DataSet } from 'vis-data'
import { statusLabel } from '../lib/status-label'
import { tooltipHtml } from '../lib/escape-html'
import { selectedNodeId, highlightedAgentId } from './activity-graph-selection'
import type { ActivityGraphResponse, ActivityGraphEdge } from '../types'

const hoveredNodeId = signal<string | null>(null)

export function nodeColor(kind: string, status: string): string {
  if (status === 'offline' || status === 'retired') return 'var(--color-fg-muted)'
  switch (kind) {
    case 'keeper': return 'var(--color-status-ok)'
    case 'agent': return 'var(--cyan)'
    case 'task': return 'var(--color-status-warn)'
    case 'decision': return 'var(--purple)'
    case 'operation': return 'var(--color-status-ok)'
    case 'debate': return 'var(--color-orange-400)'
    case 'post': return 'var(--color-pink-400)'
    default: return 'var(--color-fg-muted)'
  }
}

export function edgeColor(kind: string, active: boolean): string {
  if (!active) return 'var(--white-10)'
  switch (kind) {
    case 'works_on': return 'var(--warn-border)'
    case 'creates': return 'var(--ok-border)'
    case 'broadcasts': return 'var(--info-border)'
    case 'mentions': return 'var(--info-fg)'
    case 'hands_off_to': return 'var(--purple-50)'
    case 'posts': return 'var(--stalled-border)'
    case 'comments_on': return 'var(--stalled-fg)'
    case 'votes_on': return 'var(--purple-50)'
    case 'opens': return 'var(--purple-50)'
    case 'governs': return 'var(--warn-fg)'
    case 'operates_on': return 'var(--ok-border)'
    case 'participates_in': return 'var(--warn-soft)'
    case 'belongs_to': return 'var(--color-border-default)'
    default: return 'var(--color-border-default)'
  }
}

export function kindLabel(kind: string): string {
  switch (kind) {
    case 'keeper': return '키퍼'
    case 'agent': return '에이전트'
    case 'task': return '작업'
    case 'decision': return '결정'
    case 'operation': return '작전'
    case 'debate': return '토론'
    case 'post': return '게시글'
    case 'room': return '프로젝트'
    default: return kind
  }
}

export function edgeKindLabel(kind: string): string {
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

export function GraphView({ data }: GraphViewProps) {
  const containerRef = useRef<HTMLDivElement>(null)
  const networkRef = useRef<Network | null>(null)

  useEffect(() => {
    const container = containerRef.current
    if (!container || !data.nodes.length) return

    const nodesData = new DataSet(data.nodes.map(n => {
      const color = nodeColor(n.kind, n.status)
      return {
        id: n.id,
        label: n.label,
        title: tooltipHtml([n.label, kindLabel(n.kind), `Status: ${n.status}`]),
        value: n.semantic_weight ?? n.weight,
        color: {
          background: color,
          border: (n.status === 'offline' || n.status === 'retired') ? 'var(--color-border-default)' : color,
          highlight: {
            background: color,
            border: 'var(--color-status-warn)'
          },
          hover: {
            background: color,
            border: 'var(--white-pure)'
          }
        },
        font: { color: 'var(--frost-100)', size: 12 },
        shape: 'dot'
      }
    }))

    const edgesData = new DataSet(data.edges.map((e, i) => ({
      id: e.id ?? `e-${i}-${e.source}-${e.target}`,
      from: e.source,
      to: e.target,
      value: e.weight,
      color: {
        color: edgeColor(e.kind, e.active),
        highlight: edgeColor(e.kind, e.active).replace(/[\d.]+\)$/, '0.7)'),
        hover: edgeColor(e.kind, e.active).replace(/[\d.]+\)$/, '0.6)')
      },
      title: tooltipHtml([edgeKindLabel(e.kind)]),
      arrows: {
        to: { enabled: true, scaleFactor: 0.5 }
      }
    })))

    const networkData = { nodes: nodesData, edges: edgesData }
    const options = {
      nodes: {
        scaling: {
          min: 6,
          max: 24,
        },
        borderWidth: 1,
        borderWidthSelected: 2.5
      },
      edges: {
        scaling: {
          min: 0.5,
          max: 2
        },
        smooth: {
          enabled: true,
          type: 'continuous',
          roundness: 0.5
        }
      },
      physics: {
        forceAtlas2Based: {
          gravitationalConstant: -50,
          centralGravity: 0.01,
          springLength: 100,
          springConstant: 0.08
        },
        maxVelocity: 50,
        solver: 'forceAtlas2Based',
        timestep: 0.35,
        stabilization: { iterations: 150 }
      },
      interaction: {
        hover: true,
        tooltipDelay: 200,
        zoomView: true,
        dragView: true
      }
    }

    const network = new Network(container, networkData, options)
    networkRef.current = network

    network.on('click', (params) => {
      if (params.nodes.length > 0) {
        const found = params.nodes[0]
        selectedNodeId.value = found
        if (found && (found.startsWith('agent:') || found.startsWith('keeper:'))) {
          highlightedAgentId.value = found.slice(found.indexOf(':') + 1)
        } else {
          highlightedAgentId.value = null
        }
      } else {
        selectedNodeId.value = null
        highlightedAgentId.value = null
      }
    })

    network.on('hoverNode', (params) => {
      hoveredNodeId.value = params.node
    })

    network.on('blurNode', () => {
      hoveredNodeId.value = null
    })

    return () => {
      network.destroy()
      networkRef.current = null
    }
  }, [data])

  useEffect(() => {
    const network = networkRef.current
    const selected = selectedNodeId.value
    if (!network) return

    if (!selected) {
      network.unselectAll()
      return
    }

    network.selectNodes([selected])
    network.focus(selected, {
      animation: {
        duration: 200,
        easingFunction: 'easeInOutQuad',
      },
      scale: 1.05,
    })
  }, [data, selectedNodeId.value])

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
    <div class="relative w-full my-3 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]">
      <div ref=${containerRef} class="w-full h-90" role="img" aria-label="에이전트 활동 네트워크 그래프"></div>
    </div>
    <div class="flex flex-wrap gap-x-4 gap-y-1 mt-1 px-1">
      ${[
        { label: '키퍼', color: 'var(--color-status-ok)' },
        { label: '에이전트', color: 'var(--cyan)' },
        { label: '작업', color: 'var(--color-status-warn)' },
        { label: '결정', color: 'var(--purple)' },
        { label: '작전', color: 'var(--color-status-ok)' },
        { label: '게시글', color: 'var(--color-pink-400)' },
      ].map(({ label, color }) => html`
        <div class="flex items-center gap-1.5 text-2xs text-[var(--color-fg-muted)]" key=${label}>
          <span class="w-2.5 h-2.5 rounded-full inline-block" style="background:${color}"></span>
          ${label}
        </div>
      `)}
    </div>

    ${selectedNode ? html`
      <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-4 mt-2">
        <div class="flex items-center gap-3 mb-3">
          <strong class="text-lg text-[var(--color-fg-primary)]">${selectedNode.label}</strong>
          <span class="py-0.5 px-2 bg-[var(--color-bg-panel-alt)] text-2xs text-[var(--color-fg-muted)] rounded-[var(--r-1)]">${kindLabel(selectedNode.kind)}</span>
          <span class="py-0.5 px-2 rounded-[var(--r-1)] text-2xs ${selectedNode.status === 'active' || selectedNode.status === 'done' ? 'text-[var(--color-status-ok)] bg-[var(--ok-10)]' : selectedNode.status === 'offline' || selectedNode.status === 'retired' ? 'text-[var(--color-fg-muted)] bg-[var(--color-bg-panel-alt)]' : 'text-[var(--color-fg-secondary)] bg-[var(--color-bg-panel-alt)]'}">${statusLabel(selectedNode.status)}</span>
          <${ActionButton} variant="subtle" size="sm" class="ml-auto" onClick=${() => { selectedNodeId.value = null }} ariaLabel="패널 닫기">닫기<//>
        </div>
        <div class="grid grid-cols-3 gap-3 mb-3">
          <div class="text-center">
            <div class="text-3xs text-[var(--color-fg-muted)] uppercase tracking-1">중요도</div>
            <div class="text-xl font-bold text-[var(--color-fg-primary)] tabular-nums">${(selectedNode.semantic_weight ?? selectedNode.weight).toFixed(1)}</div>
          </div>
          <div class="text-center">
            <div class="text-3xs text-[var(--color-fg-muted)] uppercase tracking-1">빈도</div>
            <div class="text-xl font-bold text-[var(--color-fg-secondary)] tabular-nums">${selectedNode.weight}</div>
          </div>
          <div class="text-center">
            <div class="text-3xs text-[var(--color-fg-muted)] uppercase tracking-1">연결</div>
            <div class="text-xl font-bold text-[var(--color-fg-secondary)] tabular-nums">${connectedEdges.length}</div>
          </div>
        </div>
        ${connectedEdges.length > 0 ? html`
          <div class="border-t border-[var(--color-bg-panel-alt)] pt-3">
            <div class="text-3xs text-[var(--color-fg-muted)] uppercase tracking-[var(--track-caps)] mb-2">연결된 관계</div>
            <div class="flex flex-col gap-1.5 max-h-40 overflow-y-auto">
              ${connectedEdges.slice(0, 20).map(({ edge, otherLabel }) => html`
                <div class="flex items-center gap-2 text-sm py-1 px-2 rounded-[var(--r-1)] bg-[var(--color-bg-surface)]" key=${edge.id ?? `${edge.source}-${edge.kind}-${edge.target}`}>
                  <span class="text-[var(--color-fg-secondary)]">${otherLabel}</span>
                  <span class="text-2xs text-[var(--color-fg-muted)]">${edgeKindLabel(edge.kind)}</span>
                  ${edge.active ? html`<${StatusDot} size="xs" class="bg-[var(--color-status-ok)]" />` : null}
                </div>
              `)}
            </div>
          </div>
        ` : null}
      </div>
    ` : null}
  `
}
