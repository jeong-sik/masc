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
import { createAsyncResource, type AsyncResource, type AsyncState } from '../../lib/async-state'
import { navigate } from '../../router'
import {
  normalizeSurfaceReadinessPayload,
  summarizeSurfaceReadiness,
  type SurfaceReadinessEntry,
} from '../surface-readiness-panel'
import {
  fetchTelemetry,
  fetchTelemetrySummary,
  type TelemetryEntry,
  type TelemetrySourceSummary,
} from '../../api/dashboard'
import { currentDashboardActor, get } from '../../api/core'

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

export function keeperModelLabel(keeper: Keeper): string {
  const model = keeper.active_model_label
    ?? keeper.active_model
    ?? keeper.model
    ?? keeper.primary_model
    ?? keeper.last_model_used
    ?? ''
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
export const OVERVIEW_TELEMETRY_BUCKET_MINUTES = 5
export const OVERVIEW_TELEMETRY_WINDOW_MINUTES =
  OVERVIEW_TELEMETRY_BAR_COUNT * OVERVIEW_TELEMETRY_BUCKET_MINUTES
const UNIX_MS_TIMESTAMP_THRESHOLD = 10_000_000_000

export interface OverviewTelemetrySnapshot {
  bars: number[]
  peakPerBucket: number
  averagePerBucket: number
  eventCount: number
  latestAgeSeconds: number | null
  sourceHealth: string
  activeCoverageGaps: number
  healthySourceCount: number
  sourceCount: number
  truncated: boolean
}

function telemetryEntryMs(entry: TelemetryEntry): number | null {
  const raw = entry.ts_unix ?? entry.ts ?? entry.timestamp
  if (typeof raw === 'number' && Number.isFinite(raw)) {
    // Unix seconds are ~1.7e9 today; unix milliseconds are ~1.7e12.
    return raw > UNIX_MS_TIMESTAMP_THRESHOLD ? raw : raw * 1000
  }
  if (entry.ts_iso) {
    const parsed = Date.parse(entry.ts_iso)
    if (Number.isFinite(parsed)) return parsed
  }
  return null
}

function roundOne(value: number): number {
  return Math.round(value * 10) / 10
}

export function buildOverviewTelemetrySnapshot({
  entries,
  sources,
  nowMs = Date.now(),
  totalMatchingEntries,
  truncated = false,
}: {
  entries: readonly TelemetryEntry[]
  sources: readonly TelemetrySourceSummary[]
  nowMs?: number
  totalMatchingEntries?: number
  truncated?: boolean
}): OverviewTelemetrySnapshot {
  const bucketMs = OVERVIEW_TELEMETRY_BUCKET_MINUTES * 60 * 1000
  const windowMs = OVERVIEW_TELEMETRY_WINDOW_MINUTES * 60 * 1000
  const startMs = nowMs - windowMs
  const buckets = Array.from({ length: OVERVIEW_TELEMETRY_BAR_COUNT }, () => 0)

  for (const entry of entries) {
    const ts = telemetryEntryMs(entry)
    if (ts === null || ts < startMs || ts > nowMs) continue
    const idx = Math.min(
      OVERVIEW_TELEMETRY_BAR_COUNT - 1,
      Math.max(0, Math.floor((ts - startMs) / bucketMs)),
    )
    buckets[idx] = (buckets[idx] ?? 0) + 1
  }

  const peakPerBucket = Math.max(0, ...buckets)
  const averagePerBucket = roundOne(buckets.reduce((sum, count) => sum + count, 0) / buckets.length)
  const oasEventSummary = sources.find(source => source.source === 'oas_event')
  const healthySourceCount = sources.filter(source => source.health === 'ok').length
  const activeCoverageGaps = sources.reduce(
    (sum, source) => sum + (source.active_coverage_gap_count ?? 0),
    0,
  )

  return {
    bars: peakPerBucket > 0 ? buckets.map(count => count / peakPerBucket) : buckets,
    peakPerBucket,
    averagePerBucket,
    eventCount: totalMatchingEntries ?? entries.length,
    latestAgeSeconds: oasEventSummary?.latest_age_s ?? null,
    sourceHealth: oasEventSummary?.health ?? 'unknown',
    activeCoverageGaps,
    healthySourceCount,
    sourceCount: sources.length,
    truncated,
  }
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
      title="Fleet Ticker"
      class="v2-overview-ticker ss-card mx-6"
      variant="standard"
      right=${html`<span class="text-[12px] text-text-tertiary">latest ${events.length}</span>`}
      data-testid="overview-fleet-ticker"
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
            class="v2-overview-ticker-card grid min-w-[15rem] max-w-[22rem] max-[768px]:min-w-[12rem] flex-[0_0_auto] gap-1 rounded-md border border-border bg-card px-3 py-2"
          >
            <div class="flex min-w-0 items-center gap-2 font-mono text-[10px] uppercase tracking-wider">
              <span class=${tickerToneClass(event.tone)}>${event.kind}</span>
              <span class="truncate text-text-tertiary">${event.actor}</span>
              <${TimeAgo} timestamp=${event.timestamp} class="ml-auto shrink-0 text-text-disabled" />
            </div>
            <div class="truncate text-[13px] font-semibold text-text-primary">${event.text}</div>
            <div class="truncate font-mono text-[10px] uppercase tracking-wider text-text-disabled">${event.label}</div>
          </div>
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
      title="Alerts"
      class="v2-overview-alerts ss-card mx-6"
      variant="standard"
      tone=${hasCritical ? 'border-destructive' : 'border-warning'}
      right=${html`<${StatusDot} class=${hasCritical ? 'bg-destructive' : 'bg-warning'} />`}
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
                <p class="text-[13px] font-semibold truncate text-text-primary">${'name' in a ? a.display : a.title}</p>
                <p class="text-[11px] text-text-tertiary truncate">${'reason' in a ? a.reason : a.status}</p>
              </div>
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
    <${SectionCard}
      label="Today"
      class="v2-overview-funnel ss-card mx-6"
      variant="standard"
      right=${html`<span class="text-[12px] text-text-tertiary">task basis</span>`}
      data-testid="overview-funnel"
    >
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
      <${SectionCard} label="Active mission" class="v2-overview-party ss-card mx-6" variant="standard" data-testid="overview-party-empty">
        <p class="text-[11px] text-text-tertiary italic">No active mission</p>
      <//>
    `
  }

  const progress = progressPct(active)
  const status = active.status ?? 'unknown'
  const members = active.member_names

  return html`
    <${SectionCard} label="Active Mission" class="v2-overview-party ss-card mx-6" variant="standard" data-testid="overview-party">
      <div class="space-y-4">
        <div class="flex items-center justify-between">
           <p class="text-[13px] font-semibold text-text-primary truncate flex-1 mr-4">
             ${active.goal}
           </p>
           <div class="flex -space-x-1.5">
             ${members.map(m => html`<${AgentAvatar} key=${m} name=${m} size="xs" class="ring-1 ring-[var(--bg-surface-page)]" />`)}
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
      <${SectionCard} label="Active Keepers" class="v2-overview-keepers ss-card mx-6" variant="standard" data-testid="overview-keepers-empty">
        <p class="text-[11px] text-text-tertiary italic">No active keepers</p>
      <//>
    `
  }

  return html`
    <${SectionCard} label="Active Keepers" class="v2-overview-keepers ss-card mx-6" variant="standard" data-testid="overview-keepers">
      <ul class="flex flex-wrap gap-x-6 gap-y-2">
        ${activeKeepers.map(
          k => {
            const displayStatus = keeperDisplayStatus(k)
            return html`
            <li key=${k.name} class="flex items-center gap-2">
              <div class="min-w-0">
                <p class="text-[13px] font-medium truncate text-text-primary">${k.koreanName && k.koreanName !== '' ? k.koreanName : k.name}</p>
                ${k.last_heartbeat !== undefined
                  ? html`<${TimeAgo} timestamp=${k.last_heartbeat} class="text-[10px] text-text-tertiary" />`
                  : null}
              </div>
              <span class="${keeperPillClass(displayStatus)} text-[10px] shrink-0">${keeperStatusLabel(displayStatus)}</span>
            </li>
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
const overviewTelemetryResource: AsyncResource<OverviewTelemetrySnapshot> = createAsyncResource()

function loadSurfaceReadiness(): Promise<void> {
  return surfaceReadinessResource.load(async () => {
    const raw = await get<unknown>('/api/v1/dashboard/surface-readiness')
    const data = normalizeSurfaceReadinessPayload(raw)
    return data.surfaces
  })
}

function loadOverviewTelemetry(nowMs = Date.now()): Promise<void> {
  return overviewTelemetryResource.load(async () => {
    const sinceMs = nowMs - OVERVIEW_TELEMETRY_WINDOW_MINUTES * 60 * 1000
    const [telemetry, summary] = await Promise.all([
      fetchTelemetry({ source: 'oas_event', since_ms: sinceMs, n: 1000 }),
      fetchTelemetrySummary(),
    ])
    return buildOverviewTelemetrySnapshot({
      entries: telemetry.entries,
      sources: summary.sources,
      nowMs,
      totalMatchingEntries: telemetry.total_matching_entries,
      truncated: telemetry.truncated ?? false,
    })
  })
}

function SurfaceReadinessSummary() {
  useEffect(() => { void loadSurfaceReadiness() }, [])

  const state = surfaceReadinessResource.state.value
  if (state.status !== 'loaded') return null

  const summary = summarizeSurfaceReadiness(state.data)
  return html`
    <${SectionCard}
      label="Surface Readiness"
      class="v2-overview-readiness ss-card mx-6"
      variant="standard"
      data-testid="overview-surface-readiness"
    >
      <${KpiStripIsland}
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
  const actor = currentDashboardActor()
  return html`
    <header class="ov-head v2-overview-head" data-testid="overview-head">
      <div>
        <h1>운영 개요</h1>
        <p class="ov-sub">
          <span title="데이터 출처 — 실제 dashboard execution projection">source <span class="mono">dashboard/execution</span></span>
          <span> · </span>
          <span title="등록된 keeper 총 수">Keeper ${stats.total}</span>
          <span> · </span>
          <span title="현재 dashboard actor">operator <b class="text-text-secondary">@${actor}</b></span>
        </p>
      </div>
      <div class="ov-clock v2-overview-clock mono" data-testid="overview-clock">
        ${clock} <span>KST</span>
      </div>
    </header>
  `
}

function OverviewKpi({
  label,
  value,
  sub,
  tone,
  testId,
}: {
  label: string
  value: string
  sub?: string
  tone?: 'ok' | 'bad' | 'warn' | 'volt'
  testId: string
}) {
  return html`
    <div class="ov-kpi" data-testid=${testId}>
      <div class="ov-kpi-k">${label}</div>
      <div class=${`ov-kpi-v ${tone ?? ''}`}>${value}${sub !== undefined ? html`<small>${sub}</small>` : null}</div>
    </div>
  `
}

function OverviewKpiStrip({ stats }: { stats: OverviewStats }) {
  return html`
    <section class="ov-kpis v2-overview-kpis" aria-label="Fleet KPIs" data-testid="overview-kpis">
      <${OverviewKpi} label="실행 중" value=${String(stats.run)} sub=${` / ${stats.total}`} tone="ok" testId="kpi-run" />
      <${OverviewKpi} label="주의 필요" value=${String(stats.att)} tone=${stats.att > 0 ? 'bad' : undefined} testId="kpi-att" />
      <${OverviewKpi} label="컨텍스트 압박" value=${String(stats.hot)} sub=" ≥85%" tone=${stats.hot > 0 ? 'warn' : undefined} testId="kpi-hot" />
      <${OverviewKpi} label="평균 컨텍스트" value=${`${stats.avgCtx}%`} tone="volt" testId="kpi-avg-ctx" />
      <${OverviewKpi} label="소유 태스크" value=${String(stats.tasks)} testId="kpi-tasks" />
      <${OverviewKpi} label="누적 trace" value=${stats.traces.toLocaleString()} testId="kpi-traces" />
    </section>
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
      <section class="ov-card ov-attn v2-overview-attention" data-testid="overview-attention">
        <div class="ov-card-h">
          <h3>주의 필요</h3>
          <span class="ov-count">0</span>
        </div>
        <div class="ov-empty">모든 keeper 정상</div>
      </section>
    `
  }

  return html`
    <section class="ov-card ov-attn v2-overview-attention" data-testid="overview-attention">
      <div class="ov-card-h">
        <h3>주의 필요</h3>
        <span class="ov-count">${attn.length}</span>
      </div>
      <div class="ov-attn-list v2-overview-attention-list">
        ${attn.map(k => {
          const reason = deriveKeeperAttentionReason(k)
          const displayName = k.koreanName && k.koreanName !== '' ? k.koreanName : k.name
          return html`
            <div
              key=${k.name}
              class="ov-attn-row v2-overview-attention-row"
              onClick=${() => navigate('monitoring', { section: 'agents', keeper: k.name })}
              data-testid=${`attention-row-${k.name}`}
            >
              <${AgentAvatar} name=${k.name} size="sm" status=${keeperDisplayStatus(k)} />
              <div class="ov-attn-meta">
                <div class="ov-attn-name">
                  ${displayName}
                  <span class="ov-attn-ns mono">${k.name}</span>
                </div>
                <div class=${`ov-attn-reason sev-${reason.sev}`}>
                  <span class="inline-block size-1.5 rounded-full ${attentionToneClass(reason.sev)}"></span>
                  <span>${reason.text}</span>
                </div>
              </div>
              <button
                type="button"
                class="ov-attn-act"
                onClick=${(e: MouseEvent) => {
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
    </section>
  `
}

function formatTelemetryAge(seconds: number | null): string {
  if (seconds === null || !Number.isFinite(seconds)) return 'n/a'
  if (seconds < 60) return `${Math.round(seconds)}s`
  if (seconds < 3600) return `${Math.round(seconds / 60)}m`
  return `${roundOne(seconds / 3600)}h`
}

function telemetryHealthToneClass(snapshot: OverviewTelemetrySnapshot): string {
  if (snapshot.activeCoverageGaps > 0) return 'text-warning'
  if (snapshot.sourceHealth === 'ok') return 'text-success'
  return 'text-text-tertiary'
}

function OverviewTelemetry({
  telemetry,
}: {
  telemetry: AsyncState<OverviewTelemetrySnapshot>
}) {
  const snapshot = telemetry.status === 'loaded' ? telemetry.data : null
  return html`
    <section class="ov-card ov-telemetry v2-overview-telemetry" data-testid="overview-telemetry">
      <div class="ov-card-h">
        <h3>텔레메트리</h3>
        <span class="ov-legend mono">oas_event / 5m · last ${OVERVIEW_TELEMETRY_WINDOW_MINUTES}m</span>
      </div>
      ${snapshot
        ? html`
          <div class="ov-bars v2-overview-bars" role="img" aria-label="Live OAS telemetry histogram">
            ${snapshot.bars.map((b, i) => html`
              <span
                key=${i}
                class=${`ov-bar v2-overview-bar ${b >= 0.95 ? 'hot is-hot' : ''}`}
                style=${{ height: `${10 + b * 90}%` }}
              ></span>
            `)}
          </div>
          <div class="ov-tel-foot">
            <div class="ov-tel-stat"><span class="k">피크</span><span class="v mono">${snapshot.peakPerBucket}/5m</span></div>
            <div class="ov-tel-stat"><span class="k">평균</span><span class="v mono">${snapshot.averagePerBucket}/5m</span></div>
            <div class="ov-tel-stat"><span class="k">이벤트</span><span class="v mono">${snapshot.eventCount.toLocaleString()}${snapshot.truncated ? '+' : ''}</span></div>
            <div class="ov-tel-stat"><span class="k">최신</span><span class=${`v mono ${telemetryHealthToneClass(snapshot)}`}>${formatTelemetryAge(snapshot.latestAgeSeconds)}</span></div>
            <div class="ov-tel-stat"><span class="k">소스</span><span class="v mono">${snapshot.healthySourceCount}/${snapshot.sourceCount}</span></div>
            <div class="ov-tel-stat"><span class="k">갭</span><span class=${`v mono ${snapshot.activeCoverageGaps > 0 ? 'text-warning' : 'text-success'}`}>${snapshot.activeCoverageGaps}</span></div>
          </div>
        `
        : html`
          <div class="ov-empty">
            ${telemetry.status === 'error'
              ? `텔레메트리 로드 실패: ${telemetry.message}`
              : '실제 telemetry 로드 중'}
          </div>
        `}
    </section>
  `
}

function keeperNamespaceLabel(keeper: Keeper): string {
  return keeper.runtime_canonical
    ?? keeper.selected_runtime_canonical
    ?? keeper.runtime_id
    ?? keeper.agent_name
    ?? 'runtime unavailable'
}

function OverviewFleetGrid({ keeperList }: { keeperList: readonly Keeper[] }) {
  if (keeperList.length === 0) {
    return html`
      <section class="ov-card ov-fleet v2-overview-fleet" data-testid="overview-fleet">
        <div class="ov-card-h">
          <h3>Keeper 전체</h3>
          <button type="button" class="ov-link" onClick=${() => navigate('monitoring', { section: 'agents' })}>전체 대화 보기 →</button>
        </div>
        <div class="ov-empty">No keepers</div>
      </section>
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
    <section class="ov-card ov-fleet v2-overview-fleet" data-testid="overview-fleet">
      <div class="ov-card-h">
        <h3>Keeper 전체</h3>
        <button type="button" class="ov-link" onClick=${() => navigate('monitoring', { section: 'agents' })}>전체 대화 보기 →</button>
      </div>
      <div class="ov-fleet-grid v2-overview-fleet-grid">
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
              class="ov-keeper v2-overview-keeper"
              onClick=${() => navigate('monitoring', { section: 'agents', keeper: k.name })}
              data-testid=${`overview-keeper-${k.name}`}
            >
              <div class="ov-keeper-top">
                <${AgentAvatar} name=${k.name} size="sm" status=${displayStatus} />
                <div class="ov-keeper-id">
                  <div class="ov-keeper-name">${displayName}</div>
                  <div class="ov-keeper-state">
                    <${StatusDot} class=${isRunning ? 'bg-success' : 'bg-text-disabled'} />
                    <span class="truncate">${k.phase ?? k.lifecycle_phase ?? displayStatus}</span>
                  </div>
                </div>
                ${pickAttentionKeepers([k]).length > 0
                  ? html`<span class="ov-keeper-att v2-overview-keeper-att">!</span>`
                  : null}
              </div>
              <div class="ov-keeper-ns mono">${keeperNamespaceLabel(k)}</div>
              <div class="ov-keeper-foot">
                <span class="mono">${keeperModelLabel(k) || keeperNamespaceLabel(k)}</span>
                <div class="ov-mini-meter v2-overview-mini-meter">
                  <span class=${ctx >= 0.85 ? 'hot' : ''} style=${{ width: `${Math.min(100, ctxPct)}%` }}></span>
                </div>
                <span class="mono ov-keeper-ctx">${ctxPct}%</span>
              </div>
            </button>
          `
        })}
      </div>
    </section>
  `
}

// ─── Root ────────────────────────────────────────────────────────────────────

export function Overview() {
  useNowSecondsTicker()
  useEffect(() => {
    void loadOverviewTelemetry()
    const interval = window.setInterval(() => {
      void loadOverviewTelemetry()
    }, 60_000)
    return () => window.clearInterval(interval)
  }, [])
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
  const telemetry = overviewTelemetryResource.state.value

  return html`
    <main class="ov v2-overview-surface ss-surface text-text-primary" data-testid="overview-surface">
      <div class="ov-scroll v2-overview-scroll">
        <${OverviewHeader} stats=${stats} />
        <${OverviewKpiStrip} stats=${stats} />
        <div class="ov-grid v2-overview-primary-grid" data-testid="overview-primary-grid">
          <${OverviewAttentionPanel} keeperList=${keeperList} />
          <${OverviewTelemetry} telemetry=${telemetry} />
        </div>
        <${OverviewFleetGrid} keeperList=${keeperList} />

        <details class="v2-overview-rollup" data-testid="overview-rollup">
          <summary>운영 롤업</summary>
          <div class="v2-overview-rollup-body">
            <${AlertPanel} agentAlerts=${agentAlerts} taskAlerts=${taskAlerts} />
            <${SurfaceReadinessSummary} />
            <${FleetTicker} events=${tickerEvents} />
            <${FunnelCard} counts=${counts} />
            <${MissionPartyCard} active=${active} />
            <${KeeperStrip} keeperList=${keeperList} />
          </div>
        </details>
      </div>
    </main>
  `
}
