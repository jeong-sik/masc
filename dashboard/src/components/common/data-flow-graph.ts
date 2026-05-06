// DataFlowGraph — Sankey/flow diagram for agent message/data transfer
// Kimi design system sec03 3.3.1: agent data flow visualisation.
// Zero-dependency SVG fallback (no D3).

import { html } from 'htm/preact'

export interface FlowNode {
  id: string
  label: string
  x: number
  y: number
  width: number
  height: number
  color?: string
}

export interface FlowEdge {
  source: string
  target: string
  value: number
  color?: string
}

interface DataFlowGraphProps {
  nodes: FlowNode[]
  edges: FlowEdge[]
  onSelectNode?: (id: string) => void
  testId?: string
}

export type DataFlowGraphStatus = 'empty' | 'connected' | 'partial' | 'disconnected'

export interface DataFlowGraphSummary {
  nodeCount: number
  edgeCount: number
  validEdgeCount: number
  missingEdgeCount: number
  totalValue: number
  maxValue: number
  status: DataFlowGraphStatus
}

interface RenderableFlowEdge {
  edge: FlowEdge
  sourceNode: FlowNode
  targetNode: FlowNode
  value: number
}

function normalizedEdgeValue(edge: FlowEdge): number {
  return Number.isFinite(edge.value) ? Math.max(0, edge.value) : 0
}

export function getRenderableFlowEdges(nodes: FlowNode[], edges: FlowEdge[]): RenderableFlowEdge[] {
  const nodeMap = new Map(nodes.map(node => [node.id, node]))
  return edges.flatMap(edge => {
    const sourceNode = nodeMap.get(edge.source)
    const targetNode = nodeMap.get(edge.target)
    if (!sourceNode || !targetNode) {
      return []
    }
    return [{ edge, sourceNode, targetNode, value: normalizedEdgeValue(edge) }]
  })
}

export function summarizeDataFlowGraph(nodes: FlowNode[], edges: FlowEdge[]): DataFlowGraphSummary {
  const renderableEdges = getRenderableFlowEdges(nodes, edges)
  const validEdgeCount = renderableEdges.length
  const missingEdgeCount = edges.length - validEdgeCount
  const totalValue = renderableEdges.reduce((sum, item) => sum + item.value, 0)
  const maxValue = renderableEdges.reduce((max, item) => Math.max(max, item.value), 1)
  const status: DataFlowGraphStatus =
    nodes.length === 0
      ? 'empty'
      : missingEdgeCount > 0
        ? 'partial'
        : validEdgeCount > 0
          ? 'connected'
          : 'disconnected'

  return {
    nodeCount: nodes.length,
    edgeCount: edges.length,
    validEdgeCount,
    missingEdgeCount,
    totalValue,
    maxValue,
    status,
  }
}

export function DataFlowGraph({ nodes, edges, onSelectNode, testId }: DataFlowGraphProps) {
  const summary = summarizeDataFlowGraph(nodes, edges)

  if (nodes.length === 0) {
    return html`
      <div
        data-data-flow-graph
        data-data-flow-graph-node-count=${summary.nodeCount}
        data-data-flow-graph-edge-count=${summary.edgeCount}
        data-data-flow-graph-valid-edge-count=${summary.validEdgeCount}
        data-data-flow-graph-missing-edge-count=${summary.missingEdgeCount}
        data-data-flow-graph-total-value=${summary.totalValue}
        data-data-flow-graph-max-value=${summary.maxValue}
        data-data-flow-graph-status=${summary.status}
        data-testid=${testId}
        class="flex h-48 items-center justify-center rounded-[var(--r-1)] border border-dashed border-[var(--color-border-default)] text-xs text-[var(--color-fg-muted)]"
        role="img"
        aria-label="데이터 흐름 그래프, 노드 없음"
      >
        노드가 없습니다.
      </div>
    `
  }

  const width = 600
  const height = 320
  const renderableEdges = getRenderableFlowEdges(nodes, edges)
  const nodeTotals = new Map(nodes.map(node => [node.id, { incoming: 0, outgoing: 0 }]))
  for (const item of renderableEdges) {
    nodeTotals.get(item.edge.source)!.outgoing += item.value
    nodeTotals.get(item.edge.target)!.incoming += item.value
  }

  return html`
    <figure
      data-data-flow-graph
      data-data-flow-graph-node-count=${summary.nodeCount}
      data-data-flow-graph-edge-count=${summary.edgeCount}
      data-data-flow-graph-valid-edge-count=${summary.validEdgeCount}
      data-data-flow-graph-missing-edge-count=${summary.missingEdgeCount}
      data-data-flow-graph-total-value=${summary.totalValue}
      data-data-flow-graph-max-value=${summary.maxValue}
      data-data-flow-graph-status=${summary.status}
      data-testid=${testId}
      class="w-full overflow-auto"
      role="img"
      aria-label="데이터 흐름 그래프, 노드 ${summary.nodeCount}개, 연결 ${summary.validEdgeCount}개"
    >
      <div
        class="mb-2 grid grid-cols-3 gap-2 rounded-[var(--r-1)] bg-[var(--color-bg-elevated)] p-2"
        aria-label="데이터 흐름 요약"
      >
        <div>
          <div class="text-3xs text-[var(--color-fg-secondary)]">노드</div>
          <div class="font-mono text-sm text-[var(--color-fg-primary)]">${summary.nodeCount}</div>
        </div>
        <div>
          <div class="text-3xs text-[var(--color-fg-secondary)]">연결</div>
          <div class="font-mono text-sm text-[var(--color-fg-primary)]">
            ${summary.validEdgeCount}/${summary.edgeCount}
          </div>
        </div>
        <div>
          <div class="text-3xs text-[var(--color-fg-secondary)]">흐름</div>
          <div class="font-mono text-sm text-[var(--color-fg-primary)]">${summary.totalValue}</div>
        </div>
      </div>
      <svg
        viewBox="0 0 ${width} ${height}"
        class="w-full h-auto"
        aria-hidden="true"
      >
        <g aria-hidden="true">
          ${renderableEdges.map(({ edge: e, sourceNode: s, targetNode: t, value }) => {
            const strokeW = Math.max(1, (value / summary.maxValue) * 12)
            const sx = s.x + s.width
            const sy = s.y + s.height / 2
            const tx = t.x
            const ty = t.y + t.height / 2
            const cx1 = sx + (tx - sx) / 2
            const cx2 = sx + (tx - sx) / 2
            return html`
              <path
                key=${`${e.source}-${e.target}`}
                d="M${sx},${sy} C${cx1},${sy} ${cx2},${ty} ${tx},${ty}"
                fill="none"
                stroke=${e.color || 'var(--accent)'}
                stroke-width=${strokeW}
                opacity="0.7"
                data-flow-edge
                data-flow-edge-source=${e.source}
                data-flow-edge-target=${e.target}
                data-flow-edge-value=${value}
              />
            `
          })}
        </g>
        ${nodes.map((n) => {
          const totals = nodeTotals.get(n.id) ?? { incoming: 0, outgoing: 0 }
          return html`
            <g
              key=${n.id}
              transform="translate(${n.x}, ${n.y})"
              class="cursor-pointer"
              onClick=${() => onSelectNode?.(n.id)}
              data-flow-node-id=${n.id}
              data-flow-node-label=${n.label}
              data-flow-node-incoming=${totals.incoming}
              data-flow-node-outgoing=${totals.outgoing}
            >
              <rect
                width=${n.width}
                height=${n.height}
                rx="4"
                fill=${n.color || 'var(--color-bg-surface)'}
                stroke="var(--color-border-default)"
                stroke-width="1"
              />
              <text
                x=${n.width / 2}
                y=${n.height / 2 + 4}
                text-anchor="middle"
                class="text-xs fill-[var(--color-fg-primary)] pointer-events-none"
                style="font-size: var(--fs-10);"
              >
                ${n.label}
              </text>
            </g>
          `
        })}
      </svg>
    </figure>
  `
}
