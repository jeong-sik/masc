import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import { KeeperBadge } from '../keeper-badge'
import {
  createKeeperPresenceStore,
  disconnectedSnapshot,
  globalPresenceSnapshot,
  LOADING_SNAPSHOT,
  type KeeperPresenceEntry,
  type KeeperPresenceSnapshot,
} from './keeper-presence-store'
import { cursorOverlaySignal, type KeeperCursor } from './keeper-cursor-overlay'
import { focusIdeContextAnchor, type IdeContextFocus } from './ide-state'
import { routeLinksForContext } from './ide-context-lens'

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

interface PresenceContextSummary {
  readonly label: string
  readonly title: string
}

const CONTEXT_BADGE_STYLE = {
  fontSize: 'var(--fs-9)',
  padding: '0 3px',
  border: '1px solid var(--color-border-default)',
  borderRadius: 'var(--r-0)',
  color: 'var(--color-fg-muted)',
  background: 'var(--color-bg-elevated)',
  fontFamily: 'var(--font-mono)',
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

/** @internal — exported only so {@link ./ide-presence-strip.test.ts}
    can pin the disconnected/live branch behaviour against runtime
    payloads where [cluster] may arrive as [null] (the JSON wire form
    of OCaml's [None]) rather than [undefined]. */
export function agentsToPresence(
  agents: ReadonlyArray<ApiAgent>,
  status: ApiStatus,
  worktrees: ReadonlyArray<WorktreeEntry>,
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
      workspace_label: workspaceLabelForAgent(agent.name, worktrees),
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

async function fetchPresence(): Promise<PresenceData> {
  try {
    const [agentsRes, statusRes, worktrees] = await Promise.all([
      fetch('/api/v1/agents?limit=20'),
      fetch('/api/v1/status'),
      fetchWorktreeEntries(),
    ])
    if (!agentsRes.ok || !statusRes.ok) {
      return { snapshot: disconnectedSnapshot('api_unavailable'), worktrees }
    }
    const agentsData = await agentsRes.json()
    const statusData = await statusRes.json()
    const agents: ApiAgent[] = Array.isArray(agentsData.agents) ? agentsData.agents : []
    const snapshot = agentsToPresence(agents, statusData as ApiStatus, worktrees)
    return { snapshot, worktrees }
  } catch {
    return { snapshot: disconnectedSnapshot('fetch_failed'), worktrees: [] }
  }
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
      presenceStore.seed(globalPresenceSnapshot.value)
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
        ${entries.map(entry => html`<${PresenceChip} entry=${entry} worktrees=${worktrees} />`)}
      </ul>
    </div>
  `
}

interface PresenceChipProps {
  readonly entry: KeeperPresenceEntry
  readonly worktrees: ReadonlyArray<WorktreeEntry>
}

interface PresenceContextAnchorInput {
  readonly entry: KeeperPresenceEntry
  readonly worktree: WorktreeEntry | null
  readonly cursor: KeeperCursor | undefined
}

export function presenceContextAnchor({
  entry,
  worktree,
  cursor,
}: PresenceContextAnchorInput): Omit<IdeContextFocus, 'activated_at_ms'> | null {
  if (!cursor?.file_path) return null
  const prId = worktree?.pr_number != null ? String(worktree.pr_number) : undefined
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
      prId,
      gitRef: worktree?.branch,
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

function PresenceChip({ entry, worktrees }: PresenceChipProps) {
  const isActive = entry.status === 'active'
  const cursor = cursorOverlaySignal.value.cursors.get(entry.keeper_id)
  const wt = worktrees.find(w => w.branch.startsWith(entry.keeper_id + '/'))
  const contextAnchor = presenceContextAnchor({ entry, worktree: wt ?? null, cursor })
  const contextSummary = presenceContextSummary(contextAnchor)

  const focusLabel = cursor?.file_path
    ? `${cursor.file_path.split('/').pop()}:${cursor.line}`
    : null

  const prBadge = wt?.pr_number != null && wt.pr_state != null
    ? prLabel(wt.pr_number, wt.pr_state)
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
      ${contextSummary ? html`
        <span style=${CONTEXT_BADGE_STYLE} title=${contextSummary.title}>${contextSummary.label}</span>
      ` : null}
      ${prBadge ? html`
        <span style=${{
          fontSize: 'var(--fs-9)',
          padding: '0 3px',
          borderRadius: 'var(--r-0)',
          background: wt?.pr_state === 'open' ? 'var(--color-status-ok)' : 'var(--color-bg-muted)',
          color: wt?.pr_state === 'open' ? 'var(--color-bg-page)' : 'var(--color-fg-muted)',
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
