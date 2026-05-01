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
} from '../../types/dashboard-mission'
import { openAgentDetail } from '../agent-detail-state'
import { nowSecondsSignal, useNowSecondsTicker } from '../../lib/now-signal'

const CARD =
  'rounded-sm border border-card-border/60 border-l-accent/35 bg-[rgba(7,12,20,0.92)] p-2.5 shadow-[inset_0_1px_0_rgba(255,255,255,0.03)]'
const SECTION_HEAD =
  'font-mono text-3xs font-semibold uppercase tracking-[0.16em] text-text-muted'
const HEADER_ROW = `${SECTION_HEAD} mb-2 flex items-center justify-between gap-2 border-b border-card-border/40 pb-1.5`
const COCKPIT_CELL = 'rounded-sm border border-card-border/45 bg-[var(--white-3)] px-2 py-1.5'
const BRASS_RULE = 'h-px w-7 bg-accent/55'

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

/** Derive a list of failing / offline agent alerts from the live agent list.
 *
 * Severity rules:
 *   - "offline" or "inactive" → critical (agent is unreachable)
 *   - All other statuses are ignored (active/busy/idle are healthy).
 */
export function deriveAgentAlerts(agentList: readonly Agent[]): AgentAlert[] {
  const alerts: AgentAlert[] = []
  for (const a of agentList) {
    const status = a.status ?? 'idle'
    if (status === 'offline' || status === 'inactive') {
      alerts.push({
        name: a.name,
        display: a.koreanName && a.koreanName !== '' ? a.koreanName : a.name,
        reason: status === 'offline' ? 'Offline' : 'Inactive',
        severity: 'critical',
      })
    }
  }
  return alerts
}

/** Derive stalled task alerts.
 *
 * Severity rules:
 *   - awaiting_verification for > 10 minutes → warn (needs human review)
 *   - "cancelled" tasks are not surfaced here.
 */
export function deriveTaskAlerts(
  taskList: readonly Task[],
  nowMs: number = Date.now(),
): TaskAlert[] {
  const STALL_THRESHOLD_MS = 10 * 60 * 1000 // 10 minutes
  const alerts: TaskAlert[] = []
  for (const t of taskList) {
    if (t.status === 'awaiting_verification') {
      // Date.parse returns NaN for missing or non-ISO strings.  Use
      // Number.isFinite as the gate so an invalid `updated_at` is
      // treated as stale (silent-failure prevention) rather than
      // slipping through the `nowMs - NaN > THRESHOLD = false` hole
      // that the previous `=== null` check left.
      const parsedMs = t.updated_at ? Date.parse(t.updated_at) : NaN
      const isStale =
        !Number.isFinite(parsedMs) || nowMs - parsedMs > STALL_THRESHOLD_MS
      if (isStale) {
        alerts.push({
          id: t.id,
          title: t.title,
          status: 'awaiting_verification',
          assignee: t.assignee ?? null,
          severity: 'warn',
        })
      }
    }
  }
  return alerts
}

function AlertPanel({
  agentAlerts,
  taskAlerts,
}: {
  agentAlerts: AgentAlert[]
  taskAlerts: TaskAlert[]
}) {
  const total = agentAlerts.length + taskAlerts.length
  if (total === 0) return null

  const criticalCount = agentAlerts.filter(a => a.severity === 'critical').length

  return html`
    <section
      class="rounded-sm border border-l ${criticalCount > 0 ? 'border-[var(--color-status-err)]/45 border-l-[var(--color-status-err)] bg-[var(--color-status-err)]/6' : 'border-[var(--color-status-warn)]/45 border-l-[var(--color-status-warn)] bg-[var(--color-status-warn)]/6'} p-2.5 shadow-[inset_0_1px_0_rgba(255,255,255,0.03)]"
      aria-label="Attention alerts"
      data-testid="overview-alerts"
    >
      <header class="${HEADER_ROW}">
        <span class="flex min-w-0 items-center gap-2">
          <span aria-hidden="true" class=${BRASS_RULE}></span>
          <span class="${criticalCount > 0 ? 'text-[var(--color-status-err)]' : 'text-[var(--color-status-warn)]'}">
            Attention ${total}
          </span>
        </span>
        ${criticalCount > 0
          ? html`<span class="text-3xs text-[var(--color-status-err)]">${criticalCount} critical</span>`
          : null}
      </header>
      <ul class="flex flex-col gap-1.5">
        ${agentAlerts.map(a => html`
          <li
            key=${'agent:' + a.name}
            class="${COCKPIT_CELL} flex min-w-0 items-center gap-2 text-xs"
            data-testid="overview-alert-agent"
          >
            <span class="shrink-0 inline-block size-1.5 rounded-full bg-[var(--color-status-err)]"></span>
            <button
              type="button"
              class="text-[var(--color-fg-secondary)] hover:underline truncate cursor-pointer bg-transparent border-0 p-0 text-left text-xs"
              onClick=${() => openAgentDetail(a.name)}
            >${a.display}</button>
            <span class="ml-auto shrink-0 font-mono text-3xs uppercase tracking-[0.12em] text-[var(--color-status-err)]">${a.reason}</span>
          </li>
        `)}
        ${taskAlerts.map(t => html`
          <li
            key=${'task:' + t.id}
            class="${COCKPIT_CELL} flex min-w-0 items-center gap-2 text-xs"
            data-testid="overview-alert-task"
          >
            <span class="shrink-0 inline-block size-1.5 rounded-sm bg-[var(--color-status-warn)]"></span>
            <span class="text-[var(--color-fg-secondary)] truncate">${t.title}</span>
            <span class="ml-auto shrink-0 font-mono text-3xs uppercase tracking-[0.12em] text-[var(--color-status-warn)]">Awaiting verification</span>
          </li>
        `)}
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

function startOfTodayMs(now: number): number {
  const d = new Date(now)
  d.setHours(0, 0, 0, 0)
  return d.getTime()
}

function parseIsoMs(iso: string | null | undefined): number | null {
  if (iso === null || iso === undefined || iso === '') return null
  const ms = Date.parse(iso)
  return Number.isNaN(ms) ? null : ms
}

export function computeFunnelCounts(
  allTasks: readonly Task[],
  active: DashboardMissionSessionCard | null,
  now: number = Date.now(),
): FunnelCounts {
  const todayMs = startOfTodayMs(now)
  let created = 0
  let inProgress = 0
  let awaiting = 0
  let completed = 0
  for (const t of allTasks) {
    const createdMs = parseIsoMs(t.created_at)
    if (createdMs !== null && createdMs >= todayMs) created++
    switch (t.status) {
      case 'claimed':
      case 'in_progress':
        inProgress++
        break
      case 'awaiting_verification':
        awaiting++
        break
      case 'done': {
        const doneMs = parseIsoMs(t.completed_at)
        if (doneMs !== null && doneMs >= todayMs) completed++
        break
      }
      default:
        break
    }
  }
  const rawTarget = active?.required_count
  const target = typeof rawTarget === 'number' && rawTarget > 0 ? rawTarget : null
  return { created, inProgress, awaiting, completed, target }
}

export function formatTargetRatio(counts: FunnelCounts): string {
  if (counts.target === null) return String(counts.completed)
  const pct = Math.min(100, Math.round((counts.completed / counts.target) * 100))
  return `${counts.completed}/${counts.target} (${pct}%)`
}

function FunnelCard({ counts }: { counts: FunnelCounts }) {
  const awaitingKind: KpiCellKind | undefined = counts.awaiting > 0 ? 'warn' : undefined
  return html`
    <section class=${CARD} aria-label="Today funnel" data-testid="overview-funnel">
      <header class=${HEADER_ROW}>
        <span class="flex min-w-0 items-center gap-2">
          <span aria-hidden="true" class=${BRASS_RULE}></span>
          <h2 class="truncate">Today Funnel</h2>
        </span>
        <span class="shrink-0 text-3xs text-text-dim">task basis</span>
      </header>
      <div class="overflow-hidden rounded-sm border border-card-border/60 bg-card-border/60 [&_[role=list]]:!border-b-0 [&_[role=listitem]]:!rounded-none [&_[role=listitem]]:!border-0 [&_[role=listitem]]:!bg-[rgba(6,10,18,0.92)] [&_[role=listitem]]:!px-2 [&_[role=listitem]]:!py-1.5">
        <${KpiStripIsland}
          ariaLabel="Today funnel"
          variant="compact"
          cols=${5}
          cells=${[
            { variant: 'compact', bare: false, label: 'New', value: String(counts.created), testId: 'funnel-created' },
            { variant: 'compact', bare: false, label: 'Active', value: String(counts.inProgress), testId: 'funnel-in-progress' },
            { variant: 'compact', bare: false, label: 'Verify', value: String(counts.awaiting), kind: awaitingKind, testId: 'funnel-awaiting' },
            { variant: 'compact', bare: false, label: 'Done', value: String(counts.completed), kind: 'ok', testId: 'funnel-completed' },
            { variant: 'compact', bare: false, label: 'Target', value: formatTargetRatio(counts), testId: 'funnel-target' },
          ]}
        />
      </div>
    </section>
  `
}

// ─── Shared Tone ─────────────────────────────────────────────────────────────

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

// ─── Mission Party ───────────────────────────────────────────────────────────

export function pickActiveSession(
  snap: DashboardMissionResponse | null,
): DashboardMissionSessionCard | null {
  if (snap === null) return null
  if (snap.sessions.length === 0) return null
  for (const s of snap.sessions) {
    const status = (s.status ?? '').toLowerCase()
    if (status === 'active' || status === 'running' || status === 'busy') return s
  }
  return snap.sessions[0] ?? null
}

export function progressPct(active: DashboardMissionSessionCard | null): number | null {
  if (active === null) return null
  const req = active.required_count ?? 0
  if (req <= 0) return null
  const seen = active.seen_count ?? active.active_count ?? 0
  return barPercent((seen / req) * 100)
}

function MissionPartyCard({ active }: { active: DashboardMissionSessionCard | null }) {
  if (active === null) {
    return html`
      <section class=${CARD} aria-label="Active mission" data-testid="overview-party-empty">
        <header class=${HEADER_ROW}>
          <span class="flex min-w-0 items-center gap-2">
            <span aria-hidden="true" class=${BRASS_RULE}></span>
            <span>Active Mission</span>
          </span>
        </header>
        <p class="text-xs text-[var(--color-fg-muted)]">No active mission</p>
      </section>
    `
  }
  const pct = progressPct(active)
  const members = active.member_names.slice(0, 5)
  const extra = Math.max(0, active.member_names.length - members.length)
  const startedAt = active.started_at
  const blocker = active.blocker_summary
  return html`
    <section class=${CARD} aria-label="Active mission" data-testid="overview-party">
      <header class=${HEADER_ROW}>
        <span class="flex min-w-0 items-center gap-2">
          <span aria-hidden="true" class=${BRASS_RULE}></span>
          <h2 class="truncate">Active Mission</h2>
        </span>
        ${startedAt !== null && startedAt !== undefined && startedAt !== ''
          ? html`<${TimeAgo} timestamp=${startedAt} class="shrink-0 text-3xs text-text-dim" />`
          : null}
      </header>
      <p class="${COCKPIT_CELL} mb-2 line-clamp-2 text-xs text-[var(--color-fg-secondary)]" data-testid="overview-party-goal">
        ${active.goal !== '' ? active.goal : '(no goal)'}
      </p>
      ${members.length > 0
        ? html`
            <div class="${COCKPIT_CELL} mb-2 flex flex-wrap items-center gap-1.5">
              ${members.map(
                name => html`<${AgentAvatar} name=${name} status=${active.health ?? 'idle'} size="sm" />`,
              )}
              ${extra > 0
                ? html`<span class="font-mono text-3xs text-[var(--color-fg-muted)]">+${extra}</span>`
                : null}
            </div>
          `
        : null}
      ${pct !== null
        ? html`
            <div class="${COCKPIT_CELL} flex items-center gap-2" data-testid="overview-party-progress">
              <div class="h-1.5 flex-1 overflow-hidden rounded-sm bg-card-border/50">
                <div class="h-full bg-[var(--color-status-ok)]" style=${`width: ${pct}%`}></div>
              </div>
              <span class="font-mono text-3xs tabular-nums text-[var(--color-fg-muted)]">${pct}%</span>
            </div>
          `
        : null}
      ${blocker !== null && blocker !== undefined && blocker !== ''
        ? html`
            <div
              class="mt-2 rounded-sm border border-[var(--color-status-warn)]/40 border-l-[var(--color-status-warn)] bg-[var(--color-status-warn)]/10 px-2 py-1 font-mono text-3xs uppercase tracking-[0.1em] text-[var(--color-status-warn)]"
              data-testid="overview-party-blocker"
            >
              blocker: ${blocker}
            </div>
          `
        : null}
    </section>
  `
}

// ─── Keeper Strip ────────────────────────────────────────────────────────────

function keeperStatusToneClass(status: string): string {
  switch (status.toLowerCase()) {
    case 'active':
    case 'busy':
      return 'bg-[var(--color-status-ok)]'
    case 'offline':
    case 'inactive':
    case 'paused':
      return 'bg-[var(--color-status-err)]'
    default:
      return 'bg-[var(--color-fg-muted)]'
  }
}

export function pickActiveKeepers(all: readonly Keeper[], max: number = 3): Keeper[] {
  const scored: { k: Keeper; score: number }[] = []
  for (const k of all) {
    const hbIso = k.last_heartbeat
    const hb = hbIso !== undefined ? Date.parse(hbIso) : Number.NaN
    const hbScore = Number.isNaN(hb) ? 0 : hb
    const pausedPenalty = k.paused === true ? -1e15 : 0
    scored.push({ k, score: pausedPenalty + hbScore })
  }
  scored.sort((a, b) => b.score - a.score)
  return scored.slice(0, max).map(s => s.k)
}

function KeeperStrip({ keeperList }: { keeperList: readonly Keeper[] }) {
  const top = pickActiveKeepers(keeperList, 3)
  if (top.length === 0) {
    return html`
      <section class=${CARD} aria-label="Active keepers" data-testid="overview-keepers-empty">
        <header class=${HEADER_ROW}>
          <span class="flex min-w-0 items-center gap-2">
            <span aria-hidden="true" class=${BRASS_RULE}></span>
            <span>Active Keepers</span>
          </span>
        </header>
        <p class="text-xs text-[var(--color-fg-muted)]">No active keepers</p>
      </section>
    `
  }
  return html`
    <section class=${CARD} aria-label="Active keepers" data-testid="overview-keepers">
      <header class=${HEADER_ROW}>
        <span class="flex min-w-0 items-center gap-2">
          <span aria-hidden="true" class=${BRASS_RULE}></span>
          <span>Active Keepers</span>
        </span>
      </header>
      <ul class="flex flex-col gap-1.5">
        ${top.map(
          k => html`
            <li class="${COCKPIT_CELL} flex min-w-0 items-center gap-2">
              <${StatusDot} size="sm" class=${keeperStatusToneClass(k.status)} />
              <${RouteLink}
                tab="monitoring"
                params=${{ section: 'keepers', keeper: k.name }}
                class="truncate text-xs text-[var(--color-fg-secondary)] hover:underline"
              >
                ${k.koreanName !== undefined && k.koreanName !== '' ? k.koreanName : k.name}
              <//>
              ${k.last_heartbeat !== undefined
                ? html`
                    <${TimeAgo}
                      timestamp=${k.last_heartbeat}
                      class="ml-auto shrink-0 text-3xs text-[var(--color-fg-muted)]"
                    />
                  `
                : null}
            </li>
          `,
        )}
      </ul>
    </section>
  `
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
  const agentAlerts = useMemo(() => deriveAgentAlerts(agentList), [agentList])
  const taskAlerts = useMemo(() => deriveTaskAlerts(taskList, nowMs), [taskList, nowMs])
  return html`
    <div class="flex flex-col gap-2.5">
      <${AlertPanel} agentAlerts=${agentAlerts} taskAlerts=${taskAlerts} />
      <${FunnelCard} counts=${counts} />
      <${MissionPartyCard} active=${active} />
      <${KeeperStrip} keeperList=${keeperList} />
    </div>
  `
}
