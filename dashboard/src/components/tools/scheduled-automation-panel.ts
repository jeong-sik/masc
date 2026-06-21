import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import {
  resolveScheduleApproval,
  type DashboardScheduleDecision,
  type DashboardScheduledAutomation,
  type DashboardScheduledAutomationRequest,
} from '../../api'
import { formatDateTimeKo } from '../../lib/format-time'
import { ActionButton } from '../common/button'
import { StatusChip, type StatusChipTone } from '../common/status-chip'
import { showToast } from '../common/toast'

function enumLabel(value: string | null | undefined): string {
  if (!value) return '-'
  return value.replace(/_/g, ' ')
}

function automationTone(status: string | null | undefined): StatusChipTone {
  switch (status) {
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
      return 'bad'
    case 'succeeded':
      return 'info'
    case 'idle':
    case 'cancelled':
    default:
      return 'neutral'
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

function ScheduleRow({
  request,
  onResolved,
}: {
  request: DashboardScheduledAutomationRequest
  onResolved?: () => Promise<void> | void
}) {
  const effectiveStatus = request.effective_status ?? request.status
  const readiness = request.execution_readiness ?? '-'
  const action = request.operator_action ?? '-'
  const dueIso = request.next_due_at_iso ?? request.due_at_iso ?? null
  return html`
    <tr class="v2-lab-row border-t border-[var(--color-border-default)]">
      <td class="py-2 pr-3 font-mono text-xs text-[var(--color-fg-secondary)]">${request.schedule_id}</td>
      <td class="py-2 pr-3">
        <${StatusChip} tone=${automationTone(effectiveStatus)} uppercase=${false}>${enumLabel(effectiveStatus)}<//>
        ${effectiveStatus !== request.status
          ? html`<div class="mt-1 text-3xs text-[var(--color-fg-disabled)]">raw ${enumLabel(request.status)}</div>`
          : null}
      </td>
      <td class="py-2 pr-3 text-xs text-[var(--color-fg-muted)]">${enumLabel(readiness)}</td>
      <td class="py-2 pr-3 text-xs text-[var(--color-fg-muted)]">${enumLabel(action)}</td>
      <td class="py-2 pr-3"><${KeeperActionCell} request=${request} /></td>
      <td class="py-2 pr-3 text-xs text-[var(--color-fg-muted)]">${enumLabel(request.risk_class)}</td>
      <td class="py-2 pr-3"><${PayloadCell} request=${request} /></td>
      <td class="py-2 pr-3 text-xs text-[var(--color-fg-muted)]">${recurrenceLabel(request)}</td>
      <td class="py-2 pr-3 text-xs text-[var(--color-fg-muted)]">${lastExecutionLabel(request)}</td>
      <td class="py-2 pr-3 text-xs text-[var(--color-fg-muted)]">${formatDateTimeKo(dueIso)}</td>
      <td class="py-2 text-xs text-[var(--color-fg-muted)]"><${ApprovalCell} request=${request} onResolved=${onResolved} /></td>
    </tr>
  `
}

export function ScheduledAutomationPanel({
  automation,
  onResolved,
}: {
  automation?: DashboardScheduledAutomation | null
  onResolved?: () => Promise<void> | void
}) {
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
          active <span class="font-mono text-[var(--color-fg-secondary)]">${automation.fsm.active_count.toLocaleString()}</span>
        </span>
        <span class="text-[var(--color-fg-muted)]">
          terminal <span class="font-mono text-[var(--color-fg-secondary)]">${automation.fsm.terminal_count.toLocaleString()}</span>
        </span>
        <span class="text-[var(--color-fg-muted)]">
          due effective <span class="font-mono text-[var(--color-fg-secondary)]">${dueEffective.toLocaleString()}</span>
        </span>
        <span class="text-[var(--color-fg-muted)]">
          blocked <span class="font-mono text-[var(--color-fg-secondary)]">${blockedApproval.toLocaleString()}</span>
        </span>
        <span class="text-[var(--color-fg-muted)]">
          ready <span class="font-mono text-[var(--color-fg-secondary)]">${dueExecutionReady.toLocaleString()}</span>
        </span>
        <span class="text-[var(--color-fg-muted)]">
          expired <span class="font-mono text-[var(--color-fg-secondary)]">${expiredEffective.toLocaleString()}</span>
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
          next due <span class="font-mono text-[var(--color-fg-secondary)]">${formatDateTimeKo(automation.fsm.next_due_at ?? null)}</span>
        </span>
        <span class="font-mono text-3xs text-[var(--color-fg-disabled)]">${automation.source ?? 'schedule_store'}</span>
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
          : html`<span class="text-xs text-[var(--color-fg-muted)]">active schedule 없음</span>`}
      </div>

      <div class="grid gap-2">
        <div class="text-3xs uppercase tracking-wider text-[var(--color-fg-disabled)]">
          upcoming wake signals
        </div>
        <${WakeSignalFeed} signals=${wakeSignals} />
      </div>

      ${rows.length > 0
        ? html`
            <div class="overflow-x-auto">
              <table class="v2-lab-table min-w-full border-collapse text-left">
                <thead class="text-3xs uppercase tracking-wider text-[var(--color-fg-disabled)]">
                  <tr>
                    <th class="pb-2 pr-3 font-medium">schedule</th>
                    <th class="pb-2 pr-3 font-medium">status</th>
                    <th class="pb-2 pr-3 font-medium">readiness</th>
                    <th class="pb-2 pr-3 font-medium">action</th>
                    <th class="pb-2 pr-3 font-medium">keeper</th>
                    <th class="pb-2 pr-3 font-medium">risk</th>
                    <th class="pb-2 pr-3 font-medium">payload</th>
                    <th class="pb-2 pr-3 font-medium">recurrence</th>
                    <th class="pb-2 pr-3 font-medium">last run</th>
                    <th class="pb-2 pr-3 font-medium">due</th>
                    <th class="pb-2 font-medium">approval</th>
                  </tr>
                </thead>
                <tbody>
                  ${rows.map(request => html`<${ScheduleRow} request=${request} onResolved=${onResolved} />`)}
                </tbody>
              </table>
            </div>
            ${automation.truncated
              ? html`<div class="text-3xs text-[var(--color-fg-muted)]">표시 ${rows.length.toLocaleString()} / 전체 ${automation.request_count.toLocaleString()}건</div>`
              : null}
          `
        : html`<div class="text-xs text-[var(--color-fg-muted)]">예약 요청 없음</div>`}
    </div>
  `
}
