import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import { KeeperBadge } from '../keeper-badge'
import {
  createKeeperPresenceStore,
  globalPresenceSnapshot,
  type KeeperPresenceEntry,
  type KeeperPresenceSnapshot,
} from './keeper-presence-store'
import { cursorOverlaySignal } from './keeper-cursor-overlay'
import { activeIdeFile } from './ide-shell'

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

/** One entry from GET /api/dashboard/worktree-status SSE stream. */
export interface WorktreeEntry {
  readonly worktree_path: string
  readonly branch: string
  readonly changed_count: number
  readonly staged_count: number
  readonly head_sha: string
  readonly pr_number: number | null
  readonly pr_state: string | null
  readonly keeper_attached: boolean
}

function mapAgentStatus(status: string): KeeperPresenceEntry['status'] {
  if (status === 'active' || status === 'busy') return 'active'
  if (status === 'listening') return 'idle'
  return 'idle'
}

/**
 * Derive the short workspace label for a keeper chip from the worktree entries.
 * Matches by branch prefix: a MASC worktree branch is "<agentName>/<taskId>".
 * Returns the task-id segment (after the first "/") as the label.
 * Falls back to the agent name itself when no worktree is found.
 */
export function workspaceLabelForAgent(
  agentName: string,
  worktrees: ReadonlyArray<WorktreeEntry>,
): string {
  const prefix = agentName + '/'
  const match = worktrees.find(wt => wt.branch.startsWith(prefix))
  if (match) {
    const taskPart = match.branch.slice(prefix.length)
    return taskPart || agentName
  }
  return agentName
}

function agentsToPresence(
  agents: ReadonlyArray<ApiAgent>,
  status: ApiStatus,
  worktrees: ReadonlyArray<WorktreeEntry>,
): KeeperPresenceSnapshot {
  const now = Date.now()
  return {
    runtime_id: status.cluster ?? 'local',
    branch: status.project ?? 'main',
    supervisor: 'local',
    connected: agents.length > 0,
    entries: agents.map((agent, idx) => ({
      keeper_id: agent.name,
      workspace_label: workspaceLabelForAgent(agent.name, worktrees),
      branch: status.project ?? 'main',
      role: 'agent',
      status: mapAgentStatus(agent.status),
      last_seen_ms: now - idx * 1000,
    })),
  }
}

/** Parse SSE text/event-stream body into an array of WorktreeEntry objects. */
/** Type predicate that validates all required WorktreeEntry fields. */
function isWorktreeEntry(value: unknown): value is WorktreeEntry {
  if (typeof value !== 'object' || value === null) return false
  const obj = value as Record<string, unknown>
  return (
    typeof obj['worktree_path'] === 'string' &&
    typeof obj['branch'] === 'string' &&
    typeof obj['changed_count'] === 'number' &&
    typeof obj['staged_count'] === 'number' &&
    typeof obj['head_sha'] === 'string' &&
    (obj['pr_number'] === null || typeof obj['pr_number'] === 'number') &&
    (obj['pr_state'] === null || typeof obj['pr_state'] === 'string') &&
    typeof obj['keeper_attached'] === 'boolean'
  )
}

export function parseWorktreeSSE(body: string): WorktreeEntry[] {
  const entries: WorktreeEntry[] = []
  for (const line of body.split('\n')) {
    const trimmed = line.trim()
    if (!trimmed.startsWith('data:')) continue
    const json = trimmed.slice('data:'.length).trim()
    if (!json || json === '{}') continue
    try {
      const obj = JSON.parse(json) as unknown
      if (isWorktreeEntry(obj)) {
        entries.push(obj)
      }
    } catch {
      // skip malformed lines
    }
  }
  return entries
}

/** Fetch worktree status from the SSE endpoint. Returns [] on failure. */
async function fetchWorktreeEntries(): Promise<WorktreeEntry[]> {
  try {
    const res = await fetch('/api/dashboard/worktree-status')
    if (!res.ok) return []
    const body = await res.text()
    return parseWorktreeSSE(body)
  } catch {
    return []
  }
}

interface PresenceData {
  readonly snapshot: KeeperPresenceSnapshot
  readonly worktrees: ReadonlyArray<WorktreeEntry>
}

const FALLBACK_DATA: PresenceData = {
  snapshot: FALLBACK_PRESENCE,
  worktrees: [],
}

async function fetchPresence(): Promise<PresenceData> {
  try {
    const [agentsRes, statusRes, worktrees] = await Promise.all([
      fetch('/api/v1/agents?limit=20'),
      fetch('/api/v1/status'),
      fetchWorktreeEntries(),
    ])
    if (!agentsRes.ok || !statusRes.ok) return { snapshot: FALLBACK_PRESENCE, worktrees }
    const agentsData = await agentsRes.json()
    const statusData = await statusRes.json()
    const agents: ApiAgent[] = Array.isArray(agentsData.agents) ? agentsData.agents : []
    if (agents.length === 0) return { snapshot: FALLBACK_PRESENCE, worktrees }
    const snapshot = agentsToPresence(agents, statusData as ApiStatus, worktrees)
    return { snapshot, worktrees }
  } catch {
    return FALLBACK_DATA
  }
}

export function IdePresenceStrip() {
  const presenceStore = useMemo(() => createKeeperPresenceStore(FALLBACK_PRESENCE), [])
  const [, forceRender] = useState(0)
  const [worktrees, setWorktrees] = useState<ReadonlyArray<WorktreeEntry>>([])

  useEffect(() => {
    let cancelled = false
    fetchPresence().then(data => {
      if (!cancelled) {
        presenceStore.seed(data.snapshot)
        setWorktrees(data.worktrees)
      }
    })
    return () => { cancelled = true }
  }, [presenceStore])

  useEffect(() => {
    const unsub = globalPresenceSnapshot.subscribe(() => {
      const snap = globalPresenceSnapshot.value
      if (snap !== null) presenceStore.seed(snap)
    })
    return unsub
  }, [presenceStore])

  useEffect(() => {
    const unsub = presenceStore.subscribe(() => forceRender(tick => tick + 1))
    return unsub
  }, [presenceStore])

  useEffect(() => {
    const unsub = cursorOverlaySignal.subscribe(() => forceRender(tick => tick + 1))
    return unsub
  }, [])

  const current = presenceStore.snapshot()
  const entries = presenceStore.entries()

  return html`
    <div
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
      <span style=${{ color: current.connected ? 'var(--color-status-ok)' : 'var(--color-fg-disabled)' }}>●</span>
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
          overflow: 'hidden',
        }}
      >
        ${entries.map(entry => html`<${PresenceChip} entry=${entry} worktrees=${worktrees} />`)}
      </ul>
    </div>
  `
}

interface PresenceChipProps {
  readonly entry: KeeperPresenceEntry
  readonly worktrees: ReadonlyArray<WorktreeEntry>
}

function PresenceChip({ entry, worktrees }: PresenceChipProps) {
  const isActive = entry.status === 'active'
  const cursor = cursorOverlaySignal.value.cursors.get(entry.keeper_id)
  const wt = worktrees.find(w => w.branch.startsWith(entry.keeper_id + '/'))

  const focusLabel = cursor?.file_path
    ? `${cursor.file_path.split('/').pop()}:${cursor.line}`
    : null

  const prBadge = wt?.pr_number != null && wt.pr_state != null
    ? prLabel(wt.pr_number, wt.pr_state)
    : null

  const canNavigate = cursor?.file_path != null
  const navigate = (): void => {
    if (cursor?.file_path) activeIdeFile.value = cursor.file_path
  }
  const onKeyDown = canNavigate
    ? (e: KeyboardEvent) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); navigate() } }
    : undefined

  return html`
    <li
      title=${`${entry.keeper_id} · ${entry.role} · ${focusLabel ?? 'no file focus'}${prBadge ? ` · ${prBadge}` : ''}`}
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
      ${prBadge ? html`
        <span style=${{
          fontSize: 'var(--fs-9)',
          padding: '0 3px',
          borderRadius: 'var(--r-0)',
          background: wt?.pr_state === 'open' ? 'var(--color-status-ok)' : 'var(--color-bg-muted)',
          color: wt?.pr_state === 'open' ? '#fff' : 'var(--color-fg-muted)',
        }}>${prBadge}</span>
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
