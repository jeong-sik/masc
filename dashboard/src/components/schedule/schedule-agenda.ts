// Calendar (agenda) projection + presentation for the schedule surface.
//
// Ported from the keeper-v2 prototype (schedule.jsx: SchCadenceSummary /
// SchPollingStrip / SchAgenda). The prototype worked off static data and a fixed
// "now"; this module derives everything from the live schedule projection
// (DashboardScheduledAutomationRequest[]) instead.
//
// Two honesty rules the prototype did not need but production does:
//   1. Placement uses the backend-computed next wake (next_due_at ?? due_at). A
//      row without a concrete wake time cannot be placed and is dropped — future
//      occurrences are never fabricated on the client (no cron/DST guessing).
//   2. `now` is injected, so the projection is a pure function of its inputs and
//      the tests are deterministic.

import { html } from 'htm/preact'
import type { DashboardScheduledAutomationRequest } from '../../api'
import {
  automationTone,
  recurrenceLabel,
} from '../tools/scheduled-automation-panel'
import {
  SCHED_CADENCE,
  SCHED_CADENCE_ORDER,
  SCHED_TERMINAL_NORMALIZED,
  cadenceOfRecurrenceKind,
  parseRecurrenceKind,
  schedPayloadSpec,
  schedRiskSpec,
  schedStatusSpec,
  type Cadence,
} from '../v2/schedule-constants'
import { kSigil, kSlot } from '../keeper-badge'
import { SigilBadge } from '../v2/primitives-v2'
import { MOCK_KEEPER_BG } from './schedule-mock-data'

const MS_PER_DAY = 86_400_000
const AGENDA_DAYS = 7
const WEEKDAY_KO: readonly string[] = ['일', '월', '화', '수', '목', '금', '토']

// ── derivations ────────────────────────────────────────────────────

function normalizedStatus(request: DashboardScheduledAutomationRequest): string {
  return (request.effective_status ?? request.status)?.trim().toLowerCase() ?? ''
}

export function isTerminalRequest(request: DashboardScheduledAutomationRequest): boolean {
  return SCHED_TERMINAL_NORMALIZED.has(normalizedStatus(request))
}

/** Operator cadence for a request, or `null` when the recurrence kind is not one
 * of the closed backend set (surfaced, never silently bucketed). */
export function cadenceOfRequest(request: DashboardScheduledAutomationRequest): Cadence | null {
  const kind = parseRecurrenceKind(request.recurrence?.kind ?? request.recurrence_kind)
  return kind ? cadenceOfRecurrenceKind(kind) : null
}

export interface CadenceCounts {
  readonly scheduled: number
  readonly interval: number
  readonly oneshot: number
  /** Requests whose recurrence kind is outside the closed backend set. */
  readonly unknown: number
}

export function cadenceCounts(
  requests: readonly DashboardScheduledAutomationRequest[],
): CadenceCounts {
  let scheduled = 0
  let interval = 0
  let oneshot = 0
  let unknown = 0
  for (const request of requests) {
    const cadence = cadenceOfRequest(request)
    if (cadence === 'scheduled') scheduled += 1
    else if (cadence === 'interval') interval += 1
    else if (cadence === 'oneshot') oneshot += 1
    else unknown += 1
  }
  return { scheduled, interval, oneshot, unknown }
}

/** Concrete next wake in epoch milliseconds, preferring the ISO field (matches
 * the panel's `dueTimestamp`), then the numeric epoch-seconds field. `null` when
 * the projection has no concrete wake time to place. */
export function fireTimestampMs(request: DashboardScheduledAutomationRequest): number | null {
  const iso = request.next_due_at_iso ?? request.due_at_iso ?? null
  if (iso) {
    const parsed = Date.parse(iso)
    if (Number.isFinite(parsed)) return parsed
  }
  const epochSeconds = request.next_due_at ?? request.due_at ?? null
  if (typeof epochSeconds === 'number' && Number.isFinite(epochSeconds)) {
    return epochSeconds * 1000
  }
  return null
}

function startOfDayMs(ms: number): number {
  const date = new Date(ms)
  date.setHours(0, 0, 0, 0)
  return date.getTime()
}

// ── polling strip (interval schedules) ─────────────────────────────

export interface PollingRow {
  readonly request: DashboardScheduledAutomationRequest
  readonly nextTickMs: number | null
}

/** Active (non-terminal) interval schedules — the always-on polling loops that
 * do not belong on a specific calendar day. Sorted soonest-next-tick first;
 * rows without a next tick sort last but are kept (they are still active). */
export function selectPollingSchedules(
  requests: readonly DashboardScheduledAutomationRequest[],
): PollingRow[] {
  const rows: PollingRow[] = []
  for (const request of requests) {
    if (isTerminalRequest(request)) continue
    if (cadenceOfRequest(request) !== 'interval') continue
    rows.push({ request, nextTickMs: fireTimestampMs(request) })
  }
  return rows.sort(
    (a, b) => (a.nextTickMs ?? Number.MAX_SAFE_INTEGER) - (b.nextTickMs ?? Number.MAX_SAFE_INTEGER),
  )
}

// ── day agenda (scheduled + oneshot schedules) ─────────────────────

export interface AgendaEvent {
  readonly request: DashboardScheduledAutomationRequest
  readonly atMs: number
  // scheduled | oneshot for a recognized recurrence kind; null when the kind is
  // outside the closed backend set (surfaced, never silently dropped).
  readonly cadence: Exclude<Cadence, 'interval'> | null
}

export interface AgendaColumn {
  readonly offset: number
  readonly dateMs: number
  readonly events: AgendaEvent[]
}

/** Project active, non-interval schedules onto `days` day columns starting
 * today. Interval schedules are excluded (they live in the polling strip);
 * scheduled, oneshot, AND unrecognized-cadence rows all belong here so an
 * unknown recurrence kind is never silently dropped from the calendar. A row
 * whose next wake predates today is clamped onto today (overdue → visible now);
 * a row without a concrete wake time is dropped. */
export function buildAgenda(
  requests: readonly DashboardScheduledAutomationRequest[],
  options: { nowMs: number; days?: number },
): AgendaColumn[] {
  const days = options.days ?? AGENDA_DAYS
  const todayStart = startOfDayMs(options.nowMs)
  const columns: AgendaColumn[] = []
  for (let index = 0; index < days; index += 1) {
    columns.push({ offset: index, dateMs: todayStart + index * MS_PER_DAY, events: [] })
  }
  for (const request of requests) {
    if (isTerminalRequest(request)) continue
    const cadence = cadenceOfRequest(request)
    // interval → polling strip; everything else (scheduled, oneshot, unknown)
    // belongs on the day agenda.
    if (cadence === 'interval') continue
    const atMs = fireTimestampMs(request)
    if (atMs === null) continue
    const rawOffset = Math.round((startOfDayMs(atMs) - todayStart) / MS_PER_DAY)
    const offset = rawOffset < 0 ? 0 : rawOffset
    if (offset >= days) continue
    const column = columns[offset]
    if (column) column.events.push({ request, atMs, cadence })
  }
  for (const column of columns) {
    column.events.sort((a, b) => a.atMs - b.atMs)
  }
  return columns
}

// ── formatting ─────────────────────────────────────────────────────

function pad2(value: number): string {
  return String(value).padStart(2, '0')
}

function formatClock(ms: number): string {
  const date = new Date(ms)
  return `${pad2(date.getHours())}:${pad2(date.getMinutes())}`
}

function formatDayDate(ms: number): string {
  const date = new Date(ms)
  return `${date.getMonth() + 1}/${date.getDate()} (${WEEKDAY_KO[date.getDay()]})`
}

function relativeDayLabel(offset: number): string {
  if (offset === 0) return '오늘'
  if (offset === 1) return '내일'
  return `+${offset}일`
}

function scheduledBy(request: DashboardScheduledAutomationRequest): string {
  return request.scheduled_by?.id ?? request.scheduled_by?.display_name ?? '—'
}

function summaryText(request: DashboardScheduledAutomationRequest): string {
  const spec = schedPayloadSpec(request.payload_kind)
  const summary = request.payload_summary?.trim() || spec.lbl
  return `${spec.glyph} ${summary}`
}

function isPending(request: DashboardScheduledAutomationRequest): boolean {
  return normalizedStatus(request) === 'pending_approval'
}

// ── presentation ───────────────────────────────────────────────────

export function CadenceTag({ cadence, full }: { cadence: Cadence; full?: boolean }) {
  const spec = SCHED_CADENCE[cadence]
  return html`
    <span class=${`sch-cad ${spec.cls}`} title=${spec.hint}>
      ${spec.glyph} ${full ? spec.lbl : spec.short}
    </span>
  `
}

function RiskTag({ risk }: { risk: string }) {
  const spec = schedRiskSpec(risk)
  return html`<span class=${`sch-risk ${spec.cls}`} title=${`risk_class = ${risk}`}>${spec.lbl}</span>`
}

export function CadenceSummary({
  counts,
  active,
  onFilter,
}: {
  counts: CadenceCounts
  active: Cadence | null
  onFilter: (cadence: Cadence | null) => void
}) {
  return html`
    <div class="sch-cadsum" data-testid="sch-cadsum">
      ${SCHED_CADENCE_ORDER.map(cadence => {
        const spec = SCHED_CADENCE[cadence]
        const on = active === cadence
        const off = active !== null && !on
        return html`
          <button
            key=${cadence}
            class=${`sch-cadsum-i ${spec.cls} ${on ? 'on' : ''} ${off ? 'off' : ''}`}
            title=${spec.hint}
            aria-pressed=${on}
            data-testid=${`sch-cadsum-${cadence}`}
            onClick=${() => onFilter(on ? null : cadence)}
          >
            <span class="sch-cadsum-gl">${spec.glyph}</span>
            <span class="sch-cadsum-n mono">${counts[cadence].toLocaleString()}</span>
            <span class="sch-cadsum-l">${spec.lbl}</span>
          </button>
        `
      })}
      ${counts.unknown > 0
        ? html`
            <span
              class="sch-cadsum-i dim"
              title="recurrence kind가 알려진 집합(one_shot·interval·daily·cron) 밖입니다 — projection/버전 불일치"
              data-testid="sch-cadsum-unknown"
            >
              <span class="sch-cadsum-gl">⧗</span>
              <span class="sch-cadsum-n mono">${counts.unknown.toLocaleString()}</span>
              <span class="sch-cadsum-l">미상</span>
            </span>
          `
        : null}
    </div>
  `
}

function StatusTag({ status }: { status: string | null | undefined }) {
  const spec = schedStatusSpec(status)
  return html`<span class=${`sch-pill ${spec.cls}`}>${spec.glyph} ${spec.lbl}</span>`
}

function PollingCard({
  request,
  nextTickMs,
  onOpen,
}: {
  request: DashboardScheduledAutomationRequest
  nextTickMs: number | null
  onOpen: (scheduleId: string) => void
}) {
  const tone = automationTone(request.effective_status ?? request.status)
  const by = scheduledBy(request)
  return html`
    <button
      class=${`sch-poll-card st-${tone}`}
      data-testid="sch-poll-card"
      data-schedule-id=${request.schedule_id}
      onClick=${() => onOpen(request.schedule_id)}
    >
      <div class="sch-poll-top">
        <span class="sch-poll-int mono">↻ ${recurrenceLabel(request)}</span>
        <${StatusTag} status=${request.effective_status ?? request.status} />
      </div>
      <div class="sch-poll-title">${summaryText(request)}</div>
      <div class="sch-poll-foot">
        <${SigilBadge} slot=${kSlot(by)} sigil=${kSigil(by)} size=${14} />
        <span class="mono sch-poll-by">${by}</span>
        <${RiskTag} risk=${request.risk_class} />
        <span class="sch-poll-next mono" title="다음 tick (next_due_at)">
          ${nextTickMs === null ? '다음 tick 미상' : `다음 ~${formatClock(nextTickMs)}`}
        </span>
      </div>
    </button>
  `
}

export function PollingStrip({
  requests,
  onOpen,
}: {
  requests: readonly DashboardScheduledAutomationRequest[]
  onOpen: (scheduleId: string) => void
}) {
  const rows = selectPollingSchedules(requests)
  return html`
    <section class="sch-poll" data-testid="sch-polling-strip">
      <div class="sch-poll-h">
        <span class="sch-cad volt">↻ 상시 폴링</span>
        <span class="sch-poll-sub">고정 간격 반복 — 특정 시각이 아니라 계속 돎</span>
      </div>
      ${rows.length === 0
        ? html`<div class="sch-day-empty mono" data-testid="sch-polling-empty">활성 폴링 없음</div>`
        : html`
            <div class="sch-poll-list">
              ${rows.map(
                row => html`
                  <${PollingCard}
                    key=${row.request.schedule_id}
                    request=${row.request}
                    nextTickMs=${row.nextTickMs}
                    onOpen=${onOpen}
                  />
                `,
              )}
            </div>
          `}
    </section>
  `
}

function AgendaEventRow({
  event,
  onOpen,
}: {
  event: AgendaEvent
  onOpen: (scheduleId: string) => void
}) {
  const request = event.request
  const tone = automationTone(request.effective_status ?? request.status)
  const pending = isPending(request)
  const by = scheduledBy(request)
  return html`
    <button
      class=${`sch-ev st-${tone} ${pending ? 'pending' : ''}`}
      data-testid="sch-agenda-event"
      data-schedule-id=${request.schedule_id}
      onClick=${() => onOpen(request.schedule_id)}
    >
      <span class="sch-ev-time mono">${formatClock(event.atMs)}</span>
      ${event.cadence === null
        ? html`<span class="sch-cad dim" title="recurrence kind가 알려진 집합(one_shot·interval·daily·cron) 밖입니다 — projection/버전 불일치">⧗ 미상</span>`
        : html`<${CadenceTag} cadence=${event.cadence} />`}
      <span class="sch-ev-body">
        <span class="sch-ev-title">${summaryText(request)}</span>
        <span class="sch-ev-meta">
          <${SigilBadge} slot=${kSlot(by)} sigil=${kSigil(by)} size=${14} />
          <span class="mono sch-ev-by">${by}</span>
          <${RiskTag} risk=${request.risk_class} />
          ${pending ? html`<span class="sch-ev-need mono">⊙ 승인 필요</span>` : null}
        </span>
      </span>
      <${StatusTag} status=${request.effective_status ?? request.status} />
    </button>
  `
}

export function Agenda({
  requests,
  nowMs,
  days,
  onOpen,
}: {
  requests: readonly DashboardScheduledAutomationRequest[]
  nowMs: number
  days?: number
  onOpen: (scheduleId: string) => void
}) {
  const columns = buildAgenda(requests, { nowMs, days })
  // Keep today/tomorrow even when empty (anchors the timeline); drop later empty
  // days so the agenda does not pad out with blank columns.
  const visible = columns.filter(column => column.events.length > 0 || column.offset <= 1)
  const hasAny = visible.some(column => column.events.length > 0)
  return html`
    <div class="sch-agenda" data-testid="sch-agenda">
      ${!hasAny
        ? html`<div class="sch-empty" data-testid="sch-agenda-empty">다가오는 ${(days ?? AGENDA_DAYS)}일에 예정된 예약이 없습니다.</div>`
        : null}
      ${visible.map(column => {
        const isToday = column.offset === 0
        return html`
          <div key=${column.offset} class=${`sch-day ${isToday ? 'today' : ''}`}>
            <div class="sch-day-h">
              <span class="sch-day-rel">${relativeDayLabel(column.offset)}</span>
              <span class="sch-day-date mono">${formatDayDate(column.dateMs)}</span>
              ${isToday ? html`<span class="sch-day-now mono">지금 ${formatClock(nowMs)}</span>` : null}
              <span class="sch-day-n mono">${column.events.length > 0 ? `${column.events.length}건` : ''}</span>
            </div>
            ${column.events.length === 0
              ? html`<div class="sch-day-empty mono">예정 없음</div>`
              : html`
                  <div class="sch-day-evs">
                    ${column.events.map(
                      event => html`
                        <${AgendaEventRow}
                          key=${event.request.schedule_id}
                          event=${event}
                          onOpen=${onOpen}
                        />
                      `,
                    )}
                  </div>
                `}
          </div>
        `
      })}
    </div>
  `
}

interface BackgroundSignal {
  readonly id: string
  readonly keeper: string
  readonly kind: 'poll' | 'async_tool'
  readonly label: string
  readonly cadence_sec?: number
  readonly status: string
  readonly risk_class: string
  readonly since?: string
  readonly tool?: string
  readonly issued?: string
  readonly eta?: string
}

function SchKeeperBgRow({
  row,
  onOpenKeeper,
}: {
  row: BackgroundSignal
  onOpenKeeper: (keeperId: string) => void
}) {
  const tone = row.status === 'running' || row.status === 'in_flight' ? 'ok' : row.status === 'paused' ? 'idle' : 'warn'
  const isPoll = row.kind === 'poll'
  const cadenceText = isPoll ? `↻ ${row.cadence_sec}s` : '⇢ 비동기'
  const stateLabel = row.status === 'running' || row.status === 'in_flight' ? '▶ 도는 중' : row.status === 'paused' ? '⏸ 일시정지' : '⊙ 대기 중'
  const slot = kSlot(row.keeper)
  const sigil = kSigil(row.keeper)
  
  return html`
    <button
      key=${row.id}
      class=${`sch-bg-row st-${tone}`}
      onClick=${() => onOpenKeeper(row.keeper)}
      title=${`${row.keeper} 대화 열기`}
      data-testid="sch-bg-row"
    >
      <span class="sch-bg-when mono">${cadenceText}</span>
      <span class="sch-bg-body">
        <span class="sch-bg-title">${row.label}</span>
        <span class="sch-bg-meta">
          <${SigilBadge} slot=${slot} sigil=${sigil} size=${16} />
          <span class="mono sch-bg-by">${row.keeper}</span>
          <span class=${`sch-risk ${schedRiskSpec(row.risk_class).cls}`} title=${`risk_class = ${row.risk_class}`}>
            ${schedRiskSpec(row.risk_class).lbl}
          </span>
          <span class="sch-bg-since mono">
            ${isPoll ? `since ${row.since}` : `issued ${row.issued} · eta ${row.eta}`}
          </span>
        </span>
      </span>
      <span class=${`sch-pill ${tone === 'ok' ? 'ok' : tone === 'idle' ? 'dim' : 'warn'}`}>${stateLabel}</span>
    </button>
  `
}

export function SchKeeperBg({
  signals: _signals,
  demoMode,
  onOpenKeeper,
}: {
  signals: any[]
  demoMode: boolean
  onOpenKeeper: (keeperId: string) => void
}) {
  const rows = demoMode ? MOCK_KEEPER_BG : []
  if (rows.length === 0) return null

  const polls = rows.filter(r => r.kind === 'poll')
  const asyncs = rows.filter(r => r.kind === 'async_tool')

  return html`
    <section class="sch-bg" data-testid="sch-keeper-background">
      <div class="sch-bg-h">
        <span class="sch-cad ok">◈ Keeper 자율 백그라운드</span>
        <span class="sch-bg-sub">컨텍스트 루프에서 독립 구동되는 백그라운드 워커 (상시 폴링 + 비동기 도구)</span>
      </div>
      <div class="sch-bg-grid">
        <div class="sch-bg-col">
          <div class="sch-bg-colh">↻ 폴링 루프 (${polls.length})</div>
          <div class="sch-bg-list">
            ${polls.map(row => html`<${SchKeeperBgRow} key=${row.id} row=${row} onOpenKeeper=${onOpenKeeper} />`)}
          </div>
        </div>
        <div class="sch-bg-col">
          <div class="sch-bg-colh">⇢ 비동기 도구 호출 (${asyncs.length})</div>
          <div class="sch-bg-list">
            ${asyncs.map(row => html`<${SchKeeperBgRow} key=${row.id} row=${row} onOpenKeeper=${onOpenKeeper} />`)}
          </div>
        </div>
      </div>
    </section>
  `
}

/** Calendar view: always-on polling strip (interval) above the day agenda
 * (scheduled + oneshot). Cadence filter narrows both. */
export function ScheduleCalendar({
  requests,
  signals,
  demoMode,
  nowMs,
  cadenceFilter,
  onOpen,
  onOpenKeeper,
}: {
  requests: readonly DashboardScheduledAutomationRequest[]
  signals: readonly any[]
  demoMode: boolean
  nowMs: number
  cadenceFilter: Cadence | null
  onOpen: (scheduleId: string) => void
  onOpenKeeper: (keeperId: string) => void
}) {
  const showPolling = cadenceFilter === null || cadenceFilter === 'interval'
  const showAgenda = cadenceFilter === null || cadenceFilter !== 'interval'
  const agendaRequests =
    cadenceFilter === null
      ? requests
      : requests.filter(request => cadenceOfRequest(request) === cadenceFilter)
  return html`
    <div data-testid="sch-calendar">
      ${showPolling ? html`<${PollingStrip} requests=${requests} onOpen=${onOpen} />` : null}
      ${showAgenda ? html`<${Agenda} requests=${agendaRequests} nowMs=${nowMs} onOpen=${onOpen} />` : null}
      <${SchKeeperBg} signals=${signals} demoMode=${demoMode} onOpenKeeper=${onOpenKeeper} />
    </div>
  `
}
