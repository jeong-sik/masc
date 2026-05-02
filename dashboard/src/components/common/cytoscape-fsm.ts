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
  '--color-bg-2': '#1a1815',
  '--color-bg-3': '#211e1a',
  '--color-bg-4': '#2a2621',
  '--color-line-1': '#2a2520',
  '--color-line-2': '#3a332c',
  '--color-fg-3': '#7a7065',
  '--color-fg-4': '#4a453e',
  '--color-frost-100': '#e2e8f0',
  '--color-white-pure': '#ffffff',
  '--color-emerald': '#22c55e',
  '--color-amber-bright': '#f59e0b',
  '--color-err': '#c46a5a',
  '--color-indigo': '#818cf8',
  '--color-cyan': '#22d3ee',
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
  state:    { bg: '--color-bg-3', border: '--color-line-2', text: '--color-frost-100' },
  active:   { bg: '#065f46',     border: '--color-emerald',   text: '--color-white-pure' },
  buffer:   { bg: '#78350f',     border: '--color-amber-bright', text: '--color-white-pure' },
  terminal: { bg: '#7f1d1d',     border: '--color-err', text: '--color-white-pure' },
  start:    { bg: '--color-bg-3', border: '--color-indigo',     text: '--color-frost-100' },
  end:      { bg: '--color-bg-3', border: '--color-fg-3',     text: '--color-fg-4' },
  ok:       { bg: '#065f46',     border: '--color-emerald',   text: '--color-white-pure' },
  warn:     { bg: '#78350f',     border: '--color-amber-bright', text: '--color-white-pure' },
  err:      { bg: '#7f1d1d',     border: '--color-err', text: '--color-white-pure' },
  dim:      { bg: '--color-bg-3', border: '--color-line-1',     text: '--color-fg-3' },
}

const EDGE_COLOR_TOKENS: Record<string, string> = {
  normal: '--color-fg-3',
  error: '--color-err',
  recovery: '--color-emerald',
  cascade: '--color-amber-bright',
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

// Width/height sizing for label-fit nodes. Replaces the deprecated
// `width: 'label'` / `height: 'label'` (cytoscape 3.33+ emits a
// per-render warning). Estimates from label length using the node's
// monospace 11px font and respecting the 120px text-max-width cap.
const NODE_FONT_PX_PER_CHAR = 7   // 11px ui-monospace ≈ 7px wide
const NODE_PADDING_PX = 10
const NODE_TEXT_MAX_WIDTH_PX = 120
const NODE_LINE_HEIGHT_PX = 16
const NODE_MIN_WIDTH = 64
const NODE_MIN_HEIGHT = 36

function nodeWidth(ele: { data: (key: string) => unknown }): number {
  const label = String(ele.data('label') ?? '')
  const text = label.length * NODE_FONT_PX_PER_CHAR
  const fit = Math.min(NODE_TEXT_MAX_WIDTH_PX, text)
  return Math.max(NODE_MIN_WIDTH, fit + NODE_PADDING_PX * 2)
}

function nodeHeight(ele: { data: (key: string) => unknown }): number {
  const label = String(ele.data('label') ?? '')
  const text = label.length * NODE_FONT_PX_PER_CHAR
  const lines = Math.max(1, Math.ceil(text / NODE_TEXT_MAX_WIDTH_PX))
  return Math.max(NODE_MIN_HEIGHT, lines * NODE_LINE_HEIGHT_PX + NODE_PADDING_PX * 2)
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
        'background-color': resolveCssVar('--color-bg-4'),
        'border-width': 2,
        'border-color': resolveCssVar('--color-line-2'),
        shape: 'roundrectangle',
        width: nodeWidth,
        height: nodeHeight,
        padding: `${NODE_PADDING_PX}px`,
        'text-wrap': 'wrap',
        'text-max-width': `${NODE_TEXT_MAX_WIDTH_PX}px`,
      },
    },
    {
      selector: 'edge',
      style: {
        'curve-style': 'bezier',
        'target-arrow-shape': 'triangle',
        'target-arrow-color': resolveCssVar('--color-fg-3'),
        'line-color': resolveCssVar('--color-fg-3'),
        width: 1.5,
        label: 'data(label)',
        'font-size': '9px',
        'font-family': 'ui-monospace, SFMono-Regular, Menlo, monospace',
        color: resolveCssVar('--color-fg-4'),
        'text-rotation': 'autorotate',
        'text-margin-y': -8,
        'text-background-color': resolveCssVar('--color-bg-2'),
        'text-background-opacity': 0.85,
        'text-background-padding': '2px',
        'text-background-shape': 'roundrectangle',
      },
    },
    {
      selector: ':parent',
      style: {
        'background-color': resolveCssVar('--color-bg-2'),
        'border-color': resolveCssVar('--color-line-2'),
        'border-width': 1,
        'border-style': 'dashed',
        'text-valign': 'top',
        'text-halign': 'center',
        padding: '16px',
        'font-size': '10px',
        color: resolveCssVar('--color-fg-3'),
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
          // wheelSensitivity is intentionally left at the cytoscape
          // default (1). Cytoscape warns against custom values because
          // the natural zoom feel depends on hardware (mouse vs.
          // trackpad) and OS scroll settings — the previous 0.3 made
          // trackpads feel sluggish.
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
    <div class=${`relative rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] overflow-hidden ${className}`.trim()}>
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
