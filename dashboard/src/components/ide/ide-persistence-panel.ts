import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'

import {
  fetchKeeperStateDiagram,
  type KeeperStateDiagramResponse,
  type MemoryKindUsageEntry,
} from '../../api/keeper'
import { activeKeeperName } from '../../keeper-state'
import { keepers } from '../../store'
import type { Keeper } from '../../types'
import { MemoryGraph } from '../common/memory-graph'
import { PersistenceStatus, type PersistenceState } from '../common/persistence-status'
import { globalPresenceSnapshot, type KeeperPresenceEntry, type KeeperPresenceStatus } from './keeper-presence-store'
import { cursorOverlaySignal } from './keeper-cursor-overlay'

const PRESENCE_DOT: Record<KeeperPresenceStatus, { color: string; label: string }> = {
  active: { color: 'var(--color-status-ok)', label: 'ACTIVE' },
  blocked: { color: 'var(--color-status-err)', label: 'BLOCKED' },
  idle: { color: 'var(--color-fg-muted)', label: 'IDLE' },
}

const REFRESH_MS = 30_000

type LifecycleState = 'created' | 'active' | 'idle' | 'terminated'

interface GraphNode {
  id: string
  label: string
  x: number
  y: number
  color?: string
}

interface GraphEdge {
  source: string
  target: string
  label?: string
}

interface MemoryGraphModel {
  nodes: GraphNode[]
  edges: GraphEdge[]
  visibleUsage: MemoryKindUsageEntry[]
  totalUsed: number
  totalCap: number
  saturatedCount: number
}

interface IdePersistencePanelProps {
  keeperName?: string
  pollMs?: number
}

const LIFECYCLE_STEPS: ReadonlyArray<{ state: LifecycleState; label: string }> = [
  { state: 'created', label: 'CREATED' },
  { state: 'active', label: 'ACTIVE' },
  { state: 'idle', label: 'IDLE' },
  { state: 'terminated', label: 'DONE' },
]

function normalizePhase(phase: string | null | undefined): string {
  return phase?.trim().toLowerCase() ?? ''
}

export function lifecycleStateFromKeeperPhase(phase: string | null | undefined): LifecycleState {
  switch (normalizePhase(phase)) {
    case '':
      return 'created'
    case 'offline':
    case 'stopped':
    case 'crashed':
    case 'dead':
    case 'zombie':
    case 'terminated':
      return 'terminated'
    case 'idle':
    case 'paused':
    case 'stable':
      return 'idle'
    default:
      return 'active'
  }
}

export function persistenceStateFromKeeperPhase(
  phase: string | null | undefined,
  hasFetchError = false,
): PersistenceState {
  if (hasFetchError) return 'offline'
  switch (normalizePhase(phase)) {
    case 'failing':
    case 'overflowed':
    case 'crashed':
    case 'zombie':
      return 'conflict'
    case 'compacting':
    case 'handoffing':
    case 'handingoff':
    case 'draining':
    case 'restarting':
      return 'syncing'
    case '':
    case 'offline':
    case 'stopped':
    case 'dead':
      return 'offline'
    default:
      return 'saved'
  }
}

export function buildMemoryGraphModel(
  keeperName: string,
  usage: readonly MemoryKindUsageEntry[],
): MemoryGraphModel {
  const visibleUsage = [...usage]
    .sort((left, right) => right.used - left.used || left.kind.localeCompare(right.kind))
    .slice(0, 3)
  const totalUsed = usage.reduce((sum, row) => sum + row.used, 0)
  const totalCap = usage.reduce((sum, row) => sum + row.cap, 0)
  const saturatedCount = usage.filter(row => row.cap > 0 && row.used >= row.cap).length

  if (!keeperName.trim()) {
    return { nodes: [], edges: [], visibleUsage, totalUsed, totalCap, saturatedCount }
  }

  const positions = [
    { x: 170, y: 12 },
    { x: 86, y: 44 },
    { x: 254, y: 44 },
  ]

  const nodes: GraphNode[] = [
    {
      id: 'keeper',
      label: keeperName,
      x: 170,
      y: 36,
      color: 'var(--color-bg-elevated)',
    },
    ...visibleUsage.map((row, index) => {
      const saturated = row.cap > 0 && row.used >= row.cap
      return {
        id: `memory-${row.kind}`,
        label: row.kind,
        x: positions[index]?.x ?? 170,
        y: positions[index]?.y ?? 92,
        color: saturated
          ? 'var(--color-status-warn-bg, var(--warn-20))'
          : 'var(--color-accent-bg, var(--color-bg-surface))',
      }
    }),
  ]
  const edges = visibleUsage.map(row => ({
    source: 'keeper',
    target: `memory-${row.kind}`,
    label: `${row.used}/${row.cap}`,
  }))

  return { nodes, edges, visibleUsage, totalUsed, totalCap, saturatedCount }
}

function useSignalValue<T>(signal: { value: T; subscribe: (fn: (value: T) => void) => () => void }): T {
  const [value, setValue] = useState(signal.value)
  useEffect(() => signal.subscribe(next => setValue(next)), [signal])
  return value
}

function resolveKeeperName(explicit: string | undefined, active: string, rows: readonly Keeper[]): string {
  const fromProp = explicit?.trim()
  if (fromProp) return fromProp
  const fromActive = active.trim()
  if (fromActive) return fromActive
  return rows[0]?.name?.trim() ?? ''
}

function findKeeper(rows: readonly Keeper[], name: string): Keeper | null {
  const needle = name.trim().toLowerCase()
  if (!needle) return null
  return rows.find(row => row.name.trim().toLowerCase() === needle) ?? null
}

function LifecycleMini({ state, phase }: { state: LifecycleState; phase: string | null }) {
  return html`
    <div
      role="region"
      aria-label="Keeper lifecycle"
      data-testid="ide-persistence-lifecycle"
      style=${{
        display: 'grid',
        gap: 'var(--sp-2)',
        border: '1px solid var(--color-border-default)',
        borderRadius: 'var(--r-2)',
        background: 'var(--color-bg-page)',
        padding: 'var(--sp-1) var(--sp-2)',
      }}
    >
      <div style=${{ display: 'flex', justifyContent: 'space-between', gap: 'var(--sp-2)', font: 'var(--type-eyebrow)', color: 'var(--color-fg-muted)' }}>
        <span>LIFECYCLE</span>
        <span style=${{ color: 'var(--color-fg-secondary)' }}>${phase ?? 'unknown'}</span>
      </div>
      <div
        role="list"
        aria-label="Lifecycle states"
        style=${{ display: 'grid', gridTemplateColumns: 'repeat(4, minmax(0, 1fr))', gap: '4px' }}
      >
        ${LIFECYCLE_STEPS.map(step => {
          const current = step.state === state
          return html`
            <div
              key=${step.state}
              role="listitem"
              aria-current=${current ? 'step' : undefined}
              style=${{
                display: 'grid',
                gap: '4px',
                justifyItems: 'center',
                minWidth: 0,
                color: current ? 'var(--color-accent-fg)' : 'var(--color-fg-muted)',
              }}
            >
              <span
                aria-hidden="true"
                style=${{
                  width: '10px',
                  height: '10px',
                  borderRadius: '999px',
                  border: `1px solid ${current ? 'var(--color-accent-fg)' : 'var(--color-border-default)'}`,
                  background: current ? 'var(--color-accent-fg)' : 'var(--color-bg-elevated)',
                  boxShadow: current ? '0 0 0 3px color-mix(in srgb, var(--color-accent-fg) 18%, transparent)' : 'none',
                }}
              />
              <span style=${{ maxWidth: '100%', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', fontSize: 'var(--fs-10)', fontFamily: 'var(--font-mono)' }}>
                ${step.label}
              </span>
            </div>
          `
        })}
      </div>
    </div>
  `
}

export function IdePersistencePanel({
  keeperName: explicitKeeperName,
  pollMs = REFRESH_MS,
}: IdePersistencePanelProps) {
  const activeName = useSignalValue(activeKeeperName)
  const keeperRows = useSignalValue(keepers)
  const keeperName = resolveKeeperName(explicitKeeperName, activeName, keeperRows)
  const keeper = findKeeper(keeperRows, keeperName)
  const [, forceRender] = useState(0)

  useEffect(() => globalPresenceSnapshot.subscribe(() => forceRender((t: number) => t + 1)), [])
  useEffect(() => cursorOverlaySignal.subscribe(() => forceRender((t: number) => t + 1)), [])

  const presence = globalPresenceSnapshot.value
  const entries: ReadonlyArray<KeeperPresenceEntry> = presence?.entries ?? []
  const entry = keeperName ? entries.find(e => e.keeper_id === keeperName) : null
  const statusDot = entry ? PRESENCE_DOT[entry.status] : null
  const cursor = keeperName ? cursorOverlaySignal.value.cursors.get(keeperName) : undefined
  const focusLabel = cursor?.file_path
    ? `${cursor.file_path.split('/').pop()}:${cursor.line}`
    : null
  const [diagram, setDiagram] = useState<KeeperStateDiagramResponse | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)

  useEffect(() => {
    const name = keeperName.trim()
    if (!name) {
      setDiagram(null)
      setError(null)
      setLoading(false)
      return
    }

    const controller = new AbortController()
    let timer: number | null = null

    const refresh = async () => {
      setLoading(true)
      try {
        const next = await fetchKeeperStateDiagram(name, { signal: controller.signal })
        if (controller.signal.aborted) return
        setDiagram(next)
        setError(null)
      } catch (err) {
        if (!controller.signal.aborted) {
          setDiagram(null)
          setError(err instanceof Error ? err.message : 'state diagram unavailable')
        }
      } finally {
        if (!controller.signal.aborted) setLoading(false)
      }
    }

    void refresh()
    timer = window.setInterval(refresh, Math.max(5000, pollMs))
    return () => {
      controller.abort()
      if (timer !== null) window.clearInterval(timer)
    }
  }, [keeperName, pollMs])

  const phase = diagram?.current_phase ?? keeper?.phase ?? null
  const lifecycleState = lifecycleStateFromKeeperPhase(phase)
  const persistenceState = persistenceStateFromKeeperPhase(phase, error !== null)
  const usage = diagram?.memory_kind_usage ?? []
  const graph = useMemo(() => buildMemoryGraphModel(keeperName, usage), [keeperName, usage])
  const lastSaved = keeper?.last_heartbeat ?? keeper?.updated_at ?? keeper?.created_at ?? null

  return html`
    <section
      aria-label="PERSISTENCE MAP"
      data-testid="ide-persistence-panel"
      style=${{
        display: 'grid',
        gap: 'var(--sp-3)',
        padding: 'var(--sp-2) var(--sp-3)',
        borderBottom: '1px solid var(--color-border-divider)',
        background: 'var(--color-bg-surface)',
      }}
    >
      <header style=${{ display: 'flex', alignItems: 'center', gap: 'var(--sp-2)' }}>
        <h3 style=${{ margin: 0, font: 'var(--type-eyebrow)', color: 'var(--color-fg-primary)' }}>
          PERSISTENCE MAP
        </h3>
        <span style=${{ color: 'var(--color-accent-fg)', fontSize: 'var(--fs-12)' }}>
          ${keeperName || '—'}
        </span>
        ${statusDot ? html`
          <span
            role="status"
            aria-label=${`Keeper status: ${statusDot.label}`}
            style=${{
              display: 'inline-flex',
              alignItems: 'center',
              gap: '2px',
              fontSize: 'var(--fs-10)',
              fontWeight: 600,
              letterSpacing: '0.04em',
              color: statusDot.color,
            }}
          >
            <span style=${{
              width: '4px',
              height: '4px',
              borderRadius: '50%',
              background: statusDot.color,
              display: 'inline-block',
            }} />
            ${statusDot.label}
          </span>
        ` : null}
        ${focusLabel ? html`
          <span style=${{
            fontSize: 'var(--fs-10)',
            fontFamily: 'var(--font-mono)',
            color: 'var(--color-accent-fg)',
            overflow: 'hidden',
            textOverflow: 'ellipsis',
            whiteSpace: 'nowrap',
            maxWidth: '120px',
          }}
          title=${cursor?.file_path}
          >↗ ${focusLabel}</span>
        ` : null}
        <span style=${{ marginLeft: 'auto' }}>
          <${PersistenceStatus} status=${persistenceState} lastSaved=${lastSaved} />
        </span>
      </header>

      ${error
        ? html`<div role="status" style=${{ color: 'var(--color-status-warn)', fontSize: 'var(--fs-12)' }}>${error}</div>`
        : null}

      ${keeperName
        ? html`
          <div style=${{ display: 'grid', gap: 'var(--sp-2)' }}>
            <${LifecycleMini} state=${lifecycleState} phase=${phase} />

            <div
              style=${{
                display: 'grid',
                gap: 'var(--sp-2)',
                border: '1px solid var(--color-border-default)',
                borderRadius: 'var(--r-2)',
                background: 'var(--color-bg-page)',
                padding: 'var(--sp-1) var(--sp-2)',
              }}
            >
              <div style=${{ display: 'flex', justifyContent: 'space-between', gap: 'var(--sp-2)', font: 'var(--type-eyebrow)', color: 'var(--color-fg-muted)' }}>
                <span>MEMORY GRAPH</span>
                <span>${loading && usage.length === 0 ? 'loading' : `${graph.totalUsed}/${graph.totalCap || 0} · ${graph.saturatedCount} saturated`}</span>
              </div>
              <${MemoryGraph}
                nodes=${graph.nodes}
                edges=${graph.edges}
                width=${340}
                height=${64}
                ariaLabel="IDE memory graph"
                testId="ide-memory-graph"
              />
              <span
                style=${{
                  minWidth: 0,
                  overflow: 'hidden',
                  textOverflow: 'ellipsis',
                  whiteSpace: 'nowrap',
                  color: graph.visibleUsage.length === 0 ? 'var(--color-fg-disabled)' : 'var(--color-fg-muted)',
                  fontSize: 'var(--fs-11)',
                }}
                title=${graph.visibleUsage.map(row => `${row.kind} ${row.used}/${row.cap}`).join(' · ')}
              >
                ${graph.visibleUsage.length === 0
                  ? 'memory bank data unavailable'
                  : graph.visibleUsage.map(row => row.kind).join(' · ')}
              </span>
              ${keeper?.memory_recent_note
                ? html`
                  <div
                    style=${{
                      color: 'var(--color-fg-muted)',
                      fontSize: 'var(--fs-11)',
                      lineHeight: 1.35,
                      borderTop: '1px solid var(--color-border-divider)',
                      paddingTop: 'var(--sp-2)',
                    }}
                  >
                    ${keeper.memory_recent_note}
                  </div>
                `
                : null}
            </div>
          </div>
        `
        : html`<div role="status" style=${{ color: 'var(--color-fg-disabled)', fontSize: 'var(--fs-12)' }}>keeper unavailable</div>`}
    </section>
  `
}
