// DataFlowGraph — Sankey/flow diagram for agent message/data transfer
// Kimi design system sec03 3.3.1: agent data flow visualisation.
// Zero-dependency SVG fallback (no D3).

import { html } from 'htm/preact'

interface FlowNode {
  id: string
  label: string
  x: number
  y: number
  width: number
  height: number
  color?: string
}

interface FlowEdge {
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

export function DataFlowGraph({ nodes, edges, onSelectNode, testId }: DataFlowGraphProps) {
  if (nodes.length === 0) {
    return html`
      <div
        data-testid=${testId}
        class="flex h-48 items-center justify-center text-xs text-[var(--color-fg-muted)]"
        role="img"
        aria-label="데이터 흐름 그래프"
      >
        노드가 없습니다.
      </div>
    `
  }

  const width = 600
  const height = 320
  const nodeMap = new Map(nodes.map((n) => [n.id, n]))
  const maxValue = Math.max(...edges.map((e) => e.value), 1)

  return html`
    <figure data-testid=${testId} class="w-full overflow-auto" aria-label="데이터 흐름 그래프">
      <svg
        viewBox="0 0 ${width} ${height}"
        class="w-full h-auto"
        aria-hidden="true"
      >
        <g aria-hidden="true">
          ${edges.map((e) => {
            const s = nodeMap.get(e.source)
            const t = nodeMap.get(e.target)
            if (!s || !t) return null
            const strokeW = Math.max(1, (e.value / maxValue) * 12)
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
                stroke=${e.color || 'var(--color-accent)'}
                stroke-width=${strokeW}
                opacity="0.5"
              />
            `
          })}
        </g>
        ${nodes.map((n) => html`
          <g
            key=${n.id}
            transform="translate(${n.x}, ${n.y})"
            class="cursor-pointer"
            onClick=${() => onSelectNode?.(n.id)}
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
        `)}
      </svg>
    </figure>
  `
}
