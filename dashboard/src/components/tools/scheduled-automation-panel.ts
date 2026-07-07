import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import {
  resolveScheduleApproval,
  type DashboardScheduleDecision,
  type DashboardScheduledAutomationActor,
  type DashboardScheduledAutomation,
  type DashboardScheduledAutomationDispatchReceipt,
  type DashboardScheduledAutomationKeeperReactionEvidence,
  type DashboardScheduledAutomationKeeperQueueEvidence,
  type DashboardScheduledAutomationExecution,
  type DashboardScheduledAutomationLiveSupportedNonTerminalEvidence,
  type DashboardScheduledAutomationRequest,
  type DashboardScheduledAutomationSignal,
} from '../../api'
import { formatDateTimeKo } from '../../lib/format-time'
import { ActionButton } from '../common/button'
import { StatusChip, type StatusChipTone } from '../common/status-chip'
import { showToast } from '../common/toast'
import { SigilBadge } from '../v2/primitives-v2'
import { kSigil, kSlot } from '../keeper-badge'
import {
  schedPayloadSpec,
  schedRiskSpec,
  schedStatusSpec,
  type SchedStatusSpec,
} from '../v2/schedule-constants'

type ScheduleFilterKey = 'all' | 'pending' | 'due' | 'ready' | 'scheduled' | 'terminal'

const SCHEDULE_FILTERS: ReadonlyArray<{ key: ScheduleFilterKey; label: string }> = [
  { key: 'all', label: '전체' },
  { key: 'pending', label: '승인 대기' },
  { key: 'due', label: '기한 도래' },
  { key: 'ready', label: '실행 준비' },
  { key: 'scheduled', label: '예약/실행' },
  { key: 'terminal', label: '완료' },
]

function enumLabel(value: string | null | undefined): string {
  if (!value) return '-'
  return value.replace(/_/g, ' ')
}

function actorLabel(actor: DashboardScheduledAutomationActor | null | undefined): string {
  if (!actor?.id) return '-'
  const displayName = actor.display_name?.trim()
  const kind = actor.kind ? enumLabel(actor.kind) : null
  if (displayName && displayName !== actor.id) {
    return kind ? `${displayName} (${actor.id}, ${kind})` : `${displayName} (${actor.id})`
  }
  return kind ? `${actor.id} (${kind})` : actor.id
}

export function normalizedScheduleStatus(value: string | null | undefined): string {
  return value?.trim().toLowerCase() ?? ''
}

function normalized(value: string | null | undefined): string {
  return normalizedScheduleStatus(value)
}

// Pending-approval count for the always-visible nav badge + topbar schedule chip
// (schedule.jsx: onSchedule lift keeps the chip/badge in sync). Same derivation
// as the surface's '승인 대기' KPI: sparse backend counts vs materialized request
// statuses, whichever is larger, so a projection that ships only one is honored.
const SCHEDULE_PENDING_STATUSES = ['pending', 'pending_approval', 'awaiting_approval']
export function scheduledPendingApprovalCount(
  automation: DashboardScheduledAutomation | null | undefined,
): number {
  if (!automation) return 0
  const statuses = SCHEDULE_PENDING_STATUSES.map(normalizedScheduleStatus)
  const fromCounts = statuses.reduce((sum, status) => sum + (automation.counts?.[status] ?? 0), 0)
  const fromRequests = (automation.requests ?? [])
    .filter(request => statuses.includes(normalizedScheduleStatus(request.effective_status ?? request.status)))
    .length
  return Math.max(fromCounts, fromRequests)
}

export function automationTone(status: string | null | undefined): StatusChipTone {
  switch (normalized(status)) {
    case 'running':
    case 'scheduled':
    case 'ready':
    case 'approved':
      return 'ok'
    case 'pending_approval':
    case 'due':
    case 'blocked_approval':
    case 'awaiting_approval':
    case 'due_pending_refresh':
      return 'warn'
    case 'failed':
    case 'rejected':
    case 'expired':
    case 'canceled':
      return 'bad'
    case 'succeeded':
      return 'info'
    case 'idle':
    case 'cancelled':
    default:
      return 'neutral'
  }
}

function effectiveStatus(request: DashboardScheduledAutomationRequest): string {
  return request.effective_status ?? request.status
}

function dueTimestamp(request: DashboardScheduledAutomationRequest): number {
  const dueIso = request.next_due_at_iso ?? request.due_at_iso ?? null
  const parsed = dueIso ? Date.parse(dueIso) : Number.NaN
  return Number.isFinite(parsed) ? parsed : Number.MAX_SAFE_INTEGER
}

function signalTimestamp(signal: DashboardScheduledAutomationSignal): number {
  const emittedIso = signal.emitted_at_iso ?? signal.due_at_iso ?? null
  const parsed = emittedIso ? Date.parse(emittedIso) : Number.NaN
  return Number.isFinite(parsed) ? parsed : Number.MAX_SAFE_INTEGER
}

function compactTimeLabel(value: string | null | undefined): string {
  if (!value) return '--:--'
  const date = new Date(value)
  if (!Number.isFinite(date.getTime())) return clipDetailValue(value, 12)
  const hh = String(date.getHours()).padStart(2, '0')
  const mm = String(date.getMinutes()).padStart(2, '0')
  return `${hh}:${mm}`
}

function assertNever(value: never): never {
  throw new Error(`Unhandled schedule filter key: ${String(value)}`)
}

export function filterMatches(filter: ScheduleFilterKey, request: DashboardScheduledAutomationRequest): boolean {
  if (filter === 'all') return true
  const status = normalized(effectiveStatus(request))
  const readiness = normalized(request.execution_readiness)
  const operatorAction = normalized(request.operator_action)
  switch (filter) {
    case 'pending':
      return status.includes('approval') || operatorAction.includes('approve')
    case 'due':
      return status === 'due' || status === 'due_pending_refresh' || status === 'blocked_approval'
    case 'ready':
      return ['ready', 'execution_ready'].includes(readiness)
    case 'scheduled':
      return status === 'scheduled' || status === 'running'
    case 'terminal':
      return ['succeeded', 'failed', 'rejected', 'expired', 'cancelled', 'canceled'].includes(status)
    default:
      // Exhaustiveness: a new ScheduleFilterKey must fail to compile here rather
      // than silently fall through to "show all" (Unknown->Permissive-Default).
      return assertNever(filter)
  }
}

function CountChip({ name, count }: { name: string; count: number }) {
  return html`
    <span class="inline-flex items-center gap-1 rounded-[var(--r-0)] bg-[var(--color-bg-hover)] px-2 py-1 text-2xs text-[var(--color-fg-secondary)]">
      <span class="font-mono">${count.toLocaleString()}</span>
      <span>${enumLabel(name)}</span>
    </span>
  `
}

export function recurrenceLabel(request: DashboardScheduledAutomationRequest): string {
  if (request.recurrence_summary?.trim()) return request.recurrence_summary
  const recurrence = request.recurrence
  const kind = recurrence?.kind ?? request.recurrence_kind ?? 'one_shot'
  if (kind === 'interval' && typeof recurrence?.interval_sec === 'number') {
    return `every ${recurrence.interval_sec}s`
  }
  if (kind === 'daily') {
    const hour = recurrence?.hour
    const minute = recurrence?.minute
    const second = recurrence?.second ?? 0
    const timezone = recurrence?.timezone
    if (typeof hour === 'number' && typeof minute === 'number') {
      const hh = String(hour).padStart(2, '0')
      const mm = String(minute).padStart(2, '0')
      const ss = String(second).padStart(2, '0')
      return `${hh}:${mm}:${ss}${timezone ? ` ${timezone}` : ''}`
    }
  }
  if (kind === 'cron' && typeof recurrence?.expression === 'string' && recurrence.expression.trim()) {
    const timezone = recurrence.timezone
    return `cron ${recurrence.expression}${timezone ? ` ${timezone}` : ''}`
  }
  return enumLabel(kind)
}

/**
 * RFC-0234 §10 "Dashboard and operator UX" — a wake-signal feed surfaces the
 * upcoming scheduler wakes ("future rows with ... due time, payload summary,
 * and risk") ordered soonest-first. The scheduler is a turn-start channel
 * (RFC-0234 §2: proactive turn mechanisms decide whether an agent should wake);
 * this feed answers "what wakes next" rather than auditing every row like the
 * full table below.
 *
 * Every field is read verbatim from what the backend already emits (#21852):
 * id = schedule_id, at = next_due_at ?? due_at, kind = payload_kind (else the
 * recurrence label), risk = risk_class. Nothing is fabricated — a row without a
 * concrete next wake time is not a signal and is dropped.
 */
export interface WakeSignal {
  id: string
  at: number
  atIso: string | null
  kind: string
  risk: string
  readiness: string
  tone: StatusChipTone
}

// Readiness / status values that are not upcoming wake signals. Terminal rows
// are history, and running rows have already woken.
const NON_UPCOMING_WAKE_READINESS: ReadonlySet<string> = new Set(['terminal', 'expired', 'running'])
const NON_UPCOMING_WAKE_STATUS: ReadonlySet<string> = new Set([
  'running',
  'terminal',
  'expired',
  'cancelled',
  'canceled',
  'succeeded',
  'failed',
  'rejected',
])

function payloadSupportBlocksWake(request: DashboardScheduledAutomationRequest): boolean {
  return request.payload_support === 'unsupported' || request.payload_support === 'unknown'
}

function canProjectUpcomingWake(request: DashboardScheduledAutomationRequest): boolean {
  if (payloadSupportBlocksWake(request)) return false
  const readiness = normalized(request.execution_readiness)
  const status = normalized(effectiveStatus(request))
  if (readiness && NON_UPCOMING_WAKE_READINESS.has(readiness)) return false
  if (NON_UPCOMING_WAKE_STATUS.has(status)) return false
  return true
}

function payloadBlockedScheduleIds(
  requests: readonly DashboardScheduledAutomationRequest[],
): ReadonlySet<string> {
  const blockedIds = new Set<string>()
  for (const request of requests) {
    if (payloadSupportBlocksWake(request)) blockedIds.add(request.schedule_id)
  }
  return blockedIds
}

function supportedPayloadKindSet(
  automation: DashboardScheduledAutomation,
): ReadonlySet<string> | null {
  const kinds = automation.payload_support?.supported_kinds
  if (!kinds) return null
  return new Set(kinds.map(kind => kind.trim()).filter(Boolean))
}

function durableSignalPayloadBlocksWake(
  signal: DashboardScheduledAutomationSignal,
  supportedKinds: ReadonlySet<string> | null,
): boolean {
  if (!supportedKinds) return false
  const kind = signal.payload_kind?.trim()
  return !kind || !supportedKinds.has(kind)
}

function selectDurableWakeSignals(
  automation: DashboardScheduledAutomation,
): DashboardScheduledAutomationSignal[] {
  const blockedIds = payloadBlockedScheduleIds(automation.requests ?? [])
  const supportedKinds = supportedPayloadKindSet(automation)
  return [...(automation.signals ?? [])]
    .filter(signal =>
      !blockedIds.has(signal.schedule_id)
      && !durableSignalPayloadBlocksWake(signal, supportedKinds))
    .sort((a, b) => signalTimestamp(a) - signalTimestamp(b))
}

function durableWakeSignalContract(automation: DashboardScheduledAutomation): {
  rawCount: number
  visibleCount: number
  hiddenByPayloadSupport: number
  visibleSignals: DashboardScheduledAutomationSignal[]
} {
  const visibleSignals = selectDurableWakeSignals(automation)
  const rawCount = automation.signals?.length ?? 0
  return {
    rawCount,
    visibleCount: visibleSignals.length,
    hiddenByPayloadSupport: Math.max(0, rawCount - visibleSignals.length),
    visibleSignals,
  }
}

export function selectWakeSignals(
  automation: DashboardScheduledAutomation | null | undefined,
): WakeSignal[] {
  if (!automation) return []
  const signals: WakeSignal[] = []
  for (const request of automation.requests ?? []) {
    if (!canProjectUpcomingWake(request)) continue
    const at = request.next_due_at ?? request.due_at ?? null
    // No concrete wake time → no signal to surface (parse, don't validate).
    if (at == null) continue
    const readiness = request.execution_readiness ?? null
    const status = request.effective_status ?? request.status
    signals.push({
      id: request.schedule_id,
      at,
      atIso: request.next_due_at_iso ?? request.due_at_iso ?? null,
      kind: request.payload_kind?.trim() || recurrenceLabel(request),
      risk: request.risk_class,
      readiness: readiness ?? status,
      tone: automationTone(readiness ?? status),
    })
  }
  return signals.sort((a, b) => a.at - b.at)
}

function WakeSignalFeed({ signals }: { signals: WakeSignal[] }) {
  if (signals.length === 0) {
    return html`
      <div class="sch-signals text-xs text-[var(--color-fg-muted)]" data-testid="sch-signals-empty">
        예정된 wake signal 없음
      </div>
    `
  }
  return html`
    <ul class="sch-signals grid gap-1" data-testid="sch-signals">
      ${signals.map(
        signal => html`
          <li
            class="sch-signal flex flex-wrap items-center gap-x-3 gap-y-1 rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-hover)] px-2 py-1"
            data-testid="sch-signal"
          >
            <span class="sch-signal-at font-mono text-xs text-[var(--color-fg-secondary)]">
              ${formatDateTimeKo(signal.atIso ?? signal.at)}
            </span>
            <${StatusChip} tone=${signal.tone} uppercase=${false}>${enumLabel(signal.readiness)}<//>
            <span class="sch-signal-kind font-mono text-2xs text-[var(--color-fg-muted)]">${signal.kind}</span>
            <span class="sch-signal-id font-mono text-3xs text-[var(--color-fg-disabled)]">${signal.id}</span>
            <span class="sch-signal-risk text-2xs text-[var(--color-fg-muted)]">risk ${enumLabel(signal.risk)}</span>
          </li>
        `,
      )}
    </ul>
  `
}

function lastExecutionLabel(request: DashboardScheduledAutomationRequest): string {
  const execution = request.last_execution
  if (!execution) return '-'
  const status = enumLabel(execution.status)
  const finishedAt = formatDateTimeKo(execution.finished_at_iso ?? execution.started_at_iso ?? null)
  return finishedAt === '-' ? status : `${status} ${finishedAt}`
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function clipDetailValue(value: string, maxLength = 120): string {
  return value.length <= maxLength ? value : `${value.slice(0, maxLength - 3)}...`
}

function countLabel(count: number, singular: string, plural: string): string {
  return `${count.toLocaleString()} ${count === 1 ? singular : plural}`
}

function compactDetailValue(value: unknown): string | null {
  if (value == null) return null
  if (typeof value === 'string') {
    const trimmed = value.trim()
    return trimmed ? clipDetailValue(trimmed) : null
  }
  if (typeof value === 'number' || typeof value === 'boolean') return String(value)
  if (Array.isArray(value)) return `[${countLabel(value.length, 'item', 'items')}]`
  if (isRecord(value)) return `{${countLabel(Object.keys(value).length, 'field', 'fields')}}`
  return null
}

function executionDetailRows(detail: unknown): Array<{ label: string; value: string }> {
  if (detail == null) return []
  if (!isRecord(detail)) {
    const value = compactDetailValue(detail)
    return value ? [{ label: 'detail', value }] : []
  }

  return Object.entries(detail)
    .map(([label, value]) => ({
      label: clipDetailValue(enumLabel(label), 48),
      value: compactDetailValue(value),
    }))
    .filter((row): row is { label: string; value: string } => Boolean(row.label && row.value))
    .slice(0, 6)
}

function dispatchReceiptTone(
  receipt: DashboardScheduledAutomationDispatchReceipt | null | undefined,
): StatusChipTone {
  if (!receipt) return 'neutral'
  return receipt.projection_status === 'recognized' ? 'ok' : 'warn'
}

function dispatchReceiptRows(
  receipt: DashboardScheduledAutomationDispatchReceipt | null | undefined,
): Array<{ label: string; value: string }> {
  if (!receipt) return []
  const rows: Array<{ label: string; value: string | null | undefined }> = [
    { label: 'kind', value: receipt.kind },
    { label: 'queue', value: receipt.queue },
    { label: 'stimulus', value: receipt.stimulus },
    { label: 'stimulus_id', value: receipt.stimulus_id },
    { label: 'reaction_ledger_status', value: receipt.reaction_ledger_status },
    { label: 'reaction_ledger_error', value: receipt.reaction_ledger_error },
    { label: 'keeper', value: receipt.keeper_name },
    { label: 'schedule', value: receipt.schedule_id },
    { label: 'urgency', value: receipt.urgency },
    { label: 'post_id', value: receipt.post_id },
    { label: 'author', value: receipt.author },
    { label: 'hearth', value: receipt.hearth },
    { label: 'reason', value: receipt.reason },
  ]
  return rows.filter((row): row is { label: string; value: string } => {
    return typeof row.value === 'string' && row.value.trim() !== ''
  })
}

function DispatchReceiptBlock({
  receipt,
  compact = false,
}: {
  receipt: DashboardScheduledAutomationDispatchReceipt | null | undefined
  compact?: boolean
}) {
  if (!receipt) return null
  const rows = dispatchReceiptRows(receipt)
  return html`
    <div
      class=${compact
        ? 'sch-kvs'
        : 'grid gap-1 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-2'}
      data-schedule-dispatch-receipt=${receipt.projection_status}
      data-schedule-dispatch-receipt-kind=${receipt.kind ?? ''}
    >
      <div class=${compact ? 'sch-kv' : 'flex flex-wrap items-center gap-2'}>
        ${compact
          ? html`<span class="k">dispatch_receipt</span>`
          : html`<span class="text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]">dispatch receipt</span>`}
        <span class=${compact ? 'v mono' : ''}>
          <${StatusChip} tone=${dispatchReceiptTone(receipt)} uppercase=${false}>
            ${enumLabel(receipt.projection_status)}
          <//>
        </span>
      </div>
      ${rows.map(row => html`
        <div class=${compact ? 'sch-kv' : 'grid grid-cols-[5.5rem_minmax(0,1fr)] gap-2'} data-dispatch-receipt-row=${row.label}>
          <span class=${compact ? 'k' : 'truncate text-[var(--color-fg-disabled)]'} title=${row.label}>${row.label}</span>
          <span class=${compact ? 'v mono' : 'truncate font-mono text-[var(--color-fg-secondary)]'} title=${row.value}>${row.value}</span>
        </div>
      `)}
    </div>
  `
}

function queueEvidenceTone(
  evidence: DashboardScheduledAutomationKeeperQueueEvidence | null | undefined,
): StatusChipTone {
  if (!evidence) return 'neutral'
  if (evidence.projection_status === 'matched_pending' || evidence.projection_status === 'matched_inflight') return 'ok'
  if (evidence.projection_status === 'not_found' || evidence.projection_status === 'read_error') return 'warn'
  return 'bad'
}

function queueEvidenceRows(
  evidence: DashboardScheduledAutomationKeeperQueueEvidence | null | undefined,
): Array<{ label: string; value: string }> {
  if (!evidence) return []
  const readErrors = (evidence.read_errors ?? [])
    .map(error => [error.kind, error.path, error.message].filter(Boolean).join(': '))
    .filter(value => value.trim() !== '')
    .join(' | ')
  const rows: Array<{ label: string; value: string | number | null | undefined }> = [
    { label: 'source', value: evidence.source },
    { label: 'queue', value: evidence.queue },
    { label: 'stimulus', value: evidence.stimulus },
    { label: 'keeper', value: evidence.keeper_name },
    { label: 'schedule', value: evidence.schedule_id },
    { label: 'post_id', value: evidence.post_id },
    { label: 'pending_count', value: evidence.pending_count },
    { label: 'inflight_count', value: evidence.inflight_count },
    { label: 'matched_bucket', value: evidence.matched_bucket },
    { label: 'matched_payload_kind', value: evidence.matched_payload_kind },
    { label: 'matched_post_id', value: evidence.matched_post_id },
    { label: 'matched_schedule_id', value: evidence.matched_schedule_id },
    { label: 'matched_arrived_at', value: evidence.matched_arrived_at_iso },
    { label: 'matched_age_seconds', value: evidence.matched_age_seconds },
    { label: 'read_errors', value: readErrors },
    { label: 'reason', value: evidence.reason },
  ]
  return rows
    .map(row => ({ label: row.label, value: row.value == null ? '' : String(row.value) }))
    .filter(row => row.value.trim() !== '')
}

function QueueEvidenceBlock({
  evidence,
  compact = false,
}: {
  evidence: DashboardScheduledAutomationKeeperQueueEvidence | null | undefined
  compact?: boolean
}) {
  if (!evidence) return null
  const rows = queueEvidenceRows(evidence)
  return html`
    <div
      class=${compact
        ? 'sch-kvs'
        : 'grid gap-1 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-2'}
      data-schedule-keeper-queue-evidence=${evidence.projection_status}
      data-schedule-keeper-queue-evidence-source=${evidence.source ?? ''}
    >
      <div class=${compact ? 'sch-kv' : 'flex flex-wrap items-center gap-2'}>
        ${compact
          ? html`<span class="k">keeper_queue_evidence</span>`
          : html`<span class="text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]">keeper queue evidence</span>`}
        <span class=${compact ? 'v mono' : ''}>
          <${StatusChip} tone=${queueEvidenceTone(evidence)} uppercase=${false}>
            ${enumLabel(evidence.projection_status)}
          <//>
        </span>
      </div>
      ${rows.map(row => html`
        <div class=${compact ? 'sch-kv' : 'grid grid-cols-[7.5rem_minmax(0,1fr)] gap-2'} data-keeper-queue-evidence-row=${row.label}>
          <span class=${compact ? 'k' : 'truncate text-[var(--color-fg-disabled)]'} title=${row.label}>${row.label}</span>
          <span class=${compact ? 'v mono' : 'truncate font-mono text-[var(--color-fg-secondary)]'} title=${row.value}>${row.value}</span>
        </div>
      `)}
    </div>
  `
}

function reactionEvidenceTone(
  evidence: DashboardScheduledAutomationKeeperReactionEvidence | null | undefined,
): StatusChipTone {
  if (!evidence) return 'neutral'
  if (
    evidence.projection_status === 'matched_consumed_ack' ||
    evidence.projection_status === 'matched_turn_started'
  ) return 'ok'
  if (
    evidence.projection_status === 'matched_stimulus' ||
    evidence.projection_status === 'not_found' ||
    evidence.projection_status === 'missing_stimulus_id'
  ) return 'warn'
  return 'bad'
}

function reactionEvidenceRows(
  evidence: DashboardScheduledAutomationKeeperReactionEvidence | null | undefined,
): Array<{ label: string; value: string }> {
  if (!evidence) return []
  const rows: Array<{ label: string; value: string | number | boolean | null | undefined }> = [
    { label: 'source', value: evidence.source },
    { label: 'keeper', value: evidence.keeper_name },
    { label: 'schedule', value: evidence.schedule_id },
    { label: 'post_id', value: evidence.post_id },
    { label: 'stimulus', value: evidence.stimulus },
    { label: 'stimulus_id', value: evidence.stimulus_id },
    { label: 'stimulus_kind', value: evidence.stimulus_kind },
    { label: 'reaction_kind', value: evidence.reaction_kind },
    { label: 'stimulus_seen', value: evidence.stimulus_seen },
    { label: 'turn_started_seen', value: evidence.turn_started_seen },
    { label: 'event_queue_ack_seen', value: evidence.event_queue_ack_seen },
    { label: 'matched_record_count', value: evidence.matched_record_count },
    { label: 'stimulus_recorded_at', value: evidence.stimulus_recorded_at_iso },
    { label: 'turn_started_recorded_at', value: evidence.turn_started_recorded_at_iso },
    { label: 'event_queue_ack_recorded_at', value: evidence.event_queue_ack_recorded_at_iso },
    { label: 'latest_recorded_at', value: evidence.latest_recorded_at_iso },
    { label: 'reason', value: evidence.reason },
  ]
  return rows
    .map(row => ({ label: row.label, value: row.value == null ? '' : String(row.value) }))
    .filter(row => row.value.trim() !== '')
}

function ReactionEvidenceBlock({
  evidence,
  compact = false,
}: {
  evidence: DashboardScheduledAutomationKeeperReactionEvidence | null | undefined
  compact?: boolean
}) {
  if (!evidence) return null
  const rows = reactionEvidenceRows(evidence)
  return html`
    <div
      class=${compact
        ? 'sch-kvs'
        : 'grid gap-1 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-2'}
      data-schedule-keeper-reaction-evidence=${evidence.projection_status}
      data-schedule-keeper-reaction-evidence-source=${evidence.source ?? ''}
    >
      <div class=${compact ? 'sch-kv' : 'flex flex-wrap items-center gap-2'}>
        ${compact
          ? html`<span class="k">keeper_reaction_evidence</span>`
          : html`<span class="text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]">keeper reaction evidence</span>`}
        <span class=${compact ? 'v mono' : ''}>
          <${StatusChip} tone=${reactionEvidenceTone(evidence)} uppercase=${false}>
            ${enumLabel(evidence.projection_status)}
          <//>
        </span>
      </div>
      ${rows.map(row => html`
        <div class=${compact ? 'sch-kv' : 'grid grid-cols-[8.5rem_minmax(0,1fr)] gap-2'} data-keeper-reaction-evidence-row=${row.label}>
          <span class=${compact ? 'k' : 'truncate text-[var(--color-fg-disabled)]'} title=${row.label}>${row.label}</span>
          <span class=${compact ? 'v mono' : 'truncate font-mono text-[var(--color-fg-secondary)]'} title=${row.value}>${row.value}</span>
        </div>
      `)}
    </div>
  `
}

function wakeEvidenceStatus(value: { projection_status?: string | null } | null | undefined): string {
  const status = value?.projection_status?.trim()
  return status && status.length > 0 ? status : 'missing'
}

function wakeEvidenceTone(
  value: { projection_status?: string | null } | null | undefined,
  tone: StatusChipTone,
): StatusChipTone {
  return value ? tone : 'warn'
}

function isKeeperWakePayload(request: DashboardScheduledAutomationRequest): boolean {
  return request.payload_kind === 'masc.keeper_wake'
}

function hasWakeEvidenceSummary(request: DashboardScheduledAutomationRequest): boolean {
  return isKeeperWakePayload(request) ||
    request.dispatch_receipt != null ||
    request.keeper_queue_evidence != null ||
    request.keeper_reaction_evidence != null
}

function wakeEvidenceJoinKey(request: DashboardScheduledAutomationRequest): string | null {
  const candidates = [
    request.dispatch_receipt?.post_id,
    request.keeper_queue_evidence?.post_id,
    request.keeper_reaction_evidence?.post_id,
    request.dispatch_receipt?.stimulus_id,
    request.keeper_reaction_evidence?.stimulus_id,
  ]
  for (const candidate of candidates) {
    const value = candidate?.trim()
    if (value) return value
  }
  return null
}

function WakeEvidenceSummary({ request }: { request: DashboardScheduledAutomationRequest }) {
  if (!hasWakeEvidenceSummary(request)) return null
  const receiptStatus = wakeEvidenceStatus(request.dispatch_receipt)
  const queueStatus = wakeEvidenceStatus(request.keeper_queue_evidence)
  const reactionStatus = wakeEvidenceStatus(request.keeper_reaction_evidence)
  const joinKey = wakeEvidenceJoinKey(request)
  const items: ReadonlyArray<{
    key: string
    label: string
    status: string
    tone: StatusChipTone
  }> = [
    {
      key: 'receipt',
      label: 'receipt',
      status: receiptStatus,
      tone: wakeEvidenceTone(request.dispatch_receipt, dispatchReceiptTone(request.dispatch_receipt)),
    },
    {
      key: 'queue',
      label: 'queue',
      status: queueStatus,
      tone: wakeEvidenceTone(request.keeper_queue_evidence, queueEvidenceTone(request.keeper_queue_evidence)),
    },
    {
      key: 'reaction',
      label: 'reaction',
      status: reactionStatus,
      tone: wakeEvidenceTone(request.keeper_reaction_evidence, reactionEvidenceTone(request.keeper_reaction_evidence)),
    },
  ]
  return html`
    <div
      class="sch-wake-evidence"
      data-schedule-wake-evidence-summary=${request.schedule_id}
      data-schedule-wake-evidence-receipt=${receiptStatus}
      data-schedule-wake-evidence-queue=${queueStatus}
      data-schedule-wake-evidence-reaction=${reactionStatus}
    >
      <span class="sch-wake-title">wake evidence</span>
      ${items.map(item => html`
        <span class="sch-wake-item" data-schedule-wake-evidence-item=${item.key}>
          ${item.label} <${StatusChip} tone=${item.tone} uppercase=${false}>${enumLabel(item.status)}<//>
        </span>
      `)}
      ${joinKey
        ? html`<span class="sch-wake-join mono" title=${joinKey}>post ${joinKey}</span>`
        : null}
    </div>
  `
}

function PayloadCell({ request }: { request: DashboardScheduledAutomationRequest }) {
  const kind = request.payload_kind ?? '-'
  const target = request.payload_target?.trim() || null
  const summary = request.payload_summary?.trim() || null
  const support = request.payload_support
  const supportTone: StatusChipTone =
    support === 'supported' ? 'ok' : support === 'unsupported' ? 'bad' : 'neutral'
  return html`
    <div class="max-w-[18rem]">
      <div class="flex flex-wrap items-center gap-2">
        <span class="font-mono text-xs text-[var(--color-fg-secondary)]">${kind}</span>
        ${support
          ? html`<${StatusChip} tone=${supportTone} uppercase=${false}>${enumLabel(support)}<//>`
          : null}
      </div>
      ${target
        ? html`<div class="mt-1 font-mono text-3xs text-[var(--color-fg-muted)]">${target}</div>`
        : null}
      ${summary
        ? html`<div class="mt-1 truncate text-3xs text-[var(--color-fg-muted)]" title=${summary}>${summary}</div>`
        : null}
    </div>
  `
}

function keeperToolStatusTone(request: DashboardScheduledAutomationRequest): StatusChipTone {
  const status = request.keeper_next_tool_status
  if (!status) return 'neutral'
  if (status.registered_schema === false || status.dispatch_registered === false) return 'bad'
  if (status.direct_call_allowed === false) return 'warn'
  return 'ok'
}

function keeperToolStatusLabel(request: DashboardScheduledAutomationRequest): string {
  const status = request.keeper_next_tool_status
  if (!status) return 'unknown'
  if (status.registered_schema === false || status.dispatch_registered === false) return 'orphan'
  if (status.direct_call_allowed === false) return 'blocked'
  return 'callable'
}

function keeperToolSurfaceLabel(request: DashboardScheduledAutomationRequest): string {
  const status = request.keeper_next_tool_status
  if (!status) return 'surface unknown'
  const surfaces = status.surfaces ?? []
  const surfaceCount = status.surface_count ?? surfaces.length
  if (surfaceCount <= 0) return 'no surface'
  if (surfaceCount === 1 && surfaces[0]) return surfaces[0].replace(/_/g, ' ')
  return `${surfaceCount} surfaces`
}

function KeeperActionCell({ request }: { request: DashboardScheduledAutomationRequest }) {
  const nextTool = request.keeper_next_tool?.trim() || null
  const nextAction = request.keeper_next_action?.trim() || null
  const status = request.keeper_next_tool_status
  const visibility = status?.visibility?.trim() || null
  if (!nextTool && !nextAction) return html`<span class="text-xs text-[var(--color-fg-disabled)]">-</span>`
  return html`
    <div class="max-w-[16rem]">
      ${nextTool
        ? html`<div class="truncate font-mono text-3xs text-[var(--color-fg-secondary)]" title=${nextTool}>${nextTool}</div>`
        : null}
      ${status
        ? html`
            <div class="mt-1 flex flex-wrap items-center gap-1">
              <${StatusChip} tone=${keeperToolStatusTone(request)} uppercase=${false}>
                ${keeperToolStatusLabel(request)}
              <//>
              ${visibility
                ? html`<span class="rounded-[var(--r-0)] bg-[var(--color-bg-hover)] px-1.5 py-0.5 text-3xs text-[var(--color-fg-muted)]">${visibility.replace(/_/g, ' ')}</span>`
                : null}
              <span class="rounded-[var(--r-0)] bg-[var(--color-bg-hover)] px-1.5 py-0.5 text-3xs text-[var(--color-fg-muted)]">${keeperToolSurfaceLabel(request)}</span>
            </div>
          `
        : null}
      ${nextAction
        ? html`<div class="mt-1 truncate text-3xs text-[var(--color-fg-muted)]" title=${nextAction}>${nextAction}</div>`
        : null}
    </div>
  `
}

function isTerminalStatus(status: string | null | undefined): boolean {
  switch (status) {
    case 'succeeded':
    case 'failed':
    case 'rejected':
    case 'cancelled':
    case 'expired':
      return true
    default:
      return false
  }
}

function isApprovalActionable(request: DashboardScheduledAutomationRequest): boolean {
  if (isTerminalStatus(request.status) || isTerminalStatus(request.effective_status)) return false
  return request.operator_action === 'approve_or_reject'
    || request.execution_readiness === 'blocked_approval'
    || request.execution_readiness === 'awaiting_approval'
    || request.effective_status === 'blocked_approval'
    || request.effective_status === 'awaiting_approval'
}

function ApprovalCell({
  request,
  onResolved,
}: {
  request: DashboardScheduledAutomationRequest
  onResolved?: () => Promise<void> | void
}) {
  const [pendingDecision, setPendingDecision] = useState<DashboardScheduleDecision | null>(null)
  const approval = request.approval_policy ?? (request.approval_required ? 'required' : 'not_required')
  const actionable = isApprovalActionable(request)
  const busy = pendingDecision !== null

  async function decide(decision: DashboardScheduleDecision) {
    setPendingDecision(decision)
    try {
      await resolveScheduleApproval(
        request.schedule_id,
        decision,
        decision === 'reject' ? 'rejected from dashboard' : undefined,
      )
      showToast(
        `${request.schedule_id} ${decision === 'approve' ? 'approved' : 'rejected'}`,
        'success',
      )
      await onResolved?.()
    } catch (err) {
      showToast(err instanceof Error ? err.message : 'schedule approval failed', 'error')
    } finally {
      setPendingDecision(null)
    }
  }

  return html`
    <div class="grid gap-1">
      <span>${enumLabel(approval)}</span>
      ${actionable
        ? html`
            <div class="flex flex-wrap gap-1">
              <${ActionButton}
                variant="ok"
                size="sm"
                disabled=${busy}
                ariaBusy=${pendingDecision === 'approve'}
                testId=${`schedule-approve-${request.schedule_id}`}
                onClick=${() => { void decide('approve') }}
              >Approve<//>
              <${ActionButton}
                variant="danger"
                size="sm"
                disabled=${busy}
                ariaBusy=${pendingDecision === 'reject'}
                testId=${`schedule-reject-${request.schedule_id}`}
                onClick=${() => { void decide('reject') }}
              >Reject<//>
            </div>
          `
        : null}
    </div>
  `
}

function InfoBlock({
  label,
  value,
  mono = false,
}: {
  label: string
  value: string
  mono?: boolean
}) {
  return html`
    <div class="min-w-0 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3 py-2">
      <div class="text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]">${label}</div>
      <div class=${`mt-1 truncate text-xs text-[var(--color-fg-secondary)] ${mono ? 'font-mono' : ''}`} title=${value}>${value}</div>
    </div>
  `
}

function ScheduleCard({
  request,
  selected,
  onSelect,
}: {
  request: DashboardScheduledAutomationRequest
  selected: boolean
  onSelect: (request: DashboardScheduledAutomationRequest) => void
}) {
  const requestStatus = effectiveStatus(request)
  const readiness = request.execution_readiness ?? '-'
  const action = request.operator_action ?? '-'
  const dueIso = request.next_due_at_iso ?? request.due_at_iso ?? null
  const approval = request.approval_policy ?? (request.approval_required ? 'required' : 'not_required')
  return html`
    <article
      class=${`v2-lab-card rounded-[var(--r-1)] border bg-[var(--color-bg-surface)] p-4 ${selected ? 'border-[var(--color-accent-fg)]' : 'border-[var(--color-border-default)]'}`}
      data-schedule-id=${request.schedule_id}
    >
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]">예약</div>
          <div class="mt-1 truncate font-mono text-sm font-semibold text-[var(--color-fg-primary)]" title=${request.schedule_id}>
            ${request.schedule_id}
          </div>
        </div>
        <div class="flex items-center gap-2">
          <${StatusChip} tone=${automationTone(requestStatus)} uppercase=${false}>${enumLabel(requestStatus)}<//>
          <button
            type="button"
            class="rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-2 py-1 text-3xs text-[var(--color-fg-muted)] transition-colors hover:border-[var(--color-accent-fg)] hover:text-[var(--color-fg-primary)]"
            aria-pressed=${selected ? 'true' : 'false'}
            data-schedule-detail=${request.schedule_id}
            onClick=${() => { onSelect(request) }}
          >
            상세
          </button>
        </div>
      </div>

      <div class="mt-3 grid gap-2 sm:grid-cols-2 xl:grid-cols-4">
        <${InfoBlock} label="실행 준비" value=${enumLabel(readiness)} />
        <${InfoBlock} label="운영자 조치" value=${enumLabel(action)} />
        <${InfoBlock} label="위험도" value=${enumLabel(request.risk_class)} />
        <${InfoBlock} label="승인 정책" value=${enumLabel(approval)} />
        <${InfoBlock} label="반복" value=${recurrenceLabel(request)} />
        <${InfoBlock} label="마지막 실행" value=${lastExecutionLabel(request)} />
        <${InfoBlock} label="예정 시각" value=${formatDateTimeKo(dueIso)} mono=${true} />
        <${InfoBlock} label="출처" value=${enumLabel(request.source)} />
      </div>

      <div class="mt-3 grid gap-3 lg:grid-cols-2">
        <section class="min-w-0 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3 py-2">
          <div class="text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]">키퍼 다음 단계</div>
          <div class="mt-2"><${KeeperActionCell} request=${request} /></div>
        </section>
        <section class="min-w-0 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3 py-2">
          <div class="text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]">페이로드</div>
          <div class="mt-2"><${PayloadCell} request=${request} /></div>
        </section>
      </div>

      <div class="mt-3 flex flex-wrap gap-2 text-3xs text-[var(--color-fg-muted)]">
        ${requestStatus !== request.status
          ? html`<span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] px-2 py-0.5">원본 ${enumLabel(request.status)}</span>`
          : null}
        ${request.requires_separate_human_grant
          ? html`<span class="rounded-[var(--r-0)] border border-[var(--color-status-warn)] px-2 py-0.5 text-[var(--color-status-warn)]">별도 human grant 필요</span>`
          : null}
        ${request.payload_digest
          ? html`<span class="rounded-[var(--r-0)] border border-[var(--color-border-default)] px-2 py-0.5 font-mono">${request.payload_digest}</span>`
          : null}
      </div>
    </article>
  `
}

function LastExecutionBlock({
  execution,
  dispatchReceipt,
  queueEvidence,
  reactionEvidence,
}: {
  execution: DashboardScheduledAutomationExecution | null | undefined
  dispatchReceipt: DashboardScheduledAutomationDispatchReceipt | null | undefined
  queueEvidence: DashboardScheduledAutomationKeeperQueueEvidence | null | undefined
  reactionEvidence: DashboardScheduledAutomationKeeperReactionEvidence | null | undefined
}) {
  if (!execution) {
    return html`<div class="mt-1 text-xs text-[var(--color-fg-muted)]">-</div>`
  }

  const detailRows = executionDetailRows(execution.detail)
  return html`
    <div class="mt-1 grid gap-2 text-xs text-[var(--color-fg-muted)]">
      <div class="flex flex-wrap items-center gap-2">
        <${StatusChip} tone=${automationTone(execution.status)} uppercase=${false}>${enumLabel(execution.status)}<//>
        ${execution.error ? html`<span>${execution.error}</span>` : null}
      </div>
      <div class="grid gap-1 text-3xs text-[var(--color-fg-disabled)]">
        <div class="grid grid-cols-[4.5rem_minmax(0,1fr)] gap-2">
          <span>실행</span>
          <span class="truncate font-mono" title=${execution.execution_id}>${execution.execution_id}</span>
        </div>
        <div class="grid grid-cols-[4.5rem_minmax(0,1fr)] gap-2">
          <span>시작</span>
          <span class="font-mono">${formatDateTimeKo(execution.started_at_iso ?? null)}</span>
        </div>
        <div class="grid grid-cols-[4.5rem_minmax(0,1fr)] gap-2">
          <span>종료</span>
          <span class="font-mono">${formatDateTimeKo(execution.finished_at_iso ?? null)}</span>
        </div>
      </div>
      ${detailRows.length > 0
        ? html`
            <div class="grid gap-1 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-2">
              <div class="text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]">상세</div>
              ${detailRows.map(row => html`
                <div class="grid grid-cols-[5.5rem_minmax(0,1fr)] gap-2" data-execution-detail-row=${row.label}>
                  <span class="truncate text-[var(--color-fg-disabled)]" title=${row.label}>${row.label}</span>
                  <span class="truncate font-mono text-[var(--color-fg-secondary)]" title=${row.value}>${row.value}</span>
                </div>
              `)}
            </div>
          `
        : null}
      <${DispatchReceiptBlock} receipt=${dispatchReceipt} />
      <${QueueEvidenceBlock} evidence=${queueEvidence} />
      <${ReactionEvidenceBlock} evidence=${reactionEvidence} />
    </div>
  `
}

function ScheduleDetailPanel({
  request,
  onResolved,
}: {
  request: DashboardScheduledAutomationRequest | null
  onResolved?: () => Promise<void> | void
}) {
  if (!request) {
    return html`
      <section class="rounded-[var(--r-1)] border border-dashed border-[var(--color-border-default)] px-3 py-6 text-center text-xs text-[var(--color-fg-muted)]">
        예약을 선택하세요.
      </section>
    `
  }

  const requestStatus = effectiveStatus(request)
  const dueIso = request.next_due_at_iso ?? request.due_at_iso ?? null
  const requestedAtIso = request.requested_at_iso ?? null
  const expiresAtIso = request.expires_at_iso ?? null
  const execution = request.last_execution
  return html`
    <section class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3 py-3" data-schedule-detail-panel=${request.schedule_id}>
      <div class="flex flex-wrap items-start justify-between gap-2">
        <div class="min-w-0">
          <div class="text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]">선택한 예약</div>
          <div class="mt-1 truncate font-mono text-sm font-semibold text-[var(--color-fg-primary)]" title=${request.schedule_id}>${request.schedule_id}</div>
        </div>
        <${StatusChip} tone=${automationTone(requestStatus)} uppercase=${false}>${enumLabel(requestStatus)}<//>
      </div>

      <div class="mt-3 grid gap-2 text-xs text-[var(--color-fg-secondary)]">
        <div class="grid grid-cols-[7rem_minmax(0,1fr)] gap-2">
          <span class="text-[var(--color-fg-disabled)]">예정</span>
          <span class="font-mono">${formatDateTimeKo(dueIso)}</span>
        </div>
        <div class="grid grid-cols-[7rem_minmax(0,1fr)] gap-2">
          <span class="text-[var(--color-fg-disabled)]">요청</span>
          <span class="font-mono">${formatDateTimeKo(requestedAtIso)}</span>
        </div>
        <div class="grid grid-cols-[7rem_minmax(0,1fr)] gap-2">
          <span class="text-[var(--color-fg-disabled)]">만료</span>
          <span class="font-mono">${formatDateTimeKo(expiresAtIso)}</span>
        </div>
        <div class="grid grid-cols-[7rem_minmax(0,1fr)] gap-2">
          <span class="text-[var(--color-fg-disabled)]">요청자</span>
          <span>${actorLabel(request.requested_by)}</span>
        </div>
        <div class="grid grid-cols-[7rem_minmax(0,1fr)] gap-2">
          <span class="text-[var(--color-fg-disabled)]">예약자</span>
          <span>${actorLabel(request.scheduled_by)}</span>
        </div>
        <div class="grid grid-cols-[7rem_minmax(0,1fr)] gap-2">
          <span class="text-[var(--color-fg-disabled)]">실행 준비</span>
          <span>${enumLabel(request.execution_readiness)}</span>
        </div>
        <div class="grid grid-cols-[7rem_minmax(0,1fr)] gap-2">
          <span class="text-[var(--color-fg-disabled)]">운영자 조치</span>
          <span>${enumLabel(request.operator_action)}</span>
        </div>
        <div class="grid grid-cols-[7rem_minmax(0,1fr)] gap-2">
          <span class="text-[var(--color-fg-disabled)]">승인</span>
          <span><${ApprovalCell} request=${request} onResolved=${onResolved} /></span>
        </div>
        <div class="grid grid-cols-[7rem_minmax(0,1fr)] gap-2">
          <span class="text-[var(--color-fg-disabled)]">위험도</span>
          <span>${enumLabel(request.risk_class)}</span>
        </div>
        <div class="grid grid-cols-[7rem_minmax(0,1fr)] gap-2">
          <span class="text-[var(--color-fg-disabled)]">반복</span>
          <span>${recurrenceLabel(request)}</span>
        </div>
      </div>

      <div class="mt-3 grid gap-3">
        <div>
          <div class="text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]">키퍼 다음 단계</div>
          <div class="mt-1"><${KeeperActionCell} request=${request} /></div>
        </div>
        <div>
          <div class="text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]">페이로드</div>
          <div class="mt-1"><${PayloadCell} request=${request} /></div>
        </div>
        <div>
          <div class="text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]">최근 실행</div>
          <${LastExecutionBlock}
            execution=${execution}
            dispatchReceipt=${request.dispatch_receipt ?? null}
            queueEvidence=${request.keeper_queue_evidence ?? null}
            reactionEvidence=${request.keeper_reaction_evidence ?? null}
          />
        </div>
      </div>
    </section>
  `
}

function WakeSignalItem({
  request,
  onSelect,
}: {
  request: DashboardScheduledAutomationRequest
  onSelect: (request: DashboardScheduledAutomationRequest) => void
}) {
  const requestStatus = effectiveStatus(request)
  const dueIso = request.next_due_at_iso ?? request.due_at_iso ?? null
  const action = request.operator_action ? enumLabel(request.operator_action) : 'observe'
  const nextTool = request.keeper_next_tool?.trim() || null
  return html`
    <li class="grid grid-cols-[3.25rem_minmax(0,1fr)] items-start gap-3 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3 py-2">
      <span
        class="font-mono text-3xs text-[var(--color-fg-muted)]"
        title=${formatDateTimeKo(dueIso)}
        data-schedule-signal-at=${request.schedule_id}
      >
        ${compactTimeLabel(dueIso)}
      </span>
      <div class="min-w-0">
        <div class="flex flex-wrap items-center gap-2">
          <span data-schedule-signal-kind=${requestStatus}>
            <${StatusChip} tone=${automationTone(requestStatus)} uppercase=${false}>${enumLabel(requestStatus)}<//>
          </span>
          <button
            type="button"
            class="min-w-0 truncate bg-transparent p-0 text-left font-mono text-xs text-[var(--color-fg-secondary)] hover:text-[var(--color-accent-fg)] hover:underline"
            title=${request.schedule_id}
            data-schedule-signal-schedule=${request.schedule_id}
            onClick=${() => { onSelect(request) }}
          >
            ${request.schedule_id}
          </button>
        </div>
        <div class="mt-1 truncate text-3xs text-[var(--color-fg-disabled)]" title=${action}>
          ${action}
        </div>
        ${nextTool
          ? html`<div class="mt-1 truncate font-mono text-3xs text-[var(--color-fg-disabled)]" title=${nextTool}>${nextTool}</div>`
          : null}
      </div>
    </li>
  `
}

function DurableSignalItem({
  signal,
  onSelectSchedule,
}: {
  signal: DashboardScheduledAutomationSignal
  onSelectSchedule: (scheduleId: string) => void
}) {
  const kind = enumLabel(signal.kind || signal.event_type)
  const emittedIso = signal.emitted_at_iso ?? null
  const dueIso = signal.due_at_iso ?? null
  const payloadKind = signal.payload_kind?.trim() || null
  const risk = enumLabel(signal.risk_class)
  const digest = signal.payload_digest?.trim() || null
  const payloadLine = [payloadKind, digest].filter(Boolean).join(' / ')
  return html`
    <li
      class="grid grid-cols-[3.25rem_minmax(0,1fr)] items-start gap-x-3 gap-y-1 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] px-3 py-2 sm:grid-cols-[3.25rem_minmax(0,1fr)_auto]"
      data-schedule-signal-id=${signal.signal_id}
    >
      <span
        class="font-mono text-3xs text-[var(--color-fg-muted)]"
        title=${formatDateTimeKo(emittedIso)}
        data-schedule-signal-at=${signal.signal_id}
      >
        ${compactTimeLabel(emittedIso)}
      </span>
      <div class="min-w-0">
        <div class="flex flex-wrap items-center gap-2">
          <span data-schedule-signal-kind=${signal.kind || signal.event_type || ''}>
            <${StatusChip} tone=${automationTone(signal.kind)} uppercase=${false}>${kind}<//>
          </span>
          <button
            type="button"
            class="min-w-0 truncate bg-transparent p-0 text-left font-mono text-xs text-[var(--color-fg-secondary)] hover:text-[var(--color-accent-fg)] hover:underline"
            title=${signal.schedule_id}
            data-schedule-signal-schedule=${signal.schedule_id}
            onClick=${() => { onSelectSchedule(signal.schedule_id) }}
          >
            ${signal.schedule_id}
          </button>
        </div>
        <div class="mt-1 grid gap-0.5 text-3xs text-[var(--color-fg-disabled)]">
          <div class="truncate font-mono" title=${signal.signal_id}>${signal.signal_id}</div>
          <div class="truncate" title=${formatDateTimeKo(dueIso)}>
            due ${formatDateTimeKo(dueIso)}
          </div>
          ${payloadLine
            ? html`<div class="truncate font-mono" title=${payloadLine}>${payloadLine}</div>`
            : null}
        </div>
      </div>
      <span
        class="col-start-2 justify-self-start font-mono text-3xs text-[var(--color-fg-disabled)] sm:col-start-auto sm:justify-self-end"
        data-schedule-signal-risk=${signal.signal_id}
      >
        ${risk}
      </span>
    </li>
  `
}

/* ════════════════════════════════════════════════════════════════════════
   keeper-v2 prototype surface (schedule.jsx). Emits the vendored `.sch-*` /
   `.turn-*` DOM so styles/keeper-v2/schedule.css applies. Opt-in via
   `variant="v2"`; the default `diagnostics` path above is the dense FSM view
   reused by the Tools surface and must stay byte-stable.

   Live data only — no fabricated operator/timestamps. Live fields absent in the
   prototype model (relative due text "4h 12m 후", structured decision
   provenance, payload `body`) are rendered from the real ISO timestamps /
   marked data-stub rather than invented (audit P2 #11, #12). The live approval
   API supports approve/reject only (no cancel), so the prototype's cancel
   action is omitted here rather than wired to a no-op. */

// Live status strings are lower_snake (pending_approval); the vendored
// SCHED_STATUS map is keyed on Schedule_domain PascalCase. Total function:
// unknown statuses fall back to schedStatusSpec's dim spec.
const LIVE_STATUS_TO_SPEC_KEY: Readonly<Record<string, string>> = {
  pending_approval: 'Pending_approval',
  awaiting_approval: 'Pending_approval',
  blocked_approval: 'Pending_approval',
  scheduled: 'Scheduled',
  due: 'Due',
  due_pending_refresh: 'Due',
  running: 'Running',
  succeeded: 'Succeeded',
  failed: 'Failed',
  rejected: 'Rejected',
  cancelled: 'Cancelled',
  canceled: 'Cancelled',
  expired: 'Expired',
}

// Live risk_class strings are lower_snake (workspace_write); SCHED_RISK is keyed
// PascalCase. Same total-function fallback contract.
const LIVE_RISK_TO_SPEC_KEY: Readonly<Record<string, string>> = {
  reminder_only: 'Reminder_only',
  read_only: 'Read_only',
  workspace_write: 'Workspace_write',
  external_write: 'External_write',
  destructive: 'Destructive',
  cost_bearing: 'Cost_bearing',
}

function statusSpecForLive(status: string | null | undefined): SchedStatusSpec {
  const key = LIVE_STATUS_TO_SPEC_KEY[normalized(status)]
  // Pass the resolved PascalCase key when known, else the raw value so the
  // fallback renders the original string rather than a generic placeholder.
  return schedStatusSpec(key ?? status ?? undefined)
}

function riskSpecForLive(risk: string | null | undefined): { lbl: string; cls: string } {
  const key = LIVE_RISK_TO_SPEC_KEY[normalized(risk)]
  return schedRiskSpec(key ?? risk ?? undefined)
}

type PayloadSupportState = NonNullable<DashboardScheduledAutomationRequest['payload_support']>

function payloadSupportLabel(support: PayloadSupportState): string {
  switch (support) {
    case 'supported':
      return 'payload supported'
    case 'unsupported':
      return 'payload unsupported'
    case 'unknown':
      return 'payload unknown'
    default:
      return assertNever(support)
  }
}

function payloadSupportToneClass(support: PayloadSupportState): string {
  switch (support) {
    case 'supported':
      return 'ok'
    case 'unsupported':
      return 'bad'
    case 'unknown':
      return 'warn'
    default:
      return assertNever(support)
  }
}

function isUnsupportedPayloadRequest(request: DashboardScheduledAutomationRequest): boolean {
  return request.payload_support === 'unsupported'
}

function isUnknownPayloadRequest(request: DashboardScheduledAutomationRequest): boolean {
  return request.payload_support === 'unknown'
}

function kindCountsFromRequests(
  requests: readonly DashboardScheduledAutomationRequest[],
): Array<{ kind: string; count: number }> {
  const counts = new Map<string, number>()
  for (const request of requests) {
    const kind = request.payload_kind?.trim() || 'payload_kind 없음'
    counts.set(kind, (counts.get(kind) ?? 0) + 1)
  }
  return [...counts.entries()]
    .map(([kind, count]) => ({ kind, count }))
    .sort((a, b) => b.count - a.count || a.kind.localeCompare(b.kind))
}

interface PayloadSupportSummary {
  unsupportedCount: number
  unknownCount: number
  unsupportedKinds: Array<{ kind: string; count: number }>
  unsupportedRequests: DashboardScheduledAutomationRequest[]
  unknownRequests: DashboardScheduledAutomationRequest[]
}

function payloadSupportSummary(automation: DashboardScheduledAutomation): PayloadSupportSummary {
  const requests = automation.requests ?? []
  const unsupportedRequests = requests.filter(isUnsupportedPayloadRequest)
  const unknownRequests = requests.filter(isUnknownPayloadRequest)
  const unsupportedCount = Math.max(
    automation.payload_support?.unsupported_request_count
      ?? automation.derived_counts?.unsupported_payload_kind
      ?? 0,
    unsupportedRequests.length,
  )
  const unknownCount = Math.max(
    automation.payload_support?.unknown_request_count
      ?? automation.derived_counts?.unknown_payload_kind
      ?? 0,
    unknownRequests.length,
  )
  const projectedKinds = automation.payload_support?.unsupported_kinds ?? []
  return {
    unsupportedCount,
    unknownCount,
    unsupportedKinds: projectedKinds.length > 0 ? projectedKinds : kindCountsFromRequests(unsupportedRequests),
    unsupportedRequests,
    unknownRequests,
  }
}

function SchPayloadSupportChip({
  support,
}: {
  support: PayloadSupportState
}) {
  return html`
    <span
      class=${`sch-payload-support ${payloadSupportToneClass(support)}`}
      data-payload-support=${support}
    >
      ${payloadSupportLabel(support)}
    </span>
  `
}

function SchPayloadSupportBanner({
  summary,
  onOpen,
}: {
  summary: PayloadSupportSummary
  onOpen: (scheduleId: string) => void
}) {
  if (summary.unsupportedCount === 0 && summary.unknownCount === 0) return null
  const affectedRows = [...summary.unsupportedRequests, ...summary.unknownRequests].slice(0, 6)
  const hasUnsupported = summary.unsupportedCount > 0
  return html`
    <section
      class=${`sch-banner payload ${hasUnsupported ? 'bad' : 'warn'}`}
      data-testid="schedule-payload-support-alert"
    >
      <span class="sch-banner-ico">!</span>
      <div class="sch-banner-txt">
        <div>
          <b>payload support</b>
          ${hasUnsupported
            ? html`<span class="mono"> ${summary.unsupportedCount.toLocaleString()} unsupported</span>`
            : null}
          ${summary.unknownCount > 0
            ? html`<span class="mono"> ${summary.unknownCount.toLocaleString()} unknown</span>`
            : null}
        </div>
        <div class="sch-banner-sub">
          scheduler projection이 실행 불가 또는 확인 필요로 표시한 payload입니다.
        </div>
        ${summary.unsupportedKinds.length > 0
          ? html`
              <div class="sch-payload-kinds" aria-label="Unsupported payload kinds">
                ${summary.unsupportedKinds.map(kind => html`
                  <span class="sch-payload-kind">
                    <span class="mono">${kind.count.toLocaleString()}</span>
                    <span class="mono">${kind.kind}</span>
                  </span>
                `)}
              </div>
            `
          : null}
        ${affectedRows.length > 0
          ? html`
              <div class="sch-payload-rows" aria-label="Affected schedule requests">
                ${affectedRows.map(request => html`
                  <button
                    type="button"
                    class="sch-payload-row mono"
                    data-schedule-payload-support-row=${request.schedule_id}
                    onClick=${() => { onOpen(request.schedule_id) }}
                  >
                    ${request.schedule_id}
                  </button>
                `)}
              </div>
            `
          : null}
      </div>
    </section>
  `
}

type LiveSupportedEvidenceStatus =
  DashboardScheduledAutomationLiveSupportedNonTerminalEvidence['projection_status']

function liveSupportedEvidenceLabel(status: LiveSupportedEvidenceStatus): string {
  switch (status) {
    case 'matched_supported_non_terminal':
      return 'matched supported non-terminal'
    case 'no_supported_payload_rows':
      return 'no supported payload rows'
    case 'no_supported_non_terminal':
      return 'no supported non-terminal'
    default:
      return assertNever(status)
  }
}

function liveSupportedEvidenceBannerClass(status: LiveSupportedEvidenceStatus): string {
  switch (status) {
    case 'matched_supported_non_terminal':
      return 'approve'
    case 'no_supported_payload_rows':
      return 'payload bad'
    case 'no_supported_non_terminal':
      return 'payload warn'
    default:
      return assertNever(status)
  }
}

type LiveSupportedMatchedRowIntegrity =
  | { status: 'not_applicable' }
  | { status: 'matched_rows_verified'; matchedCount: number }
  | {
      status: 'matched_row_mismatch'
      mismatches: Array<{ scheduleId: string; reason: string }>
    }

function liveSupportedReadinessIsTerminalOrExpired(readiness: string | null | undefined): boolean {
  return readiness === 'terminal' || readiness === 'expired'
}

function liveSupportedMatchedRowIntegrity(
  evidence: DashboardScheduledAutomationLiveSupportedNonTerminalEvidence,
  requests: DashboardScheduledAutomationRequest[],
): LiveSupportedMatchedRowIntegrity {
  if (evidence.projection_status !== 'matched_supported_non_terminal') {
    return { status: 'not_applicable' }
  }

  const rowByScheduleId = new Map(requests.map(request => [request.schedule_id, request]))
  const matchedIds = evidence.matched_schedule_ids ?? []
  const mismatches =
    matchedIds.length === 0
      ? [{ scheduleId: '(none)', reason: 'missing_matched_schedule_ids' }]
      : matchedIds.flatMap(scheduleId => {
          const row = rowByScheduleId.get(scheduleId)
          if (!row) {
            return [{ scheduleId, reason: 'missing_request_row' }]
          }
          if (row.payload_support !== 'supported') {
            return [{ scheduleId, reason: 'payload_support_not_supported' }]
          }
          if (liveSupportedReadinessIsTerminalOrExpired(row.execution_readiness)) {
            return [{ scheduleId, reason: 'execution_readiness_terminal_or_expired' }]
          }
          return []
        })

  if (mismatches.length > 0) {
    return { status: 'matched_row_mismatch', mismatches }
  }
  return { status: 'matched_rows_verified', matchedCount: matchedIds.length }
}

function SchLiveSupportedEvidence({
  automation,
  evidence,
  onOpen,
}: {
  automation: DashboardScheduledAutomation
  evidence: DashboardScheduledAutomationLiveSupportedNonTerminalEvidence | null | undefined
  onOpen: (scheduleId: string) => void
}) {
  if (!evidence) {
    const requestCount = automation.request_count ?? automation.requests?.length ?? 0
    return html`
      <section
        class="sch-banner payload warn"
        data-schedule-live-supported-evidence="projection_contract_missing"
        data-schedule-live-supported-count="0"
        data-schedule-live-supported-source=${automation.source ?? 'dashboard_response'}
        data-schedule-live-supported-schema="missing"
      >
        <span class="sch-banner-ico">!</span>
        <div class="sch-banner-txt">
          <div>
            <b>live supported scheduler evidence</b>
            <span class="mono"> projection contract missing</span>
          </div>
          <div class="sch-banner-sub">
            <span class="mono">live_supported_non_terminal_evidence</span>
            was absent from the dashboard response; production-base
            <span class="mono">matched_supported_non_terminal</span> is unproven.
          </div>
          <div class="sch-evidence-counts" aria-label="Live supported scheduler contract gap counts">
            <span class="sch-evidence-count">
              <span>requests</span>
              <span class="mono">${requestCount.toLocaleString()}</span>
            </span>
            <span class="sch-evidence-count">
              <span>contract</span>
              <span class="mono">missing</span>
            </span>
          </div>
        </div>
      </section>
    `
  }
  const matchedIds = evidence.matched_schedule_ids ?? []
  const status = evidence.projection_status
  const rowIntegrity = liveSupportedMatchedRowIntegrity(evidence, automation.requests ?? [])
  return html`
    <section
      class=${`sch-banner ${liveSupportedEvidenceBannerClass(status)}`}
      data-schedule-live-supported-evidence=${status}
      data-schedule-live-supported-count=${evidence.supported_live_count ?? 0}
      data-schedule-live-supported-source=${evidence.source ?? ''}
    >
      <span class="sch-banner-ico">${status === 'matched_supported_non_terminal' ? '✓' : '!'}</span>
      <div class="sch-banner-txt">
        <div>
          <b>live supported scheduler evidence</b>
          <span class="mono"> ${liveSupportedEvidenceLabel(status)}</span>
        </div>
        <div class="sch-banner-sub">
          <span class="mono">${evidence.criteria ?? 'payload_support=supported && non-terminal'}</span>
        </div>
        <div class="sch-evidence-counts" aria-label="Live supported scheduler counts">
          <span class="sch-evidence-count">
            <span>requests</span>
            <span class="mono">${(evidence.request_count ?? 0).toLocaleString()}</span>
          </span>
          <span class="sch-evidence-count">
            <span>supported</span>
            <span class="mono">${(evidence.supported_request_count ?? 0).toLocaleString()}</span>
          </span>
          <span class="sch-evidence-count">
            <span>live</span>
            <span class="mono">${(evidence.supported_live_count ?? 0).toLocaleString()}</span>
          </span>
          <span class="sch-evidence-count">
            <span>terminal/expired</span>
            <span class="mono">${(evidence.terminal_or_expired_count ?? 0).toLocaleString()}</span>
          </span>
          <span class="sch-evidence-count">
            <span>unsupported/unknown</span>
            <span class="mono">${((evidence.unsupported_request_count ?? 0) + (evidence.unknown_request_count ?? 0)).toLocaleString()}</span>
          </span>
        </div>
        ${evidence.reason
          ? html`<div class="sch-banner-sub">${evidence.reason}</div>`
          : null}
        ${rowIntegrity.status === 'matched_rows_verified'
          ? html`
              <div
                class="sch-banner-sub"
                data-schedule-live-supported-row-integrity="matched_rows_verified"
                data-schedule-live-supported-row-integrity-count=${rowIntegrity.matchedCount}
              >
                matched schedule rows satisfy endpoint criteria in this response
              </div>
            `
          : rowIntegrity.status === 'matched_row_mismatch'
            ? html`
                <div
                  class="sch-banner-sub"
                  data-schedule-live-supported-row-integrity="matched_row_mismatch"
                  data-schedule-live-supported-row-integrity-count=${rowIntegrity.mismatches.length}
                >
                  matched row mismatch:
                  <span class="mono">
                    ${rowIntegrity.mismatches.map(item => `${item.scheduleId}:${item.reason}`).join(', ')}
                  </span>
                </div>
              `
            : null}
        ${matchedIds.length > 0
          ? html`
              <div class="sch-payload-rows" aria-label="Live supported schedule ids">
                ${matchedIds.map(scheduleId => html`
                  <button
                    type="button"
                    class="sch-payload-row mono"
                    data-schedule-live-supported-open=${scheduleId}
                    onClick=${() => { onOpen(scheduleId) }}
                  >${scheduleId}</button>
                `)}
              </div>
            `
          : null}
      </div>
    </section>
  `
}

// Card rail tone class. SCHED_STATUS specs only ever yield warn/info/ok/bad/dim
// for statuses; .sch-card.st-volt is not defined, so clamp anything else to dim.
const CARD_RAIL_TONES: ReadonlySet<string> = new Set(['ok', 'warn', 'bad', 'info', 'dim'])
function cardRailTone(cls: string): string {
  return CARD_RAIL_TONES.has(cls) ? cls : 'dim'
}

// Prototype filter tabs (audit P0 #3): 5 tabs, prototype labels/ordering.
type SchTabKey = 'pending' | 'scheduled' | 'active' | 'done' | 'all'
type SchCadenceKey = 'oneshot' | 'interval' | 'daily' | 'cron' | 'unknown'
interface SchTabDef {
  readonly key: SchTabKey
  readonly label: string
  // Effective-status values (live, normalized) this tab includes; null = all.
  readonly statuses: readonly string[] | null
}
interface SchCadenceDef {
  readonly key: SchCadenceKey
  readonly label: string
  readonly shortLabel: string
  readonly glyph: string
  readonly cls: string
}
const SCH_TERMINAL_STATUSES = ['succeeded', 'failed', 'rejected', 'cancelled', 'canceled', 'expired'] as const
const SCH_TABS: readonly SchTabDef[] = [
  { key: 'pending', label: '승인 대기', statuses: ['pending_approval', 'awaiting_approval', 'blocked_approval'] },
  { key: 'scheduled', label: '예약됨', statuses: ['scheduled'] },
  { key: 'active', label: 'due · 실행', statuses: ['due', 'due_pending_refresh', 'running'] },
  { key: 'done', label: '완료 · 종료', statuses: SCH_TERMINAL_STATUSES },
  { key: 'all', label: '전체', statuses: null },
]
const SCH_TERMINAL_STATUS_SET: ReadonlySet<string> = new Set(SCH_TERMINAL_STATUSES)
const SCH_CADENCES: readonly SchCadenceDef[] = [
  { key: 'daily', label: '정기 · 매일', shortLabel: '정기', glyph: '◈', cls: 'ok' },
  { key: 'interval', label: '폴링 · 주기', shortLabel: '폴링', glyph: '↻', cls: 'volt' },
  { key: 'oneshot', label: '1회 · ad-hoc', shortLabel: '1회', glyph: '•', cls: 'info' },
  { key: 'cron', label: 'cron', shortLabel: 'cron', glyph: '⌁', cls: 'warn' },
  { key: 'unknown', label: 'unknown', shortLabel: 'unknown', glyph: '?', cls: 'dim' },
]

function schTabMatches(tab: SchTabDef, request: DashboardScheduledAutomationRequest): boolean {
  if (tab.statuses === null) return true
  return tab.statuses.includes(normalized(effectiveStatus(request)))
}

function recurrenceKind(request: DashboardScheduledAutomationRequest): string | null {
  const kind = request.recurrence?.kind ?? request.recurrence_kind ?? null
  const value = normalized(kind)
  return value === '' ? null : value
}

function scheduleCadence(request: DashboardScheduledAutomationRequest): SchCadenceKey {
  switch (recurrenceKind(request)) {
    case 'one_shot':
    case 'oneshot':
      return 'oneshot'
    case 'interval':
      return 'interval'
    case 'daily':
      return 'daily'
    case 'cron':
      return 'cron'
    case null:
    default:
      return 'unknown'
  }
}

function schCadenceDef(key: SchCadenceKey): SchCadenceDef {
  return SCH_CADENCES.find(definition => definition.key === key) ?? SCH_CADENCES[SCH_CADENCES.length - 1]!
}

function SchCadenceTag({ request }: { request: DashboardScheduledAutomationRequest }) {
  const cadence = scheduleCadence(request)
  const definition = schCadenceDef(cadence)
  return html`
    <span
      class=${`sch-cad ${definition.cls}`}
      data-schedule-cadence-card=${request.schedule_id}
      data-schedule-cadence=${cadence}
      title=${`recurrence.kind = ${recurrenceKind(request) ?? 'missing'}`}
    >${definition.glyph} ${definition.shortLabel}</span>
  `
}

function SchCadenceSummary({
  requests,
  active,
  onSelect,
}: {
  requests: readonly DashboardScheduledAutomationRequest[]
  active: SchCadenceKey | null
  onSelect: (key: SchCadenceKey | null) => void
}) {
  const counts = new Map<SchCadenceKey, number>(SCH_CADENCES.map(definition => [definition.key, 0]))
  for (const request of requests) {
    const cadence = scheduleCadence(request)
    counts.set(cadence, (counts.get(cadence) ?? 0) + 1)
  }
  return html`
    <div
      class="sch-cadsum"
      data-schedule-cadence-summary
      data-schedule-cadence-active=${active ?? 'all'}
    >
      ${SCH_CADENCES.map(definition => {
        const selected = active === definition.key
        const count = counts.get(definition.key) ?? 0
        return html`
          <button
            type="button"
            class=${`sch-cadsum-i ${definition.cls} ${selected ? 'on' : ''} ${active && !selected ? 'off' : ''}`}
            aria-pressed=${selected ? 'true' : 'false'}
            data-schedule-cadence-filter=${definition.key}
            data-schedule-cadence-count=${count}
            onClick=${() => { onSelect(selected ? null : definition.key) }}
          >
            <span class="sch-cadsum-gl">${definition.glyph}</span>
            <span class="sch-cadsum-n mono">${count.toLocaleString()}</span>
            <span class="sch-cadsum-l">${definition.label}</span>
          </button>
        `
      })}
    </div>
  `
}

function isTerminalSchedule(request: DashboardScheduledAutomationRequest): boolean {
  return SCH_TERMINAL_STATUS_SET.has(normalized(effectiveStatus(request)))
}

function SchPollingStrip({
  requests,
  onOpen,
}: {
  requests: readonly DashboardScheduledAutomationRequest[]
  onOpen: (request: DashboardScheduledAutomationRequest) => void
}) {
  const polls = requests.filter(request => scheduleCadence(request) === 'interval' && !isTerminalSchedule(request))
  return html`
    <section
      class="sch-poll"
      data-schedule-polling-strip
      data-schedule-polling-count=${polls.length}
    >
      <div class="sch-poll-h">
        <span class="sch-cad volt">↻ 상시 폴링</span>
        <span class="sch-poll-sub">recurrence.kind=interval · terminal 상태 제외</span>
      </div>
      ${polls.length === 0
        ? html`<div class="sch-day-empty mono">활성 폴링 없음</div>`
        : html`
            <div class="sch-poll-list">
              ${polls.map(request => {
                const payload = schedPayloadSpec(request.payload_kind)
                const status = statusSpecForLive(effectiveStatus(request))
                const dueIso = request.next_due_at_iso ?? request.due_at_iso ?? null
                return html`
                  <button
                    type="button"
                    class=${`sch-poll-card st-${cardRailTone(status.cls)}`}
                    data-schedule-polling-card=${request.schedule_id}
                    onClick=${() => { onOpen(request) }}
                  >
                    <div class="sch-poll-top">
                      <span class="sch-poll-int mono">↻ ${recurrenceText(request)}</span>
                      <${SchStatusPill} status=${effectiveStatus(request)} />
                    </div>
                    <div class="sch-poll-title">${payload.glyph} ${request.payload_summary?.trim() || request.payload_kind || request.schedule_id}</div>
                    <div class="sch-poll-foot">
                      <${SchKeeperMeta} actor=${request.scheduled_by} />
                      <${SchRiskChip} risk=${request.risk_class} />
                      <span class="sch-poll-next mono" title="next_due_at">${formatDateTimeKo(dueIso)}</span>
                    </div>
                  </button>
                `
              })}
            </div>
          `}
    </section>
  `
}

function recurrenceText(request: DashboardScheduledAutomationRequest): string {
  return recurrenceLabel(request)
}

/** `.sch-pill` status chip with glyph (audit P0 #2). */
function SchStatusPill({ status }: { status: string | null | undefined }) {
  const spec = statusSpecForLive(status)
  return html`<span class=${`sch-pill ${spec.cls}`}>${spec.glyph} ${spec.lbl}</span>`
}

/** `.sch-risk` chip (audit P0 #1 head row). */
function SchRiskChip({ risk }: { risk: string | null | undefined }) {
  const spec = riskSpecForLive(risk)
  return html`<span class=${`sch-risk ${spec.cls}`} title=${`risk_class = ${risk ?? '-'}`}>${spec.lbl}</span>`
}

/** Keeper attribution on `.sch-meta` — sigil + id (audit P0/P1 #8). No live
 *  keeper-chat nav callback is wired into the schedule route, so the id is
 *  shown as text rather than a fake nav button. */
function SchKeeperMeta({ actor }: { actor: DashboardScheduledAutomationActor | null | undefined }) {
  const id = actor?.id?.trim()
  if (!id) {
    return html`<span class="sch-by"><span class="sch-actor-kind mono" data-stub="no scheduled_by actor">예약</span></span>`
  }
  return html`
    <span class="sch-by">
      <${SigilBadge} slot=${kSlot(id)} sigil=${kSigil(id)} size=${22} title=${id} />
      <span class="sch-klink" title=${actorLabel(actor)}>${id}</span>
      <span class="sch-actor-kind mono">예약</span>
    </span>
  `
}

function SchCard({
  request,
  onOpen,
}: {
  request: DashboardScheduledAutomationRequest
  onOpen: (request: DashboardScheduledAutomationRequest) => void
}) {
  const status = effectiveStatus(request)
  const spec = statusSpecForLive(status)
  const payload = schedPayloadSpec(request.payload_kind)
  const dueIso = request.next_due_at_iso ?? request.due_at_iso ?? null
  const summary = request.payload_summary?.trim() || null
  return html`
    <article class=${`sch-card st-${cardRailTone(spec.cls)}`} data-schedule-id=${request.schedule_id}>
      <div class="sch-card-rail"></div>
      <div class="sch-card-main">
        <button
          type="button"
          class="sch-card-head"
          data-schedule-detail=${request.schedule_id}
          onClick=${() => { onOpen(request) }}
        >
          <span class="sch-kind">${payload.glyph} ${payload.lbl}</span>
          <span class="sch-id mono">${request.schedule_id}</span>
          <${SchCadenceTag} request=${request} />
          <${SchRiskChip} risk=${request.risk_class} />
          ${request.payload_support && request.payload_support !== 'supported'
            ? html`<${SchPayloadSupportChip} support=${request.payload_support} />`
            : null}
          <span class="sch-rec mono" title="recurrence">↻ ${recurrenceText(request)}</span>
          <span class="sch-head-sp"></span>
          <${SchStatusPill} status=${status} />
        </button>
        ${summary
          ? html`<button type="button" class="sch-summary" onClick=${() => { onOpen(request) }}>${summary}</button>`
          : html`<button type="button" class="sch-summary" data-stub="no payload_summary" onClick=${() => { onOpen(request) }}>요약 없음 · 상세 보기</button>`}
        <div class="sch-meta">
          <${SchKeeperMeta} actor=${request.scheduled_by} />
          <span class="sch-due" title="due_at"><span class="sub-k">due</span> ${formatDateTimeKo(dueIso)}</span>
          ${request.requires_separate_human_grant
            ? html`<span class="sch-need mono" title="별도 사람(operator) 승인 필요">⊙ 승인 필요</span>`
            : null}
        </div>
        <${WakeEvidenceSummary} request=${request} />
      </div>
    </article>
  `
}

/** Detail overlay `.turn-overlay > .turn-drawer.sch-drawer` (audit P0 #4). */
export function SchDetail({
  request,
  onClose,
  onResolved,
}: {
  request: DashboardScheduledAutomationRequest
  onClose: () => void
  onResolved?: () => Promise<void> | void
}) {
  // External-system sync: Escape-to-close keyboard listener (legitimate effect).
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.stopPropagation()
        onClose()
      }
    }
    window.addEventListener('keydown', onKey)
    return () => { window.removeEventListener('keydown', onKey) }
  }, [onClose])

  const status = effectiveStatus(request)
  const payload = schedPayloadSpec(request.payload_kind)
  const dueIso = request.next_due_at_iso ?? request.due_at_iso ?? null
  const requestedAtIso = request.requested_at_iso ?? null
  const expiresAtIso = request.expires_at_iso ?? null
  const execution = request.last_execution
  const summary = request.payload_summary?.trim() || null
  const approval = request.approval_policy ?? (request.approval_required ? 'required' : 'not_required')
  // Live payload has no `body` — only kind/digest/target/summary. Render what is
  // available in the envelope and mark the absent body honestly (audit #12).
  const payloadEnvelope = JSON.stringify(
    {
      kind: request.payload_kind ?? null,
      support: request.payload_support ?? null,
      digest: request.payload_digest ?? null,
      target: request.payload_target ?? null,
      summary: summary,
    },
    null,
    2,
  )

  return html`
    <div class="turn-overlay" onClick=${onClose}>
      <div
        class="turn-drawer sch-drawer"
        data-schedule-detail-panel=${request.schedule_id}
        onClick=${(event: MouseEvent) => { event.stopPropagation() }}
      >
        <div class="turn-hd">
          <h3>예약 상세</h3>
          <span class="tid">${request.schedule_id}</span>
          <span class="sch-hd-sp" style=${{ marginLeft: 'auto' }}></span>
          <${SchStatusPill} status=${status} />
          <button type="button" class="turn-close" onClick=${onClose} title="닫기 (Esc)">✕</button>
        </div>
        <div class="turn-body">
          <div class="turn-sec">
            <h4>${payload.glyph} ${payload.lbl}</h4>
            ${summary
              ? html`<p class="sch-d-summary">${summary}</p>`
              : html`<p class="sch-d-summary" data-stub="no payload_summary">요약 없음</p>`}
            <div class="sch-badges">
              <${SchRiskChip} risk=${request.risk_class} />
              <span class="sch-rec mono">↻ ${recurrenceText(request)}</span>
              <span class="sch-src mono">${enumLabel(request.source)}</span>
            </div>
          </div>

          <div class="turn-sec">
            <h4>주체 · 직무분리</h4>
            <div class="sch-kvs">
              <div class="sch-kv"><span class="k">requested_by</span><span class="v mono">${actorLabel(request.requested_by)}</span></div>
              <div class="sch-kv"><span class="k">scheduled_by</span><span class="v mono">${actorLabel(request.scheduled_by)}</span></div>
              <div class="sch-kv"><span class="k">approval_required</span><span class="v mono">${String(request.approval_required)}</span></div>
            </div>
            ${request.scheduled_by?.id
              ? html`<div class="sch-sod">승인자(operator)는 요청자·예약자와 달라야 실행 grant가 발급됩니다 — 예약 주체는 keeper(<b>${request.scheduled_by.id}</b>), 승인 주체는 operator.</div>`
              : html`<div class="sch-sod">승인자(operator)는 요청자·예약자와 달라야 실행 grant가 발급됩니다.</div>`}
          </div>

          <div class="turn-sec">
            <h4>타이밍</h4>
            <div class="sch-kvs">
              <div class="sch-kv"><span class="k">요청</span><span class="v mono">${formatDateTimeKo(requestedAtIso)}</span></div>
              <div class="sch-kv"><span class="k">due</span><span class="v mono">${formatDateTimeKo(dueIso)}</span></div>
              <div class="sch-kv"><span class="k">만료</span><span class="v mono">${formatDateTimeKo(expiresAtIso)}</span></div>
              <div class="sch-kv"><span class="k">recurrence</span><span class="v mono">${recurrenceText(request)}</span></div>
            </div>
          </div>

          <div class="turn-sec">
            <h4>승인 정책</h4>
            <div class="sch-kvs">
              <div class="sch-kv"><span class="k">approval_policy</span><span class="v mono">${enumLabel(approval)}</span></div>
              <div class="sch-kv"><span class="k">운영자 조치</span><span class="v mono">${enumLabel(request.operator_action)}</span></div>
              <div class="sch-kv"><span class="k">실행 준비</span><span class="v mono">${enumLabel(request.execution_readiness)}</span></div>
            </div>
          </div>

          <div class="turn-sec">
            <h4>payload 봉투</h4>
            <div class="sch-kvs sch-payload-kvs">
              <div class="sch-kv">
                <span class="k">payload_support</span>
                <span class="v mono">
                  ${request.payload_support
                    ? html`<${SchPayloadSupportChip} support=${request.payload_support} />`
                    : html`<span data-stub="payload_support absent">projection field 없음</span>`}
                </span>
              </div>
              <div class="sch-kv">
                <span class="k">payload_kind</span>
                <span class="v mono">${request.payload_kind ?? '-'}</span>
              </div>
            </div>
            <pre class="turn-pre" data-stub="payload body not in projection">${payloadEnvelope}</pre>
          </div>

          <div class="turn-sec">
            <h4>최근 실행 기록</h4>
            <${SchExecution}
              execution=${execution}
              dispatchReceipt=${request.dispatch_receipt ?? null}
              queueEvidence=${request.keeper_queue_evidence ?? null}
              reactionEvidence=${request.keeper_reaction_evidence ?? null}
            />
          </div>

          <${SchDetailActions} request=${request} onResolved=${onResolved} onClose=${onClose} />
        </div>
      </div>
    </div>
  `
}

function SchExecution({
  execution,
  dispatchReceipt,
  queueEvidence,
  reactionEvidence,
}: {
  execution: DashboardScheduledAutomationExecution | null | undefined
  dispatchReceipt: DashboardScheduledAutomationDispatchReceipt | null | undefined
  queueEvidence: DashboardScheduledAutomationKeeperQueueEvidence | null | undefined
  reactionEvidence: DashboardScheduledAutomationKeeperReactionEvidence | null | undefined
}) {
  if (!execution) {
    return html`<div class="sch-kvs"><div class="sch-kv"><span class="k">status</span><span class="v mono" data-stub="no last_execution">실행 기록 없음</span></div></div>`
  }
  const detailRows = executionDetailRows(execution.detail)
  return html`
    <div class="sch-kvs">
      <div class="sch-kv"><span class="k">status</span><span class="v mono">${enumLabel(execution.status)}</span></div>
      <div class="sch-kv"><span class="k">시작</span><span class="v mono">${formatDateTimeKo(execution.started_at_iso ?? null)}</span></div>
      <div class="sch-kv"><span class="k">종료</span><span class="v mono">${formatDateTimeKo(execution.finished_at_iso ?? null)}</span></div>
      ${detailRows.map(row => html`
        <div class="sch-kv" data-execution-detail-row=${row.label}><span class="k">${row.label}</span><span class="v mono">${row.value}</span></div>
      `)}
    </div>
    <${DispatchReceiptBlock} receipt=${dispatchReceipt} compact=${true} />
    <${QueueEvidenceBlock} evidence=${queueEvidence} compact=${true} />
    <${ReactionEvidenceBlock} evidence=${reactionEvidence} compact=${true} />
    ${execution.error ? html`<div class="sch-exec bad">${execution.error}</div>` : null}
  `
}

/** Detail-overlay actions. Wired to the real approve/reject API only — the
 *  prototype's cancel action has no live endpoint, so it is omitted. Buttons
 *  render only when an `onResolved` refresh callback exists (mirrors the
 *  diagnostics ApprovalCell contract: no callback → read-only). */
function SchDetailActions({
  request,
  onResolved,
  onClose,
}: {
  request: DashboardScheduledAutomationRequest
  onResolved?: () => Promise<void> | void
  onClose: () => void
}) {
  const [pendingDecision, setPendingDecision] = useState<DashboardScheduleDecision | null>(null)
  if (!onResolved || !isApprovalActionable(request)) return null
  const busy = pendingDecision !== null

  async function decide(decision: DashboardScheduleDecision) {
    setPendingDecision(decision)
    try {
      await resolveScheduleApproval(
        request.schedule_id,
        decision,
        decision === 'reject' ? 'rejected from dashboard' : undefined,
      )
      showToast(`${request.schedule_id} ${decision === 'approve' ? 'approved' : 'rejected'}`, 'success')
      await onResolved?.()
      onClose()
    } catch (err) {
      showToast(err instanceof Error ? err.message : 'schedule approval failed', 'error')
    } finally {
      setPendingDecision(null)
    }
  }

  return html`
    <div class="turn-sec sch-detail-actions">
      <button
        type="button"
        class="sch-act approve"
        data-schedule-mutation="approve"
        data-testid=${`schedule-approve-${request.schedule_id}`}
        disabled=${busy}
        aria-busy=${pendingDecision === 'approve' ? 'true' : 'false'}
        onClick=${() => { void decide('approve') }}
      >승인 — grant 발급</button>
      <button
        type="button"
        class="sch-act deny"
        data-schedule-mutation="reject"
        data-testid=${`schedule-reject-${request.schedule_id}`}
        disabled=${busy}
        aria-busy=${pendingDecision === 'reject' ? 'true' : 'false'}
        onClick=${() => { void decide('reject') }}
      >거부</button>
    </div>
  `
}

function SchedulePrototypeSurface({
  automation,
  onResolved,
  selectedScheduleId: controlledSelectedId,
  onSelectSchedule,
}: {
  automation: DashboardScheduledAutomation
  onResolved?: () => Promise<void> | void
  // Optional controlled selection so a sibling (the operations aside) can drive
  // the same detail overlay. Uncontrolled (internal state) when omitted.
  selectedScheduleId?: string | null
  onSelectSchedule?: (scheduleId: string | null) => void
}) {
  const [tab, setTab] = useState<SchTabKey>('pending')
  const [cadenceFilter, setCadenceFilter] = useState<SchCadenceKey | null>(null)
  const [internalSelectedId, setInternalSelectedId] = useState<string | null>(null)
  const selectedScheduleId = controlledSelectedId !== undefined ? controlledSelectedId : internalSelectedId
  const setSelectedScheduleId = onSelectSchedule ?? setInternalSelectedId

  const rows = automation.requests ?? []
  const tabDef = SCH_TABS.find(definition => definition.key === tab) ?? SCH_TABS[0]!
  const cadenceRows = cadenceFilter
    ? rows.filter(request => scheduleCadence(request) === cadenceFilter)
    : rows
  const filtered = cadenceRows.filter(request => schTabMatches(tabDef, request))
  // Durable runner signals (real source). Keep one feed (audit P0/P1 #9).
  const durableSignalContract = durableWakeSignalContract(automation)
  const durableSignals = durableSignalContract.visibleSignals
  const selected = selectedScheduleId
    ? rows.find(request => request.schedule_id === selectedScheduleId) ?? null
    : null
  const payloadSummary = payloadSupportSummary(automation)

  return html`
    <div class="sch-panel">
      <${SchPayloadSupportBanner}
        summary=${payloadSummary}
        onOpen=${setSelectedScheduleId}
      />
      <${SchLiveSupportedEvidence}
        automation=${automation}
        evidence=${automation.live_supported_non_terminal_evidence ?? null}
        onOpen=${setSelectedScheduleId}
      />

      <${SchCadenceSummary}
        requests=${rows}
        active=${cadenceFilter}
        onSelect=${setCadenceFilter}
      />

      ${cadenceFilter === null || cadenceFilter === 'interval'
        ? html`
            <${SchPollingStrip}
              requests=${rows}
              onOpen=${(next: DashboardScheduledAutomationRequest) => { setSelectedScheduleId(next.schedule_id) }}
            />
          `
        : null}

      <div class="sch-tabs" role="tablist" aria-label="예약 필터">
        ${SCH_TABS.map(definition => {
          const count = definition.statuses === null
            ? cadenceRows.length
            : cadenceRows.filter(request => schTabMatches(definition, request)).length
          const active = definition.key === tab
          return html`
            <button
              type="button"
              role="tab"
              aria-selected=${active ? 'true' : 'false'}
              class=${`sch-tab ${active ? 'on' : ''}`}
              data-schedule-filter=${definition.key}
              onClick=${() => { setTab(definition.key) }}
            >${definition.label}<span class="sch-tab-n mono">${count.toLocaleString()}</span></button>
          `
        })}
      </div>

      ${filtered.length === 0
        ? html`<div class="sch-empty">이 필터에 해당하는 예약이 없습니다.</div>`
        : html`
            <div class="sch-list">
              ${filtered.map(request => html`
                <${SchCard}
                  request=${request}
                  onOpen=${(next: DashboardScheduledAutomationRequest) => { setSelectedScheduleId(next.schedule_id) }}
                />
              `)}
            </div>
          `}

      <section
        class="sch-signals"
        data-schedule-durable-signal-contract="payload_support"
        data-schedule-durable-signal-raw=${durableSignalContract.rawCount}
        data-schedule-durable-signal-visible=${durableSignalContract.visibleCount}
        data-schedule-durable-signal-hidden=${durableSignalContract.hiddenByPayloadSupport}
      >
        <div class="ov-card-h"><h3>wake signal 피드 · schedule_runner.tick</h3></div>
        ${durableSignals.length === 0
          ? html`
              <div class="sch-empty" data-stub="no durable runner signals">
                ${durableSignalContract.hiddenByPayloadSupport > 0
                  ? `payload support로 ${durableSignalContract.hiddenByPayloadSupport.toLocaleString()} durable wake signal 숨김`
                  : 'durable wake signal 없음'}
              </div>
            `
          : html`
              <div class="sch-sig-list">
                ${durableSignals.map(signal => {
                  const spec = statusSpecForLive(signal.kind)
                  return html`
                    <div class="sch-sig" data-schedule-signal-id=${signal.signal_id}>
                      <span class="sch-sig-at mono" data-schedule-signal-at=${signal.signal_id}>${compactTimeLabel(signal.emitted_at_iso ?? signal.due_at_iso ?? null)}</span>
                      <span class=${`sch-sig-kind ${spec.cls}`} data-schedule-signal-kind=${signal.kind}>${enumLabel(signal.kind || signal.event_type)}</span>
                      <button
                        type="button"
                        class="sch-sig-id mono"
                        data-schedule-signal-schedule=${signal.schedule_id}
                        onClick=${() => { setSelectedScheduleId(signal.schedule_id) }}
                      >${signal.schedule_id}</button>
                      <span class="sch-sig-risk mono" data-schedule-signal-risk=${signal.signal_id}>${enumLabel(signal.risk_class)}</span>
                    </div>
                  `
                })}
              </div>
            `}
      </section>

      ${selected
        ? html`<${SchDetail} request=${selected} onClose=${() => { setSelectedScheduleId(null) }} onResolved=${onResolved} />`
        : null}
    </div>
  `
}

// Aside triage buckets. Approval-needed statuses (pending family) surface under
// '해야 할 일 → 승인'; imminent due statuses under 'due'; terminal statuses feed
// the '최근 실행' recency list. Derived only from the projection — read-only.
const SCHEDULE_ASIDE_PENDING: ReadonlySet<string> = new Set([
  'pending', 'pending_approval', 'awaiting_approval', 'blocked_approval',
])
const SCHEDULE_ASIDE_DUE: ReadonlySet<string> = new Set(['due', 'due_pending_refresh'])
const SCHEDULE_ASIDE_TERMINAL: ReadonlySet<string> = new Set([
  'succeeded', 'failed', 'rejected', 'cancelled', 'canceled', 'expired',
])
const SCHEDULE_ASIDE_RECENT_MAX = 6

function scheduleAsideSummary(request: DashboardScheduledAutomationRequest): string {
  return request.payload_summary?.trim() || `${schedPayloadSpec(request.payload_kind).lbl} · 상세`
}

/** Right-column operations aside for the schedule surface (schedule.jsx SchAside):
 *  a read-only pulse (예약됨/due·실행/승인대기) + failed/pending/due/recent triage
 *  derived from the same scheduled-automation projection. A row click opens the
 *  shared detail overlay via `onOpen`; there are no mutation controls, so the
 *  surface stays read-only. */
export function ScheduleAside({
  requests,
  sum,
  onOpen,
}: {
  requests: readonly DashboardScheduledAutomationRequest[]
  sum: { readonly scheduled: number; readonly dueRunning: number; readonly pending: number; readonly total: number }
  onOpen: (scheduleId: string) => void
}) {
  const asideStatus = (request: DashboardScheduledAutomationRequest): string =>
    normalized(effectiveStatus(request))
  const payloadBlocked = requests.filter(payloadSupportBlocksWake)
  const failed = requests.filter(request => asideStatus(request) === 'failed' && !payloadSupportBlocksWake(request))
  const pending = requests.filter(request => SCHEDULE_ASIDE_PENDING.has(asideStatus(request)) && !payloadSupportBlocksWake(request))
  const due = requests.filter(request => SCHEDULE_ASIDE_DUE.has(asideStatus(request)) && !payloadSupportBlocksWake(request))
  const recent = requests
    .filter(request => SCHEDULE_ASIDE_TERMINAL.has(asideStatus(request)))
    .slice(0, SCHEDULE_ASIDE_RECENT_MAX)
  const needTotal = pending.length + due.length

  return html`
    <aside class="ov-aside" aria-label="예약 운영 상태" data-testid="schedule-aside">
      <section class="wka-sec">
        <div class="wka-h">지금 상황 <span class="n mono">${sum.total.toLocaleString()} 예약</span></div>
        <div class="wka-pulse">
          <span class="wka-pulse-i"><b class="mono">${sum.scheduled}</b> 예약됨</span>
          <span class="wka-pulse-i"><b class=${`mono ${sum.dueRunning > 0 ? 'volt' : ''}`}>${sum.dueRunning}</b> due·실행</span>
          <span class="wka-pulse-i"><b class=${`mono ${sum.pending > 0 ? 'warn' : ''}`}>${sum.pending}</b> 승인대기</span>
        </div>
        ${payloadBlocked.length === 0 && failed.length === 0
          ? html`<div class="wka-calm mono">실패한 실행 없음</div>`
          : html`
              <div class="wka-list">
                ${payloadBlocked.map(request => {
                  const support = request.payload_support === 'unknown' ? 'unknown' : 'unsupported'
                  const tone = support === 'unknown' ? 'warn' : 'bad'
                  return html`
                    <button
                      type="button"
                      class=${`wka-flag st-${tone}`}
                      data-schedule-aside-open=${request.schedule_id}
                      onClick=${() => { onOpen(request.schedule_id) }}
                    >
                      <span class=${`wka-flag-tag ${tone}`}>payload</span>
                      <span class="wka-flag-title">${scheduleAsideSummary(request)}</span>
                      <span class="wka-flag-reason mono">${support} · ${request.payload_kind ?? 'payload_kind 없음'}</span>
                    </button>
                  `
                })}
                ${failed.map(request => html`
                  <button
                    type="button"
                    class="wka-flag st-bad"
                    data-schedule-aside-open=${request.schedule_id}
                    onClick=${() => { onOpen(request.schedule_id) }}
                  >
                    <span class="wka-flag-tag bad">실패</span>
                    <span class="wka-flag-title">${scheduleAsideSummary(request)}</span>
                    ${request.last_execution?.error
                      ? html`<span class="wka-flag-reason">${request.last_execution.error}</span>`
                      : null}
                  </button>
                `)}
              </div>
            `}
      </section>

      <section class="wka-sec">
        <div class="wka-h">해야 할 일 <span class="n mono">${needTotal}</span></div>
        <div class="wka-list">
          ${pending.map(request => html`
            <button
              type="button"
              class="wka-todo approve"
              data-schedule-aside-open=${request.schedule_id}
              onClick=${() => { onOpen(request.schedule_id) }}
            >
              <span class="wka-todo-k">승인</span>
              <span class="wka-todo-t">${scheduleAsideSummary(request)}</span>
              <span class="wka-todo-m mono">${riskSpecForLive(request.risk_class).lbl} · ${formatDateTimeKo(request.next_due_at_iso ?? request.due_at_iso ?? null)}</span>
            </button>
          `)}
          ${due.map(request => html`
            <button
              type="button"
              class="wka-todo verify"
              data-schedule-aside-open=${request.schedule_id}
              onClick=${() => { onOpen(request.schedule_id) }}
            >
              <span class="wka-todo-k">due</span>
              <span class="wka-todo-t">${scheduleAsideSummary(request)}</span>
              <span class="wka-todo-m mono">${recurrenceText(request)} · 실행 대기</span>
            </button>
          `)}
          ${needTotal === 0 ? html`<div class="wka-calm mono">승인·실행 대기 없음</div>` : null}
        </div>
      </section>

      <section class="wka-sec">
        <div class="wka-h">최근 실행 <span class="n mono">${recent.length}</span></div>
        <div class="wka-list">
          ${recent.length === 0
            ? html`<div class="wka-calm mono">종료된 예약 없음</div>`
            : recent.map(request => {
                const spec = statusSpecForLive(effectiveStatus(request))
                return html`
                  <button
                    type="button"
                    class="wka-done"
                    data-schedule-aside-open=${request.schedule_id}
                    onClick=${() => { onOpen(request.schedule_id) }}
                  >
                    <span class=${`wka-done-mark ${spec.cls}`}>${spec.glyph}</span>
                    <span class="wka-done-t">${scheduleAsideSummary(request)}</span>
                    <span class="wka-done-ns mono">${spec.lbl}</span>
                  </button>
                `
              })}
        </div>
      </section>
    </aside>
  `
}

export function ScheduledAutomationPanel({
  automation,
  onResolved,
  variant = 'diagnostics',
  selectedScheduleId: controlledSelectedId,
  onSelectSchedule,
}: {
  automation?: DashboardScheduledAutomation | null
  onResolved?: () => Promise<void> | void
  variant?: 'diagnostics' | 'v2'
  // Forwarded to the v2 surface so the schedule aside can control the overlay.
  selectedScheduleId?: string | null
  onSelectSchedule?: (scheduleId: string | null) => void
}) {
  const [activeFilter, setActiveFilter] = useState<ScheduleFilterKey>('all')
  const [selectedScheduleId, setSelectedScheduleId] = useState<string | null>(null)

  if (!automation) {
    return html`
      <div class="text-xs text-[var(--color-fg-muted)]">
        예약 자동화 projection 없음
      </div>
    `
  }

  if (variant === 'v2') {
    return html`<${SchedulePrototypeSurface}
      automation=${automation}
      onResolved=${onResolved}
      selectedScheduleId=${controlledSelectedId}
      onSelectSchedule=${onSelectSchedule}
    />`
  }

  const nonzeroCounts = Object.entries(automation.counts ?? {})
    .filter(([, count]) => count > 0)
  const rows = automation.requests ?? []
  const wakeSignals = selectWakeSignals(automation)
  const filteredRows = rows.filter(request => filterMatches(activeFilter, request))
  const wakeRows = rows
    .filter(canProjectUpcomingWake)
    .sort((a, b) => dueTimestamp(a) - dueTimestamp(b))
  const durableSignalContract = durableWakeSignalContract(automation)
  const durableSignals = durableSignalContract.visibleSignals
  const rawDurableSignalCount = durableSignalContract.rawCount
  const hasDurableSignals = durableSignals.length > 0
  const selectedRequest =
    rows.find(request => request.schedule_id === selectedScheduleId)
    ?? filteredRows[0]
    ?? null
  const filterCounts = new Map(
    SCHEDULE_FILTERS.map(filter => [
      filter.key,
      rows.filter(request => filterMatches(filter.key, request)).length,
    ]),
  )
  const dueEffective = automation.derived_counts?.due_effective ?? 0
  const blockedApproval = automation.derived_counts?.blocked_approval ?? 0
  const dueExecutionReady = automation.derived_counts?.due_execution_ready ?? 0
  const expiredEffective = automation.derived_counts?.expired_effective ?? 0
  const unsupportedPayloads =
    automation.payload_support?.unsupported_request_count
      ?? automation.derived_counts?.unsupported_payload_kind
      ?? 0
  const unknownPayloads =
    automation.payload_support?.unknown_request_count
      ?? automation.derived_counts?.unknown_payload_kind
      ?? 0
  const unsupportedKinds = automation.payload_support?.unsupported_kinds ?? []

  return html`
    <div class="grid gap-4">
      <div class="flex flex-wrap items-center gap-x-4 gap-y-2 text-xs">
        <div class="flex items-center gap-2">
          <span class="text-[var(--color-fg-muted)]">FSM</span>
          <${StatusChip} tone=${automationTone(automation.fsm.state)} uppercase=${false}>
            ${enumLabel(automation.fsm.state)}
          <//>
        </div>
        <span class="text-[var(--color-fg-muted)]">
          활성 <span class="font-mono text-[var(--color-fg-secondary)]">${automation.fsm.active_count.toLocaleString()}</span>
        </span>
        <span class="text-[var(--color-fg-muted)]">
          종료 <span class="font-mono text-[var(--color-fg-secondary)]">${automation.fsm.terminal_count.toLocaleString()}</span>
        </span>
        <span class="text-[var(--color-fg-muted)]">
          유효 도래 <span class="font-mono text-[var(--color-fg-secondary)]">${dueEffective.toLocaleString()}</span>
        </span>
        <span class="text-[var(--color-fg-muted)]">
          승인 차단 <span class="font-mono text-[var(--color-fg-secondary)]">${blockedApproval.toLocaleString()}</span>
        </span>
        <span class="text-[var(--color-fg-muted)]">
          실행 준비 <span class="font-mono text-[var(--color-fg-secondary)]">${dueExecutionReady.toLocaleString()}</span>
        </span>
        <span class="text-[var(--color-fg-muted)]">
          만료 <span class="font-mono text-[var(--color-fg-secondary)]">${expiredEffective.toLocaleString()}</span>
        </span>
        <span class=${unsupportedPayloads > 0 ? 'text-[var(--color-danger-fg)]' : 'text-[var(--color-fg-muted)]'}>
          unsupported payload <span class="font-mono">${unsupportedPayloads.toLocaleString()}</span>
        </span>
        ${unknownPayloads > 0
          ? html`
              <span class="text-[var(--color-warning-fg)]">
                unknown payload <span class="font-mono">${unknownPayloads.toLocaleString()}</span>
              </span>
            `
          : null}
        <span class="text-[var(--color-fg-muted)]">
          다음 예정 <span class="font-mono text-[var(--color-fg-secondary)]">${formatDateTimeKo(automation.fsm.next_due_at ?? null)}</span>
        </span>
        <span class="text-3xs text-[var(--color-fg-disabled)]">
          출처 <span class="font-mono">${automation.source ?? 'schedule_store'}</span>
        </span>
      </div>

      ${unsupportedKinds.length > 0
        ? html`
            <div class="flex flex-wrap gap-2">
              ${unsupportedKinds.map(kind => html`
                <span class="inline-flex items-center gap-1 rounded-[var(--r-0)] bg-[var(--err-soft)] px-2 py-1 text-2xs text-[var(--color-danger-fg)]">
                  <span class="font-mono">${kind.count.toLocaleString()}</span>
                  <span class="font-mono">${kind.kind}</span>
                </span>
              `)}
            </div>
          `
        : null}

      <${SchLiveSupportedEvidence}
        automation=${automation}
        evidence=${automation.live_supported_non_terminal_evidence ?? null}
        onOpen=${setSelectedScheduleId}
      />

      <div class="flex flex-wrap gap-2">
        ${nonzeroCounts.length > 0
          ? nonzeroCounts.map(([name, count]) => html`<${CountChip} name=${name} count=${count} />`)
          : html`<span class="text-xs text-[var(--color-fg-muted)]">활성 예약 없음</span>`}
      </div>

      <div class="flex flex-wrap gap-2" aria-label="Schedule filters">
        ${SCHEDULE_FILTERS.map(filter => {
          const active = filter.key === activeFilter
          const count = filterCounts.get(filter.key) ?? 0
          return html`
            <button
              type="button"
              class=${`inline-flex items-center gap-1 rounded-[var(--r-0)] border px-2.5 py-1 text-2xs transition-colors ${active ? 'border-[var(--color-accent-fg)] bg-[var(--accent-12)] text-[var(--color-accent-fg)]' : 'border-[var(--color-border-default)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-muted)] hover:border-[var(--color-accent-fg)] hover:text-[var(--color-fg-secondary)]'}`}
              aria-pressed=${active ? 'true' : 'false'}
              data-schedule-filter=${filter.key}
              onClick=${() => {
                setActiveFilter(filter.key)
              }}
            >
              <span>${filter.label}</span>
              <span class="font-mono">${count.toLocaleString()}</span>
            </button>
          `
        })}
      </div>

      <div class="grid gap-2">
        <div class="text-3xs uppercase tracking-wider text-[var(--color-fg-disabled)]">
          upcoming wake signals
        </div>
        <${WakeSignalFeed} signals=${wakeSignals} />
      </div>

      ${rows.length > 0
        ? html`
            <div class="grid gap-4 xl:grid-cols-[minmax(0,1fr)_22rem]">
              <div class="grid gap-3">
                ${filteredRows.length > 0
                  ? filteredRows.map(request => html`
                      <${ScheduleCard}
                        request=${request}
                        selected=${selectedRequest?.schedule_id === request.schedule_id}
                        onSelect=${(next: DashboardScheduledAutomationRequest) => {
                          setSelectedScheduleId(next.schedule_id)
                        }}
                      />
                    `)
                  : html`<div class="rounded-[var(--r-1)] border border-dashed border-[var(--color-border-default)] px-4 py-8 text-center text-xs text-[var(--color-fg-muted)]">이 필터에 해당하는 예약이 없습니다.</div>`}
              </div>
              <aside class="grid content-start gap-2">
                <${ScheduleDetailPanel} request=${selectedRequest} onResolved=${onResolved} />
                <div
                  data-schedule-durable-signal-contract="payload_support"
                  data-schedule-durable-signal-raw=${durableSignalContract.rawCount}
                  data-schedule-durable-signal-visible=${durableSignalContract.visibleCount}
                  data-schedule-durable-signal-hidden=${durableSignalContract.hiddenByPayloadSupport}
                >
                  <div class="text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]">
                    ${hasDurableSignals ? 'durable wake signal feed' : 'request-derived wake signal feed'}
                  </div>
                  <div class="mt-1 text-xs text-[var(--color-fg-muted)]">
                    ${hasDurableSignals
                      ? `출처 ${automation.signal_source ?? 'schedule_runner_signals'} · ${durableSignals.length.toLocaleString()} / ${(automation.signal_count ?? durableSignals.length).toLocaleString()} signals 표시`
                      : durableSignalContract.hiddenByPayloadSupport > 0
                        ? `payload support로 ${durableSignalContract.hiddenByPayloadSupport.toLocaleString()} durable runner signal 숨김 · request rows에서 파생했습니다.`
                        : rawDurableSignalCount > 0
                          ? '표시 가능한 durable runner signal이 없어 request rows에서 파생했습니다.'
                        : 'durable runner signal이 없어 request rows에서 파생했습니다.'}
                  </div>
                </div>
                <ul class="grid gap-2">
                  ${hasDurableSignals
                    ? durableSignals.map(signal => html`
                        <${DurableSignalItem}
                          signal=${signal}
                          onSelectSchedule=${(scheduleId: string) => {
                            setSelectedScheduleId(scheduleId)
                          }}
                        />
                      `)
                    : wakeRows.map(request => html`
                        <${WakeSignalItem}
                          request=${request}
                          onSelect=${(next: DashboardScheduledAutomationRequest) => {
                            setSelectedScheduleId(next.schedule_id)
                          }}
                        />
                      `)}
                </ul>
              </aside>
            </div>
            ${automation.truncated
              ? html`<div class="text-3xs text-[var(--color-fg-muted)]">표시 ${rows.length.toLocaleString()} / 전체 ${automation.request_count.toLocaleString()}건</div>`
              : null}
          `
        : html`<div class="text-xs text-[var(--color-fg-muted)]">예약 요청 없음</div>`}
    </div>
  `
}
