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
import { StatTile } from '../common/stat-tile'
import { TimeAgo } from '../common/time-ago'
import { StatusDot } from '../common/status-dot'
import type { KpiCellKind } from '../kpi-shared'
import { KpiStripIsland } from '../kpi-strip-island'
import { LifelineBar } from '../lifeline-bar'
import { AgentAvatar } from './agent-avatar'
import { missionSnapshot } from '../../mission-store'
import { agents, tasks, keepers } from '../../store'
import type { Agent, Task, Keeper } from '../../types/core'
import type {
  DashboardMissionResponse,
  DashboardMissionSessionCard,
} from '../../types/dashboard-mission'
import { openAgentDetail } from '../agent-detail-state'
import { openTaskDetail } from '../goals/task-detail-state'
import { nowSecondsSignal, useNowSecondsTicker } from '../../lib/now-signal'

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
  task: Task
}

/** Derive a list of failing / offline agent alerts from the live agent list. */
export function deriveAgentAlerts(agentList: readonly Agent[]): AgentAlert[] {
  return agentList
    .filter(a => a.status === 'offline' || a.status === 'inactive')
    .map(a => ({
      name: a.name,
      display: a.koreanName && a.koreanName !== '' ? a.koreanName : a.name,
      reason: a.status === 'offline' ? 'Offline' : 'Inactive',
      severity: 'critical',
    }))
}

/** Derive a list of stalled tasks or tasks needing attention. */
export function deriveTaskAlerts(taskList: readonly Task[], nowMs: number): TaskAlert[] {
  const STALL_THRESHOLD_MS = 10 * 60 * 1000
  const alerts: TaskAlert[] = []
  for (const t of taskList) {
    if (t.status !== 'awaiting_verification') continue
    const updated = parseIsoMs(t.updated_at)
    if (updated !== null && nowMs - updated <= STALL_THRESHOLD_MS) continue
    alerts.push({
      id: t.id,
      title: t.title,
      status: 'awaiting_verification',
      assignee: t.assignee ?? null,
      severity: 'warn',
      task: t,
    })
  }
  return alerts
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
      return 'text-[var(--color-fg-muted)]'
  }
}

function AlertPanel({ agentAlerts, taskAlerts }: { agentAlerts: AgentAlert[]; taskAlerts: TaskAlert[] }) {
  const allAlerts = [...agentAlerts, ...taskAlerts]
  if (allAlerts.length === 0) return null
  const hasCritical = allAlerts.some(a => a.severity === 'critical')
  const criticalCount = allAlerts.filter(a => a.severity === 'critical').length
  const warnCount = allAlerts.filter(a => a.severity === 'warn').length

  return html`
    <${SectionCard}
      title="Alerts"
      tone=${hasCritical ? 'border-[var(--color-status-err)]/45' : 'border-[var(--color-status-warn)]/45'}
      right=${html`<${StatusDot} class=${hasCritical ? 'bg-[var(--color-status-err)]' : 'bg-[var(--color-status-warn)]'} />`}
      data-testid="overview-alerts"
    >
      <div class="mb-4">
        <${KpiStripIsland}
          cols=${2}
          cells=${[
            { label: 'Critical', value: String(criticalCount), kind: 'err' },
            { label: 'Warning', value: String(warnCount), kind: 'warn' },
          ]}
        />
      </div>
      <ul class="space-y-2 border-t border-[var(--color-border-default)] pt-4">
        ${allAlerts.map(
          a => html`
            <li
              class="flex items-start justify-between gap-4 cursor-pointer hover:bg-[var(--color-bg-secondary)]/50 p-1 -m-1 rounded-[var(--r-1)] transition-colors"
              onClick=${() => {
                if ('name' in a) openAgentDetail(a.name)
                else openTaskDetail(a.task)
              }}
            >
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
    <//>
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

export function computeFunnelCounts(taskList: readonly Task[], active: DashboardMissionSessionCard | null, nowMs = Date.now()): FunnelCounts {
  const todayMs = startOfTodayMs(nowMs)
  let created = 0
  let inProgress = 0
  let awaiting = 0
  let completed = 0
  for (const t of taskList) {
    const createdMs = parseIsoMs(t.created_at)
    if (createdMs !== null && createdMs >= todayMs) created += 1
    switch (t.status) {
      case 'claimed':
      case 'in_progress':
        inProgress += 1
        break
      case 'awaiting_verification':
        awaiting += 1
        break
      case 'done': {
        const completedMs = parseIsoMs(t.completed_at)
        if (completedMs !== null && completedMs >= todayMs) completed += 1
        break
      }
    }
  }
  const target =
    typeof active?.required_count === 'number' && active.required_count > 0
      ? active.required_count
      : null
  return { created, inProgress, awaiting, completed, target }
}

function startOfTodayMs(nowMs: number): number {
  const d = new Date(nowMs)
  d.setHours(0, 0, 0, 0)
  return d.getTime()
}

function parseIsoMs(iso: string | null | undefined): number | null {
  if (iso === null || iso === undefined || iso === '') return null
  const ms = Date.parse(iso)
  return Number.isFinite(ms) ? ms : null
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

export function progressPct(session: DashboardMissionSessionCard | null): number | null {
  if (!session) return null
  const req = session.required_count ?? 0
  if (req <= 0) return null
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
  const status = active.status ?? 'unknown'
  const members = active.member_names

  return html`
    <${SectionCard} title="Active Mission" data-testid="overview-party">
      <div class="space-y-4">
        <div class="flex items-center justify-between">
           <p class="text-xs font-semibold text-[var(--color-fg-default)] truncate flex-1 mr-4">
             ${active.goal}
           </p>
           <div class="flex -space-x-1.5">
             ${members.map(m => html`<${AgentAvatar} key=${m} name=${m} size="xs" class="ring-1 ring-[var(--color-bg-default)]" />`)}
           </div>
        </div>

        <div class="grid grid-cols-2 gap-3">
          <${StatTile}
            label="Progress"
            value=${progress === null ? 'n/a' : `${progress}%`}
            status=${progress !== null && progress > 80 ? 'ok' : progress !== null ? 'brass' : undefined}
            delta=${progress !== null ? { direction: progress > 50 ? 'up' : 'flat', text: progress > 80 ? 'on track' : `${progress}%` } : undefined}
          />
          <${StatTile}
            label="Status"
            value=${status.toUpperCase()}
            status=${status === 'running' || status === 'active' ? 'ok' : status === 'paused' ? 'warn' : 'brass'}
          />
        </div>
        ${progress !== null ? html`
          <div class="bar ${progress > 80 ? 'is-ok' : progress > 50 ? '' : 'is-warn'}">
            <span class="fill" style="width: ${progress}%"></span>
          </div>
        ` : null}
      </div>
    <//>
  `
}

// ─── Keeper Strip ────────────────────────────────────────────────────────────

function keeperStatusToneClass(status?: string | null): string {
  switch ((status ?? '').toLowerCase()) {
    case 'active':
    case 'live':
      return 'bg-[var(--color-status-ok)]'
    case 'busy':
    case 'executing':
      return 'bg-[var(--color-accent-fg)]'
    case 'offline':
    case 'dead':
      return 'bg-[var(--color-status-err)]'
    default:
      return 'bg-[var(--color-fg-muted)]'
  }
}

export function pickActiveKeepers(keeperList: readonly Keeper[], max = 3): Keeper[] {
  return [...keeperList]
    .sort((a, b) => {
      const tsA = parseIsoMs(a.last_heartbeat) ?? 0
      const tsB = parseIsoMs(b.last_heartbeat) ?? 0
      const pausedA = a.paused === true ? -1e15 : 0
      const pausedB = b.paused === true ? -1e15 : 0
      return tsB + pausedB - (tsA + pausedA)
    })
    .slice(0, max)
}

function KeeperStrip({ keeperList }: { keeperList: readonly Keeper[] }) {
  const activeKeepers = pickActiveKeepers(keeperList)

  if (activeKeepers.length === 0) {
    return html`
      <${SectionCard} title="Active Keepers" data-testid="overview-keepers-empty">
        <p class="text-2xs text-[var(--color-fg-muted)] italic">No active keepers</p>
      <//>
    `
  }

  return html`
    <${SectionCard} title="Fleet Lifeline" data-testid="overview-keepers">
      <div class="space-y-4">
        ${activeKeepers.slice(0, 1).map(
          k => html`
            <${LifelineBar}
              label=${k.koreanName && k.koreanName !== '' ? k.koreanName : k.name}
            />
          `,
        )}
        <ul class="flex flex-wrap gap-x-6 gap-y-2 border-t border-[var(--color-border-default)] pt-4">
          ${activeKeepers.slice(1).map(
            k => html`
              <li key=${k.name} class="flex items-center gap-2">
                <${StatusDot} class=${keeperStatusToneClass(k.status)} />
                <div class="min-w-0">
                  <p class="text-xs font-medium truncate">${k.koreanName && k.koreanName !== '' ? k.koreanName : k.name}</p>
                  ${k.last_heartbeat !== undefined
                    ? html`<${TimeAgo} timestamp=${k.last_heartbeat} class="text-3xs text-[var(--color-fg-muted)]" />`
                    : null}
                </div>
              </li>
            `,
          )}
        </ul>
      </div>
    <//>
  `
}

export function pickActiveSession(snap: DashboardMissionResponse | null): DashboardMissionSessionCard | null {
  if (snap === null) return null
  const running = snap.sessions.find(s => s.status === 'running' || s.status === 'active' || s.status === 'busy')
  return running ?? snap.sessions[0] ?? null
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
  const counts = useMemo(() => computeFunnelCounts(taskList, active, nowMs), [taskList, active, nowMs])
  const agentAlerts = useMemo(() => deriveAgentAlerts(agentList), [agentList])
  const taskAlerts = useMemo(() => deriveTaskAlerts(taskList, nowMs), [taskList, nowMs])
  return html`
    <div class="flex flex-col gap-8">
      <${AlertPanel} agentAlerts=${agentAlerts} taskAlerts=${taskAlerts} />
      <${FunnelCard} counts=${counts} />
      <${MissionPartyCard} active=${active} />
      <${KeeperStrip} keeperList=${keeperList} />
    </div>
  `
}
