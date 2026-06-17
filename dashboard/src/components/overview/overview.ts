// MASC Dashboard — Overview (slim home)
//
// "What's the party doing today?" in one glance, no scroll.
// 5 sections, top-to-bottom (V2):
//   0. Alert Panel     — failing agents and stalled tasks, actionable alerts first
//   1. (Removed: Highlight moved to Lab)
//   2. Funnel          — 5 task-count cells (new/active/verify/done/target)
//   3. Mission party   — one active session (goal, members, progress bar, blocker)
//   4. Keeper strip    — top three keepers by recent heartbeat
//
// Keeper-v2 port additions:
//   - Header surface  — namespace, keeper count, operator, live clock
//   - KPI strip       — running / attention / context pressure / avg ctx / tasks / traces
//   - Attention queue — keepers flagged for operator attention with reason + action
//   - Telemetry bars  — deterministic 28-bar trace histogram
//   - Keeper fleet    — full keeper grid with status, model, context meter

import { html } from 'htm/preact'
import { useEffect, useMemo } from 'preact/hooks'
import { SectionCard } from '../common/card'
import { StatTile } from '../common/stat-tile'
import { TimeAgo } from '../common/time-ago'
import { StatusDot } from '../common/status-dot'
import type { KpiCellKind } from '../kpi-shared'
import { KpiStripIsland } from '../kpi-strip-island'
import { AgentAvatar } from './agent-avatar'
import { missionSnapshot } from '../../mission-store'
import { agents, tasks, keepers, messages, boardPosts } from '../../store'
import type { Agent, Task, Keeper, Message, BoardPost } from '../../types/core'
import { SYSTEM_ACTOR_NAME } from '../../types/core'
import type {
  DashboardMissionResponse,
  DashboardMissionSessionCard,
} from '../../types/dashboard-mission'
import { openAgentDetail } from '../agent-detail-state'
import { openTaskDetail } from '../goals/task-detail-state'
import { nowSecondsSignal, useNowSecondsTicker } from '../../lib/now-signal'
import { keeperDisplayStatus } from '../../lib/keeper-runtime-display'
import { isKeeperPaused } from '../../lib/keeper-predicates'
import { isAgentOffline } from '../../lib/agent-status'
import { keeperRowLooksRunning } from '../../runtime-counts'
import { get } from '../../api/core'
import { createAsyncResource, type AsyncResource } from '../../lib/async-state'
import { navigate } from '../../router'
import {
  normalizeSurfaceReadinessPayload,
  summarizeSurfaceReadiness,
  type SurfaceReadinessEntry,
} from '../surface-readiness-panel'

// ─── Attention / Keeper v2 helpers ───────────────────────────────────────────

export interface KeeperAttentionReason {
  sev: 'bad' | 'warn'
  text: string
  act: string
}

const DEFAULT_ATTENTION_REASON: KeeperAttentionReason = { sev: 'warn', text: '점검 필요', act: '대화 열기' }

/** Map a keeper's runtime/trust state to a human attention reason.
 *  Mirrors the hard-coded ATTN_REASON table from keeper-v2/overview.jsx
 *  but derives the text from live dashboard fields. */
export function deriveKeeperAttentionReason(keeper: Keeper): KeeperAttentionReason {
  const blockerLabel = keeper.runtime_blocker_class?.replace(/_/g, ' ')
  const attention = keeper.attention_reason?.trim() || keeper.trust?.attention_reason?.trim()
  const nextAction = keeper.next_human_action?.trim() || keeper.trust?.next_human_action?.trim()

  if (keeper.runtime_blocker_continue_gate) {
    return {
      sev: 'warn',
      text: attention ?? blockerLabel ?? '계속 진행 승인 대기',
      act: nextAction ?? '승인 검토',
    }
  }

  if (keeper.runtime_blocker_class === 'awaiting_operator') {
    return { sev: 'warn', text: attention ?? '운영자 조치 대기', act: nextAction ?? '승인 검토' }
  }

  const isCritical = keeper.runtime_blocker_class === 'exception'
    || keeper.runtime_blocker_class === 'turn_failures'
    || keeper.runtime_blocker_class === 'heartbeat_failures'
    || keeper.lifecycle_phase === 'Dead'
    || keeper.lifecycle_phase === 'Crashed'

  if (isCritical) {
    return {
      sev: 'bad',
      text: attention ?? blockerLabel ?? '심각한 실행 장애',
      act: nextAction ?? '재시작',
    }
  }

  if (attention) {
    return { sev: 'warn', text: attention, act: nextAction ?? '대화 열기' }
  }

  return DEFAULT_ATTENTION_REASON
}

/** Keepers flagged for operator attention. */
export function pickAttentionKeepers(keeperList: readonly Keeper[]): Keeper[] {
  return keeperList.filter(k =>
    k.needs_attention === true
    || k.trust?.needs_attention === true
    || k.runtime_blocker_continue_gate === true
    || k.runtime_blocker_class === 'awaiting_operator'
    || !!k.attention_reason?.trim()
    || !!k.trust?.attention_reason?.trim(),
  )
}

// ─── KPI stats ───────────────────────────────────────────────────────────────

export interface OverviewStats {
  run: number
  att: number
  hot: number
  avgCtx: number
  tasks: number
  traces: number
  total: number
}

function keeperTraceCount(keeper: Keeper): number {
  return keeper.total_turns ?? keeper.turn_count ?? keeper.autonomous_turn_count ?? 0
}

function keeperModelLabel(keeper: Keeper): string {
  const model = keeper.active_model ?? keeper.model ?? keeper.primary_model ?? keeper.last_model_used ?? ''
  return model.replace(/^claude-/, '')
}

export function computeOverviewStats(keeperList: readonly Keeper[], taskList: readonly Task[]): OverviewStats {
  const total = keeperList.length
  const run = keeperList.filter(keeperRowLooksRunning).length
  const att = pickAttentionKeepers(keeperList).length
  const hot = keeperList.filter(k => (k.context_ratio ?? 0) >= 0.85).length
  const traces = keeperList.reduce((sum, k) => sum + keeperTraceCount(k), 0)

  const keeperNames = new Set(keeperList.map(k => k.name.toLowerCase()))
  const tasks = taskList.filter(t => t.assignee && keeperNames.has(t.assignee.toLowerCase())).length

  const liveCtx = keeperList.filter(k => keeperRowLooksRunning(k) && typeof k.context_ratio === 'number')
  const avgCtx = liveCtx.length
    ? Math.round(liveCtx.reduce((sum, k) => sum + (k.context_ratio ?? 0), 0) / liveCtx.length * 100)
    : 0

  return { run, att, hot, avgCtx, tasks, traces, total }
}

// ─── Telemetry bars ──────────────────────────────────────────────────────────

export const OVERVIEW_TELEMETRY_BAR_COUNT = 28

/** Deterministic 28-bar telemetry histogram seeded from keeper trace counts.
 *  Each bar is a 0-1 saturation value; indices 9 and 22 are synthetic spikes. */
export function telemetryBars(keeperList: readonly Keeper[]): number[] {
  const seed = keeperList.reduce((sum, k) => sum + keeperTraceCount(k), 0)
  const bars: number[] = []
  let s = seed
  for (let i = 0; i < OVERVIEW_TELEMETRY_BAR_COUNT; i++) {
    s = (s * 1103515245 + 12345) & 0x7fffffff
    const base = 0.25 + ((s >> 8) % 1000) / 1000 * 0.7
    const spike = i === 9 || i === 22 ? 1 : base
    bars.push(Math.min(1, spike))
  }
  return bars
}

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
    .filter(a => isAgentOffline(a))
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
      return 'text-destructive'
    case 'warn':
    case 'medium':
      return 'text-warning'
    default:
      return 'text-text-tertiary'
  }
}

// ─── Fleet ticker ───────────────────────────────────────────────────────────

export type FleetTickerKind = 'task' | 'message' | 'board' | 'keeper'

export interface FleetTickerEvent {
  id: string
  timestamp: string
  timestampMs: number
  actor: string
  label: string
  text: string
  kind: FleetTickerKind
  tone: 'ok' | 'warn' | 'err' | 'info' | 'idle'
}

function trimTickerText(text: string, max = 96): string {
  const normalized = text.replace(/\s+/g, ' ').trim()
  if (normalized.length <= max) return normalized
  return `${normalized.slice(0, max - 3)}...`
}

function firstNonEmptyTrimmed(...values: Array<string | null | undefined>): string | null {
  for (const value of values) {
    if (typeof value !== 'string') continue
    const trimmed = value.trim()
    if (trimmed !== '') return trimmed
  }
  return null
}

function taskTickerTone(status?: Task['status']): FleetTickerEvent['tone'] {
  switch (status) {
    case 'done':
      return 'ok'
    case 'awaiting_verification':
      return 'warn'
    case 'cancelled':
      return 'err'
    case 'claimed':
    case 'in_progress':
      return 'info'
    default:
      return 'idle'
  }
}

function keeperTickerTone(status?: string | null): FleetTickerEvent['tone'] {
  switch ((status ?? '').toLowerCase()) {
    case 'active':
    case 'live':
      return 'ok'
    case 'busy':
    case 'executing':
      return 'info'
    case 'offline':
    case 'dead':
    case 'stopped':
    case 'unbooted':
      return 'err'
    case 'paused':
    case 'inactive':
      return 'warn'
    default:
      return 'idle'
  }
}

function pushTickerEvent(out: FleetTickerEvent[], event: Omit<FleetTickerEvent, 'timestampMs'>) {
  const timestampMs = parseIsoMs(event.timestamp)
  if (timestampMs === null) return
  const text = trimTickerText(event.text)
  if (text === '') return
  out.push({ ...event, timestampMs, text })
}

export function deriveFleetTickerEvents({
  taskList,
  messageList,
  boardPostList,
  keeperList,
  max = 6,
}: {
  taskList: readonly Task[]
  messageList: readonly Message[]
  boardPostList: readonly BoardPost[]
  keeperList: readonly Keeper[]
  max?: number
}): FleetTickerEvent[] {
  const events: FleetTickerEvent[] = []
  for (const task of taskList) {
    const timestamp = task.updated_at ?? task.completed_at ?? task.created_at
    if (!timestamp) continue
    pushTickerEvent(events, {
      id: `task:${task.id}`,
      timestamp,
      actor: task.assignee ?? 'unassigned',
      label: task.status ?? '(unknown status)',
      text: task.title,
      kind: 'task',
      tone: taskTickerTone(task.status),
    })
  }
  for (const message of messageList) {
    if (!message.timestamp) continue
    pushTickerEvent(events, {
      id: `message:${message.id ?? message.seq ?? message.timestamp}`,
      timestamp: message.timestamp,
      actor: message.from ?? SYSTEM_ACTOR_NAME,
      label: message.type ?? '(unknown type)',
      text: message.content,
      kind: 'message',
      tone: 'info',
    })
  }
  for (const post of boardPostList) {
    pushTickerEvent(events, {
      id: `board:${post.id}`,
      timestamp: post.updated_at || post.created_at,
      actor: firstNonEmptyTrimmed(post.author) ?? 'board',
      label: post.post_kind ?? '(unknown post_kind)',
      text: firstNonEmptyTrimmed(post.title, post.content, post.body) ?? '',
      kind: 'board',
      tone: post.post_kind === 'system' ? 'warn' : 'info',
    })
  }
  for (const keeper of keeperList) {
    if (!keeper.last_heartbeat) continue
    const displayStatus = keeperDisplayStatus(keeper)
    pushTickerEvent(events, {
      id: `keeper:${keeper.name}`,
      timestamp: keeper.last_heartbeat,
      actor: keeper.koreanName && keeper.koreanName !== '' ? keeper.koreanName : keeper.name,
      label: 'heartbeat',
      text: keeperStatusLabel(displayStatus),
      kind: 'keeper',
      tone: keeperTickerTone(displayStatus),
    })
  }
  return events
    .sort((a, b) => b.timestampMs - a.timestampMs)
    .slice(0, Math.max(0, max))
}

function tickerToneClass(tone: FleetTickerEvent['tone']): string {
  switch (tone) {
    case 'ok':
      return 'text-success'
    case 'warn':
      return 'text-warning'
    case 'err':
      return 'text-destructive'
    case 'info':
      return 'text-brand'
    default:
      return 'text-text-tertiary'
  }
}

function FleetTicker({ events }: { events: FleetTickerEvent[] }) {
  if (events.length === 0) return null
  return html`
    <${SectionCard}
      label="Fleet Ticker"
      variant="standard"
      class="v2-overview-ticker mx-6"
      right=${html`<span class="text-[12px] text-text-tertiary">latest ${events.length}</span>`}      data-testid="overview-fleet-ticker"
    >
      <div
        role="list"
        aria-label="Recent fleet events"
        class="flex min-w-0 gap-2 overflow-x-auto pb-1"
      >
        ${events.map(event => html`
          <div
            key=${event.id}
            role="listitem"
            class="v2-overview-ticker-card ss-card grid min-w-[15rem] max-w-[22rem] max-[768px]:min-w-[12rem] flex-[0_0_auto] gap-1 border border-border px-3 py-2"          >
            <div class="flex min-w-0 items-center gap-2 font-mono text-[11px] uppercase tracking-wider">              <span class=${tickerToneClass(event.tone)}>${event.kind}</span>
              <span class="truncate text-text-tertiary">${event.actor}</span>
              <${TimeAgo} timestamp=${event.timestamp} class="ml-auto shrink-0 text-text-disabled" />
            </div>
            <div class="truncate text-[14px] font-semibold text-text-primary">${event.text}</div>
            <div class="truncate font-mono text-[11px] uppercase tracking-wider text-text-disabled">${event.label}</div>          </div>
        `)}
      </div>
    <//>
  `
}

function AlertPanel({ agentAlerts, taskAlerts }: { agentAlerts: AgentAlert[]; taskAlerts: TaskAlert[] }) {
  const allAlerts = [...agentAlerts, ...taskAlerts]
  if (allAlerts.length === 0) return null
  const hasCritical = allAlerts.some(a => a.severity === 'critical')
  const criticalCount = allAlerts.filter(a => a.severity === 'critical').length
  const warnCount = allAlerts.filter(a => a.severity === 'warn').length

  return html`
    <${SectionCard}
      label="Alerts"
      variant="standard"
      class="v2-overview-alerts mx-6"
      tone=${hasCritical ? 'border-destructive/45' : 'border-warning/45'}
      right=${html`<${StatusDot} class=${hasCritical ? 'bg-destructive' : 'bg-warning'} />`}      data-testid="overview-alerts"
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
      <ul class="space-y-2 border-t border-border pt-4">
        ${allAlerts.map(
          a => html`
            <li
              class="flex items-start justify-between gap-4 cursor-pointer p-1 -m-1 rounded-md"
              onClick=${() => {
                if ('name' in a) openAgentDetail(a.name)
                else openTaskDetail(a.task)
              }}
            >
              <div class="flex-1 min-w-0">
                <p class="text-[14px] font-semibold truncate text-text-primary">${'name' in a ? a.display : a.title}</p>
                <p class="text-[12px] text-text-tertiary truncate">${'reason' in a ? a.reason : a.status}</p>              </div>
              <span class=${`chip sm shrink-0 ${a.severity === 'critical' ? 'is-err' : 'is-warn'}`}>
                ${a.severity.toUpperCase()}
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

function funnelSegStyle(pct: number): string {
  return pct > 0 ? `width:${pct.toFixed(1)}%` : ''
}

function FunnelCard({ counts }: { counts: FunnelCounts }) {
  const awaitingKind: KpiCellKind | undefined = counts.awaiting > 0 ? 'warn' : undefined
  const total = counts.created + counts.inProgress + counts.awaiting + counts.completed
  const segPct = (n: number) => total > 0 ? (n / total) * 100 : 0
  return html`
    <${SectionCard} label="Today" variant="standard" class="v2-overview-funnel mx-6" right=${html`<span class="text-[12px] text-text-tertiary">task basis</span>`} data-testid="overview-funnel">      <${KpiStripIsland}
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
      ${total > 0 ? html`
        <div class="bar-seg mt-4" style="height:var(--sp-1)" data-testid="funnel-seg">
          ${counts.inProgress > 0 ? html`<span class="seg-idle" style=${funnelSegStyle(segPct(counts.inProgress))}></span>` : null}
          ${counts.awaiting > 0 ? html`<span class="seg-warn" style=${funnelSegStyle(segPct(counts.awaiting))}></span>` : null}
          ${counts.completed > 0 ? html`<span class="seg-ok" style=${funnelSegStyle(segPct(counts.completed))}></span>` : null}
          ${counts.created > 0 ? html`<span class="seg-idle" style=${funnelSegStyle(segPct(counts.created))}></span>` : null}
        </div>
      ` : null}
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
      <${SectionCard} label="Active mission" variant="standard" class="v2-overview-party mx-6" data-testid="overview-party-empty">
        <p class="text-[12px] text-text-tertiary italic">No active mission</p>      <//>
    `
  }

  const progress = progressPct(active)
  const status = active.status ?? 'unknown'
  const members = active.member_names

  return html`
    <${SectionCard} label="Active Mission" variant="standard" class="v2-overview-party mx-6" data-testid="overview-party">      <div class="space-y-4">
        <div class="flex items-center justify-between">
           <p class="text-[14px] font-semibold text-text-primary truncate flex-1 mr-4">             ${active.goal}
           </p>
           <div class="flex -space-x-1.5">
             ${members.map(m => html`<${AgentAvatar} key=${m} name=${m} size="xs" class="ring-1 ring-surface-page" />`)}           </div>
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

function keeperPillClass(status?: string | null): string {
  switch ((status ?? '').toLowerCase()) {
    case 'active':
    case 'live':
      return 'pill is-ok'
    case 'busy':
    case 'executing':
      return 'pill is-running'
    case 'offline':
    case 'dead':
    case 'stopped':
    case 'unbooted':
      return 'pill is-err'
    default:
      return 'pill is-paused'
  }
}


function keeperStatusLabel(status?: string | null): string {
  switch ((status ?? '').toLowerCase()) {
    case 'active': case 'live': return 'Active'
    case 'busy': case 'executing': return 'Busy'
    case 'paused': return 'Paused'
    case 'offline': return 'Offline'
    case 'dead': return 'Dead'
    case 'stopped': return 'Stopped'
    case 'unbooted': return 'Unbooted'
    default: return status ?? 'Unknown'
  }
}

export function pickActiveKeepers(keeperList: readonly Keeper[], max = 3): Keeper[] {
  return [...keeperList]
    .sort((a, b) => {
      const tsA = parseIsoMs(a.last_heartbeat) ?? 0
      const tsB = parseIsoMs(b.last_heartbeat) ?? 0
      const pausedA = isKeeperPaused(a) ? -1e15 : 0
      const pausedB = isKeeperPaused(b) ? -1e15 : 0
      return tsB + pausedB - (tsA + pausedA)
    })
    .slice(0, max)
}

function KeeperStrip({ keeperList }: { keeperList: readonly Keeper[] }) {
  const activeKeepers = pickActiveKeepers(keeperList)

  if (activeKeepers.length === 0) {
    return html`
      <${SectionCard} label="Active Keepers" variant="standard" class="v2-overview-keepers mx-6" data-testid="overview-keepers-empty">
        <p class="text-[12px] text-text-tertiary italic">No active keepers</p>      <//>
    `
  }

  return html`
    <${SectionCard} label="Active Keepers" variant="standard" class="v2-overview-keepers mx-6" data-testid="overview-keepers">      <ul class="flex flex-wrap gap-x-6 gap-y-2">
        ${activeKeepers.map(
          k => {
            const displayStatus = keeperDisplayStatus(k)
            return html`
            <li key=${k.name} class="flex items-center gap-2">
              <div class="min-w-0">
                <p class="text-[14px] font-medium truncate text-text-primary">${k.koreanName && k.koreanName !== '' ? k.koreanName : k.name}</p>                ${k.last_heartbeat !== undefined
                  ? html`<${TimeAgo} timestamp=${k.last_heartbeat} class="text-[11px] text-text-tertiary" />`                  : null}
              </div>
              <span class="${keeperPillClass(displayStatus)} text-[11px] shrink-0">${keeperStatusLabel(displayStatus)}</span>            </li>
            `
          },
        )}
      </ul>
    <//>
  `
}

export function pickActiveSession(snap: DashboardMissionResponse | null): DashboardMissionSessionCard | null {
  if (snap === null) return null
  const running = snap.sessions.find(s => s.status === 'running' || s.status === 'active' || s.status === 'busy')
  return running ?? snap.sessions[0] ?? null
}

// ─── Surface Readiness Summary ───────────────────────────────────────────────

const surfaceReadinessResource: AsyncResource<SurfaceReadinessEntry[]> = createAsyncResource()

function loadSurfaceReadiness(): Promise<void> {
  return surfaceReadinessResource.load(async () => {
    const raw = await get<unknown>('/api/v1/dashboard/surface-readiness')
    const data = normalizeSurfaceReadinessPayload(raw)
    return data.surfaces
  })
}

function SurfaceReadinessSummary() {
  useEffect(() => { void loadSurfaceReadiness() }, [])

  const state = surfaceReadinessResource.state.value
  if (state.status !== 'loaded') return null

  const summary = summarizeSurfaceReadiness(state.data)
  return html`
    <${SectionCard} label="Surface Readiness" variant="standard" class="v2-overview-readiness mx-6" data-testid="overview-surface-readiness">      <${KpiStripIsland}
        ariaLabel="Surface readiness summary"
        cols=${3}
        cells=${[
          { variant: 'stacked', label: 'Main', value: String(summary.main), testId: 'sr-main' },
          { variant: 'stacked', label: 'Total', value: String(summary.total), testId: 'sr-total' },
          { variant: 'stacked', label: 'Gaps', value: String(summary.gaps), kind: summary.gaps > 0 ? 'warn' : 'ok', testId: 'sr-gaps' },
        ]}
      />
    <//>
  `
}

// ─── Keeper-v2 overview surfaces ─────────────────────────────────────────────

function nowHMKst(): string {
  const d = new Date()
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${pad(d.getHours())}:${pad(d.getMinutes())}`
}

function OverviewHeader({ stats }: { stats: OverviewStats }) {
  useNowSecondsTicker()
  const clock = nowHMKst()
  return html`
    <header class="v2-overview-head flex flex-wrap items-end justify-between gap-3 px-6" data-testid="overview-head">
      <div>
        <h1 class="text-[20px] font-semibold tracking-normal text-text-secondary">운영 개요</h1>
        <p class="m-0 mt-1 text-[12px] text-text-tertiary">
          <span title="최상위 조정 범위 — 모든 room/keeper를 담는 root namespace">namespace <span class="font-mono text-text-secondary">masc-mcp</span></span>
          <span class="mx-1 text-text-disabled">·</span>          <span title="등록된 keeper 총 수">Keeper ${stats.total}</span>
          <span class="mx-1 text-text-disabled">·</span>
          <span title="현재 토큰으로 로그인한 운영자">operator <b class="text-text-secondary">@operator</b></span>
        </p>
      </div>
      <div class="v2-overview-clock font-mono text-[13px] text-text-secondary" data-testid="overview-clock">
        ${clock} <span class="text-text-tertiary">KST</span>
      </div>
    </header>
  `
}

function OverviewKpiStrip({ stats }: { stats: OverviewStats }) {
  return html`
    <${SectionCard} label="Fleet KPIs" variant="standard" class="v2-overview-kpis mx-6" data-testid="overview-kpis">      <${KpiStripIsland}
        ariaLabel="Fleet KPIs"
        cols=${6}
        cells=${[
        { variant: 'stacked', label: '실행 중', value: String(stats.run), caption: `/ ${stats.total}`, kind: 'ok', testId: 'kpi-run' },
        { variant: 'stacked', label: '주의 필요', value: String(stats.att), kind: stats.att > 0 ? 'err' : undefined, testId: 'kpi-att' },
        { variant: 'stacked', label: '컨텍스트 압박', value: String(stats.hot), caption: '≥85%', kind: stats.hot > 0 ? 'warn' : undefined, testId: 'kpi-hot' },
        { variant: 'stacked', label: '평균 컨텍스트', value: `${stats.avgCtx}%`, testId: 'kpi-avg-ctx' },
        { variant: 'stacked', label: '소유 태스크', value: String(stats.tasks), testId: 'kpi-tasks' },
        { variant: 'stacked', label: '누적 trace', value: stats.traces.toLocaleString(), testId: 'kpi-traces' },
      ]}
      />
    <//>
  `
}

function attentionToneClass(sev: KeeperAttentionReason['sev']): string {
  return sev === 'bad' ? 'bg-destructive' : 'bg-warning'
}

function OverviewAttentionPanel({ keeperList }: { keeperList: readonly Keeper[] }) {
  const attn = useMemo(
    () => pickAttentionKeepers(keeperList).slice().sort((a, b) => {
      const aBad = deriveKeeperAttentionReason(a).sev === 'bad'
      const bBad = deriveKeeperAttentionReason(b).sev === 'bad'
      if (aBad && !bBad) return -1
      if (!aBad && bBad) return 1
      return (b.context_ratio ?? 0) - (a.context_ratio ?? 0)
    }),
    [keeperList],
  )

  if (attn.length === 0) {
    return html`
      <${SectionCard} label="주의 필요" variant="standard" class="v2-overview-attention mx-6" data-testid="overview-attention">
        <p class="text-[12px] text-text-tertiary italic">모든 keeper 정상</p>      <//>
    `
  }

  return html`
    <${SectionCard}
      label="주의 필요"
      variant="standard"
      class="v2-overview-attention mx-6"
      right=${html`<span class="text-[12px] text-text-tertiary">${attn.length}</span>`}      data-testid="overview-attention"
    >
      <div class="v2-overview-attention-list flex flex-col gap-2">
        ${attn.map(k => {
          const reason = deriveKeeperAttentionReason(k)
          const displayName = k.koreanName && k.koreanName !== '' ? k.koreanName : k.name
          return html`
            <div
              key=${k.name}
              class="v2-overview-attention-row flex cursor-pointer items-center gap-3 rounded-[var(--r-1)] border border-border bg-card p-2 transition-colors hover:border-border hover:bg-surface-subtle"              onClick=${() => navigate('monitoring', { section: 'agents', keeper: k.name })}
              data-testid=${`attention-row-${k.name}`}
            >
              <${AgentAvatar} name=${k.name} size="sm" status=${keeperDisplayStatus(k)} />
              <div class="flex-1 min-w-0">
                <div class="flex items-center gap-2 text-[14px] font-semibold text-text-primary">                  ${displayName}
                  <span class="font-mono text-[12px] text-text-tertiary">${k.name}</span>                </div>
                <div class="flex items-center gap-1.5 text-[12px] text-text-tertiary">                  <span class="inline-block size-1.5 rounded-full ${attentionToneClass(reason.sev)}"></span>
                  <span class=${reason.sev === 'bad' ? 'text-destructive' : 'text-warning'}>${reason.text}</span>
                </div>
              </div>
              <button
                type="button"
                class="text-[12px] font-medium text-brand hover:underline min-h-11 px-2"                onClick=${(e: MouseEvent) => {
                  e.stopPropagation()
                  navigate('monitoring', { section: 'agents', keeper: k.name })
                }}
              >
                ${reason.act} →
              </button>
            </div>
          `
        })}
      </div>
    <//>
  `
}

function OverviewTelemetry({ bars }: { bars: number[] }) {
  return html`
    <${SectionCard}
      label="텔레메트리"
      variant="standard"
      class="v2-overview-telemetry mx-6"
      right=${html`<span class="text-[12px] font-mono text-text-tertiary">trace / 5m · last 140m</span>`}      data-testid="overview-telemetry"
    >
      <div class="v2-overview-bars flex h-24 items-end gap-0.5" role="img" aria-label="Trace telemetry histogram">
        ${bars.map((b, i) => html`
          <span
            key=${i}
            class="v2-overview-bar flex-1 rounded-sm ${b >= 0.95 ? 'is-hot' : ''}"
            style=${{ height: `${10 + b * 90}%` }}
          ></span>
        `)}
      </div>
      <div class="mt-3 grid grid-cols-4 gap-2 text-[12px]">
        <div><span class="text-text-tertiary">피크</span><span class="ml-2 font-mono text-text-secondary">112/5m</span></div>
        <div><span class="text-text-tertiary">평균</span><span class="ml-2 font-mono text-text-secondary">47/5m</span></div>
        <div><span class="text-text-tertiary">오류율</span><span class="ml-2 font-mono text-success">0.4%</span></div>
        <div><span class="text-text-tertiary">p95 지연</span><span class="ml-2 font-mono text-text-secondary">1.8s</span></div>      </div>
    <//>
  `
}

function OverviewFleetGrid({ keeperList }: { keeperList: readonly Keeper[] }) {
  if (keeperList.length === 0) {
    return html`
      <${SectionCard} label="Keeper 전체" variant="standard" class="v2-overview-fleet mx-6" data-testid="overview-fleet">
        <p class="text-[12px] text-text-tertiary italic">No keepers</p>      <//>
    `
  }

  const sorted = useMemo(
    () => [...keeperList].sort((a, b) => {
      const aAtt = pickAttentionKeepers([a]).length > 0 ? 1 : 0
      const bAtt = pickAttentionKeepers([b]).length > 0 ? 1 : 0
      if (aAtt !== bAtt) return bAtt - aAtt
      const tsA = parseIsoMs(a.last_heartbeat) ?? 0
      const tsB = parseIsoMs(b.last_heartbeat) ?? 0
      return tsB - tsA
    }),
    [keeperList],
  )

  return html`
    <${SectionCard}
      label="Keeper 전체"
      variant="standard"
      class="v2-overview-fleet mx-6"      right=${html`
        <button
          type="button"
          class="text-[12px] text-brand hover:underline min-h-11 px-2"          onClick=${() => navigate('monitoring', { section: 'agents' })}
        >
          전체 대화 보기 →
        </button>
      `}
      data-testid="overview-fleet"
    >
      <div class="v2-overview-fleet-grid grid gap-2 px-6" style="grid-template-columns: repeat(auto-fill, minmax(16rem, 1fr));">
        ${sorted.map(k => {
          const displayStatus = keeperDisplayStatus(k)
          const isRunning = keeperRowLooksRunning(k)
          const ctx = k.context_ratio ?? 0
          const ctxPct = Math.round(ctx * 100)
          const displayName = k.koreanName && k.koreanName !== '' ? k.koreanName : k.name
          return html`
            <button
              key=${k.name}
              type="button"
              class="v2-overview-keeper ss-card text-left border border-border bg-card p-3 transition-colors hover:border-border hover:bg-surface-subtle"              onClick=${() => navigate('monitoring', { section: 'agents', keeper: k.name })}
              data-testid=${`overview-keeper-${k.name}`}
            >
              <div class="flex items-center gap-2">
                <${AgentAvatar} name=${k.name} size="sm" status=${displayStatus} />
                <div class="min-w-0 flex-1">
                  <div class="truncate text-[14px] font-semibold text-text-primary">${displayName}</div>
                  <div class="flex items-center gap-1.5 text-[12px] text-text-tertiary">
                    <${StatusDot} class=${isRunning ? 'bg-success' : 'bg-text-disabled'} />                    <span class="truncate">${k.phase ?? k.lifecycle_phase ?? displayStatus}</span>
                  </div>
                </div>
                ${pickAttentionKeepers([k]).length > 0
                  ? html`<span class="v2-overview-keeper-att inline-flex h-5 min-w-5 items-center justify-center rounded-full bg-destructive px-1.5 text-[12px] font-semibold text-white">!</span>`                  : null}
              </div>
              <div class="mt-2 flex items-center justify-between gap-2 text-[12px]">
                <span class="font-mono text-text-tertiary">${keeperModelLabel(k)}</span>                <div class="flex flex-1 items-center gap-2">
                  <div class="v2-overview-mini-meter h-1 flex-1 rounded-full bg-surface-muted">
                    <span class="block h-full rounded-full ${ctx >= 0.85 ? 'bg-destructive' : ctx >= 0.6 ? 'bg-warning' : 'bg-success'}" style=${{ width: `${Math.min(100, ctxPct)}%` }}></span>
                  </div>
                  <span class="w-8 text-right font-mono text-text-secondary">${ctxPct}%</span>
                </div>
              </div>
            </button>
          `
        })}
      </div>
    <//>
  `
}

// ─── Root ────────────────────────────────────────────────────────────────────

export function Overview() {
  useNowSecondsTicker()
  const snap = missionSnapshot.value
  const taskList = tasks.value
  const keeperList = keepers.value
  const agentList = agents.value
  const messageList = messages.value
  const boardPostList = boardPosts.value
  const nowMs = nowSecondsSignal.value * 1000
  const active = useMemo(() => pickActiveSession(snap), [snap])
  const counts = useMemo(() => computeFunnelCounts(taskList, active, nowMs), [taskList, active, nowMs])
  const agentAlerts = useMemo(() => deriveAgentAlerts(agentList), [agentList])
  const taskAlerts = useMemo(() => deriveTaskAlerts(taskList, nowMs), [taskList, nowMs])
  const tickerEvents = useMemo(
    () => deriveFleetTickerEvents({ taskList, messageList, boardPostList, keeperList }),
    [taskList, messageList, boardPostList, keeperList],
  )
  const stats = useMemo(() => computeOverviewStats(keeperList, taskList), [keeperList, taskList])
  const bars = useMemo(() => telemetryBars(keeperList), [keeperList])

  return html`
    <div class="v2-overview-surface ss-surface flex flex-col space-y-6 py-6">      <${OverviewHeader} stats=${stats} />
      <${OverviewKpiStrip} stats=${stats} />
      <${AlertPanel} agentAlerts=${agentAlerts} taskAlerts=${taskAlerts} />
      <div class="grid gap-6 px-6 lg:grid-cols-2">
        <${OverviewAttentionPanel} keeperList=${keeperList} />
        <${OverviewTelemetry} bars=${bars} />
      </div>
      <${SurfaceReadinessSummary} />
      <${FleetTicker} events=${tickerEvents} />
      <${FunnelCard} counts=${counts} />
      <${MissionPartyCard} active=${active} />
      <${KeeperStrip} keeperList=${keeperList} />
      <${OverviewFleetGrid} keeperList=${keeperList} />
    </div>
  `
}
