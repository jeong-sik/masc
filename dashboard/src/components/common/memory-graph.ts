// MemoryGraph — Obsidian-style node-edge graph for long-term memory
// Kimi design system sec03 3.1.1: agent memory node-edge graph.
// Zero-dependency SVG fallback (no D3).

import { html } from 'htm/preact'

interface MemoryNode {
  id: string
  label: string
  x: number
  y: number
  color?: string
}

interface MemoryEdge {
  source: string
  target: string
  label?: string
}

interface MemoryGraphProps {
  nodes: MemoryNode[]
  edges: MemoryEdge[]
  onSelectNode?: (id: string) => void
  testId?: string
}

export function MemoryGraph({ nodes, edges, onSelectNode, testId }: MemoryGraphProps) {
  if (nodes.length === 0) {
    return html`
      <div
        data-testid=${testId}
        class="flex h-48 items-center justify-center text-xs text-[var(--color-fg-muted)]"
        role="img"
        aria-label="메모리 그래프"
      >
        노드가 없습니다.
      </div>
    `
  }

  const width = 400
  const height = 300
  const nodeMap = new Map(nodes.map((n) => [n.id, n]))

  return html`
    <figure data-testid=${testId} class="w-full overflow-auto" aria-label="메모리 그래프">
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
            return html`
              <line
                key=${`${e.source}-${e.target}`}
                x1=${s.x} y1=${s.y} x2=${t.x} y2=${t.y}
                stroke="var(--color-border-default)"
                stroke-width="1"
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
            <circle
              r="16"
              fill=${n.color || 'var(--color-bg-surface)'}
              stroke="var(--color-border-default)"
              stroke-width="1"
            />
            <text
              text-anchor="middle"
              dy="4"
              class="text-xs fill-[var(--color-fg-primary)] pointer-events-none"
              style="font-size: var(--fs-10);"
            >
              ${n.label.slice(0, 3)}
            </text>
          </g>
        `)}
      </svg>
    </figure>
  `
}
