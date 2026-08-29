import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'

import {
  fetchKeeperStateDiagram,
  type KeeperStateDiagramResponse,
} from '../../api/keeper'
import { activeKeeperName } from '../../keeper-state'
import { keepers } from '../../store'
import type { Keeper } from '../../types'
import { PersistenceStatus, type PersistenceState } from '../common/persistence-status'
import { globalPresenceSnapshot, PRESENCE_DOT, presenceEntries, type KeeperPresenceEntry } from './keeper-presence-store'
import {
  openIdeContextRouteLink,
  routeLinksForContext,
  type IdeContextRouteLink,
} from './ide-context-lens'
import { useSignalValue } from './use-signal-value'
import { DEFAULT_PANEL_REFRESH_MS } from '../../lib/auto-refresh'
import { IDE_CONTEXT_BADGE_STYLE } from './context-badge-style'
import { routeLinkLabels } from './ide-context-route-helpers'

type LifecycleState = 'created' | 'active' | 'idle' | 'terminated'

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
    case 'crashed':
      return 'conflict'
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
      class="ide-persistence-lifecycle v2-ide-card"
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
  pollMs = DEFAULT_PANEL_REFRESH_MS,
}: IdePersistencePanelProps) {
  const activeName = useSignalValue(activeKeeperName)
  const keeperRows = useSignalValue(keepers)
  const keeperName = resolveKeeperName(explicitKeeperName, activeName, keeperRows)
  const keeper = findKeeper(keeperRows, keeperName)
  const presence = useSignalValue(globalPresenceSnapshot)
  const entries: ReadonlyArray<KeeperPresenceEntry> = presenceEntries(presence)
  const entry = keeperName ? entries.find(e => e.keeper_id === keeperName) : null
  const statusDot = entry ? PRESENCE_DOT[entry.status] : null
  const routeLinks = persistenceRouteLinks(keeperName)
  const [diagram, setDiagram] = useState<KeeperStateDiagramResponse | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    const name = keeperName.trim()
    if (!name) {
      setDiagram(null)
      setError(null)
      return
    }

    const controller = new AbortController()
    let timer: number | null = null

    const refresh = async () => {
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
  const lastSaved = keeper?.last_heartbeat ?? keeper?.updated_at ?? keeper?.created_at ?? null

  return html`
    <section
      class="ide-persistence-panel v2-ide-panel"
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
            <${PersistenceRouteLinks}
              links=${routeLinks}
            />
          </div>
        `
        : html`<div role="status" style=${{ color: 'var(--color-fg-disabled)', fontSize: 'var(--fs-12)' }}>keeper unavailable</div>`}
    </section>
  `
}

function persistenceRouteLinks(
  keeperName: string,
): ReadonlyArray<IdeContextRouteLink> {
  const keeperId = keeperName.trim()
  return routeLinksForContext({
    surface: 'Persistence',
    label: keeperId ? `${keeperId} current focus` : 'keeper current focus',
    sourceId: keeperId ? `persistence:${keeperId}` : 'persistence',
    keeperId,
    telemetry: Boolean(keeperId),
    telemetryQuery: keeperId || undefined,
  })
}

function PersistenceRouteLinks({
  links,
}: {
  readonly links: ReadonlyArray<IdeContextRouteLink>
}) {
  if (links.length === 0) return null
  const routeLabels = routeLinkLabels(links)
  return html`
    <div class="ide-persistence-links" aria-label="Persistence context links">
      <span
        class="ide-persistence-context-badge"
        data-context-route-count=${links.length}
        title=${`Linked context: ${routeLabels}`}
        aria-label=${`Persistence map has ${links.length} linked context routes: ${routeLabels}`}
        style=${IDE_CONTEXT_BADGE_STYLE}
      >
        CTX ${links.length}
      </span>
      ${links.map(link => html`
        <button
          key=${link.id}
          type="button"
          class="v2-ide-action"
          title=${link.evidence}
          aria-label=${`Open ${link.evidence}`}
          onClick=${() => openIdeContextRouteLink(link)}
        >${link.label}</button>
      `)}
    </div>
  `
}
