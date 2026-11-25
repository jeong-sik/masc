// Dedicated Schedule surface.
//
// Two views over the schedule projection, read from the shared schedule
// resources (GET /api/v1/dashboard/scheduled-automation):
//   · 캘린더 — the always-on polling strip (interval) above a day agenda
//     (scheduled + oneshot). It draws the active-only page: every schedule
//     still going to run.
//   · 목록   — the mature diagnostic list/cards/signal feed in
//     tools/scheduled-automation-panel.ts (variant "v2"), reused verbatim so the
//     route does not fork the backed schedule semantics. It draws the fleet
//     page, as the KPI strip and the aside do.
// A cadence filter (정기 · 폴링 · 1회) narrows both views. Both share one detail
// overlay (SchDetail) and one selection state, so a row opens the same drawer
// regardless of view.

import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import type {
  DashboardScheduledAutomation,
  DashboardScheduledAutomationRequest,
} from '../../api'
import {
  fetchDashboardScheduledAutomationLookup,
  type DashboardScheduledAutomationLookup,
} from '../../api/dashboard-scheduled-automation'
import { isEpochCurrent, sessionEpoch } from '../../core/auth'
import { replaceRoute, route } from '../../router'
import { formatTimestampKo } from '../../lib/format-time'
import { ErrorState, LoadingState } from '../common/feedback-state'
import { ActionButton } from '../common/button'
import { InlineSpinner } from '../common/inline-spinner'
import { StatusChip } from '../common/status-chip'
import { showToast } from '../common/toast'
import { KeeperLaneInventoryPanel } from '../tools/keeper-waiting-inventory-panel'
import {
  ScheduleAside,
  ScheduledAutomationPanel,
  SchDetail,
  scheduleWireValue,
} from '../tools/scheduled-automation-panel'
import type { Cadence } from '../v2/schedule-constants'
import { CadenceSummary, ScheduleCalendar, cadenceCounts, cadenceOfRequest } from './schedule-agenda'
import { countQueueDrainCancelled, countQueueDrainMisses } from './queue-drain-status'
import {
  loadTools,
  toolsData,
} from '../tools/tool-state'
import {
  activeScheduleRead,
  loadScheduledAutomation,
  scheduledAutomationError,
  scheduledAutomationLoading,
  scheduledAutomationProjection,
  subscribeActiveSchedulesRefresh,
  subscribeScheduledAutomationRefresh,
} from './schedule-state'
import { pruneSchedules } from '../../api/dashboard-schedule'

type ScheduleView = 'calendar' | 'list'

type ExactScheduleState =
  | { kind: 'idle' }
  | { kind: 'loading'; scheduleId: string; epoch: number }
  // `rereadFailure` is why the newest read of this schedule did not replace
  // `lookup`: the answer on screen is then older than the projection beside it.
  | { kind: 'resolved'; lookup: DashboardScheduledAutomationLookup; rereadFailure: string | null; epoch: number }
  | { kind: 'failed'; scheduleId: string; reason: string; epoch: number }

function countLabel(count: number | null): string {
  return count === null ? '—' : count.toLocaleString()
}

// Narrow the projection handed to the list view so the cadence chip filters
// both views consistently. Requests and their durable signals are narrowed
// together (a signal for a filtered-out schedule would otherwise dangle).
function filterAutomationByCadence(
  automation: DashboardScheduledAutomation,
  cadence: Cadence | null,
): DashboardScheduledAutomation {
  if (cadence === null) return automation
  const requests = (automation.requests ?? []).filter(request => cadenceOfRequest(request) === cadence)
  const ids = new Set(requests.map(request => request.schedule_id))
  const signals = automation.signals?.filter(signal => ids.has(signal.schedule_id))
  return { ...automation, requests, signals }
}

function countByStatus(
  automation: DashboardScheduledAutomation,
  statuses: readonly string[],
): number {
  const wireStatuses = statuses.map(scheduleWireValue)
  const fromCounts = wireStatuses.reduce(
    (sum, status) => sum + (automation.counts?.[status] ?? 0),
    0,
  )
  const fromRequests = (automation.requests ?? [])
    .filter(request => wireStatuses.includes(scheduleWireValue(request.status)))
    .length
  return Math.max(fromCounts, fromRequests)
}

export function ScheduleSurface() {
  const data = toolsData.value
  const [view, setView] = useState<ScheduleView>('calendar')
  // Schedule rows come from the schedule projection; the keeper diagnostics
  // panels below still read the tool inventory, which is why both are loaded.
  const projection = scheduledAutomationProjection.value
  const automation = projection?.state === 'available' ? projection.data : null
  const page = projection?.state === 'available' ? projection.page : null
  const projectionError = projection?.state === 'unavailable' ? projection.reason : null
  const waitingInventory = data?.keeper_waiting_inventory ?? null
  const loading = scheduledAutomationLoading.value
  const error = scheduledAutomationError.value
  const blockingError = automation ? null : projectionError ?? error
  const scheduledCount = automation ? countByStatus(automation, ['scheduled']) : null
  const dueCount = automation ? countByStatus(automation, ['due']) : null
  const runningCount = automation ? countByStatus(automation, ['running']) : null
  const dueRunning = dueCount === null || runningCount === null
    ? null
    : dueCount + runningCount
  const requests = automation?.requests ?? []
  // The calendar draws its own page (#52961). The fleet page above stops at
  // the 20 soonest schedules, and polling schedules alone can take all of
  // them; this one is every schedule still going to run, up to the server's
  // selected-page limit.
  const { observation: calendar, loading: calendarLoading, error: calendarError } = activeScheduleRead.value
  const calendarAutomation = calendar?.projection.data ?? null
  // What the open view draws its rows from.
  const viewAutomation = view === 'calendar' ? calendarAutomation : automation
  const routeScheduleId = route.value.params.schedule_id ?? null
  const rowOf = (rows: readonly DashboardScheduledAutomationRequest[]) =>
    rows.find(request => request.schedule_id === routeScheduleId) ?? null
  // The calendar page is only kept current while the calendar is open, so its
  // rows answer a selection only there.
  const inPageRequest = routeScheduleId === null
    ? null
    : (view === 'calendar' ? rowOf(calendarAutomation?.requests ?? []) : null) ?? rowOf(requests)
  const totalCount = page?.totalCount ?? null
  const cadCounts = cadenceCounts(viewAutomation?.requests ?? [])
  // Scheduled keeper wakes that were dispatched but are in neither queue AND
  // never recorded as reacted — the drain-miss the calendar surfaces per row.
  const queueMisses = automation ? countQueueDrainMisses(requests) : null
  // Wakes the queue cancelled without a turn — a definition whose target is
  // gone keeps firing into this number every day.
  const queueCancelled = automation ? countQueueDrainCancelled(requests) : null
  // Every retained attempt in the store, not the newest of the rows on the
  // page: a burst of failures a later tick retried is still counted here.
  const wakeCounts = automation?.wake_counts ?? null

  const [cadenceFilter, setCadenceFilter] = useState<Cadence | null>(null)
  const [pruning, setPruning] = useState(false)
  const selectedScheduleId = routeScheduleId
  const epoch = sessionEpoch.value
  const [exactState, setExactSchedule] = useState<ExactScheduleState>({ kind: 'idle' })
  const exactSchedule = exactState.kind !== 'idle' && exactState.epoch === epoch ? exactState : null
  // Keeper-lane wake evidence is a large operator diagnostic (a card per
  // keeper, dozens of lane rows). Collapsed AND unmounted by default so the
  // schedule stays the light, primary content; the panel only mounts when the
  // operator opens it.
  const [diagOpen, setDiagOpen] = useState(false)

  useEffect(() => {
    const stopScheduleRefresh = subscribeScheduledAutomationRefresh()
    // Tool inventory is still needed for the keeper waiting/background panels.
    if (!toolsData.value) void loadTools()
    return stopScheduleRefresh
  }, [])

  // The calendar shares its active-only read with the shell preview.
  useEffect(() => {
    if (view !== 'calendar') return undefined
    return subscribeActiveSchedulesRefresh()
  }, [view])

  useEffect(() => {
    if (
      selectedScheduleId === null
      || projection?.state !== 'available'
      || inPageRequest !== null
    ) {
      // Keeping the same state object leaves a projection that selects nothing
      // without a second draw of the surface.
      setExactSchedule(current => current.kind === 'idle' ? current : { kind: 'idle' })
      return
    }
    const controller = new AbortController()
    // Every projection the observation publishes is a newer read of the
    // ledger, and a schedule outside its page is not in it: that schedule is
    // read again with each one. Its last answer stays on screen until the new
    // one arrives.
    setExactSchedule(current =>
      current.kind === 'resolved' && current.epoch === epoch && current.lookup.scheduleId === selectedScheduleId
        ? current
        : { kind: 'loading', scheduleId: selectedScheduleId, epoch })
    void fetchDashboardScheduledAutomationLookup(selectedScheduleId, {
      signal: controller.signal,
    })
      .then(lookup => {
        if (controller.signal.aborted || !isEpochCurrent(epoch)) return
        setExactSchedule({ kind: 'resolved', lookup, rereadFailure: null, epoch })
      })
      .catch((error: unknown) => {
        if (controller.signal.aborted || !isEpochCurrent(epoch)) return
        const reason = error instanceof Error ? error.message : String(error)
        // A read that fails after this schedule was answered keeps that answer
        // open and says it was not read again; the next projection reads it
        // once more. Only a schedule never answered has nothing to show.
        setExactSchedule(current =>
          current.kind === 'resolved' && current.epoch === epoch && current.lookup.scheduleId === selectedScheduleId
            ? { ...current, rereadFailure: reason }
            : { kind: 'failed', scheduleId: selectedScheduleId, reason, epoch })
      })
    return () => { controller.abort() }
  }, [selectedScheduleId, epoch, projection, inPageRequest !== null])

  function selectSchedule(scheduleId: string | null) {
    const params = { ...route.value.params }
    if (scheduleId === null) delete params.schedule_id
    else params.schedule_id = scheduleId
    replaceRoute('schedule', params)
  }

  function switchView(next: ScheduleView) {
    // Clear selection so a drawer opened in one view does not linger into the
    // other (the list panel renders its own overlay from the same id).
    selectSchedule(null)
    setView(next)
  }

  async function handlePrune() {
    if (
      blockingError !== null || !window.confirm(
        '완료되었거나 취소/만료된 예약을 정리하시겠습니까?\n연관된 실행 기록도 함께 삭제됩니다.',
      )
    ) {
      return
    }
    setPruning(true)
    try {
      const result = await pruneSchedules()
      if (!isEpochCurrent(epoch)) return
      showToast(`완료된 예약 ${result.pruned_count.toLocaleString()}개를 정리했습니다.`, 'success')
      await loadScheduledAutomation({ fresh: true })
    } catch (error) {
      if (!isEpochCurrent(epoch)) return
      const message = error instanceof Error ? error.message : String(error)
      console.error('[ScheduleSurface] prune failed:', error)
      showToast(message, 'error')
    } finally {
      setPruning(false)
    }
  }
  // In the calendar view the list panel is unmounted, so the surface owns the
  // overlay; the list panel renders its own overlay from the same selection.
  const exactRequest =
    exactSchedule?.kind === 'resolved'
    && exactSchedule.lookup.status === 'found'
    && exactSchedule.lookup.scheduleId === selectedScheduleId
      ? exactSchedule.lookup.request
      : null
  const selectedRequest =
    view === 'calendar' && selectedScheduleId !== null
      ? inPageRequest ?? exactRequest
      : null
  const exactLookupMessage = (() => {
    if (selectedScheduleId === null || exactSchedule === null) return null
    if (exactSchedule.kind === 'loading' && exactSchedule.scheduleId === selectedScheduleId) {
      return '정확한 예약을 조회하는 중입니다.'
    }
    if (exactSchedule.kind === 'failed' && exactSchedule.scheduleId === selectedScheduleId) {
      return exactSchedule.reason
    }
    if (
      exactSchedule.kind !== 'resolved'
      || exactSchedule.lookup.scheduleId !== selectedScheduleId
    ) return null
    if (exactSchedule.rereadFailure !== null) {
      return `최신 상태를 다시 읽지 못했습니다 · ${exactSchedule.rereadFailure}`
    }
    if (exactSchedule.lookup.status === 'found') return null
    return exactSchedule.lookup.status === 'not_found'
      ? 'schedule store에서 정확한 예약을 찾지 못했습니다.'
      : exactSchedule.lookup.reason
  })()

  return html`
    <main class="ov ov-2col sch-surf" data-screen-label="예약" data-testid="schedule-surface">
      <div class="ov-scroll">
        <header class="ov-head">
          <div>
            <span class="ov-eyebrow">Schedule</span>
            <h1>예약 · 자동화 큐</h1>
            <p class="ov-sub">
              keeper가 예약한 미래 작업 · <span class="mono">lib/schedule</span>
            </p>
            <div
              class="mt-2 flex flex-wrap items-center gap-2 text-2xs text-[var(--color-fg-muted)]"
              data-testid="schedule-reality-notice"
              title="schedule runner projection을 읽어 표시하며, 이 화면에서 keeper turn을 자동 구동하지 않습니다."
            >
              <${StatusChip} tone="warn" uppercase=${false}>관측 전용<//>
              <span class="sr-only">schedule runner projection을 읽어 표시하며, 이 화면에서 keeper turn을 자동 구동하지 않습니다.</span>
            </div>
          </div>
        </header>

        ${error || projectionError
          ? html`
              <div data-testid=${projectionError ? 'schedule-projection-unavailable' : undefined}>
                <${ErrorState} message=${`전체 예약 조회 실패 · ${error ?? projectionError ?? ''}`} class="mb-4" />
              </div>
            `
          : null}

        <section class="ov-kpis" aria-label="예약 요약">
          <div class="ov-kpi">
            <div class="ov-kpi-k">예약됨</div>
            <div class=${`ov-kpi-v ${scheduledCount !== null && scheduledCount > 0 ? 'info' : ''}`}>${countLabel(scheduledCount)}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">due · 실행</div>
            <div class=${`ov-kpi-v ${dueRunning !== null && dueRunning > 0 ? 'warn' : ''}`}>${countLabel(dueRunning)}</div>
          </div>
          <div class="ov-kpi">
            <div class="ov-kpi-k">총 예약</div>
            <div class="ov-kpi-v volt">${countLabel(totalCount)}</div>
          </div>
          <div class="ov-kpi" data-testid="schedule-kpi-queue-miss">
            <div class="ov-kpi-k">큐 누락</div>
            <div
              class=${`ov-kpi-v ${queueMisses === null ? '' : queueMisses > 0 ? 'warn' : 'ok'}`}
              title="dispatch됐으나 pending 큐에도 없고 keeper 반응 기록도 없는 예약 실행 수 — 실행 누락"
            >${countLabel(queueMisses)}</div>
          </div>
          <div class="ov-kpi" data-testid="schedule-kpi-queue-cancelled">
            <div class="ov-kpi-k">큐 취소</div>
            <div
              class=${`ov-kpi-v ${queueCancelled === null ? '' : queueCancelled > 0 ? 'warn' : 'ok'}`}
              title="마지막 wake 를 큐가 accepted cancellation 으로 정리한 예약 수 — keeper 턴 없이 끝남 (대상 keeper 부재 포함)"
            >${countLabel(queueCancelled)}</div>
          </div>
          <div class="ov-kpi" data-testid="schedule-kpi-wake-failed">
            <div class="ov-kpi-k">wake 실패</div>
            <div
              class=${`ov-kpi-v ${wakeCounts === null ? '' : wakeCounts.failed > 0 ? 'warn' : 'ok'}`}
              title=${wakeCounts === null
                ? 'wake_counts 없음 — 서버가 보내지 않았거나 형식이 맞지 않음'
                : `보존된 wake ${wakeCounts.retained}건(예약당 최대 ${wakeCounts.retention_per_schedule}) 중 실패 ${wakeCounts.failed} · 성공 ${wakeCounts.succeeded} · 진행 ${wakeCounts.running} · 살아있는 예약 중 마지막 wake 실패 ${wakeCounts.active_with_failed_newest_wake}`}
            >${countLabel(wakeCounts === null ? null : wakeCounts.failed)}</div>
          </div>
        </section>

        ${'' /* The fleet page's own numbers. The calendar draws another
              page and says at its top what that one leaves out. */}
        ${page && view === 'list'
          ? html`
              <div class="mb-3 text-2xs text-[var(--color-fg-muted)]" data-testid="schedule-page-metadata">
                ${`표시 ${page.visibleCount.toLocaleString()} / 전체 ${page.totalCount.toLocaleString()} · 최대 ${page.limit.toLocaleString()}${page.truncated ? ' · 일부만 표시' : ''}`}
              </div>
            `
          : null}

        ${exactLookupMessage
          ? html`
              <div class="ov-card mb-3 text-xs text-[var(--color-fg-muted)]" data-testid="schedule-exact-lookup-status">
                <span class="mono">${selectedScheduleId}</span> · ${exactLookupMessage}
              </div>
            `
          : null}

        <div class="sch-viewbar" data-testid="schedule-viewbar">
          <div class="sch-viewseg" role="tablist" aria-label="예약 뷰">
            <button
              type="button"
              role="tab"
              aria-selected=${view === 'calendar' ? 'true' : 'false'}
              class=${`sch-viewbtn ${view === 'calendar' ? 'on' : ''}`}
              data-testid="schedule-view-calendar"
              onClick=${() => switchView('calendar')}
            >▦ 캘린더</button>
            <button
              type="button"
              role="tab"
              aria-selected=${view === 'list' ? 'true' : 'false'}
              class=${`sch-viewbtn ${view === 'list' ? 'on' : ''}`}
              data-testid="schedule-view-list"
              onClick=${() => switchView('list')}
            >≡ 목록</button>
          </div>
          ${viewAutomation
            ? html`<${CadenceSummary} counts=${cadCounts} active=${cadenceFilter} onFilter=${setCadenceFilter} />`
            : null}
          <${ActionButton}
            variant="danger"
            size="sm"
            onClick=${handlePrune}
            disabled=${pruning || blockingError !== null}
            ariaBusy=${pruning}
            testId="schedule-prune-btn"
          >
            ${pruning ? '정리 중...' : '완료된 예약 정리'}
          <//>
        </div>

        ${view === 'calendar'
            ? html`
                ${calendarError
                  ? html`
                      <div data-testid="schedule-calendar-unavailable">
                        <${ErrorState} message=${`캘린더에 쓸 예약을 읽지 못했습니다 · ${calendarError}`} class="mb-4" />
                      </div>
                    `
                  : null}
                ${calendar && calendarLoading && html`
                  <p class="ap-muted" role="status"><${InlineSpinner} /> 캘린더 예약 갱신 중…</p>
                `}
                ${calendar && (calendarLoading || calendarError) && html`
                  <p class="ap-muted">마지막 확인 · <time dateTime=${new Date(calendar.observedAt).toISOString()}>
                    ${formatTimestampKo(calendar.observedAt / 1000)}
                  </time></p>
                `}
                ${calendarAutomation
                  ? html`<${ScheduleCalendar}
                      requests=${calendarAutomation.requests}
                      activeCount=${calendarAutomation.fsm.active_count}
                      nowMs=${Date.now()}
                      cadenceFilter=${cadenceFilter}
                      onOpen=${selectSchedule}
                    />`
                  : calendarError
                    ? null
                    : calendarLoading
                      ? html`<${LoadingState}>캘린더에 쓸 예약 불러오는 중…<//>`
                      : html`<p class="ap-muted">캘린더 예약 조회 대기 중</p>`}
              `
            : blockingError
              ? html`<p class="ap-muted" data-testid="schedule-ledger-unknown">전체 예약 목록을 확인할 수 없습니다.</p>`
              : loading && !automation
                ? html`<${LoadingState}>전체 예약 불러오는 중…<//>`
                : html`<${ScheduledAutomationPanel}
                automation=${automation ? filterAutomationByCadence(automation, cadenceFilter) : automation}
                variant="v2"
                selectedScheduleId=${selectedScheduleId}
                selectedRequest=${inPageRequest ?? exactRequest}
                onSelectSchedule=${selectSchedule}
              />`}

        ${'' /* Secondary diagnostics live BELOW the schedule and are unmounted
              until opened: the actual schedule (calendar/list) is the primary,
              above-the-fold content. The keeper-lane wake evidence panel is a
              large operator diagnostic (a card per keeper, dozens of lane rows)
              that previously buried the schedule and rendered on every tick.
              Lazy-mounting it keeps the default surface light. */}
        <section class="ov-card mt-4 sch-diag" data-testid="schedule-diagnostics">
          <button
            type="button"
            class="sch-diag-summary"
            aria-expanded=${diagOpen ? 'true' : 'false'}
            data-testid="schedule-diagnostics-toggle"
            onClick=${() => setDiagOpen(open => !open)}
          >Keeper 진단 · wake evidence ${diagOpen ? '▴' : '▾'}</button>
          ${diagOpen
            ? html`
                <section class="mt-3" aria-label="Keeper lane inventory" data-testid="schedule-keeper-lanes">
                  <div class="ov-card-h"><h3>Keeper Lanes · wake evidence</h3></div>
                  <${KeeperLaneInventoryPanel} inventory=${waitingInventory} />
                </section>
              `
            : null}
        </section>
      </div>
      ${automation && scheduledCount !== null && dueRunning !== null && totalCount !== null
        ? html`<${ScheduleAside}
            requests=${automation.requests ?? []}
            sum=${{ scheduled: scheduledCount, dueRunning, total: totalCount }}
            onOpen=${selectSchedule}
          />`
        : null}
      ${selectedRequest
        ? html`<${SchDetail}
            request=${selectedRequest}
            signals=${automation?.signals ?? []}
            onClose=${() => selectSchedule(null)}
          />`
        : null}
    </main>
  `
}
