// MASC Dashboard — Overview (slim home)
//
// "What's the party doing today?" in one glance, no scroll.
// 5 sections, top-to-bottom (V2):
//   0. Alert Panel     — failing agents and stalled tasks, actionable alerts first
//   1. (Removed: Highlight moved to Lab)
//   2. Funnel          — 5 task-count cells (new/active/verify/done/target)
//   3. Mission party   — one active session (goal, members, progress bar, blocker)
//   4. Keeper strip    — top three keepers by recent heartbeat

import { html } from 'htm/preact'
import { useMemo } from 'preact/hooks'
import { SectionCard } from '../common/card'
import { TimeAgo } from '../common/time-ago'
import { StatusDot } from '../common/status-dot'
import { RouteLink } from '../common/route-link'
import type { KpiCellKind } from '../kpi-shared'
import { barPercent } from '../bar-shared'
import { KpiStripIsland } from '../kpi-strip-island'
import { AgentAvatar } from './agent-avatar'
import { missionSnapshot } from '../../mission-store'
import { agents, tasks, keepers } from '../../store'
import type { Agent, Task, Keeper } from '../../types/core'
import type {
  DashboardMissionResponse,
  DashboardMissionSessionCard,
  OperatorAttentionItem,
} from '../../types/dashboard-mission'
import { openAgentDetail } from '../agent-detail-state'
import { nowSecondsSignal, useNowSecondsTicker } from '../../lib/now-signal'

const CARD = 'rounded border border-card-border/40 bg-card/18 p-4 shadow-sm shadow-black/8'

// ─── Alert Panel ─────────────────────────────────────────────────────────────

export interface AgentAlert {
  name: string
  display: string
  reason: string
  severity: 'critical' | 'warn'
}

export interface TaskAlert {
  id: string
  title: string
  status: string
  assignee: string | null
  severity: 'critical' | 'warn'
}

/** Derive a list of failing / offline agent alerts from the live agent list. */
export function deriveAgentAlerts(agentList: Agent[]): AgentAlert[] {
  return agentList
    .filter(a => a.status === 'offline' || a.status === 'inactive')
    .map(a => ({
      name: a.name,
      display: a.display_name || a.name,
      reason: a.status === 'offline' ? 'Offline' : 'Inactive',
      severity: 'critical',
    }))
}

/** Derive a list of stalled tasks or tasks needing attention. */
export function deriveTaskAlerts(taskList: Task[], nowMs: number): TaskAlert[] {
  // Simple heuristic: tasks in 'awaiting_verification' for too long
  const STALL_THRESHOLD_MS = 1000 * 60 * 10 // 10 mins
  return taskList
    .filter(t => t.status === 'awaiting_verification')
    .filter(t => {
      const updated = new Date(t.updated_at).getTime()
      return nowMs - updated > STALL_THRESHOLD_MS
    })
    .map(t => ({
      id: t.id,
      title: t.title,
      status: t.status,
      assignee: t.assignee,
      severity: 'warn',
    }))
}

export function severityToneClass(severity?: string | null): string {
  switch ((severity ?? '').toLowerCase()) {
    case 'critical':
    case 'high':
      return 'text-[var(--color-status-err)]'
    case 'warn':
    case 'medium':
      return 'text-[var(--color-status-warn)]'
    default:
      return 'text-[var(--color-fg-secondary)]'
  }
}

function AlertPanel({ agentAlerts, taskAlerts }: { agentAlerts: AgentAlert[]; taskAlerts: AlertItem[] }) {
  const allAlerts = [...agentAlerts, ...taskAlerts]
  if (allAlerts.length === 0) return null
  const hasCritical = allAlerts.some(a => a.severity === 'critical')

  return html`
    <section class=${`rounded border p-4 ${hasCritical ? 'border-[var(--color-status-err)] bg-[var(--color-status-err)]/5' : 'border-[var(--color-status-warn)] bg-[var(--color-status-warn)]/5'}`}>
      <header class="flex items-center gap-2 mb-3">
        <${StatusDot} tone=${hasCritical ? 'danger' : 'warn'} />
        <h2 class="text-xs font-bold uppercase tracking-wider">Alerts</h2>
      </header>
      <ul class="space-y-2">
        ${allAlerts.map(
          a => html`
            <li class="flex items-start justify-between gap-4">
              <div class="flex-1 min-w-0">
                <p class="text-xs font-semibold truncate">${'name' in a ? a.display : a.title}</p>
                <p class="text-2xs text-[var(--color-fg-muted)] truncate">${'reason' in a ? a.reason : a.status}</p>
              </div>
              <span class=${`text-2xs font-semibold uppercase tracking-wider shrink-0 ${severityToneClass(a.severity)}`}>
                ${a.severity}
              </span>
            </li>
          `,
        )}
      </ul>
    </section>
  `
}

// ─── Funnel ──────────────────────────────────────────────────────────────────

export interface FunnelCounts {
  created: number
  inProgress: number
  awaiting: number
  completed: number
  target: number | null
}

export function computeFunnelCounts(taskList: Task[], active: DashboardMissionSessionCard | null): FunnelCounts {
  const todayMs = startOfTodayMs()
  const created = taskList.filter(t => parseIsoMs(t.created_at) >= todayMs).length
  const inProgress = taskList.filter(t => t.status === 'claimed' || t.status === 'in_progress').length
  const awaiting = taskList.filter(t => t.status === 'awaiting_verification').length
  const completed = taskList.filter(t => t.status === 'done' && parseIsoMs(t.updated_at) >= todayMs).length
  const target = active?.target_value ? parseInt(active.target_value, 10) : null

  return { created, inProgress, awaiting, completed, target }
}

function startOfTodayMs(): number {
  const d = new Date()
  d.setHours(0, 0, 0, 0)
  return d.getTime()
}

function parseIsoMs(iso: string): number {
  return new Date(iso).getTime()
}

export function formatTargetRatio(counts: FunnelCounts): string {
  if (counts.target === null) return String(counts.completed)
  const pct = Math.min(100, Math.round((counts.completed / counts.target) * 100))
  return `${counts.completed}/${counts.target} (${pct}%)`
}

function FunnelCard({ counts }: { counts: FunnelCounts }) {
  const awaitingKind: KpiCellKind | undefined = counts.awaiting > 0 ? 'warn' : undefined
  return html`
    <${SectionCard} title="Today" right=${html`<span class="text-2xs text-[var(--color-fg-muted)]">task basis</span>`} data-testid="overview-funnel">
      <${KpiStripIsland}
        ariaLabel="Today funnel"
        cols=${5}
        cells=${[
          { variant: 'stacked', label: 'New', value: String(counts.created), testId: 'funnel-created' },
          { variant: 'stacked', label: 'Active', value: String(counts.inProgress), testId: 'funnel-in-progress' },
          { variant: 'stacked', label: 'Verify', value: String(counts.awaiting), kind: awaitingKind, testId: 'funnel-awaiting' },
          { variant: 'stacked', label: 'Done', value: String(counts.completed), kind: 'ok', testId: 'funnel-completed' },
          { variant: 'stacked', label: 'Target', value: formatTargetRatio(counts), testId: 'funnel-target' },
        ]}
      />
    <//>
  `
}

// ─── Mission Party ────────────────────────────────────────────────────────────

function progressPct(session: DashboardMissionSessionCard): number {
  const req = session.required_count ?? 0
  if (req <= 0) return 0
  const cur = session.seen_count ?? session.active_count ?? 0
  return Math.min(100, Math.round((cur / req) * 100))
}

function MissionPartyCard({ active }: { active: DashboardMissionSessionCard | null }) {
  if (!active) {
    return html`
      <${SectionCard} title="Active mission" data-testid="overview-party-empty">
        <p class="text-2xs text-[var(--color-fg-muted)] italic">No active mission</p>
      <//>
    `
  }

  const progress = progressPct(active)

  return html`
    <${SectionCard} title="Mission" data-testid="overview-party">
      <div class="space-y-4">
        <div>
          <p class="text-xs font-medium text-[var(--color-fg-default)]">${active.goal_id}</p>
          <div class="flex -space-x-2 mt-2">
            ${active.members.map(
              m => html`<${AgentAvatar} key=${m} name=${m} size="sm" class="ring-2 ring-[var(--color-bg-default)]" />`,
            )}
          </div>
        </div>

        <div class="space-y-1">
          <div class="flex items-center justify-between text-2xs">
            <span class="text-[var(--color-fg-secondary)]">Progress</span>
            <span class="font-medium">${progress}%</span>
          </div>
          <div class="h-1.5 w-full rounded-full bg-[var(--color-bg-tertiary)] overflow-hidden">
            <div class="h-full bg-[var(--color-status-ok)] transition-all" style="width: ${progress}%" />
          </div>
        </div>
      </div>
    <//>
  `
}

// ─── Keeper Strip ────────────────────────────────────────────────────────────

function keeperStatusToneClass(status?: string | null): string {
  switch ((status ?? '').toLowerCase()) {
    case 'active':
    case 'live':
      return 'tone-good'
    case 'busy':
    case 'executing':
      return 'tone-info'
    case 'offline':
    case 'dead':
      return 'tone-danger'
    default:
      return 'tone-muted'
  }
}

function pickActiveKeepers(keeperList: Keeper[], max = 3): Keeper[] {
  return [...keeperList]
    .sort((a, b) => {
      const tsA = new Date(a.last_seen_at || 0).getTime()
      const tsB = new Date(b.last_seen_at || 0).getTime()
      return tsB - tsA
    })
    .slice(0, max)
}

function KeeperStrip({ keeperList }: { keeperList: Keeper[] }) {
  const activeKeepers = pickActiveKeepers(keeperList)

  if (activeKeepers.length === 0) {
    return html`
      <${SectionCard} title="Active Keepers" data-testid="overview-keepers-empty">
        <p class="text-2xs text-[var(--color-fg-muted)] italic">No active keepers</p>
      <//>
    `
  }

  return html`
    <${SectionCard} title="Keepers" data-testid="overview-keepers">
      <ul class="flex flex-wrap gap-4">
        ${activeKeepers.map(
          k => html`
            <li key=${k.name} class="flex items-center gap-2">
              <${StatusDot} tone=${keeperStatusToneClass(k.status)} />
              <div class="min-w-0">
                <p class="text-xs font-medium truncate">${k.display_name_ko || k.name}</p>
                <${TimeAgo} timestamp=${k.last_seen_at} class="text-3xs text-[var(--color-fg-muted)]" />
              </div>
            </li>
          `,
        )}
      </ul>
    <//>
  `
}

export function pickActiveSession(snap: DashboardMissionResponse | null): DashboardMissionSessionCard | null {
  if (!snap) return null
  const running = snap.sessions.find(s => s.status === 'running' || s.status === 'active')
  return running || snap.sessions[0] || null
}

// ─── Root ────────────────────────────────────────────────────────────────────

export function Overview() {
  useNowSecondsTicker()
  const snap = missionSnapshot.value
  const taskList = tasks.value
  const keeperList = keepers.value
  const agentList = agents.value
  const nowMs = nowSecondsSignal.value * 1000
  const active = useMemo(() => pickActiveSession(snap), [snap])
  const counts = useMemo(() => computeFunnelCounts(taskList, active), [taskList, active])
  const attention = snap?.summary?.top_attention ?? null
  const agentAlerts = useMemo(() => deriveAgentAlerts(agentList), [agentList])
  const taskAlerts = useMemo(() => deriveTaskAlerts(taskList, nowMs), [taskList, nowMs])
  return html`
    <div class="flex flex-col gap-5">
      <${AlertPanel} agentAlerts=${agentAlerts} taskAlerts=${taskAlerts} />
      <${FunnelCard} counts=${counts} />
      <${MissionPartyCard} active=${active} />
      <${KeeperStrip} keeperList=${keeperList} />
    </div>
  `
}
