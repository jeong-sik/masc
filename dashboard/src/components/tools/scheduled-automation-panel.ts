import { html } from 'htm/preact'
import type {
  DashboardScheduledAutomation,
  DashboardScheduledAutomationRequest,
} from '../../api'
import { formatDateTimeKo } from '../../lib/format-time'
import { StatusChip, type StatusChipTone } from '../common/status-chip'

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

function lastExecutionLabel(request: DashboardScheduledAutomationRequest): string {
  const execution = request.last_execution
  if (!execution) return '-'
  const status = enumLabel(execution.status)
  const finishedAt = formatDateTimeKo(execution.finished_at_iso ?? execution.started_at_iso ?? null)
  return finishedAt === '-' ? status : `${status} ${finishedAt}`
}

function ScheduleRow({ request }: { request: DashboardScheduledAutomationRequest }) {
  const effectiveStatus = request.effective_status ?? request.status
  const readiness = request.execution_readiness ?? '-'
  const action = request.operator_action ?? '-'
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
      <td class="py-2 pr-3 text-xs text-[var(--color-fg-muted)]">${enumLabel(request.risk_class)}</td>
      <td class="py-2 pr-3 text-xs text-[var(--color-fg-muted)]">${request.payload_kind ?? '-'}</td>
      <td class="py-2 pr-3 text-xs text-[var(--color-fg-muted)]">${recurrenceLabel(request)}</td>
      <td class="py-2 pr-3 text-xs text-[var(--color-fg-muted)]">${lastExecutionLabel(request)}</td>
      <td class="py-2 pr-3 text-xs text-[var(--color-fg-muted)]">${formatDateTimeKo(request.due_at_iso ?? null)}</td>
      <td class="py-2 text-xs text-[var(--color-fg-muted)]">${request.approval_required ? 'required' : 'not required'}</td>
    </tr>
  `
}

export function ScheduledAutomationPanel({
  automation,
}: {
  automation?: DashboardScheduledAutomation | null
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
  const dueEffective = automation.derived_counts?.due_effective ?? 0
  const blockedApproval = automation.derived_counts?.blocked_approval ?? 0
  const dueExecutionReady = automation.derived_counts?.due_execution_ready ?? 0
  const expiredEffective = automation.derived_counts?.expired_effective ?? 0

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
        <span class="text-[var(--color-fg-muted)]">
          next due <span class="font-mono text-[var(--color-fg-secondary)]">${formatDateTimeKo(automation.fsm.next_due_at ?? null)}</span>
        </span>
        <span class="font-mono text-3xs text-[var(--color-fg-disabled)]">${automation.source ?? 'schedule_store'}</span>
      </div>

      <div class="flex flex-wrap gap-2">
        ${nonzeroCounts.length > 0
          ? nonzeroCounts.map(([name, count]) => html`<${CountChip} name=${name} count=${count} />`)
          : html`<span class="text-xs text-[var(--color-fg-muted)]">active schedule 없음</span>`}
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
                    <th class="pb-2 pr-3 font-medium">risk</th>
                    <th class="pb-2 pr-3 font-medium">payload</th>
                    <th class="pb-2 pr-3 font-medium">recurrence</th>
                    <th class="pb-2 pr-3 font-medium">last run</th>
                    <th class="pb-2 pr-3 font-medium">due</th>
                    <th class="pb-2 font-medium">approval</th>
                  </tr>
                </thead>
                <tbody>
                  ${rows.map(request => html`<${ScheduleRow} request=${request} />`)}
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
