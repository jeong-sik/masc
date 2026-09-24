import { html } from 'htm/preact'
import { useEffect, useMemo } from 'preact/hooks'
import { useStoreSubscription } from './use-signal-value'
import { get } from '../../api/core'
import { fetchIdePresence } from '../../api/ide'
import { KeeperBadge } from '../keeper-badge'
import {
  createKeeperPresenceStore,
  disconnectedSnapshot,
  globalPresenceSnapshot,
  normalizeKeeperPresenceSnapshot,
  type KeeperPresenceEntry,
  type KeeperPresenceSnapshot,
} from './keeper-presence-store'
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

/** How often the strip re-reads presence when the shell gives no cadence. */
const DEFAULT_PRESENCE_POLL_MS = 10_000

/**
 * The strip is mounted unconditionally in the IDE shell header, so it owns
 * the presence fetch for the whole IDE: every read lands in
 * {@link globalPresenceSnapshot}, which the interject pill, the activity
 * lens, the conversation rail, the persistence map and the editor read.
 * A snapshot kept only in this component's store left all of those on
 * `loading` for the life of the page.
 */
export function IdePresenceStrip({
  compact = false,
  pollMs = DEFAULT_PRESENCE_POLL_MS,
}: { readonly compact?: boolean; readonly pollMs?: number } = {}) {
  const presenceStore = useMemo(() => createKeeperPresenceStore(globalPresenceSnapshot.value), [])

  useEffect(() => {
    let cancelled = false
    let inFlight = false
    const refresh = async () => {
      // A slow server must not stack reads; the next tick picks it up.
      if (inFlight) return
      inFlight = true
      try {
        const snapshot = await fetchPresence()
        if (!cancelled) globalPresenceSnapshot.value = snapshot
      } finally {
        inFlight = false
      }
    }
    void refresh()
    const timer = window.setInterval(() => { void refresh() }, pollMs)
    return () => {
      cancelled = true
      window.clearInterval(timer)
    }
  }, [pollMs])

  useEffect(() => {
    const unsub = globalPresenceSnapshot.subscribe(() => {
      presenceStore.seed(globalPresenceSnapshot.value)
    })
    return unsub
  }, [presenceStore])

  useStoreSubscription(presenceStore.subscribe)

  const current = presenceStore.snapshot()
  const entries = presenceStore.entries()

  if (compact) {
    const compactStateLabel = current.kind === 'live'
      ? `Presence live: ${current.runtime_id}`
      : current.kind === 'disconnected'
        ? `Presence disconnected: ${current.reason}`
        : 'Presence loading'
    return html`
      <div
        class="ide-presence-strip ide-presence v2-ide-panel"
        role="status"
        aria-label="Live workspace keeper presence"
        data-state=${current.kind}
      >
        <span class="lbl">Presence</span>
        <span
          class="ide-v2-presence-state"
          data-state=${current.kind}
          aria-label=${compactStateLabel}
          title=${compactStateLabel}
        >${current.kind === 'live' ? '●' : '○'}</span>
        <ul>
          ${entries.map(entry => html`
            <li
              key=${entry.keeper_id}
              title=${`${entry.keeper_id} · ${entry.role} · ${entry.workspace_label}`}
              aria-label=${`${entry.keeper_id} ${entry.status} in ${entry.workspace_label}`}
            >
              <${KeeperBadge}
                id=${entry.keeper_id}
                variant="sigil"
                size="sm"
                beat=${entry.status === 'active'}
              />
            </li>
          `)}
        </ul>
      </div>
    `
  }

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

function PresenceChip({ entry }: PresenceChipProps) {
  const isActive = entry.status === 'active'

  return html`
    <li
      class="ide-presence-chip v2-ide-row"
      title=${`${entry.keeper_id} · ${entry.role}`}
      aria-label=${`${entry.keeper_id} ${entry.status} in ${entry.workspace_label}`}
      style=${{
        display: 'inline-flex',
        alignItems: 'center',
        gap: 'var(--sp-1)',
        maxWidth: '260px',
        color: 'var(--color-fg-secondary)',
        whiteSpace: 'nowrap',
        borderRadius: 'var(--r-1)',
        padding: '0 var(--sp-1)',
        transition: 'background 0.15s',
      }}
    >
      <${KeeperBadge} id=${entry.keeper_id} variant="sigil" size="sm" beat=${isActive} />
      <span style=${{ overflow: 'hidden', textOverflow: 'ellipsis' }}>
        ${entry.keeper_id}@${entry.workspace_label}
      </span>
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
