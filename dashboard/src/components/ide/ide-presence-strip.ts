import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import { keeperHueIndex } from '../../../design-system/headless-core/keeper-line-ownership'
import {
  createKeeperPresenceStore,
  type KeeperPresenceEntry,
  type KeeperPresenceSnapshot,
} from './keeper-presence-store'

const FALLBACK_PRESENCE: KeeperPresenceSnapshot = {
  runtime_id: 'local',
  branch: 'main',
  supervisor: 'local',
  connected: false,
  entries: [],
}

interface ApiAgent {
  readonly name: string
  readonly status: string
  readonly current_task: string | null
  readonly model: string | null
}

interface ApiStatus {
  readonly cluster?: string
  readonly project?: string
  readonly paused?: boolean
}

function mapAgentStatus(status: string): KeeperPresenceEntry['status'] {
  if (status === 'active' || status === 'busy') return 'active'
  if (status === 'listening') return 'idle'
  return 'idle'
}

function agentsToPresence(agents: ReadonlyArray<ApiAgent>, status: ApiStatus): KeeperPresenceSnapshot {
  const now = Date.now()
  return {
    runtime_id: status.cluster ?? 'local',
    branch: status.project ?? 'main',
    supervisor: 'local',
    connected: agents.length > 0,
    entries: agents.map((agent, idx) => ({
      keeper_id: agent.name,
      workspace_label: agent.name,
      branch: status.project ?? 'main',
      role: agent.model ?? 'agent',
      status: mapAgentStatus(agent.status),
      last_seen_ms: now - idx * 1000,
    })),
  }
}

async function fetchPresence(): Promise<KeeperPresenceSnapshot> {
  try {
    const [agentsRes, statusRes] = await Promise.all([
      fetch('/api/v1/agents?limit=20'),
      fetch('/api/v1/status'),
    ])
    if (!agentsRes.ok || !statusRes.ok) return FALLBACK_PRESENCE
    const agentsData = await agentsRes.json()
    const statusData = await statusRes.json()
    const agents: ApiAgent[] = Array.isArray(agentsData.agents) ? agentsData.agents : []
    if (agents.length === 0) return FALLBACK_PRESENCE
    return agentsToPresence(agents, statusData as ApiStatus)
  } catch {
    return FALLBACK_PRESENCE
  }
}

export function IdePresenceStrip() {
  const presenceStore = useMemo(() => createKeeperPresenceStore(FALLBACK_PRESENCE), [])
  const [, forceRender] = useState(0)

  useEffect(() => {
    let cancelled = false
    fetchPresence().then(snapshot => { if (!cancelled) presenceStore.seed(snapshot) })
    return () => { cancelled = true }
  }, [presenceStore])

  useEffect(() => presenceStore.subscribe(() => forceRender(tick => tick + 1)), [presenceStore])

  const current = presenceStore.snapshot()
  const entries = presenceStore.entries()

  return html`
    <div
      role="status"
      aria-label="IDE keeper presence"
      style=${{
        display: 'inline-flex',
        alignItems: 'center',
        gap: 'var(--sp-2)',
        minWidth: 0,
        color: 'var(--color-fg-muted)',
      }}
    >
      <span style=${{ color: current.connected ? 'var(--color-status-ok, var(--ok))' : 'var(--color-fg-disabled)' }}>●</span>
      <span>${current.runtime_id}</span>
      <span>/</span>
      <span>${current.branch}</span>
      <span>/</span>
      <span>${current.supervisor}</span>
      <ul
        style=${{
          display: 'inline-flex',
          alignItems: 'center',
          gap: 'var(--sp-2)',
          listStyle: 'none',
          margin: 0,
          padding: 0,
          minWidth: 0,
        }}
      >
        ${entries.map(entry => html`<${PresenceChip} entry=${entry} />`)}
      </ul>
    </div>
  `
}

function PresenceChip({ entry }: { readonly entry: KeeperPresenceEntry }) {
  const hue = keeperHueIndex(entry.keeper_id)
  const keeperColor = `var(--color-keeper-${hue}-glow, var(--k-${hue}))`
  return html`
    <li
      title=${`${entry.keeper_id} · ${entry.role} · ${entry.branch}`}
      style=${{
        display: 'inline-flex',
        alignItems: 'center',
        gap: 'var(--sp-1)',
        maxWidth: '180px',
        color: 'var(--color-fg-secondary)',
        whiteSpace: 'nowrap',
      }}
    >
      <span
        aria-hidden="true"
        class="size-[6px] shrink-0 rounded-full"
        style=${{ background: keeperColor, opacity: entry.status === 'active' ? 0.95 : 0.45 }}
      />
      <span style=${{ overflow: 'hidden', textOverflow: 'ellipsis' }}>
        ${entry.keeper_id}@${entry.workspace_label}
      </span>
    </li>
  `
}
