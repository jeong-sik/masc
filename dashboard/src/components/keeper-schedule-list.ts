// The schedules that wake one Keeper, in the order they will run.
//
// The schedule surface shows the fleet; a Keeper's own schedules were reachable
// only by filtering it by eye. This list reads the page the server narrows to
// that Keeper's keeper-wake target and draws each schedule with its next run,
// its recurrence, its status and when it last ran. A row opens the schedule.

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import type { DashboardScheduledAutomationRequest } from '../api'
import {
  fetchKeeperScheduledAutomation,
  type DashboardScheduledAutomationProjection,
} from '../api/dashboard-scheduled-automation'
import { formatRelativeSec, formatRelativeUntilSec, formatTimestampKo } from '../lib/format-time'
import { nowSecondsSignal, useNowSecondsTicker } from '../lib/now-signal'
import { setupObservationRefresh } from '../lib/observation-refresh'
import { useManagedAsyncResource } from '../lib/use-managed-async-resource'
import { hashForRoute } from '../router'
import { StatusChip } from './common/status-chip'
import { KpiSection } from './keeper-detail-kpi'
import { isCalendarVisible, queueDrainStatusOf } from './schedule/queue-drain-status'
import { summaryText } from './schedule/schedule-agenda'
import { automationTone, recurrenceLabel } from './tools/scheduled-automation-panel'

const PANEL_TITLE = '예약'
const MS_PER_SECOND = 1000

function instantMs(iso: string | null | undefined, epochSeconds: number | null | undefined): number | null {
  if (iso) {
    const parsed = Date.parse(iso)
    if (Number.isFinite(parsed)) return parsed
  }
  return typeof epochSeconds === 'number' && Number.isFinite(epochSeconds)
    ? epochSeconds * MS_PER_SECOND
    : null
}

/** When the schedule runs next, or null when it will not run again. Only the
 *  next wake counts: an ended one-shot keeps its due time, and drawn as the
 *  next run it would read as still to come. */
export function nextWakeMs(request: DashboardScheduledAutomationRequest): number | null {
  return instantMs(request.next_due_at_iso, request.next_due_at)
}

/** When the last wake ended, or started when it has not ended. */
export function lastWakeMs(request: DashboardScheduledAutomationRequest): number | null {
  const wake = request.last_wake
  if (!wake) return null
  return instantMs(wake.finished_at_iso, wake.finished_at)
    ?? instantMs(wake.started_at_iso, wake.started_at)
}

/** Earliest next run first; schedules that will not run again go last, in
 *  the order the server sent them. */
export function byNextWake(
  requests: readonly DashboardScheduledAutomationRequest[],
): DashboardScheduledAutomationRequest[] {
  return [...requests].sort((a, b) => {
    const at = nextWakeMs(a)
    const bt = nextWakeMs(b)
    if (at === null) return bt === null ? 0 : 1
    if (bt === null) return -1
    return at - bt
  })
}

/** "11. 28. 오전 09:00 (16시간 후)", or "… (3분 전)" for a next run already due. */
export function nextWakeText(atMs: number | null, nowMs: number): string {
  if (atMs === null) return '다음 실행 없음'
  const when = formatTimestampKo(atMs / MS_PER_SECOND)
  const relative = atMs >= nowMs
    ? formatRelativeUntilSec((atMs - nowMs) / MS_PER_SECOND)
    : formatRelativeSec((nowMs - atMs) / MS_PER_SECOND)
  return `${when} (${relative})`
}

function ScheduleRow({ request, nowMs }: { request: DashboardScheduledAutomationRequest; nowMs: number }) {
  const next = nextWakeMs(request)
  const last = lastWakeMs(request)
  const drain = queueDrainStatusOf(request)
  const overdue = next !== null && next < nowMs
  return html`
    <li>
      <a
        class="grid grid-cols-[minmax(11rem,auto)_minmax(0,1fr)] gap-x-3 gap-y-1 rounded-[var(--r-0)] px-2 py-1.5 text-xs no-underline hover:bg-[var(--color-bg-hover)]"
        href=${hashForRoute('schedule', { schedule_id: request.schedule_id })}
        data-testid="keeper-schedule-row"
        data-schedule-id=${request.schedule_id}
      >
        <span
          class=${`font-mono ${overdue ? 'text-[var(--color-status-warn)]' : 'text-[var(--color-fg-primary)]'}`}
          data-testid="keeper-schedule-next"
        >${nextWakeText(next, nowMs)}</span>
        <span class="min-w-0 truncate text-[var(--color-fg-primary)]">${summaryText(request)}</span>
        <span class="flex flex-wrap items-center gap-1.5">
          <span class="font-mono text-[var(--color-fg-muted)]">↻ ${recurrenceLabel(request)}</span>
          <${StatusChip} tone=${automationTone(request.status)} uppercase=${false}>${request.status}<//>
        </span>
        <span class="flex flex-wrap items-center gap-1.5 text-[var(--color-fg-muted)]" data-testid="keeper-schedule-last">
          ${last === null ? '아직 실행 안 함' : `마지막 실행 ${formatTimestampKo(last / MS_PER_SECOND)}`}
          ${drain && isCalendarVisible(drain)
            ? html`<${StatusChip} tone=${drain.tone} uppercase=${false} title=${drain.title}>${drain.label}<//>`
            : null}
        </span>
      </a>
    </li>
  `
}

function Note({ children, tone = 'muted' }: { children: unknown; tone?: 'muted' | 'warn' }) {
  const color = tone === 'warn' ? 'text-[var(--color-status-warn)]' : 'text-[var(--color-fg-muted)]'
  return html`<div class=${`px-2 text-xs ${color}`}>${children}</div>`
}

export function KeeperScheduleList({ keeperName }: { keeperName: string }) {
  useNowSecondsTicker()
  const resource = useManagedAsyncResource<DashboardScheduledAutomationProjection>()
  // Read when drawn, and again when a schedule changes anywhere: a change
  // event does not say which Keeper the schedule wakes.
  useEffect(() => setupObservationRefresh(
    () => resource.load(signal => fetchKeeperScheduledAutomation(keeperName, { signal })),
    {
      topics: ['scheduled_automation'],
      readError: () => resource.readError(),
      cancelRead: () => { resource.cancel() },
      resetRead: () => { resource.reset() },
    },
  ), [resource, keeperName])

  const { data, error } = resource.state.value
  const nowMs = nowSecondsSignal.value * MS_PER_SECOND
  const body = (() => {
    if (data === null) {
      return error === null
        ? html`<${Note}>예약을 읽는 중…<//>`
        : html`<${Note} tone="warn">예약을 읽지 못했어요: ${error}<//>`
    }
    if (data.state === 'unavailable') {
      return html`<${Note} tone="warn">예약을 읽지 못했어요: ${data.reason}<//>`
    }
    const requests = byNextWake(data.data.requests)
    if (requests.length === 0) return html`<${Note}>이 Keeper 를 깨우는 예약이 없어요.<//>`
    return html`
      <ul class="m-0 flex list-none flex-col gap-0.5 p-0" data-testid="keeper-schedule-list">
        ${requests.map(request => html`<${ScheduleRow} key=${request.schedule_id} request=${request} nowMs=${nowMs} />`)}
      </ul>
      ${data.page.truncated
        ? html`<${Note}>앞 ${data.page.visibleCount}개만 읽었어요. 나머지는 예약 화면에서 봐요.<//>`
        : null}
      ${error === null ? null : html`<${Note} tone="warn">마지막 새로고침 실패: ${error}<//>`}
    `
  })()

  return html`
    <${KpiSection} title=${PANEL_TITLE}>
      <div class="flex flex-col gap-1" data-keeper-schedules=${data === null ? 'reading' : data.state}>${body}</div>
    <//>
  `
}
