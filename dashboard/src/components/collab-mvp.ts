import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import type cytoscape from 'cytoscape'
import { GitBranch, ListChecks, Radio, UsersRound } from 'lucide-preact'
import { agents, boardPosts, tasks } from '../store'
import {
  buildCollabMvpProjection,
  COLLAB_MVP_EVENT_SEMANTICS,
  COLLAB_MVP_STACK,
  type CollabGitGraphSpec,
  type CollabMvpStackStatus,
  type CollabTodoClaim,
  type CollabTurnQueueEntry,
} from '../collab-mvp-contract'
import { InlineSpinner } from './common/inline-spinner'

type CyCore = cytoscape.Core

let cytoscapePromise: Promise<typeof cytoscape> | null = null

function getCytoscape(): Promise<typeof cytoscape> {
  if (!cytoscapePromise) {
    cytoscapePromise = import('cytoscape').then(m => m.default ?? m)
  }
  return cytoscapePromise
}

function toneForStackStatus(status: CollabMvpStackStatus): string {
  switch (status) {
    case 'installed':
      return 'border-ok/35 bg-ok/10 text-ok'
    case 'observed':
      return 'border-accent/25 bg-[var(--accent-10)] text-accent'
    case 'contract':
      return 'border-warn/30 bg-warn/10 text-warn'
  }
}

function stateTone(state: string): string {
  switch (state) {
    case 'running':
    case 'claimed':
      return 'border-ok/35 bg-ok/10 text-ok'
    case 'verification':
    case 'waiting':
      return 'border-warn/30 bg-warn/10 text-warn'
    case 'unclaimed':
      return 'border-accent/25 bg-[var(--accent-10)] text-accent'
    default:
      return 'border-card-border/50 bg-white/[0.04] text-text-muted'
  }
}

function MetricTile({
  icon,
  label,
  value,
}: {
  icon: unknown
  label: string
  value: number | string
}) {
  return html`
    <div class="min-w-0 rounded border border-card-border/70 bg-black/15 px-3 py-2">
      <div class="flex items-center gap-2 text-3xs font-medium uppercase text-text-dim">
        <${icon as never} size=${14} />
        <span class="truncate">${label}</span>
      </div>
      <div class="mt-1 text-xl font-semibold text-text-strong">${value}</div>
    </div>
  `
}

function graphElements(graph: CollabGitGraphSpec): cytoscape.ElementDefinition[] {
  return [
    ...graph.nodes.map(node => ({
      data: {
        id: node.id,
        label: node.label,
        nodeType: node.type,
        parent: node.parent,
        source: node.source,
      },
    })),
    ...graph.edges.map(edge => ({
      data: {
        id: edge.id,
        source: edge.source,
        target: edge.target,
        label: edge.label ?? '',
      },
    })),
  ]
}

function graphKey(graph: CollabGitGraphSpec): string {
  return [
    graph.source,
    ...graph.nodes.map(node => `${node.id}/${node.label}/${node.parent ?? ''}`),
    ...graph.edges.map(edge => `${edge.source}>${edge.target}:${edge.label ?? ''}`),
  ].join('|')
}

function graphStylesheet(): cytoscape.StylesheetJsonBlock[] {
  return [
    {
      selector: 'node',
      style: {
        label: 'data(label)',
        'font-family': 'ui-monospace, SFMono-Regular, Menlo, monospace',
        'font-size': '10px',
        color: '#dbeafe',
        'text-valign': 'center',
        'text-halign': 'center',
        'text-wrap': 'wrap',
        'text-max-width': '110px',
        'background-color': '#1e293b',
        'border-color': '#475569',
        'border-width': 1,
        width: 48,
        height: 30,
      },
    },
    {
      selector: 'node[nodeType="repo"]',
      style: {
        shape: 'roundrectangle',
        'background-color': '#0f172a',
        'border-color': '#334155',
        'border-style': 'dashed',
        padding: '18px',
        'font-size': '11px',
        color: '#94a3b8',
        'text-valign': 'top',
      },
    },
    {
      selector: 'node[nodeType="main"]',
      style: {
        shape: 'ellipse',
        'background-color': '#1d4ed8',
        'border-color': '#93c5fd',
        color: '#eff6ff',
      },
    },
    {
      selector: 'node[nodeType="branch"]',
      style: {
        shape: 'roundrectangle',
        'background-color': '#065f46',
        'border-color': '#34d399',
        color: '#ecfdf5',
        width: 92,
      },
    },
    {
      selector: 'node[nodeType="task"]',
      style: {
        shape: 'tag',
        'background-color': '#78350f',
        'border-color': '#f59e0b',
        color: '#fffbeb',
      },
    },
    {
      selector: 'node[source="coordination_fallback"]',
      style: {
        'border-style': 'dotted',
      },
    },
    {
      selector: 'edge',
      style: {
        width: 1.5,
        'curve-style': 'bezier',
        'target-arrow-shape': 'triangle',
        'line-color': '#64748b',
        'target-arrow-color': '#64748b',
        label: 'data(label)',
        'font-size': '9px',
        color: '#94a3b8',
        'text-background-color': '#0f172a',
        'text-background-opacity': 0.8,
        'text-background-padding': '2px',
      },
    },
  ]
}

function CollabGitGraph({ graph }: { graph: CollabGitGraphSpec }) {
  const containerRef = useRef<HTMLDivElement | null>(null)
  const cyRef = useRef<CyCore | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const key = graphKey(graph)

  useEffect(() => {
    let cancelled = false
    const container = containerRef.current
    if (!container) return undefined

    setLoading(true)
    setError(null)

    getCytoscape()
      .then(cyFactory => {
        if (cancelled) return
        cyRef.current?.destroy()
        const cy = cyFactory({
          container,
          elements: graphElements(graph),
          style: graphStylesheet(),
          layout: {
            name: 'breadthfirst',
            directed: true,
            padding: 18,
            spacingFactor: 1.15,
          },
          userZoomingEnabled: true,
          userPanningEnabled: true,
          minZoom: 0.4,
          maxZoom: 2,
        })
        cyRef.current = cy
        setLoading(false)
      })
      .catch(err => {
        if (cancelled) return
        setError(err instanceof Error ? err.message : String(err))
        setLoading(false)
      })

    return () => {
      cancelled = true
      cyRef.current?.destroy()
      cyRef.current = null
    }
  }, [key])

  return html`
    <div class="relative min-h-[320px] overflow-hidden rounded border border-card-border/70 bg-[#07101d]">
      <div
        ref=${containerRef}
        role="img"
        aria-label="Collaboration Git graph"
        class="h-[320px] w-full"
      ></div>
      ${loading ? html`
        <div class="absolute inset-0 flex items-center justify-center bg-black/20">
          <${InlineSpinner} label="graph" />
        </div>
      ` : null}
      ${error ? html`
        <div class="absolute inset-x-3 bottom-3 rounded border border-bad/30 bg-bad/10 px-3 py-2 text-xs text-bad">
          ${error}
        </div>
      ` : null}
      <div class="absolute left-3 top-3 rounded border border-card-border/60 bg-black/40 px-2 py-1 text-3xs uppercase text-text-muted">
        ${graph.source}
      </div>
    </div>
  `
}

function TodoClaimRow({ claim }: { claim: CollabTodoClaim }) {
  return html`
    <li class="grid min-w-0 grid-cols-[minmax(0,1fr)_auto] gap-2 rounded border border-card-border/60 bg-black/10 px-3 py-2">
      <div class="min-w-0">
        <div class="truncate text-xs font-medium text-text-strong" title=${claim.title}>${claim.title}</div>
        <div class="mt-0.5 truncate text-3xs text-text-dim">
          ${claim.taskId}${claim.branch ? ` · ${claim.branch}` : ''}${claim.goalId ? ` · ${claim.goalId}` : ''}
        </div>
      </div>
      <div class="flex shrink-0 flex-col items-end gap-1">
        <span class="rounded border px-2 py-0.5 text-3xs font-semibold uppercase ${stateTone(claim.state)}">
          ${claim.state}
        </span>
        <span class="text-3xs text-text-dim">${claim.claimant ?? 'open'} · p${claim.priority}</span>
      </div>
    </li>
  `
}

function TurnQueueRow({ entry }: { entry: CollabTurnQueueEntry }) {
  return html`
    <li class="grid grid-cols-[2rem_minmax(0,1fr)_auto] items-center gap-2 rounded border border-card-border/60 bg-black/10 px-3 py-2">
      <div class="font-mono text-xs text-text-muted">#${entry.rank}</div>
      <div class="min-w-0">
        <div class="truncate text-xs font-medium text-text-strong">${entry.agentName}</div>
        <div class="truncate text-3xs text-text-dim">${entry.currentTaskId ?? 'no current task'}</div>
      </div>
      <span class="rounded border px-2 py-0.5 text-3xs font-semibold uppercase ${stateTone(entry.state)}">
        ${entry.state}
      </span>
    </li>
  `
}

export function CollabMvp() {
  const projection = buildCollabMvpProjection({
    agents: agents.value,
    tasks: tasks.value,
    boardPosts: boardPosts.value,
  })
  const visibleClaims = projection.todoClaims.filter(claim => claim.state !== 'terminal').slice(0, 8)
  const visibleQueue = projection.turnQueue.slice(0, 8)

  return html`
    <section class="flex flex-col gap-4" aria-label="Collaboration MVP">
      <div class="grid gap-3 md:grid-cols-2 xl:grid-cols-5">
        <${MetricTile} icon=${UsersRound} label="active agents" value=${projection.summary.activeAgents} />
        <${MetricTile} icon=${ListChecks} label="open claims" value=${projection.summary.openClaims} />
        <${MetricTile} icon=${GitBranch} label="worktree branches" value=${projection.summary.worktreeBackedBranches} />
        <${MetricTile} icon=${Radio} label="board observations" value=${projection.summary.boardObservations} />
        <${MetricTile} icon=${Radio} label="event names" value=${COLLAB_MVP_EVENT_SEMANTICS.length} />
      </div>

      <div class="grid gap-4 xl:grid-cols-[minmax(0,1.35fr)_minmax(20rem,0.65fr)]">
        <section class="min-w-0 rounded border border-card-border/70 bg-[rgba(8,13,22,0.74)] p-3">
          <div class="mb-2 flex items-center justify-between gap-3">
            <div>
              <h3 class="m-0 text-sm font-semibold text-text-strong">Git Graph</h3>
              <div class="text-3xs text-text-dim">${projection.gitGraph.nodes.length} nodes · ${projection.gitGraph.edges.length} edges</div>
            </div>
            <span class="rounded border border-card-border/60 bg-black/20 px-2 py-1 text-3xs uppercase text-text-muted">
              cytoscape
            </span>
          </div>
          <${CollabGitGraph} graph=${projection.gitGraph} />
        </section>

        <section class="rounded border border-card-border/70 bg-[rgba(8,13,22,0.74)] p-3">
          <h3 class="m-0 text-sm font-semibold text-text-strong">Substrate</h3>
          <ul class="mt-3 grid gap-2">
            ${COLLAB_MVP_STACK.map(item => html`
              <li class="flex items-center justify-between gap-3 rounded border border-card-border/60 bg-black/10 px-3 py-2">
                <div class="min-w-0">
                  <div class="truncate text-xs font-medium text-text-strong">${item.label}</div>
                  <div class="truncate text-3xs text-text-dim">${item.packageName ?? item.owner}</div>
                </div>
                <span class="shrink-0 rounded border px-2 py-0.5 text-3xs font-semibold uppercase ${toneForStackStatus(item.status)}">
                  ${item.status}
                </span>
              </li>
            `)}
          </ul>
        </section>
      </div>

      <div class="grid gap-4 lg:grid-cols-2">
        <section class="rounded border border-card-border/70 bg-[rgba(8,13,22,0.74)] p-3">
          <div class="mb-2 flex items-center justify-between gap-2">
            <h3 class="m-0 text-sm font-semibold text-text-strong">TODO Claim</h3>
            <span class="text-3xs text-text-dim">${projection.summary.unclaimedTasks} unclaimed</span>
          </div>
          ${visibleClaims.length === 0 ? html`
            <div class="rounded border border-card-border/50 bg-black/10 px-3 py-4 text-sm text-text-muted">No open claim observations.</div>
          ` : html`
            <ul class="grid gap-2">
              ${visibleClaims.map(claim => html`<${TodoClaimRow} key=${claim.taskId} claim=${claim} />`)}
            </ul>
          `}
        </section>

        <section class="rounded border border-card-border/70 bg-[rgba(8,13,22,0.74)] p-3">
          <div class="mb-2 flex items-center justify-between gap-2">
            <h3 class="m-0 text-sm font-semibold text-text-strong">Turn Queue</h3>
            <span class="text-3xs text-text-dim">${visibleQueue.length} observed</span>
          </div>
          ${visibleQueue.length === 0 ? html`
            <div class="rounded border border-card-border/50 bg-black/10 px-3 py-4 text-sm text-text-muted">No turn observations.</div>
          ` : html`
            <ul class="grid gap-2">
              ${visibleQueue.map(entry => html`<${TurnQueueRow} key=${entry.agentName} entry=${entry} />`)}
            </ul>
          `}
        </section>
      </div>

      <section class="rounded border border-card-border/70 bg-[rgba(8,13,22,0.74)] p-3">
        <div class="mb-2 flex items-center justify-between gap-2">
          <h3 class="m-0 text-sm font-semibold text-text-strong">Event Semantics</h3>
          <span class="text-3xs text-text-dim">${projection.generatedAt}</span>
        </div>
        <div class="grid gap-2 lg:grid-cols-2">
          ${COLLAB_MVP_EVENT_SEMANTICS.map(event => html`
            <div class="rounded border border-card-border/60 bg-black/10 px-3 py-2">
              <div class="flex flex-wrap items-center gap-2">
                <span class="font-mono text-xs text-text-strong">${event.name}</span>
                <span class="rounded border border-card-border/50 bg-white/[0.04] px-1.5 py-0.5 text-3xs uppercase text-text-muted">
                  ${event.source}
                </span>
              </div>
              <div class="mt-1 text-3xs text-text-dim">${event.attributes.join(' · ')}</div>
            </div>
          `)}
        </div>
      </section>
    </section>
  `
}
