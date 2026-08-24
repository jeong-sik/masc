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
//   - Keeper fleet    — full keeper grid with status, runtime, context meter

import { html } from 'htm/preact'
import { useEffect, useMemo } from 'preact/hooks'
import { AgentAvatar } from './agent-avatar'
import { SCHED_TERMINAL_SET } from '../v2/schedule-constants'
import { tasks, keepers, boardPosts, boardTotal, lastBoardRefreshAt, goals, fusionRuns, shellRuntimeResolution } from '../../store'
import type { Agent, Task, Keeper, Message, BoardPost, Goal, KeeperRuntimeBlockerClass } from '../../types/core'
import type {
  DashboardScheduledAutomationProjection,
  DashboardScheduledAutomationRequest,
  FusionRunRecord,
} from '../../api/dashboard'
import { SYSTEM_ACTOR_NAME } from '../../types/core'
import { useNowSecondsTicker } from '../../lib/now-signal'
import { keeperDisplayRuntime, keeperDisplayStatus, keeperRuntimeBlockerLabel } from '../../lib/keeper-runtime-display'
import { isKeeperPaused } from '../../lib/keeper-predicates'
import { attentionReasonLabel, nextHumanActionLabel } from '../../lib/keeper-attention-labels'
import { isAgentOffline } from '../../lib/agent-status'
import {
  KEEPER_STATUS_LABEL_KO,
  type KeeperStatusLabelKey,
} from '../../lib/keeper-operational-state'
import {
  PHASE_LABEL_KO,
  type KeeperPhaseToken,
} from '../../lib/fleet-tone'
import { UNKNOWN_STATUS_LABEL } from '../../lib/format-string'
import {
  keeperRowLooksRunning,
  resolveKeeperFleetExecutionCounts,
  type KeeperFleetExecutionCounts,
} from '../../runtime-counts'
import {
  projectDashboardCompositeHealth,
  type DashboardCompositeHealthVerdict,
} from '../../lib/dashboard-composite-health'
import { createAsyncResource, type AsyncResource, type AsyncState } from '../../lib/async-state'
import { navigate } from '../../router'
import { gateData } from '../gate-signals'
import type { TabId } from '../../types/sse'
import {
  scheduledAutomationProjection,
  subscribeScheduledAutomationRefresh,
} from '../schedule/schedule-state'
import {
  fetchTelemetry,
  fetchTelemetrySummary,
  type TelemetryEntry,
  type TelemetrySourceSummary,
  type DashboardKeeperEventQueueHealth,
  type DashboardScheduleRunnerStatus,
} from '../../api/dashboard'
import {
  dashboardFullHealth,
  subscribeDashboardFullHealthRefresh,
} from '../dashboard-full-health-state'
import {
  OVERVIEW_TELEMETRY_EVENTS_PER_BUCKET,
} from '../../config/constants'

// ─── Attention / Keeper v2 helpers ───────────────────────────────────────────

export interface KeeperAttentionReason {
  sev: 'bad' | 'warn'
  text: string
  act: string
}

const DEFAULT_ATTENTION_REASON: KeeperAttentionReason = { sev: 'warn', text: '주의 사유 미보고', act: '상태 상세' }

const CRITICAL_ATTENTION_BLOCKERS = new Set<KeeperRuntimeBlockerClass>([
  'exception',
  'turn_failures',
  'heartbeat_failures',
])

function hasCriticalAttentionBlocker(blockerClass: Keeper['runtime_blocker_class'] | null | undefined): boolean {
  return blockerClass != null && CRITICAL_ATTENTION_BLOCKERS.has(blockerClass)
}

/** Map a keeper's runtime/trust state to a human attention reason.
 *  Mirrors the hard-coded ATTN_REASON table from keeper-v2/overview.jsx
 *  but derives the text from live dashboard fields. */
export function deriveKeeperAttentionReason(keeper: Keeper): KeeperAttentionReason {
  const blockerClass = keeper.runtime_blocker_class ?? null
  const blockerLabel = keeperRuntimeBlockerLabel(blockerClass) ?? blockerClass?.replace(/_/g, ' ')
  // Humanize the backend `attention_reason` / `next_human_action` wire codes
  // through the shared SSOT instead of rendering raw tokens like
  // `inspect_blocker_before_resume`. Unknown codes (e.g. composite reasons
  // such as `completion_contract_result:*`) fall back to the raw string and
  // warn in dev — matching the keeper detail alert strip.
  const attentionRaw = keeper.attention_reason?.trim() || keeper.trust?.attention_reason?.trim() || null
  const nextActionRaw = keeper.next_human_action?.trim() || keeper.trust?.next_human_action?.trim() || null
  const attention = attentionReasonLabel(attentionRaw, false) ?? undefined
  const nextAction = nextHumanActionLabel(nextActionRaw) ?? undefined

  const isCritical = hasCriticalAttentionBlocker(blockerClass)
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
    || !!k.attention_reason?.trim()
    || !!k.trust?.attention_reason?.trim(),
  )
}

// ─── KPI stats ───────────────────────────────────────────────────────────────

/** Roster-derived counts. Keeper *execution* counts deliberately live outside
 *  this type: they come from the runtime-health fleet projection via
 *  {!resolveKeeperFleetExecutionCounts}, because a roster row's status string
 *  describes what the row last recorded, not whether a keeper fiber is running
 *  right now. */
export interface OverviewStats {
  att: number
  hot: number
  avgCtx: number | null
  tasks: number
  traces: number
  total: number
}

function keeperTraceCount(keeper: Keeper): number {
  return keeper.total_turns ?? keeper.turn_count ?? 0
}

export function keeperRuntimeLabel(keeper: Keeper): string {
  return keeperDisplayRuntime(keeper)?.value ?? ''
}

export function computeOverviewStats(keeperList: readonly Keeper[], taskList: readonly Task[]): OverviewStats {
  const total = keeperList.length
  const att = pickAttentionKeepers(keeperList).length
  const hot = keeperList.filter(k => (k.context_ratio ?? 0) >= 0.85).length
  const traces = keeperList.reduce((sum, k) => sum + keeperTraceCount(k), 0)

  const keeperNames = new Set(keeperList.map(k => k.name.toLowerCase()))
  const tasks = taskList.filter(t => t.assignee && keeperNames.has(t.assignee.toLowerCase())).length

  // Still roster-scoped: context_ratio is only carried on roster rows, and the
  // fleet projection reports running keepers as a count without the per-keeper
  // ratios needed to average them.
  const liveCtx = keeperList.filter(k => keeperRowLooksRunning(k) && typeof k.context_ratio === 'number')
  const avgCtx = liveCtx.length
    ? Math.round(liveCtx.reduce((sum, k) => sum + (k.context_ratio ?? 0), 0) / liveCtx.length * 100)
    : null

  return { att, hot, avgCtx, tasks, traces, total }
}

/** Renders a fleet execution count. `—` means the runtime-health fleet
 *  projection did not report the number; a rendered `0` always means the
 *  projection reported zero. */
export function fleetCountText(value: number | null | undefined): string {
  return typeof value === 'number' ? String(value) : '—'
}

// ─── Cross-surface digest (overview.jsx:71-92) ───────────────────────────────
//
// The prototype reads window.GOALS / APPROVALS / CONNECTORS / FUSION_RUNS etc.
// from a mock. The live v2 dashboard exposes goals + fusion runs as signals, and
// surfaces operator-awaiting keepers as the approval queue.

export interface OverviewDigest {
  /** Exact pending requests from the Gate queue SSOT. */
  openGateRequests: number | null
  /** Top goals by priority (highest first), up to 3. */
  topGoals: Goal[]
  /** Most urgent goal label for the "최우선 목표" KPI, or null when none. */
  topGoalLabel: string | null
  /** Fusion runs currently executing. */
  fusionRunning: number
  /** Completed fusion runs (status === 'completed'). */
  fusionDone: number
  /** Total fusion runs. */
  fusionTotal: number
  /** Latest fusion run record (newest startedAt), or null. */
  fusionLatest: FusionRunRecord | null
  /** Scheduled-automation projection snapshot summary for the domain cards. */
  scheduledAutomation: OverviewScheduledAutomationDigest
  /** schedule_runner liveness summary from /health?full=1. */
  scheduleRunner: OverviewScheduleRunnerDigest
  /** Durable queue storage and runnable work are intentionally separate. */
  keeperQueue: OverviewKeeperQueueDigest
}

export interface OverviewKeeperQueueDigest {
  hasProjection: boolean
  storageStatus: string
  workStatus: string
  workState: string
  runnableBacklogCount: number
  runnableOldestAgeSeconds: number | null
  backlogClean: boolean
}

export interface OverviewScheduleRunnerDigest {
  hasProjection: boolean
  status: string
  tone: 'ok' | 'warn' | 'bad' | 'volt'
  tickInFlight: boolean
  tickCount: number
  successCount: number
  failureCount: number
  crashCount: number
  lastTickAgeSec: number | null
  lastSuccessAgeSec: number | null
  lastErrorAgeSec: number | null
  lastDurationSec: number | null
  staleAfterSec: number | null
  lastError: string | null
  lastCounts:
    | {
      dueChanged?: number | null
      emitted?: number | null
      rescheduled?: number | null
      dispatchSucceeded?: number | null
      dispatchFailed?: number | null
      dispatchUnsupported?: number | null
      dispatchStartRejected?: number | null
      wakeEnqueued?: number | null
      wakeSkippedNoKeeper?: number | null
      wakeSkippedMissingSchedule?: number | null
      wakeSkippedNonKeeperActor?: number | null
      wakeSkippedUnregisteredKeeper?: number | null
      wakeFailed?: number | null
    }
    | null
}

interface OverviewScheduledAutomationAvailableDigest {
  state: 'available'
  /** Rows materialized in this projection page. */
  visibleCount: number
  /** Total rows reported by the schedule ledger. */
  totalCount: number
  /** Projection quota metadata for diagnostics. */
  limit: number
  /** FSM state from the scheduler surface. */
  fsmState: string
  /** FSM active_count from scheduler projection. */
  fsmActiveCount: number
  /** FSM terminal_count from scheduler projection. */
  fsmTerminalCount: number
  /** Next due time (projection field) if available. */
  nextDueAt: string | null
  /** Non-terminal by status count from projection/status inference. */
  dueCount: number
  /** Running-by-status count from projection/status inference. */
  runningCount: number
  /** Scheduled-by-status count from projection/status inference. */
  scheduledCount: number
  /** Number of warning rows returned by the backend for this projection. */
  warningCount: number
  /** Unsupported payload request count. */
  unsupportedPayloadCount: number
  /** Unknown payload request count. */
  unknownPayloadCount: number
  /** Whether scheduler projection was marked truncated. */
  truncated: boolean
  /** Recommended card tone derived from the above state. */
  tone: 'ok' | 'warn' | 'bad' | 'volt'
}

export type OverviewScheduledAutomationDigest =
  | OverviewScheduledAutomationAvailableDigest
  | {
    state: 'unavailable'
    reason: string
    tone: 'bad'
  }
  | {
    state: 'not_loaded'
    tone: 'warn'
  }

function requestCountByStatus(requests: readonly DashboardScheduledAutomationRequest[], target: string): number {
  let count = 0
  for (const request of requests) {
    if (request.status === target) count += 1
  }
  return count
}

function requestCountByPayloadSupport(
  requests: readonly DashboardScheduledAutomationRequest[],
  target: string,
): number {
  const key = target.trim().toLowerCase()
  let count = 0
  for (const request of requests) {
    if (request.payload_support === key) count += 1
  }
  return count
}

function requestCountByProjectionCount(
  requests: readonly DashboardScheduledAutomationRequest[],
  counts: Record<string, number> | undefined,
  target: string,
): number {
  const projected = counts?.[target]
  if (typeof projected === 'number' && Number.isFinite(projected)) {
    return projected
  }
  return requestCountByStatus(requests, target)
}

function sumTerminalCountFromProjection(counts: Record<string, number> | undefined): number {
  let sum = 0
  for (const terminalStatus of SCHED_TERMINAL_SET) {
    const n = counts?.[terminalStatus]
    if (typeof n === 'number' && Number.isFinite(n)) sum += n
  }
  return sum
}

function summarizeScheduleRunnerStatus(
  scheduleRunner: DashboardScheduleRunnerStatus | null | undefined,
): OverviewScheduleRunnerDigest {
  if (!scheduleRunner) {
    return {
      hasProjection: false,
      status: 'unknown',
      tone: 'warn',
      tickInFlight: false,
      tickCount: 0,
      successCount: 0,
      failureCount: 0,
      crashCount: 0,
      lastTickAgeSec: null,
      lastSuccessAgeSec: null,
      lastErrorAgeSec: null,
      lastDurationSec: null,
      staleAfterSec: null,
      lastError: null,
      lastCounts: null,
    }
  }

  const counts = scheduleRunner.last_counts
  const status = scheduleRunner.status ?? 'unknown'
  const tickInFlight = scheduleRunner.tick_in_flight === true
  const tickCount = Number.isFinite(scheduleRunner.tick_count ?? Number.NaN)
    ? Number(scheduleRunner.tick_count)
    : 0
  const successCount = Number.isFinite(scheduleRunner.success_count ?? Number.NaN)
    ? Number(scheduleRunner.success_count)
    : 0
  const failureCount = Number.isFinite(scheduleRunner.failure_count ?? Number.NaN)
    ? Number(scheduleRunner.failure_count)
    : 0
  const crashCount = Number.isFinite(scheduleRunner.crash_count ?? Number.NaN)
    ? Number(scheduleRunner.crash_count)
    : 0

  const tone = tickInFlight || status === 'running'
    ? 'volt'
    : status === 'ok' && failureCount === 0 && crashCount === 0
      ? 'ok'
      : status === 'degraded' || failureCount > 0 || crashCount > 0
        ? 'bad'
        : 'warn'

  return {
    hasProjection: true,
    status,
    tone,
    tickInFlight,
    tickCount,
    successCount,
    failureCount,
    crashCount,
    lastTickAgeSec:
      typeof scheduleRunner.last_tick_age_sec === 'number' && Number.isFinite(scheduleRunner.last_tick_age_sec)
        ? scheduleRunner.last_tick_age_sec
        : null,
    lastSuccessAgeSec:
      typeof scheduleRunner.last_success_age_sec === 'number' && Number.isFinite(scheduleRunner.last_success_age_sec)
        ? scheduleRunner.last_success_age_sec
        : null,
    lastErrorAgeSec:
      typeof scheduleRunner.last_error_age_sec === 'number' && Number.isFinite(scheduleRunner.last_error_age_sec)
        ? scheduleRunner.last_error_age_sec
        : null,
    lastDurationSec:
      typeof scheduleRunner.last_duration_sec === 'number' && Number.isFinite(scheduleRunner.last_duration_sec)
        ? scheduleRunner.last_duration_sec
        : null,
    staleAfterSec:
      typeof scheduleRunner.stale_after_sec === 'number' && Number.isFinite(scheduleRunner.stale_after_sec)
        ? scheduleRunner.stale_after_sec
        : null,
    lastError: typeof scheduleRunner.last_error === 'string' && scheduleRunner.last_error.trim() !== ''
      ? scheduleRunner.last_error
      : null,
    lastCounts: counts
      ? {
          dueChanged: typeof counts.due_changed === 'number' ? counts.due_changed : null,
          emitted: typeof counts.emitted === 'number' ? counts.emitted : null,
          rescheduled: typeof counts.rescheduled === 'number' ? counts.rescheduled : null,
          dispatchSucceeded: typeof counts.dispatch_succeeded === 'number' ? counts.dispatch_succeeded : null,
          dispatchFailed: typeof counts.dispatch_failed === 'number' ? counts.dispatch_failed : null,
          dispatchUnsupported: typeof counts.dispatch_unsupported === 'number' ? counts.dispatch_unsupported : null,
          dispatchStartRejected: typeof counts.dispatch_start_rejected === 'number' ? counts.dispatch_start_rejected : null,
          wakeEnqueued: typeof counts.wake_enqueued === 'number' ? counts.wake_enqueued : null,
          wakeSkippedNoKeeper: typeof counts.wake_skipped_no_keeper === 'number' ? counts.wake_skipped_no_keeper : null,
          wakeSkippedMissingSchedule:
            typeof counts.wake_skipped_missing_schedule === 'number'
              ? counts.wake_skipped_missing_schedule
              : null,
          wakeSkippedNonKeeperActor:
            typeof counts.wake_skipped_non_keeper_actor === 'number'
              ? counts.wake_skipped_non_keeper_actor
              : null,
          wakeSkippedUnregisteredKeeper:
            typeof counts.wake_skipped_unregistered_keeper === 'number'
              ? counts.wake_skipped_unregistered_keeper
              : null,
          wakeFailed: typeof counts.wake_failed === 'number' ? counts.wake_failed : null,
        }
      : null,
  }
}

function summarizeKeeperQueueHealth(
  queue: DashboardKeeperEventQueueHealth | null | undefined,
): OverviewKeeperQueueDigest {
  if (!queue) {
    return {
      hasProjection: false,
      storageStatus: 'unknown',
      workStatus: 'unknown',
      workState: 'unknown',
      runnableBacklogCount: 0,
      runnableOldestAgeSeconds: null,
      backlogClean: false,
    }
  }
  return {
    hasProjection: true,
    storageStatus: queue.storage_integrity?.status ?? 'unknown',
    workStatus: queue.work_liveness?.status ?? 'unknown',
    workState: queue.work_liveness?.state ?? 'unknown',
    runnableBacklogCount: queue.work_liveness?.runnable_backlog_count ?? 0,
    runnableOldestAgeSeconds: queue.work_liveness?.runnable_oldest_age_seconds ?? null,
    backlogClean: queue.backlog_clean,
  }
}

export function summarizeScheduledAutomation(
  projection: DashboardScheduledAutomationProjection | null | undefined,
): OverviewScheduledAutomationDigest {
  if (!projection) {
    return {
      state: 'not_loaded',
      tone: 'warn',
    }
  }
  if (projection.state === 'unavailable') {
    return {
      state: 'unavailable',
      reason: projection.reason,
      tone: 'bad',
    }
  }

  const automation = projection.data
  const requests = automation.requests ?? []
  const counts = automation.counts
  const payloadSupport = automation.payload_support

  const warningCount = automation.warnings?.length ?? 0
  const unsupportedPayloadCount = Math.max(
    payloadSupport?.unsupported_request_count ?? 0,
    requestCountByPayloadSupport(requests, 'unsupported'),
  )
  const unknownPayloadCount = Math.max(
    payloadSupport?.unknown_request_count ?? 0,
    requestCountByPayloadSupport(requests, 'unknown'),
  )

  const fsmActiveCount = Math.max(0, automation.fsm.active_count)
  const fsmTerminalCount = Math.max(
    0,
    automation.fsm.terminal_count,
    sumTerminalCountFromProjection(counts),
  )
  const dueCount = requestCountByProjectionCount(requests, counts, 'due')
  const runningCount = requestCountByProjectionCount(requests, counts, 'running')
  const scheduledCount = requestCountByProjectionCount(requests, counts, 'scheduled')

  const fsmState = automation.fsm?.state?.trim() ? automation.fsm.state.trim() : 'unknown'
  const nextDueAt = automation.fsm?.next_due_at?.trim() ? automation.fsm.next_due_at.trim() : null

  const hasActive = dueCount > 0 || runningCount > 0 || scheduledCount > 0
  const hasWarnings = unsupportedPayloadCount > 0 || unknownPayloadCount > 0 || warningCount > 0

  return {
    state: 'available',
    visibleCount: projection.page.visibleCount,
    totalCount: projection.page.totalCount,
    limit: projection.page.limit,
    fsmState,
    fsmActiveCount,
    fsmTerminalCount,
    nextDueAt,
    dueCount,
    runningCount,
    scheduledCount,
    warningCount,
    unsupportedPayloadCount,
    unknownPayloadCount,
    truncated: projection.page.truncated,
    tone: hasWarnings ? 'warn' : hasActive ? 'volt' : 'ok',
  }
}

function goalPriorityClass(priority: number): 'high' | 'normal' | 'low' {
  // overview.jsx:166 — priority >= 7 high, >= 4 normal, else low
  if (priority >= 7) return 'high'
  if (priority >= 4) return 'normal'
  return 'low'
}

export function computeOverviewDigest(
  openGateRequests: number | null,
  goalList: readonly Goal[],
  fusionList: readonly FusionRunRecord[],
  scheduledAutomation?: DashboardScheduledAutomationProjection | null,
  scheduleRunnerStatus?: DashboardScheduleRunnerStatus | null,
  keeperQueueHealth?: DashboardKeeperEventQueueHealth | null,
): OverviewDigest {
  // Highest priority first; ties keep input order (stable sort).
  const topGoals = [...goalList].sort((a, b) => b.priority - a.priority).slice(0, 3)
  const lead = topGoals[0] ?? null
  const topGoalLabel = lead ? (lead.due_date ?? `P${lead.priority}`) : null

  const fusionRunning = fusionList.filter(r => r.status === 'running').length
  const fusionDone = fusionList.filter(r => r.status === 'completed').length
  const fusionLatest = [...fusionList].sort((a, b) => b.startedAt - a.startedAt)[0] ?? null
  const scheduledAutomationDigest = summarizeScheduledAutomation(scheduledAutomation)
  const scheduleRunnerDigest = summarizeScheduleRunnerStatus(scheduleRunnerStatus)
  const keeperQueueDigest = summarizeKeeperQueueHealth(keeperQueueHealth)

  return {
    openGateRequests,
    topGoals,
    topGoalLabel,
    fusionRunning,
    fusionDone,
    fusionTotal: fusionList.length,
    fusionLatest,
    scheduledAutomation: scheduledAutomationDigest,
    scheduleRunner: scheduleRunnerDigest,
    keeperQueue: keeperQueueDigest,
  }
}

// ─── Telemetry bars ──────────────────────────────────────────────────────────

export const OVERVIEW_TELEMETRY_BAR_COUNT = 28
export const OVERVIEW_TELEMETRY_BUCKET_MINUTES = 5
export const OVERVIEW_TELEMETRY_WINDOW_MINUTES =
  OVERVIEW_TELEMETRY_BAR_COUNT * OVERVIEW_TELEMETRY_BUCKET_MINUTES
export { OVERVIEW_TELEMETRY_EVENTS_PER_BUCKET }
export const OVERVIEW_TELEMETRY_EVENT_SAMPLE_LIMIT =
  OVERVIEW_TELEMETRY_BAR_COUNT * OVERVIEW_TELEMETRY_EVENTS_PER_BUCKET
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
  const agentCoreEventSummary = sources.find(source => source.source === 'agent_core_event')
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
    latestAgeSeconds: agentCoreEventSummary?.latest_age_s ?? null,
    sourceHealth: agentCoreEventSummary?.health ?? 'unknown',
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

// Human-readable keeper status, used in the fleet ticker event text.
// Labels come from the KEEPER_STATUS_LABEL_KO SSOT
// (lib/keeper-operational-state.ts), falling back to the fleet-tone
// PHASE_LABEL_KO for lifecycle phase tokens (compacting, handoff, …)
// that `keeperDisplayStatus` can emit — the dashboard is Korean-only, so
// the former English pass-through ('Active'/'Busy'/…) is gone.
function keeperStatusLabel(status?: string | null): string {
  const key = (status ?? '').toLowerCase()
  if (Object.prototype.hasOwnProperty.call(KEEPER_STATUS_LABEL_KO, key)) {
    return KEEPER_STATUS_LABEL_KO[key as KeeperStatusLabelKey]
  }
  if (Object.prototype.hasOwnProperty.call(PHASE_LABEL_KO, key)) {
    return PHASE_LABEL_KO[key as KeeperPhaseToken]
  }
  return status ?? UNKNOWN_STATUS_LABEL
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

// ─── Funnel ──────────────────────────────────────────────────────────────────

export interface FunnelCounts {
  created: number
  inProgress: number
  awaiting: number
  completed: number
  target: number | null
}

export function computeFunnelCounts(taskList: readonly Task[], nowMs = Date.now()): FunnelCounts {
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
  return { created, inProgress, awaiting, completed, target: null }
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

// ─── Keeper Strip ────────────────────────────────────────────────────────────

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

// ─── Surface Readiness Summary ───────────────────────────────────────────────

const overviewTelemetryResource: AsyncResource<OverviewTelemetrySnapshot> = createAsyncResource()

function loadOverviewTelemetry(nowMs = Date.now()): Promise<void> {
  return overviewTelemetryResource.load(async () => {
    const sinceMs = nowMs - OVERVIEW_TELEMETRY_WINDOW_MINUTES * 60 * 1000
    const [telemetry, summary] = await Promise.all([
      fetchTelemetry({
        source: 'agent_core_event',
        since_ms: sinceMs,
        n: OVERVIEW_TELEMETRY_EVENT_SAMPLE_LIMIT,
      }),
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

// ─── Keeper-v2 overview surfaces ─────────────────────────────────────────────

function nowHMKst(): string {
  const d = new Date()
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${pad(d.getHours())}:${pad(d.getMinutes())}`
}

function OverviewHeader() {
  useNowSecondsTicker()
  const clock = nowHMKst()
  return html`
    <header class="ov-head v2-overview-head" data-testid="overview-head">
      <div>
        <!-- eyebrow + display header + purpose: overview.jsx:99-101 (copy verbatim) -->
        <span class="ov-eyebrow">운영 홈</span>
        <h1>지금, 전체</h1>
        <p class="ov-sub">fleet 전체 — 목표 · Gate · Fusion · 연결 한눈에</p>
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
  onClick,
}: {
  label: string
  value: string
  sub?: string
  tone?: 'ok' | 'bad' | 'warn' | 'volt'
  testId: string
  onClick?: () => void
}) {
  // overview.jsx:16-25 — clickable KPI cell gets .link + button role + keyboard handler
  const onKeyDown = onClick
    ? (e: KeyboardEvent) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault()
          onClick()
        }
      }
    : undefined
  return html`
    <div
      class=${`ov-kpi ${onClick ? 'link' : ''}`}
      data-testid=${testId}
      onClick=${onClick}
      role=${onClick ? 'button' : undefined}
      tabIndex=${onClick ? 0 : undefined}
      onKeyDown=${onKeyDown}
    >
      <div class="ov-kpi-k">${label}</div>
      <div class=${`ov-kpi-v ${tone ?? ''}`}>${value}${sub !== undefined ? html`<small>${sub}</small>` : null}</div>
    </div>
  `
}

// Cross-surface KPI row — overview.jsx:106-114. Seven cells, each a deep link into
// its surface. Labels and `sub` separators are copied verbatim from the prototype.
function OverviewKpiStrip({
  stats,
  fleet,
  health,
  digest,
  approvalQueueState,
}: {
  stats: OverviewStats
  fleet: KeeperFleetExecutionCounts | null
  health: DashboardCompositeHealthVerdict
  digest: OverviewDigest
  approvalQueueState: NonNullable<typeof gateData.value>['approval_queue_state'] | undefined
}) {
  const attentionCount = stats.att + health.issueCount
  const attentionValue = health.state === 'unavailable'
    ? stats.att > 0 ? `${stats.att}+?` : '—'
    : String(attentionCount)
  const attentionTone = health.state === 'attention' && health.severity === 'warn' && stats.att === 0
    ? 'warn'
    : attentionCount > 0 || health.state === 'unavailable'
      ? 'bad'
      : undefined
  const hasKeeperAttention = stats.att > 0
  const hasHealthRow = health.state !== 'healthy'
  const openAttention = () => {
    if (hasKeeperAttention && hasHealthRow) {
      document.getElementById('overview-attention')?.scrollIntoView({ behavior: 'smooth', block: 'start' })
    } else if (hasHealthRow) {
      navigate('monitoring', { section: 'fleet-health' })
    } else {
      navigate('monitoring', { section: 'agents' })
    }
  }
  return html`
    <section class="ov-kpis v2-overview-kpis" aria-label="Cross-surface KPIs" data-testid="overview-kpis">
      <${OverviewKpi} label="실행 중 keeper" value=${fleetCountText(fleet?.running)} sub=${` / ${stats.total}`} tone=${fleet?.running != null ? 'ok' : undefined} testId="kpi-run" onClick=${() => navigate('monitoring')} />
      <${OverviewKpi} label="주의 필요" value=${attentionValue} tone=${attentionTone} testId="kpi-att" onClick=${openAttention} />
      ${approvalQueueState && approvalQueueState.state !== 'ready'
        ? html`<${OverviewKpi}
            label="열린 Gate"
            value=${`${approvalQueueState.icon} ${approvalQueueState.title}`}
            sub=${approvalQueueState.operator_detail}
            tone=${approvalQueueState.severity}
            testId="kpi-approvals"
            onClick=${() => navigate('approvals')}
          />`
        : html`<${OverviewKpi}
            label="열린 Gate"
            value=${digest.openGateRequests === null ? '—' : String(digest.openGateRequests)}
            tone=${digest.openGateRequests === null || digest.openGateRequests > 0 ? 'warn' : undefined}
            testId="kpi-approvals"
            onClick=${() => navigate('approvals')}
          />`}
      <${OverviewKpi} label="최우선 목표" value=${digest.topGoalLabel ?? '—'} tone="volt" testId="kpi-top-goal" onClick=${() => navigate('workspace', { section: 'work' })} />
      <${OverviewKpi} label="활성 커넥터" value="—" testId="kpi-connectors" onClick=${() => navigate('connectors')} />
      <${OverviewKpi} label="예약 HITL" value="—" testId="kpi-schedule" onClick=${() => navigate('schedule')} />
      <${OverviewKpi} label="진행 심의" value=${String(digest.fusionRunning)} sub=${digest.fusionDone > 0 ? ` · 완료 ${digest.fusionDone}` : undefined} tone=${digest.fusionRunning > 0 ? 'volt' : undefined} testId="kpi-fusion" onClick=${() => navigate('fusion')} />
    </section>
  `
}

function attentionToneClass(sev: KeeperAttentionReason['sev']): string {
  return sev === 'bad' ? 'bg-destructive' : 'bg-warning'
}

function OverviewAttentionPanel({
  keeperList,
  health,
}: {
  keeperList: readonly Keeper[]
  health: DashboardCompositeHealthVerdict
}) {
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

  if (attn.length === 0 && health.state === 'healthy') {
    return html`
      <section id="overview-attention" class="ov-card ov-attn v2-overview-attention" data-testid="overview-attention">
        <div class="ov-card-h">
          <h3>주의 필요 · 지금 손이 필요한 것</h3>
          <span class="ov-count">0</span>
        </div>
        <div class="ov-empty">모든 keeper 정상</div>
      </section>
    `
  }

  const attentionCount = attn.length + health.issueCount
  const attentionCountLabel = health.state === 'unavailable'
    ? attn.length > 0 ? `${attn.length}+?` : '—'
    : String(attentionCount)

  return html`
    <section id="overview-attention" class="ov-card ov-attn v2-overview-attention" data-testid="overview-attention">
      <div class="ov-card-h">
        <h3>${attentionCount === 0 && health.state === 'status' ? '상태 참고' : '주의 필요 · 지금 손이 필요한 것'}</h3>
        <span class="ov-count">${attentionCountLabel}</span>
      </div>
      <div class="ov-attn-list v2-overview-attention-list">
        ${health.state === 'unavailable'
          ? html`
              <div
                class="ov-attn-row v2-overview-attention-row"
                data-testid="attention-row-composite-health-unavailable"
                onClick=${() => navigate('monitoring', { section: 'fleet-health' })}
              >
                <span class="inline-block size-2 rounded-full bg-warning"></span>
                <div class="ov-attn-meta">
                  <div class="ov-attn-name">Fleet health 미연결</div>
                  <div class="ov-attn-reason sev-warn">Backend composite health verdict has not loaded.</div>
                </div>
                <button type="button" class="ov-attn-act">상태 상세 →</button>
              </div>
            `
          : health.state === 'attention' || health.state === 'status'
            ? health.issues.map(issue => html`
                <div
                  key=${issue.kind}
                  class="ov-attn-row v2-overview-attention-row"
                  data-testid=${`attention-row-${issue.kind}`}
                  title=${issue.detail}
                  onClick=${() => navigate('monitoring', { section: 'fleet-health' })}
                >
                  <span class=${`inline-block size-2 rounded-full ${issue.severity === 'bad' ? 'bg-destructive' : 'bg-warning'}`}></span>
                  <div class="ov-attn-meta">
                    <div class="ov-attn-name">${issue.label}</div>
                    <div class=${`ov-attn-reason sev-${issue.severity}`}>${issue.detail}</div>
                  </div>
                  <button type="button" class="ov-attn-act">상태 상세 →</button>
                </div>
              `)
            : null}
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
                  ${displayName === k.name
                    ? null
                    : html`<span class="ov-attn-ns mono">${k.name}</span>`}
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
  const sampledLabel = snapshot?.truncated ? ' 샘플' : ''
  return html`
    <section class="ov-card ov-telemetry v2-overview-telemetry" data-testid="overview-telemetry">
      <div class="ov-card-h">
        <h3>텔레메트리</h3>
        <button type="button" class="ov-link" onClick=${() => navigate('logs')}>로그 보기 →</button>
      </div>
      ${snapshot
        ? html`
          <div class="ov-bars v2-overview-bars" role="img" aria-label="Live Agent Core telemetry histogram">
            ${snapshot.bars.map((b, i) => html`
              <span
                key=${i}
                class=${`ov-bar v2-overview-bar ${b >= 0.95 ? 'hot is-hot' : ''}`}
                style=${{ height: `${10 + b * 90}%` }}
              ></span>
            `)}
          </div>
          <div class="ov-tel-foot">
            <div class="ov-tel-stat"><span class="k">피크${sampledLabel}</span><span class="v mono">${snapshot.peakPerBucket}/5m</span></div>
            <div class="ov-tel-stat"><span class="k">평균${sampledLabel}</span><span class="v mono">${snapshot.averagePerBucket}/5m</span></div>
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

// ─── Domain status section (overview.jsx:159-261) ────────────────────────────
//
// "도메인 현황" header over a 7-card grid: one summary card per surface
// (work · approvals · schedule · fusion · board · connectors · fleet), each a
// deep link. Card chrome mirrors the prototype DomainCard (overview.jsx:42-53).

type DomainTone = 'ok' | 'bad' | 'warn' | 'volt'

type DomainNav = { tab: TabId; params?: Record<string, string> }

function DomainCard({
  title,
  count,
  tone,
  linkLabel,
  nav,
  testId,
  children,
}: {
  title: string
  count?: string | null
  tone?: DomainTone
  linkLabel: string
  nav: DomainNav
  testId: string
  children: unknown
}) {
  return html`
    <section class="ov-dcard v2-overview-dcard" data-testid=${testId}>
      <div class="ov-dcard-h">
        <h3>${title}</h3>
        ${count != null ? html`<span class=${`ov-dcount ${tone ?? ''}`}>${count}</span>` : null}
        <button type="button" class="ov-dlink" onClick=${() => navigate(nav.tab, nav.params)}>${linkLabel} →</button>
      </div>
      <div class="ov-dcard-body">${children}</div>
    </section>
  `
}

function OverviewDomainSection({
  stats,
  fleet,
  digest,
  approvalQueueState,
}: {
  stats: OverviewStats
  fleet: KeeperFleetExecutionCounts | null
  digest: OverviewDigest
  approvalQueueState: NonNullable<typeof gateData.value>['approval_queue_state'] | undefined
}) {
  const scheduleSummary = digest.scheduledAutomation
  const scheduleRunnerSummary = digest.scheduleRunner
  const keeperQueueSummary = digest.keeperQueue

  const scheduleRunnerRows: string[] = []
  if (scheduleRunnerSummary.hasProjection) {
    scheduleRunnerRows.push(`runner: ${scheduleRunnerSummary.status}`)
    scheduleRunnerRows.push(`tick ${scheduleRunnerSummary.tickCount} (성공 ${scheduleRunnerSummary.successCount} / 실패 ${scheduleRunnerSummary.failureCount} / Crash ${scheduleRunnerSummary.crashCount})`)
    if (scheduleRunnerSummary.tickInFlight) scheduleRunnerRows.push('현재 tick 실행 중')
    if (scheduleRunnerSummary.lastError) scheduleRunnerRows.push(`오류 ${scheduleRunnerSummary.lastError}`)
  } else {
    scheduleRunnerRows.push('schedule_runner 미연결')
  }

  const scheduleRunnerCountLabel = scheduleRunnerSummary.hasProjection
    ? `runner ${scheduleRunnerSummary.status}`
    : 'runner unavailable'
  return html`
    <h2 class="ov-section-h v2-overview-section-h" data-testid="overview-domains-header">도메인 현황</h2>
    <div class="ov-domains v2-overview-domains" data-testid="overview-domains">
      <!-- WORK · overview.jsx:162-179 -->
      <${DomainCard} title="작업 · 목표" linkLabel="작업" nav=${{ tab: 'workspace', params: { section: 'work' } }} testId="domain-work">
        ${digest.topGoals.length > 0
          ? digest.topGoals.map(g => {
              const pri = goalPriorityClass(g.priority)
              return html`
                <div key=${g.id} class="ov-goal">
                  <div class="ov-goal-top">
                    <span class=${`ov-goal-pri ${pri}`}></span>
                    <span class="ov-goal-title">${g.title}</span>
                    <span class="ov-goal-due mono">${g.due_date ?? ''}</span>
                  </div>
                  <div class="ov-goal-sub mono">P${g.priority} · ${g.phase}</div>
                </div>
              `
            })
          : html`<div class="ov-mini-empty ov-empty">활성 목표 없음</div>`}
      <//>

      <!-- APPROVALS · overview.jsx:182-198 -->
      <${DomainCard}
        title="Gate · HITL"
        count=${approvalQueueState && approvalQueueState.state !== 'ready'
          ? approvalQueueState.icon
          : digest.openGateRequests === null
            ? null
            : String(digest.openGateRequests)}
        tone=${approvalQueueState && approvalQueueState.state !== 'ready'
          ? approvalQueueState.severity
          : digest.openGateRequests === null || digest.openGateRequests > 0
            ? 'warn'
            : 'ok'}
        linkLabel="Gate"
        nav=${{ tab: 'approvals' }}
        testId="domain-approvals"
      >
        <div class="ov-mini-list">
          ${approvalQueueState && approvalQueueState.state !== 'ready'
            ? html`
                <div
                  class="ov-mini-row"
                  data-testid="overview-approval-queue-unavailable"
                  data-severity=${approvalQueueState.severity}
                  title=${approvalQueueState.operator_detail}
                >
                  <span class="ov-mini-txt">${approvalQueueState.icon} ${approvalQueueState.title}</span>
                </div>
              `
            : digest.openGateRequests === null
              ? html`<div class="ov-mini-empty">Gate queue state not loaded</div>`
            : digest.openGateRequests > 0
            ? html`
                <div class="ov-mini-row">
                  <span class="inline-block size-1.5 rounded-full bg-warning"></span>
                  <span class="ov-mini-txt">Human 판단 대기 ${digest.openGateRequests}건 · Keeper lane nonblocking</span>
                </div>
              `
            : html`<div class="ov-mini-empty ov-empty">Human 판단 대기 없음</div>`}
        </div>
      <//>

      <!-- SCHEDULE · overview.jsx:201-215 -->
      <${DomainCard}
        title="예약 · 자동화"
        count=${scheduleSummary.state === 'available' ? String(scheduleSummary.totalCount) : '—'}
        tone=${scheduleSummary.tone}
        linkLabel="예약"
        nav=${{ tab: 'schedule' }}
        testId="domain-schedule"
      >
      ${scheduleSummary.state === 'available'
        ? html`
              <div class="ov-mini-list">
                <div class="ov-mini-row" data-testid="overview-schedule-page-metadata">
                  <span class="inline-block size-1.5 rounded-full bg-warning"></span>
                  <span class="ov-mini-txt">
                    ${`표시 ${scheduleSummary.visibleCount} / 전체 ${scheduleSummary.totalCount} · 최대 ${scheduleSummary.limit}${scheduleSummary.truncated ? ' · 일부만 표시' : ''}`}
                  </span>
                </div>
                <div class="ov-mini-row">
                  <span class="inline-block size-1.5 rounded-full bg-warning"></span>
                  <span class="ov-mini-txt">상태: ${scheduleSummary.fsmState}</span>
                </div>
                <div class="ov-mini-row">
                  <span class="inline-block size-1.5 rounded-full bg-warning"></span>
                  <span class="ov-mini-txt">
                    Due ${scheduleSummary.dueCount} · Running ${scheduleSummary.runningCount} · 예약 ${scheduleSummary.scheduledCount}
                  </span>
                </div>
                <div class="ov-mini-row">
                  <span class="inline-block size-1.5 rounded-full bg-warning"></span>
                  <span class="ov-mini-txt">
                    payload: unsupported ${scheduleSummary.unsupportedPayloadCount} / unknown ${scheduleSummary.unknownPayloadCount}
                  </span>
                </div>
                ${scheduleSummary.nextDueAt
                  ? html`
                      <div class="ov-mini-row">
                        <span class="inline-block size-1.5 rounded-full bg-warning"></span>
                        <span class="ov-mini-txt mono">next ${scheduleSummary.nextDueAt}</span>
                      </div>
                    `
                  : null}
                ${scheduleSummary.warningCount > 0
                  ? html`
                      <div class="ov-mini-row">
                        <span class="inline-block size-1.5 rounded-full bg-warning"></span>
                        <span class="ov-mini-txt">projection warning ${scheduleSummary.warningCount}</span>
                      </div>
                    `
                  : null}
                <div class="ov-mini-row">
                  <span class="inline-block size-1.5 rounded-full bg-warning"></span>
                  <span class="ov-mini-txt">${scheduleRunnerCountLabel}</span>
                </div>
                ${scheduleRunnerRows.map((row, index) => html`
                  <div class="ov-mini-row" key=${index}>
                    <span class="inline-block size-1.5 rounded-full bg-warning"></span>
                    <span class="ov-mini-txt">${row}</span>
                  </div>
                `)}
              </div>
            `
          : scheduleSummary.state === 'unavailable'
            ? html`
              <div class="ov-mini-list" data-testid="overview-schedule-unavailable">
                <div class="ov-mini-row">
                  <span class="inline-block size-1.5 rounded-full bg-destructive"></span>
                  <span class="ov-mini-txt">schedule ledger 읽기 실패: ${scheduleSummary.reason}</span>
                </div>
                ${scheduleRunnerRows.map((row, index) => html`
                  <div class="ov-mini-row" key=${index}>
                    <span class="inline-block size-1.5 rounded-full bg-warning"></span>
                    <span class="ov-mini-txt">${row}</span>
                  </div>
                `)}
              </div>
            `
            : html`
              <div class="ov-mini-list">
                <div class="ov-mini-empty ov-empty">예약 자동화 projection 미연결</div>
                ${scheduleRunnerRows.map((row, index) => html`
                  <div class="ov-mini-row" key=${index}>
                    <span class="inline-block size-1.5 rounded-full bg-warning"></span>
                    <span class="ov-mini-txt">${row}</span>
                  </div>
                `)}
              </div>
            `}
      <//>

      <!-- FUSION · overview.jsx:218-230 -->
      <${DomainCard}
        title="Fusion 심의"
        count=${String(digest.fusionTotal)}
        tone="volt"
        linkLabel="Fusion"
        nav=${{ tab: 'fusion' }}
        testId="domain-fusion"
      >
        ${digest.fusionLatest
          ? html`
              <div class="ov-fus">
                <div class="ov-fus-h">
                  <span class="ov-fus-run mono">${digest.fusionLatest.runId}</span>
                </div>
                <div class="ov-fus-by mono">${digest.fusionLatest.keeper} · ${digest.fusionLatest.preset}</div>
              </div>
            `
          : null}
        <div class="ov-fus-foot">
          ${digest.fusionRunning > 0
            ? html`<span class="ov-fus-live"><span class="inline-block size-1.5 rounded-full bg-warning"></span>${digest.fusionRunning}건 심의 중</span>`
            : html`<span class="ov-fus-idle">진행 중 심의 없음</span>`}
        </div>
      <//>

      <!-- BOARD · overview.jsx:233-237
           The overview route subscribes to the GLOBAL + execution slices only
           (dashboardSlicesForRoute in dashboard-ws.ts) and never calls
           refreshBoard, so boardPosts is empty here on every fresh load.
           Rendering its length printed "전체 포스트 0" while the board route
           and the post store both held posts. lastBoardRefreshAt stays null
           until refreshBoard or hydrateBoardSnapshot runs, so it separates
           "never loaded" from "loaded and empty". boardTotal is null whenever
           the server pages the result (server_dashboard_http.ml emits total
           only when the whole result fits the fetched window), so the
           loaded-rows count is labelled as such instead of as a total. -->
      <${DomainCard} title="보드" linkLabel="보드" nav=${{ tab: 'board' }} testId="domain-board">
        ${lastBoardRefreshAt.value === null
          ? html`<div class="ov-mini-list"><div class="ov-mini-empty ov-empty">보드 데이터 미연결</div></div>`
          : boardTotal.value !== null
            ? html`<div class="ov-stat-row"><span class="k">전체 포스트</span><span class="v mono">${boardTotal.value}</span></div>`
            : html`<div class="ov-stat-row"><span class="k">불러온 포스트</span><span class="v mono">${boardPosts.value.length}</span></div>`}
      <//>

      <!-- CONNECTORS · overview.jsx:240-249 (no live connector store yet) -->
      <${DomainCard} title="커넥터" linkLabel="커넥터" nav=${{ tab: 'connectors' }} testId="domain-connectors">
        <div class="ov-mini-list">
          <div class="ov-mini-empty ov-empty">커넥터 데이터 미연결</div>
        </div>
      <//>

      <!-- FLEET summary · overview.jsx:252-260 -->
      <${DomainCard} title="Fleet 요약" linkLabel="Monitor" nav=${{ tab: 'monitoring' }} testId="domain-fleet">
        <div class="ov-fleet-sum">
          <div class="ov-fleet-stat" data-testid="fleet-stat-running"><span class="v ok">${fleetCountText(fleet?.running)}</span><span class="k">실행</span></div>
          <div class="ov-fleet-stat" data-testid="fleet-stat-recovering"><span class=${`v ${(fleet?.recovering ?? 0) > 0 ? 'warn' : ''}`}>${fleetCountText(fleet?.recovering)}</span><span class="k">복구</span></div>
          <div class="ov-fleet-stat" data-testid="fleet-stat-paused"><span class="v">${fleetCountText(fleet?.paused)}</span><span class="k">일시정지</span></div>
          <div class="ov-fleet-stat"><span class="v warn">${stats.att}</span><span class="k">주의</span></div>
          <div class="ov-fleet-stat"><span class=${`v ${stats.hot > 0 ? 'bad' : ''}`}>${stats.hot}</span><span class="k">압박</span></div>
          <div class="ov-fleet-stat"><span class="v">${stats.total}</span><span class="k">전체</span></div>
        </div>
        ${keeperQueueSummary.hasProjection
          ? html`
              <div class="ov-stat-row" data-testid="fleet-queue-storage">
                <span class="k">queue storage</span>
                <span class="v mono">${keeperQueueSummary.storageStatus}</span>
              </div>
              <div class="ov-stat-row" data-testid="fleet-queue-work">
                <span class="k">work liveness</span>
                <span class=${`v mono ${keeperQueueSummary.backlogClean ? 'ok' : 'warn'}`}>
                  ${keeperQueueSummary.workState} · ${keeperQueueSummary.runnableBacklogCount}
                  ${keeperQueueSummary.runnableOldestAgeSeconds == null
                    ? ''
                    : ` · oldest ${Math.round(keeperQueueSummary.runnableOldestAgeSeconds)}s`}
                </span>
              </div>
            `
          : html`<div class="ov-stat-row"><span class="k">queue health</span><span class="v mono">unknown</span></div>`}
        <div class="ov-stat-row"><span class="k">전체 keeper</span><span class="v mono">${stats.total}</span></div>
      <//>
    </div>
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
    // Overview and the shell consume one shared full-health resource. The
    // subscriber owns ref-counted refresh lifetime, so mounting both surfaces
    // never creates a second backend poller.
    const stopFullHealthRefresh = subscribeDashboardFullHealthRefresh()
    // Schedule state is its own projection with its own poller. Root used to
    // reach it through the tool inventory, which meant entering the home
    // surface fetched the whole tool registry.
    const stopScheduleRefresh = subscribeScheduledAutomationRefresh()
    return () => {
      window.clearInterval(interval)
      stopFullHealthRefresh()
      stopScheduleRefresh()
    }
  }, [])
  const taskList = tasks.value
  const keeperList = keepers.value
  const goalList = goals.value
  const fusionList = fusionRuns.value
  const approvalQueueState = gateData.value?.approval_queue_state
  const openGateRequests =
    approvalQueueState?.state === 'ready'
      ? gateData.value?.approval_queue?.length ?? null
      : null
  const scheduledAutomationData = scheduledAutomationProjection.value ?? null
  const fullHealth = dashboardFullHealth.value
  const scheduleRunnerStatus = fullHealth?.schedule_runner ?? null
  const keeperQueueHealth = fullHealth?.keeper_event_queue ?? null
  // Keeper execution counts come from the runtime-health fleet projection the
  // shell already holds — the same `keeper_fleet_safety_health_json` payload
  // `/health?full=1` embeds, so reading it here adds no request.
  const fleetSafety = shellRuntimeResolution.value?.fleet_safety ?? null
  const fleet = useMemo(() => resolveKeeperFleetExecutionCounts(fleetSafety), [fleetSafety])
  const compositeHealth = useMemo(() => projectDashboardCompositeHealth(fullHealth), [fullHealth])
  const stats = useMemo(() => computeOverviewStats(keeperList, taskList), [keeperList, taskList])
  const digest = useMemo(
    () => computeOverviewDigest(
      openGateRequests,
      goalList,
      fusionList,
      scheduledAutomationData,
      scheduleRunnerStatus,
      keeperQueueHealth,
    ),
    [openGateRequests, goalList, fusionList, scheduledAutomationData, scheduleRunnerStatus, keeperQueueHealth],
  )
  const telemetry = overviewTelemetryResource.state.value

  return html`
    <main class="ov v2-overview-surface ss-surface text-text-primary" data-testid="overview-surface">
      <div class="ov-scroll v2-overview-scroll">
        <${OverviewHeader} />
        <${OverviewKpiStrip}
          stats=${stats}
          fleet=${fleet}
          health=${compositeHealth}
          digest=${digest}
          approvalQueueState=${approvalQueueState}
        />
        <div class="ov-grid v2-overview-primary-grid" data-testid="overview-primary-grid">
          <${OverviewAttentionPanel} keeperList=${keeperList} health=${compositeHealth} />
          <${OverviewTelemetry} telemetry=${telemetry} />
        </div>
        <${OverviewDomainSection}
          stats=${stats}
          fleet=${fleet}
          digest=${digest}
          approvalQueueState=${approvalQueueState}
        />
      </div>
    </main>
  `
}
