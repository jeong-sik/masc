import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import type cytoscape from 'cytoscape'
import type { GitGraphResponse, GitGraphNode } from '../api/git-graph'
import { InlineSpinner } from './common/inline-spinner'

type CyCore = cytoscape.Core

let cytoscapePromise: Promise<typeof cytoscape> | null = null

function getCytoscape(): Promise<typeof cytoscape> {
  if (!cytoscapePromise) {
    cytoscapePromise = import('cytoscape').then(m => m.default ?? m)
  }
  return cytoscapePromise
}

// Cytoscape does not resolve CSS variables. Resolve once against :root
// with fallback to literal hex values.
const TOKEN_FALLBACKS: Record<string, string> = {
  '--color-slate-900': '#0f172a',
  '--color-slate-700': '#334155',
  '--color-slate-600': '#475569',
  '--color-slate-500': '#64748b',
  '--color-slate-400': '#94a3b8',
  '--color-slate-200': '#e2e8f0',
  '--color-status-err': '#ef4444',
  '--color-amber-bright': '#f59e0b',
  '--color-emerald': '#22c55e',
  '--color-sky-400': '#38bdf8',
  '--color-purple': '#a78bfa',
}

function resolveCssVar(token: string): string {
  const m = token.match(/^var\((--[a-z0-9-]+)\)$/i)
  const name = m ? m[1] : token.startsWith('--') ? token : null
  if (!name) return token
  if (typeof window === 'undefined' || typeof document === 'undefined') {
    return TOKEN_FALLBACKS[name] ?? token
  }
  const v = getComputedStyle(document.documentElement).getPropertyValue(name).trim()
  return v || TOKEN_FALLBACKS[name] || token
}

export function borderForStatus(status: string): string {
  if (status === 'conflict') return resolveCssVar('--color-status-err')
  if (status === 'dirty') return resolveCssVar('--color-amber-bright')
  if (status === 'current') return resolveCssVar('--color-emerald')
  return resolveCssVar('--color-slate-600')
}

export function buildElements(graph: GitGraphResponse): cytoscape.ElementDefinition[] {
  const agentParents = graph.agents.map(agent => ({
    data: {
      id: `agent:${agent.id}`,
      label: agent.label,
      kind: 'agent',
      color: agent.color,
      borderColor: agent.color,
    },
  }))

  const nodes = graph.nodes.map(node => ({
    data: {
      ...node,
      parent: node.agent_id ? `agent:${node.agent_id}` : undefined,
      color: node.color ?? resolveCssVar('--color-slate-500'),
      borderColor: borderForStatus(node.status),
      title: node.detail ?? node.branch ?? node.sha ?? node.label,
    },
    classes: [
      node.kind,
      node.status,
      node.conflict ? 'conflict' : '',
    ].filter(Boolean).join(' '),
  }))

  const nodeIds = new Set<string>([
    ...agentParents.map(n => n.data.id),
    ...nodes.map(n => n.data.id),
  ])
  const edges = graph.edges
    .filter(edge => nodeIds.has(edge.source) && nodeIds.has(edge.target))
    .map(edge => ({
      data: {
        ...edge,
        label: edge.label ?? '',
      },
      classes: edge.kind,
    }))

  return [...agentParents, ...nodes, ...edges]
}

export function stylesheet(): cytoscape.StylesheetJsonBlock[] {
  return [
    {
      selector: 'node',
      style: {
        label: 'data(label)',
        'background-color': 'data(color)',
        'border-color': 'data(borderColor)',
        'border-width': 2,
        color: resolveCssVar('--color-slate-200'),
        'font-family': 'ui-monospace, SFMono-Regular, Menlo, monospace',
        'font-size': '10px',
        'text-wrap': 'wrap',
        'text-max-width': '110px',
        'text-valign': 'center',
        'text-halign': 'center',
        shape: 'roundrectangle',
        width: 42,
        height: 30,
      },
    },
    {
      selector: 'node.commit',
      style: {
        shape: 'ellipse',
        width: 24,
        height: 24,
        label: '',
      },
    },
    {
      selector: 'node.branch',
      style: {
        shape: 'round-tag',
      },
    },
    {
      selector: 'node.conflict',
      style: {
        'border-width': 4,
        'overlay-color': resolveCssVar('--color-status-err'),
        'overlay-opacity': 0.14,
      },
    },
    {
      selector: ':parent',
      style: {
        label: 'data(label)',
        'background-color': resolveCssVar('--color-slate-900'),
        'border-color': 'data(borderColor)',
        'border-style': 'dashed',
        'border-width': 1,
        color: resolveCssVar('--color-slate-400'),
        'font-size': '10px',
        'text-valign': 'top',
        'text-halign': 'center',
        padding: '18px',
      },
    },
    {
      selector: 'edge',
      style: {
        width: 1.2,
        'line-color': resolveCssVar('--color-slate-500'),
        'target-arrow-color': resolveCssVar('--color-slate-500'),
        'target-arrow-shape': 'triangle',
        'curve-style': 'bezier',
        label: 'data(label)',
        color: resolveCssVar('--color-slate-400'),
        'font-size': '9px',
      },
    },
    {
      selector: 'edge.checked_out',
      style: {
        'line-style': 'dashed',
        'line-color': resolveCssVar('--color-sky-400'),
        'target-arrow-color': resolveCssVar('--color-sky-400'),
      },
    },
    {
      selector: 'edge.points_to',
      style: {
        'line-color': resolveCssVar('--color-purple'),
        'target-arrow-color': resolveCssVar('--color-purple'),
      },
    },
  ]
}

interface GitGraphViewProps {
  graph: GitGraphResponse
}

export function GitGraphView({ graph }: GitGraphViewProps) {
  const containerRef = useRef<HTMLDivElement | null>(null)
  const cyRef = useRef<CyCore | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [selected, setSelected] = useState<GitGraphNode | null>(null)

  useEffect(() => {
    let cancelled = false
    const container = containerRef.current
    if (!container) return undefined

    async function init() {
      try {
        setLoading(true)
        setError(null)
        const cytoscapeFn = await getCytoscape()
        if (cancelled || !container) return

        const cy = cytoscapeFn({
          container,
          elements: buildElements(graph),
          style: stylesheet(),
          layout: {
            name: 'breadthfirst',
            directed: true,
            spacingFactor: 1.35,
            animate: false,
          } as cytoscape.LayoutOptions,
          minZoom: 0.2,
          maxZoom: 2.5,
          wheelSensitivity: 0.15,
        })

        cy.on('tap', 'node', (evt: cytoscape.EventObject) => {
          const raw = evt.target.data() as GitGraphNode
          if (typeof raw.id === 'string' && !raw.id.startsWith('agent:')) {
            setSelected(raw)
          }
        })
        cyRef.current = cy
        setLoading(false)
      } catch (err) {
        if (!cancelled) {
          setError(err instanceof Error ? err.message : String(err))
          setLoading(false)
        }
      }
    }

    void init()

    return () => {
      cancelled = true
      cyRef.current?.destroy()
      cyRef.current = null
    }
  }, [graph.generated_at, graph.nodes.length, graph.edges.length])

  return html`
    <div class="grid gap-3 lg:grid-cols-[minmax(0,1fr)_18rem]">
      <div class="relative min-h-[420px] overflow-hidden rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]">
        <div ref=${containerRef} class="h-[420px] w-full" data-testid="git-graph-canvas"></div>
        ${loading ? html`
          <div class="absolute inset-0 grid place-items-center bg-[var(--panel-dark-60)] text-sm text-[var(--color-fg-muted)]">
            <span class="inline-flex items-center gap-2"><${InlineSpinner} />그래프 렌더링 중...</span>
          </div>
        ` : null}
        ${error ? html`
          <div class="absolute inset-x-4 top-4 rounded-[var(--r-1)] border border-[var(--bad-30)] bg-[var(--bad-12)] px-3 py-2 text-sm text-[var(--bad-light)]">
            ${error}
          </div>
        ` : null}
      </div>
      <aside class="min-h-[12rem] rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-3">
        ${selected ? html`
          <div class="grid gap-2 text-sm">
            <div class="text-2xs font-semibold uppercase tracking-[0.16em] text-[var(--color-fg-muted)]">선택</div>
            <div class="font-mono text-[var(--color-fg-primary)] [overflow-wrap:anywhere]">${selected.label}</div>
            <dl class="grid gap-1 text-2xs text-[var(--color-fg-muted)]">
              <div class="flex justify-between gap-3"><dt>종류</dt><dd class="text-[var(--color-fg-secondary)]">${selected.kind}</dd></div>
              <div class="flex justify-between gap-3"><dt>상태</dt><dd class="text-[var(--color-fg-secondary)]">${selected.status}</dd></div>
              ${selected.branch ? html`<div class="flex justify-between gap-3"><dt>브랜치</dt><dd class="min-w-0 text-right text-[var(--color-fg-secondary)] [overflow-wrap:anywhere]">${selected.branch}</dd></div>` : null}
              ${selected.sha ? html`<div class="flex justify-between gap-3"><dt>SHA</dt><dd class="min-w-0 text-right font-mono text-[var(--color-fg-secondary)] [overflow-wrap:anywhere]">${selected.sha}</dd></div>` : null}
            </dl>
            ${selected.detail ? html`<p class="text-xs leading-relaxed text-[var(--color-fg-muted)]">${selected.detail}</p>` : null}
          </div>
        ` : html`
          <div class="grid h-full place-items-center text-center text-sm text-[var(--color-fg-muted)]">
            노드를 선택하면 ref, commit, worktree 세부 정보가 표시됩니다.
          </div>
        `}
      </aside>
    </div>
  `
}
