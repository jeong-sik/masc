import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect, useRef } from 'preact/hooks'
import { Network } from 'vis-network'
import 'vis-network/styles/vis-network.css'
import { DataSet } from 'vis-data'
import { statusLabel } from '../lib/status-label'
import { tooltipHtml } from '../lib/escape-html'
import { selectedNodeId, highlightedAgentId } from './activity-graph-selection'
import type { ActivityGraphResponse, ActivityGraphEdge } from '../types'

const hoveredNodeId = signal<string | null>(null)

function nodeColor(kind: string, status: string): string {
  if (status === 'offline' || status === 'retired') return 'var(--slate-500)'
  switch (kind) {
    case 'keeper': return 'var(--ok)'
    case 'agent': return 'var(--cyan)'
    case 'task': return 'var(--warn)'
    case 'decision': return 'var(--purple)'
    case 'operation': return 'var(--ok)'
    case 'debate': return '#fb923c'
    case 'post': return '#f472b6'
    default: return 'var(--slate-400)'
  }
}

function edgeColor(kind: string, active: boolean): string {
  if (!active) return 'rgba(100, 116, 139, 0.15)'
  switch (kind) {
    case 'works_on': return 'rgba(251, 191, 36, 0.5)'
    case 'creates': return 'rgba(74, 222, 128, 0.4)'
    case 'broadcasts': return 'rgba(34, 211, 238, 0.35)'
    case 'mentions': return 'rgba(34, 211, 238, 0.55)'
    case 'hands_off_to': return 'var(--purple-50)'
    case 'posts': return 'rgba(244, 114, 182, 0.4)'
    case 'comments_on': return 'rgba(244, 114, 182, 0.3)'
    case 'votes_on': return 'rgba(167, 139, 250, 0.35)'
    case 'opens': return 'rgba(167, 139, 250, 0.4)'
    case 'governs': return 'rgba(251, 146, 60, 0.4)'
    case 'operates_on': return 'rgba(74, 222, 128, 0.45)'
    case 'participates_in': return 'rgba(251, 191, 36, 0.35)'
    case 'belongs_to': return 'var(--slate-gray-12)'
    default: return 'rgba(148, 163, 184, 0.25)'
  }
}

function kindLabel(kind: string): string {
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
          border: (n.status === 'offline' || n.status === 'retired') ? 'var(--slate-600)' : color,
          highlight: {
            background: color,
            border: 'var(--warn)'
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
    <div class="relative w-full my-3 rounded border border-[var(--card-border)] bg-[#0f1117]">
      <div ref=${containerRef} class="w-full h-90"></div>
    </div>
    <div class="flex flex-wrap gap-x-4 gap-y-1 mt-1 px-1">
      ${[
        { label: '키퍼', color: 'var(--ok)' },
        { label: '에이전트', color: 'var(--cyan)' },
        { label: '작업', color: 'var(--warn)' },
        { label: '결정', color: 'var(--purple)' },
        { label: '작전', color: 'var(--ok)' },
        { label: '게시글', color: '#f472b6' },
      ].map(({ label, color }) => html`
        <div class="flex items-center gap-1.5 text-2xs text-[var(--text-muted)]" key=${label}>
          <span class="w-2.5 h-2.5 rounded-full inline-block" style="background:${color}"></span>
          ${label}
        </div>
      `)}
    </div>

    ${selectedNode ? html`
      <div class="rounded border border-[var(--card-border)] bg-[var(--card)] p-4 mt-2">
        <div class="flex items-center gap-3 mb-3">
          <strong class="text-lg text-[var(--text-near-white)]">${selectedNode.label}</strong>
          <span class="py-0.5 px-2 bg-[var(--slate-gray-15)] text-2xs text-[var(--text-slate)] rounded">${kindLabel(selectedNode.kind)}</span>
          <span class="py-0.5 px-2 rounded text-2xs ${selectedNode.status === 'active' || selectedNode.status === 'done' ? 'text-[var(--ok)] bg-[var(--ok-10)]' : selectedNode.status === 'offline' || selectedNode.status === 'retired' ? 'text-[var(--text-slate)] bg-[var(--slate-gray-10)]' : 'text-[var(--text-slate-light)] bg-[var(--slate-gray-10)]'}">${statusLabel(selectedNode.status)}</span>
          <button type="button" class="ml-auto text-[var(--text-muted)] hover:text-[var(--text-slate-light)] text-sm cursor-pointer bg-transparent border-none" onClick=${() => { selectedNodeId.value = null }}>닫기</button>
        </div>
        <div class="grid grid-cols-3 gap-3 mb-3">
          <div class="text-center">
            <div class="text-3xs text-[var(--text-muted)] uppercase tracking-1">중요도</div>
            <div class="text-xl font-bold text-[var(--text-near-white)] tabular-nums">${(selectedNode.semantic_weight ?? selectedNode.weight).toFixed(1)}</div>
          </div>
          <div class="text-center">
            <div class="text-3xs text-[var(--text-muted)] uppercase tracking-1">빈도</div>
            <div class="text-xl font-bold text-[var(--text-slate-light)] tabular-nums">${selectedNode.weight}</div>
          </div>
          <div class="text-center">
            <div class="text-3xs text-[var(--text-muted)] uppercase tracking-1">연결</div>
            <div class="text-xl font-bold text-[var(--text-slate-light)] tabular-nums">${connectedEdges.length}</div>
          </div>
        </div>
        ${connectedEdges.length > 0 ? html`
          <div class="border-t border-[var(--slate-gray-10)] pt-3">
            <div class="text-3xs text-[var(--text-muted)] uppercase tracking-1 mb-2">연결된 관계</div>
            <div class="flex flex-col gap-1.5 max-h-40 overflow-y-auto">
              ${connectedEdges.slice(0, 20).map(({ edge, otherLabel }) => html`
                <div class="flex items-center gap-2 text-sm py-1 px-2 rounded bg-[rgba(15,23,42,0.4)]" key=${edge.id ?? `${edge.source}-${edge.kind}-${edge.target}`}>
                  <span class="text-[var(--text-slate-light)]">${otherLabel}</span>
                  <span class="text-2xs text-[var(--text-muted)]">${edgeKindLabel(edge.kind)}</span>
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
