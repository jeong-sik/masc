// CytoscapeFSM — Reusable interactive state machine visualization.
// Loads Cytoscape.js on demand for pan/zoom/animation.

import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import type cytoscape from 'cytoscape'
import { InlineSpinner } from './inline-spinner'

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

// Cytoscape's style parser does not resolve CSS variables — `var(--x)`
// strings are rejected. Resolve once per render against `:root` and
// pass literal hex/rgb values into the stylesheet.
const TOKEN_FALLBACKS: Record<string, string> = {
  '--slate-800': '#1e293b',
  '--slate-600': '#475569',
  '--slate-500': '#64748b',
  '--slate-400': '#94a3b8',
  '--frost-100': '#e2e8f0',
  '--emerald': '#22c55e',
  '--amber-bright': '#f59e0b',
  '--color-status-err': '#ef4444',
  '--white-pure': '#ffffff',
  '--panel-dark': '#0f172a',
}

function resolveCssVar(token: string): string {
  // token may be the bare name "--frost-100" or a "var(--frost-100)" wrapper.
  const m = token.match(/^var\((--[a-z0-9-]+)\)$/i)
  const name = m ? m[1] : token.startsWith('--') ? token : null
  if (!name) return token
  if (typeof window === 'undefined' || typeof document === 'undefined') {
    return TOKEN_FALLBACKS[name] ?? token
  }
  const v = getComputedStyle(document.documentElement).getPropertyValue(name).trim()
  return v || TOKEN_FALLBACKS[name] || token
}

// Color palette matching dashboard dark theme. Values are resolved
// lazily inside buildStylesheet/buildNodeColors so that token changes
// (theme switch) propagate on next render.
const NODE_COLOR_TOKENS: Record<FsmNode['type'], { bg: string; border: string; text: string }> = {
  state:    { bg: '--slate-800', border: '--slate-600', text: '--frost-100' },
  active:   { bg: '#065f46',     border: '--emerald',   text: '--white-pure' },
  buffer:   { bg: '#78350f',     border: '--amber-bright', text: '--white-pure' },
  terminal: { bg: '#7f1d1d',     border: '--color-status-err', text: '--white-pure' },
  start:    { bg: '--slate-800', border: '#6366f1',     text: '#c7d2fe' },
  end:      { bg: '--slate-800', border: '#6b7280',     text: '#9ca3af' },
  ok:       { bg: '#065f46',     border: '--emerald',   text: '--white-pure' },
  warn:     { bg: '#78350f',     border: '--amber-bright', text: '--white-pure' },
  err:      { bg: '#7f1d1d',     border: '--color-status-err', text: '--white-pure' },
  dim:      { bg: '--slate-800', border: '#374151',     text: '#6b7280' },
}

const EDGE_COLOR_TOKENS: Record<string, string> = {
  normal: '--slate-500',
  error: '--color-status-err',
  recovery: '--emerald',
  cascade: '--amber-bright',
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
        color: resolveCssVar('--frost-100'),
        'background-color': resolveCssVar('--slate-800'),
        'border-width': 2,
        'border-color': resolveCssVar('--slate-600'),
        shape: 'roundrectangle',
        width: 'label',
        height: 'label',
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
        'target-arrow-color': resolveCssVar('--slate-500'),
        'line-color': resolveCssVar('--slate-500'),
        width: 1.5,
        label: 'data(label)',
        'font-size': '9px',
        'font-family': 'ui-monospace, SFMono-Regular, Menlo, monospace',
        color: resolveCssVar('--slate-400'),
        'text-rotation': 'autorotate',
        'text-margin-y': -8,
        'text-background-color': resolveCssVar('--panel-dark'),
        'text-background-opacity': 0.85,
        'text-background-padding': '2px',
        'text-background-shape': 'roundrectangle',
      },
    },
    {
      selector: ':parent',
      style: {
        'background-color': resolveCssVar('--panel-dark'),
        'border-color': '#334155',
        'border-width': 1,
        'border-style': 'dashed',
        'text-valign': 'top',
        'text-halign': 'center',
        padding: '16px',
        'font-size': '10px',
        color: resolveCssVar('--slate-500'),
      },
    },
  ]

  // Node type-specific styles
  for (const [type, tokens] of Object.entries(NODE_COLOR_TOKENS)) {
    styles.push({
      selector: `node[nodeType="${type}"]`,
      style: {
        'background-color': resolveCssVar(tokens.bg),
        'border-color': resolveCssVar(tokens.border),
        color: resolveCssVar(tokens.text),
      },
    })
  }

  // Active node emphasis. Cytoscape has no `shadow-*` node properties
  // (only `text-shadow-*`); use the supported `overlay-*` family plus
  // a thicker border to convey "active" without warnings.
  styles.push({
    selector: 'node[nodeType="active"]',
    style: {
      'border-width': 4,
      'overlay-color': resolveCssVar('--emerald'),
      'overlay-opacity': 0.18,
      'overlay-padding': 6,
    },
  })

  // Edge type styles
  for (const [type, token] of Object.entries(EDGE_COLOR_TOKENS)) {
    const color = resolveCssVar(token)
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
          wheelSensitivity: 0.3,
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
