import { html } from 'htm/preact'
import { useEffect, useMemo } from 'preact/hooks'
import { useSignalValue, useStoreSubscription } from './use-signal-value'
import { get } from '../../api/core'
import { fetchIdePresence } from '../../api/ide'
import { KeeperBadge } from '../keeper-badge'
import {
  createKeeperPresenceStore,
  disconnectedSnapshot,
  globalPresenceSnapshot,
  LOADING_SNAPSHOT,
  normalizeKeeperPresenceSnapshot,
  type KeeperPresenceEntry,
  type KeeperPresenceSnapshot,
} from './keeper-presence-store'
import { cursorOverlaySignal, type KeeperCursor } from './keeper-cursor-overlay'
import { focusIdeContextAnchor, type IdeContextFocus } from './ide-state'
import { IDE_INLINE_BADGE_BASE } from './context-badge-style'
import { routeLinksForContext } from './ide-context-lens'
import { parseAgentStatus } from '../../lib/agent-status'

export interface ApiAgent {
  readonly name: string
  readonly status: string
  readonly current_task: string | null
  readonly model: string | null
}

export interface ApiStatus {
  readonly cluster?: string | null
  readonly project?: string | null
  readonly paused?: boolean
}

interface PresenceContextSummary {
  readonly label: string
  readonly title: string
}

const CONTEXT_BADGE_STYLE = {
  ...IDE_INLINE_BADGE_BASE,
  background: 'var(--color-bg-elevated)',
}

function mapAgentStatus(status: string): KeeperPresenceEntry['status'] {
  const parsed = parseAgentStatus(status)
  return parsed === 'active' || parsed === 'busy' ? 'active' : 'idle'
}

/** @internal — exported only so {@link ./ide-presence-strip.test.ts}
    can pin the disconnected/live branch behaviour against runtime
    payloads where [cluster] may arrive as [null] (the JSON wire form
    of OCaml's [None]) rather than [undefined]. */
export function agentsToPresence(
  agents: ReadonlyArray<ApiAgent>,
  status: ApiStatus,
): KeeperPresenceSnapshot {
  const cluster = status.cluster?.trim() ?? ''
  if (cluster === '') {
    return disconnectedSnapshot('runtime_unknown')
  }
  if (agents.length === 0) {
    return disconnectedSnapshot('no_agents')
  }
  const now = Date.now()
  return {
    kind: 'live',
    runtime_id: cluster,
    entries: agents.map((agent, idx) => ({
      keeper_id: agent.name,
      workspace_label: agent.name,
      role: 'agent',
      status: mapAgentStatus(agent.status),
      last_seen_ms: now - idx * 1000,
    })),
  }
}

/** The standard MASC API endpoints ([/api/v1/status], [/api/v1/agents]) wrap
    their payload in an [{ ok, data }] envelope, unlike the dashboard-specific
    [/api/v1/providers] which returns its payload at the top level. [get()]
    returns the raw parsed body without unwrapping, so a consumer must pull
    [.data] out. Reading the envelope's absent top-level fields (e.g.
    [status.cluster], which actually lives at [status.data.cluster]) is what
    made this strip render a permanent [disconnected (runtime_unknown)]
    regardless of the live runtime. Falls back to the raw value when no [data]
    key is present, so an un-enveloped response still works.
    @internal — exported for {@link ./ide-presence-strip.test.ts}. */
export function unwrapEnvelope<T>(raw: unknown): T | undefined {
  if (raw === null || typeof raw !== 'object') return undefined
  if ('data' in raw) return (raw as { data: T }).data
  return raw as T
}

async function fetchPresence(): Promise<KeeperPresenceSnapshot> {
  const [idePresence, agentsResponse, statusResponse] = await Promise.allSettled([
    fetchIdePresence(),
    get<unknown>('/api/v1/agents?limit=20'),
    get<unknown>('/api/v1/status'),
  ])

  // The IDE endpoint is the only source that has the runtime/branch and
  // keeper-presence contract together. Prefer it when valid; the generic
  // agents/status pair remains a compatibility fallback for older servers.
  if (idePresence.status === 'fulfilled') {
    const snapshot = normalizeKeeperPresenceSnapshot(idePresence.value)
    if (snapshot !== null) return snapshot
  }

  if (agentsResponse.status === 'fulfilled' && statusResponse.status === 'fulfilled') {
    const agentsRaw = agentsResponse.value
    const statusRaw = statusResponse.value
    const agentsData = unwrapEnvelope<{ agents?: ApiAgent[] }>(agentsRaw)
    const statusData = unwrapEnvelope<ApiStatus>(statusRaw)
    const agents: ApiAgent[] = Array.isArray(agentsData?.agents) ? agentsData.agents : []
    return agentsToPresence(agents, statusData ?? {})
  }

  return disconnectedSnapshot('fetch_failed')
}

function presenceHeader(snap: KeeperPresenceSnapshot) {
  if (snap.kind === 'loading') {
    return html`
      <span style=${{ color: 'var(--color-fg-disabled)' }} aria-label="presence loading">○</span>
      <span style=${{ fontStyle: 'italic' }}>loading…</span>
    `
  }
  if (snap.kind === 'disconnected') {
    return html`
      <span style=${{ color: 'var(--color-status-err)' }} aria-label=${`presence disconnected: ${snap.reason}`}>○</span>
      <span style=${{ fontStyle: 'italic' }}>disconnected (${snap.reason})</span>
    `
  }
  const segments = [snap.runtime_id]
  if (snap.branch !== undefined) segments.push(snap.branch)
  if (snap.supervisor !== undefined) segments.push(snap.supervisor)
  return html`
    <span style=${{ color: 'var(--color-status-ok)' }} aria-label="presence live">●</span>
    ${segments.map((seg, idx) => html`
      ${idx > 0 ? html`<span>/</span>` : null}
      <span>${seg}</span>
    `)}
  `
}

export function IdePresenceStrip() {
  const presenceStore = useMemo(() => createKeeperPresenceStore(LOADING_SNAPSHOT), [])

  useEffect(() => {
    let cancelled = false
    fetchPresence().then(snapshot => {
      if (!cancelled) {
        presenceStore.seed(snapshot)
      }
    })
    return () => { cancelled = true }
  }, [presenceStore])

  useEffect(() => {
    const unsub = globalPresenceSnapshot.subscribe(() => {
      presenceStore.seed(globalPresenceSnapshot.value)
    })
    return unsub
  }, [presenceStore])

  useStoreSubscription(presenceStore.subscribe)
  useSignalValue(cursorOverlaySignal)

  const current = presenceStore.snapshot()
  const entries = presenceStore.entries()

  return html`
    <div
      class="ide-presence-strip v2-ide-panel"
      role="status"
      aria-label="Live workspace keeper presence"
      style=${{
        display: 'inline-flex',
        alignItems: 'center',
        gap: 'var(--sp-2)',
        minWidth: 0,
        color: 'var(--color-fg-muted)',
      }}
    >
      ${presenceHeader(current)}
      <ul
        style=${{
          display: 'inline-flex',
          alignItems: 'center',
          gap: 'var(--sp-2)',
          listStyle: 'none',
          margin: 0,
          padding: 0,
          minWidth: 0,
          overflow: 'hidden',
        }}
      >
        ${entries.map(entry => html`<${PresenceChip} entry=${entry} />`)}
      </ul>
    </div>
  `
}

interface PresenceChipProps {
  readonly entry: KeeperPresenceEntry
}

interface PresenceContextAnchorInput {
  readonly entry: KeeperPresenceEntry
  readonly cursor: KeeperCursor | undefined
}

export function presenceContextAnchor({
  entry,
  cursor,
}: PresenceContextAnchorInput): Omit<IdeContextFocus, 'activated_at_ms'> | null {
  if (!cursor?.file_path) return null
  const label = `${entry.keeper_id}@${entry.workspace_label}`
  const sourceId = `presence:${entry.keeper_id}`
  return {
    file_path: cursor.file_path,
    line: cursor.line,
    surface: 'Keeper',
    label,
    source_id: sourceId,
    keeper_id: entry.keeper_id,
    route_links: routeLinksForContext({
      filePath: cursor.file_path,
      line: cursor.line,
      surface: 'Keeper',
      label,
      sourceId,
      telemetry: true,
      telemetryQuery: entry.keeper_id,
      keeperId: entry.keeper_id,
    }),
  }
}

export function presenceContextSummary(
  anchor: Omit<IdeContextFocus, 'activated_at_ms'> | null,
): PresenceContextSummary | null {
  const labels = anchor?.route_links?.map(link => link.label) ?? []
  if (labels.length === 0) return null
  return {
    label: `CTX ${labels.length}`,
    title: `Linked context: ${labels.join(', ')}`,
  }
}

function PresenceChip({ entry }: PresenceChipProps) {
  const isActive = entry.status === 'active'
  const cursor = cursorOverlaySignal.value.cursors.get(entry.keeper_id)
  const contextAnchor = presenceContextAnchor({ entry, cursor })
  const contextSummary = presenceContextSummary(contextAnchor)

  const focusLabel = cursor?.file_path
    ? `${cursor.file_path.split('/').pop()}:${cursor.line}`
    : null

  const canNavigate = contextAnchor !== null
  const navigate = (): void => {
    if (contextAnchor) focusIdeContextAnchor(contextAnchor)
  }
  const onKeyDown = canNavigate
    ? (e: KeyboardEvent) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); navigate() } }
    : undefined

  return html`
    <li
      class="ide-presence-chip v2-ide-row"
      title=${`${entry.keeper_id} · ${entry.role} · ${focusLabel ?? 'no file focus'}`}
      aria-label=${`${entry.keeper_id} ${entry.status} in ${entry.workspace_label}${focusLabel ? ` editing ${focusLabel}` : ''}`}
      role=${canNavigate ? 'button' : undefined}
      aria-disabled=${canNavigate ? undefined : 'true'}
      tabIndex=${canNavigate ? 0 : undefined}
      onClick=${canNavigate ? navigate : undefined}
      onKeyDown=${onKeyDown}
      style=${{
        display: 'inline-flex',
        alignItems: 'center',
        gap: 'var(--sp-1)',
        maxWidth: '260px',
        color: 'var(--color-fg-secondary)',
        whiteSpace: 'nowrap',
        cursor: cursor?.file_path ? 'pointer' : 'default',
        borderRadius: 'var(--r-1)',
        padding: '0 var(--sp-1)',
        transition: 'background 0.15s',
      }}
    >
      <${KeeperBadge} id=${entry.keeper_id} variant="sigil" size="sm" beat=${isActive} />
      <span style=${{ overflow: 'hidden', textOverflow: 'ellipsis' }}>
        ${entry.keeper_id}@${entry.workspace_label}
      </span>
      ${focusLabel ? html`
        <span style=${{
          color: 'var(--color-accent-fg)',
          fontSize: 'var(--fs-10)',
          maxWidth: '90px',
          overflow: 'hidden',
          textOverflow: 'ellipsis',
        }}>${focusLabel}</span>
      ` : null}
      ${contextSummary ? html`
        <span style=${CONTEXT_BADGE_STYLE} title=${contextSummary.title}>${contextSummary.label}</span>
      ` : null}
      <span
        style=${{
          color: isActive ? 'var(--color-status-ok)' : 'var(--color-fg-muted)',
          fontSize: 'var(--fs-10)',
        }}
      >
        ${entry.status}
      </span>
    </li>
  `
}

export function prLabel(prNumber: number, prState: string | null): string {
  if (prState === 'open') return `#${prNumber}`
  if (prState === 'closed') return `#${prNumber}✕`
  if (prState === 'merged') return `#${prNumber}✓`
  return `#${prNumber}`
}
