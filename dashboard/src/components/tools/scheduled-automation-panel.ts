import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import {
  resolveScheduleApproval,
  type DashboardScheduleDecision,
  type DashboardScheduledAutomationActor,
  type DashboardScheduledAutomation,
  type DashboardScheduledAutomationExecution,
  type DashboardScheduledAutomationRequest,
  type DashboardScheduledAutomationSignal,
} from '../../api'
import { formatDateTimeKo } from '../../lib/format-time'
import { ActionButton } from '../common/button'
import { StatusChip, type StatusChipTone } from '../common/status-chip'
import { showToast } from '../common/toast'

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

function automationTone(status: string | null | undefined): StatusChipTone {
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

function recurrenceLabel(request: DashboardScheduledAutomationRequest): string {
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
  'succeeded',
  'failed',
  'rejected',
])

export function selectWakeSignals(
  automation: DashboardScheduledAutomation | null | undefined,
): WakeSignal[] {
  if (!automation) return []
  const signals: WakeSignal[] = []
  for (const request of automation.requests ?? []) {
    const at = request.next_due_at ?? request.due_at ?? null
    // No concrete wake time → no signal to surface (parse, don't validate).
    if (at == null) continue
    const readiness = request.execution_readiness ?? null
    const status = request.effective_status ?? request.status
    if (readiness != null && NON_UPCOMING_WAKE_READINESS.has(readiness)) continue
    if (NON_UPCOMING_WAKE_STATUS.has(status)) continue
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

function LastExecutionBlock({ execution }: { execution: DashboardScheduledAutomationExecution | null | undefined }) {
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
          <${LastExecutionBlock} execution=${execution} />
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

export function ScheduledAutomationPanel({
  automation,
  onResolved,
}: {
  automation?: DashboardScheduledAutomation | null
  onResolved?: () => Promise<void> | void
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

  const nonzeroCounts = Object.entries(automation.counts ?? {})
    .filter(([, count]) => count > 0)
  const rows = automation.requests ?? []
  const wakeSignals = selectWakeSignals(automation)
  const filteredRows = rows.filter(request => filterMatches(activeFilter, request))
  const wakeRows = [...rows].sort((a, b) => dueTimestamp(a) - dueTimestamp(b))
  const durableSignals = [...(automation.signals ?? [])].sort((a, b) => signalTimestamp(a) - signalTimestamp(b))
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
                <div>
                  <div class="text-3xs uppercase tracking-[var(--track-caps)] text-[var(--color-fg-disabled)]">
                    ${hasDurableSignals ? 'durable wake signal feed' : 'request-derived wake signal feed'}
                  </div>
                  <div class="mt-1 text-xs text-[var(--color-fg-muted)]">
                    ${hasDurableSignals
                      ? `출처 ${automation.signal_source ?? 'schedule_runner_signals'} · ${durableSignals.length.toLocaleString()} / ${(automation.signal_count ?? durableSignals.length).toLocaleString()} signals 표시`
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
