// CytoscapeFSM — Reusable interactive state machine visualization.
// Loads Cytoscape.js on demand for pan/zoom/animation.

import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import type cytoscape from 'cytoscape'
import { InlineSpinner } from './inline-spinner'

// Cytoscape's style language doesn't accept CSS custom properties directly —
// it parses `var(--x)` as an unknown literal and silently drops the property.
// Resolve to the actual computed color at stylesheet-build time.
function resolveCssVar(value: string, fallback: string): string {
  if (typeof window === 'undefined') return fallback
  const match = /^var\((--[^)]+)\)$/.exec(value.trim())
  const name = match?.[1]
  if (!name) return value
  const computed = getComputedStyle(document.documentElement)
    .getPropertyValue(name)
    .trim()
  return computed || fallback
}

function resolveNodeColor(c: { bg: string; border: string; text: string }) {
  return {
    bg: resolveCssVar(c.bg, '#1e293b'),
    border: resolveCssVar(c.border, '#475569'),
    text: resolveCssVar(c.text, '#f1f5f9'),
  }
}

// Types for graph spec (consumed by all 3 FSM builders)
export interface FsmNode {
  id: string
  label: string
  type: 'state' | 'active' | 'buffer' | 'terminal' | 'start' | 'end' | 'ok' | 'warn' | 'err' | 'dim'
  parent?: string
}

export interface FsmEdge {
  source: string
  target: string
  label?: string
  type?: 'normal' | 'error' | 'recovery' | 'cascade'
}

export interface FsmGraphSpec {
  nodes: FsmNode[]
  edges: FsmEdge[]
  activeNodeId?: string | null
  layout?: 'dagre' | 'breadthfirst' | 'grid'
  direction?: 'TB' | 'LR'
}

// Color palette matching dashboard dark theme
const NODE_COLORS: Record<FsmNode['type'], { bg: string; border: string; text: string }> = {
  state:    { bg: 'var(--slate-800)', border: 'var(--slate-600)', text: 'var(--frost-100)' },
  active:   { bg: '#065f46', border: 'var(--emerald)', text: 'var(--white-pure)' },
  buffer:   { bg: '#78350f', border: 'var(--amber-bright)', text: 'var(--white-pure)' },
  terminal: { bg: '#7f1d1d', border: 'var(--color-status-err)', text: 'var(--white-pure)' },
  start:    { bg: 'var(--slate-800)', border: '#6366f1', text: '#c7d2fe' },
  end:      { bg: 'var(--slate-800)', border: '#6b7280', text: '#9ca3af' },
  ok:       { bg: '#065f46', border: 'var(--emerald)', text: 'var(--white-pure)' },
  warn:     { bg: '#78350f', border: 'var(--amber-bright)', text: 'var(--white-pure)' },
  err:      { bg: '#7f1d1d', border: 'var(--color-status-err)', text: 'var(--white-pure)' },
  dim:      { bg: 'var(--slate-800)', border: '#374151', text: '#6b7280' },
}

const EDGE_COLORS: Record<string, string> = {
  normal: 'var(--slate-500)',
  error: 'var(--color-status-err)',
  recovery: 'var(--emerald)',
  cascade: 'var(--amber-bright)',
}

interface CytoscapeFsmProps {
  spec: FsmGraphSpec
  height?: string
  class?: string
}

// Lazy-load Cytoscape for graph-heavy panels.
type CyCore = cytoscape.Core

let cyPromise: Promise<typeof cytoscape> | null = null

function getCytoscape(): Promise<typeof cytoscape> {
  if (!cyPromise) {
    cyPromise = import('cytoscape').then(m => m.default ?? m)
  }
  return cyPromise
}

function buildElements(spec: FsmGraphSpec) {
  const nodes = spec.nodes.map(n => ({
    data: {
      id: n.id,
      label: n.label,
      nodeType: n.type,
      parent: n.parent,
    },
  }))

  const edges = spec.edges.map((e, i) => ({
    data: {
      id: `e-${i}`,
      source: e.source,
      target: e.target,
      label: e.label ?? '',
      edgeType: e.type ?? 'normal',
    },
  }))

  return [...nodes, ...edges]
}

function buildStylesheet() {
  const styles: Array<{ selector: string; style: Record<string, unknown> }> = [
    {
      selector: 'node',
      style: {
        label: 'data(label)',
        'text-valign': 'center',
        'text-halign': 'center',
        'font-size': '11px',
        'font-family': 'ui-monospace, SFMono-Regular, Menlo, monospace',
        color: resolveCssVar('var(--frost-100)', '#cbd5e1'),
        'background-color': resolveCssVar('var(--slate-800)', '#1e293b'),
        'border-width': 2,
        'border-color': resolveCssVar('var(--slate-600)', '#475569'),
        shape: 'roundrectangle',
        // 'auto' sizes the node to its label bbox; 'label' was deprecated.
        width: 'auto',
        height: 'auto',
        padding: '10px',
        'text-wrap': 'wrap',
        'text-max-width': '120px',
      },
    },
    {
      selector: 'edge',
      style: {
        'curve-style': 'bezier',
        'target-arrow-shape': 'triangle',
        'target-arrow-color': resolveCssVar('var(--slate-500)', '#64748b'),
        'line-color': resolveCssVar('var(--slate-500)', '#64748b'),
        width: 1.5,
        label: 'data(label)',
        'font-size': '9px',
        'font-family': 'ui-monospace, SFMono-Regular, Menlo, monospace',
        color: resolveCssVar('var(--slate-400)', '#94a3b8'),
        'text-rotation': 'autorotate',
        'text-margin-y': -8,
        'text-background-color': resolveCssVar('var(--panel-dark)', '#0f172a'),
        'text-background-opacity': 0.85,
        'text-background-padding': '2px',
        'text-background-shape': 'roundrectangle',
      },
    },
    {
      selector: ':parent',
      style: {
        'background-color': resolveCssVar('var(--panel-dark)', '#0f172a'),
        'border-color': '#334155',
        'border-width': 1,
        'border-style': 'dashed',
        'text-valign': 'top',
        'text-halign': 'center',
        padding: '16px',
        'font-size': '10px',
        color: resolveCssVar('var(--slate-500)', '#64748b'),
      },
    },
  ]

  // Node type-specific styles
  for (const [type, raw] of Object.entries(NODE_COLORS)) {
    const colors = resolveNodeColor(raw)
    styles.push({
      selector: `node[nodeType="${type}"]`,
      style: {
        'background-color': colors.bg,
        'border-color': colors.border,
        color: colors.text,
      },
    })
  }

  // Active node emphasis. Cytoscape core has no `shadow-*` properties — they
  // were silently dropped before. Use a thicker border instead, which is
  // visually unambiguous and survives layout/zoom without canvas overhead.
  styles.push({
    selector: 'node[nodeType="active"]',
    style: {
      'border-width': 4,
    },
  })

  // Edge type styles
  for (const [type, raw] of Object.entries(EDGE_COLORS)) {
    const color = resolveCssVar(raw, '#64748b')
    styles.push({
      selector: `edge[edgeType="${type}"]`,
      style: {
        'line-color': color,
        'target-arrow-color': color,
      },
    })
  }

  return styles
}

export function CytoscapeFsm({ spec, height = '280px', class: className = '' }: CytoscapeFsmProps) {
  const containerRef = useRef<HTMLDivElement | null>(null)
  const cyRef = useRef<CyCore | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  // Initialize Cytoscape instance
  useEffect(() => {
    let cancelled = false
    const container = containerRef.current
    if (!container) return undefined

    const init = async () => {
      try {
        const cytoscapeFn = await getCytoscape()
        if (cancelled) return

        const cy = cytoscapeFn({
          container,
          elements: buildElements(spec),
          style: buildStylesheet() as cytoscape.StylesheetJsonBlock[],
          layout: {
            name: 'breadthfirst',
            directed: true,
            spacingFactor: 1.4,
            avoidOverlap: true,
            nodeDimensionsIncludeLabels: true,
          } as cytoscape.LayoutOptions,
          minZoom: 0.3,
          maxZoom: 3,
          // wheelSensitivity intentionally left at default (1).
          // Cytoscape warns against custom values because zoom feel
          // depends on hardware (mouse vs trackpad) and OS scroll
          // settings; the previous 0.3 made trackpads feel sluggish.
          boxSelectionEnabled: false,
          selectionType: 'single',
          userPanningEnabled: true,
          userZoomingEnabled: true,
        })

        cyRef.current = cy

        // Fit after layout settles
        cy.on('layoutstop', () => {
          cy.fit(undefined, 24)
        })

        // Hover tooltip via title
        cy.on('mouseover', 'node', (evt: cytoscape.EventObject) => {
          const node = evt.target
          container.title = node.data('label') as string
        })
        cy.on('mouseout', 'node', () => {
          container.title = ''
        })

        setLoading(false)
      } catch (err) {
        if (cancelled) return
        setError(err instanceof Error ? err.message : 'Cytoscape 초기화 실패')
        setLoading(false)
      }
    }

    void init()

    return () => {
      cancelled = true
      if (cyRef.current) {
        cyRef.current.destroy()
        cyRef.current = null
      }
    }
  }, []) // mount only

  // Update elements when spec changes (without full re-init)
  useEffect(() => {
    const cy = cyRef.current
    if (!cy || loading) return

    cy.batch(() => {
      cy.elements().remove()
      cy.add(buildElements(spec))
    })

    const layout = cy.layout({
      name: 'breadthfirst',
      directed: true,
      spacingFactor: 1.4,
      avoidOverlap: true,
      nodeDimensionsIncludeLabels: true,
      animate: true,
      animationDuration: 300,
    } as cytoscape.LayoutOptions)
    layout.run()
  }, [spec, loading])

  if (error) {
    return html`<div class="text-2xs text-[var(--color-fg-disabled)]">${error}</div>`
  }

  return html`
    <div class=${`relative rounded border border-[var(--white-8)] bg-[rgba(9,12,20,0.7)] overflow-hidden ${className}`.trim()}>
      ${loading ? html`
        <div class="absolute inset-0 flex items-center justify-center text-2xs text-[var(--color-fg-disabled)]">
          <${InlineSpinner} class="mr-2" />
          그래프 로딩중
        </div>
      ` : null}
      <div
        ref=${containerRef}
        style=${{ height, width: '100%' }}
      ></div>
    </div>
  `
}
