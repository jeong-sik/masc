import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import {
  MgEntry,
  MgLegend,
  MgNodeCard,
  type MemoryKeeper,
  type MemoryNode,
  type MemoryNodeType,
} from './memory-primitives'

export interface MemoryLensEdge {
  readonly source: string
  readonly target: string
  readonly rel: string
}

export interface MemoryLensProps {
  readonly nodes: Readonly<Record<string, MemoryNode>>
  readonly edges: ReadonlyArray<MemoryLensEdge>
  readonly nodeTypes: Readonly<Record<string, MemoryNodeType>>
  readonly keepers?: Readonly<Record<string, MemoryKeeper>>
  readonly start?: string
  readonly W?: number
  readonly H?: number
  readonly onSelectNode?: (id: string) => void
  readonly ariaLabel?: string
  readonly testId?: string
}

interface PlacedSatellite {
  readonly id: string
  readonly rel: string
  readonly x: number
  readonly y: number
}

export function MemoryLens({
  nodes,
  edges,
  nodeTypes,
  keepers = {},
  start,
  W = 600,
  H = 540,
  onSelectNode,
  ariaLabel = '메모리 렌즈',
  testId,
}: MemoryLensProps) {
  const nodeIds = Object.keys(nodes)
  const firstId = start ?? nodeIds[0]
  const [anchor, setAnchor] = useState<string>(firstId ?? '')

  useEffect(() => {
    if (start && nodes[start]) {
      setAnchor(start)
    } else if (!nodes[anchor] && nodeIds.length > 0) {
      setAnchor(nodeIds[0] ?? '')
    }
  }, [start, nodes, anchor, nodeIds])

  if (nodeIds.length === 0 || !nodes[anchor]) {
    return html`
      <div
        class="mg-board"
        data-testid=${testId}
        aria-label=${ariaLabel}
      >
        <${MgEntry} extra="1-hop 렌즈 · 노드 클릭 = 재중심" />
        <div class="flex items-center justify-center text-xs text-[var(--color-fg-muted)]" style=${{ height: `${H}px` }}>
          연결할 메모리 노드가 없습니다.
        </div>
      </div>
    `
  }

  const cx = W / 2
  const cy = H / 2 + 4
  const r = Math.min(W, H) * 0.37

  const sats = edges
    .filter((edge) => edge.source === anchor || edge.target === anchor)
    .map((edge) => ({
      id: edge.source === anchor ? edge.target : edge.source,
      rel: edge.rel,
    }))
    .filter((s) => Boolean(nodes[s.id]) && Boolean(nodeTypes[nodes[s.id]!.type]))

  const placed: PlacedSatellite[] = sats.map((s, i) => {
    const ang = (-90 + i * (360 / sats.length)) * (Math.PI / 180)
    return {
      ...s,
      x: cx + Math.cos(ang) * r,
      y: cy + Math.sin(ang) * r,
    }
  })

  function handleSelect(id: string) {
    setAnchor(id)
    onSelectNode?.(id)
  }

  return html`
    <div class="mg-board" data-testid=${testId} aria-label=${ariaLabel}>
      <${MgEntry} extra="1-hop 렌즈 · 노드 클릭 = 재중심" />
      <div class="mg-lens" style=${{ width: W, height: H }}>
        <svg
          class="mg-edges"
          viewBox=${`0 0 ${W} ${H}`}
          width=${W}
          height=${H}
          role="img"
          aria-label=${`${ariaLabel} SVG edges`}
        >
          ${placed.map((s) => {
            const type = nodeTypes[nodes[s.id]!.type]
            return html`
              <line
                key=${s.id}
                x1=${cx}
                y1=${cy}
                x2=${s.x}
                y2=${s.y}
                stroke=${type?.c ?? 'var(--text-dim)'}
                stroke-width="1.4"
                stroke-opacity="0.5"
              />
            `
          })}
        </svg>
        ${placed.map((s) => {
          const lx = cx + (s.x - cx) * 0.5
          const ly = cy + (s.y - cy) * 0.5
          return html`
            <span
              key=${`l-${s.id}`}
              class="mg-edge-lbl mono"
              style=${{ left: lx, top: ly }}
            >
              ${s.rel}
            </span>
          `
        })}
        <div class="mg-pos" style=${{ left: cx, top: cy }}>
          <${MgNodeCard}
            node=${nodes[anchor]}
            type=${nodeTypes[nodes[anchor].type]}
            keepers=${keepers}
            anchor
          />
        </div>
        ${placed.map((s) => html`
          <div key=${s.id} class="mg-pos" style=${{ left: s.x, top: s.y }}>
            <${MgNodeCard}
              node=${nodes[s.id]}
              type=${nodeTypes[nodes[s.id]!.type]}
              keepers=${keepers}
              satellite
              onClick=${() => handleSelect(s.id)}
            />
          </div>
        `)}
      </div>
      <${MgLegend} nodeTypes=${nodeTypes} />
    </div>
  `
}
