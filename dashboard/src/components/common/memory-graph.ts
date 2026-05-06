// MemoryGraph — Obsidian-style node-edge graph for long-term memory
// Kimi design system sec03 3.1.1: agent memory node-edge graph.
// Zero-dependency SVG fallback (no D3).

import { html } from 'htm/preact'
import { StatusChip } from './status-chip'

export interface MemoryNode {
  id: string
  label: string
  x: number
  y: number
  color?: string
}

export interface MemoryEdge {
  source: string
  target: string
  label?: string
}

interface MemoryGraphProps {
  nodes: MemoryNode[]
  edges: MemoryEdge[]
  onSelectNode?: (id: string) => void
  width?: number
  height?: number
  ariaLabel?: string
  testId?: string
}

export interface MemoryGraphSummary {
  readonly nodeCount: number
  readonly edgeCount: number
  readonly linkedEdgeCount: number
  readonly danglingEdgeCount: number
  readonly isolatedNodeCount: number
  readonly degreeByNode: ReadonlyMap<string, number>
}

export function summarizeMemoryGraph(
  nodes: ReadonlyArray<MemoryNode>,
  edges: ReadonlyArray<MemoryEdge>,
): MemoryGraphSummary {
  const nodeIds = new Set(nodes.map(node => node.id))
  const degreeByNode = new Map(nodes.map(node => [node.id, 0]))
  let linkedEdgeCount = 0

  for (const edge of edges) {
    if (!nodeIds.has(edge.source) || !nodeIds.has(edge.target)) continue
    linkedEdgeCount += 1
    degreeByNode.set(edge.source, (degreeByNode.get(edge.source) ?? 0) + 1)
    degreeByNode.set(edge.target, (degreeByNode.get(edge.target) ?? 0) + 1)
  }

  let isolatedNodeCount = 0
  for (const degree of degreeByNode.values()) {
    if (degree === 0) isolatedNodeCount += 1
  }

  return {
    nodeCount: nodes.length,
    edgeCount: edges.length,
    linkedEdgeCount,
    danglingEdgeCount: edges.length - linkedEdgeCount,
    isolatedNodeCount,
    degreeByNode,
  }
}

function graphAriaLabel(label: string, summary: MemoryGraphSummary): string {
  const dangling =
    summary.danglingEdgeCount > 0 ? `, ${summary.danglingEdgeCount} dangling edges ignored` : ''
  const isolated =
    summary.isolatedNodeCount > 0 ? `, ${summary.isolatedNodeCount} isolated nodes` : ''
  return `${label}: ${summary.nodeCount} nodes, ${summary.linkedEdgeCount} linked edges${dangling}${isolated}`
}

function nodeAriaLabel(node: MemoryNode, degree: number): string {
  return `${node.label}, ${degree} ${degree === 1 ? 'connection' : 'connections'}`
}

function edgeMidpoint(source: MemoryNode, target: MemoryNode): { readonly x: number; readonly y: number } {
  return {
    x: (source.x + target.x) / 2,
    y: (source.y + target.y) / 2,
  }
}

function handleNodeKeyDown(e: KeyboardEvent, nodeId: string, onSelectNode?: (id: string) => void): void {
  if (!onSelectNode) return
  if (e.key !== 'Enter' && e.key !== ' ') return
  e.preventDefault()
  onSelectNode(nodeId)
}

export function MemoryGraph({
  nodes,
  edges,
  onSelectNode,
  width = 400,
  height = 300,
  ariaLabel = '메모리 그래프',
  testId,
}: MemoryGraphProps) {
  const summary = summarizeMemoryGraph(nodes, edges)

  if (nodes.length === 0) {
    return html`
      <div
        data-testid=${testId}
        class="flex h-48 items-center justify-center text-xs text-[var(--color-fg-muted)]"
        role="img"
        aria-label=${ariaLabel}
        style=${{ height: `${height}px` }}
      >
        노드가 없습니다.
      </div>
    `
  }

  const nodeMap = new Map(nodes.map((n) => [n.id, n]))
  const visibleEdges = edges
    .map((edge) => ({ edge, source: nodeMap.get(edge.source), target: nodeMap.get(edge.target) }))
    .filter((entry): entry is { edge: MemoryEdge; source: MemoryNode; target: MemoryNode } =>
      entry.source !== undefined && entry.target !== undefined,
    )

  return html`
    <figure
      data-memory-graph
      data-testid=${testId}
      class="w-full overflow-auto"
      aria-label=${ariaLabel}
    >
      <figcaption class="mb-2 flex flex-wrap items-center gap-1.5 text-xs text-[var(--color-fg-muted)]">
        <span class="mr-1 font-medium text-[var(--color-fg-primary)]">${ariaLabel}</span>
        <${StatusChip} tone="neutral" uppercase=${false}>nodes ${summary.nodeCount}</${StatusChip}>
        <${StatusChip} tone="info" uppercase=${false}>edges ${summary.linkedEdgeCount}</${StatusChip}>
        ${summary.isolatedNodeCount > 0
          ? html`<${StatusChip} tone="warn" uppercase=${false}>isolated ${summary.isolatedNodeCount}</${StatusChip}>`
          : null}
        ${summary.danglingEdgeCount > 0
          ? html`<${StatusChip} tone="bad" uppercase=${false}>dangling ${summary.danglingEdgeCount}</${StatusChip}>`
          : null}
      </figcaption>
      <svg
        role=${onSelectNode ? 'group' : 'img'}
        aria-label=${graphAriaLabel(ariaLabel, summary)}
        viewBox="0 0 ${width} ${height}"
        class="w-full h-auto"
      >
        <g aria-hidden="true">
          ${visibleEdges.map(({ edge, source, target }) => {
            const midpoint = edgeMidpoint(source, target)
            return html`
              <g key=${`${edge.source}-${edge.target}`}>
                <line
                  x1=${source.x} y1=${source.y} x2=${target.x} y2=${target.y}
                  stroke="var(--color-border-default)"
                  stroke-width="1"
                />
                ${edge.label
                  ? html`
                      <text
                        x=${midpoint.x}
                        y=${midpoint.y - 4}
                        text-anchor="middle"
                        class="pointer-events-none text-2xs fill-[var(--color-fg-muted)]"
                        style="font-size: var(--fs-10);"
                        data-memory-graph-edge-label=${edge.label}
                      >
                        ${edge.label}
                      </text>
                    `
                  : null}
              </g>
            `
          })}
        </g>
        ${nodes.map((node) => {
          const degree = summary.degreeByNode.get(node.id) ?? 0
          return html`
            <g
              key=${node.id}
              transform="translate(${node.x}, ${node.y})"
              class=${onSelectNode ? 'cursor-pointer' : ''}
              onClick=${() => onSelectNode?.(node.id)}
              onKeyDown=${(event: KeyboardEvent) => handleNodeKeyDown(event, node.id, onSelectNode)}
              role=${onSelectNode ? 'button' : undefined}
              tabindex=${onSelectNode ? 0 : undefined}
              aria-label=${nodeAriaLabel(node, degree)}
              data-memory-graph-node=${node.id}
              data-memory-graph-degree=${degree}
            >
              <circle
                r="16"
                fill=${node.color || 'var(--color-bg-surface)'}
                stroke="var(--color-border-default)"
                stroke-width="1"
              />
              <text
                text-anchor="middle"
                dy="4"
                class="text-xs fill-[var(--color-fg-primary)] pointer-events-none"
                style="font-size: var(--fs-10);"
              >
                ${node.label.slice(0, 3)}
              </text>
            </g>
          `
        })}
      </svg>
    </figure>
  `
}
